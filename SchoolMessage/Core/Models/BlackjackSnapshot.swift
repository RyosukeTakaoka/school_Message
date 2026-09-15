import Foundation

/// ブラックジャックの状態(2 人以上).
///
/// ## ディーラーを置かない理由
/// 人間のディーラーがいないので, ディーラーを置くと誰かの端末がその役を代行する
/// ことになる. そうすると
/// - 勝ち負けが「人と人」ではなくなり, 対戦している感じがしない
/// - 全員がディーラーに勝つと, どこからともなく CHIP が増えてしまう
/// という 2 つの問題が出る. そこで**参加者どうしの勝負**にして,
/// 21 を超えなかった人のうち一番大きい人が, 全員の賭けを総取りする形にした.
/// 負けた人が出した分をそのまま勝った人が受け取るので, CHIP の総量は変わらない.
///
/// ## 作りをどこまで簡単にしたか
/// - 操作は HIT と STAND だけ(ダブルダウン・スプリット・保険は入れない).
/// - 順番は決めない. 各自が好きなときに HIT / STAND できる
///   (ほかの人の点数は見えるので, それを見ながら決められる).
///
/// 引く札はその都度, 引いた本人の端末の乱数で決めて記録する. 対戦 ID から
/// 導ける並びにすると, 引く前に次の札が分かってしまい HIT の判断が意味を失うため.
struct BlackjackSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    static let maxBet = 100
    static let blackjack = 21

    struct PlayerState: Hashable, Sendable, Codable {
        var cards: [PlayingCard]
        var isStanding: Bool

        var bestValue: Int { BlackjackSnapshot.bestValue(of: cards) }
        var isBust: Bool { bestValue > BlackjackSnapshot.blackjack }
        /// これ以上引けない(STAND したかバーストした)か.
        var isDone: Bool { isStanding || isBust }
    }

    struct Round: Hashable, Sendable, Codable {
        var playerIDs: [UserID]
        var bet: Int
        var hands: [UserID: PlayerState]
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(ChipGameLobby)
        case playing(Round)
    }

    var gameID: String
    var hostID: UserID
    var phase: Phase

    /// 募集を取り消したか. Optional なのは, この項目が無い頃に送られた
    /// メッセージも読めるようにするため(`nil` は「取り消されていない」).
    var isCancelled: Bool? = nil

    static func newLobby(hostID: UserID, bet: Int) -> BlackjackSnapshot {
        BlackjackSnapshot(
            gameID: UUID().uuidString,
            hostID: hostID,
            phase: .lobby(ChipGameLobby(hostID: hostID, bet: bet))
        )
    }

    // MARK: - 参照

    var lobby: ChipGameLobby? {
        if case .lobby(let lobby) = phase { return lobby }
        return nil
    }

    var round: Round? {
        if case .playing(let round) = phase { return round }
        return nil
    }

    var bet: Int {
        switch phase {
        case .lobby(let lobby): lobby.bet
        case .playing(let round): round.bet
        }
    }

    var playerIDs: [UserID] {
        switch phase {
        case .lobby(let lobby): lobby.joinedPlayerIDs
        case .playing(let round): round.playerIDs
        }
    }

    /// 全員が止めるかバーストしたら決着.
    var isFinished: Bool {
        guard let round else { return false }
        return round.playerIDs.allSatisfy { round.hands[$0]?.isDone ?? false }
    }

    func state(of userID: UserID) -> PlayerState? {
        round?.hands[userID]
    }

    func canAct(_ userID: UserID) -> Bool {
        guard let round, !isFinished else { return false }
        guard let state = round.hands[userID] else { return false }
        return !state.isDone
    }

    /// 勝った人. 21 を超えなかった人のうち一番大きい点数の人(同点なら全員).
    /// 全員バーストなら空.
    var winnerIDs: [UserID] {
        guard let round, isFinished else { return [] }
        let alive = round.playerIDs.filter { !(round.hands[$0]?.isBust ?? true) }
        guard let best = alive.compactMap({ round.hands[$0]?.bestValue }).max() else { return [] }
        return alive.filter { round.hands[$0]?.bestValue == best }
    }

    enum Outcome: Hashable, Sendable {
        case win, lose, draw

        var title: String {
            switch self {
            case .win: String(localized: "勝ち")
            case .lose: String(localized: "負け")
            case .draw: String(localized: "引き分け")
            }
        }
    }

    func outcome(for userID: UserID) -> Outcome? {
        guard isFinished, round?.hands[userID] != nil else { return nil }
        let winners = winnerIDs
        // 全員バーストなら勝った人がいないので, 全員引き分け扱い.
        guard !winners.isEmpty else { return .draw }
        guard winners.contains(userID) else { return .lose }
        return winners.count == 1 ? .win : .draw
    }

    // MARK: - 札の数え方

    /// A を 11 として数え, 21 を超えるなら 1 に読み替える.
    static func bestValue(of cards: [PlayingCard]) -> Int {
        var total = cards.reduce(0) { $0 + $1.rank.blackjackValue }
        var aceCount = cards.filter { $0.rank == .ace }.count
        while total > blackjack, aceCount > 0 {
            total -= 10
            aceCount -= 1
        }
        return total
    }

    /// 1 枚引く. 山札は持たず, その場の乱数で決める(引く前に次が分からないように).
    static func drawCard() -> PlayingCard {
        PlayingCard(
            suit: PlayingSuit.allCases.randomElement() ?? .spade,
            rank: PlayingRank.allCases.randomElement() ?? .ace
        )
    }

    // MARK: - 開始

    static func startRound(playerIDs: [UserID], bet: Int) -> Round {
        var hands: [UserID: PlayerState] = [:]
        for playerID in playerIDs {
            hands[playerID] = PlayerState(cards: [drawCard(), drawCard()], isStanding: false)
        }
        return Round(playerIDs: playerIDs, bet: bet, hands: hands)
    }

    // MARK: - 手を進める

    func hitting(by userID: UserID, card: PlayingCard = BlackjackSnapshot.drawCard()) -> BlackjackSnapshot? {
        guard var round, canAct(userID), var state = round.hands[userID] else { return nil }
        state.cards.append(card)
        round.hands[userID] = state
        var next = self
        next.phase = .playing(round)
        return next
    }

    func standing(by userID: UserID) -> BlackjackSnapshot? {
        guard var round, canAct(userID), var state = round.hands[userID] else { return nil }
        state.isStanding = true
        round.hands[userID] = state
        var next = self
        next.phase = .playing(round)
        return next
    }

    // MARK: - 精算

    /// 負けた人が出した分を, 勝った人で分ける.
    ///
    /// 全員が同じ額を賭けているので, 「負けた人数 × 賭け額」が勝った人の取り分に
    /// なる. 同点で勝った人が複数いるときは山分けし, 割り切れない端数は
    /// 並び順の先頭から 1 ずつ足して総量を合わせる(CHIP が増減しないように).
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }
        let winners = winnerIDs
        guard !winners.isEmpty else {
            // 全員バースト. 誰も勝っていないので増減なし.
            return Dictionary(uniqueKeysWithValues: round.playerIDs.map { ($0, 0) })
        }

        var deltas: [UserID: Int] = [:]
        let losers = round.playerIDs.filter { !winners.contains($0) }
        for loser in losers {
            deltas[loser] = -round.bet
        }

        let pot = round.bet * losers.count
        let share = pot / winners.count
        let remainder = pot % winners.count
        for (index, winner) in winners.enumerated() {
            deltas[winner] = share + (index < remainder ? 1 : 0)
        }
        return deltas
    }
}

extension PlayingRank {
    /// ブラックジャックでの点数. 絵札は 10, A はいったん 11 として数える.
    var blackjackValue: Int {
        switch self {
        case .two: 2
        case .jack, .queen, .king: 10
        case .ace: 11
        default: rawValue
        }
    }
}
