import Foundation
import CryptoKit

/// 競馬(平日 15:00 発走).
///
/// ## 他の遊びとの違い
/// チャットの中の対戦は「参加者どうしの奪い合い」で, CHIP の総量は変わらない.
/// 競馬はそうではなく, **胴元のいる賭け**として作ってある. 払い戻しは
/// 実際の競馬と同じ固定オッズで, 控除率(`HorseRaceRules.takeout`)のぶんだけ
/// 長い目で見れば CHIP は減っていく. 減ったぶんは復活ルーレットで戻るので,
/// 全体としては釣り合う. この形にしたことで,
/// - 買った人数に関係なくレースが成立する(1 人でも遊べる)
/// - 強い馬は低配当・弱い馬は高配当という関係が生まれ, 出走表を読む意味が出る
/// - 期待値がマイナスなので, 競馬で CHIP を荒稼ぎすることはできない
///
/// ## 結果とアニメーションがずれない作り
/// 「先に着順を決めて, それらしいアニメを後から付ける」ことはしない.
/// 種(`seed`)ひとつから**レースそのものを計算で再現**し(`HorseRaceRun`),
/// 着順はその計算のゴール順をそのまま読む. 画面の馬は計算された位置に
/// 置いているだけなので, 原理的にずれようがない.
///
/// 同じ種なら, どの端末でも何度見返しても寸分違わず同じレースになる
/// (色勝負や大富豪のカードを配るのに使っている `SeededGenerator` と同じ考え方).
enum HorseRaceRules {

    /// 出走頭数.
    static let horseCount = 9

    /// 1 枚の馬券に賭けられる上限.
    static let maxBet = 100

    /// 控除率. 実際の競馬とほぼ同じ 20%.
    static let takeout = 0.20

    /// オッズの上限(倍).
    ///
    /// 3 連単は 9 頭なら 504 通りあるため, 計算上は数千倍になることがある.
    /// そのまま払うと 1 回の的中でランキングが壊れてしまうので頭を抑える.
    static let maxOdds = 200.0

    /// オッズの下限(倍). 元返し以下にはしない.
    static let minOdds = 1.1

    /// 発走時刻(時, 分).
    static let postHour = 15
    static let postMinute = 0

    /// 締切時刻(時, 分). 発走の 10 分前.
    static let closingHour = 14
    static let closingMinute = 50

    /// レースの演出にかける秒数.
    static let runDuration: Double = 12

    /// 精算をさかのぼって確かめる日数.
    ///
    /// 買ったまま何日かアプリを開かなかった人にも, あとから払い戻しが届くようにする.
    static let settlementLookbackDays = 7
}

// MARK: - 開催日

/// 開催日の決まり. 平日だけ, 1 日 1 レース.
///
/// レースは誰かが「開催する」ものではなく, **日付が来れば存在する**ものとして扱う.
/// こうすると主催者を置かずに済み, 出走表も開催日から計算で組み立てられる.
enum HorseRaceSchedule {

    /// 開催日の表記(`2026-09-16`). これがそのままレースの ID になる.
    static func raceID(for date: Date, calendar: Calendar = .current) -> String? {
        guard isRaceDay(date, calendar: calendar) else { return nil }
        return dateFormatter.string(from: date)
    }

