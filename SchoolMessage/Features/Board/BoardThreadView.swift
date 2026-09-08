import SwiftUI

/// 掲示板のスレッド(書き込み一覧 + 書き込み欄).
///
/// 名前は出さず, 「通し番号」と「そのスレッドの中だけで通じる短い ID」で表す.
/// 誰の発言かを追える程度の手掛かりは残しつつ, 実名でのやり取りにはしない
/// という, 掲示板らしい距離感を作るため.
struct BoardThreadView: View {

    @Environment(AppEnvironment.self) private var environment

    let thread: BoardThread

    @State private var posts: [BoardPost] = []
    @State private var draft = ""
    @State private var isLoading = false
    @State private var isSending = false
    @FocusState private var isInputFocused: Bool

    private var store: ChatStore { environment.store }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                    if isLoading && posts.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(posts) { post in
                        postRow(post)
                            .id(post.id)
                    }
                }
                .padding(AppConstants.Layout.standardSpacing)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.chatBackground)
            .onChange(of: posts.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .safeAreaInset(edge: .top) {
            if let error = store.banner {
                ErrorBannerView(error: error) { store.setBanner(nil) }
            }
        }
    }

    // MARK: - 部品

    private func postRow(_ post: BoardPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(post.number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Text("ID:\(post.displayID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.subdued)
                Text(DateDisplay.messageTimestamp(post.createdAt))
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                if post.authorID == store.currentUserID {
                    Text("自分")
                        .font(.caption2)
                        .foregroundStyle(Palette.subdued)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Palette.incomingBubble, in: Capsule())
                }
            }
            Text(post.body)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, AppConstants.Layout.compactSpacing)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: AppConstants.Layout.compactSpacing) {
            TextField(String(localized: "書き込む"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, AppConstants.Layout.standardSpacing)
                .padding(.vertical, 8)
                .frame(minHeight: AppConstants.Layout.composerMinHeight)
                .background(Palette.chatBackground, in: Capsule())

            if isSending {
                ProgressView().frame(width: 36, height: 36)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(!canSend)
                .accessibilityLabel(String(localized: "書き込む"))
            }
        }
        .padding(.horizontal, AppConstants.Layout.standardSpacing)
        .padding(.vertical, AppConstants.Layout.compactSpacing)
        .background(Palette.composerBackground)
    }

    // MARK: - 動作

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            posts = try await environment.backend.fetchBoardPosts(in: thread.id)
        } catch {
            store.setBanner(AppError.wrap(error))
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""

        Task {
            isSending = true
            defer { isSending = false }
            do {
                _ = try await environment.backend.createBoardPost(in: thread.id, body: text)
                await load()
            } catch {
                // 失敗したら書いた内容を戻す(消えてしまうと書き直しになる).
                draft = text
                store.setBanner(AppError.wrap(error))
            }
        }
    }
}

#Preview {
    NavigationStack {
        BoardThreadView(
            thread: BoardThread(title: "今日の給食", authorID: UserID("preview"))
        )
        .environment(AppEnvironment.preview())
    }
}
