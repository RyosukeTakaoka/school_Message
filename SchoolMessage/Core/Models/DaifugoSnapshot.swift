import Foundation

/// トランプの数字の強さ. 3 が一番弱く, 2 が一番強い(標準的な大富豪の順).
/// 革命・Jバックが起きている間は, この大小関係が逆転する.
enum PlayingRank: Int, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case three = 3, four, five, six, seven, eight, nine, ten
    case jack = 11, queen = 12, king = 13
    case ace = 14
    case two = 15

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        case .ten: "10"
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        case .ace: "A"
        case .two: "2"
        }
    }
}

enum PlayingSuit: String, Codable, Sendable, Hashable, CaseIterable {
    case spade, heart, diamond, club

    var symbolName: String {
        switch self {
        case .spade: "suit.spade.fill"
        case .heart: "suit.heart.fill"
        case .diamond: "suit.diamond.fill"
        case .club: "suit.club.fill"
        }
    }

    /// 見た目の色分け(色覚特性に配慮し, 記号でも区別できるようにしてある).
    var isRed: Bool { self == .heart || self == .diamond }
}

/// トランプ 1 枚.
struct PlayingCard: Codable, Sendable, Hashable, Identifiable {
    var suit: PlayingSuit
    var rank: PlayingRank

    var id: String { "\(suit.rawValue)-\(rank.rawValue)" }
    var label: String { rank.label }
}

/// 大富豪の状態.
///
/// ## グループの遊びであること
/// 色勝負・オセロと違い, 3 人以上のグループで遊ぶ. 始めたい人がまず
/// 「募集(ロビー)」を作り, 参加したい人がそれぞれ参加を選んでから,
/// 募集した人が対戦を開始する(グループの全員が強制的に参加させられることはない).
///
/// ## 手札を隠す仕組み
/// 色勝負と同じ. 各プレイヤーの手札は本人の公開鍵宛てに封じて運び,
/// 本人以外(サーバも含む)は開けない. 残り枚数だけは公開情報として持つ
/// (対戦の進行そのものから分かる情報であり, 上がり判定にも必要なため).
///
/// 「7わたし」で相手に渡す 1 枚は, その相手の公開鍵宛てに個別に封じて,
/// 受け取り待ちの列に積む. 受け取った本人が次に何か行動する(出す/パスする)
/// ときに, 自分の手札へ取り込んでからまとめて封じ直す
/// (本人以外は相手の手札を復号できないため, 本人の行動を待つしかない).
struct DaifugoSnapshot: Hashable, Sendable, Codable {

    /// 参加者を募っている段階. まだ手札は配っていない.
    struct Lobby: Hashable, Sendable, Codable {
        var joinedPlayerIDs: [UserID]
    }

    /// 対戦中の状態.
    struct Round: Hashable, Sendable, Codable {
        /// 席順 = 手番の順. ロビーで参加した順のまま固定する.
        var seating: [UserID]
        /// 本人の公開鍵宛てに封じた手札.
        var sealedHands: [UserID: WrappedConversationKey]
        /// 受け取りを待っている, 個別に封じられた 1 枚(7わたし用).
        var pendingGivenCards: [UserID: [WrappedConversationKey]]
        /// Qバンバー(下記)で, まだ本人の手札から取り除けていない宣言された数字.
        ///
        /// クイーンを出した人が宣言した数字は, その場にいる全員(出した本人以外)の
        /// 手札から取り除かれるはずだが, 本人以外の手札は本人にしか復号できないため
        /// その場で取り除くことができない. 代わりにここへ積んでおき, 対象者が
        /// 次に自分の番で札を出すときに, 自分の手札を復号したその場で取り除いて
        /// 手札を封じ直す(「7わたし」の `pendingGivenCards` と同じ考え方).
        /// パスだけしている間は取り除けない(手札に触れないため).
        var pendingRankPurgesByPlayer: [UserID: [PlayingRank]]
        /// 手札の残り枚数(暗号化しない. 進行そのものから分かる情報のため).
        var handCounts: [UserID: Int]
        /// 上がった順(先頭が最初に上がった人 = 大富豪).
        var finishedOrder: [UserID]
        /// いま場に出ている札. 空なら場が流れた直後で, 次の人は自由に出せる.
        var fieldCards: [PlayingCard]
        /// 場に出した人(場が流れたときに次の親になる). 場が空の間は nil.
        var fieldOwnerID: UserID?
        /// いまの手番.
        var currentPlayerID: UserID
        /// Jバックでこの場だけ強さが逆転しているか(場が流れたら false に戻る).
        var isTrickReversed: Bool
        /// 革命で強さが逆転しているか(次に革命が起きるまでずっと持続する).
        var isRevolution: Bool
        var isFinished: Bool
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(Lobby)
        case round(Round)
    }