    /// 平日(月〜金)か. 祝日は考慮しない(学校の予定表は持てないため).
    static func isRaceDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // 1 = 日曜, 7 = 土曜.
        return weekday != 1 && weekday != 7
    }

    /// いま見せるべきレース.
    ///
    /// 平日ならその日のレース. 土日なら次の平日のレースを先に見せる
    /// (出走表は開催日から決まるので, 前もって眺められる).
    static func currentRaceID(now: Date = .now, calendar: Calendar = .current) -> String {
        if isRaceDay(now, calendar: calendar) {
            return dateFormatter.string(from: now)
        }
        var candidate = now
        for _ in 0..<7 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
            if isRaceDay(candidate, calendar: calendar) {
                return dateFormatter.string(from: candidate)
            }
        }
        return dateFormatter.string(from: now)
    }

    /// 直近の開催日を新しい順に返す(精算のさかのぼりに使う).
    static func recentRaceIDs(
        upTo now: Date = .now,
        days: Int = HorseRaceRules.settlementLookbackDays,
        calendar: Calendar = .current
    ) -> [String] {
        var results: [String] = []
        var candidate = now
        for _ in 0..<days {
            if isRaceDay(candidate, calendar: calendar) {
                results.append(dateFormatter.string(from: candidate))
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: candidate) else { break }
            candidate = previous
        }
        return results
    }

    static func date(fromRaceID raceID: String) -> Date? {
        dateFormatter.date(from: raceID)
    }

    /// 締切時刻(14:50).
    static func closingTime(raceID: String, calendar: Calendar = .current) -> Date? {
        guard let day = date(fromRaceID: raceID) else { return nil }
        return calendar.date(
            bySettingHour: HorseRaceRules.closingHour,
            minute: HorseRaceRules.closingMinute,
            second: 0,
            of: day
        )
    }

    /// 発走時刻(15:00).
    static func postTime(raceID: String, calendar: Calendar = .current) -> Date? {
        guard let day = date(fromRaceID: raceID) else { return nil }
        return calendar.date(
            bySettingHour: HorseRaceRules.postHour,
            minute: HorseRaceRules.postMinute,
            second: 0,
            of: day
        )
    }

    /// レースがいまどの段階にあるか.
    enum Phase: Hashable, Sendable {
        /// 受付中. 締切までの残り時間を持つ.
        case betting(closesAt: Date)
        /// 締切済み, 発走待ち.
        case closed(startsAt: Date)
        /// 発走済み(結果を見られる).
        case finished
    }

    static func phase(raceID: String, now: Date = .now, calendar: Calendar = .current) -> Phase {
        guard let closesAt = closingTime(raceID: raceID, calendar: calendar),
              let startsAt = postTime(raceID: raceID, calendar: calendar)
        else { return .finished }

        if now < closesAt { return .betting(closesAt: closesAt) }
        if now < startsAt { return .closed(startsAt: startsAt) }
        return .finished
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // 端末の暦の設定に左右されないよう固定する(ID として使うため).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - 脚質

/// 走り方の型. 出走表に出す情報であり, **そのままアニメーションの形**になる.
///
/// 強さとは関係がない(逃げだから強い, ということはない). 展開の読みどころを
/// 作るためのもので, 「今日は逃げ馬が 1 頭しかいないから楽に先行できそう」
/// といった予想ができるようにしている.
enum RunningStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// 逃げ. 序盤から先頭に立つが, 終盤は苦しくなりやすい.
    case front
    /// 先行. 前めにつけて粘る.
    case stalk
    /// 差し. 中団から直線で伸びる.
    case close
    /// 追込. 後方から最後だけ一気に来る.
    case deepClose

    var title: String {
        switch self {
        case .front: String(localized: "逃げ")
        case .stalk: String(localized: "先行")
        case .close: String(localized: "差し")
        case .deepClose: String(localized: "追込")
        }
    }

    /// 走りの形を決める指数. 1 より小さいほど序盤から前に出て,
    /// 大きいほど序盤は後ろで終盤に伸びる.
    var paceExponent: Double {
        switch self {
        case .front: 0.78
        case .stalk: 0.92
        case .close: 1.12
        case .deepClose: 1.34
        }
    }
}

// MARK: - 調子

enum HorseCondition: String, Hashable, Sendable, Codable, CaseIterable {
    case good
    case normal
    case poor

    var mark: String {
        switch self {
        case .good: "◎"
        case .normal: "○"
        case .poor: "▲"
        }
    }

    var title: String {
        switch self {
        case .good: String(localized: "好調")
        case .normal: String(localized: "普通")
        case .poor: String(localized: "不調")
        }
    }

    /// 能力への上乗せ.
    var ratingBonus: Double {
        switch self {
        case .good: 8
        case .normal: 0
        case .poor: -8
        }
    }
}

// MARK: - 出走馬

struct Horse: Identifiable, Hashable, Sendable {

    /// 馬番(1 から).
    let number: Int
    let name: String
    let style: RunningStyle
    let condition: HorseCondition
    /// 近 3 走の着順(新しい順).
    let recentForm: [Int]
    /// 能力値. 画面には出さず, オッズと勝ちやすさの根拠にだけ使う.
    let rating: Double

    var id: Int { number }

    /// 近走の表記(`1-3-2`).
    var recentFormText: String {
        recentForm.map(String.init).joined(separator: "-")
    }

