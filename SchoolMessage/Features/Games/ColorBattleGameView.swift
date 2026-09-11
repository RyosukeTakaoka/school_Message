import SwiftUI

/// 色勝負の対戦画面.
///
/// オセロと同じく, 1 手 = 1 メッセージ. この画面は「いまの場を描いて,
/// 出したら 1 手ぶん送る」だけを受け持つ.
struct ColorBattleGameView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let conversationID: ConversationID

    @State private var isSending = false
    /// 復号済みの自分の手札. 相手の手札は復号する手立てが無いため持たない
    /// (`opponentHandSection` は枚数だけを表示する).
    @State private var myHand: [ColorCard] = []

    // MARK: - 切り札の公開演出

    /// 演出のもとになる, 決着したばかりの回戦(表示中はここに入る. 終われば nil).
    @State private var revealingRound: ColorBattleRound?
    @State private var isTrumpRevealedInOverlay = false
    @State private var isWinnerRevealedInOverlay = false
    /// 直近で演出を出した回戦番号(会話を開き直しただけで昔の結果を演出しないため).
    @State private var lastAnimatedRoundNumber: Int?
    @State private var hasInitializedReveal = false

    private var store: ChatStore { environment.store }

    private var snapshot: ColorBattleSnapshot? {
        store.currentGame(kind: .colorBattle, in: conversationID)?.colorBattle
    }

    private var me: UserID? { store.currentUserID }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot, let me, snapshot.isPlayer(me) {
                    table(snapshot, me: me)
                } else {
                    startPrompt
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.chatBackground)
            .navigationTitle("色勝負")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
            .overlay {
                if let revealingRound, let me {
                    revealOverlay(revealingRound, me: me)
                        .transition(.opacity)
                }
            }
        }
        // 手札は暗号化されているため, 対戦の状態(=誰かが 1 手進めるたび)が
        // 変わるたびに, 自分の分だけを復号し直す.
        .task(id: snapshot) {
            myHand = await store.decryptedColorBattleHand(in: conversationID)
        }
        .onChange(of: snapshot?.lastRound) { _, newValue in
            handleRoundResolved(newValue)
        }
    }

    /// 回戦が決着したときの演出を出す.
    ///
    /// 切り札はゲーム開始時にもう全 8 回戦ぶん決まっている(`ColorBattleSnapshot.trump`
    /// は `gameID` と回戦数だけから決まる決定的な値)が, 画面には「両者が札を
    /// 出し終えるまで」あえて出さない. 読み合いの核はここにあるため.
    private func handleRoundResolved(_ round: ColorBattleRound?) {
        guard let round else { return }
        guard hasInitializedReveal else {
            // 会話を開いた直後(既にある結果を読み込んだだけ)では演出しない.
            hasInitializedReveal = true
            lastAnimatedRoundNumber = round.round
            return
        }
        guard lastAnimatedRoundNumber != round.round else { return }
        lastAnimatedRoundNumber = round.round
        playReveal(round)
    }

    private func playReveal(_ round: ColorBattleRound) {
        revealingRound = round
        isTrumpRevealedInOverlay = false
        isWinnerRevealedInOverlay = false
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard revealingRound?.round == round.round else { return }
            withAnimation(.spring(duration: 0.35)) { isTrumpRevealedInOverlay = true }

            try? await Task.sleep(for: .milliseconds(650))
            guard revealingRound?.round == round.round else { return }
            withAnimation(.easeOut(duration: 0.25)) { isWinnerRevealedInOverlay = true }

            try? await Task.sleep(for: .seconds(2))
            guard revealingRound?.round == round.round else { return }
            withAnimation(.easeOut(duration: 0.25)) { revealingRound = nil }
        }
    }

    /// 決着の瞬間だけ出す, 一時的な演出画面.
    private func revealOverlay(_ round: ColorBattleRound, me: UserID) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(spacing: AppConstants.Layout.standardSpacing) {
                Text("第 \(round.round) 回戦")
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: AppConstants.Layout.standardSpacing) {
                    revealCardColumn(
                        round.leadCard,
                        label: round.leaderID == me ? String(localized: "あなた") : opponentName(round.leaderID),
                        trump: isTrumpRevealedInOverlay ? round.trump : nil
                    )
                    Text("対")
                        .foregroundStyle(.white.opacity(0.7))
                    revealCardColumn(
                        round.followCard,
                        label: round.followerID == me ? String(localized: "あなた") : opponentName(round.followerID),
                        trump: isTrumpRevealedInOverlay ? round.trump : nil
                    )
                }

                trumpBadge(round)

                if isWinnerRevealedInOverlay {
                    Text(round.winnerID == me
                         ? String(localized: "あなたの勝ち +\(round.points)点")
                         : String(localized: "\(opponentName(round.winnerID)) の勝ち +\(round.points)点"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // タップで早送りできるようにしておく(気持ちよさより, 遊びのテンポを優先したい人もいる).
            withAnimation(.easeOut(duration: 0.2)) {
                revealingRound = nil
            }
        }
    }

    private func revealCardColumn(_ card: ColorCard, label: String, trump: CardColor?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            ColorCardView(card: card, isTrump: trump == card.color)
        }
    }

    @ViewBuilder
    private func trumpBadge(_ round: ColorBattleRound) -> some View {
        if isTrumpRevealedInOverlay {
            HStack(spacing: 6) {
                Text("切り札")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Image(systemName: round.trump.symbolName)
                Text(round.trump.title)
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(round.trump.tint, in: Capsule())
            .transition(.scale.combined(with: .opacity))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                Text("切り札は伏せられています")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - 対戦が無いとき

    private var startPrompt: some View {
        ContentUnavailableView {
            Label(String(localized: "色勝負をする"), systemImage: "square.stack.3d.up")
        } description: {
            Text(Self.rulesText)
                .multilineTextAlignment(.leading)
        } actions: {
            Button(String(localized: "対戦を始める")) {
                Task { await startGame() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || opponentID == nil)
        }
    }

    private static let rulesText = String(localized: """
        毎回戦、切り札の色が決まりますが、両者が札を出し終えるまで何色かは分かりません。切り札の色の札は、数字に関係なく切り札でない札に勝ちます。どちらも切り札か、どちらも切り札でないときは、数字の大きいほうが勝ちです。

        先に出す人は相手の出方を知らずに出すので、同じ数字なら先に出した人の勝ちです。先に出す人は 1 回戦ごとに交代します。

        勝った人は、2 枚の数字の合計を得点します。手札を出しきったときに、得点の多いほうが勝ちです。
        """)

    // MARK: - 場

    private func table(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                scoreBar(snapshot, me: me)
                Divider()

                if snapshot.isFinished {
                    resultSection(snapshot, me: me)
                } else {
                    roundHeader(snapshot)
                    statusLine(snapshot, me: me)
                    fieldSection(snapshot, me: me)
                }

                if let last = snapshot.lastRound {
                    lastRoundSection(last, me: me)
                }

                Divider()
                opponentHandSection(snapshot, me: me)
                myHandSection(snapshot, me: me)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func scoreBar(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            scoreChip(String(localized: "あなた"), score: snapshot.score(for: me))
            if let opponent = snapshot.opponentID(of: me) {
                scoreChip(opponentName(opponent), score: snapshot.score(for: opponent))
            }
            Spacer(minLength: 0)
        }
    }

    private func scoreChip(_ name: String, score: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            Text("\(score)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(name) \(score) 点"))
    }

    private func roundHeader(_ snapshot: ColorBattleSnapshot) -> some View {
        HStack(spacing: AppConstants.Layout.compactSpacing) {
            Text("第 \(snapshot.round) 回戦 / \(ColorBattleSnapshot.handSize)")
                .font(.headline)
            Spacer(minLength: 0)
            // この回戦の切り札は, 両者が札を出し終えるまで画面には出さない
            // (`ColorBattleSnapshot.trump` としてはもう決まっている値だが,
            // あえて隠すことで「見えない切り札を読む」駆け引きにしている).
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                Text("切り札は伏せられています")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Palette.subdued)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.incomingBubble, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "切り札は伏せられています"))
        }
    }

    @ViewBuilder
    private func statusLine(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        if snapshot.isTurn(of: me) {
            Text(snapshot.isLeading(me)
                 ? String(localized: "あなたの番です。先に 1 枚出してください")
                 : String(localized: "あなたの番です。相手の札に応じて 1 枚出してください"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Text(snapshot.pendingLeadCard == nil
                 ? String(localized: "相手が先に出すのを待っています")
                 : String(localized: "相手が応じるのを待っています"))
                .font(.subheadline)
                .foregroundStyle(Palette.subdued)
        }
    }

    /// いま場に出ている札.
    ///
    /// 切り札かどうかの縁取りは付けない. まだ両者が出し終えていない回戦で
    /// 「縁取りがある = 切り札だ」と分かってしまうと, 切り札を隠している意味が無い.
    @ViewBuilder
    private func fieldSection(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        if let lead = snapshot.pendingLeadCard {
            HStack(spacing: AppConstants.Layout.standardSpacing) {
                VStack(spacing: 4) {
                    Text(snapshot.leaderID == me ? String(localized: "あなたが出した札") : String(localized: "相手が出した札"))
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                    ColorCardView(card: lead, isTrump: false)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func lastRoundSection(_ last: ColorBattleRound, me: UserID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(last.round) 回戦の結果")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            HStack(spacing: AppConstants.Layout.compactSpacing) {
                ColorCardView(card: last.leadCard, isTrump: last.leadCard.color == last.trump, size: .small)
                Text("対")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                ColorCardView(card: last.followCard, isTrump: last.followCard.color == last.trump, size: .small)
                Text(last.winnerID == me
                     ? String(localized: "あなたの勝ち +\(last.points)")
                     : String(localized: "相手の勝ち +\(last.points)"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(last.winnerID == me ? Color.accentColor : Palette.subdued)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func resultSection(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
            Text(resultText(snapshot, me: me))
                .font(.title3.weight(.semibold))
            Button(String(localized: "もう一局")) {
                Task { await startGame() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
        }
    }

    private func resultText(_ snapshot: ColorBattleSnapshot, me: UserID) -> String {
        guard let winner = snapshot.winnerID else { return String(localized: "引き分けです") }
        return winner == me ? String(localized: "あなたの勝ちです") : String(localized: "あなたの負けです")
    }

    // MARK: - 手札

    @ViewBuilder
    private func opponentHandSection(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        if let opponent = snapshot.opponentID(of: me) {
            VStack(alignment: .leading, spacing: 6) {
                Text("相手の手札")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                // 相手の手札は相手の公開鍵宛てに封じてあり, 復号する手立てが無い.
                // 中身は見せず, 残り枚数だけを裏向きの札で示す.
                faceDownCardRow(count: snapshot.handCount(for: opponent))
            }
        }
    }

    private func myHandSection(_ snapshot: ColorBattleSnapshot, me: UserID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("あなたの手札")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            let canPlay = snapshot.isTurn(of: me) && !isSending
            // 切り札は自分の手札の中でも分からない(縁取りで教えてしまうと,
            // 「自分のこの色が切り札かどうか」を読む楽しさが無くなる).
            cardRow(myHand, trump: nil, size: .large) { card in
                guard canPlay else { return }
                Task { await play(card) }
            }
            .opacity(canPlay ? 1 : 0.55)
        }
    }

    /// 相手の手札の代わりに出す, 中身の見えない札の並び(枚数だけ伝える).
    private func faceDownCardRow(count: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if count == 0 {
                    Text("なし")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.subdued.opacity(0.3))
                        .frame(width: ColorCardView.Size.small.width, height: ColorCardView.Size.small.height)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                        }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "相手の手札 残り\(count)枚"))
    }

    private func cardRow(
        _ cards: [ColorCard],
        trump: CardColor?,
        size: ColorCardView.Size,
        onTap: ((ColorCard) -> Void)? = nil
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if cards.isEmpty {
                    Text("なし")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
                ForEach(cards) { card in
                    if let onTap {
                        Button {
                            onTap(card)
                        } label: {
                            ColorCardView(card: card, isTrump: card.color == trump, size: size)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ColorCardView(card: card, isTrump: card.color == trump, size: size)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 動作

    private var opponentID: UserID? {
        guard let me, let conversation = store.conversation(conversationID) else { return nil }
        return conversation.participantIDs.first { $0 != me }
    }

    private func opponentName(_ userID: UserID) -> String {
        store.profilesByID[userID]?.displayName ?? String(localized: "相手")
    }

    private func startGame() async {
        guard let opponent = opponentID else { return }
        isSending = true
        defer { isSending = false }
        // 対戦を始めた人が第 1 回戦のリードになる.
        await store.startColorBattle(with: opponent, in: conversationID)
    }

    private func play(_ card: ColorCard) async {
        isSending = true
        defer { isSending = false }
        await store.playColorBattleCard(card, in: conversationID)
    }
}

/// 1 枚の札の見た目.
struct ColorCardView: View {

    enum Size {
        case small
        case large

        var width: CGFloat { self == .small ? 40 : 58 }
        var height: CGFloat { self == .small ? 56 : 80 }
        var numberFont: Font { self == .small ? .headline : .largeTitle }
    }

    let card: ColorCard
    var isTrump: Bool = false
    var size: Size = .large

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: card.color.symbolName)
                .font(size == .small ? .caption2 : .footnote)
            Text("\(card.number)")
                .font(size.numberFont.weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .background(card.color.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            // 切り札は縁で示す. 色の違いだけに頼らない.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isTrump ? Color.primary : Color.black.opacity(0.15), lineWidth: isTrump ? 3 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isTrump
                            ? String(localized: "\(card.label) 切り札")
                            : card.label)
    }
}

extension CardColor {
    /// 画面に出す色. 白い数字が読めるよう, どれも十分に濃くする.
    var tint: Color {
        switch self {
        case .red: Color(red: 0.80, green: 0.19, blue: 0.24)
        case .blue: Color(red: 0.13, green: 0.36, blue: 0.75)
        case .green: Color(red: 0.13, green: 0.51, blue: 0.31)
        case .yellow: Color(red: 0.71, green: 0.51, blue: 0.06)
        }
    }
}

#Preview {
    ColorBattleGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
