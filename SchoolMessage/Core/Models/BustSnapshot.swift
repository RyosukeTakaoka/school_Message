import Foundation

/// BUST: 倍率が 1.00x から 0.01x刻みで上がっていく, せーので降りるタイミングを
/// 見極めるギャンブル.
///
/// ## 基本ルール
/// - 参加者は同額を賭ける(`ChipGameLobby` を使う, 他の CHIP ゲームと同じ).
/// - 倍率は 1.00x から 0.01x ずつ上がっていく. 各自好きなタイミングで STOP できる.
/// - STOP するまで, 他の人が STOP したかどうかは見えない
///   (`BustGameView` 側の表示の作法. データ自体は他の対戦と同じくチャットの
///   メッセージに載るので, チンチロの「めくる前の出目」と同じ扱い. 本人が
///   STOP するまで**画面に出さない**ことで守っている).
/// - 倍率が上がるほど BUST しやすくなる. BUST が起きると, まだ STOP していない
///   全員が同時に脱落する.
/// - BUST が起きなければ, 一番高い倍率で STOP した人が
///   「自分の賭け金 × 自分の倍率」(ただし総ポットが上限)を受け取り,
///   余った分は他の参加者に払い戻す(倍率が高いほど総取りに近づく)。
/// - BUST が起きたら, 脱落した人の賭け金を, 生き残った人たちで
///   「倍率の逆数」の比率で分け合う(早く止めた人ほど多くもらえる)。
/// - 生き残りが 0 人(誰も STOP しないうちに BUST)なら, 全員据え置き(void).
///
/// どの場合も CHIP の総量は厳密に保存される(`chipDeltas` 参照)。
///
/// ## クラッシュ倍率の決め方(と, そこにある重要な割り切り)
/// 「どの倍率で BUST するか」は, 対戦を開始した瞬間に生成する乱数の種
/// (`Round.startSeed`)から, 全端末が同じ式で計算する。この種はチンチロの
/// 出目やチームバトルの山札シャッフルと同じ考え方で, 対戦相手を信頼する前提
/// (暗号までは使わない)。
///
/// **この割り切りは, BUST では他の CHIP ゲームより重い.** `startSeed` は
/// 対戦開始のメッセージにそのまま載って全員に届き, `computeCrashMultiplier`
/// は誰でも呼べる純粋な関数なので, 理屈の上では**参加者の誰か 1 人でも**
/// (対戦を始めたホストに限らず)受け取った `startSeed` からクラッシュ倍率を
/// 自分で計算し, その 1 ティック前で確実に STOP する, ということができてしまう
/// (加えてホストは, 種を何度も試し引きして都合のいい結果だけを送ることもできる)。
/// チンチロの出目やダウトの手札は「対戦相手を信頼する」が破られても自分の
/// 手番の中に被害が閉じるが, BUST は倍率という**全員が見る共通の値**を
/// 種だけから計算できてしまう分, 影響が対戦全体に及ぶ. きちんと対策するには,
/// 全員の入力を集めてから初めて結果が決まる「コミット&リビール」のような
/// 仕組みが要るが, サーバを介さないこの設計では大掛かりになる. 休み時間に
/// 友達と遊ぶ前提でいったんここまでにしているが, **本気で悪用されると経済が
/// 壊れる規模の割り切りなので, 導入前に一度立ち止まって判断したほうがよい.**
struct BustSnapshot: Hashable, Sendable, Codable {

    static let minimumPlayers = 2
    /// これを超えて参加はできない. 4人を超えると, 早くSTOPした人が
    /// 有利になりすぎるバランス崩れが大きくなることがシミュレーションで
    /// 分かっているため, 上限を設けている.
    static let maximumPlayers = 4
    static let maxBet = 50

    /// 倍率の刻み幅.
    static let step = 0.01
    /// これに達したら強制的にクラッシュする(青天井にしない).
    static let maxMultiplier = 30.0
    /// 0.01x ぶん進むのにかかる時間.
    static let tickInterval: TimeInterval = 0.1

    /// BUST 危険度: h(倍率) = hazardCoefficient × (倍率 − 1)^2.
    /// 1.00x では危険度 0, 倍率が上がるほど滑らかに危険になっていく.
    /// シミュレーションで 2〜4 人のバランスが良かった値.
    static let hazardCoefficient = 0.0008
    private static let hazardExponent = 2.0

    struct StopRecord: Hashable, Sendable, Codable {
        var multiplier: Double
        var stoppedAt: Date
    }

    struct Round: Hashable, Sendable, Codable {
        var playerIDs: [UserID]
        var bet: Int
        var startedAt: Date
        /// クラッシュ倍率を決める種. 対戦を開始した端末が生成する.
        var startSeed: UInt64
        /// STOP 済みの人の記録.
        var stops: [UserID: StopRecord]
    }