    /// 勝ちやすさの重み. オッズも実際の走りも, すべてこの値から決まる.
    ///
    /// 指数を掛けて差を広げている. そのままの能力値だと 9 頭がほぼ横並びになり,
    /// オッズに差が付かず予想する楽しみが無くなるため.
    var weight: Double {
        pow(max(rating, 1) / 100, 5)
    }
}

// MARK: - 出走表

/// その日の 9 頭.
///
/// 開催日から決まるので, **朝から見られる**(決まっていないのは結果だけ).
/// レコードには保存しない — どの端末でも同じ計算で同じ表が組み立つため.
struct HorseRaceCard: Hashable, Sendable {

    let raceID: String
    let horses: [Horse]

    init(raceID: String) {
        self.raceID = raceID
        self.horses = Self.makeHorses(raceID: raceID)
    }

    func horse(number: Int) -> Horse? {
        horses.first { $0.number == number }
    }

    // MARK: 確率

    /// 単勝の的中率.
    func winProbability(of number: Int) -> Double {
        guard let horse = horse(number: number) else { return 0 }
        let total = horses.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return horse.weight / total
    }

    /// 上位 3 着の並びと, その並びになる確率の一覧.
    ///
    /// 9 頭なら 9 × 8 × 7 = 504 通り. どの券種の的中率も, この一覧のうち
    /// 当てはまるものを足し合わせれば正確に求まる.
    ///
    /// 確率の出し方は競馬で一般的な方法(1 着を能力の比で選び, 残りから
    /// 2 着を同じ比で選ぶ…… と繰り返す)を使っている. **実際の走りも
    /// まったく同じ方法で決める**ので, オッズと勝ちやすさが食い違うことはない
    /// (食い違うと, 特定の買い方だけが得になってしまう).
    func topThreeOutcomes() -> [(order: [Int], probability: Double)] {
        let total = horses.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return [] }

        var results: [(order: [Int], probability: Double)] = []
        for first in horses {
            let afterFirst = total - first.weight
            guard afterFirst > 0 else { continue }
            let probabilityOfFirst = first.weight / total

            for second in horses where second.number != first.number {
                let afterSecond = afterFirst - second.weight
                guard afterSecond > 0 else { continue }
                let probabilityOfSecond = second.weight / afterFirst

                for third in horses where third.number != first.number && third.number != second.number {
                    let probabilityOfThird = third.weight / afterSecond
                    results.append((
                        order: [first.number, second.number, third.number],
                        probability: probabilityOfFirst * probabilityOfSecond * probabilityOfThird
                    ))
                }
            }
        }
        return results
    }

    /// 買い目の的中率.
    func probability(kind: HorseRaceBetKind, selections: [Int]) -> Double {
        guard kind.isValid(selections: selections, horseCount: horses.count) else { return 0 }
        return topThreeOutcomes()
            .filter { kind.hits(selections: selections, topThree: $0.order) }
            .reduce(0.0) { $0 + $1.probability }
    }

    /// 買い目のオッズ(倍).
    func odds(kind: HorseRaceBetKind, selections: [Int]) -> Double {
        Self.odds(forProbability: probability(kind: kind, selections: selections))
    }

    /// 単勝オッズ(出走表に出す).
    func winOdds(of number: Int) -> Double {
        Self.odds(forProbability: winProbability(of: number))
    }

    /// 的中率からオッズを出す. 控除率を引いたうえで, 上限と下限で頭を抑える.
    static func odds(forProbability probability: Double) -> Double {
        guard probability > 0 else { return HorseRaceRules.maxOdds }
        let raw = (1 - HorseRaceRules.takeout) / probability
        let clamped = min(max(raw, HorseRaceRules.minOdds), HorseRaceRules.maxOdds)
        // 小数第 1 位まで(実際の競馬と同じ見せ方).
        return (clamped * 10).rounded() / 10
    }

    /// 人気順(単勝オッズが低い順)の番号. 1 番人気が先頭.
    var horsesByPopularity: [Horse] {
        horses.sorted { $0.weight > $1.weight }
    }

    /// 何番人気か.
    func popularity(of number: Int) -> Int {
        (horsesByPopularity.firstIndex { $0.number == number } ?? 0) + 1
    }

    // MARK: 組み立て

    private static func makeHorses(raceID: String) -> [Horse] {
        // 出走表の種は開催日だけから作る. 結果の種(締切後に決まる)とは別物で,
        // こちらは朝から確定していてよい — むしろ確定していないと予想ができない.
        var generator = SeededGenerator(seed: ColorBattleSnapshot.hash("card-\(raceID)"))

        var namePool = horseNames
        namePool.shuffle(using: &generator)

        return (1...HorseRaceRules.horseCount).map { number in
            let baseRating = 62 + Double(generator.next() % 34)
            let condition = HorseCondition.allCases[Int(generator.next() % UInt64(HorseCondition.allCases.count))]
            let style = RunningStyle.allCases[Int(generator.next() % UInt64(RunningStyle.allCases.count))]
            let rating = min(max(baseRating + condition.ratingBonus, 40), 100)

            // 近走は能力に引っ張られた着順にする. 強い馬ほど上の着順が出やすく,
            // 表を見たときの印象と実際の強さが噛み合うようにするため.
            let recentForm = (0..<3).map { _ -> Int in
                let luck = Double(generator.next() % 100) / 100
                let expected = (100 - rating) / 100 * 8 + 1
                let value = Int((expected * (0.5 + luck)).rounded())
                return min(max(value, 1), HorseRaceRules.horseCount)
            }

            return Horse(
                number: number,
                name: namePool[(number - 1) % namePool.count],
                style: style,
                condition: condition,
                recentForm: recentForm,
                rating: rating
            )
        }
    }

    /// 馬名の候補. 開催日ごとに引き直すので, 日によって顔ぶれが変わる.
    private static let horseNames: [String] = [
        "サクラディーヴァ", "ミドリノカゼ", "テツヤノホシ", "ハルカゼスマイル",
        "ゴールドアンサー", "シラユキメテオ", "カミナリオトシ", "アオイインパクト",
        "ユウヒノオカ", "トワイライトベル", "ネコゼンリョク", "ホシゾラレター",
        "カゲロウダンス", "ミライエクスプレス", "ソラトビウオ", "チョコレートボム",
        "イナズマガール", "ヒカリノランナー", "ナツヤスミロード", "キボウノカケラ",
        "ブンカサイクイーン", "テンサイジュケン", "オベントウバコ", "シンリンヨクヨク",
        "ハヤオキマスター", "ネムケマックス", "コウテイペンギン", "サイコウノヒビ",
        "タイフウノメ", "ユメミルチカラ", "ギンガテツドウ", "アサガオブルーム",
        "ラムネノアワ", "トショシツノヌシ", "キュウショクバンゾク", "ハクシュカッサイ",
        "モクヨウノユウウツ", "シケンゼンヤ", "カエリミチノホシ", "ヤカンノオト"
    ]
}