    var gameID: String
    /// 募集した人. ロビーの間, 開始できるのはこの人だけ.
    var hostID: UserID
    var phase: Phase

    var isFinished: Bool {
        switch phase {
        case .lobby: false
        case .round(let round): round.isFinished
        }
    }

    static func newLobby(hostID: UserID) -> DaifugoSnapshot {
        DaifugoSnapshot(
            gameID: UUID().uuidString,
            hostID: hostID,
            phase: .lobby(Lobby(joinedPlayerIDs: [hostID]))
        )
    }
}

// MARK: - ロビー

extension DaifugoSnapshot.Lobby {
    static let minimumPlayers = 3
}

// MARK: - 対戦の開始(配札)

extension DaifugoSnapshot.Round {

    /// 標準 52 枚(ジョーカーなし)を組み立てる.
    private static func freshDeck() -> [PlayingCard] {
        var deck: [PlayingCard] = []
        for suit in PlayingSuit.allCases {
            for rank in PlayingRank.allCases {
                deck.append(PlayingCard(suit: suit, rank: rank))
            }
        }
        return deck
    }

    /// 参加者に手札を配って対戦を開始する.
    ///
    /// 山札は `gameID` から決まる並びで切る(色勝負と同じ考え方). 割り切れない
    /// 分は席順の前の方から 1 枚ずつ多く配る. 席順の最初の人が第 1 手の親になる.
    static func start(
        gameID: String,
        seating: [UserID],
        publicKeys: [UserID: Data],
        crypto: CryptoService
    ) async throws -> DaifugoSnapshot.Round? {
        guard seating.count >= DaifugoSnapshot.Lobby.minimumPlayers else { return nil }
        guard seating.allSatisfy({ publicKeys[$0] != nil }) else { return nil }

        var deck = freshDeck()
        var generator = SeededGenerator(seed: ColorBattleSnapshot.hash(gameID))
        deck.shuffle(using: &generator)

        let base = deck.count / seating.count
        let remainder = deck.count % seating.count

        var sealedHands: [UserID: WrappedConversationKey] = [:]
        var handCounts: [UserID: Int] = [:]
        var cursor = 0
        for (index, playerID) in seating.enumerated() {
            let count = base + (index < remainder ? 1 : 0)
            let hand = Array(deck[cursor..<(cursor + count)])
            cursor += count
            guard let publicKey = publicKeys[playerID] else { return nil }
            sealedHands[playerID] = try await crypto.sealToPublicKey(
                try JSONEncoder().encode(hand), recipientPublicKey: publicKey
            )
            handCounts[playerID] = hand.count
        }

        return DaifugoSnapshot.Round(
            seating: seating,
            sealedHands: sealedHands,
            pendingGivenCards: [:],
            pendingRankPurgesByPlayer: [:],
            handCounts: handCounts,
            finishedOrder: [],
            fieldCards: [],
            fieldOwnerID: nil,
            currentPlayerID: seating[0],
            isTrickReversed: false,
            isRevolution: false,
            isFinished: false
        )
    }
}

// MARK: - 参照

extension DaifugoSnapshot.Round {

    static func isStronger(_ a: PlayingRank, than b: PlayingRank, reversed: Bool) -> Bool {
        reversed ? a.rawValue < b.rawValue : a.rawValue > b.rawValue
    }

    /// `userID` より後の, まだ上がっていない次のプレイヤー.
    func nextActivePlayer(after userID: UserID) -> UserID? {
        guard let startIndex = seating.firstIndex(of: userID) else { return nil }
        let finishedSet = Set(finishedOrder)
        for offset in 1...seating.count {
            let candidate = seating[(startIndex + offset) % seating.count]
            if !finishedSet.contains(candidate) { return candidate }
        }
        return nil
    }

    func isTurn(of userID: UserID) -> Bool {
        !isFinished && currentPlayerID == userID
    }

