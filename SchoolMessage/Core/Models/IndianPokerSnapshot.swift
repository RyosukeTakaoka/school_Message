import Foundation

/// インディアンポーカーの状態(2 人).
///
/// ## 「自分だけ見えない」をどう作るか
/// 色勝負・大富豪では, 手札を**本人の公開鍵**で封じて本人以外に見せなかった.
/// インディアンポーカーはその逆で, 自分のカードだけが自分に見えない.
/// そこで封じる向きを入れ替え, **相手の公開鍵**で封じる.
/// 1 人目のカードは 2 人目だけが開けられ, 2 人目のカードは 1 人目だけが開けられる.
///
/// ## 決着のときにどう見せ合うか
/// 勝負(CALL)が揃った時点で, 「自分に見えている相手のカード」を各自が平文で
/// 書き込む. 自分のカードは最後まで自分では開けないので, 相手に開いてもらう形になる.
/// 先に行動した人のカードは後から行動した人がその場で公開し, 残り 1 枚は
/// 先に行動した人の端末が自動で公開する(画面を開いていれば数秒で揃う).
/// 降りた(FOLD)場合は勝負にならないので, カードは伏せたまま終わる.
struct IndianPokerSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    static let maxBet = 100

    enum Action: String, Hashable, Sendable, Codable {
        /// 勝負する.
        case call
        /// 降りる(その時点で負け).
        case fold

        var title: String {
            switch self {
            case .call: String(localized: "勝負する")
            case .fold: String(localized: "降りる")
            }
        }
    }

    struct Round: Hashable, Sendable, Codable {
        var firstPlayerID: UserID
        var secondPlayerID: UserID
        var bet: Int
        /// 1 人目のカードを**2 人目の公開鍵**で封じたもの(2 人目だけが開ける).
        var firstCardSealedToSecond: WrappedConversationKey
        /// 2 人目のカードを**1 人目の公開鍵**で封じたもの(1 人目だけが開ける).
        var secondCardSealedToFirst: WrappedConversationKey
        var firstAction: Action?
        var secondAction: Action?
        /// 決着後に公開された 1 人目のカード(公開するのは 2 人目).
        var revealedFirstCard: PlayingCard?
        /// 決着後に公開された 2 人目のカード(公開するのは 1 人目).
        var revealedSecondCard: PlayingCard?
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

    static func newLobby(hostID: UserID, bet: Int) -> IndianPokerSnapshot {
        IndianPokerSnapshot(
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
        case .playing(let round): [round.firstPlayerID, round.secondPlayerID]
        }
    }

    /// 降りた人がいれば決着. どちらも勝負なら, 2 枚とも公開されてから決着.
    var isFinished: Bool {
        guard let round else { return false }
        if round.firstAction == .fold || round.secondAction == .fold { return true }
        guard round.firstAction == .call, round.secondAction == .call else { return false }
        return round.revealedFirstCard != nil && round.revealedSecondCard != nil
    }

    /// 両者が行動を済ませ, あとは見せ合うだけの状態か.
    var isAwaitingReveal: Bool {
        guard let round else { return false }
        guard round.firstAction == .call, round.secondAction == .call else { return false }
        return round.revealedFirstCard == nil || round.revealedSecondCard == nil
    }

    func action(of userID: UserID) -> Action? {
        guard let round else { return nil }
        if userID == round.firstPlayerID { return round.firstAction }
        if userID == round.secondPlayerID { return round.secondAction }
        return nil
    }

    func opponentID(of userID: UserID) -> UserID? {
        guard let round else { return nil }
        if userID == round.firstPlayerID { return round.secondPlayerID }
        if userID == round.secondPlayerID { return round.firstPlayerID }
        return nil
    }

    func isPlayer(_ userID: UserID) -> Bool {
        playerIDs.contains(userID)
    }

    /// 相手のカード. 自分の鍵で開けられるのは相手のぶんだけ.
    func decryptedOpponentCard(for userID: UserID, crypto: CryptoService) async throws -> PlayingCard? {
        guard let round else { return nil }
        let sealed: WrappedConversationKey
        if userID == round.firstPlayerID {
            sealed = round.secondCardSealedToFirst
        } else if userID == round.secondPlayerID {
            sealed = round.firstCardSealedToSecond
        } else {
            return nil
        }
        let data = try await crypto.openSealedToSelf(sealed)
        return try JSONDecoder().decode(PlayingCard.self, from: data)
    }

    /// 自分のカード(決着して公開されたあとだけ分かる).
    func revealedCard(of userID: UserID) -> PlayingCard? {
        guard let round else { return nil }
        if userID == round.firstPlayerID { return round.revealedFirstCard }
        if userID == round.secondPlayerID { return round.revealedSecondCard }
        return nil
    }

    /// 勝った人. 引き分けなら nil.
    var winnerID: UserID? {
        guard let round, isFinished else { return nil }
        if round.firstAction == .fold { return round.secondPlayerID }
        if round.secondAction == .fold { return round.firstPlayerID }
        guard let first = round.revealedFirstCard, let second = round.revealedSecondCard else { return nil }
        let firstStrength = first.rank.indianPokerStrength
        let secondStrength = second.rank.indianPokerStrength
        if firstStrength == secondStrength { return nil }
        return firstStrength > secondStrength ? round.firstPlayerID : round.secondPlayerID
    }

    /// 引き分け(同じ強さで見せ合った)か.
    var isDraw: Bool {
        guard let round, isFinished else { return false }
        guard round.firstAction == .call, round.secondAction == .call else { return false }
        return winnerID == nil
    }

    // MARK: - 開始

    /// 参加者が揃ったので配る. 1 枚ずつ, **相手の公開鍵**で封じる.
    static func startRound(
        gameID: String,
        first: UserID,
        second: UserID,
        bet: Int,
        firstPublicKey: Data,
        secondPublicKey: Data,
        crypto: CryptoService
    ) async throws -> Round {
        var deck: [PlayingCard] = []
        for suit in PlayingSuit.allCases {
            for rank in PlayingRank.allCases {
                deck.append(PlayingCard(suit: suit, rank: rank))
            }
        }
        // 対戦 ID から導ける並びにすると, 配る前に結果が分かってしまうため,
        // ここは端末の乱数で選ぶ.
        deck.shuffle()
        let firstCard = deck[0]
        let secondCard = deck[1]

        return Round(
            firstPlayerID: first,
            secondPlayerID: second,
            bet: bet,
            firstCardSealedToSecond: try await crypto.sealToPublicKey(
                JSONEncoder().encode(firstCard), recipientPublicKey: secondPublicKey
            ),
            secondCardSealedToFirst: try await crypto.sealToPublicKey(
                JSONEncoder().encode(secondCard), recipientPublicKey: firstPublicKey
            ),
            firstAction: nil,
            secondAction: nil,
            revealedFirstCard: nil,
            revealedSecondCard: nil
        )
    }

    // MARK: - 手を進める

    /// 勝負する / 降りる.
    ///
    /// 相手がすでに行動していれば, 同時に相手のカードを公開する
    /// (相手はもう選び終わっているので, ここで公開しても選択に影響しない).
    func acting(
        _ action: Action,
        by userID: UserID,
        revealingOpponentCard opponentCard: PlayingCard?
    ) -> IndianPokerSnapshot? {
        guard var round, !isFinished else { return nil }
        let isFirst = userID == round.firstPlayerID
        let isSecond = userID == round.secondPlayerID
        guard isFirst || isSecond else { return nil }
        guard (isFirst ? round.firstAction : round.secondAction) == nil else { return nil }

        let opponentHasActed = (isFirst ? round.secondAction : round.firstAction) != nil

        if isFirst {
            round.firstAction = action
        } else {
            round.secondAction = action
        }

        // 見せ合いになるのは, 双方が勝負を選んだときだけ.
        if action == .call, opponentHasActed, let opponentCard {
            if isFirst {
                round.revealedSecondCard = opponentCard
            } else {
                round.revealedFirstCard = opponentCard
            }
        }

        var next = self
        next.phase = .playing(round)
        return next
    }

    /// 見せ合いの残り 1 枚を公開する(相手のカードを開けられる側が呼ぶ).
    func revealing(opponentCard: PlayingCard, by userID: UserID) -> IndianPokerSnapshot? {
        guard var round, isAwaitingReveal else { return nil }
        if userID == round.firstPlayerID {
            guard round.revealedSecondCard == nil else { return nil }
            round.revealedSecondCard = opponentCard
        } else if userID == round.secondPlayerID {
            guard round.revealedFirstCard == nil else { return nil }
            round.revealedFirstCard = opponentCard
        } else {
            return nil
        }
        var next = self
        next.phase = .playing(round)
        return next
    }

    /// 精算. 勝った人が相手のぶんを受け取る.
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }
        guard let winnerID else {
            return [round.firstPlayerID: 0, round.secondPlayerID: 0]
        }
        let loserID = winnerID == round.firstPlayerID ? round.secondPlayerID : round.firstPlayerID
        return [winnerID: round.bet, loserID: -round.bet]
    }
}

extension PlayingRank {
    /// インディアンポーカーでの強さ. 大富豪と違い A が一番強く, 2 が一番弱い.
    var indianPokerStrength: Int {
        self == .two ? 2 : rawValue
    }
}
