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

    @State private var text: String = ""
    @State private var draft: Draft?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPreparingAttachment = false
    @State private var isShowingCamera = false
    @FocusState private var isInputFocused: Bool

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

    var body: some View {
        VStack(spacing: 0) {
            if let draft {
                attachmentPreview(draft)
                Divider()
            }
            inputRow
        }
        .background(Palette.composerBackground)
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPickedItem(newValue) }
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
    }

    // MARK: - プレビュー

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

            TextField(String(localized: "メッセージを入力"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .submitLabel(.send)
                // 外付けキーボードの Return で送れるようにする.
                .onSubmit(send)
                .padding(.horizontal, AppConstants.Layout.standardSpacing)
                .padding(.vertical, 8)
                .frame(minHeight: AppConstants.Layout.composerMinHeight)
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

    private func send() {
        guard canSend else { return }
        let body = text
        let attachment = draft

        // 先に入力欄を空にする. 送信完了を待つと連続入力の妨げになる.
        text = ""
        draft = nil
        pickerItem = nil

        Task {
            if let attachment {
                switch attachment {
                case .image(let data):
                    await store.sendImage(originalData: data, in: conversationID)
                case .video(let url, _):
                    await store.sendVideo(sourceURL: url, in: conversationID)
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await store.sendText(trimmed, in: conversationID)
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
