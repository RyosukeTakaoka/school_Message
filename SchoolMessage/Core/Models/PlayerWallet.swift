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
    /// 最後に復活ルーレットに挑戦した日時. 挑戦のたびに更新し, 復活したら nil に戻す.
    ///
    /// `bankruptAt` は「0 になった最初の瞬間」を指したまま動かさない
    /// (`claimingRevival` 参照). はずれを引くたびにここだけ進めることで,
    /// 「最初だけ `bankruptRestDays` 待ち, 以降はずれるたびに `revivalRetryRestDays`
    /// だけ待つ」という, 2 段階の待ち時間を表せる.
    var lastRevivalAttemptAt: Date?
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
        lastRevivalAttemptAt: Date? = nil,
        settledGameIDs: [String] = [],
        updatedAt: Date = .now
    ) {
        self.ownerID = ownerID
        self.balance = balance
        self.bankruptAt = bankruptAt
        self.lastRevivalAttemptAt = lastRevivalAttemptAt
        self.settledGameIDs = settledGameIDs
        self.updatedAt = updatedAt
    }
}

// MARK: - 破産と復活

extension PlayerWallet {

    /// 0 になった日の**翌日を丸 1 日空けて**, その次の日に初めて挑戦できる.
    /// (月曜に 0 → 水曜に挑戦可能)
    ///
    /// 「今日 0 にして明日から満額」を狙えてしまうと, 負けを取り返すために
    /// わざと 0 にする遊び方を誘発するため, 1 日空ける.
    static let bankruptRestDays = 2

    /// はずれてから, 次に挑戦できるまでの日数.
    ///
    /// 最初の `bankruptRestDays` より短くしてある. 「はずれるたびにまた
    /// `bankruptRestDays` 待つ」にすると, 運が悪いだけで 1〜2 週間 CHIP を
    /// 使えなくなることがあり, 罰というより詰みに近くなってしまうため.
    /// 一度でも最初の待機を終えていれば, あとは 1 日 1 回のチャレンジとして扱う.
    static let revivalRetryRestDays = 1

    /// 最初に挑戦できるようになる日(その日の 0 時). まだ一度も 0 になっていなければ nil.
    func revivalDate(calendar: Calendar = .current) -> Date? {
        guard let bankruptAt else { return nil }
        let startOfBankruptDay = calendar.startOfDay(for: bankruptAt)
        return calendar.date(byAdding: .day, value: Self.bankruptRestDays, to: startOfBankruptDay)
    }

    /// 次に挑戦できる日(その日の 0 時).
    ///
    /// 最初の待機(`revivalDate`)と, 直前にはずれてからの待機
    /// (`lastRevivalAttemptAt` + `revivalRetryRestDays`)のうち, 遅いほうを返す.
    /// まだ一度も挑戦していなければ最初の待機だけで決まる.
    func nextRevivalAttemptDate(calendar: Calendar = .current) -> Date? {
        guard let firstEligible = revivalDate(calendar: calendar) else { return nil }
        guard let lastAttempt = lastRevivalAttemptAt else { return firstEligible }
        let retryEligible = calendar.date(
            byAdding: .day,
            value: Self.revivalRetryRestDays,
            to: calendar.startOfDay(for: lastAttempt)
        ) ?? firstEligible
        return max(firstEligible, retryEligible)
    }

    /// CHIP が足りず, ゲームに参加できない状態か.
    func isBankrupt() -> Bool {
        balance < ChipRules.minBet
    }

    /// 復活のルーレットを回せる状態か.
    func isRevivalDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard bankruptAt != nil, let nextAttemptDate = nextRevivalAttemptDate(calendar: calendar) else {
            return false
        }
        return now >= nextAttemptDate
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

    /// この挑戦で出る額.
    ///
    /// `now` は呼び出し側(`ChatStore.claimRevivalIfDue`)がサーバへの問い合わせと
    /// 共有する 1 つの時刻を渡す. 同じ `now` を渡す限り, アプリを落として
    /// 引き直す(いわゆるリセマラ)はできない — 挑戦した瞬間に `lastRevivalAttemptAt`
    /// としてサーバ側に刻まれ, 開き直しても同じ挑戦の結果しか読めなくなるため.
    func revivalAmount(now: Date) -> Int {
        ChipRevivalWheel.amount(seed: "\(ownerID.rawValue)#\(Int(now.timeIntervalSince1970))")
    }

    /// ルーレットの結果を受け取った財布を返す.
    ///
    /// はずれ(遊べる額に届かない)ときは, `bankruptAt`(0 になった最初の瞬間)は
    /// 動かさず, `lastRevivalAttemptAt` だけ進める. 次に挑戦できる日は
    /// `nextRevivalAttemptDate` が計算する.
    func claimingRevival(now: Date = .now) -> PlayerWallet {
        var next = self
        next.balance = revivalAmount(now: now)
        if next.balance < ChipRules.minBet {
            next.lastRevivalAttemptAt = now
        } else {
            next.bankruptAt = nil
            next.lastRevivalAttemptAt = nil
        }
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
            if next.bankruptAt == nil {
                next.bankruptAt = now
                // 新しい破産サイクルなので, 前回までの挑戦の記録は持ち越さない.
                next.lastRevivalAttemptAt = nil
            }
        } else {
            next.bankruptAt = nil
            next.lastRevivalAttemptAt = nil
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
