import SwiftUI
import PhotosUI

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
    @State private var draftImageData: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var isSending = false
    @State private var isPreparingAttachment = false
    @State private var viewingImage: BoardImageAttachment?
    @FocusState private var isInputFocused: Bool

    private var store: ChatStore { environment.store }

    private var canSend: Bool {
        guard !isSending, !isPreparingAttachment else { return false }
        return draftImageData != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .task { await loadAndPoll() }
        .safeAreaInset(edge: .top) {
            if let error = store.banner {
                ErrorBannerView(error: error) { store.setBanner(nil) }
            }
        }
        .fullScreenCover(item: $viewingImage) { image in
            BoardImageViewerScreen(image: image)
        }
    }

    // MARK: - 部品

    private func postRow(_ post: BoardPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if let image = post.image {
                postImage(image)
            }
            if !post.body.isEmpty {
                Text(post.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, AppConstants.Layout.compactSpacing)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    /// 書き込みに添付された写真. サムネイルは書き込みと一緒に届くので即座に出せる.
    private func postImage(_ image: BoardImageAttachment) -> some View {
        let maxEdge = AppConstants.Layout.mediaBubbleMaxEdge
        let size: CGSize = image.aspectRatio >= 1
            ? CGSize(width: maxEdge, height: maxEdge / image.aspectRatio)
            : CGSize(width: maxEdge * image.aspectRatio, height: maxEdge)

        return Button {
            viewingImage = image
        } label: {
            Group {
                if let data = image.thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else if let localURL = image.localURL, let uiImage = UIImage(contentsOfFile: localURL.path) {
                    Image(uiImage: uiImage).resizable().scaledToFill()
                } else {
                    Rectangle()
                        .fill(Palette.incomingBubble)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(Palette.subdued)
                        }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.Layout.bubbleCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "添付された写真"))
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if let draftImageData, let uiImage = UIImage(data: draftImageData) {
            HStack {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button {
                        self.draftImageData = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .padding(4)
                    .accessibilityLabel(String(localized: "写真を取り消す"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppConstants.Layout.standardSpacing)
            .padding(.top, AppConstants.Layout.compactSpacing)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            attachmentPreview

            HStack(alignment: .bottom, spacing: AppConstants.Layout.compactSpacing) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                }
                .accessibilityLabel(String(localized: "写真を選ぶ"))

                TextField(String(localized: "書き込む"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, AppConstants.Layout.standardSpacing)
                    .padding(.vertical, 8)
                    .frame(minHeight: AppConstants.Layout.composerMinHeight)
                    .background(Palette.chatBackground, in: Capsule())

                if isSending || isPreparingAttachment {
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
        }
        .background(Palette.composerBackground)
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPickedItem(newValue) }
        }
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

    /// 掲示板には Push 通知が無いので, 開いている間は
    /// チャットの購読失敗時フォールバックと同じ間隔でポーリングする.
    /// `.task` は画面が消えると自動でキャンセルされるので, ここで
    /// タイマーを片付ける必要はない.
    private func loadAndPoll() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(AppConstants.Timing.fallbackPollInterval))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func loadPickedItem(_ item: PhotosPickerItem) async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            store.setBanner(.unsupportedMedia)
            return
        }
        draftImageData = data
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let imageData = draftImageData
        draft = ""
        draftImageData = nil
        pickerItem = nil

        Task {
            isSending = true
            defer { isSending = false }
            do {
                var media: OutgoingMessage.LocalMedia?
                if let imageData {
                    media = try await store.processor.prepareImage(originalData: imageData)
                }
                _ = try await environment.backend.createBoardPost(in: thread.id, body: text, image: media)
                await load()
            } catch {
                // 失敗したら書いた内容を戻す(消えてしまうと書き直しになる).
                draft = text
                draftImageData = imageData
                store.setBanner(AppError.wrap(error))
            }
        }
    }
}

/// 掲示板の写真の拡大表示.
///
/// チャットの `MediaViewerScreen` と分けているのは, 掲示板の写真は暗号化して
/// いないため復号が要らず, 会話 ID にも紐付かないので, もっと単純に済むため.
private struct BoardImageViewerScreen: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let image: BoardImageAttachment

    private enum LoadState: Equatable {
        case loading
        case ready(URL)
        case failed(AppError)
    }

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(AppError)
    }

    @State private var loadState: LoadState = .loading
    @State private var saveState: SaveState = .idle

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .overlay(alignment: .topLeading) {
            if case .ready = loadState {
                saveButton
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .padding()
            .accessibilityLabel(String(localized: "閉じる"))
        }
        .statusBarHidden()
        .task { await load() }
        .alert(
            saveFailureMessage ?? "",
            isPresented: .init(
                get: { saveFailureMessage != nil },
                set: { if !$0 { saveState = .idle } }
            )
        ) {
            Button(String(localized: "OK")) { saveState = .idle }
        }
    }

    private var saveFailureMessage: String? {
        if case .failed(let error) = saveState { return error.errorDescription }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .ready(let url):
            ZoomableImageView(url: url)
        case .loading:
            ZStack {
                if let data = image.thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .blur(radius: 8)
                        .opacity(0.6)
                }
                ProgressView().tint(.white).controlSize(.large)
            }
        case .failed(let error):
            ContentUnavailableView {
                Label(
                    error.errorDescription ?? String(localized: "読み込めませんでした"),
                    systemImage: "exclamationmark.triangle"
                )
            } actions: {
                Button(String(localized: "再試行")) {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        }
    }

    private var saveButton: some View {
        Button {
            saveCurrentImage()
        } label: {
            Group {
                switch saveState {
                case .saving:
                    ProgressView().tint(.white)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.25))
                default:
                    Image(systemName: "square.and.arrow.down.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.25))
                }
            }
            .font(.largeTitle)
        }
        .disabled(saveState == .saving)
        .padding()
        .accessibilityLabel(String(localized: "写真を保存"))
    }

    private func load() async {
        // ローカルにある(自分がいま投稿した直後の)分は, ダウンロードせずそのまま使う.
        if let localURL = image.localURL {
            loadState = .ready(localURL)
            return
        }
        guard let reference = image.remote else {
            loadState = .failed(.underlying(String(localized: "写真が見つかりませんでした")))
            return
        }
        loadState = .loading
        do {
            let url = try await environment.backend.downloadBoardImage(reference)
            loadState = .ready(url)
        } catch {
            loadState = .failed(AppError.wrap(error))
        }
    }

    private func saveCurrentImage() {
        guard case .ready(let url) = loadState else { return }
        saveState = .saving
        Task {
            do {
                try await PhotoLibraryExporter.save(fileAt: url, kind: .image)
                saveState = .saved
                try? await Task.sleep(for: .seconds(1.5))
                if saveState == .saved { saveState = .idle }
            } catch {
                saveState = .failed(AppError.wrap(error))
            }
        }
    }
}

extension BoardImageAttachment: Identifiable {
    var id: String {
        remote?.cacheKey ?? localURL?.path ?? UUID().uuidString
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
