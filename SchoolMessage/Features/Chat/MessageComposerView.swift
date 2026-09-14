import SwiftUI
import PhotosUI
import AVFoundation
import CoreMedia

/// メッセージ入力欄.
///
/// 「写真選択 → プレビュー → 送信」の流れをここで完結させる.
/// 送信ボタンを押した時点で吹き出しが出て, アップロードは裏で進む.
struct MessageComposerView: View {

    @Environment(AppEnvironment.self) private var environment
    let conversationID: ConversationID
    /// 返信先. 設定されている間は入力欄の上に引用を出す.
    @Binding var replyingTo: Message?

    @State private var text: String = ""
    @State private var draft: Draft?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPreparingAttachment = false
    @State private var isShowingCamera = false
    @State private var isShowingGifPicker = false
    @State private var composerHeight: CGFloat = AppConstants.Layout.composerMinHeight

    /// 「@」で選べる状態のときの検索文字列. nil のときはメンション選択中ではない.
    @State private var mentionQuery: String?
    /// これまでに選んだメンション(本文中の「@表示名」と対応させる).
    @State private var mentions: [ComposerMention] = []
    /// 候補をタップしたときに `ComposerTextView` へ渡す, 挿入の指示.
    @State private var mentionInsertion: PendingMentionInsertion?
    /// 入力欄の `UITextView` を自前で first responder にしているため,
    /// `@FocusState` は使わない. `@FocusState` は `.focused()` で紐付けた
    /// SwiftUI標準の入力欄と同期する仕組みで, ここでは何にも紐付いていない
    /// (`ComposerTextView` へ手渡すだけの) 状態にまで使うと, SwiftUI が
    /// 「どの入力欄にも紐付いていない」と判断して勝手に `false` へ戻してしまう
    /// ことがあり, その結果 `ComposerTextView` 側が `resignFirstResponder()`
    /// を呼んでキーボードが閉じてしまっていた
    /// (iPad のソフトウェアキーボードで 1 文字打つと閉じる不具合の原因).
    @State private var isInputFocused = false

    /// 送信前の添付.
    private enum Draft: Equatable {
        case image(Data)
        case video(URL, thumbnail: Data?)
    }

    private var store: ChatStore { environment.store }

