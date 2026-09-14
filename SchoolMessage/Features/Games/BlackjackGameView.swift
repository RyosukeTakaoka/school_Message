import SwiftUI

/// ブラックジャックの対戦画面.
///
/// 参加者はそれぞれディーラーと勝負する. プレイヤー同士は影響し合わないので
/// 順番は決めず, 好きなときに HIT / STAND できる.
struct BlackjackGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: BlackjackSnapshot? {
        store.currentGame(kind: .blackjack, in: conversationID)?.blackjack
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.blackjack.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .blackjack,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinBlackjack(in: conversationID) } },
                            onLeave: nil,
                            onStart: { run { await store.startBlackjack(in: conversationID) } }
                        )
                    case .playing(let round):
                        roundView(snapshot, round: round)
                    }
                } else {
                    ChipGameStartPrompt(kind: .blackjack, rules: Self.rules) { bet in
                        run { await store.createBlackjackLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot else { return }
            // 全員が引き終わったら, 気付いた端末がディーラーを進める.
            if snapshot.isAwaitingDealer {
                await store.resolveBlackjackDealerIfNeeded(in: conversationID)
            }
            if snapshot.isFinished, let me {
                settledDelta = await store.settleChipsIfNeeded(for: .blackjack(snapshot))
                    ?? snapshot.chipDeltas[me]
            }
        }
    }

    private static let rules = String(localized: """
        21に近いほうが勝ちです。21を超えたら負け(バースト)。絵札は10、Aは11か1の都合のよいほうで数えます。

        操作は HIT(もう1枚引く)と STAND(そこで止める)だけ。全員が止めたあと、ディーラーが17以上になるまで引きます。ディーラーがバーストしたら残っている人の勝ちです。
        """)

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: BlackjackSnapshot, round: BlackjackSnapshot.Round) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                HStack {
                    Label(String(localized: "1人 \(ChipRules.formatted(round.bet))"), systemImage: "circle.hexagongrid.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    ChipBalanceBadge(compact: true)
                }

                dealerSection(snapshot, round: round)

                Divider()

                if let me, let myState = round.hands[me] {
                    mySection(snapshot, round: round, state: myState)
                    Divider()
                }

                othersSection(snapshot, round: round)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func dealerSection(_ snapshot: BlackjackSnapshot, round: BlackjackSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ディーラー")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Spacer()
                Text(round.isDealerDone
                     ? String(localized: "\(round.dealerValue)\(round.isDealerBust ? " (バースト)" : "")")
                     : String(localized: "引くのは全員が止めてから"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(round.isDealerBust ? Palette.failure : Palette.subdued)
            }
            cardRow(round.dealerCards)
        }
    }

    private func mySection(
        _ snapshot: BlackjackSnapshot,
        round: BlackjackSnapshot.Round,
        state: BlackjackSnapshot.PlayerState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("あなたの手")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Spacer()
                Text("\(state.bestValue)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(state.isBust ? Palette.failure : Color.primary)
            }
            cardRow(state.cards)

            if state.isBust {
                Text("バーストしました")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.failure)
            }

            if snapshot.isFinished {
                if let outcome = me.flatMap({ snapshot.outcome(for: $0) }) {
                    HStack(spacing: AppConstants.Layout.standardSpacing) {
                        Text(outcome.title)
                            .font(.title3.weight(.bold))
                        if let delta = settledDelta ?? me.flatMap({ snapshot.chipDeltas[$0] }) {
                            ChipResultBanner(delta: delta)
                        }
                    }
                }
                Button(String(localized: "もう一回")) {
                    run { await store.createBlackjackLobby(bet: round.bet, in: conversationID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !store.canPlayChipGames)
            } else if let me, snapshot.canAct(me) {
                HStack(spacing: AppConstants.Layout.standardSpacing) {
                    Button(String(localized: "HIT")) {
                        run { await store.hitBlackjack(in: conversationID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending)

                    Button(String(localized: "STAND")) {
                        run { await store.standBlackjack(in: conversationID) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSending)
                }
            } else {
                Text("ほかの人を待っています…")
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
            }
        }
    }

    private func othersSection(_ snapshot: BlackjackSnapshot, round: BlackjackSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ほかの参加者")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ForEach(round.playerIDs.filter { $0 != me }, id: \.self) { playerID in
                HStack(spacing: 8) {
                    Text(store.displayName(for: playerID))
                        .font(.subheadline)
                    Spacer()
                    if let state = round.hands[playerID] {
                        Text("\(state.bestValue)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(state.isBust ? Palette.failure : Palette.subdued)
                        if snapshot.isFinished, let outcome = snapshot.outcome(for: playerID) {
                            Text(outcome.title)
                                .font(.caption.weight(.semibold))
                        } else {
                            Text(state.isDone ? String(localized: "止めた") : String(localized: "考え中"))
                                .font(.caption)
                                .foregroundStyle(Palette.subdued)
                        }
                    }
                }
            }
        }
    }

    private func cardRow(_ cards: [PlayingCard]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                PlayingCardView(card: card, size: .small)
            }
        }
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
    BlackjackGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
