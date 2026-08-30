import Foundation

/// メッセージの取得・送信・再送・既読.
extension ChatStore {

    // MARK: - 取得

    /// チャットを開く. 一覧で選ばれたときに呼ぶ.
    func openConversation(_ conversationID: ConversationID) async {
        selectedConversationID = conversationID
        if messagesByConversation[conversationID] == nil {
            await refreshMessages(in: conversationID)
        } else {
            // すでに表示できる内容があるので, 先に描画してから裏で更新する.
            Task { [weak self] in
                await self?.refreshMessages(in: conversationID)
            }
        }
        await markSelectedConversationRead()
    }

    /// 最新のメッセージを取り直す.
    func refreshMessages(in conversationID: ConversationID) async {
        guard phase == .ready else { return }
        loadingConversationIDs.insert(conversationID)
        defer { loadingConversationIDs.remove(conversationID) }

        do {
            let existing = messagesByConversation[conversationID] ?? []
            let confirmed = existing.filter { $0.deliveryState == .sent }

            let fetched: [Message]
            if let newest = confirmed.last?.createdAt {
                // 差分だけ取る. 会話を開くたびに全件取り直すのは無駄が大きい.
                fetched = try await backend.fetchNewMessages(in: conversationID, after: newest)
            } else {
                fetched = try await backend.fetchMessages(
                    in: conversationID,
                    before: nil,
                    limit: AppConstants.Paging.initialMessagePageSize
                )
                if fetched.count == AppConstants.Paging.initialMessagePageSize {
                    hasMoreHistory.insert(conversationID)
                }
            }

            merge(fetched, into: conversationID)
            await loadMissingSenderProfiles(from: fetched)
        } catch {
            let appError = AppError.wrap(error)
            if appError != .offline {
                banner = appError
            }
        }
    }

