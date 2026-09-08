import Foundation
import CloudKit
import CryptoKit

/// 会話・メッセージ・メディアに関する `CloudKitBackend` の実装.
extension CloudKitBackend {

    // MARK: - 参照ヘルパ

    private func reference(to conversationID: ConversationID) -> CKRecord.Reference {
        // Public Database では親子関係を作らないので action は .none.
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: conversationID.rawValue),
            action: .none
        )
    }

    // MARK: - 会話鍵

    /// 会話鍵を取得する(キャッシュ → CloudKit の順).
    func conversationKey(for conversationID: ConversationID) async throws -> SymmetricKey {
        if let cached = await crypto.cachedKey(for: conversationID) { return cached }

        let me = try await currentUserID()
        let owner: UserID
        if let cachedOwner = cachedOwner(for: conversationID) {
            owner = cachedOwner
        } else {
            let record = try await fetchWithRetry(CKRecord.ID(recordName: conversationID.rawValue))
            let raw = try CloudKitMapper.rawConversation(from: record, currentUserID: me)
            cacheConversationMetadata(participants: raw.participantIDs, owner: raw.ownerID, for: raw.id)
            owner = raw.ownerID
        }
        return try await fetchAndUnwrapKey(conversationID: conversationID, owner: owner, me: me)
    }

    private func fetchAndUnwrapKey(conversationID: ConversationID, owner: UserID, me: UserID) async throws -> SymmetricKey {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            CKSchema.ConversationKey.conversation, reference(to: conversationID),
            CKSchema.ConversationKey.recipientID, me.rawValue
        )
        let query = CKQuery(recordType: CKSchema.ConversationKey.recordType, predicate: predicate)
        let records = try await queryWithRetry(query, limit: 10)

        // 会話の作成者が書いた鍵だけを信用する.
        // 第三者が自分宛の偽の鍵レコードを置いても, ここで無視される.
        guard let record = records.first(where: {
                CloudKitMapper.resolvedCreatorName(of: $0, currentUserID: me) == owner.rawValue
              }),
              let parsed = try? CloudKitMapper.wrappedKey(from: record) else {
            throw AppError.missingEncryptionKey
        }
        let key = try await crypto.unwrap(parsed.key)
        await crypto.cache(key, for: conversationID)
        return key
    }

    /// 参加者全員ぶんの鍵レコードを書き出す.
    private func distributeKey(
        _ key: SymmetricKey,
        conversationID: ConversationID,
        owner: UserID,
        to participants: [UserProfile]
    ) async throws {
        for participant in participants {
            guard let publicKey = participant.publicKeyData else {
                throw AppError.recipientHasNoPublicKey(displayName: participant.displayName)
            }
            let wrapped = try await crypto.wrap(key, forRecipientPublicKey: publicKey)

            let recordID = CKRecord.ID(
                recordName: CKSchema.ConversationKey.recordName(
                    conversation: conversationID,
                    recipient: participant.id,
                    owner: owner
                )
            )
            let record = CKRecord(recordType: CKSchema.ConversationKey.recordType, recordID: recordID)
            record[CKSchema.ConversationKey.conversation] = reference(to: conversationID)
            record[CKSchema.ConversationKey.recipientID] = participant.id.rawValue as CKRecordValue
            record[CKSchema.ConversationKey.ephemeralPublicKey] = wrapped.ephemeralPublicKey as CKRecordValue
            record[CKSchema.ConversationKey.wrappedKey] = wrapped.ciphertext as CKRecordValue

            do {
                _ = try await saveWithRetry(record)
            } catch {
                // 既に配布済みなら成功扱い(メンバー再追加や再試行で失敗させない).
                if CloudKitErrorMapping.isAlreadyExists(error) { continue }
                throw CloudKitErrorMapping.appError(from: error)
            }
        }
    }

    // MARK: - 会話一覧

    func fetchConversations() async throws -> [Conversation] {
        let me = try await currentUserID()

        // 4 本のクエリを順に実行する. 並列化も可能だが CKQuery は Sendable ではなく,
        // 得られる短縮は数百ミリ秒に留まる. 一覧は先にローカルの内容を表示するので
        // ここは単純さを優先する.
        let conversationRecords = try await queryWithRetry(
            CKQuery(
                recordType: CKSchema.Conversation.recordType,
                predicate: NSPredicate(format: "%K CONTAINS %@", CKSchema.Conversation.participantIDs, me.rawValue)
            ),
            limit: 300
        )

        let keyRecords = try await queryWithRetry(
            CKQuery(
                recordType: CKSchema.ConversationKey.recordType,
                predicate: NSPredicate(format: "%K == %@", CKSchema.ConversationKey.recipientID, me.rawValue)
            ),
            limit: 600
        )

        let readRecords = try await queryWithRetry(
            CKQuery(
                recordType: CKSchema.ReadState.recordType,
                predicate: NSPredicate(format: "%K == %@", CKSchema.ReadState.userID, me.rawValue)
            ),
            limit: 300
        )

        // 退出記録は無くても動くので, 取得に失敗しても一覧は出す.
        let leaveRecords = (try? await queryWithRetry(
            CKQuery(
                recordType: CKSchema.ConversationLeave.recordType,
                predicate: NSPredicate(format: "%K == %@", CKSchema.ConversationLeave.userID, me.rawValue)
            ),
            limit: 300
        )) ?? []

        // --- 索引を作る ---

        var keysByConversation: [ConversationID: [(creator: String, wrapped: WrappedConversationKey)]] = [:]
        for record in keyRecords {
            guard let creator = CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me),
                  let parsed = try? CloudKitMapper.wrappedKey(from: record) else { continue }
            keysByConversation[parsed.conversation, default: []].append((creator, parsed.key))
        }

        var lastReadByConversation: [ConversationID: Date] = [:]
        for record in readRecords {
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == me.rawValue,
                  let reference = record[CKSchema.ReadState.conversation] as? CKRecord.Reference,
                  let date = record[CKSchema.ReadState.lastReadAt] as? Date else { continue }
            lastReadByConversation[ConversationID(reference.recordID.recordName)] = date
        }

        var leftConversations: Set<ConversationID> = []
        for record in leaveRecords {
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == me.rawValue,
                  let reference = record[CKSchema.ConversationLeave.conversation] as? CKRecord.Reference
            else { continue }
            leftConversations.insert(ConversationID(reference.recordID.recordName))
        }

        // --- 会話を組み立てる ---

        var conversations: [Conversation] = []
        var keysByID: [ConversationID: SymmetricKey] = [:]

        for record in conversationRecords {
            guard let raw = try? CloudKitMapper.rawConversation(from: record, currentUserID: me) else { continue }
            guard raw.participantIDs.contains(me) else { continue }
            guard !leftConversations.contains(raw.id) else { continue }

            cacheConversationMetadata(participants: raw.participantIDs, owner: raw.ownerID, for: raw.id)

            // 鍵を解く. 解けない会話は表示しない(内容が一切読めないため).
            let key: SymmetricKey
            if let cached = await crypto.cachedKey(for: raw.id) {
                key = cached
            } else if let candidate = keysByConversation[raw.id]?.first(where: { $0.creator == raw.ownerID.rawValue }),
                      let unwrapped = try? await crypto.unwrap(candidate.wrapped) {
                await crypto.cache(unwrapped, for: raw.id)
                key = unwrapped
            } else {
                Log.backend.notice("no usable key for conversation, skipping")
                continue
            }
            keysByID[raw.id] = key

            var title: String?
            if let cipher = raw.titleCipher,
               let plaintext = try? await crypto.open(cipher, with: key) {
                title = String(data: plaintext, encoding: .utf8)
            }
            var imageData: Data?
            if let cipher = raw.imageCipher {
                imageData = try? await crypto.open(cipher, with: key)
            }

            conversations.append(
                Conversation(
                    id: raw.id,
                    kind: raw.kind,
                    title: title,
                    imageData: imageData,
                    participantIDs: raw.participantIDs,
                    ownerID: raw.ownerID,
                    createdAt: raw.createdAt,
                    lastMessage: nil,
                    lastReadAt: lastReadByConversation[raw.id] ?? .distantPast,
                    unreadCount: 0
                )
            )
        }

        guard !conversations.isEmpty else { return [] }

        return try await attachRecentActivity(to: conversations, keys: keysByID, me: me)
    }

    /// 会話一覧に「最終メッセージ」と「未読数」を付ける.
    ///
    /// 会話ごとに問い合わせると往復が会話数に比例して増えるため, まとめて 1 本の
    /// クエリで直近のメッセージを取り, クライアント側で会話ごとに割り振る.
    /// 直近ウィンドウに 1 件も無い会話だけ, 個別に最新 1 件を引き直す.
    private func attachRecentActivity(
        to conversations: [Conversation],
        keys: [ConversationID: SymmetricKey],
        me: UserID
    ) async throws -> [Conversation] {

        let windowStart = conversations
            .map(\.lastReadAt)
            .min()
            .map { max($0, Date.now.addingTimeInterval(-Self.activityWindow)) }
            ?? Date.now.addingTimeInterval(-Self.activityWindow)

        let references = conversations.map { reference(to: $0.id) }
        var recentByConversation: [ConversationID: [CloudKitMapper.RawMessage]] = [:]

        let query = CKQuery(
            recordType: CKSchema.Message.recordType,
            predicate: NSPredicate(
                format: "%K IN %@ AND %K > %@",
                CKSchema.Message.conversation, references,
                CKSchema.Message.sentAt, windowStart as NSDate
            )
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.sentAt, ascending: false)]

        let lightKeys = [
            CKSchema.Message.conversation,
            CKSchema.Message.sentAt,
            CKSchema.Message.senderID,
            CKSchema.Message.payload
        ]
        let records = try await queryWithRetry(query, desiredKeys: lightKeys, limit: Self.activityFetchLimit)
        for record in records {
            guard let raw = try? CloudKitMapper.rawMessage(from: record, currentUserID: me) else { continue }
            recentByConversation[raw.conversationID, default: []].append(raw)
        }

        var updated: [Conversation] = []
        for var conversation in conversations {
            guard let key = keys[conversation.id] else {
                updated.append(conversation)
                continue
            }

            var recents = recentByConversation[conversation.id] ?? []
            if recents.isEmpty {
                // 直近ウィンドウに無い＝しばらく動きのない会話. 最新 1 件だけ引く.
                if let latest = try? await fetchLatestRawMessage(in: conversation.id, me: me) {
                    recents = [latest]
                }
            }
            guard let newest = recents.max(by: { $0.sentAt < $1.sentAt }) else {
                updated.append(conversation)
                continue
            }

            if let payload = try? await decodePayload(newest, key: key) {
                conversation.lastMessage = MessageSummary(
                    senderID: newest.senderID,
                    preview: Self.previewText(for: payload),
                    createdAt: newest.sentAt
                )
            }
            conversation.unreadCount = recents.filter {
                $0.sentAt > conversation.lastReadAt && $0.senderID != me
            }.count

            updated.append(conversation)
        }

        return updated.sorted { $0.sortDate > $1.sortDate }
    }

    private func fetchLatestRawMessage(in conversationID: ConversationID, me: UserID) async throws -> CloudKitMapper.RawMessage? {
        let query = CKQuery(
            recordType: CKSchema.Message.recordType,
            predicate: NSPredicate(format: "%K == %@", CKSchema.Message.conversation, reference(to: conversationID))
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.sentAt, ascending: false)]
        let records = try await queryWithRetry(
            query,
            desiredKeys: [
                CKSchema.Message.conversation,
                CKSchema.Message.sentAt,
                CKSchema.Message.senderID,
                CKSchema.Message.payload
            ],
            limit: 1
        )
        return records.compactMap { try? CloudKitMapper.rawMessage(from: $0, currentUserID: me) }.first
    }

    // MARK: - 会話の作成

    func openDirectConversation(with userID: UserID) async throws -> Conversation {
        let me = try await currentUserID()
        guard userID != me else { throw AppError.underlying(String(localized: "自分とのチャットは作成できません")) }

        let conversationID = Conversation.directConversationID(me, userID)

        // 既にあれば, それを使う(両者が同時に開いても同じ ID に収束する).
        if let existing = try? await fetchConversation(conversationID) {
            return existing
        }

        let profiles = try await fetchProfiles(ids: [me, userID])
        guard profiles.count == 2 else { throw AppError.underlying(String(localized: "相手の情報を取得できませんでした")) }

        let participants = [me, userID].sorted { $0.rawValue < $1.rawValue }
        let record = CKRecord(
            recordType: CKSchema.Conversation.recordType,
            recordID: CKRecord.ID(recordName: conversationID.rawValue)
        )
        record[CKSchema.Conversation.kind] = ConversationKind.direct.rawValue as CKRecordValue
        record[CKSchema.Conversation.participantIDs] = participants.map(\.rawValue) as CKRecordValue
        record[CKSchema.Conversation.ownerID] = me.rawValue as CKRecordValue
        record[CKSchema.Conversation.createdAt] = Date.now as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            // 相手が一瞬先に作った場合. 相手のレコードを正として読み直す.
            if CloudKitErrorMapping.isAlreadyExists(error) {
                return try await fetchConversation(conversationID)
            }
            throw CloudKitErrorMapping.appError(from: error)
        }

        let key = await crypto.makeConversationKey()
        try await distributeKey(key, conversationID: conversationID, owner: me, to: profiles)
        await crypto.cache(key, for: conversationID)
        cacheConversationMetadata(participants: participants, owner: me, for: conversationID)
        eventHub.emit(.conversationsChanged)

        return Conversation(
            id: conversationID,
            kind: .direct,
            participantIDs: participants,
            ownerID: me,
            createdAt: .now
        )
    }

    func createGroup(_ draft: GroupDraft) async throws -> Conversation {
        let me = try await currentUserID()
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError.underlying(String(localized: "グループ名を入力してください"))
        }
        guard name.count <= AppConstants.Validation.groupNameMaxLength else {
            throw AppError.underlying(String(localized: "グループ名は \(AppConstants.Validation.groupNameMaxLength) 文字までです"))
        }

        var memberIDs = Set(draft.memberIDs)
        memberIDs.insert(me)
        guard memberIDs.count >= 2 else {
            throw AppError.underlying(String(localized: "メンバーを 1 人以上選んでください"))
        }
        guard memberIDs.count <= AppConstants.Validation.groupMemberMaxCount else {
            throw AppError.underlying(String(localized: "メンバーは \(AppConstants.Validation.groupMemberMaxCount) 人までです"))
        }

        let profiles = try await fetchProfiles(ids: Array(memberIDs))
        guard profiles.count == memberIDs.count else {
            // 誰の情報が取れなかったのかまで出す. 「相手がまだプロフィール登録を
            // 済ませていない」場合が大半なので, 原因に辿り着けるようにする.
            let missing = memberIDs.subtracting(profiles.map(\.id))
            throw AppError.underlying(
                String(localized: "メンバー \(missing.count) 人の情報を取得できませんでした。相手がプロフィール登録を済ませているか確認してください")
            )
        }

        // 公開鍵が無い相手が 1 人でもいると, 会話レコードだけが残って
        // 誰も開けないグループができてしまう. 保存する前に弾く.
        if let unreachable = profiles.first(where: { !$0.canReceiveEncryptedMessages }) {
            throw AppError.recipientHasNoPublicKey(displayName: unreachable.displayName)
        }

        let conversationID = ConversationID.generate()
        let key = await crypto.makeConversationKey()
        let participants = profiles.map(\.id).sorted { $0.rawValue < $1.rawValue }

        let record = CKRecord(
            recordType: CKSchema.Conversation.recordType,
            recordID: CKRecord.ID(recordName: conversationID.rawValue)
        )
        record[CKSchema.Conversation.kind] = ConversationKind.group.rawValue as CKRecordValue
        record[CKSchema.Conversation.participantIDs] = participants.map(\.rawValue) as CKRecordValue
        record[CKSchema.Conversation.ownerID] = me.rawValue as CKRecordValue
        record[CKSchema.Conversation.createdAt] = Date.now as CKRecordValue
        record[CKSchema.Conversation.titleCipher] = try await crypto.seal(Data(name.utf8), with: key) as CKRecordValue
        if let imageData = draft.imageData {
            record[CKSchema.Conversation.imageCipher] = try await crypto.seal(imageData, with: key) as CKRecordValue
        }

        // 先に鍵を配ってから会話を保存すると, 鍵だけが残るゴミが出る.
        // 逆に会話を先に保存すると, 鍵配布に失敗しても後から再配布できる
        // (recordName が決定的なので冪等). こちらを採る.
        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
        try await distributeKey(key, conversationID: conversationID, owner: me, to: profiles)
        await crypto.cache(key, for: conversationID)
        cacheConversationMetadata(participants: participants, owner: me, for: conversationID)
        eventHub.emit(.conversationsChanged)

        return Conversation(
            id: conversationID,
            kind: .group,
            title: name,
            imageData: draft.imageData,
            participantIDs: participants,
            ownerID: me,
            createdAt: .now
        )
    }

    func addMembers(_ userIDs: [UserID], to conversationID: ConversationID) async throws -> Conversation {
        let me = try await currentUserID()
        let record = try await fetchWithRetry(CKRecord.ID(recordName: conversationID.rawValue))
        let raw = try CloudKitMapper.rawConversation(from: record, currentUserID: me)

        // Public Database ではレコードを更新できるのは作成者だけ.
        // UI 側でも作成者以外には追加ボタンを出さないが, ここでも防ぐ.
        guard raw.ownerID == me else {
            throw AppError.underlying(String(localized: "メンバーを追加できるのはグループの作成者だけです"))
        }
        guard raw.kind == .group else {
            throw AppError.underlying(String(localized: "1 対 1 のチャットにはメンバーを追加できません"))
        }

        var participants = Set(raw.participantIDs)
        let newIDs = userIDs.filter { !participants.contains($0) }
        guard !newIDs.isEmpty else {
            return try await fetchConversation(conversationID)
        }
        participants.formUnion(newIDs)
        guard participants.count <= AppConstants.Validation.groupMemberMaxCount else {
            throw AppError.underlying(String(localized: "メンバーは \(AppConstants.Validation.groupMemberMaxCount) 人までです"))
        }

        let newProfiles = try await fetchProfiles(ids: newIDs)
        guard newProfiles.count == newIDs.count else {
            throw AppError.underlying(String(localized: "追加するメンバーの情報を取得できませんでした"))
        }

        let key = try await conversationKey(for: conversationID)
        try await distributeKey(key, conversationID: conversationID, owner: me, to: newProfiles)

        let sorted = participants.sorted { $0.rawValue < $1.rawValue }
        record[CKSchema.Conversation.participantIDs] = sorted.map(\.rawValue) as CKRecordValue
        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
        cacheConversationMetadata(participants: sorted, owner: raw.ownerID, for: conversationID)
        eventHub.emit(.conversationsChanged)

        return try await fetchConversation(conversationID)
    }

    func leaveConversation(_ conversationID: ConversationID) async throws {
        let me = try await currentUserID()

        // 会話レコードの参加者一覧は作成者しか書き換えられないため,
        // 本人が作れる「退出記録」を置いて各クライアントが差し引く.
        let recordID = CKRecord.ID(
            recordName: CKSchema.ConversationLeave.recordName(conversation: conversationID, user: me)
        )
        let record = CKRecord(recordType: CKSchema.ConversationLeave.recordType, recordID: recordID)
        record[CKSchema.ConversationLeave.conversation] = reference(to: conversationID)
        record[CKSchema.ConversationLeave.userID] = me.rawValue as CKRecordValue
        record[CKSchema.ConversationLeave.leftAt] = Date.now as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            if !CloudKitErrorMapping.isAlreadyExists(error) {
                throw CloudKitErrorMapping.appError(from: error)
            }
        }

        await crypto.forgetKey(for: conversationID)
        eventHub.emit(.conversationsChanged)
    }

    /// 会話 1 件を取得して復号する.
    func fetchConversation(_ conversationID: ConversationID) async throws -> Conversation {
        let me = try await currentUserID()
        let record = try await fetchWithRetry(CKRecord.ID(recordName: conversationID.rawValue))
        let raw = try CloudKitMapper.rawConversation(from: record, currentUserID: me)
        guard raw.participantIDs.contains(me) else { throw AppError.notAParticipant }

        cacheConversationMetadata(participants: raw.participantIDs, owner: raw.ownerID, for: raw.id)
        let key = try await conversationKey(for: conversationID)

        var title: String?
        if let cipher = raw.titleCipher,
           let plaintext = try? await crypto.open(cipher, with: key) {
            title = String(data: plaintext, encoding: .utf8)
        }
        var imageData: Data?
        if let cipher = raw.imageCipher {
            imageData = try? await crypto.open(cipher, with: key)
        }

        return Conversation(
            id: raw.id,
            kind: raw.kind,
            title: title,
            imageData: imageData,
            participantIDs: raw.participantIDs,
            ownerID: raw.ownerID,
            createdAt: raw.createdAt
        )
    }

    // MARK: - メッセージ取得

    func fetchMessages(in conversationID: ConversationID, before: Date?, limit: Int) async throws -> [Message] {
        let me = try await currentUserID()
        let key = try await conversationKey(for: conversationID)

        let predicate: NSPredicate
        if let before {
            predicate = NSPredicate(
                format: "%K == %@ AND %K < %@",
                CKSchema.Message.conversation, reference(to: conversationID),
                CKSchema.Message.sentAt, before as NSDate
            )
        } else {
            predicate = NSPredicate(
                format: "%K == %@",
                CKSchema.Message.conversation, reference(to: conversationID)
            )
        }

        let query = CKQuery(recordType: CKSchema.Message.recordType, predicate: predicate)
        // 新しい順に取ってから反転する. 古い順に取ると最新に辿り着くまで全件必要になる.
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.sentAt, ascending: false)]

        let records = try await queryWithRetry(query, desiredKeys: Self.messageDesiredKeys, limit: limit)
        return try await decodeMessages(records, key: key, me: me).sorted { $0.createdAt < $1.createdAt }
    }

    func fetchNewMessages(in conversationID: ConversationID, after date: Date) async throws -> [Message] {
        let me = try await currentUserID()
        let key = try await conversationKey(for: conversationID)

        let query = CKQuery(
            recordType: CKSchema.Message.recordType,
            predicate: NSPredicate(
                format: "%K == %@ AND %K > %@",
                CKSchema.Message.conversation, reference(to: conversationID),
                CKSchema.Message.sentAt, date as NSDate
            )
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.sentAt, ascending: true)]

        let records = try await queryWithRetry(
            query,
            desiredKeys: Self.messageDesiredKeys,
            limit: AppConstants.Paging.initialMessagePageSize
        )
        return try await decodeMessages(records, key: key, me: me).sorted { $0.createdAt < $1.createdAt }
    }

    private func decodeMessages(_ records: [CKRecord], key: SymmetricKey, me: UserID) async throws -> [Message] {
        var messages: [Message] = []
        for record in records {
            guard let raw = try? CloudKitMapper.rawMessage(from: record, currentUserID: me) else {
                // なりすまし検出 or 壊れたレコード. 1 件落としても会話は表示する.
                continue
            }
            guard let payload = try? await decodePayload(raw, key: key) else { continue }
            let thumbnail: Data?
            if let cipher = raw.thumbnailCipher {
                thumbnail = try? await crypto.open(cipher, with: key)
            } else {
                thumbnail = nil
            }
            messages.append(Self.message(from: raw, payload: payload, thumbnailData: thumbnail))
        }
        return messages
    }

    private func decodePayload(_ raw: CloudKitMapper.RawMessage, key: SymmetricKey) async throws -> MessagePayload {
        let plaintext = try await crypto.open(raw.payloadCipher, with: key)
        return try JSONDecoder().decode(MessagePayload.self, from: plaintext)
    }

    private static func message(
        from raw: CloudKitMapper.RawMessage,
        payload: MessagePayload,
        thumbnailData: Data?
    ) -> Message {
        // 取り消し済みは中身を持たない. 位置と時刻だけを残して印を付ける.
        if payload.isUnsent == true {
            return Message(
                id: raw.id,
                conversationID: raw.conversationID,
                senderID: raw.senderID,
                content: .text(""),
                createdAt: raw.sentAt,
                deliveryState: .sent,
                isUnsent: true,
                modifiedAt: raw.modifiedAt,
                isRead: true
            )
        }

        let content: MessageContent
        if let game = payload.game {
            return Message(
                id: raw.id,
                conversationID: raw.conversationID,
                senderID: raw.senderID,
                content: .game(game),
                createdAt: raw.sentAt,
                deliveryState: .sent,
                modifiedAt: raw.modifiedAt,
                isRead: true
            )
        }
        if let media = payload.media {
            let attachment = MediaAttachment(
                id: media.attachmentID,
                kind: media.kind,
                remote: MediaReference(
                    recordName: raw.id.rawValue,
                    fieldName: CKSchema.Message.mediaAsset,
                    byteCount: media.byteCount
                ),
                thumbnailData: thumbnailData,
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight,
                duration: media.duration,
                byteCount: media.byteCount
            )
            content = media.kind == .image ? .image(attachment) : .video(attachment)
        } else {
            content = .text(payload.text ?? "")
        }

        return Message(
            id: raw.id,
            conversationID: raw.conversationID,
            senderID: raw.senderID,
            content: content,
            createdAt: raw.sentAt,
            deliveryState: .sent,
            replyTo: payload.replyTo,
            modifiedAt: raw.modifiedAt,
            isRead: true   // 既読判定は会話の lastReadAt との比較で上位層が付け直す
        )
    }

    private static func previewText(for payload: MessagePayload) -> String {
        if payload.isUnsent == true {
            return String(localized: "送信を取り消しました")
        }
        if let game = payload.game {
            return game.previewText
        }
        if let media = payload.media {
            return media.kind == .image ? String(localized: "写真") : String(localized: "動画")
        }
        return payload.text ?? ""
    }

    // MARK: - 送信

    func send(_ outgoing: OutgoingMessage) async throws -> Message {
        let me = try await currentUserID()
        guard outgoing.senderID == me else { throw AppError.senderMismatch }

        let participants = try await participants(of: outgoing.conversationID, me: me)
        guard participants.contains(me) else { throw AppError.notAParticipant }

        let key = try await conversationKey(for: outgoing.conversationID)

        let payload: MessagePayload
        switch outgoing.body {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppError.underlying(String(localized: "メッセージが空です"))
            }
            payload = MessagePayload(
                text: String(trimmed.prefix(AppConstants.Validation.messageTextMaxLength)),
                replyTo: outgoing.replyTo
            )
        case .media(let media):
            payload = MessagePayload(media: media.metadata, replyTo: outgoing.replyTo)
        case .game(let snapshot):
            payload = MessagePayload(game: snapshot)
        }

        let record = CKRecord(
            recordType: CKSchema.Message.recordType,
            recordID: CKRecord.ID(recordName: outgoing.id.rawValue)
        )
        record[CKSchema.Message.conversation] = reference(to: outgoing.conversationID)
        record[CKSchema.Message.senderID] = me.rawValue as CKRecordValue
        record[CKSchema.Message.sentAt] = outgoing.createdAt as CKRecordValue
        record[CKSchema.Message.participantIDs] = participants.map(\.rawValue) as CKRecordValue
        // プッシュ通知の「誰から」に使う. 未取得のときは一般名詞にフォールバックする.
        record[CKSchema.Message.senderDisplayName] = (currentDisplayName() ?? String(localized: "友達")) as CKRecordValue
        record[CKSchema.Message.payload] = try await crypto.seal(
            JSONEncoder().encode(payload),
            with: key
        ) as CKRecordValue

        // 暗号化した本体は一時ファイルに書き, 保存後に消す.
        var encryptedMediaURL: URL?
        if case .media(let media) = outgoing.body {
            guard mediaStore.fileExists(at: media.fileURL) else {
                // アプリ再起動などで圧縮済みファイルを失った場合.
                throw AppError.underlying(String(localized: "送信する写真・動画が見つかりませんでした"))
            }
            let url = mediaStore.scratchURL(suffix: "enc")
            try await crypto.sealFile(at: media.fileURL, to: url, with: key)
            record[CKSchema.Message.mediaAsset] = CKAsset(fileURL: url)
            encryptedMediaURL = url

            if !media.thumbnailData.isEmpty {
                record[CKSchema.Message.thumbnailCipher] = try await crypto.seal(
                    media.thumbnailData,
                    with: key
                ) as CKRecordValue
            }
        }
        defer {
            if let encryptedMediaURL { mediaStore.remove(at: encryptedMediaURL) }
        }

        do {
            _ = try await saveWithRetry(record)
        } catch {
            // 同じ recordName は 1 つしか存在できないので, 「既にある」＝
            // 前回の試行が実は成功していた, とみなして重複送信を防ぐ.
            if CloudKitErrorMapping.isAlreadyExists(error) {
                Log.outbox.notice("message already stored; treating retry as success")
            } else {
                throw CloudKitErrorMapping.appError(from: error)
            }
        }

        var sent = outgoing.optimisticMessage()
        sent.deliveryState = .sent
        if case .media(let media) = outgoing.body {
            let attachment = MediaAttachment(
                id: media.attachmentID,
                kind: media.kind,
                remote: MediaReference(
                    recordName: outgoing.id.rawValue,
                    fieldName: CKSchema.Message.mediaAsset,
                    byteCount: media.byteCount
                ),
                localURL: media.fileURL,
                thumbnailData: media.thumbnailData,
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight,
                duration: media.duration,
                byteCount: media.byteCount
            )
            sent.content = sent.content.replacingAttachment(attachment)
        }
        return sent
    }

    /// 会話の参加者一覧. キャッシュがあればそれを使う.
    private func participants(of conversationID: ConversationID, me: UserID) async throws -> [UserID] {
        if let cached = cachedParticipants(for: conversationID) { return cached }
        let record = try await fetchWithRetry(CKRecord.ID(recordName: conversationID.rawValue))
        let raw = try CloudKitMapper.rawConversation(from: record, currentUserID: me)
        cacheConversationMetadata(participants: raw.participantIDs, owner: raw.ownerID, for: raw.id)
        return raw.participantIDs
    }

    // MARK: - 送信取り消し

    /// 送信を取り消す.
    ///
    /// ## レコードを消さずに上書きする理由
    /// レコードごと消すと, 既に受け取っている相手の画面からは黙って消えることに
    /// なり, 「あったはずのものが無い」状態だけが残る. レコードを残して
    /// 「取り消し済み」の印を書き込めば, どちらの画面にも同じ位置に
    /// 「送信を取り消しました」と出せる.
    ///
    /// 中身(暗号文・写真や動画の実体・サムネイル)はすべて取り除くので,
    /// サーバに残るのは「その時刻に取り消されたメッセージがある」という事実だけになる.
    ///
    /// Public Database ではレコードを更新できるのは作成者だけなので,
    /// 他人のメッセージを取り消すことは CloudKit 側で拒否される.
    /// ここでも念のため送信者を確認する.
    func unsendMessage(_ messageID: MessageID, in conversationID: ConversationID) async throws -> Message {
        let me = try await currentUserID()

        // 添付そのものは取りにいかない. 消すためだけに動画を丸ごと
        // ダウンロードするのは無駄なので, 判定に要るフィールドだけを取る.
        // (取得しなかった添付フィールドは, 後で明示的に nil を入れて消す)
        let recordID = CKRecord.ID(recordName: messageID.rawValue)
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(for: [recordID], desiredKeys: Self.unsendDesiredKeys)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
        guard let result = results[recordID], let record = try? result.get() else {
            throw AppError.underlying(String(localized: "メッセージが見つかりませんでした"))
        }
        let raw = try CloudKitMapper.rawMessage(from: record, currentUserID: me)

        guard raw.senderID == me else {
            throw AppError.underlying(String(localized: "自分が送ったメッセージだけ取り消せます"))
        }
        guard raw.conversationID == conversationID else {
            throw AppError.underlying(String(localized: "メッセージが見つかりませんでした"))
        }
        guard Date.now.timeIntervalSince(raw.sentAt) <= Message.unsendWindow else {
            throw AppError.underlying(String(localized: "送信から 24 時間を過ぎたメッセージは取り消せません"))
        }

        let key = try await conversationKey(for: conversationID)
        // 取り消し済みの印だけを入れた payload で上書きする.
        record[CKSchema.Message.payload] = try await crypto.seal(
            JSONEncoder().encode(MessagePayload(isUnsent: true)),
            with: key
        ) as CKRecordValue
        // 写真・動画とサムネイルの実体をサーバから取り除く.
        // 型を明示しているのは, CKRecord の添字が複数あり素の nil では
        // どの添字か決まらないため.
        let cleared: CKRecordValue? = nil
        record[CKSchema.Message.mediaAsset] = cleared
        record[CKSchema.Message.thumbnailCipher] = cleared

        let saved: CKRecord
        do {
            saved = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        return Message(
            id: messageID,
            conversationID: conversationID,
            senderID: me,
            content: .text(""),
            createdAt: raw.sentAt,
            deliveryState: .sent,
            isUnsent: true,
            modifiedAt: saved.modificationDate ?? .now,
            isRead: true
        )
    }

    func fetchMessageRevisions(in conversationID: ConversationID, since: Date) async throws -> [MessageID: Date] {
        let query = CKQuery(
            recordType: CKSchema.Message.recordType,
            predicate: NSPredicate(
                format: "%K == %@ AND %K >= %@",
                CKSchema.Message.conversation, reference(to: conversationID),
                CKSchema.Message.sentAt, since as NSDate
            )
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.Message.sentAt, ascending: false)]

        // desiredKeys を空にすると, 独自フィールドは取らずにシステム項目
        // (レコード ID と更新時刻)だけが返る. 本文もサムネイルも運ばないので軽い.
        let records = try await queryWithRetry(query, desiredKeys: [], limit: Self.revisionCheckLimit)

        var revisions: [MessageID: Date] = [:]
        for record in records {
            let id = MessageID(record.recordID.recordName)
            revisions[id] = record.modificationDate ?? record.creationDate ?? .distantPast
        }
        return revisions
    }

    func fetchMessages(ids: [MessageID], in conversationID: ConversationID) async throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        let me = try await currentUserID()
        let key = try await conversationKey(for: conversationID)

        let recordIDs = ids.map { CKRecord.ID(recordName: $0.rawValue) }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(for: recordIDs, desiredKeys: Self.messageDesiredKeys)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        let records = results.values.compactMap { try? $0.get() }
        return try await decodeMessages(records, key: key, me: me)
    }

    // MARK: - 既読

    func markRead(conversationID: ConversationID, upTo date: Date) async throws {
        let me = try await currentUserID()
        let recordID = CKRecord.ID(
            recordName: CKSchema.ReadState.recordName(conversation: conversationID, user: me)
        )

        // 既存があれば更新, 無ければ作成. 自分が作ったレコードなので必ず書き換えられる.
        let record: CKRecord
        do {
            record = try await fetchWithRetry(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: CKSchema.ReadState.recordType, recordID: recordID)
            record[CKSchema.ReadState.conversation] = reference(to: conversationID)
            record[CKSchema.ReadState.userID] = me.rawValue as CKRecordValue
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        // 既読位置は戻さない(古い端末が後から同期して未読が復活するのを防ぐ).
        if let existing = record[CKSchema.ReadState.lastReadAt] as? Date, existing >= date {
            return
        }
        record[CKSchema.ReadState.lastReadAt] = date as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    /// 自分以外の参加者の既読位置.
    ///
    /// クエリではなく recordName を組み立てた一括取得にしている.
    /// `ReadState` の recordName は `readstate-<会話>-<ユーザ>` と決まっているので
    /// 参加者一覧から機械的に求められ, インデックス(QUERYABLE)の有無に依存しない.
    /// 会話 1 件あたり 1 往復で済む点も, チャットを開いている間の定期更新に向く.
    func fetchReadReceipts(in conversationID: ConversationID) async throws -> [UserID: Date] {
        let me = try await currentUserID()
        let others = try await participants(of: conversationID, me: me).filter { $0 != me }
        guard !others.isEmpty else { return [:] }

        let recordIDs = others.map {
            CKRecord.ID(recordName: CKSchema.ReadState.recordName(conversation: conversationID, user: $0))
        }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(for: recordIDs)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        var receipts: [UserID: Date] = [:]
        for result in results.values {
            // まだ一度も読んでいない相手のレコードは存在しない(unknownItem). 既読なしとして扱う.
            guard case .success(let record) = result,
                  let rawUser = record[CKSchema.ReadState.userID] as? String,
                  let lastReadAt = record[CKSchema.ReadState.lastReadAt] as? Date
            else { continue }
            // 他人が代わりに書いた「既読」を信用しない. 申告された userID と
            // サーバが押印した作成者が一致するものだけ採用する.
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == rawUser else {
                Log.backend.notice("ignoring read state with mismatched creator")
                continue
            }
            receipts[UserID(rawUser)] = lastReadAt
        }
        return receipts
    }

    // MARK: - メディア取得

    func downloadMedia(
        _ mediaReference: MediaReference,
        kind: MediaKind,
        conversationID: ConversationID
    ) async throws -> URL {
        let destination = mediaStore.cachedURL(for: mediaReference, kind: kind)
        if mediaStore.fileExists(at: destination) { return destination }

        let key = try await conversationKey(for: conversationID)
        let record: CKRecord
        do {
            record = try await fetchRecordWithAsset(
                recordName: mediaReference.recordName,
                fieldName: mediaReference.fieldName
            )
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        guard let asset = record[mediaReference.fieldName] as? CKAsset,
              let sourceURL = asset.fileURL else {
            throw AppError.underlying(String(localized: "写真・動画のデータが見つかりませんでした"))
        }

        try await crypto.openFile(at: sourceURL, to: destination, with: key)
        return destination
    }

    func downloadThumbnail(_ mediaReference: MediaReference, conversationID: ConversationID) async throws -> Data {
        let key = try await conversationKey(for: conversationID)
        let record = try await fetchRecordWithAsset(
            recordName: mediaReference.recordName,
            fieldName: CKSchema.Message.thumbnailCipher
        )
        guard let cipher = record[CKSchema.Message.thumbnailCipher] as? Data else {
            throw AppError.underlying(String(localized: "サムネイルが見つかりませんでした"))
        }
        return try await crypto.open(cipher, with: key)
    }

    private func fetchRecordWithAsset(recordName: String, fieldName: String) async throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName)
        let results = try await database.records(for: [recordID], desiredKeys: [fieldName])
        guard let result = results[recordID] else {
            throw AppError.underlying(String(localized: "データが見つかりませんでした"))
        }
        switch result {
        case .success(let record):
            return record
        case .failure(let error):
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    // MARK: - 定数

    /// チャット一覧を組み立てるときに遡る期間.
    private static let activityWindow: TimeInterval = 30 * 24 * 60 * 60

    /// 一覧用にまとめて取るメッセージの上限.
    private static let activityFetchLimit = 500

    /// 書き換え(送信取り消し)の確認でさかのぼるメッセージ数の上限.
    private static let revisionCheckLimit = 300

    /// 送信取り消しのときに読み出すフィールド.
    ///
    /// `mediaAsset` と `thumbnailCipher` は入れない — 消すためだけに
    /// 本体をダウンロードしないため. 代わりに保存時へ明示的に nil を入れる.
    /// 逆に, それ以外のフィールドはすべて読んでおく(読まずに保存すると
    /// 消えてしまう可能性があるため).
    private static let unsendDesiredKeys: [CKRecord.FieldKey] = [
        CKSchema.Message.conversation,
        CKSchema.Message.senderID,
        CKSchema.Message.sentAt,
        CKSchema.Message.payload,
        CKSchema.Message.participantIDs,
        CKSchema.Message.senderDisplayName
    ]

    /// メッセージ取得時に要求するフィールド.
    /// `mediaAsset` は含めない — 本体は表示のためにタップされたときに初めて取る.
    private static let messageDesiredKeys: [CKRecord.FieldKey] = [
        CKSchema.Message.conversation,
        CKSchema.Message.senderID,
        CKSchema.Message.sentAt,
        CKSchema.Message.payload,
        CKSchema.Message.thumbnailCipher
    ]
}
