import Foundation
import CryptoKit

/// ダウトの状態(3 人以上).
///
/// ## 伏せた札をどう「後から検証できる形」で隠すか
/// 場に伏せた札をそのまま平文で載せると, 中身を見れば嘘かどうか分かってしまい,
/// ブラフが成立しない. かといって出した本人の鍵で封じるだけだと,
/// ダウトされた後で本人が別の札にすり替えられる余地が残る.
///
/// そこで, 出すときに**使い捨ての共通鍵**を 1 つ作り,
/// - 実際の札はその鍵で暗号化して場に置く(`cardsCipher`)
/// - 鍵そのものは出した本人の公開鍵で封じておく(`keySealedToPlayer`)
/// という形にする. ダウトされたら本人が**鍵だけを公開**し, 全員が同じ暗号文を
/// 開いて確かめる. 暗号文は出した時点で場に置かれているので, 後から中身を
/// 差し替えることはできない. 使うのは既存の `CryptoService` の仕組みだけで,
/// 新しい暗号方式は作っていない.
///
/// ## 簡単にしたところ
/// - 場に残るのは**直前のプレイだけ**(それ以前は捨て札になる).
///   古いプレイまで受け取らせるには, 出した人全員に鍵を公開してもらう必要があり,
///   1 回のダウトで人数ぶんの往復が要るため.
/// - 手札が 0 枚になるプレイだけは, その場で鍵も一緒に公開する.
///   最後の 1 枚だけ嘘をついて勝ち逃げできないようにするため.
struct DoubtSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 3
    static let maxBet = 50
    /// 1 回に出せる枚数の上限.
    static let maxPlayCount = 4

    /// 場に伏せられている直前のプレイ.
    struct Play: Hashable, Sendable, Codable {
        var playerID: UserID
        /// 「この数字だ」と宣言した内容. 本当かどうかは分からない.
        var claimedRank: PlayingRank
        var count: Int
        /// 使い捨ての鍵で暗号化した, 実際に出した札.
        var cardsCipher: Data
        /// その使い捨ての鍵を, 出した本人の公開鍵で封じたもの.
        var keySealedToPlayer: WrappedConversationKey
        /// ダウトされたときに本人が公開した鍵.
        var revealedKey: Data?
        /// 公開された実際の札.
        var revealedCards: [PlayingCard]?

        var isRevealed: Bool { revealedCards != nil }
    }

    /// 直前のダウトの結末(画面に出す).
    struct Verdict: Hashable, Sendable, Codable {
        var callerID: UserID
        var playerID: UserID
        var claimedRank: PlayingRank
        var actualCards: [PlayingCard]
        /// 宣言が嘘だったか.
        var wasLying: Bool
        /// 札を引き取ることになった人.
        var penalizedID: UserID
    }

    struct Round: Hashable, Sendable, Codable {
        /// 席順 = 手番の順.
        var seating: [UserID]
        /// 本人の公開鍵で封じた手札.
        var sealedHands: [UserID: WrappedConversationKey]
        /// 受け取り待ちの札(ダウトの罰で引き取る分. すでに公開済みなので平文でよい).
        var pendingPickups: [UserID: [PlayingCard]]
        var handCounts: [UserID: Int]
        var bet: Int
        var currentPlayerID: UserID
        /// 次に出す人が宣言しなければならない数字.
        var requiredRank: PlayingRank
        var lastPlay: Play?
        /// ダウトを宣言した人(まだ鍵が公開されていない間だけ入る).
        var doubtCallerID: UserID?
        var lastVerdict: Verdict?
        var winnerID: UserID?
        var isFinished: Bool
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(ChipGameLobby)
        case round(Round)
    }

    var gameID: String
    var hostID: UserID
    var phase: Phase

    /// 募集を取り消したか. Optional なのは, この項目が無い頃に送られた
    /// メッセージも読めるようにするため(`nil` は「取り消されていない」).
    var isCancelled: Bool? = nil

    static func newLobby(hostID: UserID, bet: Int) -> DoubtSnapshot {
        DoubtSnapshot(
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
        if case .round(let round) = phase { return round }
        return nil
    }

    var isFinished: Bool { round?.isFinished ?? false }

    var bet: Int {
        switch phase {
        case .lobby(let lobby): lobby.bet
        case .round(let round): round.bet
        }
    }

    var playerIDs: [UserID] {
        switch phase {
        case .lobby(let lobby): lobby.joinedPlayerIDs
        case .round(let round): round.seating
        }
    }

    func isTurn(of userID: UserID) -> Bool {
        guard let round, !round.isFinished else { return false }
        return round.currentPlayerID == userID && round.doubtCallerID == nil
    }

    /// いまダウトを宣言できるか(出した本人以外・公開待ちでない).
    func canCallDoubt(_ userID: UserID) -> Bool {
        guard let round, !round.isFinished else { return false }
        guard let play = round.lastPlay, !play.isRevealed else { return false }
        guard round.doubtCallerID == nil else { return false }
        return round.seating.contains(userID) && play.playerID != userID
    }

    /// 鍵の公開待ちか(ダウトされた本人の端末が公開する).
    func isAwaitingReveal(by userID: UserID) -> Bool {
        guard let round, round.doubtCallerID != nil, let play = round.lastPlay else { return false }
        return !play.isRevealed && play.playerID == userID
    }

    func handCount(for userID: UserID) -> Int {
        round?.handCounts[userID] ?? 0
    }

    /// 自分の手札. 受け取り待ちの札があれば合わせて返す.
    func decryptedHand(for userID: UserID, crypto: CryptoService) async throws -> [PlayingCard] {
        guard let round else { return [] }
        var hand: [PlayingCard] = []
        if let sealed = round.sealedHands[userID] {
            let data = try await crypto.openSealedToSelf(sealed)
            hand = try JSONDecoder().decode([PlayingCard].self, from: data)
        }
        hand.append(contentsOf: round.pendingPickups[userID] ?? [])
        return hand.sortedForDoubtDisplay()
    }

    // MARK: - 開始

    static func startRound(
        seating: [UserID],
        bet: Int,
        publicKeys: [UserID: Data],
        crypto: CryptoService
    ) async throws -> Round? {
        guard seating.count >= minimumPlayers else { return nil }

        var deck: [PlayingCard] = []
        for suit in PlayingSuit.allCases {
            for rank in PlayingRank.allCases {
                deck.append(PlayingCard(suit: suit, rank: rank))
            }
        }
        deck.shuffle()

        var sealedHands: [UserID: WrappedConversationKey] = [:]
        var handCounts: [UserID: Int] = [:]
        let base = deck.count / seating.count
        let remainder = deck.count % seating.count
        var cursor = 0
        for (index, playerID) in seating.enumerated() {
            guard let publicKey = publicKeys[playerID] else { return nil }
            let count = base + (index < remainder ? 1 : 0)
            let hand = Array(deck[cursor..<(cursor + count)]).sortedForDoubtDisplay()
            cursor += count
            sealedHands[playerID] = try await crypto.sealToPublicKey(
                JSONEncoder().encode(hand), recipientPublicKey: publicKey
            )
            handCounts[playerID] = hand.count
        }

        return Round(
            seating: seating,
            sealedHands: sealedHands,
            pendingPickups: [:],
            handCounts: handCounts,
            bet: bet,
            currentPlayerID: seating[0],
            requiredRank: .three,
            lastPlay: nil,
            doubtCallerID: nil,
            lastVerdict: nil,
            winnerID: nil,
            isFinished: false
        )
    }

    // MARK: - 手を進める

    /// 札を伏せて出す. 宣言する数字は場が決めた `requiredRank` で固定
    /// (持っていなければ嘘をつくしかない, というのがこの遊びの肝).
    ///
    /// 手札が 0 枚になる場合は, その場で使い捨ての鍵も公開して上がりを確定させる.
    func playing(
        _ cards: [PlayingCard],
        by userID: UserID,
        crypto: CryptoService
    ) async throws -> DoubtSnapshot? {
        guard var round, isTurn(of: userID) else { return nil }
        guard !cards.isEmpty, cards.count <= Self.maxPlayCount else { return nil }

        var hand = try await decryptedHand(for: userID, crypto: crypto)
        for card in cards {
            guard let index = hand.firstIndex(of: card) else { return nil }
            hand.remove(at: index)
        }

        let myPublicKey = try await crypto.identityPublicKeyData()
        round.sealedHands[userID] = try await crypto.sealToPublicKey(
            JSONEncoder().encode(hand), recipientPublicKey: myPublicKey
        )
        round.pendingPickups[userID] = nil
        round.handCounts[userID] = hand.count

        // 使い捨ての鍵で封じて場に置く.
        let onceKey = await crypto.makeConversationKey()
        let keyBytes = onceKey.withUnsafeBytes { Data($0) }
        let cipher = try await crypto.seal(JSONEncoder().encode(cards), with: onceKey)
        let sealedKey = try await crypto.sealToPublicKey(keyBytes, recipientPublicKey: myPublicKey)

        var play = Play(
            playerID: userID,
            claimedRank: round.requiredRank,
            count: cards.count,
            cardsCipher: cipher,
            keySealedToPlayer: sealedKey,
            revealedKey: nil,
            revealedCards: nil
        )

        let isGoingOut = hand.isEmpty
        if isGoingOut {
            // 上がるプレイだけは隠す意味が無い. その場で公開して真偽を確定させる.
            play.revealedKey = keyBytes
            play.revealedCards = cards
        }

        round.lastPlay = play
        round.doubtCallerID = nil
        round.lastVerdict = nil

        if isGoingOut {
            let wasHonest = cards.allSatisfy { $0.rank == play.claimedRank }
            if wasHonest {
                round.winnerID = userID
                round.isFinished = true
            } else {
                // 嘘で上がろうとしたので, 出した札を引き取って続行.
                round.pendingPickups[userID, default: []].append(contentsOf: cards)
                round.handCounts[userID] = (round.handCounts[userID] ?? 0) + cards.count
                round.lastVerdict = Verdict(
                    callerID: userID,
                    playerID: userID,
                    claimedRank: play.claimedRank,
                    actualCards: cards,
                    wasLying: true,
                    penalizedID: userID
                )
                round.lastPlay = nil
                round.requiredRank = Self.nextRank(after: round.requiredRank)
                // 引き取った本人がそのまま次も出す.
            }
        } else {
            round.requiredRank = Self.nextRank(after: round.requiredRank)
            round.currentPlayerID = Self.nextPlayer(after: userID, in: round.seating)
        }

        var next = self
        next.phase = .round(round)
        return next
    }

    /// ダウトを宣言する. 実際の判定は, 出した本人が鍵を公開してから.
    func callingDoubt(by userID: UserID) -> DoubtSnapshot? {
        guard var round, canCallDoubt(userID) else { return nil }
        round.doubtCallerID = userID
        var next = self
        next.phase = .round(round)
        return next
    }

    /// ダウトされた本人が鍵を公開し, 勝敗を確定させる.
    func revealing(by userID: UserID, crypto: CryptoService) async throws -> DoubtSnapshot? {
        guard var round, let play = round.lastPlay, let callerID = round.doubtCallerID else { return nil }
        guard play.playerID == userID, !play.isRevealed else { return nil }

        // 出したときに封じた使い捨ての鍵を開け, その鍵で場の暗号文を開く.
        // 暗号文は出した時点で場に置かれているので, 中身をすり替えることはできない.
        let keyBytes = try await crypto.openSealedToSelf(play.keySealedToPlayer)
        let key = SymmetricKey(data: keyBytes)
        let plaintext = try await crypto.open(play.cardsCipher, with: key)
        let actualCards = try JSONDecoder().decode([PlayingCard].self, from: plaintext)

        let wasLying = !actualCards.allSatisfy { $0.rank == play.claimedRank }
        // 嘘なら出した人が, そうでなければ宣言した人が引き取る.
        let penalizedID = wasLying ? play.playerID : callerID

        round.pendingPickups[penalizedID, default: []].append(contentsOf: actualCards)
        round.handCounts[penalizedID] = (round.handCounts[penalizedID] ?? 0) + actualCards.count
        round.lastVerdict = Verdict(
            callerID: callerID,
            playerID: play.playerID,
            claimedRank: play.claimedRank,
            actualCards: actualCards,
            wasLying: wasLying,
            penalizedID: penalizedID
        )
        round.lastPlay = nil
        round.doubtCallerID = nil
        // 引き取った人から再開する.
        round.currentPlayerID = penalizedID

        var next = self
        next.phase = .round(round)
        return next
    }

    // MARK: - 精算

    /// 全員が同じ額を出し合い, 勝った人が総取りする.
    var chipDeltas: [UserID: Int] {
        guard let round, round.isFinished, let winnerID = round.winnerID else { return [:] }
        let losers = round.seating.filter { $0 != winnerID }
        var deltas: [UserID: Int] = [winnerID: round.bet * losers.count]
        for loser in losers {
            deltas[loser] = -round.bet
        }
        return deltas
    }

    // MARK: - 内部

    static func nextRank(after rank: PlayingRank) -> PlayingRank {
        let order = PlayingRank.allCases
        guard let index = order.firstIndex(of: rank) else { return .three }
        return order[(index + 1) % order.count]
    }

    private static func nextPlayer(after userID: UserID, in seating: [UserID]) -> UserID {
        guard let index = seating.firstIndex(of: userID) else { return seating[0] }
        return seating[(index + 1) % seating.count]
    }
}

private extension Array where Element == PlayingCard {
    /// 手札は数字順に並べる(同じ数字がまとまっていないと出しにくい).
    func sortedForDoubtDisplay() -> [PlayingCard] {
        sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank.rawValue < rhs.rank.rawValue }
            let suits = PlayingSuit.allCases
            return (suits.firstIndex(of: lhs.suit) ?? 0) < (suits.firstIndex(of: rhs.suit) ?? 0)
        }
    }
}
