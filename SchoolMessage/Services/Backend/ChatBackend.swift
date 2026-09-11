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

    /// 送信を取り消す.
    ///
    /// レコードは残したまま本文・写真・動画をサーバから消し, 「取り消し済み」の
    /// 印だけを残す. 自分が送ったメッセージにしか行えない.
    func unsendMessage(_ messageID: MessageID, in conversationID: ConversationID) async throws -> Message

    /// 取得済みメッセージがその後書き換えられていないかを確かめるための一覧.
    ///
    /// 送信取り消しは既存レコードの書き換えとして届くため, `sentAt` を見る
    /// 差分取得では気付けない. ID と更新時刻だけを軽く引いて突き合わせる.
    /// - Returns: メッセージ ID → サーバ上の最終更新時刻.
    func fetchMessageRevisions(in conversationID: ConversationID, since: Date) async throws -> [MessageID: Date]

    /// 指定した ID のメッセージを取り直す(書き換えを検出したときに使う).
    func fetchMessages(ids: [MessageID], in conversationID: ConversationID) async throws -> [Message]

    /// 既読位置を保存する.
    func markRead(conversationID: ConversationID, upTo date: Date) async throws

    /// 自分以外の参加者の既読位置. 「自分の送信に既読が付いたか」の表示に使う.
    func fetchReadReceipts(in conversationID: ConversationID) async throws -> [UserID: Date]

    // MARK: リアクション

    /// 会話内の全メッセージへの絵文字リアクション.
    ///
    /// 新着メッセージの取得(`refreshMessages`)のたびに呼び直され, 差分ではなく
    /// 会話ぶん丸ごとを返す想定. リアクションは件数も更新頻度も本文よりずっと
    /// 少ないため, 差分管理の複雑さに見合わない.
    func fetchReactions(in conversationID: ConversationID) async throws -> [MessageReaction]

    /// 自分のリアクションを設定する. `emoji` が `nil` なら外す.
    ///
    /// 1 人 1 メッセージにつき 1 個までなので, 既にある自分のリアクションは
    /// 呼ぶたびに置き換わる(新規追加・絵文字の変更・削除のすべてをこの 1 本で担う).
    func setReaction(_ emoji: String?, on messageID: MessageID, in conversationID: ConversationID) async throws

    // MARK: 掲示板

    /// スレッド一覧(最後の書き込みが新しい順).
    func fetchBoardThreads() async throws -> [BoardThread]

    /// スレッドを立てる. 最初の書き込みも同時に行う. `image` があれば添付する.
    func createBoardThread(title: String, body: String, image: OutgoingMessage.LocalMedia?) async throws -> BoardThread

    /// スレッドの書き込み(古い順).
    func fetchBoardPosts(in threadID: ThreadID) async throws -> [BoardPost]

    /// スレッドに書き込む. `image` があれば添付する
    /// (掲示板は暗号化しないため, 写真もチャットとは別の平文のフィールドに保存される).
    func createBoardPost(in threadID: ThreadID, body: String, image: OutgoingMessage.LocalMedia?) async throws -> BoardPost

    /// 掲示板の写真本体をダウンロードする. 暗号化していないため復号は不要.
    func downloadBoardImage(_ reference: MediaReference) async throws -> URL

    /// 掲示板への新着通知を受け取れるようにする(冪等). 通知の設定でオンにしたときに呼ぶ.
    func configureBoardSubscription() async throws

    /// 掲示板への新着通知を止める. 通知の設定でオフにしたときに呼ぶ.
    func removeBoardSubscription() async throws

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

    /// サーバ上に実際に存在する購読の ID.
    ///
    /// 「購読の作成に成功した」ことと「サーバに購読が残っている」ことは別なので,
    /// 通知が来ないときの切り分けのために実際の状態を問い合わせられるようにする.
    func fetchSubscriptionIDs() async throws -> [String]

    /// リモート通知の payload を受けて, 対応するイベントを流す.
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async
}
