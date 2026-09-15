import SwiftUI

/// ブラックジャックの対戦画面.
///
/// 参加者どうしの勝負. 順番は決めず, 好きなときに HIT / STAND できる
/// (ほかの人の手札と点数は見えるので, それを見ながら決められる).
struct BlackjackGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: BlackjackSnapshot? {
        store.activeGame(kind: .blackjack, in: conversationID)?.blackjack
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
                            onLeave: { run { await store.leaveGameLobby(kind: .blackjack, in: conversationID) } },
                            onCancel: store.canCancelGame(kind: .blackjack, in: conversationID)
                                ? { run { await store.cancelGame(kind: .blackjack, in: conversationID) } }
                                : nil,
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
            guard let snapshot, snapshot.isFinished, let me else { return }
            settledDelta = await store.settleChipsIfNeeded(for: .blackjack(snapshot))
                ?? snapshot.chipDeltas[me]
        }
    }

    private static let rules = String(localized: """
        参加者どうしで勝負します。21に近いほうが勝ちで、21を超えたら負け(バースト)です。絵札は10、Aは11か1の都合のよいほうで数えます。

        操作は HIT(もう1枚引く)と STAND(そこで止める)だけ。全員が止めるかバーストしたら決着で、21を超えなかった人のうち一番大きい人が、みんなの賭けたCHIPを総取りします。同じ点数で並んだら山分け、全員バーストなら増減なしです。
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

                if snapshot.isFinished {
                    resultLine(snapshot)
                }

                if let me, let myState = round.hands[me] {
                    mySection(snapshot, round: round, state: myState)
                    Divider()
                }

                othersSection(snapshot, round: round)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    /// 決着したときに, 誰が勝ったのかを 1 行で出す.
    private func resultLine(_ snapshot: BlackjackSnapshot) -> some View {
        let winners = snapshot.winnerIDs
        let text: String
        if winners.isEmpty {
            text = String(localized: "全員バースト。引き分けです")
        } else if winners.count == 1 {
            text = String(localized: "\(store.displayName(for: winners[0])) の勝ちです")
        } else {
            let names = winners.map { store.displayName(for: $0) }.joined(separator: "、")
            text = String(localized: "\(names) が同点で山分けです")
        }
        return Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                ChipGameRematchSection(kind: .blackjack, previousBet: round.bet, isSending: isSending) { bet in
                    run { await store.createBlackjackLobby(bet: bet, in: conversationID) }
                }
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

    /// ほかの参加者の手札. 相手の点数を見ながら引くか決められるように,
    /// 札も点数もそのまま出す(伏せる札は無い).
    private func othersSection(_ snapshot: BlackjackSnapshot, round: BlackjackSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
            Text("ほかの参加者")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ForEach(round.playerIDs.filter { $0 != me }, id: \.self) { playerID in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(store.displayName(for: playerID))
                            .font(.subheadline)
                        Spacer()
                        if let state = round.hands[playerID] {
                            Text("\(state.bestValue)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(state.isBust ? Palette.failure : Color.primary)
                            if snapshot.isFinished, let outcome = snapshot.outcome(for: playerID) {
                                Text(outcome.title)
                                    .font(.caption.weight(.semibold))
                            } else {
                                Text(state.isBust
                                     ? String(localized: "バースト")
                                     : (state.isStanding ? String(localized: "止めた") : String(localized: "考え中")))
                                    .font(.caption)
                                    .foregroundStyle(Palette.subdued)
                            }
                        }
                    }
                    if let state = round.hands[playerID] {
                        cardRow(state.cards)
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
