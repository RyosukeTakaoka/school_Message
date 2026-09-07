import Foundation

/// 会話の種類.
enum ConversationKind: String, Hashable, Sendable, Codable {
    case direct
    case group
}

/// チャット一覧に出す最終メッセージの要約.
/// 一覧を出すためだけに全メッセージを取りに行かなくて済むように, 会話側に持たせる.
struct MessageSummary: Hashable, Sendable {
    var senderID: UserID
    var preview: String
    var createdAt: Date
}

/// 1 対 1 またはグループの会話.
struct Conversation: Identifiable, Hashable, Sendable {

    let id: ConversationID
    let kind: ConversationKind

    /// グループ名. 1 対 1 では nil で, 表示名は相手のプロフィールから作る.
    var title: String?

    /// グループ画像(会話鍵で暗号化して保存し, 取得時に復号済みのものが入る).
    var imageData: Data?

    /// 参加者(自分を含む). ここに載っていないユーザには会話鍵が配られない.
    var participantIDs: [UserID]

    /// 作成者. グループ画像や名前の変更を許す判断材料に使う.
    let ownerID: UserID

    let createdAt: Date

    /// 一覧の並べ替えと表示に使う最終メッセージ.
    var lastMessage: MessageSummary?

    /// この端末のユーザがこの会話をどこまで読んだか.
    var lastReadAt: Date

    /// 未読件数(サーバから取得したメッセージから導出).
    var unreadCount: Int

    /// 自分以外の参加者がどこまで読んだか.
    ///
    /// 「自分が送ったメッセージに既読が付いたか」を出すために使う.
    /// メッセージ 1 件ごとの既読フラグではなく参加者ごとの到達点を持つのは,
    /// 既読化の書き込みを会話あたり 1 レコードに抑えるため(`ReadState`).
    var readReceipts: [UserID: Date]

    init(
        id: ConversationID = .generate(),
        kind: ConversationKind,
        title: String? = nil,
        imageData: Data? = nil,
        participantIDs: [UserID],
        ownerID: UserID,
        createdAt: Date = .now,
        lastMessage: MessageSummary? = nil,
        lastReadAt: Date = .distantPast,
        unreadCount: Int = 0,
        readReceipts: [UserID: Date] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.imageData = imageData
        self.participantIDs = participantIDs
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.lastMessage = lastMessage
        self.lastReadAt = lastReadAt
        self.unreadCount = unreadCount
        self.readReceipts = readReceipts
    }

    /// `date` の時点までを読んだ, 自分以外の参加者の人数.
    ///
    /// 1 対 1 では 0 か 1 になり, そのまま「既読」の有無として使える.
    /// グループでは「既読 3」のように人数を出す.
    func readCount(upTo date: Date, excluding me: UserID) -> Int {
        readReceipts.reduce(into: 0) { total, entry in
            let (userID, lastReadAt) = entry
            // 退出した人の記録が残っていても数えない.
            guard userID != me, participantIDs.contains(userID) else { return }
            if lastReadAt >= date { total += 1 }
        }
    }

    /// 一覧の並び順に使う時刻. メッセージがまだ無い会話は作成時刻を使う.
    var sortDate: Date {
        lastMessage?.createdAt ?? createdAt
    }

    func contains(_ userID: UserID) -> Bool {
        participantIDs.contains(userID)
    }

    /// 1 対 1 会話における相手の ID.
    func counterpartID(for me: UserID) -> UserID? {
        guard kind == .direct else { return nil }
        return participantIDs.first { $0 != me }
    }

    /// 1 対 1 会話の決定的な ID.
    ///
    /// 両者が同時に「チャットを開始」しても同じ ID になるようにして,
    /// 同じ相手との会話が二重に作られるのを防ぐ.
    static func directConversationID(_ a: UserID, _ b: UserID) -> ConversationID {
        let sorted = [a.rawValue, b.rawValue].sorted()
        return ConversationID("direct-\(sorted[0])-\(sorted[1])")
    }
}