    func handCount(for userID: UserID) -> Int {
        handCounts[userID] ?? 0
    }

    /// 上がった順位(1 が大富豪). まだ上がっていなければ nil.
    func finishRank(for userID: UserID) -> Int? {
        guard let index = finishedOrder.firstIndex(of: userID) else { return nil }
        return index + 1
    }

    /// 順位の呼び方. 人数に応じて呼び方の数を調整する
    /// (例: 3 人なら 大富豪 → 平民 → 大貧民).
    func rankTitle(for userID: UserID) -> String? {
        guard let place = finishRank(for: userID) else { return nil }
        return Self.rankTitle(place: place, totalPlayers: seating.count)
    }

    static func rankTitle(place: Int, totalPlayers: Int) -> String {
        if place == 1 { return String(localized: "大富豪") }
        if place == totalPlayers { return String(localized: "大貧民") }
        if place == totalPlayers - 1, totalPlayers >= 4 { return String(localized: "貧民") }
        if place == 2, totalPlayers >= 4 { return String(localized: "富豪") }
        return String(localized: "平民")
    }

    /// 自分の手札を開ける. 受け取り待ちの札(7わたしで受け取った分)があれば
    /// それも合わせて返す(ただし, まだ自分の封じた手札には取り込まれていない).
    ///
    /// Qバンバー(`playing` 参照)で自分宛ての宣言が積まれている場合, 表示上は
    /// 先に取り除いた状態を返す(実際に手札から取り除いて保存し直すのは,
    /// 本人が次に札を出すときになる).
    func decryptedHand(for userID: UserID, crypto: CryptoService) async throws -> [PlayingCard] {
        var hand: [PlayingCard] = []
        if let sealed = sealedHands[userID] {
            let data = try await crypto.openSealedToSelf(sealed)
            hand = try JSONDecoder().decode([PlayingCard].self, from: data)
        }
        for pending in pendingGivenCards[userID] ?? [] {
            let data = try await crypto.openSealedToSelf(pending)
            hand.append(try JSONDecoder().decode(PlayingCard.self, from: data))
        }
        let purges = pendingRankPurgesByPlayer[userID] ?? []
        if !purges.isEmpty {
            hand.removeAll { purges.contains($0.rank) }
        }
        return hand
    }
}

// MARK: - 手を進める

extension DaifugoSnapshot.Round {

    /// 出せる/出せないだけを判定する(UI がボタンの有効・無効を出すのに使う).
    func canPlay(_ cards: [PlayingCard]) -> Bool {
        guard !cards.isEmpty else { return false }
        let ranks = Set(cards.map(\.rank))
        guard ranks.count == 1 else { return false }
        guard !fieldCards.isEmpty else { return true }
        guard cards.count == fieldCards.count, let fieldRank = fieldCards.first?.rank else {
            return false
        }
        let reversed = isRevolution != isTrickReversed
        return Self.isStronger(cards[0].rank, than: fieldRank, reversed: reversed)
    }

