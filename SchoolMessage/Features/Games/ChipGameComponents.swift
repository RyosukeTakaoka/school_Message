import SwiftUI
import UIKit

/// ゲームの節目で軽い触覚を鳴らす.
///
/// 派手にしすぎると鬱陶しいので, 「めくれた」のような小さな節目は軽い
/// インパクトだけにし, 「結果が出た」場面だけ少し強めの通知にする.
///
/// 設定(`GamePreferences.hapticsEnabled`)でオフにできる. 各ゲーム画面から
/// 直接呼ばれる静的な関数なので, `AppEnvironment` を経由せず `UserDefaults`
/// を直接読む(`GamePreferences.hapticsEnabledRawValue` 参照).
enum GameHaptics {
    static func tick() {
        guard GamePreferences.hapticsEnabledRawValue() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func result(didWin: Bool) {
        guard GamePreferences.hapticsEnabledRawValue() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(didWin ? .success : .warning)
    }
}

/// 手持ちの CHIP.
///
/// 出るたびに残高を取り直す(古ければ). 残高は起動時に 1 回取るだけだったため,
/// 別の端末で遊んだぶんや, 相手の端末で決着したぶん, 競馬の払い戻しが入った
/// ぶんに追いつけず, ミニゲームの画面にいつまでも古い数字が出ていた
/// (`ChatStore.refreshWalletIfStale` 参照).
struct ChipBalanceBadge: View {

    @Environment(AppEnvironment.self) private var environment
    var compact = false

    private var store: ChatStore { environment.store }

    /// まだ取れていないときは 0 と区別する(0 CHIP に見えてしまうため).
    private var text: String {
        store.isWalletLoaded ? ChipRules.formatted(store.chipBalance) : "—"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("🪙")
            Text(text)
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(Palette.incomingBubble, in: Capsule())
        .accessibilityLabel(
            store.isWalletLoaded
                ? String(localized: "持っているCHIP \(store.chipBalance)")
                : String(localized: "持っているCHIP 読み込み中")
        )
        .task { await store.refreshWalletIfStale() }
    }
}

/// 賭ける額を選ぶ. 持っている CHIP を超える額は出さない.
struct ChipBetPicker: View {

    @Environment(AppEnvironment.self) private var environment

    let maxBet: Int
    @Binding var bet: Int

    private var store: ChatStore { environment.store }

