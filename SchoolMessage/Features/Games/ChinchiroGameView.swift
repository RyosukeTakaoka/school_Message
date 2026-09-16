import SwiftUI

/// チンチロの対戦画面.
///
/// サイコロは 3 個まとめて回し, STOP を 1 回押すと 3 個とも同時に止まる
/// (1 個ずつ止める操作はしない). 振り直しも無い.
struct ChinchiroGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var isSpinning = false
    @State private var displayDice = [1, 2, 3]
    /// 決まった目だけここに入る. nil のままの目は, 決まるまで高速に切り替わり続ける.
    @State private var lockedDice: [Int?] = [nil, nil, nil]
    /// 左から何個決まったか(表示のハイライトに使う).
    @State private var settledDiceCount = 0
    /// STOP を押してから, 目が全部決まって役が見えるまでの「溜め」の間 true.
    @State private var isRevealingResult = false
    @State private var spinTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: ChinchiroSnapshot? {
        store.activeGame(kind: .chinchiro, in: conversationID)?.chinchiro
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.chinchiro.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .chinchiro,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinChinchiro(in: conversationID) } },
                            onLeave: { run { await store.leaveGameLobby(kind: .chinchiro, in: conversationID) } },
                            onCancel: store.canCancelGame(kind: .chinchiro, in: conversationID)
                                ? { run { await store.cancelGame(kind: .chinchiro, in: conversationID) } }
                                : nil,
                            onStart: { run { await store.startChinchiro(in: conversationID) } }
                        )
                    case .rolling:
                        roundView(snapshot)
                    }
                } else {
                    ChipGameStartPrompt(kind: .chinchiro, rules: Self.rules) { bet in
                        run { await store.createChinchiroLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot, snapshot.isFinished, let me else { return }
            // 決着を見つけた端末が, 自分のぶんだけ残高に反映する.
            settledDelta = await store.settleChipsIfNeeded(for: .chinchiro(snapshot))
                ?? snapshot.chipDeltas[me]
        }
        .onDisappear {
            spinTask?.cancel()
            revealTask?.cancel()
            isSpinning = false
        }
    }

    private static let rules = String(localized: """
        3個のサイコロを1回だけ振ります。STOPを押すと3個とも同時に止まります。

        役の強さは、ピンゾロ(1-1-1)が一番強く、次にゾロ目、シゴロ(4-5-6)、目(2個そろって残りが目になる)、目無し、ヒフミ(1-2-3)が一番弱い順です。全員が振り終えると、一番強い役を出した人が全員の賭けを総取りします。同じ強さで並んだら山分けです。
        """)

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: ChinchiroSnapshot) -> some View {
        let myRoll = me.flatMap { snapshot.round?.rolls[$0] }

        ScrollView {
            VStack(spacing: AppConstants.Layout.standardSpacing) {
                HStack {
                    Label(String(localized: "1人 \(ChipRules.formatted(snapshot.bet))"), systemImage: "circle.hexagongrid.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    ChipBalanceBadge(compact: true)
                }

                diceRow(
                    isRevealingResult ? displayDice : (myRoll?.dice ?? displayDice),
                    settledCount: isRevealingResult ? settledDiceCount : nil
                )

                if let myRoll, !isRevealingResult {
                    VStack(spacing: 6) {
                        Text(myRoll.hand.title)
                            .font(.title3.weight(.bold))
                            .transition(.scale.combined(with: .opacity))
                        if let delta = settledDelta ?? me.flatMap({ snapshot.chipDeltas[$0] }) {
                            ChipResultBanner(delta: delta)
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isRevealingResult)
                } else if isRevealingResult {
                    Label(String(localized: "目を確かめています…"), systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(Palette.subdued)
                } else if me.map({ snapshot.playerIDs.contains($0) }) == true {
                    Button {
                        stopSpinning()
                    } label: {
                        Text("STOP")
                            .font(.title2.weight(.heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending)
                    .padding(.horizontal, AppConstants.Layout.standardSpacing)
                } else {
                    Text("見学中です")
                        .font(.footnote)
                        .foregroundStyle(Palette.subdued)
                }

                if snapshot.isFinished, !isRevealingResult {
                    resultLine(snapshot)
                }

                Divider()
                resultsSection(snapshot)

                // 全員が振り終わったら, そのまま次の対戦を始められるようにする.
                if snapshot.isFinished {
                    ChipGameRematchSection(
                        kind: .chinchiro,
                        previousBet: snapshot.bet,
                        isSending: isSending
                    ) { bet in
                        run { await store.createChinchiroLobby(bet: bet, in: conversationID) }
                    }
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
        .task(id: snapshot.hashValue) {
            // まだ振っていないなら回し始める.
            if myRoll == nil, !isSpinning { startSpinning() }
        }
    }

    /// 決着したときに, 誰が総取りしたのかを 1 行で出す.
    private func resultLine(_ snapshot: ChinchiroSnapshot) -> some View {
        let winners = snapshot.winnerIDs
        let text: String
        if winners.count == snapshot.playerIDs.count {
            text = String(localized: "全員同着。増減なしです")
        } else if winners.count == 1 {
            text = String(localized: "\(store.displayName(for: winners[0])) の総取りです")
        } else {
            let names = winners.map { store.displayName(for: $0) }.joined(separator: "、")
            text = String(localized: "\(names) が同着で山分けです")
        }
        return Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `settledCount` を渡すと, 左から何個が「決まった目」かを見た目で区別する
    /// (決まっていない目は, 高速に切り替わっている最中でも同じ枠で表示され続ける).
    private func diceRow(_ dice: [Int], settledCount: Int? = nil) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(dice.enumerated()), id: \.offset) { index, value in
                let isSettled = settledCount.map { index < $0 } ?? true
                Text("\(value)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 72, height: 72)
                    .background(
                        isSettled ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSettled ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isSettled ? 2 : 1)
                    }
                    .scaleEffect(isSettled ? 1 : 0.94)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSettled)
            }
        }
        .padding(.vertical, 8)
    }

    private func resultsSection(_ snapshot: ChinchiroSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("みんなの結果")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            ForEach(snapshot.playerIDs, id: \.self) { playerID in
                HStack(spacing: 8) {
                    Text(store.displayName(for: playerID))
                        .font(.subheadline)
                    Spacer()
                    // 自分の分は, 画面上の演出が終わるまでここにも先に出さない
                    // (先に出すと, 上のダイスが決まる前に結果が分かってしまう).
                    if let roll = snapshot.round?.rolls[playerID], !(playerID == me && isRevealingResult) {
                        Text(roll.dice.map(String.init).joined(separator: " "))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.subdued)
                        Text(roll.hand.title)
                            .font(.caption.weight(.semibold))
                        if snapshot.isFinished, let delta = snapshot.chipDeltas[playerID] {
                            Text(ChipRules.formattedDelta(delta))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delta > 0 ? .green : (delta < 0 ? Palette.failure : Palette.subdued))
                        }
                    } else {
                        Text(playerID == me && isRevealingResult ? "確認中…" : "まだ振っていません")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                }
            }
        }
    }

    // MARK: - 動作

    private func startSpinning() {
        spinTask?.cancel()
        isSpinning = true
        lockedDice = [nil, nil, nil]
        settledDiceCount = 0
        spinTask = Task {
            while !Task.isCancelled {
                // 決まった目はそのまま, まだの目だけ高速に切り替え続ける.
                displayDice = (0..<3).map { index in lockedDice[index] ?? Int.random(in: 1...6) }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    /// STOP が押された瞬間に出目は全部決まるが, 見せ方は左から順に
    /// 1 個ずつ「決まった感じ」を出してから, 最後に役を見せる.
    private func stopSpinning() {
        guard !isRevealingResult else { return }
        let roll = ChinchiroRoll.roll()
        run { await store.rollChinchiro(roll, in: conversationID) }

        revealTask?.cancel()
        revealTask = Task { await revealSequentially(roll) }
    }

    private func revealSequentially(_ roll: ChinchiroRoll) async {
        isRevealingResult = true
        for index in roll.dice.indices {
            try? await Task.sleep(for: .milliseconds(380))
            GameHaptics.tick()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                lockedDice[index] = roll.dice[index]
                settledDiceCount = index + 1
            }
        }
        spinTask?.cancel()
        isSpinning = false
        displayDice = roll.dice
        GameHaptics.result(didWin: roll.hand.strength >= ChinchiroHand.shigoro.strength)
        isRevealingResult = false
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
    ChinchiroGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
