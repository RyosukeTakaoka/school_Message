import SwiftUI

/// インディアンポーカーの対戦画面(2 人).
///
/// 自分のカードは最後まで自分には見えない. 見えるのは相手のカードだけ.
struct IndianPokerGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var opponentCard: PlayingCard?
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: IndianPokerSnapshot? {
        store.currentGame(kind: .indianPoker, in: conversationID)?.indianPoker
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.indianPoker.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .indianPoker,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinIndianPoker(in: conversationID) } },
                            onLeave: nil,
                            onStart: { run { await store.startIndianPoker(in: conversationID) } }
                        )
                    case .playing:
                        roundView(snapshot)
                    }
                } else {
                    ChipGameStartPrompt(kind: .indianPoker, rules: Self.rules) { bet in
                        run { await store.createIndianPokerLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot, let me, snapshot.isPlayer(me) else { return }
            opponentCard = await store.decryptedIndianPokerOpponentCard(in: conversationID)

            // 見せ合いになったら, 自分に見えている相手のカードを公開する.
            if snapshot.isAwaitingReveal {
                await store.revealIndianPokerIfNeeded(in: conversationID)
            }
            if snapshot.isFinished {
                settledDelta = await store.settleChipsIfNeeded(for: .indianPoker(snapshot))
                    ?? snapshot.chipDeltas[me]
            }
        }
    }

    private static let rules = String(localized: """
        自分のカードは見えません。見えるのは相手のカードだけです。相手の様子から自分のカードの強さを読んで、勝負するか降りるかを決めます。

        強さは A が一番強く、2 が一番弱い順です。両方が「勝負する」を選ぶと見せ合い、強いほうが賭けた分をもらいます。降りた人はその時点で負けです。
        """)

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: IndianPokerSnapshot) -> some View {
        let myAction = me.flatMap { snapshot.action(of: $0) }

        ScrollView {
            VStack(spacing: AppConstants.Layout.standardSpacing) {
                HStack {
                    Label(String(localized: "1人 \(ChipRules.formatted(snapshot.bet))"), systemImage: "circle.hexagongrid.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    ChipBalanceBadge(compact: true)
                }

                // 相手のカード(自分には見えている).
                VStack(spacing: 6) {
                    Text(opponentName(snapshot) + "のカード")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                    if let opponentCard {
                        PlayingCardView(card: opponentCard, size: .large)
                    } else {
                        hiddenCard(label: "?")
                    }
                }

                // 自分のカード(決着するまで伏せたまま).
                VStack(spacing: 6) {
                    Text("あなたのカード")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                    if let myCard = me.flatMap({ snapshot.revealedCard(of: $0) }) {
                        PlayingCardView(card: myCard, size: .large)
                    } else {
                        hiddenCard(label: "?")
                    }
                }

                statusText(snapshot, myAction: myAction)

                if snapshot.isFinished {
                    resultView(snapshot)
                } else if myAction == nil, me.map({ snapshot.isPlayer($0) }) == true {
                    HStack(spacing: AppConstants.Layout.standardSpacing) {
                        Button(IndianPokerSnapshot.Action.call.title) {
                            run { await store.actIndianPoker(.call, in: conversationID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending)

                        Button(IndianPokerSnapshot.Action.fold.title, role: .destructive) {
                            run { await store.actIndianPoker(.fold, in: conversationID) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                    }
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func hiddenCard(label: String) -> some View {
        Text(label)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Palette.subdued)
            .frame(width: 58, height: 80)
            .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func opponentName(_ snapshot: IndianPokerSnapshot) -> String {
        guard let me, let opponentID = snapshot.opponentID(of: me) else {
            return String(localized: "相手")
        }
        return store.displayName(for: opponentID)
    }

    @ViewBuilder
    private func statusText(_ snapshot: IndianPokerSnapshot, myAction: IndianPokerSnapshot.Action?) -> some View {
        if snapshot.isFinished {
            EmptyView()
        } else if snapshot.isAwaitingReveal {
            Label(String(localized: "見せ合っています…"), systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
        } else if myAction != nil {
            Text("相手を待っています…")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
        } else {
            Text("勝負するか、降りるかを選んでください")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private func resultView(_ snapshot: IndianPokerSnapshot) -> some View {
        VStack(spacing: 8) {
            Text(resultTitle(snapshot))
                .font(.title3.weight(.bold))
            if let delta = settledDelta ?? me.flatMap({ snapshot.chipDeltas[$0] }) {
                ChipResultBanner(delta: delta)
            }
            Button(String(localized: "もう一回")) {
                run { await store.createIndianPokerLobby(bet: snapshot.bet, in: conversationID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || !store.canPlayChipGames)
        }
    }

    private func resultTitle(_ snapshot: IndianPokerSnapshot) -> String {
        guard let me else { return String(localized: "対戦終了") }
        if snapshot.isDraw { return String(localized: "引き分け") }
        guard let winnerID = snapshot.winnerID else { return String(localized: "対戦終了") }
        return winnerID == me ? String(localized: "あなたの勝ち") : String(localized: "あなたの負け")
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
    IndianPokerGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
