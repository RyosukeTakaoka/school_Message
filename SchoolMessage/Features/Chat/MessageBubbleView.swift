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
    /// 時刻と既読を出すか.
    ///
    /// 同じ分に続けて送られたメッセージでは, まとまりの末尾だけ `true` になる.
    /// 3 通送るたびに時刻が 3 つ並ぶのを避けるため.
    var showsTimestamp: Bool = true
    var onTapMedia: (MediaAttachment) -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void
    /// 「返信」を選んだ. 入力欄に引用を出すのは呼び出し側の担当.
    var onReply: () -> Void = {}
    /// 引用をタップした. 元メッセージまでスクロールする.
    var onTapQuote: (MessageID) -> Void = { _ in }
    /// 「送信を取り消す」を選んだ. 確認は呼び出し側で取る.
    var onUnsend: () -> Void = {}
    /// 対戦のカードをタップした.
    var onOpenGame: (GameSnapshot.Kind) -> Void = { _ in }

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

                quotedOriginal

                bubble
                    .contextMenu { replyMenu }

                reactionsRow

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

    /// 返信の引用. 元メッセージの送信者と抜粋を吹き出しの上に出す.
    @ViewBuilder
    private var quotedOriginal: some View {
        if let reply = message.replyTo {
            Button {
                onTapQuote(reply.messageID)
            } label: {
                HStack(spacing: 6) {
                    // 引用であることを縦棒で示す. 色だけに頼らない表現にする.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.displayName(for: reply.senderID))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.subdued)
                        Text(reply.preview)
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: 380, alignment: .leading)
                .background(Palette.incomingBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "返信元のメッセージへ移動します"))
        }
    }

    /// 吹き出しの長押しメニュー.
    ///
    /// 送信待ちのメッセージにも返信できる. 引用は本文の写しを自分で持つので,
    /// 元が送信中でも表示は崩れず, 送信キューは投入順に送るため順序も保たれる.
    @ViewBuilder
    private var replyMenu: some View {
        // 取り消し済みには何も操作させない.
        if !message.isUnsent {
            // `ControlGroup` を使うと, メニューの先頭に横並びのボタン列として出る
            // (Notes 等のリアクションバーと同じ考え方). タップ 1 回で選べる.
            ControlGroup {
                ForEach(Self.quickReactionEmojis, id: \.self) { emoji in
                    Button {
                        Task { await store.toggleReaction(emoji, on: message) }
                    } label: {
                        Text(emoji)
                    }
                }
            }

            // 対戦のカードには返信・コピー・取り消しはさせない(リアクションのみ).
            if message.content.game == nil {
                Button {
                    onReply()
                } label: {
                    Label(String(localized: "返信"), systemImage: "arrowshape.turn.up.left")
                }
                if case .text(let body) = message.content {
                    Button {
                        UIPasteboard.general.string = body
                    } label: {
                        Label(String(localized: "コピー"), systemImage: "doc.on.doc")
                    }
                }
                if message.canUnsend(by: store.currentUserID) {
                    Button(role: .destructive) {
                        onUnsend()
                    } label: {
                        Label(String(localized: "送信を取り消す"), systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
    }

    /// 長押しメニューに出す, よく使う絵文字の候補.
    private static let quickReactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// 吹き出しの下に出す, 付いているリアクションの一覧.
    ///
    /// 同じ絵文字ごとにまとめ, 人数が 2 人以上なら数を添える.
    /// 自分が付けたものは縁取りで示し, タップすると外れる.
    @ViewBuilder
    private var reactionsRow: some View {
        let reactions = store.reactionsByConversation[message.conversationID]?[message.id] ?? []
        if !message.isUnsent, !reactions.isEmpty {
            let grouped = Dictionary(grouping: reactions, by: \.emoji)
            HStack(spacing: 4) {
                ForEach(grouped.keys.sorted(), id: \.self) { emoji in
                    let matches = grouped[emoji] ?? []
                    let isMine = matches.contains { $0.userID == store.currentUserID }
                    Button {
                        Task { await store.toggleReaction(emoji, on: message) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(emoji).font(.footnote)
                            if matches.count > 1 {
                                Text("\(matches.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isMine ? Color.accentColor : Palette.subdued)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            isMine ? Color.accentColor.opacity(0.15) : Palette.incomingBubble,
                            in: Capsule()
                        )
                        .overlay {
                            if isMine {
                                Capsule().strokeBorder(Color.accentColor, lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isMine
                        ? String(localized: "\(emoji) 自分を含む\(matches.count)人。タップで取り消す")
                        : String(localized: "\(emoji) \(matches.count)人")
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.isUnsent {
            unsentBubble
        } else {
            contentBubble
        }
    }

    /// 取り消し済みの吹き出し.
    ///
    /// 枠線だけの控えめな見た目にして, 中身のあるメッセージと明確に区別する.
    /// 位置と時刻はそのまま残るので, 会話の流れが分からなくならない.
    private var unsentBubble: some View {
        Text("送信を取り消しました")
            .font(.footnote)
            .italic()
            .foregroundStyle(Palette.subdued)
            .padding(.horizontal, AppConstants.Layout.bubbleHorizontalPadding)
            .padding(.vertical, AppConstants.Layout.bubbleVerticalPadding)
            .overlay {
                RoundedRectangle(cornerRadius: AppConstants.Layout.bubbleCornerRadius, style: .continuous)
                    .strokeBorder(Palette.subdued.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
    }

    @ViewBuilder
    private var contentBubble: some View {
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

        case .game(let snapshot):
            gameBubble(snapshot)
        }
    }

    /// 対戦の状況を出すカード. タップで対戦の画面を開く.
    private func gameBubble(_ snapshot: GameSnapshot) -> some View {
        Button {
            onOpenGame(snapshot.kind)
        } label: {
            HStack(spacing: AppConstants.Layout.standardSpacing) {
                Image(systemName: snapshot.kind.symbolName)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(gameStatusText(snapshot))
                        .font(.caption)
                        .foregroundStyle(Palette.subdued)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
            }
            .padding(AppConstants.Layout.standardSpacing)
            .frame(maxWidth: 300, alignment: .leading)
            .background(
                Palette.incomingBubble,
                in: RoundedRectangle(cornerRadius: AppConstants.Layout.bubbleCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func gameStatusText(_ snapshot: GameSnapshot) -> String {
        switch snapshot {
        case .othello(let state): othelloStatusText(state)
        case .colorBattle(let state): colorBattleStatusText(state)
        case .daifugo(let state): daifugoStatusText(state)
        }
    }

    private func othelloStatusText(_ state: OthelloSnapshot) -> String {
        guard let board = state.othelloBoard else { return String(localized: "対戦中") }
        let score = String(localized: "黒 \(board.count(of: .black)) - 白 \(board.count(of: .white))")
        if state.isFinished {
            return String(localized: "対戦終了 · \(score)")
        }
        if let me = store.currentUserID, state.isTurn(of: me) {
            return String(localized: "あなたの番 · \(score)")
        }
        return String(localized: "相手の番 · \(score)")
    }

    private func colorBattleStatusText(_ state: ColorBattleSnapshot) -> String {
        guard let me = store.currentUserID,
              let opponent = state.opponentID(of: me) else {
            return state.isFinished ? String(localized: "対戦終了") : String(localized: "対戦中")
        }
        let score = String(localized: "あなた \(state.score(for: me)) - 相手 \(state.score(for: opponent))")
        if state.isFinished {
            return String(localized: "対戦終了 · \(score)")
        }
        if state.isTurn(of: me) {
            return String(localized: "あなたの番 · \(score)")
        }
        return String(localized: "相手の番 · \(score)")
    }

    private func daifugoStatusText(_ state: DaifugoSnapshot) -> String {
        switch state.phase {
        case .lobby(let lobby):
            return String(localized: "参加者募集中 · \(lobby.joinedPlayerIDs.count)人")
        case .round(let round):
            if round.isFinished {
                return String(localized: "対戦終了")
            }
            if let me = store.currentUserID, round.isTurn(of: me) {
                return String(localized: "あなたの番")
            }
            return String(localized: "\(store.displayName(for: round.currentPlayerID)) の番")
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
            if showsTimestamp {
                HStack(spacing: 4) {
                    if let readLabel {
                        Text(readLabel)
                            .font(.caption2)
                            .foregroundStyle(Palette.subdued)
                    }
                    Text(DateDisplay.messageTimestamp(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(Palette.subdued)
                }
                .padding(.horizontal, 4)
            }

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

    /// 自分が送ったメッセージにだけ付ける「既読」表示.
    ///
    /// 相手がまだ読んでいない間は何も出さない. 「未読」と明示すると
    /// 未読であること自体を責めるような圧力になりやすいため, 付いたときだけ出す.
    private var readLabel: String? {
        // 取り消し済みに既読を出しても意味がない.
        guard !message.isUnsent else { return nil }
        guard isOutgoing, let me = store.currentUserID else { return nil }
        let count = conversation.readCount(upTo: message.createdAt, excluding: me)
        guard count > 0 else { return nil }
        // グループでは何人が読んだかまで出す.
        return conversation.kind == .group
            ? String(localized: "既読 \(count)")
            : String(localized: "既読")
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(isOutgoing ? String(localized: "自分") : store.displayName(for: message.senderID))
        if let reply = message.replyTo {
            parts.append(String(localized: "\(store.displayName(for: reply.senderID))さんへの返信"))
        }
        parts.append(message.isUnsent
                     ? String(localized: "送信を取り消しました")
                     : message.content.previewText)
        parts.append(DateDisplay.accessibilityTimestamp(message.createdAt))
        switch message.deliveryState {
        case .sending: parts.append(String(localized: "送信中"))
        case .failed: parts.append(String(localized: "送信に失敗しました"))
        case .sent:
            if let readLabel { parts.append(readLabel) }
        }
        return parts.joined(separator: "、")
    }
}
