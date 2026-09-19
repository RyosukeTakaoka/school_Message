import SwiftUI

/// Slingo の対戦画面.
///
/// 他の CHIP ゲームと違い, 隠す情報が無い(カードは全員から見える). そのため
/// BUST やチンチロにある「演出が終わるまで自分の分を隠す」仕掛けは要らない ――
/// 同期で届いた状態をそのまま出すだけでよい.
///
/// SPIN の結果は対戦開始時の種から決まる決定的な値(`SlingoSnapshot.spinning(by:)`)
/// なので, ボタンを押した本人の端末はネットワークの往復を待たずに結果が分かる.
/// その値を使って, チンチロのダイスと同じ「高速に切り替わってから, ふわっと
/// 止まる」演出を 1 つのリール(数字 or WILD)で行う. 他の人の端末には,
/// 同期で届いた瞬間に軽いアニメーションで反映する(スピン中の演出そのものは
/// 押した本人だけ ―― 全員ぶん揃えるのは今回は見送っている. 下の TODO 参照).
///
/// TODO: 手が空いたら, 自分が押していない SPIN でも(届いた瞬間に)簡単な
/// スピン演出を出せるとより気持ちよくなる. 今回はターン制の骨組みを優先し,
/// 見送った.
struct SlingoGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    @State private var isSpinning = false
    @State private var isRevealingResult = false
    @State private var displayDraw: SlingoSnapshot.DrawItem = .number(Int.random(in: SlingoSnapshot.cardNumberRange))
    @State private var spinTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var settledDelta: Int?

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    private var snapshot: SlingoSnapshot? {
        store.activeGame(kind: .slingo, in: conversationID)?.slingo
    }

    var body: some View {
        ChipGameScaffold(title: GameSnapshot.Kind.slingo.title) {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        ChipGameLobbySection(
                            kind: .slingo,
                            lobby: lobby,
                            hostID: snapshot.hostID,
                            isSending: isSending,
                            onJoin: { run { await store.joinSlingo(in: conversationID) } },
                            onLeave: { run { await store.leaveGameLobby(kind: .slingo, in: conversationID) } },
                            onCancel: store.canCancelGame(kind: .slingo, in: conversationID)
                                ? { run { await store.cancelGame(kind: .slingo, in: conversationID) } }
                                : nil,
                            onStart: { run { await store.startSlingo(in: conversationID) } },
                            maximumPlayers: GameSnapshot.Kind.slingo.maximumPlayers
                        )
                    case .playing:
                        roundView(snapshot)
                    }
                } else {
                    ChipGameStartPrompt(kind: .slingo, rules: GameSnapshot.Kind.slingo.rules) { bet in
                        run { await store.createSlingoLobby(bet: bet, in: conversationID) }
                    }
                }
            }
        }
        .task(id: snapshot) {
            guard let snapshot, snapshot.isFinished, let me else { return }
            settledDelta = await store.settleChipsIfNeeded(for: .slingo(snapshot)) ?? snapshot.chipDeltas[me]
        }
        .onDisappear {
            spinTask?.cancel()
            revealTask?.cancel()
            isSpinning = false
        }
    }

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: SlingoSnapshot) -> some View {
        if let round = snapshot.round {
            let isMyTurn = me != nil && snapshot.currentPlayerID == me
            let isMyWildPick = me != nil && round.pendingWildFor == me
            let isPlayer = me.map { round.playerIDs.contains($0) } ?? false

            ScrollView {
                VStack(spacing: AppConstants.Layout.standardSpacing) {
                    HStack {
                        Label(String(localized: "1人 \(ChipRules.formatted(round.bet))"), systemImage: "circle.hexagongrid.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        ChipBalanceBadge(compact: true)
                    }

                    turnBanner(snapshot)
                    reelView

                    if snapshot.isFinished {
                        resultLine(snapshot)
                        if let me, let delta = settledDelta ?? snapshot.chipDeltas[me] {
                            ChipResultBanner(delta: delta)
                        }
                    } else if isMyWildPick {
                        Text("WILD! カードの未開放マスをタップして開けてください")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    } else if isMyTurn {
                        Button {
                            spinTapped(snapshot: snapshot)
                        } label: {
                            Text("SPIN")
                                .font(.title2.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || isSpinning)
                        .padding(.horizontal, AppConstants.Layout.standardSpacing)
                    } else if isPlayer {
                        Text("他の人の番を待っています")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else {
                        Text("見学中です")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    }

                    Divider()

                    if let me {
                        cardSection(
                            title: String(localized: "自分のカード"),
                            playerID: me,
                            snapshot: snapshot,
                            isLarge: true,
                            isInteractive: isMyWildPick
                        ) { number in
                            run { await store.openSlingoWildCell(number, in: conversationID) }
                        }
                    }

                    Divider()

                    Text("他のプレイヤー")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)

                    ForEach(round.playerIDs.filter { $0 != me }, id: \.self) { playerID in
                        cardSection(
                            title: store.displayName(for: playerID),
                            playerID: playerID,
                            snapshot: snapshot,
                            isLarge: false,
                            isInteractive: false,
                            onTapCell: nil
                        )
                    }

                    if snapshot.isFinished {
                        ChipGameRematchSection(
                            kind: .slingo,
                            previousBet: round.bet,
                            isSending: isSending
                        ) { bet in
                            run { await store.createSlingoLobby(bet: bet, in: conversationID) }
                        }
                    }
                }
                .padding(AppConstants.Layout.standardSpacing)
            }
            .task(id: round.lastDraw) {
                // 自分が押した SPIN は `spinTapped` 側ですでに演出中なので, ここでは
                // 他の端末から届いた分(自分の演出中でない場合)だけ反映する.
                guard !isRevealingResult, let draw = round.lastDraw else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    displayDraw = draw
                }
            }
        }
    }

    private func turnBanner(_ snapshot: SlingoSnapshot) -> some View {
        let text: String
        if snapshot.isFinished {
            text = String(localized: "対戦終了")
        } else if let pending = snapshot.round?.pendingWildFor {
            text = pending == me
                ? String(localized: "WILD! あなたの番です")
                : String(localized: "\(store.displayName(for: pending)) がWILDのマスを選んでいます")
        } else if let current = snapshot.currentPlayerID {
            text = current == me
                ? String(localized: "あなたのターンです")
                : String(localized: "\(store.displayName(for: current)) のターン")
        } else {
            text = ""
        }
        return Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// SPIN の結果を出すリール. 数字か WILD を 1 つだけ表示する.
    private var reelView: some View {
        Group {
            switch displayDraw {
            case .number(let value):
                Text("\(value)")
                    .monospacedDigit()
            case .wild:
                Text("WILD")
            }
        }
        .font(.system(size: 40, weight: .heavy, design: .rounded))
        .frame(width: 140, height: 90)
        .background(
            Color.accentColor.opacity(isSpinning ? 0.10 : 0.18),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
        .scaleEffect(isSpinning ? 0.96 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSpinning)
    }

    private func resultLine(_ snapshot: SlingoSnapshot) -> some View {
        let winners = snapshot.round?.finisherIDs ?? []
        let text: String
        if winners.count == 1 {
            text = String(localized: "\(store.displayName(for: winners[0])) がSlingo! 総取りです")
        } else if winners.isEmpty {
            text = ""
        } else {
            let names = winners.map { store.displayName(for: $0) }.joined(separator: "、")
            text = String(localized: "\(names) が同時にSlingo! 山分けです")
        }
        return Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
    }

    /// 1 人ぶんのカードと, 名前・オープン数・リーチ状況をまとめたセクション.
    @ViewBuilder
    private func cardSection(
        title: String,
        playerID: UserID,
        snapshot: SlingoSnapshot,
        isLarge: Bool,
        isInteractive: Bool,
        onTapCell: ((Int) -> Void)? = nil
    ) -> some View {
        if let card = snapshot.card(for: playerID) {
            let opens = snapshot.openNumbers(for: playerID)
            let reach = snapshot.reachCellIndices(for: playerID)
            let isWinner = snapshot.round?.finisherIDs.contains(playerID) ?? false

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(isLarge ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    if isWinner {
                        Text("Slingo!")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(Color.white)
                    } else if !reach.isEmpty {
                        Text("リーチ")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(opens.count)/\(SlingoSnapshot.numbersPerCard)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.subdued)
                }

                SlingoCardGridView(
                    card: card,
                    openNumbers: opens,
                    reachIndices: reach,
                    cellSize: isLarge ? 52 : 28,
                    isInteractive: isInteractive,
                    onTapCell: onTapCell
                )
            }
        }
    }

    // MARK: - 動作

    /// SPIN を押した瞬間. 結果は種から決まる決定的な値なので, 送信の往復を
    /// 待たずにこの場でも同じ値を計算できる(`snapshot.spinning(by:)`)。
    /// その値を使って先にリールの演出を始めつつ, 実際の送信も並行して行う.
    private func spinTapped(snapshot: SlingoSnapshot) {
        guard let me, let peeked = snapshot.spinning(by: me), let draw = peeked.round?.lastDraw else { return }
        run { await store.spinSlingo(in: conversationID) }

        revealTask?.cancel()
        revealTask = Task { await revealSpin(draw) }
    }

    private func revealSpin(_ draw: SlingoSnapshot.DrawItem) async {
        isRevealingResult = true
        isSpinning = true
        spinTask?.cancel()
        spinTask = Task {
            while !Task.isCancelled {
                displayDraw = .number(Int.random(in: SlingoSnapshot.cardNumberRange))
                try? await Task.sleep(for: .milliseconds(70))
            }
        }

        try? await Task.sleep(for: .milliseconds(900))
        spinTask?.cancel()
        isSpinning = false
        GameHaptics.tick()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            displayDraw = draw
        }
        if case .wild = draw {
            GameHaptics.result(didWin: true)
        }
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

/// 5×5 のカードを描く. 開いたマスは塗りつぶし, リーチのマスは縁取りで示す.
private struct SlingoCardGridView: View {

    let card: SlingoSnapshot.Card
    let openNumbers: Set<Int>
    var reachIndices: Set<Int> = []
    var cellSize: CGFloat = 52
    var isInteractive: Bool = false
    var onTapCell: ((Int) -> Void)? = nil

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: 4), count: SlingoSnapshot.gridSize)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(card.numbers.enumerated()), id: \.offset) { index, number in
                let isOpen = openNumbers.contains(number)
                let isReach = reachIndices.contains(index)
                let canTap = isInteractive && !isOpen

                Button {
                    guard canTap else { return }
                    onTapCell?(number)
                } label: {
                    Text("\(number)")
                        .font(.system(size: cellSize * 0.34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: cellSize, height: cellSize)
                        .background(
                            isOpen ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(isOpen ? Color.white : Color.primary)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    canTap ? Color.accentColor : (isReach ? .orange : .clear),
                                    lineWidth: canTap || isReach ? 2 : 0
                                )
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canTap)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isOpen)
            }
        }
    }
}

#Preview {
    SlingoGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
