import SwiftUI
import AVKit

/// 写真の拡大表示 / 動画の全画面再生.
///
/// 本体は開いた時点で初めてダウンロードする. それまではメッセージと一緒に届いた
/// サムネイルを引き伸ばして出し, 「何も出ない時間」を作らない.
struct MediaViewerScreen: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let attachment: MediaAttachment
    let conversationID: ConversationID

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(AppError)

        var failedError: AppError? {
            if case .failed(let error) = self { return error }
            return nil
        }
    }

    @State private var saveState: SaveState = .idle

    private var loader: MediaLoader { environment.mediaLoader }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .overlay(alignment: .topLeading) {
            if case .ready = loader.state(for: attachment) {
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
        .overlay(alignment: .bottom) {
            footer
        }
        .statusBarHidden()
        .task {
            loader.load(attachment, in: conversationID)
        }
        .alert(
            (saveState.failedError)?.errorDescription ?? "",
            isPresented: .init(
                get: { saveState.failedError != nil },
                set: { if !$0 { saveState = .idle } }
            ),
            presenting: saveState.failedError
        ) { _ in
            Button(String(localized: "OK")) { saveState = .idle }
        } message: { error in
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
            }
        }
    }

    private var saveButton: some View {
        Button {
            saveCurrentMedia()
        } label: {
            Group {
                switch saveState {
                case .saving:
                    ProgressView()
                        .tint(.white)
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
        .accessibilityLabel(
            attachment.kind == .image
                ? String(localized: "写真を保存")
                : String(localized: "動画を保存")
        )
    }

    /// 表示中の本体を「写真」アプリへ保存する.
    private func saveCurrentMedia() {
        guard case .ready(let url) = loader.state(for: attachment) else { return }
        saveState = .saving
        Task {
            do {
                try await PhotoLibraryExporter.save(fileAt: url, kind: attachment.kind)
                saveState = .saved
                try? await Task.sleep(for: .seconds(1.5))
                if saveState == .saved { saveState = .idle }
            } catch {
                saveState = .failed(AppError.wrap(error))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state(for: attachment) {
        case .ready(let url):
            switch attachment.kind {
            case .image:
                ZoomableImageView(url: url)
            case .video:
                FullScreenVideoPlayer(url: url)
            }

        case .loading, .idle:
            ZStack {
                placeholderThumbnail
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }

        case .failed(let error):
            ContentUnavailableView {
                Label(
                    error.errorDescription ?? String(localized: "読み込めませんでした"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                }
            } actions: {
                Button(String(localized: "再試行")) {
                    loader.retry(attachment, in: conversationID)
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        }
    }

    /// ダウンロード中に見せるぼかしたサムネイル.
    @ViewBuilder
    private var placeholderThumbnail: some View {
        if let data = attachment.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .blur(radius: 8)
                .opacity(0.6)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .loading = loader.state(for: attachment) {
            Text("読み込み中… \(MediaLimits.formatted(byteCount: attachment.byteCount))")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 24)
        }
    }
}

/// 全画面の動画再生.
///
/// `AVPlayer` を `@State` に持つ. body の評価ごとに作り直すと,
/// 再生位置が巻き戻ったり音声が二重になったりするため.
struct FullScreenVideoPlayer: View {

    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

/// ピンチとダブルタップで拡大できる画像表示.
///
/// `UIScrollView` を包むことで, 慣性・境界の跳ね返り・二本指スクロールなど
/// 標準の挙動をそのまま得る. SwiftUI のジェスチャで再実装するより素直に動く.
struct ZoomableImageView: UIViewRepresentable {

    let url: URL

    private static let maximumZoomScale: CGFloat = 4
    private static let doubleTapZoomScale: CGFloat = 2.5

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = Self.maximumZoomScale
        scrollView.minimumZoomScale = 1
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.accessibilityLabel = String(localized: "写真")
        imageView.isAccessibilityElement = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        context.coordinator.imageView = imageView
        context.coordinator.zoomScale = Self.doubleTapZoomScale
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // 大きな画像でメモリを使い切らないよう, 表示直前に読み込む.
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.imageView?.image = UIImage(contentsOfFile: url.path)
            uiView.setZoomScale(1, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var loadedURL: URL?
        var zoomScale: CGFloat = 2.5

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = imageView?.superview as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                scrollView.setZoomScale(zoomScale, animated: true)
            }
        }
    }
}
