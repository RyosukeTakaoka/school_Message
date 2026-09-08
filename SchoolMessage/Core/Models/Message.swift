import Foundation

/// メッセージの中身.
///
/// 要件では `type` / `text` / `mediaAsset` を並べたフラットな構造が例示されていたが,
/// その形だと「type == .text なのに mediaAsset が入っている」「type == .image なのに
/// mediaAsset が nil」といった不正な状態が型の上では作れてしまい, 描画側が毎回
/// `if let` と `switch` の二重チェックを強いられる.
///
/// associated value 付きの enum にすることで
/// - 不正な組み合わせを表現できなくする
/// - View 側は `switch` ひとつで網羅でき, ケース追加時にコンパイラが漏れを検出する
/// という利点が得られるため, こちらを採用する.
enum MessageContent: Hashable, Sendable {
    case text(String)
    case image(MediaAttachment)
    case video(MediaAttachment)
    /// チャットに付随する対戦(オセロ)の 1 手.
    case game(GameSnapshot)

    /// 添付を持つケースの共通アクセサ.
    var attachment: MediaAttachment? {
        switch self {
        case .text, .game: nil
        case .image(let attachment), .video(let attachment): attachment
        }
    }

    /// 対戦のケースの共通アクセサ.
    var game: GameSnapshot? {
        if case .game(let snapshot) = self { return snapshot }
        return nil
    }

    /// 添付を差し替えた新しい content を返す(アップロード完了時の更新に使う).
    func replacingAttachment(_ attachment: MediaAttachment) -> MessageContent {
        switch self {
        case .text, .game: self
        case .image: .image(attachment)
        case .video: .video(attachment)
        }
    }

    /// チャット一覧やプッシュ通知に出す 1 行プレビュー.
    var previewText: String {
        switch self {
        case .text(let body): body
        case .image: String(localized: "写真")
        case .video: String(localized: "動画")
        case .game(let snapshot): snapshot.previewText
        }
    }
}

/// 返信先の要約.
///
/// 元メッセージの本文は暗号化されて別レコードにあるため, 参照だけを持つと
/// 引用を出すたびに元レコードの取得と復号が必要になる. 返信を作った時点で
/// 復号済みの抜粋をここに複製しておくことで,
/// - 引用の表示に追加の通信が要らない
/// - 元メッセージが履歴の彼方(未取得のページ)にあっても引用が壊れない
/// という 2 点を満たす. 抜粋も本文と同じ会話鍵で暗号化されるため,
/// 会話の外に平文が漏れることはない.
struct ReplyReference: Hashable, Sendable, Codable {

    /// 返信先のメッセージ. タップして元メッセージへ移動するのに使う.
    var messageID: MessageID
    var senderID: UserID
    /// 引用として表示する抜粋.
    var preview: String

    /// 引用の長さ上限. 元が長文でも吹き出しが引用で埋まらないようにする.
    static let previewMaxLength = 80

    init(messageID: MessageID, senderID: UserID, preview: String) {
        self.messageID = messageID
        self.senderID = senderID
        self.preview = String(preview.prefix(Self.previewMaxLength))
    }

    init(replyingTo message: Message) {
        self.init(
            messageID: message.id,
            senderID: message.senderID,
            preview: message.content.previewText
        )
    }
}

