import SwiftUI

/// アプリの最上位.
///
/// 起動 → 状態判定 → 2 カラムのチャット画面, という流れを 1 箇所で表す.
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    /// 同意画面を出す必要があるか.
    ///
    /// `AppConstants.Legal.requiresConsent` が `false` の間(身内だけで使う段階)は,
    /// 未同意でも画面を素通りする. 画面自体・文書は消していないので,
    /// フラグを `true` に戻すだけで同意を要求する状態に復帰できる.
    private var needsConsentGate: Bool {
        AppConstants.Legal.requiresConsent && !environment.consent.hasAgreedToCurrentVersion
    }

    var body: some View {
        Group {
            // 同意はどの画面よりも先に取る. iCloud の状態に関わらず,
            // 規約に同意していない状態でアプリの中身を見せない.
            if needsConsentGate {
                ConsentGateView()
                    .environment(environment.consent)
            } else {
                switch environment.store.phase {
                case .launching:
                    LaunchPlaceholderView()
                case .blocked(let error):
                    BlockedView(error: error)
                case .needsRegistration:
                    RegistrationView()
                case .ready:
                    MainSplitView()
                }
            }
        }
        .animation(.default, value: environment.store.phase)
        .animation(.default, value: needsConsentGate)
    }
}

/// 起動直後の待ち時間に出す表示.
///
/// アプリアイコンから続く見た目にして, 「固まっている」ように見せない.
private struct LaunchPlaceholderView: View {
    var body: some View {
        VStack(spacing: AppConstants.Layout.standardSpacing) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.chatBackground)
        .accessibilityLabel(String(localized: "読み込み中"))
    }
}

/// iCloud サインインなど, アプリ側で解決できない問題の案内.
private struct BlockedView: View {
    let error: AppError
    @Environment(AppEnvironment.self) private var environment
    @Environment(DemoModeTrigger.self) private var demoTrigger

    var body: some View {
        ContentUnavailableView {
            Label(error.errorDescription ?? String(localized: "利用できません"), systemImage: "icloud.slash")
        } description: {
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
            }
        } actions: {
            Button(String(localized: "再確認")) {
                Task { await environment.store.start() }
            }
            .buttonStyle(.borderedProminent)

            Button(String(localized: "デモモードで試す")) {
                demoTrigger.isRequested = true
            }
            .buttonStyle(.bordered)
        }
    }
}

/// iPad 向けの 2 カラム.
///
/// 左にチャット一覧, 右に会話. 縦向きや Split View で幅が狭いときは
/// `NavigationSplitView` が自動で 1 カラムに畳む.
private struct MainSplitView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var presentedSheet: Sheet?

    private enum Sheet: String, Identifiable {
        case friends, createGroup, board, streetPass, profile
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var store = environment.store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChatListView(
                selection: $store.selectedConversationID,
                onShowFriends: { presentedSheet = .friends },
                onCreateGroup: { presentedSheet = .createGroup },
                onShowBoard: { presentedSheet = .board },
                onShowStreetPass: { presentedSheet = .streetPass },
                onShowProfile: { presentedSheet = .profile }
            )
            .navigationSplitViewColumnWidth(
                min: AppConstants.Layout.sidebarMinWidth,
                ideal: AppConstants.Layout.sidebarIdealWidth,
                max: AppConstants.Layout.sidebarMaxWidth
            )
        } detail: {
            if let conversationID = store.selectedConversationID,
               let conversation = store.conversation(conversationID) {
                ChatDetailView(conversation: conversation)
                    // 会話を切り替えたときに状態を確実に作り直す.
                    .id(conversation.id)
            } else {
                EmptyChatPlaceholder()
            }
        }
        // 横向きでは常に一覧を出したままにして, 会話の切り替えを 1 タップにする.
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .friends:
                FriendsView()
            case .createGroup:
                CreateGroupView()
            case .board:
                BoardView()
            case .streetPass:
                StreetPassView()
            case .profile:
                ProfileView()
            }
        }
        .onChange(of: store.pendingNotificationConversationID) { _, pending in
            // 通知をタップして指定されたチャットを開く.
            guard let pending else { return }
            store.pendingNotificationConversationID = nil
            Task { await store.openConversation(pending) }
        }
    }
}

/// まだ会話を選んでいないときの右ペイン.
private struct EmptyChatPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            String(localized: "チャットを選んでください"),
            systemImage: "bubble.left.and.bubble.right",
            description: Text("左の一覧から相手を選ぶと、ここに会話が表示されます。")
        )
        .background(Palette.chatBackground)
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.preview())
        .environment(DemoModeTrigger())
}
