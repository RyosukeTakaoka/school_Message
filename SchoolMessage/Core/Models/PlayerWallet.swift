import Foundation

/// アプリ内ゲーム専用ポイント「CHIP」の残高.
///
/// ## CHIP の位置づけ
/// CHIP は**アプリ内のゲームでしか使えない点数**であり, 現金・電子マネー・
/// ギフト券などの財産と交換できない. 購入する手段も, 利用者同士で
/// 受け渡す手段も用意しない(規約にも同じことを書いてある).
/// 残高が 0 になっても, 時間が経てば無償で戻る(下記「復活」).
///
/// ## どこに保存するか
/// プロフィール(`UserProfile`)には入れず, 専用のレコードに分けている.
/// プロフィールは全員に配って回る情報なので, ゲームのたびに書き換えると
/// 他の人の手元のキャッシュまで無効にしてしまうため.
struct PlayerWallet: Hashable, Sendable {

    /// 持ち主. CloudKit の `creatorUserRecordID` と突き合わせて偽物を弾く.
    let ownerID: UserID
    var balance: Int
    /// CHIP が 0 になった日時. 復活したら nil に戻す.
    var bankruptAt: Date?
    /// 精算済みの対戦 ID. 同じ対戦で二重に増減させないための記録.
    var settledGameIDs: [String]
    var updatedAt: Date

    /// 新規ユーザ, および復活時の残高.
    static let initialBalance = 1000

    /// 記録しておく精算済み対戦の数(端末を変えても効くよう, 残高と一緒に保存する).
    ///
    /// 古いものから捨てるので, 二重精算を防ぎたい期間(対戦は 3 日,
    /// 競馬は 7 日さかのぼって確かめる)のあいだに押し出されない程度の
    /// 余裕が要る. 馬券は 1 枚ごとに記録が増えるため, そのぶん多めにしてある.
    static let settledHistoryLimit = 300

    init(
        ownerID: UserID,
        balance: Int = PlayerWallet.initialBalance,
        bankruptAt: Date? = nil,
        settledGameIDs: [String] = [],
        updatedAt: Date = .now
    ) {
        self.ownerID = ownerID
        self.balance = balance
        self.bankruptAt = bankruptAt
        self.settledGameIDs = settledGameIDs
        self.updatedAt = updatedAt
    }
}

// MARK: - 破産と復活

extension PlayerWallet {

    /// 0 になった日の**翌日を丸 1 日空けて**, その次の日に復活する.
    /// (月曜に 0 → 水曜に復活)
    ///
    /// 「今日 0 にして明日から満額」を狙えてしまうと, 負けを取り返すために
    /// わざと 0 にする遊び方を誘発するため, 1 日空ける.
    static let bankruptRestDays = 2

    /// 復活する日(その日の 0 時).
    func revivalDate(calendar: Calendar = .current) -> Date? {
        guard let bankruptAt else { return nil }
        let startOfBankruptDay = calendar.startOfDay(for: bankruptAt)
        return calendar.date(byAdding: .day, value: Self.bankruptRestDays, to: startOfBankruptDay)
    }

    /// CHIP が足りず, ゲームに参加できない状態か.
    func isBankrupt() -> Bool {
        balance < ChipRules.minBet
    }

    /// 復活のルーレットを回せる状態か.
    func isRevivalDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard bankruptAt != nil, let revivalDate = revivalDate(calendar: calendar) else { return false }
        return now >= revivalDate
    }

    /// 0 になったのに起点が記録されていなければ記録する. 変える必要がなければ nil.
    ///
    /// 記録が無いままだと復活日が決まらず, ずっと遊べなくなってしまうための保険.
    func stampingBankruptcyIfNeeded(now: Date = .now) -> PlayerWallet? {
        guard balance < ChipRules.minBet, bankruptAt == nil else { return nil }
        var stamped = self
        stamped.bankruptAt = now
        stamped.updatedAt = now
        return stamped
    }

    /// 今回の復活で出る額.
    ///
    /// 回すたびに変わると, アプリを落として引き直す(いわゆるリセマラ)ができて
    /// しまうため, **持ち主と「0 になった日時」から決まる値**にしてある.
    /// 同じ破産 1 回につき結果はひとつで, 何度開き直しても変わらない.
    var revivalAmount: Int {
        guard let bankruptAt else { return Self.initialBalance }
        return ChipRevivalWheel.amount(
            seed: "\(ownerID.rawValue)#\(Int(bankruptAt.timeIntervalSince1970))"
        )
    }

    /// ルーレットの結果を受け取った財布を返す.
    ///
    /// はずれ(遊べる額に届かない)ときは, その時点から数え直してまた待つ.
    func claimingRevival(now: Date = .now) -> PlayerWallet {
        var next = self
        next.balance = revivalAmount
        next.bankruptAt = next.balance < ChipRules.minBet ? now : nil
        next.updatedAt = now
        return next
    }

    /// 差分を適用した財布を返す(残高は 0 未満にしない).
    ///
    /// 0 になった瞬間に破産の起点を記録する. すでに破産中ならその日時は動かさない
    /// (0 のまま遊べない間に起点が先送りされないように).
    func applying(delta: Int, gameID: String?, now: Date = .now) -> PlayerWallet {
        var next = self
        next.balance = max(0, balance + delta)
        next.updatedAt = now

        if next.balance < ChipRules.minBet {
            if next.bankruptAt == nil { next.bankruptAt = now }
        } else {
            next.bankruptAt = nil
        }

        if let gameID, !next.settledGameIDs.contains(gameID) {
            next.settledGameIDs.append(gameID)
            if next.settledGameIDs.count > Self.settledHistoryLimit {
                next.settledGameIDs.removeFirst(next.settledGameIDs.count - Self.settledHistoryLimit)
            }
        }
        return next
    }

    func hasSettled(gameID: String) -> Bool {
        settledGameIDs.contains(gameID)
    }
}