// MARK: - 券種

enum HorseRaceBetKind: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// 単勝. 1 着を当てる.
    case win
    /// 複勝. 3 着以内に入れば的中.
    case place
    /// 馬連. 1・2 着の組み合わせ(順不同).
    case quinella
    /// 馬単. 1・2 着を順番どおり.
    case exacta
    /// ワイド. 選んだ 2 頭が, どちらも 3 着以内.
    case wide
    /// 3 連複. 1〜3 着の 3 頭(順不同).
    case trio
    /// 3 連単. 1〜3 着を順番どおり.
    case trifecta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .win: String(localized: "単勝")
        case .place: String(localized: "複勝")
        case .quinella: String(localized: "馬連")
        case .exacta: String(localized: "馬単")
        case .wide: String(localized: "ワイド")
        case .trio: String(localized: "3連複")
        case .trifecta: String(localized: "3連単")
        }
    }

    var detail: String {
        switch self {
        case .win: String(localized: "1着を当てる")
        case .place: String(localized: "3着以内に入れば的中")
        case .quinella: String(localized: "1・2着の組み合わせ(順番は問わない)")
        case .exacta: String(localized: "1・2着を順番どおりに")
        case .wide: String(localized: "選んだ2頭が、どちらも3着以内")
        case .trio: String(localized: "1〜3着の3頭(順番は問わない)")
        case .trifecta: String(localized: "1〜3着を順番どおりに")
        }
    }

    /// 選ぶ頭数.
    var selectionCount: Int {
        switch self {
        case .win, .place: 1
        case .quinella, .exacta, .wide: 2
        case .trio, .trifecta: 3
        }
    }

    /// 選ぶ順番に意味があるか(ある券種は「1 着はこの馬」と指定する).
    var isOrdered: Bool {
        switch self {
        case .exacta, .trifecta: true
        case .win, .place, .quinella, .wide, .trio: false
        }
    }

    func isValid(selections: [Int], horseCount: Int) -> Bool {
        guard selections.count == selectionCount else { return false }
        guard Set(selections).count == selections.count else { return false }
        return selections.allSatisfy { $0 >= 1 && $0 <= horseCount }
    }

    /// 上位 3 着の並びに対して, この買い目が的中しているか.
    func hits(selections: [Int], topThree: [Int]) -> Bool {
        guard topThree.count >= 3, selections.count == selectionCount else { return false }
        switch self {
        case .win:
            return selections[0] == topThree[0]
        case .place:
            return topThree.contains(selections[0])
        case .quinella:
            return Set(selections) == Set(topThree.prefix(2))
        case .exacta:
            return selections == Array(topThree.prefix(2))
        case .wide:
            return Set(selections).isSubset(of: Set(topThree))
        case .trio:
            return Set(selections) == Set(topThree)
        case .trifecta:
            return selections == topThree
        }
    }
}

