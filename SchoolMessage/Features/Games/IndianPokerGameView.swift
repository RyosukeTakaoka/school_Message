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
    /// 決着してから, 自分のカードを実際にめくるまでの「溜め」を作るための状態.
    @State private var isMyCardRevealed = false
    @State private var isOpponentCardPulsing = false
    @State private var revealTask: Task<Void, Never>?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: IndianPokerSnapshot? {
        store.activeGame(kind: .indianPoker, in: conversationID)?.indianPoker
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
                            onLeave: { run { await store.leaveGameLobby(kind: .indianPoker, in: conversationID) } },
                            onCancel: store.canCancelGame(kind: .indianPoker, in: conversationID)
                                ? { run { await store.cancelGame(kind: .indianPoker, in: conversationID) } }
                                : nil,
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

                // 自分のカードが公開対象なら(降りていなければ), 少し溜めてからめくる.
                // 相手のカードはもう見えているので, 最後まで隠すのは自分の分だけ.
                if !isMyCardRevealed, revealTask == nil, snapshot.revealedCard(of: me) != nil {
                    revealTask = Task {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            isOpponentCardPulsing = true
                        }
                        GameHaptics.tick()
                        try? await Task.sleep(for: .milliseconds(900))
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isMyCardRevealed = true
                            isOpponentCardPulsing = false
                        }
                        if let winnerID = snapshot.winnerID {
                            GameHaptics.result(didWin: winnerID == me)
                        }
                    }
                }
            } else {
                isMyCardRevealed = false
                revealTask?.cancel()
                revealTask = nil
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

                // 相手のカード(自分には見えている). 自分のカードをめくる直前,
                // 「相手はもう分かっている」ことを強調するために少し脈打たせる.
                VStack(spacing: 6) {
                    Text(opponentName(snapshot) + "のカード")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                    if let opponentCard {
                        PlayingCardView(card: opponentCard, size: .large)
                            .scaleEffect(isOpponentCardPulsing ? 1.08 : 1)
                    } else {
                        CardBackView(size: .large)
                    }
                }

                // 自分のカード(決着してもすぐには見せず, 少し溜めてからめくる).
                VStack(spacing: 6) {
                    Text("あなたのカード")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                    if let myCard = me.flatMap({ snapshot.revealedCard(of: $0) }) {
                        FlippableCardView(card: myCard, size: .large, isFaceUp: isMyCardRevealed)
                    } else {
                        CardBackView(size: .large)
                    }
                }

                statusText(snapshot, myAction: myAction)

                if canShowResult(snapshot) {
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

    /// 決着していて, かつ(自分のカードをめくる演出があるなら)それも終わっているか.
    /// 降りていて自分のカードがそもそも公開されない対戦は, 決着と同時に見せてよい.
    private func canShowResult(_ snapshot: IndianPokerSnapshot) -> Bool {
        guard snapshot.isFinished else { return false }
        guard me.flatMap({ snapshot.revealedCard(of: $0) }) != nil else { return true }
        return isMyCardRevealed
    }

    private func opponentName(_ snapshot: IndianPokerSnapshot) -> String {
        guard let me, let opponentID = snapshot.opponentID(of: me) else {
            return String(localized: "相手")
        }
        return store.displayName(for: opponentID)
    }

    @ViewBuilder
    private func statusText(_ snapshot: IndianPokerSnapshot, myAction: IndianPokerSnapshot.Action?) -> some View {
        if snapshot.isFinished, !canShowResult(snapshot) {
            Label(String(localized: "結果を確かめています…"), systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
        } else if snapshot.isFinished {
            EmptyView()
        } else if snapshot.isAwaitingReveal {
            Label(String(localized: "見せ合っています…"), systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
        } else if myAction != nil {
            Label(String(localized: "選択しました。相手を待っています…"), systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
                .transition(.opacity)
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
            ChipGameRematchSection(kind: .indianPoker, previousBet: snapshot.bet, isSending: isSending) { bet in
                run { await store.createIndianPokerLobby(bet: bet, in: conversationID) }
            }
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
