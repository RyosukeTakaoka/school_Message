import Foundation

/// チンチロの役.
///
/// 一般的なチンチロと違い, このアプリでは**振り直しをしない**(1 回だけ振る)し,
/// **親も置かない**. 覚えることを減らして, 休み時間に 1 分で遊べることを優先した.
///
/// 役の強さの比較(`strength`)だけを使い, 一番強い役を出した人が全員の賭けを
/// 総取りする(`ChinchiroSnapshot.chipDeltas` 参照). 以前は各自が自分の役の
/// 倍率でその場で精算していたが, その形だと全員が弱い役(ヒフミなど)を出すと
/// **全員が損をする**(CHIP がどこにも移動せず消える)ことがあり, 賭け事として
/// 不自然だったため, 総取り方式に変えた.
enum ChinchiroHand: Hashable, Sendable, Codable {
    /// 1-1-1.
    case pinzoro
    /// 1 以外のゾロ目.
    case triple(Int)
    /// 4-5-6.
    case shigoro
    /// 2 つ同じで, 残りの 1 つが「目」になる.
    case number(Int)
    /// 1-2-3.
    case hifumi
    /// どれにも当てはまらない.
    case noHand

    /// 出目 3 つから役を決める.
    static func evaluate(_ dice: [Int]) -> ChinchiroHand {
        guard dice.count == 3 else { return .noHand }
        let sorted = dice.sorted()

        if sorted[0] == sorted[2] {
            return sorted[0] == 1 ? .pinzoro : .triple(sorted[0])
        }
        if sorted == [4, 5, 6] { return .shigoro }
        if sorted == [1, 2, 3] { return .hifumi }
        if sorted[0] == sorted[1] { return .number(sorted[2]) }
        if sorted[1] == sorted[2] { return .number(sorted[0]) }
        return .noHand
    }

    var title: String {
        switch self {
        case .pinzoro: String(localized: "ピンゾロ")
        case .triple(let value): String(localized: "\(value)のゾロ目")
        case .shigoro: String(localized: "シゴロ")
        case .number(let value): String(localized: "\(value)の目")
        case .hifumi: String(localized: "ヒフミ")
        case .noHand: String(localized: "目無し")
        }
    }

    /// 強い順の並び(結果一覧の並べ替えと, 総取りする人の判定に使う). 大きいほど強い.
    var strength: Int {
        switch self {
        case .pinzoro: 100
        case .triple(let value): 80 + value
        case .shigoro: 70
        case .number(let value): 10 + value
        case .noHand: 5
        case .hifumi: 0
        }
    }
}

/// 1 人ぶんの出目.
struct ChinchiroRoll: Hashable, Sendable, Codable {
    var dice: [Int]
    var rolledAt: Date

    var hand: ChinchiroHand { ChinchiroHand.evaluate(dice) }

    /// その場で 3 個振る. 出目は振った本人の端末で決める
    /// (対戦 ID から導ける並びにすると, 振る前に結果が分かってしまうため).
    static func roll(now: Date = .now) -> ChinchiroRoll {
        ChinchiroRoll(dice: (0..<3).map { _ in Int.random(in: 1...6) }, rolledAt: now)
    }
}

/// チンチロの状態.
///
/// 参加者それぞれが 1 回ずつ振り, 一番強い役を出した人が総取りする(親なし).
/// 順番は決めず, 振っていない人は好きなときに振れる.
struct ChinchiroSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    static let maxBet = 100

    struct Round: Hashable, Sendable, Codable {
        var playerIDs: [UserID]
        var bet: Int
        /// 振り終わった人の出目.
        var rolls: [UserID: ChinchiroRoll]
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(ChipGameLobby)
        case rolling(Round)
    }

    var gameID: String
    var hostID: UserID
    var phase: Phase

    /// 募集を取り消したか. Optional なのは, この項目が無い頃に送られた
    /// メッセージも読めるようにするため(`nil` は「取り消されていない」).
    var isCancelled: Bool? = nil

    static func newLobby(hostID: UserID, bet: Int) -> ChinchiroSnapshot {
        ChinchiroSnapshot(
            gameID: UUID().uuidString,
            hostID: hostID,
            phase: .lobby(ChipGameLobby(hostID: hostID, bet: bet))
        )
    }

    var round: Round? {
        if case .rolling(let round) = phase { return round }
        return nil
    }

    var lobby: ChipGameLobby? {
        if case .lobby(let lobby) = phase { return lobby }
        return nil
    }

    /// 全員が振り終わったら終了.
    var isFinished: Bool {
        guard let round else { return false }
        return round.playerIDs.allSatisfy { round.rolls[$0] != nil }
    }

    var bet: Int {
        switch phase {
        case .lobby(let lobby): lobby.bet
        case .rolling(let round): round.bet
        }
    }

    var playerIDs: [UserID] {
        switch phase {
        case .lobby(let lobby): lobby.joinedPlayerIDs
        case .rolling(let round): round.playerIDs
        }
    }

    func hasRolled(_ userID: UserID) -> Bool {
        round?.rolls[userID] != nil
    }

    /// 振った結果を書き込んだ次の状態. 振れない場面なら nil.
    func rolling(by userID: UserID, roll: ChinchiroRoll = .roll()) -> ChinchiroSnapshot? {
        guard var round, round.playerIDs.contains(userID), round.rolls[userID] == nil else { return nil }
        round.rolls[userID] = roll
        var next = self
        next.phase = .rolling(round)
        return next
    }

    /// 一番強い役を出した人(同着なら複数). 全員が振り終わっていなければ空.
    var winnerIDs: [UserID] {
        guard let round, isFinished else { return [] }
        guard let best = round.playerIDs.compactMap({ round.rolls[$0]?.hand.strength }).max() else { return [] }
        return round.playerIDs.filter { round.rolls[$0]?.hand.strength == best }
    }

    /// 精算. 一番強い役を出した人が, 全員の賭けを総取りする(親なし).
    ///
    /// ブラックジャックの対人戦と同じ考え方. 全員が同じ額を賭けるので,
    /// 「負けた人数 × 賭け額」がそのまま勝った人の取り分になる. 同着で
    /// 勝った人が複数いれば山分けし, 割り切れない端数は並び順の先頭から
    /// 1 ずつ足して総量を合わせる(CHIP の総量が変わらないように).
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }
        let winners = winnerIDs
        guard !winners.isEmpty else { return [:] }

        var deltas: [UserID: Int] = [:]
        let losers = round.playerIDs.filter { !winners.contains($0) }
        for loser in losers {
            deltas[loser] = -round.bet
        }

        // 全員が同着(全員が同じ強さ)なら, 出し合った分がそのまま戻るだけ.
        guard !losers.isEmpty else {
            return Dictionary(uniqueKeysWithValues: round.playerIDs.map { ($0, 0) })
        }

        let pot = round.bet * losers.count
        let share = pot / winners.count
        let remainder = pot % winners.count
        for (index, winner) in winners.enumerated() {
            deltas[winner] = share + (index < remainder ? 1 : 0)
        }
        return deltas
    }

    /// 結果一覧の並び(強い順).
    var resultsByStrength: [(playerID: UserID, roll: ChinchiroRoll)] {
        guard let round else { return [] }
        return round.playerIDs
            .compactMap { playerID in round.rolls[playerID].map { (playerID, $0) } }
            .sorted { $0.1.hand.strength > $1.1.hand.strength }
    }
}
