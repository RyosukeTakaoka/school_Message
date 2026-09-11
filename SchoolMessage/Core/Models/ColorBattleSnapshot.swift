import Foundation

/// 札の色.
///
/// 色だけで区別させると, 色覚特性や画面の明るさによって見分けにくくなる.
/// 記号も一緒に持たせて, 画面側では色と形の両方で示す.
enum CardColor: String, Codable, Sendable, Hashable, CaseIterable {
    case red
    case blue
    case green
    case yellow

    var title: String {
        switch self {
        case .red: String(localized: "あか")
        case .blue: String(localized: "あお")
        case .green: String(localized: "みどり")
        case .yellow: String(localized: "きいろ")
        }
    }

    var symbolName: String {
        switch self {
        case .red: "heart.fill"
        case .blue: "drop.fill"
        case .green: "leaf.fill"
        case .yellow: "star.fill"
        }
    }
}

/// 1 枚の札.
struct ColorCard: Codable, Sendable, Hashable, Identifiable {
    var color: CardColor
    var number: Int

    var id: String { "\(color.rawValue)-\(number)" }

    var label: String { String(localized: "\(color.title)の\(number)") }
}

/// 決着した 1 回戦の記録. 「なぜ勝った / 負けた」を画面に出すために残す.
struct ColorBattleRound: Codable, Sendable, Hashable {
    var round: Int
    var trump: CardColor
    var leaderID: UserID
    var leadCard: ColorCard
    var followerID: UserID
    var followCard: ColorCard
    var winnerID: UserID
    var points: Int
}

/// 色勝負の状態.
///
/// ## 手札を隠す仕組み
/// 対戦の状態はメッセージとして相手にも丸ごと渡るため, 単に暗号化するだけでは
/// 「両者が持つ会話鍵」で相手も開けてしまい, 手札を隠したことにならない.
///
/// そこで, 各プレイヤーの手札は**本人の公開鍵宛てにもう一段封をする**
/// (`CryptoService.sealToPublicKey` / `openSealedToSelf`). 会話鍵での暗号化は
/// 今まで通り(第三者から中身を隠す), その内側で, 手札のフィールドだけは
/// 本人の秘密鍵でしか開けない状態で運ぶ. 相手の端末には「開けない暗号文」が
/// 届くだけで, 中身を復元する手立てがない.
///
/// 手札の枚数(`firstHandCount` / `secondHandCount`)だけは暗号化していない.
/// 何枚残っているかは対戦の進行そのものから分かる情報で, 隠す意味が無いため,
/// 手札を開けなくても対戦が終わったかどうかを両者が判定できるようにしている.
///
/// - 先に出す人(リード)は, 相手の応じ方を知らずに出す
/// - 後から出す人は, 相手の札を見てから出す
/// - リードは 1 回戦ごとに交代し, 引き分けはリードの勝ちとする
///
/// 状態は今まで通りすべてメッセージに乗っているため, 端末を変えても,
/// アプリを入れ直しても, 本人の秘密鍵さえあれば途中から続きを遊べる.
struct ColorBattleSnapshot: Hashable, Sendable, Codable {

    /// 1 人に配る枚数(= 回戦数).
    static let handSize = 8

    /// 札の数字の範囲.
    static let numbers = 1...10

    var gameID: String
    /// 第 1 回戦で先に出す人(対戦を始めた人).
    var firstPlayerID: UserID
    var secondPlayerID: UserID
    /// 本人の公開鍵宛てに封じた手札. 本人以外は開けない.
    var firstHandSealed: WrappedConversationKey
    var secondHandSealed: WrappedConversationKey
    /// 手札の残り枚数(暗号化しない. 対戦の進行から分かる情報のため).
    var firstHandCount: Int
    var secondHandCount: Int
    var firstScore: Int
    var secondScore: Int
    /// いま進行中の回戦(1 から始まる).
    var round: Int
    /// リードが出したが, まだ相手が応じていない札.
    var pendingLeadCard: ColorCard?
    /// 直前に決着した回戦.
    var lastRound: ColorBattleRound?
    var isFinished: Bool

    // MARK: - 開始

