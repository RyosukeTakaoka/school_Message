import SwiftUI

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
                    if isLoading && threads.isEmpty {
                        HStack {
                            ProgressView()
                            Text("読み込み中…").foregroundStyle(Palette.subdued)
                        }
                    } else if threads.isEmpty {
                        Text("まだスレッドがありません。右上の＋で立ててみてください。")
                            .font(.footnote)
                            .foregroundStyle(Palette.subdued)
                    } else {
                        ForEach(threads) { thread in
                            Button {
                                openedThread = thread
                            } label: {
                                threadRow(thread)
                            }
                        }
                    }
                } footer: {
                    Text("掲示板の書き込みは、このアプリを使っている人なら誰でも読めます。チャットと違って暗号化されず、名前は表示されませんが、消すこともできません。")
                }
            }
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
            .task { await load() }
            .sheet(isPresented: $isComposingThread) {
                NewThreadView { title, body in
                    await create(title: title, body: body)
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

    private func threadRow(_ thread: BoardThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thread.title)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.primary)
            HStack(spacing: 8) {
                Text("\(thread.postCount) レス")
                Text(DateDisplay.messageTimestamp(thread.lastPostedAt))
            }
            .font(.caption)
            .foregroundStyle(Palette.subdued)
        }
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

    private func create(title: String, body: String) async {
        do {
            _ = try await environment.backend.createBoardThread(title: title, body: body)
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

    let onCreate: (String, String) async -> Void

    @State private var title = ""
    // View の `body` と名前がぶつからないよう `text` にしている.
    @State private var text = ""
    @State private var isSending = false

    private var canSend: Bool {
        !isSending
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                    await onCreate(title, text)
                                    isSending = false
                                }
                            }
                            .disabled(!canSend)
                        }
                    }
                }
        }
    }
}

#Preview {
    BoardView()
        .environment(AppEnvironment.preview())
}
