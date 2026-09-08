import SwiftUI

/// 左ペイン: チャット一覧.
///
/// 起動して最初に目に入る画面なので, 表示までの手数を最小にする.
/// - すでに読み込んだ内容があれば即座に描き, 更新は裏で行う.
/// - 行をタップした瞬間に右ペインへ反映する(確定を待たない).
struct ChatListView: View {

    @Environment(AppEnvironment.self) private var environment
    @Binding var selection: ConversationID?

    var onShowFriends: () -> Void
    var onCreateGroup: () -> Void
    var onShowBoard: () -> Void
    var onShowStreetPass: () -> Void
    var onShowProfile: () -> Void

    private var store: ChatStore { environment.store }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.conversations) { conversation in
                ChatListRow(conversation: conversation)
                    .tag(conversation.id)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await store.leaveConversation(conversation.id) }
                        } label: {
                            Label(String(localized: "退出"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("チャット")
        .overlay {
            if store.conversations.isEmpty && !store.isRefreshingConversations {
                emptyState
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !store.isOnline {
                    OfflineBar()
                }
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                        .padding(.top, AppConstants.Layout.compactSpacing)
                }
            }
        }
        .refreshable {
            await store.refreshConversations()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onShowFriends) {
                    Label(String(localized: "友達"), systemImage: "person.2")
                }
                Button(action: onCreateGroup) {
                    Label(String(localized: "グループを作成"), systemImage: "person.3.sequence")
                }
                Button(action: onShowBoard) {
                    Label(String(localized: "掲示板"), systemImage: "text.bubble")
                }
                Button(action: onShowStreetPass) {
                    Label(String(localized: "すれ違い通信"), systemImage: "figure.walk.motion")
                }
                .overlay(alignment: .topTrailing) {
                    // すれ違った相手がいることは, 開かないと気付けないので印を出す.
                    if environment.streetPass.unseenCount > 0 {
                        Circle()
                            .fill(Palette.unreadBadge)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onShowProfile) {
                    if let profile = store.myProfile {
                        AvatarView(profile: profile, size: 28)
                    } else {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .accessibilityLabel(String(localized: "プロフィール"))
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task { await store.openConversation(newValue) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "まだチャットがありません"), systemImage: "bubble.left")
        } description: {
            Text("友達を追加すると、ここにチャットが並びます。")
        } actions: {
            Button(String(localized: "友達を追加"), action: onShowFriends)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 一覧の 1 行.
struct ChatListRow: View {

    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation

    private var store: ChatStore { environment.store }

    var body: some View {
        HStack(alignment: .center, spacing: AppConstants.Layout.standardSpacing) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.title(for: conversation))
                        .font(.body.weight(conversation.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: AppConstants.Layout.compactSpacing)
                    if let last = conversation.lastMessage {
                        Text(DateDisplay.listTimestamp(last.createdAt))
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                }

                HStack(alignment: .center, spacing: AppConstants.Layout.compactSpacing) {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(Palette.subdued)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if conversation.unreadCount > 0 {
                        unreadBadge
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var avatar: some View {
        Group {
            if let counterpart = store.counterpartProfile(for: conversation) {
                AvatarView(profile: counterpart, size: AppConstants.Layout.avatarMedium)
            } else {
                AvatarView(
                    imageData: conversation.imageData,
                    fallbackText: String(store.title(for: conversation).prefix(1)),
                    seed: conversation.id.rawValue,
                    size: AppConstants.Layout.avatarMedium
                )
            }
        }
    }

    /// グループでは「誰が言ったか」も出す.
    private var previewText: String {
        guard let last = conversation.lastMessage else {
            return String(localized: "メッセージはまだありません")
        }
        guard conversation.kind == .group, last.senderID != store.currentUserID else {
            return last.preview
        }
        return "\(store.displayName(for: last.senderID)): \(last.preview)"
    }

    private var unreadBadge: some View {
        Text(conversation.unreadCount > 99 ? "99+" : "\(conversation.unreadCount)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Palette.unreadBadge, in: Capsule())
            .monospacedDigit()
    }

    /// VoiceOver では「名前・未読件数・最後のメッセージ・時刻」を一続きで読む.
    private var accessibilityLabel: String {
        var parts: [String] = [store.title(for: conversation)]
        if conversation.unreadCount > 0 {
            parts.append(String(localized: "未読 \(conversation.unreadCount) 件"))
        }
        parts.append(previewText)
        if let last = conversation.lastMessage {
            parts.append(DateDisplay.accessibilityTimestamp(last.createdAt))
        }
        return parts.joined(separator: "、")
    }
}

#Preview {
    NavigationStack {
        ChatListView(
            selection: .constant(nil),
            onShowFriends: {},
            onCreateGroup: {},
            onShowBoard: {},
            onShowProfile: {}
        )
    }
    .environment(AppEnvironment.preview())
}
