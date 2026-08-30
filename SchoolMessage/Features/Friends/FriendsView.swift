import SwiftUI

/// 友達一覧とユーザ検索.
///
/// ユーザIDでの完全一致検索を主経路にしている. 学校では口頭で
/// 「ID は tanaka_2a」と伝えるほうが速く, 名前の部分一致より確実なため.
struct FriendsView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private var store: ChatStore { environment.store }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section(String(localized: "検索結果")) {
                        if isSearching {
                            HStack {
                                ProgressView()
                                Text("検索中…").foregroundStyle(Palette.subdued)
                            }
                        } else if results.isEmpty {
                            Text("見つかりませんでした")
                                .foregroundStyle(Palette.subdued)
                        } else {
                            ForEach(results) { profile in
                                searchResultRow(profile)
                            }
                        }
                    }
                }

                Section(String(localized: "友達")) {
                    if store.friends.isEmpty {
                        Text("まだ友達がいません。上の検索でユーザIDを入力して追加してください。")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else {
                        ForEach(store.friends) { profile in
                            friendRow(profile)
                        }
                        .onDelete(perform: removeFriends)
                    }
                }
            }
            .navigationTitle("友達")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("ユーザIDまたは名前")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .task {
                await store.refreshFriends()
            }
        }
    }

    // MARK: - 行

    private func searchResultRow(_ profile: UserProfile) -> some View {
        HStack {
            AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
            VStack(alignment: .leading) {
                Text(profile.displayName)
                Text("@\(profile.handle)")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }
            Spacer()
            if store.friends.contains(where: { $0.id == profile.id }) {
                Text("追加済み")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            } else {
                Button(String(localized: "追加")) {
                    Task { await store.addFriend(profile) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func friendRow(_ profile: UserProfile) -> some View {
        Button {
            Task {
                // チャットを開いてシートを閉じる. 「友達を選ぶ → すぐ送る」を 2 タップに.
                if await store.openDirectConversation(with: profile) != nil {
                    dismiss()
                }
            }
        } label: {
            HStack {
                AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
                VStack(alignment: .leading) {
                    Text(profile.displayName)
                        .foregroundStyle(Color.primary)
                    Text("@\(profile.handle)")
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
                Spacer()
                Image(systemName: "bubble.left")
                    .foregroundStyle(Palette.subdued)
            }
        }
        .accessibilityHint(String(localized: "チャットを開きます"))
    }

    private func removeFriends(at offsets: IndexSet) {
        let targets = offsets.map { store.friends[$0] }
        Task {
            for profile in targets {
                await store.removeFriend(profile)
            }
        }
    }

    // MARK: - 検索

    /// 1 文字ごとに問い合わせるとサーバへの往復が増えるので, 入力が
    /// 落ち着いてから検索する.
    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await store.searchUsers(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

#Preview {
    FriendsView()
        .environment(AppEnvironment.preview())
}
