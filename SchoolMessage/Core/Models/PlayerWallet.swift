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
    static let settledHistoryLimit = 100

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

    /// いま CHIP を使うゲームで遊べない状態か.
    func isBankrupt(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard balance < ChipRules.minBet else { return false }
        guard let revivalDate = revivalDate(calendar: calendar) else { return true }
        return now < revivalDate
    }

    /// 時間の経過で変わるところを整える. 変える必要がなければ nil.
    ///
    /// - 復活日を過ぎていれば満額に戻す(「今すぐ戻す」操作は用意しない)
    /// - 0 になったのに起点が記録されていなければ, ここで記録する
    ///   (記録が無いままだと復活日が決まらず, ずっと遊べなくなってしまうため)
    func refreshedIfNeeded(now: Date = .now, calendar: Calendar = .current) -> PlayerWallet? {
        if bankruptAt != nil, let revivalDate = revivalDate(calendar: calendar), now >= revivalDate {
            var revived = self
            revived.balance = Self.initialBalance
            revived.bankruptAt = nil
            revived.updatedAt = now
            return revived
        }
        if balance < ChipRules.minBet, bankruptAt == nil {
            var stamped = self
            stamped.bankruptAt = now
            stamped.updatedAt = now
            return stamped
        }
        return nil
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

/// CHIP ランキングの 1 行.
///
/// 表示名やアバターはここには入れず, `UserProfile` を別途引いて合わせる
/// (プロフィールの取得・キャッシュはすでにある仕組みを使い回す).
struct ChipRankingEntry: Hashable, Sendable, Identifiable {
    let ownerID: UserID
    let balance: Int
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
