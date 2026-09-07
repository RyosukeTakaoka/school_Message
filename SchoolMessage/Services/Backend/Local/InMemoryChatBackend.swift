import Foundation

/// メモリ上だけで完結するバックエンド.
///
/// - SwiftUI プレビューと UI テストで, iCloud アカウントもネットワークも無しに
///   画面を動かすために使う.
/// - `ChatBackend` を差し替え可能にしておく価値がここで回収される.
///
/// 暗号化は行わない(端末外に出ないため). 本番経路のコードには影響しない.
actor InMemoryChatBackend: ChatBackend {

    private let eventHub = BackendEventHub()

    private var me: UserProfile
    private var profiles: [UserID: UserProfile] = [:]
    private var friendIDs: Set<UserID> = []
    private var conversations: [ConversationID: Conversation] = [:]
    private var messages: [ConversationID: [Message]] = [:]
    private var readStates: [ConversationID: Date] = [:]
    /// 会話 → (参加者 → 既読位置). デモでも「既読」表示を確認できるようにする.
    private var readReceipts: [ConversationID: [UserID: Date]] = [:]

    init(seeded: Bool = true) {
        let owner = UserProfile(
            id: UserID("me"),
            handle: "me_2a",
            displayName: "自分",
            publicKeyData: Data(repeating: 1, count: 32)
        )
        self.me = owner
        self.profiles[owner.id] = owner
        if seeded { seed() }
    }

    private func seed() {
        let tanaka = UserProfile(id: UserID("tanaka"), handle: "tanaka", displayName: "田中", publicKeyData: Data(repeating: 2, count: 32))
        let sato = UserProfile(id: UserID("sato"), handle: "sato", displayName: "佐藤", publicKeyData: Data(repeating: 3, count: 32))
        let yamada = UserProfile(id: UserID("yamada"), handle: "yamada", displayName: "山田", publicKeyData: Data(repeating: 4, count: 32))
        for profile in [tanaka, sato, yamada] {
            profiles[profile.id] = profile
            friendIDs.insert(profile.id)
        }

        let direct = Conversation(
            id: Conversation.directConversationID(me.id, tanaka.id),
            kind: .direct,
            participantIDs: [me.id, tanaka.id],
            ownerID: me.id,
            createdAt: .now.addingTimeInterval(-7200)
        )
        let group = Conversation(
            id: ConversationID("group-2a"),
            kind: .group,
            title: "2年A組",
            participantIDs: [me.id, tanaka.id, sato.id, yamada.id],
            ownerID: yamada.id,
            createdAt: .now.addingTimeInterval(-86_400)
        )
        conversations[direct.id] = direct
        conversations[group.id] = group

        let lunchQuestion = Message(
            conversationID: direct.id,
            senderID: tanaka.id,
            content: .text("今日どこで昼食べる？"),
            createdAt: .now.addingTimeInterval(-600)
        )
        messages[direct.id] = [
            lunchQuestion,
            Message(
                conversationID: direct.id,
                senderID: me.id,
                content: .text("食堂！"),
                createdAt: .now.addingTimeInterval(-540),
                replyTo: ReplyReference(replyingTo: lunchQuestion)
            )
        ]
        messages[group.id] = [
            Message(conversationID: group.id, senderID: yamada.id, content: .text("明日の体育祭どうする？"), createdAt: .now.addingTimeInterval(-300))
        ]

        // 自分が送った「食堂！」には既読が付いている状態にしておく.
        readReceipts[direct.id] = [tanaka.id: .now.addingTimeInterval(-500)]
        readReceipts[group.id] = [
            tanaka.id: .now.addingTimeInterval(-120),
            sato.id: .now.addingTimeInterval(-60)
        ]
    }

    // MARK: - アカウント / プロフィール

    func accountStatus() async throws -> BackendAccountStatus { .available(me.id) }

    func fetchMyProfile() async throws -> UserProfile? { me }

    func registerProfile(handle: String, displayName: String, avatarData: Data?) async throws -> UserProfile {
        me.handle = try UserProfile.validateHandle(handle)
        me.displayName = try UserProfile.validateDisplayName(displayName)
        me.avatarData = avatarData
        profiles[me.id] = me
        return me
    }

    func updateProfile(displayName: String?, avatarData: Data?) async throws -> UserProfile {
        if let displayName { me.displayName = try UserProfile.validateDisplayName(displayName) }
        if let avatarData { me.avatarData = avatarData }
        profiles[me.id] = me
        return me
    }

    func searchUsers(matching query: String) async throws -> [UserProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return profiles.values
            .filter { $0.id != me.id }
            .filter { $0.handle.contains(needle) || $0.displayName.lowercased().contains(needle) }
            .sorted { $0.displayName < $1.displayName }
    }

    func fetchProfiles(ids: [UserID]) async throws -> [UserProfile] {
        ids.compactMap { profiles[$0] }
    }

    // MARK: - 友達

    func fetchFriends() async throws -> [UserProfile] {
        friendIDs.compactMap { profiles[$0] }.sorted { $0.displayName < $1.displayName }
    }

    func addFriend(_ userID: UserID) async throws {
        friendIDs.insert(userID)
        eventHub.emit(.profilesChanged)
    }

    func removeFriend(_ userID: UserID) async throws {
        friendIDs.remove(userID)
        eventHub.emit(.profilesChanged)
    }

    // MARK: - 会話

    func fetchConversations() async throws -> [Conversation] {
        conversations.values.map { conversation in
            var copy = conversation
            let history = messages[conversation.id] ?? []
            let lastReadAt = readStates[conversation.id] ?? .distantPast
            copy.lastReadAt = lastReadAt
            copy.unreadCount = history.filter { $0.createdAt > lastReadAt && $0.senderID != me.id }.count
            copy.readReceipts = readReceipts[conversation.id] ?? [:]
            if let last = history.last {
                copy.lastMessage = MessageSummary(
                    senderID: last.senderID,
                    preview: last.isUnsent
                        ? String(localized: "送信を取り消しました")
                        : last.content.previewText,
                    createdAt: last.createdAt
                )
            }
            return copy
        }
        .sorted { $0.sortDate > $1.sortDate }
    }

    func openDirectConversation(with userID: UserID) async throws -> Conversation {
        let id = Conversation.directConversationID(me.id, userID)
        if let existing = conversations[id] { return existing }
        let conversation = Conversation(
            id: id,
            kind: .direct,
            participantIDs: [me.id, userID],
            ownerID: me.id
        )
        conversations[id] = conversation
        eventHub.emit(.conversationsChanged)
        return conversation
    }

    func createGroup(_ draft: GroupDraft) async throws -> Conversation {
        var members = Set(draft.memberIDs)
        members.insert(me.id)
        let conversation = Conversation(
            kind: .group,
            title: draft.name,
            imageData: draft.imageData,
            participantIDs: Array(members),
            ownerID: me.id
        )
        conversations[conversation.id] = conversation
        eventHub.emit(.conversationsChanged)
        return conversation
    }

    func addMembers(_ userIDs: [UserID], to conversationID: ConversationID) async throws -> Conversation {
        guard var conversation = conversations[conversationID] else { throw AppError.notAParticipant }
        var members = Set(conversation.participantIDs)
        members.formUnion(userIDs)
        conversation.participantIDs = Array(members)
        conversations[conversationID] = conversation
        eventHub.emit(.conversationsChanged)
        return conversation
    }

    func leaveConversation(_ conversationID: ConversationID) async throws {
        conversations.removeValue(forKey: conversationID)
        messages.removeValue(forKey: conversationID)
        eventHub.emit(.conversationsChanged)
    }

    // MARK: - メッセージ

    func fetchMessages(in conversationID: ConversationID, before: Date?, limit: Int) async throws -> [Message] {
        let history = messages[conversationID] ?? []
        let filtered = before.map { cutoff in history.filter { $0.createdAt < cutoff } } ?? history
        return Array(filtered.suffix(limit))
    }

    func fetchNewMessages(in conversationID: ConversationID, after date: Date) async throws -> [Message] {
        (messages[conversationID] ?? []).filter { $0.createdAt > date }
    }

    func send(_ outgoing: OutgoingMessage) async throws -> Message {
        var message = outgoing.optimisticMessage()
        message.deliveryState = .sent
        messages[outgoing.conversationID, default: []].append(message)
        eventHub.emit(.messagesChanged(outgoing.conversationID))
        return message
    }

    func unsendMessage(_ messageID: MessageID, in conversationID: ConversationID) async throws -> Message {
        guard var history = messages[conversationID],
              let index = history.firstIndex(where: { $0.id == messageID })
        else {
            throw AppError.underlying("メッセージが見つかりませんでした")
        }
        guard history[index].senderID == me.id else {
            throw AppError.underlying("自分が送ったメッセージだけ取り消せます")
        }

        var updated = history[index]
        updated.content = .text("")
        updated.replyTo = nil
        updated.isUnsent = true
        updated.modifiedAt = .now
        history[index] = updated
        messages[conversationID] = history

        eventHub.emit(.messagesChanged(conversationID))
        return updated
    }

    func fetchMessageRevisions(in conversationID: ConversationID, since: Date) async throws -> [MessageID: Date] {
        let history = messages[conversationID] ?? []
        return history
            .filter { $0.createdAt >= since }
            .reduce(into: [:]) { result, message in
                result[message.id] = message.modifiedAt ?? message.createdAt
            }
    }

    func fetchMessages(ids: [MessageID], in conversationID: ConversationID) async throws -> [Message] {
        let wanted = Set(ids)
        return (messages[conversationID] ?? []).filter { wanted.contains($0.id) }
    }

    func markRead(conversationID: ConversationID, upTo date: Date) async throws {
        let current = readStates[conversationID] ?? .distantPast
        readStates[conversationID] = max(current, date)
    }

    func fetchReadReceipts(in conversationID: ConversationID) async throws -> [UserID: Date] {
        readReceipts[conversationID] ?? [:]
    }

    // MARK: - メディア

    func downloadMedia(_ reference: MediaReference, kind: MediaKind, conversationID: ConversationID) async throws -> URL {
        throw AppError.underlying("プレビューではメディアを取得できません")
    }

    func downloadThumbnail(_ reference: MediaReference, conversationID: ConversationID) async throws -> Data {
        throw AppError.underlying("プレビューではメディアを取得できません")
    }

    // MARK: - 変更通知

    nonisolated func events() -> AsyncStream<BackendEvent> { eventHub.stream() }

    func configureSubscriptions() async throws {}

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async {}
}
