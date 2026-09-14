import SwiftUI

/// CHIP ランキング(このアプリを使っている人全員).
///
/// 掲示板と同じく「みんなが見る場所」なので, 名前と持っている CHIP だけを出す.
/// CHIP はアプリ内のゲームでしか使えないポイントで, お金とは交換できない.
struct ChipRankingView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ChipRankingEntry] = []
    @State private var isLoading = false
    @State private var isShowingRevivalWheel = false

    private var store: ChatStore { environment.store }
    private var me: UserID? { store.currentUserID }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    myStandingRow
                    if store.isRevivalDue {
                        Button(String(localized: "復活ルーレットを回す")) {
                            isShowingRevivalWheel = true
                        }
                    } else if let notice = store.bankruptNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    }
                }

                Section {
                    if isLoading && entries.isEmpty {
                        HStack {
                            ProgressView()
                            Text("読み込み中…").foregroundStyle(Palette.subdued)
                        }
                    } else if entries.isEmpty {
                        Text("まだ誰も遊んでいません")
                            .foregroundStyle(Palette.subdued)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(place: index + 1, entry: entry)
                        }
                    }
                } header: {
                    Text("ランキング")
                } footer: {
                    Text("CHIPはアプリの中のゲームでしか使えないポイントです。買うことも、誰かに渡すことも、お金やギフト券などと交換することもできません。")
                }
            }
            .navigationTitle("CHIPランキング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $isShowingRevivalWheel, onDismiss: { Task { await load() } }) {
                ChipRevivalWheelView()
            }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
        }
    }

    // MARK: - 部品

    private var myStandingRow: some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("あなたの持ち CHIP")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Text(ChipRules.formatted(store.chipBalance))
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            Spacer()
            if let place = myPlace {
                Text("\(place)位")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var myPlace: Int? {
        guard let me, let index = entries.firstIndex(where: { $0.ownerID == me }) else { return nil }
        return index + 1
    }

    private func row(place: Int, entry: ChipRankingEntry) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            Text(placeLabel(place))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(width: 36, alignment: .leading)
                .foregroundStyle(place <= 3 ? Color.accentColor : Palette.subdued)

            if let profile = store.profilesByID[entry.ownerID] {
                AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
            }

            Text(store.displayName(for: entry.ownerID))
                .font(.body)
                .lineLimit(1)

            if entry.ownerID == me {
                Text("あなた")
                    .font(.caption2)
                    .foregroundStyle(Palette.subdued)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Palette.incomingBubble, in: Capsule())
            }

            Spacer(minLength: 0)

            Text(ChipRules.formatted(entry.balance))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// 上位 3 人だけメダルを添える.
    private func placeLabel(_ place: Int) -> String {
        switch place {
        case 1: "🥇"
        case 2: "🥈"
        case 3: "🥉"
        default: "\(place)"
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        await store.refreshWallet()
        entries = await store.fetchChipRanking()
    }
}

#Preview {
    ChipRankingView()
        .environment(AppEnvironment.preview())
}
