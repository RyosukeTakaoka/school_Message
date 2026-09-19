import Foundation

/// Slingo: 全員で 1 つのスロットを共有しながら, 早く 1 列を揃えることを競う,
/// 5×5 のビンゴ風レース.
///
/// ## 基本ルール
/// - 2〜4 人で遊ぶ. 全員が持つカードは 1〜50 の数字から 25 個を選んだ, 各自
///   違う 5×5 の並び(中央 FREE なし).
/// - ターン制で, 手番の人だけが SPIN できる. 出た結果は**全員に同じもの**が
///   届き, 該当する数字を持っている全員のカードが自動で開く.
/// - WILD は「選んで使う」ものではなく, スロットの中に混ざっている結果の 1 つ.
///   WILD が出たときだけ特別で, スピンした本人だけが自分のカードの好きな
///   未開放マスを 1 つ選んで開けられる(選べるのは「WILD を使うかどうか」
///   ではなく「WILD が出た結果, どこを開けるか」だけ).
/// - 縦・横・斜めのどれか 1 列(5 マス)を開けた人が Slingo(上がり)。
///   最初に上がった人が賭け金の合計を総取りする. 同じ SPIN の結果で複数人が
///   同時に完成したときは, その人たちで山分けする.
/// - 他のプレイヤーのカードは常に全員から見える遊びなので, インディアン
///   ポーカーや大富豪のように手札を暗号化して配る仕組みは要らない.
///
/// ## 共有スロットの決め方
/// 「山」は 1〜50 の数字 1 個ずつと, 「？(ミステリー)」`mysterySlotCount` 枚を
/// 混ぜてシャッフルしたもの. 「？」のうち実際に WILD なのは `wildCount(seed:)`
/// 枚(1 枚 70% / 2 枚 30%)だけで, 残りは「ハズレ」. どちらも対戦開始時の種
/// (`Round.startSeed`)だけから, 全端末が同じ式で計算する(`BustSnapshot`/
/// `ChinchiroSnapshot` と同じ「対戦相手を信頼する」前提の乱数の共有. 悪用の
/// 余地については `BustSnapshot` のコメント参照)。「？」が何枚 WILD かは
/// どの画面にも出さないので, プレイヤーは最後まで残り枚数が分からない.
///
/// 各自のカードも, 同じ種とプレイヤー ID から `card(for:seed:)` で決定的に
/// 計算するので, メッセージにカードそのものを載せる必要が無い(対戦を
/// 始めるメッセージに種が 1 つ載るだけで済む)。
///
/// 数字は 1〜50 が山の中に 1 回ずつしか無いので, 山を最後まで引けば
/// (「？」を挟んでも)必ず全員のカードが全開放になる ―― つまり対戦は
/// どんなに揃わなくても必ず終わる.
///
/// ## 演出の同期
/// SPIN の結果(数字 / WILD / ハズレ)そのものはメッセージが届いた瞬間に
/// 確定するが, 見せ方だけ `Round.lastDrawAt` からの経過時間で段階分けして
/// 遅らせている(`revealStage(drawnAt:draw:now:)`)。時刻という誰でも同じ
/// 値を計算できるものだけを使うので, 押した本人の端末はもちろん, 届いた
/// だけの他の端末でも, 同じタイミングで同じ演出が見える(BUST の倍率が
/// 経過時間だけの純粋関数なのと同じ考え方). WILD とハズレは, 結果が
/// 確定するまで見た目もタイミングも完全に同じ「？」にしておくことで,
/// 演出から事前に当たり外れを読めないようにしている.
///
/// ターン制で「手番の人しか操作できない」ため, インディアンポーカーや BUST の
/// ような「同時に複数人が動く」場面が無い. そのため `merged(_:)` のような
/// 取りこぼし対策の畳み込みは不要(`ChatStore.mergingConcurrentMoves` にも
/// Slingo は加えていない)。
struct SlingoSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    /// 5人以上だと「早い者勝ち」の性質がぼやけるため, 他の少人数向け
    /// CHIP ゲーム(BUST)と同じく上限を設けている.
    static let maximumPlayers = 4
    static let maxBet = 100

    /// カードは 5×5.
    static let gridSize = 5
    static let numbersPerCard = gridSize * gridSize
    static let cardNumberRange = 1...50
    /// 山に混ぜる「？(ミステリー)」の枚数. このうち実際に WILD なのは
    /// `wildCount(seed:)` 枚だけ(残りはハズレ)で, 画面にはどちらも「？」
    /// までしか出さない.
    static let mysterySlotCount = 6

    /// SPIN から, 数字 or 「？」を見せるまでの間.
    static let faceRevealDelay: TimeInterval = 0.2
    /// 「？」から, WILD かハズレかを見せるまでの間.
    static let mysteryResolveDelay: TimeInterval = 1.0

    /// スロットの結果 1 つぶん. `miss` は「？」がハズレだったことを表す
    /// (画面には「MISS」ではなく「ハズレ」と出す. 表示文言は View 側の仕事).
    enum DrawItem: Hashable, Sendable, Codable {
        case number(Int)
        case wild
        case miss
    }

    /// SPIN 結果を, 今の時点(`now`)でどこまで見せてよいか.
    ///
    /// WILD とハズレは, `.face` の間はどちらも同じ「？」にしか見えない
    /// ようにする(`SlingoGameView` 側の描き分けの責務). 経過時間だけで
    /// 決まる純粋な段階なので, 全端末で必ず同じ結果になる.
    enum RevealStage: Hashable, Sendable {
        /// SPIN 直後. まだ何も見せない.
        case spinning
        /// 数字, または「？」(WILD かハズレかはまだ見せない)を見せてよい.
        case face
        /// 最終結果(数字 / WILD / ハズレ)を見せてよい.
        case resolved
    }

    /// `draw` を `drawnAt` に引いたとして, `now` の時点でどこまで見せてよいか.
    static func revealStage(drawnAt: Date, draw: DrawItem, now: Date = .now) -> RevealStage {
        let elapsed = now.timeIntervalSince(drawnAt)
        guard elapsed >= faceRevealDelay else { return .spinning }
        switch draw {
        case .number:
            return .resolved
        case .wild, .miss:
            return elapsed >= faceRevealDelay + mysteryResolveDelay ? .resolved : .face
        }
    }

    /// 5×5 のカード. `numbers` は左上から右へ, 行ごとに並ぶ(row-major, 25 個).
    struct Card: Hashable, Sendable, Codable {
        var numbers: [Int]

        func number(row: Int, column: Int) -> Int {
            numbers[row * SlingoSnapshot.gridSize + column]
        }

        /// 縦 5 列・横 5 列・斜め 2 本, 合計 12 本の「揃えられる列」を,
        /// `numbers` 内のインデックスの組で表したもの.
        static let lineIndexSets: [[Int]] = {
            let size = SlingoSnapshot.gridSize
            var lines: [[Int]] = []
            for row in 0..<size {
                lines.append((0..<size).map { row * size + $0 })
            }
            for column in 0..<size {
                lines.append((0..<size).map { $0 * size + column })
            }
            lines.append((0..<size).map { $0 * size + $0 })
            lines.append((0..<size).map { $0 * size + (size - 1 - $0) })
            return lines
        }()
    }

    struct Round: Hashable, Sendable, Codable {
        /// 参加した順 = 手番の順.
        var playerIDs: [UserID]
        var bet: Int
        var startedAt: Date
        var startSeed: UInt64

        /// 山から何回引いたか(次に引く結果は `drawSequence(seed:)[spinIndex]`).
        var spinIndex: Int = 0
        /// いまの手番(`playerIDs` の添字). WILD 待ちの間も, 待っている本人の
        /// 添字のまま進めない.
        var currentPlayerIndex: Int = 0
        /// 通常の数字で, もう出た(全員のカードで開いている)もの.
        var revealedNumbers: Set<Int> = []
        /// WILD で個人的に開けた数字(その人のカードでだけ開く).
        var wildOpenedNumbers: [UserID: Set<Int>] = [:]
        /// WILD が出て, まだそのマスを選んでいない人. nil なら通常の手番進行.
        var pendingWildFor: UserID? = nil
        /// 直近の SPIN 結果(演出・表示用. 中身自体は届いた瞬間に確定するが,
        /// 見せるタイミングは `revealStage(drawnAt:draw:now:)` が決める).
        var lastDraw: DrawItem? = nil
        /// 直近の SPIN が確定した時刻. 演出の段階分けの基準(`revealStage`)。
        var lastDrawAt: Date? = nil
        /// 直近に SPIN した人(演出・表示用. WILD 待ちの間も, 選び終えるまで
        /// この人のまま).
        var lastSpinnerID: UserID? = nil
        /// 上がった人. 複数いれば同じ結果で同時に上がった(山分け)。
        /// 空でなければ対戦は終了.
        var finisherIDs: [UserID] = []
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

    static func newLobby(hostID: UserID, bet: Int) -> SlingoSnapshot {
        SlingoSnapshot(
            gameID: UUID().uuidString,
            hostID: hostID,
            phase: .lobby(ChipGameLobby(hostID: hostID, bet: bet))
        )
    }

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

    /// 上がった人がいれば終了.
    var isFinished: Bool {
        !(round?.finisherIDs.isEmpty ?? true)
    }

    /// いまの手番. WILD 待ちの間も, 選び終えるまでこの人のまま変わらない.
    var currentPlayerID: UserID? {
        guard let round, round.playerIDs.indices.contains(round.currentPlayerIndex) else { return nil }
        return round.playerIDs[round.currentPlayerIndex]
    }

    /// WILD が出て, まだマスを選んでいない人を待っている状態か.
    var isAwaitingWildPick: Bool {
        round?.pendingWildFor != nil
    }

    /// 直近の SPIN の演出がまだ再生中か(全員の画面でタイミングを揃えるための
    /// 判定. この間は SPIN も WILD のマス選択もできない).
    func isRevealing(now: Date = .now) -> Bool {
        guard let round, let draw = round.lastDraw, let drawnAt = round.lastDrawAt else { return false }
        return Self.revealStage(drawnAt: drawnAt, draw: draw, now: now) != .resolved
    }

    // MARK: - カードと山

    /// `playerID` のカード. 種から決定的に計算するので, 対戦中いつでも
    /// どの端末でも同じ結果になる(メッセージにカードそのものを載せない).
    static func card(for playerID: UserID, seed: UInt64) -> Card {
        var generator = SeededGenerator(seed: seed ^ hash(playerID.rawValue))
        var numbers = Array(cardNumberRange)
        numbers.shuffle(using: &generator)
        return Card(numbers: Array(numbers.prefix(numbersPerCard)))
    }

    func card(for playerID: UserID) -> Card? {
        guard let round else { return nil }
        return Self.card(for: playerID, seed: round.startSeed)
    }

    /// この対戦で「？」`mysterySlotCount` 枚のうち実際に WILD なのは何枚か.
    /// 1 枚 70% / 2 枚 30% で, 対戦開始時の種から 1 回だけ決める
    /// (全端末が同じ値になる. どの画面にもこの値そのものは出さない).
    static func wildCount(seed: UInt64) -> Int {
        var generator = SeededGenerator(seed: seed ^ 0x5A1D_C0DE)
        return generator.next() % 100 < 70 ? 1 : 2
    }

    /// 山の中身. 1〜50 の数字 1 個ずつと, 「？」`mysterySlotCount` 枚
    /// (うち `wildCount(seed:)` 枚が WILD, 残りがハズレ)をシャッフルした並び.
    static func drawSequence(seed: UInt64) -> [DrawItem] {
        var generator = SeededGenerator(seed: seed)
        var items: [DrawItem] = cardNumberRange.map { DrawItem.number($0) }
        let wilds = wildCount(seed: seed)
        items.append(contentsOf: Array(repeating: DrawItem.wild, count: wilds))
        items.append(contentsOf: Array(repeating: DrawItem.miss, count: mysterySlotCount - wilds))
        items.shuffle(using: &generator)
        return items
    }

    /// `playerID` のカードでいま開いているマスの数字.
    func openNumbers(for playerID: UserID) -> Set<Int> {
        guard let round else { return [] }
        return Self.openNumbers(round: round, playerID: playerID)
    }

    private static func openNumbers(round: Round, playerID: UserID) -> Set<Int> {
        var opens = round.revealedNumbers
        if let wildOpened = round.wildOpenedNumbers[playerID] {
            opens.formUnion(wildOpened)
        }
        return opens
    }

    /// `playerID` が縦・横・斜めのどれか 1 列を揃えているか.
    func hasCompletedLine(for playerID: UserID) -> Bool {
        guard let round, let card = card(for: playerID) else { return false }
        return Self.hasCompletedLine(card: card, openNumbers: Self.openNumbers(round: round, playerID: playerID))
    }

    private static func hasCompletedLine(card: Card, openNumbers: Set<Int>) -> Bool {
        Card.lineIndexSets.contains { line in
            line.allSatisfy { openNumbers.contains(card.numbers[$0]) }
        }
    }

    /// あと 1 マスで列が揃う「リーチ」になっているマス(表示の強調に使う).
    func reachCellIndices(for playerID: UserID) -> Set<Int> {
        guard let card = card(for: playerID) else { return [] }
        let opens = openNumbers(for: playerID)
        var indices: Set<Int> = []
        for line in Card.lineIndexSets {
            let unopened = line.filter { !opens.contains(card.numbers[$0]) }
            if unopened.count == 1 { indices.formUnion(unopened) }
        }
        return indices
    }

    // MARK: - 操作

    /// SPIN する. 呼べるのは今の手番の人だけ, WILD 待ちでない, かつ直前の
    /// SPIN の演出がもう終わっているとき.
    ///
    /// 結果はチンチロの出目のように本人の端末で新しく決めるのではなく,
    /// 対戦開始時の種から計算する(`drawSequence(seed:)`)ので, 誰の端末で
    /// 呼んでも同じ結果になる.
    func spinning(by userID: UserID, now: Date = .now) -> SlingoSnapshot? {
        guard var round, !isFinished, round.pendingWildFor == nil, currentPlayerID == userID,
              !isRevealing(now: now)
        else { return nil }
        let sequence = Self.drawSequence(seed: round.startSeed)
        guard round.spinIndex < sequence.count else { return nil }

        let draw = sequence[round.spinIndex]
        round.spinIndex += 1
        round.lastDraw = draw
        round.lastDrawAt = now
        round.lastSpinnerID = userID

        switch draw {
        case .wild:
            round.pendingWildFor = userID
        case .miss:
            round.currentPlayerIndex = (round.currentPlayerIndex + 1) % round.playerIDs.count
        case .number(let value):
            round.revealedNumbers.insert(value)
            let finishers = Self.newlyCompletedPlayers(round: round)
            if !finishers.isEmpty {
                round.finisherIDs = finishers
            } else {
                round.currentPlayerIndex = (round.currentPlayerIndex + 1) % round.playerIDs.count
            }
        }

        var next = self
        next.phase = .playing(round)
        return next
    }

    /// WILD: 自分のカードの未開放マスを 1 つ選んで開ける.
    /// 呼べるのは WILD を引いた本人だけ, まだ開いていない・自分のカードに
    /// 実在する数字で, かつ WILD の演出がもう終わっているときだけ.
    func openingWildCell(_ number: Int, by userID: UserID, now: Date = .now) -> SlingoSnapshot? {
        guard var round, !isFinished, round.pendingWildFor == userID, !isRevealing(now: now),
              let card = card(for: userID), card.numbers.contains(number)
        else { return nil }
        let opens = Self.openNumbers(round: round, playerID: userID)
        guard !opens.contains(number) else { return nil }

        round.wildOpenedNumbers[userID, default: []].insert(number)
        round.pendingWildFor = nil

        if Self.hasCompletedLine(card: card, openNumbers: opens.union([number])) {
            round.finisherIDs = [userID]
        } else {
            round.currentPlayerIndex = (round.currentPlayerIndex + 1) % round.playerIDs.count
        }

        var next = self
        next.phase = .playing(round)
        return next
    }

    /// この SPIN で新たに列を揃えた人(全員ぶん確かめる. 数字は全員のカードに
    /// 同時に反映されるため, 1 回の SPIN で複数人が同時に上がることがある).
    private static func newlyCompletedPlayers(round: Round) -> [UserID] {
        round.playerIDs.filter { playerID in
            let card = card(for: playerID, seed: round.startSeed)
            return hasCompletedLine(card: card, openNumbers: openNumbers(round: round, playerID: playerID))
        }
    }

    // MARK: - 精算

    /// 精算. 最初に上がった人(複数なら同着)が賭け金の合計を山分けする.
    /// 端数は先頭の当選者から 1 ずつ足して, CHIP の総量がぴったり合うようにする.
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }
        let winners = round.finisherIDs
        let pot = round.bet * round.playerIDs.count

        var deltas: [UserID: Int] = [:]
        for playerID in round.playerIDs where !winners.contains(playerID) {
            deltas[playerID] = -round.bet
        }

        let share = pot / winners.count
        let remainder = pot % winners.count
        for (index, winner) in winners.enumerated() {
            deltas[winner] = -round.bet + share + (index < remainder ? 1 : 0)
        }
        return deltas
    }

    // MARK: - 文字列からの決定的な種

    /// `String.hashValue` は起動ごとに種が変わるため使えない(`Palette.avatarBackground`
    /// と同じ理由). 決定的な djb2 ハッシュを自前で計算する.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 5381
        for byte in text.utf8 {
            value = (value &* 33) &+ UInt64(byte)
        }
        return value
    }
}
