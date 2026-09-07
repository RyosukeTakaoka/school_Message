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

    /// 添付を持つケースの共通アクセサ.
    var attachment: MediaAttachment? {
        switch self {
        case .text: nil
        case .image(let attachment), .video(let attachment): attachment
        }
    }

    /// 添付を差し替えた新しい content を返す(アップロード完了時の更新に使う).
    func replacingAttachment(_ attachment: MediaAttachment) -> MessageContent {
        switch self {
        case .text: self
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
        isRead: Bool = true
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.replyTo = replyTo
        self.isRead = isRead
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

    init(text: String? = nil, media: MediaMetadata? = nil, replyTo: ReplyReference? = nil) {
        self.text = text
        self.media = media
        self.replyTo = replyTo
    }

    init(content: MessageContent, replyTo: ReplyReference? = nil) {
        self.replyTo = replyTo
        switch content {
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
