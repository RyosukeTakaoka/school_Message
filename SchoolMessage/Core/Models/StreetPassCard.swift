import Foundation

/// すれ違ったときに相手へ渡す小さな名刺.
///
/// ## なぜ名前と一言しか入れないのか
/// この内容は Bluetooth の電波に乗って, 近くにいる「このアプリを入れている人」
/// が受け取れる. サーバを通らないので, 誰が受け取ったかも分からない.
/// だから**相手に見られて困る物は載せない**のが前提になる.
///
/// 渡すのは名前・ユーザ ID・短い一言だけ. 持ち物やメッセージのやり取りはしない.
/// 画像も載せない(数 KB でも Bluetooth では往復が増え, すれ違う数秒の間に
/// 読み終わらないことがある). 画像が要るときは, 後から iCloud 側の
/// プロフィールを引けばよい.
struct StreetPassCard: Codable, Hashable, Sendable {

    /// 一言の最大文字数. 電波に乗せる都合で短く抑える.
    static let commentMaxLength = 60

    /// 形式の版. 将来内容を変えたときに, 古い版を無視できるようにする.
    static let currentVersion = 1

    var version: Int
    var userID: UserID
    var handle: String
    var displayName: String
    /// すれ違った相手に見せる一言. 空でもよい.
    var comment: String

    init(userID: UserID, handle: String, displayName: String, comment: String) {
        self.version = Self.currentVersion
        self.userID = userID
        self.handle = handle
        self.displayName = displayName
        self.comment = String(comment.prefix(Self.commentMaxLength))
    }

    // MARK: - 電波に乗せる形

    /// 交換に使う JSON. 読み取り 1 往復で終わる大きさに収める.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// 受け取った内容を読む. 壊れていたり版が違えば `nil`.
    ///
    /// 中身は「近くにいた誰か」が自由に作れる値なので, 一切信用せずに
    /// 長さを切り詰めてから取り込む.
    static func decoded(from data: Data) -> StreetPassCard? {
        guard data.count <= 1024,
              let card = try? JSONDecoder().decode(StreetPassCard.self, from: data),
              card.version == currentVersion,
              !card.userID.rawValue.isEmpty else { return nil }

        var sanitized = card
        sanitized.displayName = String(card.displayName.prefix(AppConstants.Validation.displayNameMaxLength))
        sanitized.handle = String(card.handle.prefix(AppConstants.Validation.handleMaxLength))
        sanitized.comment = String(card.comment.prefix(commentMaxLength))
        guard !sanitized.displayName.isEmpty else { return nil }
        return sanitized
    }
}

/// すれ違いの記録.
///
/// 端末の中だけに持ち, サーバへは送らない. 「誰と誰がいつ同じ場所にいたか」は
/// 本人たち以外が持つべき情報ではないため.
struct StreetPassEncounter: Codable, Hashable, Sendable, Identifiable {

    var card: StreetPassCard
    var firstMetAt: Date
    var lastMetAt: Date
    /// すれ違った回数.
    var meetCount: Int
    /// まだ一覧を開いて確認していないか.
    var isUnseen: Bool

    /// 最後に見えたときの電波の強さ(dBm). 参考値.
    ///
    /// 距離の判定には**使わない**. RSSI は人の体・壁・端末の向きで簡単に
    /// 20dBm 以上変わるので, これで足切りすると本当のすれ違いを取りこぼす.
    /// 記録の目的は「どのくらいの近さで拾えているか」を後から確かめること.
    var lastRSSI: Int?
    /// これまでで最も強かった値.
    var strongestRSSI: Int?

    var id: String { card.userID.rawValue }

    init(card: StreetPassCard, rssi: Int? = nil, at date: Date = .now) {
        self.card = card
        self.firstMetAt = date
        self.lastMetAt = date
        self.meetCount = 1
        self.isUnseen = true
        self.lastRSSI = rssi
        self.strongestRSSI = rssi
    }

    /// もう一度すれ違ったときの更新. 一言は最新のものに置き換える.
    mutating func met(with card: StreetPassCard, rssi: Int? = nil, at date: Date = .now) {
        self.card = card
        self.lastMetAt = date
        self.meetCount += 1
        self.isUnseen = true
        touch(rssi: rssi, at: date)
    }

    /// 同じすれ違いの中での更新(回数は増やさない).
    ///
    /// 1 回のすれ違いでも, こちらが相手を読む経路と, 相手がこちらへ書き込む
    /// 経路の両方が成立することがある. 2 回と数えないための入り口.
    mutating func touch(rssi: Int?, at date: Date = .now) {
        lastMetAt = max(lastMetAt, date)
        if let rssi {
            lastRSSI = rssi
            strongestRSSI = max(strongestRSSI ?? rssi, rssi)
        }
    }
}
