import Foundation

/// これから送信するメッセージ.
///
/// `Message` と分けているのは, 送信前は「ローカルファイルの場所」を持ち,
/// 送信後は「リモート参照」を持つという別物だから. 同じ型に両方を持たせると
/// どちらが有効なのか呼び出し側で判断できなくなる.
struct OutgoingMessage: Identifiable, Hashable, Sendable, Codable {

    enum Body: Hashable, Sendable, Codable {
        case text(String)
        /// 圧縮済みファイルのローカル位置とメタデータ.
        case media(LocalMedia)
    }

    /// 圧縮・サムネイル生成まで済ませたローカルメディア.
    struct LocalMedia: Hashable, Sendable, Codable {
        var attachmentID: AttachmentID
        var kind: MediaKind
        /// 圧縮済み本体. アプリの Application Support 配下に置き,
        /// アプリが強制終了しても残るようにする(再開可能にするため).
        var fileURL: URL
        var thumbnailData: Data
        var pixelWidth: Int
        var pixelHeight: Int
        var duration: TimeInterval?
        var byteCount: Int

        var metadata: MediaMetadata {
            MediaMetadata(
                attachmentID: attachmentID,
                kind: kind,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: duration,
                byteCount: byteCount
            )
        }
    }

    /// 送信前に確定させる ID. リトライしても変わらないので, サーバ側で
    /// 同じ recordName への保存となり重複が生まれない.
    let id: MessageID
    let conversationID: ConversationID
    let senderID: UserID
    var body: Body
    let createdAt: Date

    /// 返信先(引用). Optional なので, この項目が無い古いキューの JSON も読める.
    var replyTo: ReplyReference?

    /// これまでの送信試行回数. バックオフの計算に使う.
    var attemptCount: Int

    /// 次に自動再送してよい時刻. `nil` なら即時対象.
    /// 一時的な失敗のあと即座に叩き直すとサーバの混雑を悪化させるため.
    var nextAttemptAt: Date?

    /// 直近の失敗理由(ユーザ提示用).
    var lastFailureReason: String?

    /// 自動再送を諦めた状態か. ユーザが「再送信」を押すまで待つ.
    var isPermanentlyFailed: Bool

    init(
        id: MessageID = .generate(),
        conversationID: ConversationID,
        senderID: UserID,
        body: Body,
        createdAt: Date = .now,
        replyTo: ReplyReference? = nil,
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastFailureReason: String? = nil,
        isPermanentlyFailed: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.replyTo = replyTo
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastFailureReason = lastFailureReason
        self.isPermanentlyFailed = isPermanentlyFailed
    }

    /// このメッセージが持つ添付 ID(ローカルファイルの掃除に使う).
    var attachmentID: AttachmentID? {
        if case .media(let media) = body { return media.attachmentID }
        return nil
    }

    /// 楽観的にチャットへ即時表示するための `Message` を作る.
    /// 送信完了を待たずに吹き出しを出すことで「送ってすぐ次の操作へ」を実現する.
    func optimisticMessage() -> Message {
        let content: MessageContent
        switch body {
        case .text(let value):
            content = .text(value)
        case .media(let media):
            let attachment = MediaAttachment(
                id: media.attachmentID,
                kind: media.kind,
                localURL: media.fileURL,
                thumbnailData: media.thumbnailData,
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight,
                duration: media.duration,
                byteCount: media.byteCount
            )
            content = media.kind == .image ? .image(attachment) : .video(attachment)
        }
        return Message(
            id: id,
            conversationID: conversationID,
            senderID: senderID,
            content: content,
            createdAt: createdAt,
            // 自動再送の途中は「送信中」のまま見せる. 諦めた時点で初めて
            // 「送信できませんでした」と再送ボタンを出す.
            deliveryState: isPermanentlyFailed
                ? .failed(reason: lastFailureReason ?? String(localized: "送信できませんでした"))
                : .sending,
            replyTo: replyTo,
            isRead: true
        )
    }
}