// MARK: - 馬券

struct HorseRaceBet: Identifiable, Hashable, Sendable {

    let id: String
    let raceID: String
    let bettorID: UserID
    let kind: HorseRaceBetKind
    /// 選んだ馬番. 順番に意味がある券種では, 並びがそのまま着順の指定になる.
    let selections: [Int]
    let amount: Int
    let createdAt: Date
    /// CloudKit がサーバ側で打刻した作成時刻.
    ///
    /// 種の材料に使う. クライアントが選べる値ではないので, 狙った結果を
    /// 作ることができない(`HorseRaceResult.makeSeed` 参照).
    var serverCreatedAt: Date?

    init(
        id: String = UUID().uuidString,
        raceID: String,
        bettorID: UserID,
        kind: HorseRaceBetKind,
        selections: [Int],
        amount: Int,
        createdAt: Date = .now,
        serverCreatedAt: Date? = nil
    ) {
        self.id = id
        self.raceID = raceID
        self.bettorID = bettorID
        self.kind = kind
        self.selections = selections
        self.amount = amount
        self.createdAt = createdAt
        self.serverCreatedAt = serverCreatedAt
    }

    /// 買い目の表記(`3 → 1 → 5` / `2・7`).
    var selectionsText: String {
        kind.isOrdered
            ? selections.map(String.init).joined(separator: " → ")
            : selections.sorted().map(String.init).joined(separator: "・")
    }
}

// MARK: - 結果の確定

/// レースの種を確定させる 1 件.
///
/// recordName を `race-<開催日>` に固定しているので, 複数の端末が同時に
/// 作ろうとしてもサーバ側で 1 件しか作れない. これで全員が必ず同じ種を見る.
struct HorseRaceResult: Hashable, Sendable {

    let raceID: String
    let seed: String
    /// 種の材料にした馬券. 各端末が検算できるように残す.
    let betIDs: [String]
    let lockedAt: Date

    /// CloudKit の recordName.
    static func recordName(raceID: String) -> String { "race-\(raceID)" }

    var recordName: String { Self.recordName(raceID: raceID) }

