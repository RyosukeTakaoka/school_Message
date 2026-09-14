import Foundation

/// ブラックジャックの状態.
///
/// ## 作りをどこまで簡単にしたか
/// - 操作は HIT と STAND だけ(ダブルダウン・スプリット・保険は入れない).
/// - ディーラーは自動. 伏せカードは持たせず, **全員が引き終わってから**
///   17 以上になるまで引く. 伏せカードを持たせると「誰がその 1 枚を知るのか」を
///   決めなければならず, 人間のディーラーがいないこの作りでは筋が通らないため.
/// - 順番は決めない. 各自が好きなときに HIT / STAND できる
///   (プレイヤー同士は影響し合わないので, 待ち時間を作る意味がない).
///
/// 引く札はその都度, 引いた本人の端末の乱数で決めて記録する. 対戦 ID から
/// 導ける並びにすると, 引く前に次の札が分かってしまい HIT の判断が意味を失うため.
struct BlackjackSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    static let maxBet = 100
    /// ディーラーはこの数以上になるまで引く.
    static let dealerStandsAt = 17
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
        /// ディーラーの札. 最初は 1 枚だけ見えている.
        var dealerCards: [PlayingCard]
        /// ディーラーが引き終わったか.
        var isDealerDone: Bool

        var dealerValue: Int { BlackjackSnapshot.bestValue(of: dealerCards) }
        var isDealerBust: Bool { dealerValue > BlackjackSnapshot.blackjack }
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(ChipGameLobby)
        case playing(Round)
    }

    var gameID: String
    var hostID: UserID
    var phase: Phase

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

    var isFinished: Bool {
        round?.isDealerDone ?? false
    }

    /// 全員が引き終わり, あとはディーラーが引くだけの状態か.
    var isAwaitingDealer: Bool {
        guard let round, !round.isDealerDone else { return false }
        return round.playerIDs.allSatisfy { round.hands[$0]?.isDone ?? false }
    }

    func state(of userID: UserID) -> PlayerState? {
        round?.hands[userID]
    }

    func canAct(_ userID: UserID) -> Bool {
        guard let round, !round.isDealerDone else { return false }
        guard let state = round.hands[userID] else { return false }
        return !state.isDone
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
        return Round(
            playerIDs: playerIDs,
            bet: bet,
            hands: hands,
            dealerCards: [drawCard()],
            isDealerDone: false
        )
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

    /// ディーラーが引き終わるところまで進める. 全員が引き終わっていなければ nil.
    ///
    /// 誰の端末が呼んでも結果は同じ形になる(その時点で引き切ってしまう).
    func resolvingDealer() -> BlackjackSnapshot? {
        guard isAwaitingDealer, var round else { return nil }
        // 全員バーストしているならディーラーは引かなくてよい(勝負が付いている).
        let someoneAlive = round.playerIDs.contains { !(round.hands[$0]?.isBust ?? true) }
        if someoneAlive {
            var generator = SeededGenerator(
                seed: ColorBattleSnapshot.hash(Self.dealerSeed(gameID: gameID, round: round))
            )
            while Self.bestValue(of: round.dealerCards) < Self.dealerStandsAt {
                round.dealerCards.append(Self.drawCard(using: &generator))
            }
        }
        round.isDealerDone = true
        var next = self
        next.phase = .playing(round)
        return next
    }

    /// 確定した場の状態から作る種.
    ///
    /// 全員が引き終わってからでないと定まらないので, 先に覗いて HIT / STAND を
    /// 決めることはできない. 逆に, 全員が引き終わったあとはどの端末で計算しても
    /// 同じ並びになるため, 誰が先にディーラーを進めても結果が食い違わない.
    private static func dealerSeed(gameID: String, round: Round) -> String {
        let hands = round.playerIDs
            .map { playerID in
                let cards = (round.hands[playerID]?.cards ?? []).map(\.id).joined(separator: ",")
                return "\(playerID.rawValue):\(cards)"
            }
            .joined(separator: "|")
        let dealer = round.dealerCards.map(\.id).joined(separator: ",")
        return "\(gameID)#\(hands)#\(dealer)"
    }

    private static func drawCard(using generator: inout SeededGenerator) -> PlayingCard {
        let suits = PlayingSuit.allCases
        let ranks = PlayingRank.allCases
        let suit = suits[Int(generator.next() % UInt64(suits.count))]
        let rank = ranks[Int(generator.next() % UInt64(ranks.count))]
        return PlayingCard(suit: suit, rank: rank)
    }

    // MARK: - 精算

    /// ディーラーとの 1 対 1 の勝負なので, 参加者ごとに独立して計算する.
    var chipDeltas: [UserID: Int] {
        guard let round, round.isDealerDone else { return [:] }
        var deltas: [UserID: Int] = [:]
        for playerID in round.playerIDs {
            guard let state = round.hands[playerID] else { continue }
            deltas[playerID] = outcome(of: state, round: round).delta(bet: round.bet)
        }
        return deltas
    }

    enum Outcome: Hashable, Sendable {
        case win, lose, push

        var title: String {
            switch self {
            case .win: String(localized: "勝ち")
            case .lose: String(localized: "負け")
            case .push: String(localized: "引き分け")
            }
        }

        func delta(bet: Int) -> Int {
            switch self {
            case .win: bet
            case .lose: -bet
            case .push: 0
            }
        }
    }

    func outcome(of state: PlayerState, round: Round) -> Outcome {
        if state.isBust { return .lose }
        if round.isDealerBust { return .win }
        if state.bestValue > round.dealerValue { return .win }
        if state.bestValue < round.dealerValue { return .lose }
        return .push
    }

    func outcome(for userID: UserID) -> Outcome? {
        guard let round, round.isDealerDone, let state = round.hands[userID] else { return nil }
        return outcome(of: state, round: round)
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
