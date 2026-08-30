import Foundation

/// iCloud アカウントの状態.
enum BackendAccountStatus: Sendable, Equatable {
    /// 利用可能. プロフィール登録済みかは別途確認する.
    case available(UserID)
    case noAccount
    case restricted
    case temporarilyUnavailable
}

/// バックエンドから届く変更通知.
///
/// プッシュ通知とポーリングのどちらで気付いたかを UI 側が意識せずに済むよう,
/// ひとつのストリームに正規化する.
enum BackendEvent: Sendable, Equatable {
    /// 指定の会話に新しいメッセージがある可能性がある.
    case messagesChanged(ConversationID)
    /// 会話の作成・メンバー変更・退出があった.
    case conversationsChanged
    /// 自分または友達のプロフィールが変わった.
    case profilesChanged
}

/// グループ作成時のパラメータ.
struct GroupDraft: Sendable {
    var name: String
    var imageData: Data?
    var memberIDs: [UserID]
}

/// チャット機能のバックエンド抽象.
///
/// CloudKit 実装とインメモリ実装(プレビュー / UI テスト用)を差し替えられるようにする.
/// これがあることで, 将来 CloudKit の制約に当たった場合でも UI とドメイン層を
/// 触らずにバックエンドだけを置き換えられる.
protocol ChatBackend: Sendable {

    // MARK: アカウント / プロフィール

    func accountStatus() async throws -> BackendAccountStatus

    /// 自分のプロフィール. 未登録なら nil.
    func fetchMyProfile() async throws -> UserProfile?

    /// 初回登録. 公開鍵の登録もここで行う.
    func registerProfile(handle: String, displayName: String, avatarData: Data?) async throws -> UserProfile

    func updateProfile(displayName: String?, avatarData: Data?) async throws -> UserProfile

    /// ハンドルまたは表示名の前方一致でユーザを探す.
    func searchUsers(matching query: String) async throws -> [UserProfile]

    func fetchProfiles(ids: [UserID]) async throws -> [UserProfile]

    // MARK: 友達

    func fetchFriends() async throws -> [UserProfile]
    func addFriend(_ userID: UserID) async throws
    func removeFriend(_ userID: UserID) async throws

    // MARK: 会話

    func fetchConversations() async throws -> [Conversation]

    /// 相手との 1 対 1 会話を取得, 無ければ作る.
    func openDirectConversation(with userID: UserID) async throws -> Conversation

    func createGroup(_ draft: GroupDraft) async throws -> Conversation

    func addMembers(_ userIDs: [UserID], to conversationID: ConversationID) async throws -> Conversation

    func leaveConversation(_ conversationID: ConversationID) async throws

    // MARK: メッセージ

    /// `before` より前のメッセージを新しい順に最大 `limit` 件取得する.
    /// `before` が nil なら最新から.
    func fetchMessages(
        in conversationID: ConversationID,
        before: Date?,
        limit: Int
    ) async throws -> [Message]

    /// `after` より後のメッセージ(差分取得).
    func fetchNewMessages(in conversationID: ConversationID, after: Date) async throws -> [Message]

    /// 送信. 失敗時は `AppError` を投げる. 同じ `OutgoingMessage.id` での再送は
    /// サーバ側で同じレコードに上書きされ, 重複しない.
    func send(_ outgoing: OutgoingMessage) async throws -> Message

    /// 既読位置を保存する.
    func markRead(conversationID: ConversationID, upTo date: Date) async throws

    // MARK: メディア

    /// 添付の本体を復号してローカルにダウンロードし, その URL を返す.
    func downloadMedia(_ reference: MediaReference, kind: MediaKind, conversationID: ConversationID) async throws -> URL

    /// サムネイルを復号して返す.
    func downloadThumbnail(_ reference: MediaReference, conversationID: ConversationID) async throws -> Data

    // MARK: 変更通知

    /// 変更イベントのストリーム. 複数回呼ばれても構わない.
    func events() -> AsyncStream<BackendEvent>

    /// プッシュ購読を用意する(冪等).
    func configureSubscriptions() async throws

    /// リモート通知の payload を受けて, 対応するイベントを流す.
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async
}
