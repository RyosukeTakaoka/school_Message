import SwiftUI

/// Giphy から GIF を選ぶ画面.
///
/// 写真と違って「選ぶ → プレビュー → 送信ボタン」を挟まず, タップした
/// その場で送る(スタンプピッカーに近い操作感にするため). チャットの
/// メッセージ入力欄からも, 掲示板の書き込み欄からも同じものを使う.
struct GifPickerView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// 選ばれた GIF の実データ(送信用レンディション). 呼び出し側が送信を担当する.
    let onPick: (Data) async -> Void

    @State private var query = ""
    @State private var results: [GiphyGif] = []
    @State private var isLoading = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var service: GiphyService { environment.giphyService }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView {
                        Label(String(localized: "GIFを読み込めませんでした"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(String(localized: "再試行")) {
                            Task { await load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if isLoading && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(results) { gif in
                                gifCell(gif)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .overlay {
                if isSending {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView()
                    }
                }
            }
            .navigationTitle("GIFを選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }
                }
            }
            .searchable(text: $query, prompt: Text("GIFを検索"))
            .onChange(of: query) { _, _ in scheduleSearch() }
            .task { await load() }
        }
        .disabled(isSending)
    }

    private func gifCell(_ gif: GiphyGif) -> some View {
        Button {
            Task { await pick(gif) }
        } label: {
            AsyncImage(url: gif.previewRendition?.url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.gray.opacity(0.15)
                default:
                    Color.gray.opacity(0.1).overlay { ProgressView() }
                }
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gif.title.isEmpty ? String(localized: "GIF") : gif.title)
    }

    /// 入力のたびに叩かず, 少し止まってから検索する(通信と表示のガタつきを抑える).
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = trimmed.isEmpty
                ? try await service.trending()
                : try await service.search(query: trimmed)
        } catch {
            errorMessage = AppError.wrap(error).errorDescription
        }
    }

    private func pick(_ gif: GiphyGif) async {
        guard let rendition = gif.sendRendition, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: rendition.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AppError.unsupportedMedia
            }
            await onPick(data)
            dismiss()
        } catch {
            errorMessage = AppError.wrap(error).errorDescription
        }
    }
}
