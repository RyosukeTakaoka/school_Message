import Foundation

/// チンチロの役.
///
/// 一般的なチンチロと違い, このアプリでは**振り直しをしない**(1 回だけ振る).
/// 親も置かず, 各自が自分の役の倍率でそのまま精算する. 覚えることを減らして,
/// 休み時間に 1 分で遊べることを優先した.
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

    /// 賭けた額に掛ける倍率. マイナスは支払い.
    var multiplier: Int {
        switch self {
        case .pinzoro: 5
        case .triple: 3
        case .shigoro: 2
        case .number: 1
        case .hifumi: -2
        case .noHand: 0
        }
    }

    /// 強い順の並び(結果一覧の並べ替えに使う). 大きいほど強い.
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
/// 参加者それぞれが 1 回ずつ振り, 自分の役の倍率で精算する(親なし).
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

    /// 精算. 各自の役の倍率をそのまま賭け額に掛ける(親なし).
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }
        var deltas: [UserID: Int] = [:]
        for playerID in round.playerIDs {
            guard let roll = round.rolls[playerID] else { continue }
            deltas[playerID] = round.bet * roll.hand.multiplier
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
