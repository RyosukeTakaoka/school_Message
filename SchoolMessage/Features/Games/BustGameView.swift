import Foundation
import SwiftUI

/// BUST の対戦画面.
///
/// 倍率は端末ごとのローカルなタイマーで進める(`BustSnapshot.currentMultiplier`
/// が開始時刻からの経過時間だけで決まる純粋な関数なので, サーバから逐一
/// 押してもらう必要が無い). STOP した人だけが自分のぶんのメッセージを送る.
///
/// 「STOP するまで他人の状況は見えない」は, データ自体はチャットの
/// メッセージに載って全員の端末に届いてしまうので, 見せ方(`revealOthers`)
/// で守っている(チンチロで自分の出目を演出が終わるまで隠すのと同じ考え方)。
struct BustGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var displayMultiplier = 1.00
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: BustSnapshot? {
        store.activeGame(kind: .bust, in: conversationID)?.bust
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.bust.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .bust,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinBust(in: conversationID) } },
                            onLeave: { run { await store.leaveGameLobby(kind: .bust, in: conversationID) } },
                            onCancel: store.canCancelGame(kind: .bust, in: conversationID)
                                ? { run { await store.cancelGame(kind: .bust, in: conversationID) } }
                                : nil,
                            onStart: { run { await store.startBust(in: conversationID) } },
                            maximumPlayers: GameSnapshot.Kind.bust.maximumPlayers
                        )
                    case .playing:
                        roundView(snapshot)
                    }
                } else {
                    ChipGameStartPrompt(kind: .bust, rules: GameSnapshot.Kind.bust.rules) { bet in
                        run { await store.createBustLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot, snapshot.isFinished, let me else { return }
            settledDelta = await store.settleChipsIfNeeded(for: .bust(snapshot)) ?? snapshot.chipDeltas[me]
        }
    }

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: BustSnapshot) -> some View {
        if let round = snapshot.round {
            // クラッシュ倍率を毎回計算し直すそれなりに重い処理
            // (`BustSnapshot.tickState` のコメント参照)なので,
            // この描画の中で 1 度だけまとめて取って使い回す.
            let tick = snapshot.tickState()
            let isFinished = tick.isFinished
            let isCrashed = tick.isCrashed
            let myStop = me.flatMap { round.stops[$0] }
            let isPlayer = me.map { round.playerIDs.contains($0) } ?? false
            let revealOthers = myStop != nil || isFinished
            // 決着した人・していない人と最終的な増減も, ここで(倍率の計算を
            // 経由せず `round.stops` から直接)1 度だけ求めて使い回す.
            let busted = isFinished ? round.playerIDs.filter { round.stops[$0] == nil } : []
            let survivors = isFinished ? round.playerIDs.filter { round.stops[$0] != nil } : []
            let deltas = isFinished ? snapshot.chipDeltas : [:]

            ScrollView {
                VStack(spacing: AppConstants.Layout.standardSpacing) {
                    HStack {
                        Label(String(localized: "1人 \(ChipRules.formatted(round.bet))"), systemImage: "circle.hexagongrid.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        ChipBalanceBadge(compact: true)
                    }

                    multiplierCard(round: round, isFinished: isFinished)

                    if isFinished {
                        resultSection(round: round, busted: busted, survivors: survivors, deltas: deltas)
                    } else if isCrashed {
                        // クラッシュはしたが, まだ他の人の STOP が届いていない
                        // かもしれない猶予期間(`BustSnapshot.isFinished` 参照).
                        Label(String(localized: "結果を確認しています…"), systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else if let myStop {
                        VStack(spacing: 6) {
                            Text("STOP済み: \(formattedMultiplier(myStop.multiplier))")
                                .font(.title3.weight(.bold))
                            Text("他のみんなの結果が出るまでお待ちください")
                                .font(.footnote)
                                .foregroundStyle(Palette.subdued)
                        }
                    } else if isPlayer {
                        Button {
                            run { await store.stopBust(in: conversationID) }
                        } label: {
                            Text("STOP")
                                .font(.title2.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isSending)
                        .padding(.horizontal, AppConstants.Layout.standardSpacing)
                    } else {
                        Text("見学中です")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    }

                    Divider()
                    resultsSection(round: round, isFinished: isFinished, revealOthers: revealOthers, deltas: deltas)

                    if isFinished {
                        ChipGameRematchSection(
                            kind: .bust,
                            previousBet: round.bet,
                            isSending: isSending
                        ) { bet in
                            run { await store.createBustLobby(bet: bet, in: conversationID) }
                        }
                    }
                }
                .padding(AppConstants.Layout.standardSpacing)
            }
            .task(id: round.startedAt) {
                // 新しい対戦(再戦)が始まったら, 前の対戦の結果表示を持ち越さない.
                settledDelta = nil
                await runTicker()
            }
        }
    }

    /// 倍率の表示と, 「このままSTOPしたら」の見込み額, 危険度ゲージ.
    private func multiplierCard(round: BustSnapshot.Round, isFinished: Bool) -> some View {
        let myMultiplier = me.flatMap { round.stops[$0]?.multiplier } ?? displayMultiplier
        let pot = round.bet * round.playerIDs.count
        let soloWin = Int(min(Double(pot), Double(round.bet) * myMultiplier).rounded())

        return VStack(spacing: 10) {
            Text(formattedMultiplier(myMultiplier))
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(gaugeColor(for: myMultiplier))

            if !isFinished {
                Text("いま一人勝ちなら \(ChipRules.formatted(soloWin))")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)

                VStack(alignment: .leading, spacing: 4) {
                    Text("危険度")
                        .font(.caption2)
                        .foregroundStyle(Palette.subdued)
                    ProgressView(value: BustSnapshot.dangerGaugeFraction(at: displayMultiplier))
                        .tint(gaugeColor(for: displayMultiplier))
                }
                .frame(maxWidth: 220)
            }
        }
        .padding(.vertical, 12)
    }

    /// 倍率の値に応じた色.
    ///
    /// 大きな数字の色には, 自分が確定させた倍率(STOP済みならそれ, まだなら
    /// 現在の表示倍率)を渡す. 危険度ゲージには現在の表示倍率を渡す。
    /// 同じ `displayMultiplier` を両方に使うと, すでに STOP して安全なはずの
    /// 自分の数字まで, 対戦がまだ続いている間ずっと赤くなり続けてしまう.
    private func gaugeColor(for multiplier: Double) -> Color {
        let fraction = BustSnapshot.dangerGaugeFraction(at: multiplier)
        if fraction > 0.66 { return Palette.failure }
        if fraction > 0.33 { return .orange }
        return .green
    }

    /// 決着したときに, 何が起きたのかを 1 行で出す.
    private func resultSection(
        round: BustSnapshot.Round, busted: [UserID], survivors: [UserID], deltas: [UserID: Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if busted.isEmpty {
                if let topMultiplier = survivors.compactMap({ round.stops[$0]?.multiplier }).max() {
                    let winners = survivors.filter { round.stops[$0]?.multiplier == topMultiplier }
                    if winners.count == 1 {
                        Text("\(store.displayName(for: winners[0])) が \(formattedMultiplier(topMultiplier)) で一人勝ちです")
                            .font(.headline)
                    } else {
                        let names = winners.map { store.displayName(for: $0) }.joined(separator: "、")
                        Text("\(names) が \(formattedMultiplier(topMultiplier)) で同着です")
                            .font(.headline)
                    }
                }
            } else if survivors.isEmpty {
                Text("誰もSTOPできないままCRASHしました。賭け金はそのまま戻ります")
                    .font(.headline)
            } else {
                let names = busted.map { store.displayName(for: $0) }.joined(separator: "、")
                Text("CRASH! \(names) が脱落しました")
                    .font(.headline)
                    .foregroundStyle(Palette.failure)
            }

            if let me, let delta = settledDelta ?? deltas[me] {
                ChipResultBanner(delta: delta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultsSection(
        round: BustSnapshot.Round, isFinished: Bool, revealOthers: Bool, deltas: [UserID: Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("みんなの状況")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            ForEach(round.playerIDs, id: \.self) { playerID in
                HStack(spacing: 8) {
                    Text(store.displayName(for: playerID))
                        .font(.subheadline)
                    Spacer()

                    if !revealOthers && playerID != me {
                        Text("?")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    } else if let stop = round.stops[playerID] {
                        Text(formattedMultiplier(stop.multiplier))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        if let delta = deltas[playerID] {
                            Text(ChipRules.formattedDelta(delta))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delta > 0 ? .green : (delta < 0 ? Palette.failure : Palette.subdued))
                        }
                    } else if isFinished {
                        Text("CRASH")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.failure)
                        if let delta = deltas[playerID] {
                            Text(ChipRules.formattedDelta(delta))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.failure)
                        }
                    } else {
                        Text("継続中")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                }
            }
        }
    }

    // MARK: - 動作

    /// 倍率の表示を進め, 決着したら精算を拾う.
    ///
    /// BUST は時間が経つだけで決着することがある唯一の CHIP ゲームなので
    /// (最後まで粘っていた 1 人が STOP を押さないままクラッシュを迎えた場合),
    /// 新しいメッセージが届くのを待つだけでは決着に気付けない. 対戦画面を
    /// 開いている間, ここで一定間隔ごとに自分から確かめにいく.
    ///
    /// `.task(id: round.startedAt)` の中から呼ぶので, 対戦が変わったり
    /// 画面が閉じられたりしたときは `Task.isCancelled` が自動で立ち,
    /// ここで別途タスクを管理する必要は無い.
    private func runTicker() async {
        while !Task.isCancelled {
            guard let snapshot, snapshot.round != nil else { return }
            // 倍率と決着したかどうかをまとめて 1 回で取る(`tickState` 参照.
            // 別々に呼ぶとクラッシュ倍率の計算を毎回 2 回してしまうため).
            let state = snapshot.tickState()
            displayMultiplier = state.multiplier
            if state.isFinished {
                await store.settleBustIfCrashed(in: conversationID)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func formattedMultiplier(_ multiplier: Double) -> String {
        String(format: "%.2fx", multiplier)
    }

    private func run(_ operation: @escaping () async -> Void) {
        Task {
            isSending = true
            defer { isSending = false }
            await operation()
        }
    }
}

#Preview {
    BustGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
