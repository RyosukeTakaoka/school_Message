import SwiftUI

/// ダウトの対戦画面(3 人以上).
///
/// 自分の番では, 場が決めた数字を宣言しながら札を伏せて出す. 持っていなければ
/// 別の札を出す(嘘をつく)しかない. 出した札は他の人からは見えないが,
/// ダウトされると本人の端末が鍵を公開して中身が全員に明かされる.
struct DoubtGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var myHand: [PlayingCard] = []
    @State private var selectedCards: Set<PlayingCard> = []
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: DoubtSnapshot? {
        store.activeGame(kind: .doubt, in: conversationID)?.doubt
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.doubt.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .doubt,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinDoubt(in: conversationID) } },
                            onLeave: { run { await store.leaveGameLobby(kind: .doubt, in: conversationID) } },
                            onCancel: { run { await store.cancelGame(kind: .doubt, in: conversationID) } },
                            onStart: { run { await store.startDoubt(in: conversationID) } }
                        )
                    case .round(let round):
                        roundView(snapshot, round: round)
                    }
                } else {
                    ChipGameStartPrompt(kind: .doubt, rules: Self.rules) { bet in
                        run { await store.createDoubtLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot, let me else { return }
            myHand = await store.decryptedDoubtHand(in: conversationID)
            selectedCards = []

            // ダウトされたら, 自分の端末が鍵を公開して真偽を確定させる.
            if snapshot.isAwaitingReveal(by: me) {
                await store.revealDoubtIfNeeded(in: conversationID)
            }
            if snapshot.isFinished {
                settledDelta = await store.settleChipsIfNeeded(for: .doubt(snapshot))
                    ?? snapshot.chipDeltas[me]
            }
        }
    }

    private static let rules = String(localized: """
        順番に、場が決めた数字を宣言しながら札を伏せて出していきます。数字は3から順に上がっていき、持っていなければ嘘をつくしかありません。

        怪しいと思ったら「ダウト」。嘘だったら出した人が、本当だったら宣言した人が、その札を引き取ります。先に手札を出し切った人の勝ちで、負けた人のCHIPを総取りします。最後の1枚は必ず公開されるので、嘘で上がることはできません。
        """)

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: DoubtSnapshot, round: DoubtSnapshot.Round) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                HStack {
                    Label(String(localized: "1人 \(ChipRules.formatted(round.bet))"), systemImage: "circle.hexagongrid.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    ChipBalanceBadge(compact: true)
                }

                if round.isFinished {
                    finishedSection(snapshot, round: round)
                } else {
                    statusSection(snapshot, round: round)
                    fieldSection(snapshot, round: round)
                }

                if let verdict = round.lastVerdict {
                    verdictSection(verdict)
                }

                Divider()
                playersSection(round)
                Divider()
                handSection(snapshot, round: round)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func statusSection(_ snapshot: DoubtSnapshot, round: DoubtSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if round.doubtCallerID != nil {
                Label(String(localized: "ダウト! 中身を確かめています…"), systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.failure)
            } else if let me, snapshot.isTurn(of: me) {
                Text("あなたの番です。「\(round.requiredRank.label)」として出してください")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("\(store.displayName(for: round.currentPlayerID)) の番です(宣言する数字: \(round.requiredRank.label))")
                    .font(.subheadline)
                    .foregroundStyle(Palette.subdued)
            }
        }
    }

    @ViewBuilder
    private func fieldSection(_ snapshot: DoubtSnapshot, round: DoubtSnapshot.Round) -> some View {
        if let play = round.lastPlay {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(store.displayName(for: play.playerID)) が「\(play.claimedRank.label)」を \(play.count)枚 出しました")
                    .font(.subheadline)

                HStack(spacing: 6) {
                    ForEach(0..<play.count, id: \.self) { _ in
                        Text("?")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Palette.subdued)
                            .frame(width: 40, height: 56)
                            .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if let me, snapshot.canCallDoubt(me) {
                    Button(String(localized: "ダウト!"), role: .destructive) {
                        run { await store.callDoubt(in: conversationID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending)
                }
            }
        }
    }

    private func verdictSection(_ verdict: DoubtSnapshot.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verdict.wasLying ? String(localized: "嘘でした!") : String(localized: "本当でした"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(verdict.wasLying ? Palette.failure : .green)
            HStack(spacing: 6) {
                ForEach(Array(verdict.actualCards.enumerated()), id: \.offset) { _, card in
                    PlayingCardView(card: card, size: .small)
                }
            }
            Text("\(store.displayName(for: verdict.penalizedID)) が \(verdict.actualCards.count)枚 引き取りました")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
        }
        .padding(AppConstants.Layout.compactSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.incomingBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func finishedSection(_ snapshot: DoubtSnapshot, round: DoubtSnapshot.Round) -> some View {
        VStack(spacing: 8) {
            Text(round.winnerID == me ? String(localized: "あなたの勝ち!") : String(localized: "\(store.displayName(for: round.winnerID ?? round.currentPlayerID)) の勝ち"))
                .font(.title3.weight(.bold))
            if let delta = settledDelta ?? me.flatMap({ snapshot.chipDeltas[$0] }) {
                ChipResultBanner(delta: delta)
            }
            Button(String(localized: "もう一回")) {
                run { await store.createDoubtLobby(bet: round.bet, in: conversationID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || !store.canPlayChipGames)
        }
        .frame(maxWidth: .infinity)
    }

    private func playersSection(_ round: DoubtSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参加者")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ForEach(round.seating, id: \.self) { playerID in
                HStack(spacing: 6) {
                    Text(store.displayName(for: playerID))
                        .font(.subheadline)
                    if playerID == round.currentPlayerID, !round.isFinished {
                        Image(systemName: "hand.point.right.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Text("残り\(round.handCounts[playerID] ?? 0)枚")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
            }
        }
    }

    @ViewBuilder
    private func handSection(_ snapshot: DoubtSnapshot, round: DoubtSnapshot.Round) -> some View {
        let canAct = me.map { snapshot.isTurn(of: $0) } == true && !isSending

        VStack(alignment: .leading, spacing: 6) {
            Text("あなたの手札")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            if myHand.isEmpty {
                Text("なし")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(myHand) { card in
                            Button {
                                toggle(card)
                            } label: {
                                PlayingCardView(card: card, size: .small)
                                    .overlay {
                                        if selectedCards.contains(card) {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canAct)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .opacity(canAct ? 1 : 0.55)
            }

            if canAct {
                Button(String(localized: "「\(round.requiredRank.label)」として \(selectedCards.count)枚 出す")) {
                    let cards = myHand.filter { selectedCards.contains($0) }
                    run { await store.playDoubtCards(cards, in: conversationID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCards.isEmpty || selectedCards.count > DoubtSnapshot.maxPlayCount)

                Text("嘘をついても構いません。ダウトされなければそのまま場に残ります。")
                    .font(.caption2)
                    .foregroundStyle(Palette.subdued)
            }
        }
    }

    // MARK: - 動作

    private func toggle(_ card: PlayingCard) {
        if selectedCards.contains(card) {
            selectedCards.remove(card)
        } else if selectedCards.count < DoubtSnapshot.maxPlayCount {
            selectedCards.insert(card)
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
    DoubtGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