    private var canSend: Bool {
        guard !isPreparingAttachment else { return false }
        return draft != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// メンションはグループでのみ意味があるので, 1 対 1 では機能ごと出さない.
    private var isGroupConversation: Bool {
        store.conversation(conversationID)?.kind == .group
    }

    /// 「@」の検索文字列に合う参加者(自分は除く).
    private var mentionCandidates: [UserProfile] {
        guard let query = mentionQuery,
              let conversation = store.conversation(conversationID),
              conversation.kind == .group else { return [] }
        let others = store.members(of: conversation).filter { $0.id != store.currentUserID }
        guard !query.isEmpty else {
            return others.sorted { $0.displayName < $1.displayName }
        }
        let lowered = query.lowercased()
        return others
            .filter { $0.displayName.lowercased().contains(lowered) || $0.handle.lowercased().contains(lowered) }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                replyPreview(replyingTo)
                Divider()
            }
            if let draft {
                attachmentPreview(draft)
                Divider()
            }
            mentionPicker
            inputRow
        }
        .background(Palette.composerBackground)
        .onChange(of: replyingTo?.id) { _, newValue in
            // 返信を選んだらすぐ書き始められるようにキーボードを出す.
            guard newValue != nil else { return }
            isInputFocused = true
        }
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPickedItem(newValue) }
        }
        .onChange(of: text) { _, newValue in
            pruneMentions(in: newValue)
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { capture in
                isShowingCamera = false
                switch capture {
                case .photo(let data):
                    draft = .image(data)
                case .video(let url):
                    Task { await prepareVideoDraft(url) }
                }
            } onCancel: {
                isShowingCamera = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingGifPicker) {
            GifPickerView { data in
                await sendGif(data)
            }
        }
    }

    // MARK: - プレビュー

    /// 返信先の引用. 誰の何に返信しているのかを送信前に確認できるようにする.
    private func replyPreview(_ original: Message) -> some View {
        HStack(spacing: AppConstants.Layout.compactSpacing) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.displayName(for: original.senderID))さんに返信")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(original.content.previewText)
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.subdued)
            }
            .accessibilityLabel(String(localized: "返信をやめる"))
        }
        .padding(.horizontal, AppConstants.Layout.standardSpacing)
        .padding(.vertical, AppConstants.Layout.compactSpacing)
    }

    /// 「@」を打つと出る, メンションする相手の候補一覧.
    @ViewBuilder
    private var mentionPicker: some View {
        if mentionQuery != nil {
            let candidates = mentionCandidates
            if candidates.isEmpty {
                Text("該当する人がいません")
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
                    .padding(.horizontal, AppConstants.Layout.standardSpacing)
                    .padding(.vertical, AppConstants.Layout.compactSpacing)
                Divider()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { profile in
                            Button {
                                mentionInsertion = PendingMentionInsertion(displayName: profile.displayName, userID: profile.id)
                            } label: {
                                HStack(spacing: AppConstants.Layout.compactSpacing) {
                                    AvatarView(profile: profile, size: AppConstants.Layout.avatarSmall)
                                    Text(profile.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, AppConstants.Layout.standardSpacing)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
                Divider()
            }
        }
    }

    /// 本文から消えた(編集で壊れた)メンションを取り除く.
    ///
    /// 範囲を追いかける代わりに, 「@表示名」が本文中に何回出てくるか」を
    /// 数え直し, 選んだ回数より減っていれば減った分だけ捨てる.
    /// 同じ表示名の相手を 2 人メンションしていて片方だけ消した, という
    /// まれなケースでも, どちらか一方を正しく捨てられる.
    private func pruneMentions(in text: String) {
        guard !mentions.isEmpty else { return }
        let grouped = Dictionary(grouping: mentions, by: \.displayName)
        var keptIDs: Set<UUID> = []
        for (displayName, group) in grouped {
            let needle = "@\(displayName)"
            let occurrences = text.components(separatedBy: needle).count - 1
            for mention in group.prefix(occurrences) {
                keptIDs.insert(mention.id)
            }
        }
        mentions.removeAll { !keptIDs.contains($0.id) }
    }

    @ViewBuilder
    private func attachmentPreview(_ draft: Draft) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            ZStack(alignment: .topTrailing) {
                previewThumbnail(draft)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    clearDraft()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(4)
                .accessibilityLabel(String(localized: "添付を取り消す"))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(draftLabel(draft))
                    .font(.subheadline.weight(.medium))
                Text("送信ボタンで送ります")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }
            Spacer()
        }
        .padding(AppConstants.Layout.standardSpacing)
    }

    @ViewBuilder
    private func previewThumbnail(_ draft: Draft) -> some View {
        switch draft {
        case .image(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        case .video(_, let thumbnail):
            ZStack {
                if let thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.7)
                }
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
    }

    private func draftLabel(_ draft: Draft) -> String {
        switch draft {
        case .image: String(localized: "写真")
        case .video: String(localized: "動画")
        }
    }

    // MARK: - 入力行

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: AppConstants.Layout.compactSpacing) {
            PhotosPicker(
                selection: $pickerItem,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
            }
            .accessibilityLabel(String(localized: "写真・動画を選ぶ"))

            if CameraPicker.isAvailable {
                Button {
                    isShowingCamera = true
                } label: {
                    Image(systemName: "camera")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "撮影する"))
            }

            Button {
                isShowingGifPicker = true
            } label: {
                Text("GIF")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(String(localized: "GIFを選ぶ"))

            // 標準の `TextField` + `.onSubmit` ではなく `UITextView` を
            // 直接使っているのは, 日本語入力の変換確定にも使う外付けキーボードの
            // Return を, 変換中かどうかを見て正しく扱うため
            // (`ComposerTextView` のコメント参照).
            ComposerTextView(
                text: $text,
                placeholder: String(localized: "メッセージを入力"),
                isFocused: $isInputFocused,
                height: $composerHeight,
                minHeight: AppConstants.Layout.composerMinHeight,
                maxHeight: AppConstants.Layout.composerMaxHeight,
                mentionsEnabled: isGroupConversation,
                mentionQuery: $mentionQuery,
                mentions: $mentions,
                mentionInsertion: $mentionInsertion,
                onSubmit: send
            )
            .frame(height: composerHeight)
            .background(Palette.chatBackground, in: Capsule())

            if isPreparingAttachment {
                ProgressView()
                    .frame(width: 36, height: 36)
                    .accessibilityLabel(String(localized: "準備中"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(!canSend)
                .accessibilityLabel(String(localized: "送信"))
            }
        }
        .padding(.horizontal, AppConstants.Layout.standardSpacing)
        .padding(.vertical, AppConstants.Layout.compactSpacing)
    }

    // MARK: - 動作

    /// GIF ピッカーで選んだものは, 下書きを経由せずその場で送る
    /// (スタンプに近い操作感にするため. `send()` とは別経路).
    private func sendGif(_ data: Data) async {
        let reply = replyingTo.map { ReplyReference(replyingTo: $0) }
        replyingTo = nil
        await store.sendGif(originalData: data, in: conversationID, replyTo: reply)
    }

    private func send() {
        guard canSend else { return }
        let body = text
        let attachment = draft
        let reply = replyingTo.map { ReplyReference(replyingTo: $0) }
        let mentionedIDs = Array(Set(mentions.map(\.userID)))

        // 先に入力欄を空にする. 送信完了を待つと連続入力の妨げになる.
        text = ""
        draft = nil
        pickerItem = nil
        replyingTo = nil
        mentions = []
        mentionQuery = nil

        Task {
            if let attachment {
                switch attachment {
                case .image(let data):
                    await store.sendImage(originalData: data, in: conversationID, replyTo: reply)
                case .video(let url, _):
                    await store.sendVideo(sourceURL: url, in: conversationID, replyTo: reply)
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // 添付と本文の両方があるときは, 引用は先に出る添付だけに付ける.
                await store.sendText(
                    trimmed,
                    in: conversationID,
                    replyTo: attachment == nil ? reply : nil,
                    mentions: mentionedIDs
                )
            }
        }
    }

    private func clearDraft() {
        if case .video(let url, _) = draft {
            try? FileManager.default.removeItem(at: url)
        }
        draft = nil
        pickerItem = nil
    }

    private func loadPickedItem(_ item: PhotosPickerItem) async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }

        // まず動画として読めるか試し, だめなら画像として読む.
        if let video = try? await item.loadTransferable(type: PickedVideo.self) {
            await prepareVideoDraft(video.url)
            return
        }
        if let data = try? await item.loadTransferable(type: Data.self) {
            draft = .image(data)
            return
        }
        store.setBanner(.unsupportedMedia)
    }

    /// 動画のサムネイルだけ先に作ってプレビューに出す.
    /// 再エンコードは送信時にまとめて行う(選ぶたびに待たせない).
    private func prepareVideoDraft(_ url: URL) async {
        let thumbnail = await VideoThumbnail.make(from: url)
        draft = .video(url, thumbnail: thumbnail)
    }
}