    /// 上方向のページング.
    func loadOlderMessages(in conversationID: ConversationID) async {
        guard hasMoreHistory.contains(conversationID) else { return }
        guard let oldest = messagesByConversation[conversationID]?.first?.createdAt else { return }

        do {
            let older = try await backend.fetchMessages(
                in: conversationID,
                before: oldest,
                limit: AppConstants.Paging.olderMessagePageSize
            )
            if older.count < AppConstants.Paging.olderMessagePageSize {
                hasMoreHistory.remove(conversationID)
            }
            merge(older, into: conversationID)
            await loadMissingSenderProfiles(from: older)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// サーバから来たメッセージを, 楽観表示中のものを保ちつつ差し込む.
    private func merge(_ incoming: [Message], into conversationID: ConversationID) {
        guard !incoming.isEmpty else { return }
        var current = messagesByConversation[conversationID] ?? []
        // 万一同じ ID が重複していても落ちないよう, 後勝ちで索引を作る.
        var indexByID = Dictionary(
            current.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, latest in latest }
        )

        for message in incoming {
            var updated = message
            updated.isRead = isRead(message, in: conversationID)
            if let index = indexByID[message.id] {
                // 自分が送って楽観表示していたものが確定した場合など.
                current[index] = updated
            } else {
                indexByID[message.id] = current.count
                current.append(updated)
            }
        }
        current.sort { $0.createdAt < $1.createdAt }
        messagesByConversation[conversationID] = current
    }

    private func isRead(_ message: Message, in conversationID: ConversationID) -> Bool {
        guard let conversation = conversation(conversationID) else { return true }
        if message.senderID == currentUserID { return true }
        return message.createdAt <= conversation.lastReadAt
    }

    private func loadMissingSenderProfiles(from messages: [Message]) async {
        let needed = Set(messages.map(\.senderID)).subtracting(profilesByID.keys)
        guard !needed.isEmpty else { return }
        if let profiles = try? await backend.fetchProfiles(ids: Array(needed)) {
            for profile in profiles {
                profilesByID[profile.id] = profile
            }
        }
    }

    // MARK: - 送信

    func sendText(_ text: String, in conversationID: ConversationID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let me = currentUserID else { return }

        let outgoing = OutgoingMessage(
            conversationID: conversationID,
            senderID: me,
            body: .text(String(trimmed.prefix(AppConstants.Validation.messageTextMaxLength)))
        )
        await enqueueAndShow(outgoing)
    }

    /// 写真を送る. 圧縮とサムネイル生成を済ませてからキューに積む.
    func sendImage(originalData: Data, in conversationID: ConversationID) async {
        guard let me = currentUserID else { return }
        do {
            let media = try await processor.prepareImage(originalData: originalData)
            let outgoing = OutgoingMessage(
                conversationID: conversationID,
                senderID: me,
                body: .media(media)
            )
            await enqueueAndShow(outgoing)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 動画を送る. 再エンコードに時間がかかるので, 完了後にキューへ積む.
    func sendVideo(sourceURL: URL, in conversationID: ConversationID) async {
        guard let me = currentUserID else { return }
        do {
            let media = try await processor.prepareVideo(sourceURL: sourceURL)
            let outgoing = OutgoingMessage(
                conversationID: conversationID,
                senderID: me,
                body: .media(media)
            )
            await enqueueAndShow(outgoing)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// キューに積み, 送信完了を待たずに吹き出しを出す.
    private func enqueueAndShow(_ outgoing: OutgoingMessage) async {
        await outboxQueue.enqueue(outgoing)
        merge([outgoing.optimisticMessage()], into: outgoing.conversationID)
        // 自分の送信で一覧の並びも即座に更新する.
        updateConversationPreview(for: outgoing)
        flushOutbox()
    }

    private func updateConversationPreview(for outgoing: OutgoingMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == outgoing.conversationID }) else { return }
        let preview: String
        switch outgoing.body {
        case .text(let text): preview = text
        case .media(let media): preview = media.kind == .image
            ? String(localized: "写真")
            : String(localized: "動画")
        }
        conversations[index].lastMessage = MessageSummary(
            senderID: outgoing.senderID,
            preview: preview,
            createdAt: outgoing.createdAt
        )
        conversations.sort { $0.sortDate > $1.sortDate }
    }

    // MARK: - 送信キューの実行

    /// 送信待ちを順に送る.
    ///
    /// 1 件ずつ直列に送るのは, 会話内の順序を保つためと, 学校の共有 Wi-Fi で
    /// 複数の動画アップロードを同時に走らせないため.
    func runOutboxFlush() async {
        guard phase == .ready else { return }
        // 明確にオフラインのときは叩かない. 復帰時に NetworkMonitor から
        // もう一度フラッシュが走る.
        guard isOnline else { return }

        while true {
            let ready = await outboxQueue.ready()
            guard let next = ready.first else { break }

            do {
                let sent = try await backend.send(next)
                await outboxQueue.complete(next.id)
                merge([sent], into: sent.conversationID)
                await refreshConversationSummaryAfterSend(sent)
            } catch {
                let appError = AppError.wrap(error)
                await outboxQueue.recordFailure(next.id, error: appError)
                reflectOutboxState(for: next.id, conversationID: next.conversationID)

                if !appError.isRetryable {
                    banner = appError
                }
                // 一時的な失敗なら, 次回のフラッシュ(再接続 / ポーリング)に任せる.
                break
            }
        }
    }

    private func refreshConversationSummaryAfterSend(_ message: Message) async {
        guard let index = conversations.firstIndex(where: { $0.id == message.conversationID }) else { return }
        conversations[index].lastMessage = MessageSummary(
            senderID: message.senderID,
            preview: message.content.previewText,
            createdAt: message.createdAt
        )
        conversations.sort { $0.sortDate > $1.sortDate }
    }

    /// キューの状態を吹き出しの表示に反映する.
    private func reflectOutboxState(for messageID: MessageID, conversationID: ConversationID) {
        Task { [weak self] in
            guard let self else { return }
            let pending = await self.outboxQueue.items(in: conversationID)
            guard let item = pending.first(where: { $0.id == messageID }) else { return }
            self.merge([item.optimisticMessage()], into: conversationID)
        }
    }

    /// ユーザが「再送信」を押した.
    func retrySending(_ messageID: MessageID, in conversationID: ConversationID) async {
        guard let refreshed = await outboxQueue.resetForManualRetry(messageID) else { return }
        merge([refreshed.optimisticMessage()], into: conversationID)
        flushOutbox()
    }

    /// ユーザが送信を取り消した.
    func cancelSending(_ messageID: MessageID, in conversationID: ConversationID) async {
        await outboxQueue.cancel(messageID)
        messagesByConversation[conversationID]?.removeAll { $0.id == messageID }
    }

    // MARK: - 既読

    /// 表示中のチャットを既読にする.
    func markSelectedConversationRead() async {
        guard let conversationID = selectedConversationID else { return }
        await markRead(conversationID)
    }

    func markRead(_ conversationID: ConversationID) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let newest = messagesByConversation[conversationID]?.last?.createdAt else { return }
        guard newest > conversations[index].lastReadAt else { return }

        // 先にローカルを既読にする. 通信を待ってからバッジが消えると
        // 「開いたのに未読のまま」に見えてしまうため.
        conversations[index].lastReadAt = newest
        conversations[index].unreadCount = 0
        markLocalMessagesRead(in: conversationID, upTo: newest)

        do {
            try await backend.markRead(conversationID: conversationID, upTo: newest)
        } catch {
            // 失敗しても次に開いたときに送り直されるので, ユーザには出さない.
            Log.sync.notice("failed to persist read state")
        }
    }

    private func markLocalMessagesRead(in conversationID: ConversationID, upTo date: Date) {
        guard var messages = messagesByConversation[conversationID] else { return }
        for index in messages.indices where messages[index].createdAt <= date {
            messages[index].isRead = true
        }
        messagesByConversation[conversationID] = messages
    }

    /// 全会話の未読合計(アプリアイコンのバッジに使う).
    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }
}