    /// 札を出す.
    /// - `extraCard`: 7わたしで渡す札, または 10捨てで捨てる札(出した札が 7 か 10 かで意味が変わる).
    /// - `declaredRank`: Qバンバー(クイーンを出したときだけ使う)で宣言する数字.
    ///   出した本人以外の全員から, その数字の札を強制的に捨てさせる.
    ///
    /// 出せない手なら nil.
    func playing(
        _ cards: [PlayingCard],
        by userID: UserID,
        extraCard: PlayingCard? = nil,
        giveRecipientID: UserID? = nil,
        giveRecipientPublicKey: Data? = nil,
        declaredRank: PlayingRank? = nil,
        crypto: CryptoService
    ) async throws -> DaifugoSnapshot.Round? {
        guard isTurn(of: userID), canPlay(cards) else { return nil }

        let rank = cards[0].rank

        var next = self

        // 自分宛てに積まれた Qバンバーの宣言があれば, 出す前にまず自分の手札から
        // 取り除く(取り除いた後の手札に, これから出そうとしている札が
        // 残っているかで判定する. 既に無くなっていれば出せない).
        var myHand = try await decryptedHand(for: userID, crypto: crypto)
        next.pendingRankPurgesByPlayer[userID] = nil

        for card in cards {
            guard let index = myHand.firstIndex(of: card) else { return nil }
            myHand.remove(at: index)
        }

        // 7わたし・10捨て: 出した札を除いた後の手札が対象.
        // 最後の 1 枚を出して上がった場合は, 渡す/捨てる札が無いので何もしない.
        if !myHand.isEmpty, let extraCard, let index = myHand.firstIndex(of: extraCard) {
            if rank == .seven, let giveRecipientID, let giveRecipientPublicKey {
                myHand.remove(at: index)
                let sealedCard = try await crypto.sealToPublicKey(
                    try JSONEncoder().encode(extraCard), recipientPublicKey: giveRecipientPublicKey
                )
                next.pendingGivenCards[giveRecipientID, default: []].append(sealedCard)
                next.handCounts[giveRecipientID] = (next.handCounts[giveRecipientID] ?? 0) + 1
            } else if rank == .ten {
                myHand.remove(at: index)
            }
        }

        // Qバンバー: クイーンを出すと, 好きな数字をひとつ宣言できる.
        // 宣言された数字は, 出した本人以外の全員が次に自分の番で手札を
        // 開いたときに取り除かれる(仕組みは `pendingRankPurgesByPlayer` 参照).
        if rank == .queen, let declaredRank {
            for other in seating where other != userID {
                next.pendingRankPurgesByPlayer[other, default: []].append(declaredRank)
            }
        }

        // 自分の手札を封じ直す. 受け取り待ちの札は, ここで取り込んでしまうので
        // 以後は列に残さない.
        let myPublicKey = try await crypto.identityPublicKeyData()
        next.sealedHands[userID] = try await crypto.sealToPublicKey(
            try JSONEncoder().encode(myHand), recipientPublicKey: myPublicKey
        )
        next.pendingGivenCards[userID] = []
        next.handCounts[userID] = myHand.count

        if myHand.isEmpty, !next.finishedOrder.contains(userID) {
            next.finishedOrder.append(userID)
        }

        if rank == .jack {
            next.isTrickReversed.toggle()
        }
        if cards.count >= 4 {
            // 革命: 同じ数字を 4 枚以上同時に出すと強さが反転する.
            // 場が流れても元に戻らない(次の革命が起きるまで持続する).
            next.isRevolution.toggle()
        }

        let remainingActive = seating.filter { !next.finishedOrder.contains($0) }
        if remainingActive.count <= 1 {
            // 残り 1 人になったら, その人を大貧民として対戦を終える
            // (1 人だけになってまで打たせない).
            if let last = remainingActive.first {
                next.finishedOrder.append(last)
            }
            next.isFinished = true
            next.fieldCards = []
            next.fieldOwnerID = nil
            return next
        }

        if rank == .eight {
            // 8切り: 場を即座に流し, 出した本人がそのまま親を続ける
            // (本人がこの札で上がっていれば, 代わりに次の現役プレイヤーから).
            next.fieldCards = []
            next.fieldOwnerID = nil
            next.isTrickReversed = false
            next.currentPlayerID = next.finishedOrder.contains(userID)
                ? (next.nextActivePlayer(after: userID) ?? userID)
                : userID
            return next
        }

        // 通常の進行. 5スキップなら, 出した枚数ぶんだけ余分に手番を進める.
        next.fieldCards = cards
        next.fieldOwnerID = userID
        var turnHolder = userID
        let skipCount = (rank == .five) ? cards.count : 0
        for _ in 0...skipCount {
            guard let advanced = next.nextActivePlayer(after: turnHolder) else { break }
            turnHolder = advanced
        }
        next.currentPlayerID = turnHolder
        return next
    }

    /// パスする. 場が空(自分が親)のときはパスできない.
    func passing(by userID: UserID) -> DaifugoSnapshot.Round? {
        guard isTurn(of: userID), let owner = fieldOwnerID else { return nil }
        guard let advanced = nextActivePlayer(after: userID) else { return nil }

        var next = self
        if advanced == owner {
            // 一周して場を出した本人まで戻ってきた = 場が流れる.
            next.fieldCards = []
            next.fieldOwnerID = nil
            next.isTrickReversed = false
            next.currentPlayerID = finishedOrder.contains(owner)
                ? (nextActivePlayer(after: owner) ?? owner)
                : owner
        } else {
            next.currentPlayerID = advanced
        }
        return next
    }
}
