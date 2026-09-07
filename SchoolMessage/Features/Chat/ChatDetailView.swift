import SwiftUI

/// 右ペイン: 会話.
struct ChatDetailView: View {

    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation

    @State private var viewingMedia: MediaAttachment?
    @State private var isShowingInfo = false
    @State private var isLoadingOlder = false
    /// 返信しようとしている元メッセージ. 入力欄に引用として出す.
    @State private var replyingTo: Message?
    /// 引用をタップして移動したときに, 一瞬強調する対象.
    @State private var highlightedMessageID: MessageID?

    private var store: ChatStore { environment.store }

    private var messages: [Message] {
        store.messagesByConversation[conversation.id] ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
                    if store.hasMoreHistory.contains(conversation.id) {
                        loadOlderButton
                    }

                    ForEach(rows) { row in
                        switch row.kind {
                        case .daySeparator(let date):
                            daySeparator(date)
                        case .message(let message, let grouped):
                            MessageBubbleView(
                                message: message,
                                conversation: conversation,
                                isGroupedWithPrevious: grouped,
                                onTapMedia: { viewingMedia = $0 },
                                onRetry: {
                                    Task { await store.retrySending(message.id, in: conversation.id) }
                                },
                                onCancel: {
                                    Task { await store.cancelSending(message.id, in: conversation.id) }
                                },
                                onReply: { replyingTo = message },
                                onTapQuote: { original in
                                    scrollToOriginal(original, using: proxy)
                                }
                            )
                            .id(message.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                // 引用から飛んできた元メッセージを短く強調する.
                                if highlightedMessageID == message.id {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.15))
                                }
                            }
                        }
                    }

                    // 最下部への自動スクロール用のアンカー.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, AppConstants.Layout.standardSpacing)
                .padding(.vertical, AppConstants.Layout.standardSpacing)
            }
            .background(Palette.chatBackground)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                Task { await store.markRead(conversation.id) }
            }
            .task {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MessageComposerView(conversationID: conversation.id, replyingTo: $replyingTo)
        }
        .safeAreaInset(edge: .top) {
            if let error = store.banner {
                ErrorBannerView(error: error) { store.setBanner(nil) }
            }
        }
        .navigationTitle(store.title(for: conversation))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ヘッダはアバター付きの独自表示にする. 相手が誰か一目で分かるように.
            ToolbarItem(placement: .principal) {
                header
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingInfo = true
                } label: {
                    Label(String(localized: "詳細"), systemImage: "info.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingInfo) {
            ConversationInfoView(conversation: conversation)
        }
        .fullScreenCover(item: $viewingMedia) { attachment in
            MediaViewerScreen(attachment: attachment, conversationID: conversation.id)
        }
        .task(id: conversation.id) {
            await store.markRead(conversation.id)
            // 通知の許可は起動直後ではなく, 実際に会話を始めた時点で求める.
            // 何のための通知かが伝わっている状態のほうが許可されやすい.
            await environment.pushService.requestAuthorizationAndRegister()
        }
    }

    // MARK: - 動作

    /// 引用から元メッセージへ移動する.
    ///
    /// 元が読み込み済みの範囲に無い場合(古い履歴)は, 黙って何も起きないと
    /// 壊れて見えるので, 読み込みを促す案内を出す.
    private func scrollToOriginal(_ messageID: MessageID, using proxy: ScrollViewProxy) {
        guard messages.contains(where: { $0.id == messageID }) else {
            store.setBanner(.underlying(String(localized: "返信元のメッセージはまだ読み込まれていません。「以前のメッセージを読み込む」で遡ってください")))
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(messageID, anchor: .center)
            highlightedMessageID = messageID
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { highlightedMessageID = nil }
        }
    }

    // MARK: - 部品

    private var header: some View {
        HStack(spacing: AppConstants.Layout.compactSpacing) {
            if let counterpart = store.counterpartProfile(for: conversation) {
                AvatarView(profile: counterpart, size: 28)
            } else {
                AvatarView(
                    imageData: conversation.imageData,
                    fallbackText: String(store.title(for: conversation).prefix(1)),
                    seed: conversation.id.rawValue,
                    size: 28
                )
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(store.title(for: conversation))
                    .font(.headline)
                if conversation.kind == .group {
                    Text("\(conversation.participantIDs.count) 人")
                        .font(.caption2)
                        .foregroundStyle(Palette.subdued)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var loadOlderButton: some View {
        Button {
            Task {
                isLoadingOlder = true
                await store.loadOlderMessages(in: conversation.id)
                isLoadingOlder = false
            }
        } label: {
            if isLoadingOlder {
                ProgressView()
            } else {
                Text("以前のメッセージを読み込む")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppConstants.Layout.compactSpacing)
    }

    private func daySeparator(_ date: Date) -> some View {
        Text(DateDisplay.daySeparator(date))
            .font(.caption)
            .foregroundStyle(Palette.subdued)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Palette.incomingBubble, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppConstants.Layout.compactSpacing)
    }

    // MARK: - 行の組み立て

    private static let bottomAnchor = "bottom-anchor"

    /// 日付区切りと「連続発言かどうか」を前計算する.
    /// View の body で毎回条件分岐を書くより, データにしてしまうほうが読みやすい.
    private var rows: [ChatRow] {
        var result: [ChatRow] = []
        var previous: Message?
        let calendar = Calendar.current

        for message in messages {
            if previous == nil || !calendar.isDate(message.createdAt, inSameDayAs: previous?.createdAt ?? .distantPast) {
                result.append(ChatRow(id: "day-\(message.id.rawValue)", kind: .daySeparator(message.createdAt)))
            }
            let grouped: Bool
            if let previous,
               previous.senderID == message.senderID,
               calendar.isDate(previous.createdAt, inSameDayAs: message.createdAt),
               message.createdAt.timeIntervalSince(previous.createdAt) < Self.groupingWindow {
                grouped = true
            } else {
                grouped = false
            }
            result.append(ChatRow(id: message.id.rawValue, kind: .message(message, grouped: grouped)))
            previous = message
        }
        return result
    }

    /// この時間内に続く同じ人の発言は 1 つのまとまりとして表示する.
    private static let groupingWindow: TimeInterval = 120
}

/// 一覧に流す行.
private struct ChatRow: Identifiable {
    enum Kind {
        case daySeparator(Date)
        case message(Message, grouped: Bool)
    }
    let id: String
    let kind: Kind
}