/// CHIP が 0 になったあとの「復活ルーレット」.
///
/// 以前は必ず 1,000 CHIP に戻していたが, それだと戻ってくる額が分かりきっていて
/// 面白みが無い. 多くは 0〜1,000 の間に収まるようにしつつ,
/// ごくまれに **0(はずれ)** と **2,000(初期の 2 倍)** が出るようにしてある.
enum ChipRevivalWheel {

    struct Slot: Hashable, Sendable, Identifiable {
        let amount: Int
        /// 出やすさ. 全部足すと 100 になるので, そのまま「％」として読める.
        let weight: Int

        var id: Int { amount }
    }

    /// 表示する順番(少ない順. 最後がジャックポット).
    static let slots: [Slot] = [
        Slot(amount: 0, weight: 2),
        Slot(amount: 100, weight: 5),
        Slot(amount: 200, weight: 8),
        Slot(amount: 300, weight: 10),
        Slot(amount: 400, weight: 12),
        Slot(amount: 500, weight: 14),
        Slot(amount: 600, weight: 14),
        Slot(amount: 700, weight: 12),
        Slot(amount: 800, weight: 10),
        Slot(amount: 900, weight: 6),
        Slot(amount: PlayerWallet.initialBalance, weight: 4),
        Slot(amount: PlayerWallet.initialBalance * 2, weight: 3)
    ]

    /// 種から決まる当たり. 同じ種なら何度呼んでも同じ額になる.
    static func amount(seed: String) -> Int {
        var generator = SeededGenerator(seed: ColorBattleSnapshot.hash(seed))
        let total = slots.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return PlayerWallet.initialBalance }
        var roll = Int(generator.next() % UInt64(total))
        for slot in slots {
            roll -= slot.weight
            if roll < 0 { return slot.amount }
        }
        return slots.last?.amount ?? PlayerWallet.initialBalance
    }

    /// 当たりの呼び方(画面に出す).
    static func title(for amount: Int) -> String {
        if amount >= PlayerWallet.initialBalance * 2 { return String(localized: "大当たり!") }
        if amount >= PlayerWallet.initialBalance { return String(localized: "満額!") }
        if amount < ChipRules.minBet { return String(localized: "はずれ…") }
        return String(localized: "復活!")
    }
}

/// CHIP ランキングの 1 行.
///
/// 表示名やアバターはここには入れず, `UserProfile` を別途引いて合わせる
/// (プロフィールの取得・キャッシュはすでにある仕組みを使い回す).
struct ChipRankingEntry: Hashable, Sendable, Identifiable {
    let ownerID: UserID
    let balance: Int
    /// 精算まで終わった対戦の数.
    ///
    /// 1 回も遊んでいない人は, 配られたままの CHIP でランキングに並んでしまい
    /// おもしろくないので, 並べる前にここで振り分ける.
    let playedGameCount: Int
    let updatedAt: Date

    var id: UserID { ownerID }
}

// MARK: - ベットの決まり

/// CHIP を賭ける額の決まり. ゲームごとに上限だけが違う.
enum ChipRules {

    static let minBet = 10
    static let step = 10
    static let defaultMaxBet = 100

    /// 選べる額の一覧. 所持 CHIP を超える額は出さない.
    static func betOptions(maxBet: Int, balance: Int) -> [Int] {
        let ceiling = min(maxBet, balance)
        guard ceiling >= minBet else { return [] }
        return stride(from: minBet, through: ceiling, by: step).map { $0 }
    }

    /// 賭けられる額か.
    static func isValidBet(_ bet: Int, maxBet: Int, balance: Int) -> Bool {
        bet >= minBet && bet <= maxBet && bet <= balance && bet.isMultiple(of: step)
    }

    /// 画面に出す表記. 「1,000 CHIP」のように 3 桁区切りにする.
    static func formatted(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(number) CHIP"
    }

    /// 増減の表記(+50 CHIP / -50 CHIP).
    static func formattedDelta(_ delta: Int) -> String {
        delta >= 0 ? "+\(formatted(delta))" : "-\(formatted(abs(delta)))"
    }
}
