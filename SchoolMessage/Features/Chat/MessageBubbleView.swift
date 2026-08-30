import SwiftUI

/// メッセージ 1 件の吹き出し.
///
/// 自分と相手の区別は「左右の位置」「背景色」「角の形」の 3 つで表す.
/// 色だけに頼らないのは, 色覚特性やダークモードでの見え方に依存させないため.
struct MessageBubbleView: View {

    @Environment(AppEnvironment.self) private var environment

    let message: Message
    let conversation: Conversation
    /// 直前のメッセージと同じ送信者か(名前とアバターの重複表示を避ける).
    let isGroupedWithPrevious: Bool
    var onTapMedia: (MediaAttachment) -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void

    private var store: ChatStore { environment.store }
    private var isOutgoing: Bool { message.senderID == store.currentUserID }

    var body: some View {
        HStack(alignment: .bottom, spacing: AppConstants.Layout.compactSpacing) {
            if isOutgoing { Spacer(minLength: 40) }

            if !isOutgoing {
                avatarSlot
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsSenderName {
                    Text(store.displayName(for: message.senderID))
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                        .padding(.leading, 4)
                }

                bubble

                footer
            }

            if !isOutgoing { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - 部品

    /// グループでは相手のアバターを出す. 連続発言では位置合わせ用の余白だけ残す.
    @ViewBuilder
    private var avatarSlot: some View {
        if conversation.kind == .group, !isGroupedWithPrevious,
           let profile = store.profilesByID[message.senderID] {
            AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
        } else if conversation.kind == .group {
            Color.clear.frame(width: AppConstants.Layout.avatarSmall, height: 1)
        }
    }

    private var showsSenderName: Bool {
        conversation.kind == .group && !isOutgoing && !isGroupedWithPrevious
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.content {
        case .text(let body):
            Text(body)
                .font(.body)
                .foregroundStyle(isOutgoing ? Palette.outgoingText : Palette.incomingText)
                .textSelection(.enabled)
                .padding(.horizontal, AppConstants.Layout.bubbleHorizontalPadding)
                .padding(.vertical, AppConstants.Layout.bubbleVerticalPadding)
                .background(
                    isOutgoing ? Palette.outgoingBubble : Palette.incomingBubble,
                    in: BubbleShape(isOutgoing: isOutgoing, isGroupedWithPrevious: isGroupedWithPrevious)
                )
                .frame(maxWidth: 460, alignment: isOutgoing ? .trailing : .leading)

        case .image(let attachment):
            mediaBubble(attachment, showsPlayBadge: false)

        case .video(let attachment):
            mediaBubble(attachment, showsPlayBadge: true)
        }
    }

    private func mediaBubble(_ attachment: MediaAttachment, showsPlayBadge: Bool) -> some View {
        Button {
            onTapMedia(attachment)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                thumbnail(attachment)
                if showsPlayBadge {
                    playOverlay(attachment)
                }
            }
            .frame(
                width: mediaSize(attachment).width,
                height: mediaSize(attachment).height
            )
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.Layout.bubbleCornerRadius, style: .continuous))
            .overlay {
                if message.deliveryState.isPending {
                    // アップロード中は薄く覆って進行中であることを示す.
                    RoundedRectangle(cornerRadius: AppConstants.Layout.bubbleCornerRadius, style: .continuous)
                        .fill(.black.opacity(0.25))
                        .overlay { ProgressView().tint(.white) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ attachment: MediaAttachment) -> some View {
        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let localURL = attachment.localURL,
                  attachment.kind == .image,
                  let image = UIImage(contentsOfFile: localURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Palette.incomingBubble)
                .overlay {
                    Image(systemName: attachment.kind == .image ? "photo" : "video")
                        .font(.largeTitle)
                        .foregroundStyle(Palette.subdued)
                }
        }
    }

    private func playOverlay(_ attachment: MediaAttachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
            if let duration = attachment.formattedDuration {
                Text(duration).monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
    }

    /// 吹き出し内のメディアの表示サイズ. 元の縦横比を保ったまま上限に収める.
    private func mediaSize(_ attachment: MediaAttachment) -> CGSize {
        let maxEdge = AppConstants.Layout.mediaBubbleMaxEdge
        let ratio = attachment.aspectRatio
        if ratio >= 1 {
            return CGSize(width: maxEdge, height: maxEdge / ratio)
        }
        return CGSize(width: maxEdge * ratio, height: maxEdge)
    }

    /// 時刻と送信状態.
    @ViewBuilder
    private var footer: some View {
        switch message.deliveryState {
        case .sent:
            Text(DateDisplay.messageTimestamp(message.createdAt))
                .font(.caption2)
                .foregroundStyle(Palette.subdued)
                .padding(.horizontal, 4)

        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("送信中…")
            }
            .font(.caption2)
            .foregroundStyle(Palette.subdued)
            .padding(.horizontal, 4)

        case .failed(let reason):
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(Palette.failure)
                HStack(spacing: AppConstants.Layout.standardSpacing) {
                    Button(String(localized: "再送信"), action: onRetry)
                    Button(String(localized: "取り消す"), role: .destructive, action: onCancel)
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(isOutgoing ? String(localized: "自分") : store.displayName(for: message.senderID))
        parts.append(message.content.previewText)
        parts.append(DateDisplay.accessibilityTimestamp(message.createdAt))
        switch message.deliveryState {
        case .sending: parts.append(String(localized: "送信中"))
        case .failed: parts.append(String(localized: "送信に失敗しました"))
        case .sent: break
        }
        return parts.joined(separator: "、")
    }
}
