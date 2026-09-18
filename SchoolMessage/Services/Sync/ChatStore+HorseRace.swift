import Foundation

/// 画面に出すレース 1 回ぶんの状態.
struct HorseRaceState: Sendable {

    let raceID: String
    let card: HorseRaceCard
    var phase: HorseRaceSchedule.Phase
    /// 自分が買った馬券.
    var myBets: [HorseRaceBet]
    /// 締切後に名前付きで公開する, 全員ぶんの馬券.
    ///
    /// 受付中は空のまま. 締切前に他人の予想が見えると, 人気馬に乗るだけの
    /// 買い方ができてしまい, 出走表を読む意味が無くなるため
    /// (画面に渡さないことで, 誤って出してしまう余地も無くしている).
    var publicBets: [HorseRaceBet] = []
    /// このレースに入っている馬券の総数(自分以外も含む).
    var totalBetCount: Int
    /// 種が確定していれば, 再現したレース.
    var run: HorseRaceRun?
    /// 精算済みの受け取り額. まだ精算していなければ nil.
    ///
    /// 「的中した分の払い戻し」と, 締切に間に合わず種の材料に入らなかった
    /// 馬券の「そのままの返金」を合わせた, 実際に CHIP へ反映された総額
    /// (`ChatStore.settleHorseRaceIfNeeded` 参照). 以前は払い戻しだけで
    /// 返金を含んでいなかったため, 画面の表示額と実際の CHIP 残高の増減が
    /// 食い違っていた.
    var payout: Int?
    /// 締切に間に合わず, 種の材料(`HorseRaceResult.betIDs`)に入らなかった
    /// 自分の馬券の ID.
    ///
    /// これに入っている馬券は, レースの着順とは関係なく賭けた額がそのまま
    /// 返ってくる. 画面ではこれを「外れ」ではなく「返金」として区別する
    /// (`myBetsSection` 参照) — そうしないと, すべての馬券が「外れ」と
    /// 表示されているのに CHIP は減っていない(または増えている)という,
    /// 「当たっていないのに増えた」ように見える食い違いが起きる.
    var refundedBetIDs: Set<String> = []
    /// 公表された種が材料どおりに作られていなかった場合に true.
    /// このときは精算しない(`ChatStore.settleHorseRaceIfNeeded` 参照).
    var isResultUntrusted: Bool = false
    /// 馬券の一覧をサーバから取れたか.
    ///
    /// 取れなかったときも `myBets` は空になるが, それは「買っていない」では
    /// なく「まだ分からない」なので, 呼び出し側が区別できるようにしておく
    /// (`ChatStore.settleRecentHorseRaces` 参照).
    var didLoadBets: Bool = false

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
            // 【診断ログ】ここで失敗していれば, まだ精算どころか馬券の一覧すら
            // 読めていない. CloudKit の Production スキーマに HorseRaceBet /
            // HorseRaceResult がまだ反映されていない場合もここに来る
            // (docs/TODAY.md の「CloudKit スキーマを取り込んで Deploy」参照).
            let description = AppError.wrap(error).localizedDescription
            Log.backend.error("HORSE FETCH BETS FAILED raceID=\(raceID, privacy: .public) error=\(description, privacy: .public)")
            banner = AppError.wrap(error)
            return state
        }

        state.didLoadBets = true
        state.totalBetCount = bets.count
        if let me = currentUserID {
            state.myBets = bets.filter { $0.bettorID == me }
        }
        // 【診断ログ】ここで myBets が 0 なら, 以降の精算はそもそも走らない
        // (`settleHorseRaceIfNeeded` の `guard !state.myBets.isEmpty else { return nil }`).
        // 「買ったのに 0 件」なら, currentUserID と馬券の bettorID が食い違っている
        // (アカウント切り替えの持ち越し等)可能性が高い.
        let meDescription = currentUserID?.rawValue ?? "nil"
        Log.backend.notice("HORSE LOAD raceID=\(raceID, privacy: .public) phase=\(String(describing: phase), privacy: .public) me=\(meDescription, privacy: .public) totalBets=\(bets.count, privacy: .public) myBets=\(state.myBets.count, privacy: .public)")
        switch phase {
        case .betting:
            break
        case .closed, .finished:
            state.publicBets = bets
            // 名前を出すために, まだ持っていないプロフィールをまとめて取る
            // (競馬は友達に限らず誰でも買うので, 手元に無いことがある).
            let missing = Set(bets.map(\.bettorID)).subtracting(profilesByID.keys)
            if !missing.isEmpty, let profiles = try? await backend.fetchProfiles(ids: Array(missing)) {
                for profile in profiles { profilesByID[profile.id] = profile }
            }
        }

        // 発走前なら, ここまで(結果はまだ無い).
        guard case .finished = phase else { return state }

        do {
            let result = try await resolvedResult(raceID: raceID, bets: bets)
            guard let result else {
                // 【診断ログ】結果の確定・取得の両方に失敗した(通常はここに来ない).
                Log.backend.notice("HORSE RESULT raceID=\(raceID, privacy: .public) result=nil")
                return state
            }

            // 公表された種が, 材料どおりに作られたものかを確かめる.
            // 確定レコードは作った人があとから書き換えられるため, 読む側で必ず検算する.
            state.isResultUntrusted = !result.isConsistent(with: bets)
            // 【診断ログ】ここが true のまま止まっているなら, 精算はここで完全に
            // 止まる(`settleHorseRaceIfNeeded` の `guard !state.isResultUntrusted`).
            // resultBetIDs と fetchedBets の件数のズレを見れば,
            // 「締切後に来た馬券が種の材料に入らなかった」のか
            // 「種そのものが書き換えられた」のか切り分けられる.
            Log.backend.notice("HORSE CONSISTENCY raceID=\(raceID, privacy: .public) isResultUntrusted=\(state.isResultUntrusted, privacy: .public) resultBetIDs=\(result.betIDs.count, privacy: .public) fetchedBets=\(bets.count, privacy: .public)")
            state.run = HorseRaceRun(card: card, seed: result.seed)
            // 自分の馬券のうち, 種の材料に入らなかった(＝レースの着順とは
            // 関係なく賭けた額がそのまま返ってくる)ものを, 表示のために覚えておく.
            state.refundedBetIDs = Set(state.myBets.map(\.id)).subtracting(result.betIDs)
            state.payout = await settleHorseRaceIfNeeded(state: state, result: result)
            Log.backend.notice("HORSE PAYOUT raceID=\(raceID, privacy: .public) payout=\(state.payout.map(String.init) ?? "nil", privacy: .public)")
            // 端末の時計のズレで, 馬券が1件も無いまま結果が確定してしまった日の
            // 埋め合わせ(`applyKnownBrokenRaceCorrectionIfNeeded` 参照).
            await applyKnownBrokenRaceCorrectionIfNeeded(state: state, result: result)
        } catch {
            // 【診断ログ】以前はここで起きた例外が画面上部のバナーにしか出ず,
            // あとから追えなかった. 「精算まで到達すらしていない」ケースの主な
            // 原因はここ(結果の確定・取得での CloudKit エラー)である可能性が高い.
            let description = AppError.wrap(error).localizedDescription
            Log.backend.error("HORSE LOAD FAILED raceID=\(raceID, privacy: .public) error=\(description, privacy: .public)")
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
        // 残高が未取得のまま黙って終わらせない(`assertCanBet` と同じ扱い).
        guard let myWallet else {
            banner = .underlying(String(localized: "CHIPの残高を読み込めていません。少し待ってからもう一度お試しください"))
            Task { await refreshWallet() }
            return false
        }
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

        // 引き落とし. 馬券 1 枚ごとの ID を残す.
        //
        // ランキングは「1 回でも遊び終えた人」だけを並べる仕組みで, その判定に
        // この記録(`PlayerWallet.settledGameIDs`)を使っている. ここを空のままに
        // すると, 馬券を買って CHIP が減っているのに, レースの精算が済むまで
        // ランキングに出てこない(競馬しか遊ばない人は特に分かりにくい).
        //
        // 精算の重複防止に使う ID(`race-<開催日>`)とは別の名前にしてあるので,
        // 払い戻しが「精算済み」と誤判定されることはない.
        do {
            self.myWallet = try await backend.applyChipDelta(-amount, gameID: "race-bet-\(bet.id)")
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
            // この起動中に確かめて, 馬券が無かった日も通信しない.
            if checkedHorseRaceIDs.contains(raceID) { continue }

            let state = await loadHorseRace(raceID: raceID, now: now)
            // 馬券が無ければ, この先も精算するものは出てこない(確定後のレースは
            // 変わらないため). 開いている間の繰り返しを止める.
            //
            // ただし **取得に成功したときだけ** 止める. 以前は通信に失敗した
            // ときも `myBets` が空になるためここで「確かめ済み」に入れてしまい,
            // 電波が悪かった 1 回のせいで, アプリを起動し直すまでその開催日の
            // 払い戻しが二度と入らなくなっていた(CHIP が増えない原因の一つ).
            if state.didLoadBets, state.myBets.isEmpty {
                checkedHorseRaceIDs.insert(raceID)
            }
        }
    }

    // MARK: - 内部

    /// 精算を二重にしないための記録用 ID.
    static func horseRaceSettlementID(raceID: String) -> String { "race-\(raceID)" }

    /// 確定した種を取る. まだ無ければ, ここで 1 件だけ作る.
    private func resolvedResult(raceID: String, bets: [HorseRaceBet]) async throws -> HorseRaceResult? {
        if let existing = try await backend.fetchHorseRaceResult(raceID: raceID) {
            Log.backend.notice("HORSE RESULT SOURCE raceID=\(raceID, privacy: .public) source=existing betIDs=\(existing.betIDs.count, privacy: .public)")
            return existing
        }
        let locked = try await backend.lockHorseRaceResult(raceID: raceID, bets: bets)
        Log.backend.notice("HORSE RESULT SOURCE raceID=\(raceID, privacy: .public) source=locked-by-this-device betIDs=\(locked.betIDs.count, privacy: .public)")
        return locked
    }

    /// 自分のぶんだけ CHIP に反映する. 反映した総額(払い戻し + 返金)を返す.
    ///
    /// 他人の残高は書き換えられないので, 各自の端末が自分のぶんを反映する
    /// (チャットの中の対戦と同じ考え方).
    ///
    /// 戻り値は「的中した分の払い戻し」だけでなく, 種の材料に入らなかった
    /// 馬券の「そのままの返金」も含めた合計にする. `applyChipDelta` に渡す
    /// 差分(`delta = payout + refund`)と必ず一致させる — ここが食い違うと,
    /// 実際の CHIP 残高は正しく増えているのに, 画面の結果表示
    /// (`ChipResultBanner`)だけが少なく見える(以前の不具合).
    private func settleHorseRaceIfNeeded(state: HorseRaceState, result: HorseRaceResult) async -> Int? {
        let settlementID = Self.horseRaceSettlementID(raceID: state.raceID)
        // 【診断ログ】ここでどの guard に引っかかって nil を返しているかが分かれば,
        // ①〜④のどこで止まっているかがそのまま確定する.
        //
        // `myWallet` の参照は先に変数へ取り出しておく. OSLog の文字列補間に
        // `self` を経由するプロパティを直接書くと, 内部で @escaping な
        // クロージャとして展開されるため, Swift 6 の厳格な並行性検査で
        // 「クロージャ内での self の暗黙キャプチャ」としてビルドエラーになる
        // (実機のビルドで実際に検出された: ChatStore+HorseRace.swift:255).
        let alreadySettled = myWallet?.hasSettled(gameID: settlementID) ?? false
        Log.backend.notice("HORSE SETTLE ENTER raceID=\(state.raceID, privacy: .public) hasRun=\(state.run != nil, privacy: .public) isResultUntrusted=\(state.isResultUntrusted, privacy: .public) myBets=\(state.myBets.count, privacy: .public) alreadySettled=\(alreadySettled, privacy: .public)")

        guard let run = state.run else {
            Log.backend.notice("HORSE SETTLE ABORT raceID=\(state.raceID, privacy: .public) reason=no-run")
            return nil
        }
        // 検算に通らなかった種では精算しない(細工された可能性があるため).
        guard !state.isResultUntrusted else {
            Log.backend.notice("HORSE SETTLE ABORT raceID=\(state.raceID, privacy: .public) reason=untrusted-result")
            return nil
        }
        guard !state.myBets.isEmpty else {
            Log.backend.notice("HORSE SETTLE ABORT raceID=\(state.raceID, privacy: .public) reason=no-my-bets")
            return nil
        }

        if myWallet?.hasSettled(gameID: settlementID) == true {
            // すでに反映済み. 画面に出す額だけ計算し直す.
            // (以前は払い戻し分だけを計算しており, 返金分が抜けていたため,
            //  再度画面を開き直すと合計が実際の増減より少なく見えていた)
            let counted = state.myBets.filter { result.betIDs.contains($0.id) }
            let uncounted = state.myBets.filter { !result.betIDs.contains($0.id) }
            let payout = run.totalPayout(for: counted) + uncounted.reduce(0) { $0 + $1.amount }
            Log.backend.notice("HORSE SETTLE ALREADY-DONE raceID=\(state.raceID, privacy: .public) displayedPayout=\(payout, privacy: .public)")
            return payout
        }

        // 締切に間に合わず種の材料に入らなかった馬券は, レースに参加していないので
        // 賭けたぶんをそのまま返す.
        let counted = state.myBets.filter { result.betIDs.contains($0.id) }
        let uncounted = state.myBets.filter { !result.betIDs.contains($0.id) }
        let payout = run.totalPayout(for: counted)
        let refund = uncounted.reduce(0) { $0 + $1.amount }
        let delta = payout + refund

        // 【診断ログ】ここまで到達していれば, あとは CloudKit への書き込みが
        // 成功しているかどうかだけの問題になる.
        Log.backend.notice("HORSE CHIP DELTA START raceID=\(state.raceID, privacy: .public) gameID=\(settlementID, privacy: .public) counted=\(counted.count, privacy: .public) uncounted=\(uncounted.count, privacy: .public) payout=\(payout, privacy: .public) refund=\(refund, privacy: .public) delta=\(delta, privacy: .public)")

        do {
            let saved = try await backend.applyChipDelta(delta, gameID: settlementID)
            myWallet = saved
            Log.backend.notice("HORSE CHIP DELTA SUCCESS raceID=\(state.raceID, privacy: .public) newBalance=\(saved.balance, privacy: .public) settledGameIDs=\(saved.settledGameIDs.count, privacy: .public)")
            // CHIP へ実際に反映したのは `delta`(= payout + refund) であり,
            // 画面の結果表示もこれと必ず一致させる. ここを `payout` だけに
            // していたのが「的中していないのに増えた(ように見える)」不具合の
            // 実体 — 実際には的中せず, 締切に間に合わず種の材料に入らなかった
            // 馬券が全額返金されていただけなのに, その返金が画面のどこにも
            // 出ていなかったため, 利用者からは説明のつかない増加に見えていた.
            return delta
        } catch {
            let description = AppError.wrap(error).localizedDescription
            Log.backend.error("HORSE CHIP DELTA FAILED raceID=\(state.raceID, privacy: .public) gameID=\(settlementID, privacy: .public) error=\(description, privacy: .public)")
            banner = AppError.wrap(error)
            return nil
        }
    }

    // MARK: - 過去の誤精算の埋め合わせ

    /// 端末の時計・タイムゾーンのズレが原因で, 馬券が1件も無いまま
    /// (`HorseRaceResult.betIDs` が空のまま)結果が確定してしまった開催日.
    ///
    /// この日は `settleHorseRaceIfNeeded` が「締切に間に合わなかった馬券」
    /// として全員ぶんの馬券を扱い, 的中・不的中に関係なく賭けた額をそのまま
    /// 全額返金していた. `HorseRaceSchedule` 側のタイムゾーンを固定した
    /// ことで新たに起きることは無いはずだが, 起きてしまった開催日ぶんは
    /// 別途 CloudKit 上で結果を正しい馬券一覧から作り直したうえで,
    /// この一覧に載せて埋め合わせる(直った開催日は削除してよい).
    ///
    /// - `2026-09-18`: CloudKit Dashboard で確認済み(馬券 58 件に対し betIDs が空).
    /// - `2026-09-17`: 同じく確認済み(馬券 45 件に対し betIDs が空. 締切
    ///   〈9/17 5:55 UTC〉より前の 9/16 13:56:51 UTC に確定してしまっていた).
    private static let knownEmptyResultRaceIDs: Set<String> = ["2026-09-18", "2026-09-17"]

    /// 誤って全額返金だけで終わっていた分と, 本来の払い戻し額との差額を, 一度だけ埋め合わせる.
    ///
    /// 対象は `knownEmptyResultRaceIDs` に載っている開催日だけ. かつ, その日の
    /// `HorseRaceResult` が(CloudKit 上で作り直されて)実際に馬券を含むように
    /// なってから初めて動く — 壊れたまま(`betIDs` が空のまま)のときに動くと,
    /// 「差額 0」を精算済みとして記録してしまい, 直ったあとも二度と埋め合わせ
    /// られなくなるため, 必ず `!result.betIDs.isEmpty` を確かめてから行う.
    private func applyKnownBrokenRaceCorrectionIfNeeded(state: HorseRaceState, result: HorseRaceResult) async {
        guard Self.knownEmptyResultRaceIDs.contains(state.raceID) else { return }
        // 壊れた結果のままなら, 直るまで何もしない(上記参照).
        guard !result.betIDs.isEmpty else { return }
        guard !state.isResultUntrusted, let run = state.run else { return }
        guard !state.myBets.isEmpty else { return }

        let correctionID = "\(Self.horseRaceSettlementID(raceID: state.raceID))-fix"
        if myWallet?.hasSettled(gameID: correctionID) == true { return }

        // 壊れていたときは `betIDs` が空だったため, 的中・不的中に関係なく
        // 「賭けた額の合計」をそのまま全額受け取っている. 本来受け取るべき額
        // (正しい結果での払い戻し + 種の材料に入らなかった分の返金)との差額
        // だけを, ここで一度だけ追加で反映する.
        let counted = state.myBets.filter { result.betIDs.contains($0.id) }
        let uncounted = state.myBets.filter { !result.betIDs.contains($0.id) }
        let trueTotal = run.totalPayout(for: counted) + uncounted.reduce(0) { $0 + $1.amount }
        let alreadyReceived = state.myBets.reduce(0) { $0 + $1.amount }
        let correction = trueTotal - alreadyReceived

        Log.backend.notice("HORSE CORRECTION raceID=\(state.raceID, privacy: .public) trueTotal=\(trueTotal, privacy: .public) alreadyReceived=\(alreadyReceived, privacy: .public) correction=\(correction, privacy: .public)")

        do {
            let saved = try await backend.applyChipDelta(correction, gameID: correctionID)
            myWallet = saved
            Log.backend.notice("HORSE CORRECTION SUCCESS raceID=\(state.raceID, privacy: .public) newBalance=\(saved.balance, privacy: .public)")
        } catch {
            let description = AppError.wrap(error).localizedDescription
            Log.backend.error("HORSE CORRECTION FAILED raceID=\(state.raceID, privacy: .public) error=\(description, privacy: .public)")
            // 埋め合わせが失敗しても, 通常の対戦結果を隠すほどのことではないので
            // banner は出さない(次に開いたときにまた自動で試す).
        }
    }
}
