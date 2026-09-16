import Foundation

/// 画面に出すレース 1 回ぶんの状態.
struct HorseRaceState: Sendable {

    let raceID: String
    let card: HorseRaceCard
    var phase: HorseRaceSchedule.Phase
    /// 自分が買った馬券.
    var myBets: [HorseRaceBet]
    /// このレースに入っている馬券の総数(自分以外も含む).
    var totalBetCount: Int
    /// 種が確定していれば, 再現したレース.
    var run: HorseRaceRun?
    /// 精算済みの払い戻し額. まだ精算していなければ nil.
    var payout: Int?
    /// 公表された種が材料どおりに作られていなかった場合に true.
    /// このときは精算しない(`ChatStore.settleHorseRaceIfNeeded` 参照).
    var isResultUntrusted: Bool = false

    /// 自分が賭けた合計.
    var myTotalStake: Int { myBets.reduce(0) { $0 + $1.amount } }
}

/// 競馬. チャットの中の対戦と違い, 会話に紐づかない「みんなで見る場所」なので,
/// 状態は画面側が持ち, ストアは取得と書き込みだけを受け持つ.
extension ChatStore {

    /// レースの状態をまとめて読み込む.
    ///
    /// 締切を過ぎていて, まだ誰も種を確定させていなければ, ここで確定させる
    /// (先に開いた端末が 1 件だけ作る).
    func loadHorseRace(raceID: String, now: Date = .now) async -> HorseRaceState {
        let card = HorseRaceCard(raceID: raceID)
        let phase = HorseRaceSchedule.phase(raceID: raceID, now: now)
        var state = HorseRaceState(
            raceID: raceID,
            card: card,
            phase: phase,
            myBets: [],
            totalBetCount: 0,
            run: nil,
            payout: nil
        )

        let bets: [HorseRaceBet]
        do {
            bets = try await backend.fetchHorseRaceBets(raceID: raceID)
        } catch {
            banner = AppError.wrap(error)
            return state
        }

        state.totalBetCount = bets.count
        if let me = currentUserID {
            state.myBets = bets.filter { $0.bettorID == me }
        }

        // 発走前なら, ここまで(結果はまだ無い).
        guard case .finished = phase else { return state }

        do {
            let result = try await resolvedResult(raceID: raceID, bets: bets)
            guard let result else { return state }

            // 公表された種が, 材料どおりに作られたものかを確かめる.
            // 確定レコードは作った人があとから書き換えられるため, 読む側で必ず検算する.
            state.isResultUntrusted = !result.isConsistent(with: bets)
            state.run = HorseRaceRun(card: card, seed: result.seed)
            state.payout = await settleHorseRaceIfNeeded(state: state, result: result)
        } catch {
            banner = AppError.wrap(error)
        }
        return state
    }

    /// 馬券を買う.
    ///
    /// 先に CHIP を引いてから馬券を保存する. 逆にすると, 保存できたのに
    /// 引き落とせなかった場合に「払っていない馬券」ができてしまうため.
    /// 保存に失敗したときは引いたぶんを戻す.
    func placeHorseRaceBet(
        raceID: String,
        kind: HorseRaceBetKind,
        selections: [Int],
        amount: Int,
        now: Date = .now
    ) async -> Bool {
        guard let me = currentUserID else { return false }

        guard case .betting = HorseRaceSchedule.phase(raceID: raceID, now: now) else {
            banner = .underlying(String(localized: "受付は終了しました"))
            return false
        }
        guard kind.isValid(selections: selections, horseCount: HorseRaceRules.horseCount) else {
            banner = .underlying(String(localized: "買い目が正しくありません"))
            return false
        }
        guard let myWallet else { return false }
        if myWallet.isBankrupt() {
            banner = .underlying(bankruptNotice ?? String(localized: "いまは CHIP を使う遊びができません"))
            return false
        }
        guard ChipRules.isValidBet(amount, maxBet: HorseRaceRules.maxBet, balance: myWallet.balance) else {
            banner = .underlying(String(localized: "その額は賭けられません(持っている CHIP を確認してください)"))
            return false
        }

        let bet = HorseRaceBet(
            raceID: raceID,
            bettorID: me,
            kind: kind,
            selections: selections,
            amount: amount
        )

        // 引き落とし. 対戦 ID は記録しない(同じ馬券をもう一度引く場面が無く,
        // 記録すると精算の重複防止に使っている一覧をいたずらに埋めてしまうため).
        do {
            self.myWallet = try await backend.applyChipDelta(-amount, gameID: nil)
        } catch {
            banner = AppError.wrap(error)
            return false
        }

        do {
            try await backend.placeHorseRaceBet(bet)
            return true
        } catch {
            // 買えなかったので引いたぶんを戻す.
            if let restored = try? await backend.applyChipDelta(amount, gameID: nil) {
                self.myWallet = restored
            }
            banner = AppError.wrap(error)
            return false
        }
    }

