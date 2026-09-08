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
            // 取り消されたメッセージも, 開いた時点で確認する.
            Task { [weak self] in
                await self?.refreshMessages(in: conversationID)
                await self?.reconcileMessages(in: conversationID)
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
            await refreshReadReceipts(in: conversationID)
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

    /// 相手がどこまで読んだかを取り直す(自分の送信に付く「既読」の更新).
    ///
    /// 失敗しても会話の表示自体には影響しないので, エラーはユーザに出さない.
    func refreshReadReceipts(in conversationID: ConversationID) async {
        guard let receipts = try? await backend.fetchReadReceipts(in: conversationID) else { return }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        // 数秒ごとに呼ばれるので, 変化が無いときは代入しない
        // (代入するだけで画面全体の再描画が走るため).
        guard conversations[index].readReceipts != receipts else { return }
        conversations[index].readReceipts = receipts
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

    func sendText(
        _ text: String,
        in conversationID: ConversationID,
        replyTo: ReplyReference? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let me = currentUserID else { return }

        let outgoing = OutgoingMessage(
            conversationID: conversationID,
            senderID: me,
            body: .text(String(trimmed.prefix(AppConstants.Validation.messageTextMaxLength))),
            replyTo: replyTo
        )
        await enqueueAndShow(outgoing)
    }

    /// 写真を送る. 圧縮とサムネイル生成を済ませてからキューに積む.
    func sendImage(
        originalData: Data,
        in conversationID: ConversationID,
        replyTo: ReplyReference? = nil
    ) async {
        guard let me = currentUserID else { return }
        do {
            let media = try await processor.prepareImage(originalData: originalData)
            let outgoing = OutgoingMessage(
                conversationID: conversationID,
                senderID: me,
                body: .media(media),
                replyTo: replyTo
            )
            await enqueueAndShow(outgoing)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 動画を送る. 再エンコードに時間がかかるので, 完了後にキューへ積む.
    func sendVideo(
        sourceURL: URL,
        in conversationID: ConversationID,
        replyTo: ReplyReference? = nil
    ) async {
        guard let me = currentUserID else { return }
        do {
            let media = try await processor.prepareVideo(sourceURL: sourceURL)
            let outgoing = OutgoingMessage(
                conversationID: conversationID,
                senderID: me,
                body: .media(media),
                replyTo: replyTo
            )
            await enqueueAndShow(outgoing)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    // MARK: - 対戦(オセロ)

    /// この会話でいま進行している対戦.
    ///
    /// 1 手 = 1 メッセージなので, 最後の対戦メッセージが現在の盤面になる.
    func currentGame(in conversationID: ConversationID) -> GameSnapshot? {
        messagesByConversation[conversationID]?
            .last(where: { $0.content.game != nil && !$0.isUnsent })?
            .content.game
    }

    /// 対戦を始める / 石を置く.
    ///
    /// 盤面をまるごと載せたメッセージを送るだけなので, 送信の仕組みは
    /// 通常のメッセージと同じ(オフラインなら送信待ちに積まれる).
    func sendGameMove(_ snapshot: GameSnapshot, in conversationID: ConversationID) async {
        guard let me = currentUserID else { return }
        let outgoing = OutgoingMessage(
            conversationID: conversationID,
            senderID: me,
            body: .game(snapshot)
        )
        await enqueueAndShow(outgoing)
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
        case .game(let snapshot): preview = snapshot.previewText
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

    /// まだ送信できていないメッセージを, キューから取り下げる.
    ///
    /// サーバにはまだ何も無いので, 痕跡を残さず消してよい.
    func cancelSending(_ messageID: MessageID, in conversationID: ConversationID) async {
        await outboxQueue.cancel(messageID)
        messagesByConversation[conversationID]?.removeAll { $0.id == messageID }
    }

    // MARK: - 送信取り消し

    /// 送信済みのメッセージを取り消す.
    ///
    /// 相手の画面にも「送信を取り消しました」が残る. 完全に消えるのではなく
    /// 痕跡が残ることは, 取り消す前に画面上で断りを入れている.
    func unsendMessage(_ messageID: MessageID, in conversationID: ConversationID) async {
        do {
            let updated = try await backend.unsendMessage(messageID, in: conversationID)
            applyUnsent(updated, in: conversationID)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 取り消し済みの状態を画面と端末内の保存物へ反映する.
    private func applyUnsent(_ message: Message, in conversationID: ConversationID) {
        // 端末に残っているダウンロード済みの写真・動画も消す.
        // サーバから消しても手元に残っていては取り消しの意味がない.
        if let attachment = messagesByConversation[conversationID]?
            .first(where: { $0.id == message.id })?
            .content.attachment {
            purgeCachedMedia(for: attachment)
        }
        merge([message], into: conversationID)
        refreshPreviewIfNeeded(for: conversationID)
    }

    private func purgeCachedMedia(for attachment: MediaAttachment) {
        if let localURL = attachment.localURL {
            files.remove(at: localURL)
        }
        if let remote = attachment.remote {
            files.remove(at: files.cachedURL(for: remote, kind: attachment.kind))
        }
    }

    /// 一覧に出ている「最後のメッセージ」が取り消されたときに文言を追従させる.
    private func refreshPreviewIfNeeded(for conversationID: ConversationID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let newest = messagesByConversation[conversationID]?.last
        else { return }
        conversations[index].lastMessage = MessageSummary(
            senderID: newest.senderID,
            preview: newest.isUnsent
                ? String(localized: "送信を取り消しました")
                : newest.content.previewText,
            createdAt: newest.createdAt
        )
    }

    /// 取得済みのメッセージがその後書き換えられていないかを確かめる.
    ///
    /// 送信取り消しは既存レコードの書き換えとして届くため, 「`sentAt` が
    /// 新しいものを取る」差分取得では永久に気付けない. ID と更新時刻だけを
    /// 軽く引き, 変わったものだけを取り直す.
    func reconcileMessages(in conversationID: ConversationID) async {
        guard phase == .ready else { return }
        let loaded = (messagesByConversation[conversationID] ?? [])
            .filter { $0.deliveryState == .sent && !$0.isUnsent }
        guard let oldest = loaded.first?.createdAt else { return }

        guard let revisions = try? await backend.fetchMessageRevisions(
            in: conversationID,
            since: oldest
        ) else { return }

        // 手元の記録より新しく書き換えられているものを探す.
        let changed = loaded.filter { message in
            guard let serverModifiedAt = revisions[message.id] else { return false }
            guard let localModifiedAt = message.modifiedAt else { return true }
            return serverModifiedAt > localModifiedAt
        }
        guard !changed.isEmpty else { return }

        guard let refreshed = try? await backend.fetchMessages(
            ids: changed.map(\.id),
            in: conversationID
        ) else { return }

        for message in refreshed where message.isUnsent {
            applyUnsent(message, in: conversationID)
        }
        let stillLive = refreshed.filter { !$0.isUnsent }
        if !stillLive.isEmpty {
            merge(stillLive, into: conversationID)
        }
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