    /// 締切時点で出そろった馬券から種を作る.
    ///
    /// 材料に使うのは, 馬券の中身と **CloudKit がサーバ側で打刻した作成時刻**.
    /// 作成時刻はクライアントが決められないので, 誰かが狙った結果になるまで
    /// 作り直す, ということができない. また最後に買う人も, 自分より後に
    /// 誰かが買えば種が変わるため, 結果を見越して買うことはできない.
    static func makeSeed(raceID: String, bets: [HorseRaceBet]) -> String {
        // 並び順で種が変わらないよう, 馬券 ID で整列してから混ぜる.
        let material = bets
            .sorted { $0.id < $1.id }
            .map { bet -> String in
                let stamp = (bet.serverCreatedAt ?? bet.createdAt).timeIntervalSince1970
                let selections = bet.selections.map(String.init).joined(separator: "-")
                return "\(bet.id)|\(bet.bettorID.rawValue)|\(bet.kind.rawValue)|\(selections)|\(bet.amount)|\(stamp)"
            }
            .joined(separator: "\n")

        let digest = SHA256.hash(data: Data("\(raceID)\n\(material)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 公表された種が, 材料どおりに作られたものかを確かめる.
    ///
    /// 確定レコードは作った人があとから書き換えられてしまうため(Public Database では
    /// 作成者に書き込み権限がある), 読んだ側でも必ず検算する.
    func isConsistent(with bets: [HorseRaceBet]) -> Bool {
        let included = bets.filter { betIDs.contains($0.id) }
        guard included.count == betIDs.count else { return false }
        return Self.makeSeed(raceID: raceID, bets: included) == seed
    }
}

// MARK: - レースの再現

/// 種から再現したレース 1 回ぶん.
///
/// 着順は「決めたもの」ではなく, ここで計算した走りのゴール順を読んだもの.
/// 画面はこの `position(of:at:)` の値をそのまま馬の位置に使うので,
/// 見えている走りと着順が食い違うことはない.
struct HorseRaceRun: Hashable, Sendable {

    let card: HorseRaceCard
    /// 着順(1 着から最下位まで)の馬番.
    let finishingOrder: [Int]
    /// 馬番ごとの, ゴール時点で進んだ距離(1 着が 1.0).
    let finalDistances: [Int: Double]
    /// 馬番ごとの走りの形.
    let paceExponents: [Int: Double]

    /// 上位 3 着.
    var topThree: [Int] { Array(finishingOrder.prefix(3)) }

    init(card: HorseRaceCard, seed: String) {
        self.card = card

        var generator = SeededGenerator(seed: Self.numericSeed(from: seed))

        // 1 着から順に, 能力の比で選んでいく. オッズを計算するときの考え方と
        // まったく同じなので, オッズと実際の勝ちやすさが必ず一致する.
        var remaining = card.horses
        var order: [Int] = []
        while !remaining.isEmpty {
            let total = remaining.reduce(0.0) { $0 + $1.weight }
            guard total > 0 else {
                order.append(contentsOf: remaining.map(\.number))
                break
            }
            let roll = Double(generator.next() % 1_000_000) / 1_000_000 * total
            var cursor = 0.0
            var pickedIndex = remaining.count - 1
            for (index, horse) in remaining.enumerated() {
                cursor += horse.weight
                if roll < cursor {
                    pickedIndex = index
                    break
                }
            }
            order.append(remaining[pickedIndex].number)
            remaining.remove(at: pickedIndex)
        }
        self.finishingOrder = order

        // 着差. 1 着を 1.0 とし, 後ろほど少しずつ手前で終わる.
        var distances: [Int: Double] = [:]
        var covered = 1.0
        for number in order {
            distances[number] = covered
            let gap = 0.006 + Double(generator.next() % 40) / 1000
            covered -= gap
        }
        self.finalDistances = distances

        // 走りの形. 同じ脚質の馬が寸分違わず同じ動きをしないよう少しだけ散らす.
        var exponents: [Int: Double] = [:]
        for horse in card.horses {
            let jitter = (Double(generator.next() % 160) / 1000) - 0.08
            exponents[horse.number] = max(horse.style.paceExponent + jitter, 0.5)
        }
        self.paceExponents = exponents
    }

    /// 進み具合(0 = スタート, 1 = 1 着のゴール地点)を返す.
    ///
    /// - Parameter progress: 演出の進み具合(0〜1).
    func position(of number: Int, at progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        let distance = finalDistances[number] ?? 0
        let exponent = paceExponents[number] ?? 1
        return distance * pow(clamped, exponent)
    }

    /// 何着か(1 から). 分からなければ nil.
    func rank(of number: Int) -> Int? {
        guard let index = finishingOrder.firstIndex(of: number) else { return nil }
        return index + 1
    }

    /// 馬券の払い戻し. 外れていれば 0.
    func payout(for bet: HorseRaceBet) -> Int {
        guard bet.kind.hits(selections: bet.selections, topThree: topThree) else { return 0 }
        let odds = card.odds(kind: bet.kind, selections: bet.selections)
        return Int((Double(bet.amount) * odds).rounded(.down))
    }

    /// 複数の馬券の払い戻しの合計.
    func totalPayout(for bets: [HorseRaceBet]) -> Int {
        bets.reduce(0) { $0 + payout(for: $1) }
    }

    /// 16 進の種を数値に変換する. 先頭 16 桁を使う.
    private static func numericSeed(from seed: String) -> UInt64 {
        let prefix = String(seed.prefix(16))
        if let value = UInt64(prefix, radix: 16) { return value }
        return ColorBattleSnapshot.hash(seed)
    }
}