    /// 買ったまま何日か開かなかった人に, あとから払い戻しを届ける.
    ///
    /// アプリを開いた日が開催日でなくても, 直近の開催日ぶんをさかのぼって確かめる.
    func settleRecentHorseRaces(now: Date = .now) async {
        guard currentUserID != nil else { return }
        for raceID in HorseRaceSchedule.recentRaceIDs(upTo: now) {
            // 発走前のレースは精算しない.
            guard case .finished = HorseRaceSchedule.phase(raceID: raceID, now: now) else { continue }
            // すでに精算済みなら通信しない.
            if myWallet?.hasSettled(gameID: Self.horseRaceSettlementID(raceID: raceID)) == true { continue }
            _ = await loadHorseRace(raceID: raceID, now: now)
        }
    }

    // MARK: - 内部

    /// 精算を二重にしないための記録用 ID.
    static func horseRaceSettlementID(raceID: String) -> String { "race-\(raceID)" }

    /// 確定した種を取る. まだ無ければ, ここで 1 件だけ作る.
    private func resolvedResult(raceID: String, bets: [HorseRaceBet]) async throws -> HorseRaceResult? {
        if let existing = try await backend.fetchHorseRaceResult(raceID: raceID) { return existing }
        return try await backend.lockHorseRaceResult(raceID: raceID, bets: bets)
    }

    /// 自分のぶんだけ CHIP に反映する. 反映した払い戻し額を返す.
    ///
    /// 他人の残高は書き換えられないので, 各自の端末が自分のぶんを反映する
    /// (チャットの中の対戦と同じ考え方).
    private func settleHorseRaceIfNeeded(state: HorseRaceState, result: HorseRaceResult) async -> Int? {
        guard let run = state.run else { return nil }
        // 検算に通らなかった種では精算しない(細工された可能性があるため).
        guard !state.isResultUntrusted else { return nil }
        guard !state.myBets.isEmpty else { return nil }

        let settlementID = Self.horseRaceSettlementID(raceID: state.raceID)
        if myWallet?.hasSettled(gameID: settlementID) == true {
            // すでに反映済み. 画面に出す額だけ計算し直す.
            return run.totalPayout(for: state.myBets.filter { result.betIDs.contains($0.id) })
        }

        // 締切に間に合わず種の材料に入らなかった馬券は, レースに参加していないので
        // 賭けたぶんをそのまま返す.
        let counted = state.myBets.filter { result.betIDs.contains($0.id) }
        let uncounted = state.myBets.filter { !result.betIDs.contains($0.id) }
        let payout = run.totalPayout(for: counted)
        let refund = uncounted.reduce(0) { $0 + $1.amount }

        do {
            myWallet = try await backend.applyChipDelta(payout + refund, gameID: settlementID)
            return payout
        } catch {
            banner = AppError.wrap(error)
            return nil
        }
    }
}