/// プレビュー用のサムネイル生成.
enum VideoThumbnail {
    static func make(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: MediaLimits.thumbnailMaxPixelEdge,
            height: MediaLimits.thumbnailMaxPixelEdge
        )
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
            .jpegData(compressionQuality: MediaLimits.thumbnailCompressionQuality)
    }
}

/// 入力欄本体. `TextField` の `.onSubmit` ではなく `UITextView` を直接使う.
///
/// ## なぜ標準の `TextField` を使わないか
/// 外付けキーボードの Return で送信できるようにしているが, 日本語入力では
/// 変換候補を確定するのにも Return を使う. `TextField` + `.onSubmit` は
/// この 2 つを区別できず, **変換確定のつもりで押した Return が送信として
/// 扱われ, まだ確定していなかった文字列が消える**ことがあった
/// (`.onSubmit` が呼ばれた時点でまだ `text` に反映されておらず,
/// 送信処理が入力欄を空にしてしまうため).
///
/// `UITextView` は `markedTextRange` で「変換中の未確定文字列があるか」を
/// 取得できる. これを見て, 変換中の Return は確定だけに使わせ(送信しない),
/// 確定し終えたあとの Return だけを送信として扱うようにする.

/// 選んだメンション 1 件.「@表示名」という文字列と紐付いた相手.
struct ComposerMention: Identifiable, Equatable {
    let id = UUID()
    let userID: UserID
    let displayName: String
}

/// 候補をタップした瞬間に, どの相手を挿入するかを `ComposerTextView` へ伝える指示.
/// SwiftUI 側からは書き込むだけで, 挿入し終えたら `ComposerTextView` 側が nil に戻す.
struct PendingMentionInsertion: Equatable {
    let displayName: String
    let userID: UserID
}

struct ComposerTextView: UIViewRepresentable {

