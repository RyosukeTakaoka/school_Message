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
    @State private var spinTask: Task<Void, Never>?
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
                            onCancel: { run { await store.cancelGame(kind: .chinchiro, in: conversationID) } },
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
            isSpinning = false
        }
    }

    private static let rules = String(localized: """
        3個のサイコロを1回だけ振ります。STOPを押すと3個とも同時に止まります。

        ピンゾロ(1-1-1)は5倍、ほかのゾロ目は3倍、シゴロ(4-5-6)は2倍、2個そろえば残りの数字が「目」になって1倍もらえます。ヒフミ(1-2-3)は2倍の支払い、それ以外の組み合わせは増減なしです。
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

                diceRow(myRoll?.dice ?? displayDice)

                if let myRoll {
                    VStack(spacing: 6) {
                        Text(myRoll.hand.title)
                            .font(.title3.weight(.bold))
                        if let delta = settledDelta ?? me.flatMap({ snapshot.chipDeltas[$0] }) {
                            ChipResultBanner(delta: delta)
                        }
                    }
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

                Divider()
                resultsSection(snapshot)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
        .task(id: snapshot.hashValue) {
            // まだ振っていないなら回し始める.
            if myRoll == nil, !isSpinning { startSpinning() }
        }
    }

    private func diceRow(_ dice: [Int]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(dice.enumerated()), id: \.offset) { _, value in
                Text("\(value)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 72, height: 72)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                    }
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
                    if let roll = snapshot.round?.rolls[playerID] {
                        Text(roll.dice.map(String.init).joined(separator: " "))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.subdued)
                        Text(roll.hand.title)
                            .font(.caption.weight(.semibold))
                        Text(ChipRules.formattedDelta(snapshot.bet * roll.hand.multiplier))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(roll.hand.multiplier > 0 ? .green : (roll.hand.multiplier < 0 ? Palette.failure : Palette.subdued))
                    } else {
                        Text("まだ振っていません")
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
        spinTask = Task {
            while !Task.isCancelled {
                displayDice = (0..<3).map { _ in Int.random(in: 1...6) }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopSpinning() {
        spinTask?.cancel()
        isSpinning = false
        let roll = ChinchiroRoll.roll()
        displayDice = roll.dice
        run { await store.rollChinchiro(roll, in: conversationID) }
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
