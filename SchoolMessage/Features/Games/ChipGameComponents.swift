import SwiftUI

/// 手持ちの CHIP.
struct ChipBalanceBadge: View {

    @Environment(AppEnvironment.self) private var environment
    var compact = false

    private var store: ChatStore { environment.store }

    var body: some View {
        HStack(spacing: 4) {
            Text("🪙")
            Text(ChipRules.formatted(store.chipBalance))
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(Palette.incomingBubble, in: Capsule())
        .accessibilityLabel(String(localized: "持っているCHIP \(store.chipBalance)"))
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

/// 参加者を募っている間の画面. 4 つの遊びで共通.
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

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }
    private var hasJoined: Bool { me.map(lobby.joinedPlayerIDs.contains) ?? false }
    private var isHost: Bool { me == hostID }

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
                        .disabled(isSending || store.chipBalance < lobby.bet || !store.canPlayChipGames)
                } else if !isHost, let onLeave {
                    Button(String(localized: "参加を取りやめる"), role: .destructive, action: onLeave)
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                }

                if isHost {
                    Button(String(localized: "開始する"), action: onStart)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || lobby.joinedPlayerIDs.count < kind.minimumPlayers)

                    // 始まる前なら, 募集した人はいつでも取りやめられる.
                    // 始まったあとは取り消せない(賭けを無かったことにできないように).
                    if let onCancel {
                        Button(String(localized: "募集を取り消す"), role: .destructive, action: onCancel)
                            .buttonStyle(.bordered)
                            .disabled(isSending)
                    }
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