    enum Phase: Hashable, Sendable, Codable {
        case lobby(ChipGameLobby)
        case playing(Round)
    }

    var gameID: String
    var hostID: UserID
    var phase: Phase

    /// 募集を取り消したか(他の CHIP ゲームと同じ扱い).
    var isCancelled: Bool? = nil

    static func newLobby(hostID: UserID, bet: Int) -> BustSnapshot {
        BustSnapshot(
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

    // MARK: - 倍率とクラッシュ

    /// この対戦のクラッシュ倍率. 対戦が始まっていなければ nil.
    var crashMultiplier: Double? {
        guard let round else { return nil }
        return Self.computeCrashMultiplier(seed: round.startSeed)
    }

    /// `now` の時点で, 何もしなければ表示されているはずの倍率
    /// (クラッシュ倍率や上限を超えては進まない).
    func currentMultiplier(now: Date = .now) -> Double {
        tickState(now: now).multiplier
    }

    /// `now` の時点でもうクラッシュしているか(精算してよいかの猶予は考えない,
    /// 生の判定. 画面上「もう危ない」と見せるための表示専用).
    func isCrashed(now: Date = .now) -> Bool {
        tickState(now: now).isCrashed
    }

    /// クラッシュしてから, 精算してよいと判断するまでの猶予.
    ///
    /// クラッシュした瞬間, 他の人がその直前に送った STOP がまだこの端末に
    /// 同期しきっていないことがある(`ChatStore.currentGame` は最後に届いた
    /// メッセージから状態を組み立てるため)。猶予が短すぎると, まだ届いていない
    /// STOP を「BUST した」ものとして精算してしまい, しかも他の端末は(その
    /// STOP がすでに届いていれば)別の額で精算してしまう ―― 端末どうしで
    /// 違う額を精算すると, CHIP の総量が合わなくなる(生まれたり消えたりする)。
    /// ポーリング間隔(`AppConstants.Timing.activeConversationPollInterval` =
    /// 3秒)の実に十数倍を確保し, 通常の接続状況ではまず追いつくようにする.
    private static let settlementGracePeriod: TimeInterval = 20.0

    /// 全員の判断がついたか(全員 STOP した, またはクラッシュが確定した).
    ///
    /// クラッシュ後すぐには true にならない(`settlementGracePeriod` 参照)。
    /// 「もう表示上はクラッシュしているか」を知りたいだけなら `isCrashed(now:)`
    /// を直接使う(STOP を押せるかの判定や, 倍率表示の上限はそちらを使う).
    var isFinished: Bool {
        tickState().isFinished
    }

    /// `currentMultiplier`/`isCrashed`/`isFinished` が複数要るとき用の窓口
    /// (`BustGameView` が毎秒 10 回呼ぶ).
    ///
    /// `crashMultiplier` は 0.01 刻みグリッドをなぞって求める, それなりに重い
    /// 計算(`computeCrashMultiplier` 参照)。別々に呼ぶと, それぞれが同じ
    /// `crashMultiplier` を計算し直してしまうので, ここで 1 回だけ計算して
    /// まとめて返す.
    func tickState(now: Date = .now) -> (multiplier: Double, isCrashed: Bool, isFinished: Bool) {
        guard let round else { return (1.00, false, false) }
        let crash = crashMultiplier
        let multiplier = currentMultiplier(now: now, crashMultiplier: crash)
        let crashed = crash.map { multiplier >= $0 } ?? false

        if round.playerIDs.allSatisfy({ round.stops[$0] != nil }) {
            return (multiplier, crashed, true)
        }
        guard crashed, let crash else { return (multiplier, crashed, false) }
        let ticksToCrash = (crash - 1.00) / Self.step
        let crashElapsed = ticksToCrash * Self.tickInterval
        let elapsed = now.timeIntervalSince(round.startedAt)
        return (multiplier, crashed, elapsed >= crashElapsed + Self.settlementGracePeriod)
    }

    /// `crashMultiplier` は呼び出し側で 1 度だけ取って渡し直す
    /// (`tickState`/`isCrashed` 参照. 呼ぶたびに毎回計算し直すのは無駄が大きい).
    private func currentMultiplier(now: Date, crashMultiplier: Double?) -> Double {
        guard let round else { return 1.00 }
        let elapsed = max(0, now.timeIntervalSince(round.startedAt))
        // 浮動小数の誤差で, ちょうど刻みの境目(例: 0.3 秒ぴったり)のつもりが
        // ほんの少しだけ小さい値(0.299999999998…)になり, 切り捨てで 1 ティック
        // 損をすることがある. 誤差よりずっと小さい値を足してから切り捨てる.
        let ticks = Double(Int(elapsed / Self.tickInterval + 1e-9))
        let raw = 1.00 + ticks * Self.step
        let cap = crashMultiplier.map { min($0, Self.maxMultiplier) } ?? Self.maxMultiplier
        return min(raw, cap)
    }

    func hasStopped(_ userID: UserID) -> Bool {
        round?.stops[userID] != nil
    }

    /// STOP した状態. 押せない場面(参加者でない・すでに STOP した・
    /// もうクラッシュしている)なら nil.
    func stopping(by userID: UserID, now: Date = .now) -> BustSnapshot? {
        guard var round, round.playerIDs.contains(userID), round.stops[userID] == nil else { return nil }
        let crash = crashMultiplier
        let multiplier = currentMultiplier(now: now, crashMultiplier: crash)
        if let crash, multiplier >= crash { return nil }
        round.stops[userID] = StopRecord(multiplier: multiplier, stoppedAt: now)
        var next = self
        next.phase = .playing(round)
        return next
    }

    /// 脱落した(STOP しないままクラッシュを迎えた)人.
    var bustedPlayerIDs: [UserID] {
        guard let round, isFinished else { return [] }
        return round.playerIDs.filter { round.stops[$0] == nil }
    }

    /// 生き残った(STOP できた)人.
    var survivorPlayerIDs: [UserID] {
        guard let round, isFinished else { return [] }
        return round.playerIDs.filter { round.stops[$0] != nil }
    }

    /// 精算. 総量は常に賭け金の合計とぴったり一致する(CHIP を生まない・消さない).
    var chipDeltas: [UserID: Int] {
        guard let round, isFinished else { return [:] }

        // `bustedPlayerIDs`/`survivorPlayerIDs` を使うと, どちらも中で
        // `isFinished`(≒ 重い `crashMultiplier` の計算)を確かめ直してしまう.
        // ここではもう確かめ済みなので, 同じ絞り込みを直接行う.
        let busted = round.playerIDs.filter { round.stops[$0] == nil }
        let survivors = round.playerIDs.filter { round.stops[$0] != nil }
        let pot = round.bet * round.playerIDs.count

        // ケース1: BUST なし(全員が自分の判断で STOP できた)
        // -> 一番高い倍率の人が「賭け金×倍率」(ただしポットが上限)を受け取り,
        //    余りは他の参加者に均等に払い戻す. 同じ倍率で並んだ場合は
        //    (0.1秒刻みなので, ほぼ同時に STOP すると起こり得る)その人たちで
        //    均等に山分けする(チンチロの同着と同じ考え方).
        guard !busted.isEmpty else {
            guard let topMultiplier = survivors.compactMap({ round.stops[$0]?.multiplier }).max()
            else { return [:] }
            let winners = survivors.filter { round.stops[$0]?.multiplier == topMultiplier }
            let others = round.playerIDs.filter { !winners.contains($0) }

            // 山分けする相手(others)がいない=全員が同着なら, 払い戻す先が無い
            // ので, 端数を消してしまわないようポット全額をそのまま勝者だけで
            // 分ける(でなければ余り(remainder)が誰にも渡らず CHIP が消える).
            let winnerGrossInt: Int
            if others.isEmpty {
                winnerGrossInt = pot
            } else {
                let winnerGross = min(Double(pot), Double(round.bet) * topMultiplier)
                winnerGrossInt = Int(winnerGross.rounded())
            }
            let remainder = pot - winnerGrossInt

            var deltas: [UserID: Int] = [:]
            let baseShare = winnerGrossInt / winners.count
            var winnerExtra = winnerGrossInt % winners.count
            for winner in winners {
                var share = baseShare
                if winnerExtra > 0 { share += 1; winnerExtra -= 1 }
                deltas[winner] = share - round.bet
            }

            if !others.isEmpty {
                let share = remainder / others.count
                var extra = remainder % others.count
                for playerID in others {
                    var refund = share
                    if extra > 0 { refund += 1; extra -= 1 }
                    deltas[playerID] = -round.bet + refund
                }
            }
            return deltas
        }

        // ケース2: 生存者が 0 人(誰も STOP しないうちに BUST) -> void, 全員据え置き.
        guard !survivors.isEmpty else {
            return Dictionary(uniqueKeysWithValues: round.playerIDs.map { ($0, 0) })
        }

        // ケース3: BUST あり, 生存者がいる
        // -> 脱落した人の賭け金を, 生存者どうしで「倍率の逆数」の比率で分ける
        //    (最も公平な端数処理として, 最大剰余法(Hamilton 方式)を使い,
        //    総量が寸分違わずぴったり合うようにする).
        var deltas: [UserID: Int] = [:]
        for playerID in busted { deltas[playerID] = -round.bet }

        let bustedPot = round.bet * busted.count
        let weights = survivors.map { 1.0 / (round.stops[$0]?.multiplier ?? 1.0) }
        let weightSum = weights.reduce(0, +)
        let rawShares = weights.map { weightSum > 0 ? Double(bustedPot) * $0 / weightSum : 0 }
        var shares = rawShares.map { Int($0) } // 切り捨て(常に 0 以上)
        var leftover = bustedPot - shares.reduce(0, +)

        // 端数(切り捨てで失った分)が大きい人から 1 ずつ配る.
        let byRemainder = rawShares.enumerated().sorted {
            (rawShares[$0.offset] - Double(shares[$0.offset])) > (rawShares[$1.offset] - Double(shares[$1.offset]))
        }
        for entry in byRemainder {
            guard leftover > 0 else { break }
            shares[entry.offset] += 1
            leftover -= 1
        }

        for (index, playerID) in survivors.enumerated() {
            deltas[playerID] = shares[index]
        }
        return deltas
    }

    // MARK: - 同時に STOP したメッセージの畳み込み

    /// 同じ対戦(`gameID`)のメッセージを 1 つに畳み込む.
    ///
    /// ## なぜ畳み込みが必要か
    /// このアプリの対戦は「1 手 = 1 メッセージ, 最後のメッセージが現在の状態」
    /// という設計(`ChatStore.currentGame` 参照)になっている. BUST は
    /// 「STOP するまで他人の状況が見えない」ぶん, 複数人がほぼ同時に STOP を
    /// 押しやすい遊びで, これはインディアンポーカーの「勝負する/降りる」と
    /// 同じ状況(`IndianPokerSnapshot.merged` 参照)。時系列で後のメッセージ
    /// だけを現在の状態にすると, 先に送られた STOP が消え, 「STOP したのに
    /// BUST 扱いにされる」ことが起こり得る。
    ///
    /// 一度埋まった `stops` は, 後続のメッセージに引き継がれていなくても消さない
    /// (STOP は一度きりで変わらないので, どのメッセージの値を採っても食い違わない)。
    static func merged(_ snapshots: [BustSnapshot]) -> BustSnapshot {
        guard let base = snapshots.last else {
            preconditionFailure("merged(_:) には 1 件以上渡す")
        }
        guard var round = base.round else { return base }

        for snapshot in snapshots {
            guard let other = snapshot.round else { continue }
            for (playerID, stop) in other.stops where round.stops[playerID] == nil {
                round.stops[playerID] = stop
            }
        }

        var merged = base
        merged.phase = .playing(round)
        return merged
    }

    // MARK: - 画面表示用

    /// 現在の倍率での危険度を, ゲージ表示用に 0〜1 へ正規化したもの.
    ///
    /// クラッシュ倍率(秘密)そのものは使わない. あくまで「いまどれくらい
    /// 危ないか」の目安として, 公開されているハザード関数だけから計算する.
    static func dangerGaugeFraction(at multiplier: Double) -> Double {
        let hazardAtCap = hazardCoefficient * pow(maxMultiplier - 1.0, hazardExponent)
        guard hazardAtCap > 0 else { return 0 }
        let hazardNow = hazardCoefficient * pow(max(0, multiplier - 1.0), hazardExponent)
        return min(1.0, hazardNow / hazardAtCap)
    }

    // MARK: - クラッシュ倍率の計算

    /// 種からクラッシュ倍率を計算する.
    ///
    /// `h(倍率) = hazardCoefficient × (倍率−1)^2` というハザード関数から,
    /// 生存関数の逆変換抽出法でクラッシュ倍率を 1 つ引く。0.01 刻みのグリッド上を
    /// 端から順に見ていき, 累積クラッシュ確率が引いた乱数を初めて超えたところが
    /// クラッシュ倍率になる(`maxMultiplier` に達したら必ずそこでクラッシュする)。
    static func computeCrashMultiplier(seed: UInt64) -> Double {
        var generator = SeededGenerator(seed: seed)
        // [0, 1) の一様乱数(52bit あれば CHIP ゲームには十分な精度).
        let u = Double(generator.next() % (1 << 52)) / Double(1 << 52)

        let tickCount = Int(((maxMultiplier - 1.00) / step).rounded())
        var survival = 1.0
        for i in 0...tickCount {
            let m = 1.00 + Double(i) * step
            let hazard = (i == tickCount) ? 1.0 : min(1.0, hazardCoefficient * pow(m - 1.0, hazardExponent))
            survival *= (1.0 - hazard)
            if 1.0 - survival >= u {
                return (m * 100).rounded() / 100
            }
        }
        return maxMultiplier
    }
}