    private var options: [Int] {
        ChipRules.betOptions(maxBet: maxBet, balance: store.chipBalance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("賭けるCHIP")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { amount in
                        Button {
                            bet = amount
                        } label: {
                            Text("\(amount)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .frame(minWidth: 44)
                                .padding(.vertical, 8)
                                .background(
                                    bet == amount ? Color.accentColor : Palette.incomingBubble,
                                    in: Capsule()
                                )
                                .foregroundStyle(bet == amount ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            if options.isEmpty {
                Text("賭けられるCHIPが足りません")
                    .font(.caption)
                    .foregroundStyle(Palette.failure)
            }
        }
        .onAppear {
            if !options.contains(bet), let first = options.first { bet = first }
        }
    }
}

/// 対戦がまだ無いときの画面. 遊び方とベット選択, 募集ボタンを出す.
struct ChipGameStartPrompt: View {

    @Environment(AppEnvironment.self) private var environment

    let kind: GameSnapshot.Kind
    let rules: String
    let onCreate: (Int) -> Void

    @State private var bet = ChipRules.minBet
    @State private var isShowingRevivalWheel = false

    private var store: ChatStore { environment.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                HStack {
                    Label(kind.title, systemImage: kind.symbolName)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    ChipBalanceBadge()
                }

                Text(rules)
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
                    .fixedSize(horizontal: false, vertical: true)

                if let notice = store.bankruptNotice {
                    Label(notice, systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(Palette.failure)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.isRevivalDue {
                        Button(String(localized: "復活ルーレットを回す")) {
                            isShowingRevivalWheel = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ChipBetPicker(maxBet: kind.maxBet ?? ChipRules.defaultMaxBet, bet: $bet)

                    Button(String(localized: "この額で募集する")) {
                        onCreate(bet)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canPlayChipGames)

                    Text("\(kind.minimumPlayers)人以上そろうと始められます。CHIPはアプリの中のゲームでしか使えないポイントで、お金と交換することはできません。")
                        .font(.caption2)
                        .foregroundStyle(Palette.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
        .sheet(isPresented: $isShowingRevivalWheel) {
            ChipRevivalWheelView()
        }
    }
}

/// 参加者を募っている間の画面. 5 つの遊びで共通.
struct ChipGameLobbySection: View {

    @Environment(AppEnvironment.self) private var environment

    let kind: GameSnapshot.Kind
    let lobby: ChipGameLobby
    let hostID: UserID
    let isSending: Bool
    let onJoin: () -> Void
    let onLeave: (() -> Void)?
    /// 募集した人が募集ごと取りやめる. 始まる前だけ呼べる.
    let onCancel: (() -> Void)?
    let onStart: () -> Void
    /// これ以上参加できない上限人数. 上限が無い遊びは nil(既定).
    var maximumPlayers: Int? = nil

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }
    private var hasJoined: Bool { me.map(lobby.joinedPlayerIDs.contains) ?? false }
    private var isHost: Bool { me == hostID }
    private var isFull: Bool {
        guard let maximumPlayers else { return false }
        return lobby.joinedPlayerIDs.count >= maximumPlayers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
            HStack {
                Text("参加者(\(lobby.joinedPlayerIDs.count)人)")
                    .font(.headline)
                Spacer()
                ChipBalanceBadge()
            }

            Label(String(localized: "1人 \(ChipRules.formatted(lobby.bet))"), systemImage: "circle.hexagongrid.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            ForEach(lobby.joinedPlayerIDs, id: \.self) { playerID in
                HStack(spacing: 6) {
                    Text(store.displayName(for: playerID))
                    if playerID == hostID {
                        Text("(募集した人)")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                    Spacer()
                }
            }

            if lobby.joinedPlayerIDs.count < kind.minimumPlayers {
                Text("あと \(kind.minimumPlayers - lobby.joinedPlayerIDs.count) 人以上参加すると始められます")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            } else if let maximumPlayers, isFull {
                Text("満員です(最大\(maximumPlayers)人)")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }

            if let notice = store.bankruptNotice, !hasJoined {
                Label(notice, systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppConstants.Layout.standardSpacing) {
                if !hasJoined {
                    Button(String(localized: "参加する"), action: onJoin)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || isFull || store.chipBalance < lobby.bet || !store.canPlayChipGames)
                } else if !isHost, let onLeave {
                    Button(String(localized: "参加を取りやめる"), role: .destructive, action: onLeave)
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                }

                if isHost {
                    Button(String(localized: "開始する"), action: onStart)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || lobby.joinedPlayerIDs.count < kind.minimumPlayers)
                }

                // 始まる前なら取りやめられる(始まったあとは賭けを無かったことに
                // できないよう取り消せない). 1 対 1 では相手が作った募集も
                // 取りやめられるので, 出すかどうかは呼び出し側が決める.
                if let onCancel {
                    Button(String(localized: "募集を取り消す"), role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                }
            }
        }
        .padding(AppConstants.Layout.standardSpacing)
    }
}

/// 決着したあと, 同じチャットですぐ次の対戦を始めるための部品.
///
/// 賭ける額を選び直せるようにしてあるのは, 「同じ額でもう一回」しかできないと
/// 持ち CHIP が減ったときに次を始められなくなるため.
struct ChipGameRematchSection: View {

    @Environment(AppEnvironment.self) private var environment

    let kind: GameSnapshot.Kind
    /// 直前の対戦で賭けていた額. 最初はこれを選んでおく.
    let previousBet: Int
    let isSending: Bool
    let onCreate: (Int) -> Void

    @State private var chosenBet: Int?

    private var store: ChatStore { environment.store }

    /// 選び直していない間は直前の額を使う.
    private var bet: Binding<Int> {
        Binding(get: { chosenBet ?? previousBet }, set: { chosenBet = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
            Divider()
            if let notice = store.bankruptNotice {
                Label(notice, systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ChipBetPicker(maxBet: kind.maxBet ?? ChipRules.defaultMaxBet, bet: bet)
                Button(String(localized: "この額でもう一回")) {
                    onCreate(bet.wrappedValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !store.canPlayChipGames)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 決着したときに出す CHIP の増減.
struct ChipResultBanner: View {

    let delta: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("🪙")
            Text(ChipRules.formattedDelta(delta))
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        if delta > 0 { return .green }
        if delta < 0 { return Palette.failure }
        return Palette.subdued
    }
}

/// ゲーム画面の外枠. 4 つの遊びで同じ見た目にするためにまとめてある.
struct ChipGameScaffold<Content: View>: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let title: String
    @ViewBuilder var content: () -> Content

    private var store: ChatStore { environment.store }

    var body: some View {
        NavigationStack {
            content()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.chatBackground)
                .navigationTitle(title)
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
        }
    }
}

/// カードの裏面. めくられる前の「溜め」の間, ずっとこれが見えている.
struct CardBackView: View {

    var size: PlayingCardView.Size = .large

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.gradient)
            .overlay {
                Image(systemName: "seal.fill")
                    .font(.system(size: size.suitFontSize * 1.3))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

/// カードを 1 枚, めくる演出つきで出す.
///
/// `isFaceUp` が変わるたびに, 表と裏をそれぞれ 90度だけ逆向きに回して
/// 透明度を入れ替える. 180度回して同じ面の裏側を見せる作りだと,
/// 表の文字が一瞬鏡文字になって見えてしまうので, それぞれ 90度までしか回さない.
struct FlippableCardView: View {

    let card: PlayingCard
    var size: PlayingCardView.Size = .large
    var isFaceUp: Bool

    var body: some View {
        ZStack {
            CardBackView(size: size)
                .rotation3DEffect(.degrees(isFaceUp ? -90 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFaceUp ? 0 : 1)
            PlayingCardView(card: card, size: size)
                .rotation3DEffect(.degrees(isFaceUp ? 0 : 90), axis: (x: 0, y: 1, z: 0))
                .opacity(isFaceUp ? 1 : 0)
        }
    }
}

/// 手札や公開された札を並べて出す.
///
/// 増えた分(ブラックジャックの HIT)や, まだめくっていない分
/// (ダウトで開示された札)を, 少し間を置いてから 1 枚ずつめくる.
/// まとめて一気に出すと味気ないので, それぞれのカードの間に「溜め」を作る.
struct RevealingCardRow: View {

    let cards: [PlayingCard]
    var size: PlayingCardView.Size = .small
    var revealDelay: Duration = .milliseconds(400)
    /// true: 表示された瞬間はまだ全部裏で, 最初から順番にめくる
    ///   (ダウトの開示のように, 見せる瞬間そのものが本番のとき).
    /// false: すでにある札はめくらず, 増えた分だけめくる(ブラックジャックの HIT).
    var startFaceDown = false
    /// 最後の 1 枚までめくり終えたときに呼ぶ.
    var onFinishedRevealing: (() -> Void)?

    @State private var faceUpCount: Int

    init(
        cards: [PlayingCard],
        size: PlayingCardView.Size = .small,
        revealDelay: Duration = .milliseconds(400),
        startFaceDown: Bool = false,
        onFinishedRevealing: (() -> Void)? = nil
    ) {
        self.cards = cards
        self.size = size
        self.revealDelay = revealDelay
        self.startFaceDown = startFaceDown
        self.onFinishedRevealing = onFinishedRevealing
        _faceUpCount = State(initialValue: startFaceDown ? 0 : cards.count)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                FlippableCardView(card: card, size: size, isFaceUp: index < faceUpCount)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: cards.count)
        // `.task(id:)` にしておくと, 画面が閉じられたときに自動でこの演出も
        // 打ち切られる(手動で Task を保持して cancel する必要が無い).
        .task(id: cards.count) {
            await reveal(to: cards.count)
        }
    }

    private func reveal(to newCount: Int) async {
        guard faceUpCount < newCount else {
            faceUpCount = newCount
            return
        }
        for index in faceUpCount..<newCount {
            try? await Task.sleep(for: revealDelay)
            guard !Task.isCancelled else { return }
            GameHaptics.tick()
            withAnimation(.easeInOut(duration: 0.35)) {
                faceUpCount = index + 1
            }
        }
        if faceUpCount == cards.count {
            onFinishedRevealing?()
        }
    }
}
