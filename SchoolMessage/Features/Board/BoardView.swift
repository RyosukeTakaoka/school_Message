import SwiftUI
import PhotosUI

/// 掲示板のスレッド一覧.
///
/// 「わざわざチャットに送るほどでもない独り言」を置く場所. チャットと違って
/// **誰でも読める**ので, その点は画面の上で最初に伝える.
struct BoardView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var threads: [BoardThread] = []
    @State private var isLoading = false
    @State private var isComposingThread = false
    @State private var openedThread: BoardThread?

    private var store: ChatStore { environment.store }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    explainerCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if isLoading && threads.isEmpty {
                        HStack {
                            ProgressView()
                            Text("読み込み中…").foregroundStyle(Palette.subdued)
                        }
                    } else if threads.isEmpty {
                        emptyState
                    } else {
                        ForEach(threads) { thread in
                            Button {
                                openedThread = thread
                            } label: {
                                threadRow(thread)
                            }
                        }
                    }
                } header: {
                    if !threads.isEmpty {
                        Text("スレッド")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("掲示板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isComposingThread = true
                    } label: {
                        Label(String(localized: "スレッドを立てる"), systemImage: "plus")
                    }
                }
            }
            .refreshable { await load() }
            .task { await loadAndPoll() }
            .sheet(isPresented: $isComposingThread) {
                NewThreadView { title, body, image in
                    await create(title: title, body: body, image: image)
                }
            }
            .navigationDestination(item: $openedThread) { thread in
                BoardThreadView(thread: thread)
            }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
        }
    }

    // MARK: - 部品

    /// 「これはチャットとは別の場所だ」を最初に伝えるための説明カード.
    private var explainerCard: some View {
        HStack(alignment: .top, spacing: AppConstants.Layout.standardSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.white)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("みんなの掲示板")
                    .font(.headline)
                Text("このアプリを使っている人なら誰でも読めます。チャットと違って暗号化されず、名前も表示されませんが、書き込みを消すこともできません。")
                    .font(.footnote)
                    .foregroundStyle(Palette.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppConstants.Layout.standardSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.incomingBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(Palette.subdued)
            Text("まだスレッドがありません")
                .font(.subheadline.weight(.medium))
            Text("右上の＋から、最初のスレッドを立ててみましょう。")
                .font(.footnote)
                .foregroundStyle(Palette.subdued)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppConstants.Layout.standardSpacing * 2)
    }

    private func threadRow(_ thread: BoardThread) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                HStack(spacing: AppConstants.Layout.compactSpacing) {
                    Label("\(thread.postCount)", systemImage: "text.bubble")
                    Label(DateDisplay.messageTimestamp(thread.lastPostedAt), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(Palette.subdued)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.subdued)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await environment.backend.fetchBoardThreads()
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

    private func create(title: String, body: String, image: Data?) async {
        do {
            var media: OutgoingMessage.LocalMedia?
            if let image {
                media = try await store.processor.prepareImage(originalData: image)
            }
            _ = try await environment.backend.createBoardThread(title: title, body: body, image: media)
            isComposingThread = false
            await load()
        } catch {
            store.setBanner(AppError.wrap(error))
        }
    }
}

/// スレッドを立てる画面.
private struct NewThreadView: View {

    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String, Data?) async -> Void

    @State private var title = ""
    // View の `body` と名前がぶつからないよう `text` にしている.
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var isPreparingAttachment = false
    @State private var isSending = false

    private var canSend: Bool {
        !isSending && !isPreparingAttachment
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (imageData != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "タイトル"), text: $title)
                } header: {
                    Text("タイトル")
                }
                Section {
                    TextField(String(localized: "本文"), text: $text, axis: .vertical)
                        .lineLimit(4...12)

                    if let imageData, let uiImage = UIImage(data: imageData) {
                        HStack {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Spacer()
                            Button(role: .destructive) {
                                self.imageData = nil
                                pickerItem = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label(
                            imageData == nil ? String(localized: "写真を選ぶ") : String(localized: "写真を選び直す"),
                            systemImage: "photo.on.rectangle"
                        )
                    }
                    .disabled(isPreparingAttachment)
                } header: {
                    Text("最初の書き込み")
                } footer: {
                    Text("名前は表示されませんが、書き込みは誰でも読めます。人が傷つくことは書かないでください。")
                }
            }
                .navigationTitle("スレッドを立てる")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "キャンセル")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSending {
                            ProgressView()
                        } else {
                            Button(String(localized: "立てる")) {
                                Task {
                                    isSending = true
                                    await onCreate(title, text, imageData)
                                    isSending = false
                                }
                            }
                            .disabled(!canSend)
                        }
                    }
                }
                .onChange(of: pickerItem) { _, newValue in
                    guard let newValue else { return }
                    Task {
                        isPreparingAttachment = true
                        defer { isPreparingAttachment = false }
                        imageData = try? await newValue.loadTransferable(type: Data.self)
                    }
                }
        }
    }
}

#Preview {
    BoardView()
        .environment(AppEnvironment.preview())
}