    @Binding var text: String
    let placeholder: String
    var isFocused: Binding<Bool>
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// グループでだけ true. false のときは「@」を打っても候補を出さない.
    var mentionsEnabled: Bool = false
    var mentionQuery: Binding<String?> = .constant(nil)
    var mentions: Binding<[ComposerMention]> = .constant([])
    var mentionInsertion: Binding<PendingMentionInsertion?> = .constant(nil)
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(
            top: 8, left: AppConstants.Layout.standardSpacing,
            bottom: 8, right: AppConstants.Layout.standardSpacing
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.text = text

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isHidden = !text.isEmpty
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor, constant: textView.textContainerInset.top
            ),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor, constant: textView.textContainerInset.left
            )
        ])
        context.coordinator.placeholderLabel = placeholderLabel

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // `Coordinator` は使い回されるが, この構造体自体は描画のたびに
        // 新しく作られる. コールバックが最新の(クロージャなど)値を見られるよう,
        // 都度差し替える.
        context.coordinator.parent = self

        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty

        if isFocused.wrappedValue, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused.wrappedValue, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        if let insertion = mentionInsertion.wrappedValue {
            context.coordinator.insertMention(insertion, into: uiView)
            // 挿入は UIKit 側の状態(テキスト・カーソル)を書き換える操作なので,
            // ここで直接やってよい. 指示を消す(SwiftUI 側の @State を書き換える)
            // 方は, body の再評価中に状態を書き換える形になるのを避けるため
            // 次の runloop に回す(`recalculateHeight` の `height` と同じやり方).
            DispatchQueue.main.async { mentionInsertion.wrappedValue = nil }
        }

        recalculateHeight(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// 1〜5 行ぶんの高さの範囲で伸び縮みさせる. それを超えたら中で
    /// スクロールする(それ以上ふくらませない).
    private func recalculateHeight(_ textView: UITextView) {
        let fitting = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        )
        let clamped = min(max(fitting.height, minHeight), maxHeight)
        textView.isScrollEnabled = fitting.height > maxHeight
        guard abs(height - clamped) > 0.5 else { return }
        DispatchQueue.main.async { height = clamped }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        weak var placeholderLabel: UILabel?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        /// Return が押された瞬間はここに来る. 変換中(未確定の文字列がある)
        /// なら, ここでは何もせず true を返して, システムに変換確定を
        /// 任せる. 確定済みの状態で押された Return だけを送信として扱う.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n" else { return true }
            guard textView.markedTextRange == nil else { return true }
            parent.onSubmit()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            syncFromTextView(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // カーソルを動かしただけでも(打ち込んでいなくても), 「@のすぐ後ろ」に
            // 戻ってきたかどうかで候補の表示・非表示を更新する.
            updateMentionQuery(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = false
        }

        private func syncFromTextView(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.recalculateHeight(textView)
            updateMentionQuery(textView)
        }

        // MARK: - メンション

        /// カーソルの直前が「@検索中の文字列」になっているかを調べ, 候補欄の
        /// 開閉と検索文字列を更新する.
        private func updateMentionQuery(_ textView: UITextView) {
            guard parent.mentionsEnabled,
                  let range = ComposerTextView.openMentionRange(
                    in: textView.text, cursor: textView.selectedRange.location
                  ) else {
                parent.mentionQuery.wrappedValue = nil
                return
            }
            let ns = textView.text as NSString
            parent.mentionQuery.wrappedValue = ns.substring(
                with: NSRange(location: range.location + 1, length: range.length - 1)
            )
        }

        /// 候補をタップしたときに呼ばれる. 開いている「@検索文字列」を
        /// 「@表示名 」に置き換え, 選んだ相手を記録する.
        func insertMention(_ insertion: PendingMentionInsertion, into textView: UITextView) {
            guard let triggerRange = ComposerTextView.openMentionRange(
                in: textView.text, cursor: textView.selectedRange.location
            ) else { return }

            let ns = textView.text as NSString
            let inserted = "@\(insertion.displayName) "
            textView.text = ns.replacingCharacters(in: triggerRange, with: inserted)
            let newCursor = triggerRange.location + (inserted as NSString).length
            textView.selectedRange = NSRange(location: newCursor, length: 0)

            parent.mentions.wrappedValue.append(
                ComposerMention(userID: insertion.userID, displayName: insertion.displayName)
            )
            syncFromTextView(textView)
        }
    }

    /// カーソルの直前にある, まだ確定していない「@検索文字列」の範囲を探す.
    ///
    /// - 「@」からカーソルまでの間に空白・改行があれば, もう検索中ではない(nil).
    /// - 「@」の直前が文頭か空白・改行でなければ, メールアドレスの一部などと
    ///   見なしてメンションの対象にしない(nil).
    private static func openMentionRange(in text: String, cursor: Int) -> NSRange? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        var index = cursor - 1
        while index >= 0 {
            let unit = ns.character(at: index)
            guard let scalar = Unicode.Scalar(unit) else { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
            if scalar == "@" {
                if index == 0 { return NSRange(location: index, length: cursor - index) }
                let previousUnit = ns.character(at: index - 1)
                if let previousScalar = Unicode.Scalar(previousUnit),
                   CharacterSet.whitespacesAndNewlines.contains(previousScalar) {
                    return NSRange(location: index, length: cursor - index)
                }
                return nil
            }
            index -= 1
        }
        return nil
    }
}