/// 送信状態. 「送信中のまま無言で止まる」状態を作らないために明示的に持つ.
enum MessageDeliveryState: Hashable, Sendable {
    /// ローカルには存在するがまだ送信していない / 送信中.
    case sending
    /// サーバに保存済み.
    case sent
    /// 送信に失敗した. 理由はユーザに提示し, 再送できるようにする.
    case failed(reason: String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isPending: Bool {
        self == .sending
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// 1 件のメッセージ.
struct Message: Identifiable, Hashable, Sendable {

    /// クライアント側で採番する. リトライ時も同じ ID を使うことで重複送信を防ぐ.
    let id: MessageID
    let conversationID: ConversationID

    /// 送信者. CloudKit から取得したものは `creatorUserRecordID` と一致することを
    /// 検証済みのものだけがここに入る(なりすまし対策).
    let senderID: UserID

    var content: MessageContent

    /// 送信者の端末での作成時刻. 表示順の基準.
    let createdAt: Date

    var deliveryState: MessageDeliveryState

    /// 返信先(引用). 通常のメッセージでは nil.
    var replyTo: ReplyReference?

    /// 送信が取り消されたか.
    ///
    /// 取り消してもレコード自体は残し, 中身(本文・写真・動画)だけを消す.
    /// 吹き出しの場所に「送信を取り消しました」と表示され, 痕跡が残る.
    /// 何も残さず消すと, 受け取った側には「見た気がするが無くなっている」
    /// という状態だけが残り, かえって混乱と不信を招くため.
    var isUnsent: Bool

    /// サーバ上で最後に書き換えられた時刻.
    ///
    /// 取り消しは既存レコードの書き換えとして届くので, 差分取得
    /// (新しい `sentAt` のものだけを取る)では気付けない. この値を
    /// サーバ側と突き合わせて, 変化したものだけを取り直す.
    var modifiedAt: Date?

    /// この端末のユーザから見て既読か.
    ///
    /// 実データは会話ごとの `lastReadAt` 1 レコードで管理し, ここには導出結果を入れる.
    /// メッセージ 1 件ごとに既読フラグを書き戻すと, チャットを開くたびに
    /// 未読件数ぶんの書き込みが発生して CloudKit のレート制限に当たりやすいため.
    var isRead: Bool

    init(
        id: MessageID = .generate(),
        conversationID: ConversationID,
        senderID: UserID,
        content: MessageContent,
        createdAt: Date = .now,
        deliveryState: MessageDeliveryState = .sent,
        replyTo: ReplyReference? = nil,
        isUnsent: Bool = false,
        modifiedAt: Date? = nil,
        isRead: Bool = true
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.replyTo = replyTo
        self.isUnsent = isUnsent
        self.modifiedAt = modifiedAt
        self.isRead = isRead
    }

    /// この時間内なら送信を取り消せる.
    ///
    /// 期限を設けるのは, 何日も前のやり取りを後から書き換えられると
    /// 会話の記録としての信頼性が失われるため. LINE 等と同じ考え方で 24 時間とする.
    static let unsendWindow: TimeInterval = 24 * 60 * 60

    /// 自分がいま取り消せるメッセージか.
    func canUnsend(by userID: UserID?, now: Date = .now) -> Bool {
        guard let userID, senderID == userID else { return false }
        guard deliveryState == .sent, !isUnsent else { return false }
        return now.timeIntervalSince(createdAt) <= Self.unsendWindow
    }

    func isSent(by userID: UserID) -> Bool {
        senderID == userID
    }
}

/// 暗号化して保存するメッセージ本文.
///
/// CloudKit の Public Database には行単位のアクセス制御がないため,
/// 本文とメディアのメタデータはこの構造体にまとめて会話鍵で封緘し,
/// レコードには暗号文だけを置く.
struct MessagePayload: Hashable, Sendable, Codable {
    var text: String?
    var media: MediaMetadata?

    /// 返信先(引用).
    ///
    /// CloudKit のフィールドではなく暗号化ペイロードの中に入れているのは,
    /// - 引用文が平文でサーバに残らない
    /// - レコードタイプの変更が要らない(Production へのスキーマ再デプロイが不要)
    /// という 2 点のため. 古い版のアプリが読んでも, 未知のキーとして無視される.
    var replyTo: ReplyReference?

    /// 送信取り消し済みか.
    ///
    /// 取り消すと, このフラグだけを立てた payload で元のレコードを上書きし,
    /// 本文・メディアのメタデータは持たせない. 平文のフィールドを増やさないので
    /// CloudKit のスキーマ変更は不要で, かつ「取り消した」事実自体も
    /// 会話の参加者以外には読めない.
    var isUnsent: Bool?

    /// 対戦の状態. 平文のフィールドを増やさずに済ませるため, ここに入れる.
    var game: GameSnapshot?

    init(
        text: String? = nil,
        media: MediaMetadata? = nil,
        replyTo: ReplyReference? = nil,
        isUnsent: Bool? = nil,
        game: GameSnapshot? = nil
    ) {
        self.text = text
        self.media = media
        self.replyTo = replyTo
        self.isUnsent = isUnsent
        self.game = game
    }

    init(content: MessageContent, replyTo: ReplyReference? = nil) {
        self.replyTo = replyTo
        switch content {
        case .game(let snapshot):
            self.text = nil
            self.media = nil
            self.game = snapshot
        case .text(let body):
            self.text = body
            self.media = nil
        case .image(let attachment), .video(let attachment):
            self.text = nil
            self.media = MediaMetadata(
                attachmentID: attachment.id,
                kind: attachment.kind,
                pixelWidth: attachment.pixelWidth,
                pixelHeight: attachment.pixelHeight,
                duration: attachment.duration,
                byteCount: attachment.byteCount
            )
        }
    }
}
