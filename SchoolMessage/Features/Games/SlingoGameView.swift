import SwiftUI

/// スリンゴの対戦画面.
///
/// 他の CHIP ゲームと違い, 隠す情報が無い(カードは全員から見える). そのため
/// BUST やチンチロにある「演出が終わるまで自分の分を隠す」仕掛けは要らない.
///
/// SPIN の演出(数字 / 「？」 / WILD・ハズレの確定)は, 誰の端末でも
/// `SlingoSnapshot.revealStage(drawnAt:draw:now:)` という「経過時間だけで
/// 決まる純粋な関数」から求める. これは BUST の倍率表示と同じ考え方で,
/// 押した本人の端末はもちろん, あとから同期で届いただけの端末でも,
/// 同じタイミングで同じ演出が見える(押した本人だけ演出が違う, ということが
/// 起きない).
struct SlingoGameView: View {

    @Environment(AppEnvironment.self) private var environment

    let conversationID: ConversationID

    @State private var isSending = false
    /// 演出の段階を計算するための「いま」. `.task(id:)` のループで刻む.
    @State private var now = Date.now
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
    }

    // MARK: - 対戦中

    @ViewBuilder
    private func roundView(_ snapshot: SlingoSnapshot) -> some View {
        if let round = snapshot.round {
            let stage = Self.stage(for: round, now: now)
            let isRevealingNow = stage != .resolved
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

                    turnBanner(snapshot, isRevealingNow: isRevealingNow)
                    reelView(round: round, stage: stage)

                    if isRevealingNow {
                        Text("結果を確認しています…")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else if snapshot.isFinished {
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
                            run { await store.spinSlingo(in: conversationID) }
                        } label: {
                            Text("SPIN")
                                .font(.title2.weight(.heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending)
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
                            isInteractive: isMyWildPick && !isRevealingNow
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
            .task(id: round.lastDrawAt) {
                await tickReveal(round: round)
            }
        }
    }

    private static func stage(for round: SlingoSnapshot.Round, now: Date) -> SlingoSnapshot.RevealStage {
        guard let draw = round.lastDraw, let drawnAt = round.lastDrawAt else { return .resolved }
        return SlingoSnapshot.revealStage(drawnAt: drawnAt, draw: draw, now: now)
    }

    /// `now` を刻んで, 演出の段階が進むたびに軽い触覚を鳴らす.
    /// 段階が `.resolved` になったら, これ以上刻む必要が無いので抜ける.
    private func tickReveal(round: SlingoSnapshot.Round) async {
        guard round.lastDraw != nil, round.lastDrawAt != nil else { return }
        var announcedFace = false
        while !Task.isCancelled {
            now = .now
            let stage = Self.stage(for: round, now: now)
            if stage != .spinning, !announcedFace {
                GameHaptics.tick()
                announcedFace = true
            }
            if stage == .resolved {
                if case .wild = round.lastDraw {
                    GameHaptics.result(didWin: true)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func turnBanner(_ snapshot: SlingoSnapshot, isRevealingNow: Bool) -> some View {
        let text: String
        if isRevealingNow {
            text = ""
        } else if snapshot.isFinished {
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

    /// SPIN の結果を出すリール.
    ///
    /// `.spinning` と `.face`(「？」)は WILD かハズレかで見た目もタイミングも
    /// 変えない ―― 演出だけを見て事前に当たり外れを読めないようにするため
    /// (`SlingoSnapshot.RevealStage` のコメント参照)。
    private func reelView(round: SlingoSnapshot.Round, stage: SlingoSnapshot.RevealStage) -> some View {
        let text: String
        switch stage {
        case .spinning:
            text = round.lastDraw == nil ? "-" : "…"
        case .face:
            text = "？"
        case .resolved:
            switch round.lastDraw {
            case .number(let value): text = "\(value)"
            case .wild: text = "WILD"
            case .miss: text = "ハズレ"
            case nil: text = "-"
            }
        }
        let isPulsing = stage != .resolved && round.lastDraw != nil

        return Text(text)
            .font(.system(size: 36, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .frame(width: 140, height: 90)
            .background(
                Color.accentColor.opacity(isPulsing ? 0.10 : 0.18),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            .scaleEffect(isPulsing ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: stage)
    }

    private func resultLine(_ snapshot: SlingoSnapshot) -> some View {
        let winners = snapshot.round?.finisherIDs ?? []
        let text: String
        if winners.count == 1 {
            text = String(localized: "\(store.displayName(for: winners[0])) がスリンゴ! 総取りです")
        } else if winners.isEmpty {
            text = ""
        } else {
            let names = winners.map { store.displayName(for: $0) }.joined(separator: "、")
            text = String(localized: "\(names) が同時にスリンゴ! 山分けです")
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
                        Text("スリンゴ!")
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