    /// 新しい対戦を始める.
    ///
    /// 山札は `gameID` から決まる並びで切る. 乱数の種を対戦の識別子にすることで,
    /// 誰の端末で組み立てても同じ配りになり, 「配り直し」で有利にすることもできない.
    /// 配った手札はその場でそれぞれの公開鍵宛てに封じるため, crypto アクセスが要る.
    static func new(
        first: UserID,
        second: UserID,
        firstPublicKey: Data,
        secondPublicKey: Data,
        crypto: CryptoService
    ) async throws -> ColorBattleSnapshot {
        var deck: [ColorCard] = []
        for color in CardColor.allCases {
            for number in numbers {
                deck.append(ColorCard(color: color, number: number))
            }
        }
        let gameID = UUID().uuidString
        var generator = SeededGenerator(seed: Self.hash(gameID))
        deck.shuffle(using: &generator)

        let firstHand = Array(deck.prefix(handSize)).sortedForDisplay()
        let secondHand = Array(deck.dropFirst(handSize).prefix(handSize)).sortedForDisplay()

        let firstSealed = try await crypto.sealToPublicKey(
            JSONEncoder().encode(firstHand), recipientPublicKey: firstPublicKey
        )
        let secondSealed = try await crypto.sealToPublicKey(
            JSONEncoder().encode(secondHand), recipientPublicKey: secondPublicKey
        )

        return ColorBattleSnapshot(
            gameID: gameID,
            firstPlayerID: first,
            secondPlayerID: second,
            firstHandSealed: firstSealed,
            secondHandSealed: secondSealed,
            firstHandCount: firstHand.count,
            secondHandCount: secondHand.count,
            firstScore: 0,
            secondScore: 0,
            round: 1,
            pendingLeadCard: nil,
            lastRound: nil,
            isFinished: false
        )
    }

    // MARK: - 参照

    /// この回戦の切り札の色.
    ///
    /// 対戦の識別子と回戦数から決める. どちらの端末で計算しても同じ色になり,
    /// かつ次に何が来るかを狙って操作することはできない.
    static func trump(gameID: String, round: Int) -> CardColor {
        let value = hash("\(gameID)#\(round)")
        let colors = CardColor.allCases
        return colors[Int(value % UInt64(colors.count))]
    }

    var trump: CardColor { Self.trump(gameID: gameID, round: round) }

    /// この回戦で先に出す人. 1 回戦ごとに交代する.
    var leaderID: UserID {
        round.isMultiple(of: 2) ? secondPlayerID : firstPlayerID
    }

    var followerID: UserID {
        leaderID == firstPlayerID ? secondPlayerID : firstPlayerID
    }

    /// いま出す番の人.
    var currentPlayerID: UserID {
        pendingLeadCard == nil ? leaderID : followerID
    }

    func isTurn(of userID: UserID) -> Bool {
        !isFinished && currentPlayerID == userID
    }

    /// この人がリードとして出す場面か(相手の札を見ずに出す番か).
    func isLeading(_ userID: UserID) -> Bool {
        pendingLeadCard == nil && leaderID == userID
    }

    /// 手札の残り枚数(中身は本人にしか分からない).
    func handCount(for userID: UserID) -> Int {
        userID == firstPlayerID ? firstHandCount : (userID == secondPlayerID ? secondHandCount : 0)
    }

    /// 自分の手札を開ける. 本人の秘密鍵でしか開けないため, 引数無しで
    /// 「いま signed in している利用者」の分だけを対象にする設計にしている
    /// (`userID` を引数に取ると, 誰の分でも開けるかのように誤解しやすいため).
    ///
    /// `userID` はこの対戦の当事者(`firstPlayerID` / `secondPlayerID`)の
    /// どちらかである必要がある. それ以外を渡した場合は空配列を返す.
    func decryptedHand(for userID: UserID, crypto: CryptoService) async throws -> [ColorCard] {
        let sealed: WrappedConversationKey
        if userID == firstPlayerID {
            sealed = firstHandSealed
        } else if userID == secondPlayerID {
            sealed = secondHandSealed
        } else {
            return []
        }
        let data = try await crypto.openSealedToSelf(sealed)
        return try JSONDecoder().decode([ColorCard].self, from: data)
    }

    func score(for userID: UserID) -> Int {
        userID == firstPlayerID ? firstScore : (userID == secondPlayerID ? secondScore : 0)
    }

