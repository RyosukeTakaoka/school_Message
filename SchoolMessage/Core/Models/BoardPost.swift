import Foundation

/// 掲示板のスレッド.
///
/// ## チャットと分けている理由
/// 「わざわざ全体に送るほどでもない独り言」を置く場所なので, 特定の相手へ
/// 届ける仕組み(会話・鍵の配布・既読)は要らない. 逆に**誰でも読める**ことが
/// 前提なので, チャットのような会話鍵での暗号化も行わない.
///
/// この違いは利用者に伝わる必要があるため, 画面にも明示する.
struct BoardThread: Identifiable, Hashable, Sendable {

    let id: ThreadID
    /// スレッドのタイトル.
    var title: String
    /// 立てた人(表示はしないが, なりすまし検証のために保持する).
    let authorID: UserID
    let createdAt: Date
    /// 最後に書き込まれた時刻. 一覧の並べ替えに使う.
    var lastPostedAt: Date
    /// 書き込み数. 一覧に出す.
    var postCount: Int

    init(
        id: ThreadID = .generate(),
        title: String,
        authorID: UserID,
        createdAt: Date = .now,
        lastPostedAt: Date = .now,
        postCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.authorID = authorID
        self.createdAt = createdAt
        self.lastPostedAt = lastPostedAt
        self.postCount = postCount
    }

    static let titleMaxLength = 40

    static func validateTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.underlying(String(localized: "スレッドのタイトルを入力してください"))
        }
        guard trimmed.count <= titleMaxLength else {
            throw AppError.underlying(String(localized: "タイトルは \(titleMaxLength) 文字までです"))
        }
        return trimmed
    }
}

/// 掲示板の書き込み.
struct BoardPost: Identifiable, Hashable, Sendable {

    let id: PostID
    let threadID: ThreadID
    /// 書き込んだ人. 表示名は出さず, ここから作った短い ID だけを出す.
    let authorID: UserID
    var body: String
    let createdAt: Date
    /// スレッド内の通し番号(1 から).
    var number: Int

    init(
        id: PostID = .generate(),
        threadID: ThreadID,
        authorID: UserID,
        body: String,
        createdAt: Date = .now,
        number: Int = 0
    ) {
        self.id = id
        self.threadID = threadID
        self.authorID = authorID
        self.body = body
        self.createdAt = createdAt
        self.number = number
    }

    static let bodyMaxLength = 1000

    static func validateBody(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.underlying(String(localized: "本文を入力してください"))
        }
        guard trimmed.count <= bodyMaxLength else {
            throw AppError.underlying(String(localized: "本文は \(bodyMaxLength) 文字までです"))
        }
        return trimmed
    }

    /// スレッド内で書き手を見分けるための短い ID.
    ///
    /// 表示名を出さない代わりに, 「同じスレッドの同じ人は同じ表示になる」
    /// 程度の手掛かりを残す. 別のスレッドでは別の値になるので, 掲示板全体を
    /// またいで個人を追うことはできない.
    ///
    /// 元の userID は復元できないが, これは匿名性の保証ではない
    /// (作成者はサーバ側に記録されている). あくまで表示上の配慮.
    var displayID: String {
        var hash: UInt64 = 5381
        for byte in (authorID.rawValue + threadID.rawValue).utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var value = hash
        var result = ""
        for _ in 0..<6 {
            result.append(alphabet[Int(value % UInt64(alphabet.count))])
            value /= UInt64(alphabet.count)
        }
        return result
    }
}