    func opponentID(of userID: UserID) -> UserID? {
        if userID == firstPlayerID { return secondPlayerID }
        if userID == secondPlayerID { return firstPlayerID }
        return nil
    }

    func isPlayer(_ userID: UserID) -> Bool {
        userID == firstPlayerID || userID == secondPlayerID
    }

    /// 勝った人. 同点なら `nil`.
    var winnerID: UserID? {
        if firstScore == secondScore { return nil }
        return firstScore > secondScore ? firstPlayerID : secondPlayerID
    }

    // MARK: - ルール

    /// 後から出した札が勝つか.
    ///
    /// - 切り札の色は, 数字に関係なく切り札でない札に勝つ
    /// - 同じ立場どうしなら, 数字が大きいほうが勝つ
    /// - 同じ数字なら, 相手の出方を知らずに出したリードの勝ちとする
    static func followerWins(follow: ColorCard, lead: ColorCard, trump: CardColor) -> Bool {
        let followIsTrump = follow.color == trump
        let leadIsTrump = lead.color == trump
        if followIsTrump != leadIsTrump { return followIsTrump }
        return follow.number > lead.number
    }

    /// 札を 1 枚出した次の状態を返す. 出せない場面・持っていない札なら `nil`.
    ///
    /// 自分の手札はここで一旦復号し, 出した札を除いてから自分の公開鍵宛てに
    /// 封じ直す. 相手の手札(封じられたもう一方)には一切触れない
    /// (そもそも復号する手立てが無い).
    func playing(_ card: ColorCard, by userID: UserID, crypto: CryptoService) async throws -> ColorBattleSnapshot? {
        guard isTurn(of: userID) else { return nil }
        var myHand = try await decryptedHand(for: userID, crypto: crypto)
        guard let index = myHand.firstIndex(of: card) else { return nil }
        myHand.remove(at: index)

        let myPublicKey = try await crypto.identityPublicKeyData()
        let resealed = try await crypto.sealToPublicKey(
            JSONEncoder().encode(myHand), recipientPublicKey: myPublicKey
        )

        var next = self
        if userID == firstPlayerID {
            next.firstHandSealed = resealed
            next.firstHandCount = myHand.count
        } else if userID == secondPlayerID {
            next.secondHandSealed = resealed
            next.secondHandCount = myHand.count
        } else {
            return nil
        }

        guard let lead = pendingLeadCard else {
            next.pendingLeadCard = card
            return next
        }

        let trumpColor = trump
        let leader = leaderID
        let winner = Self.followerWins(follow: card, lead: lead, trump: trumpColor) ? userID : leader
        let points = lead.number + card.number
        next.addScore(points, to: winner)
        next.lastRound = ColorBattleRound(
            round: round,
            trump: trumpColor,
            leaderID: leader,
            leadCard: lead,
            followerID: userID,
            followCard: card,
            winnerID: winner,
            points: points
        )
        next.pendingLeadCard = nil
        next.round = round + 1
        next.isFinished = next.firstHandCount == 0 && next.secondHandCount == 0
        return next
    }

    private mutating func addScore(_ points: Int, to userID: UserID) {
        if userID == firstPlayerID {
            firstScore += points
        } else if userID == secondPlayerID {
            secondScore += points
        }
    }

    // MARK: - 決定的な乱数

    /// 文字列から決まる値を作る(djb2).
    ///
    /// `String.hashValue` は起動ごとに種が変わるため, 保存や通信に混ぜると
    /// 端末や起動のたびに違う結果になってしまう. 自前で計算する.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 5381
        for byte in text.utf8 {
            value = (value &* 33) &+ UInt64(byte)
        }
        return value
    }
}

/// 種から決まる乱数. 同じ種なら, どの端末でも同じ並びになる.
struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64. 短い実装で, 十分に散らばる.
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension Array where Element == ColorCard {
    /// 手札は色ごと・数字順に並べる. 引くたびに並びが変わると選びにくい.
    func sortedForDisplay() -> [ColorCard] {
        sorted { lhs, rhs in
            if lhs.color != rhs.color {
                let order = CardColor.allCases
                return (order.firstIndex(of: lhs.color) ?? 0) < (order.firstIndex(of: rhs.color) ?? 0)
            }
            return lhs.number < rhs.number
        }
    }
}
