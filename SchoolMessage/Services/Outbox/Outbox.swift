import Foundation

/// 送信待ちメッセージの永続キュー.
///
/// ### なぜディスクに残すのか
/// - 送信中にアプリが強制終了された / ユーザがアプリを閉じた場合でも,
///   次回起動時に続きから送れるようにするため.
/// - 圧縮済みの写真・動画は `MediaStore.outboxDirectory` に置いてあり,
///   このキューが「どのファイルがまだ必要か」の唯一の情報源になる.
///
/// 保存は 1 ファイルへの JSON 書き出し. 送信待ちが数十件を超える想定はないので,
/// データベースを持ち込むより単純さを優先する.
actor Outbox {

    private let fileURL: URL
    private let mediaStore: MediaStore
    private var items: [OutgoingMessage] = []
    private var isLoaded = false

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.fileURL = mediaStore.outboxDirectory.appendingPathComponent("outbox.json")
    }

    // MARK: - 読み書き

    func load() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            items = try JSONDecoder().decode([OutgoingMessage].self, from: data)
            Log.outbox.info("loaded \(self.items.count, privacy: .public) pending message(s)")
        } catch {
            // 壊れたキューで起動できなくなるのが最悪なので, 捨てて先へ進む.
            Log.outbox.error("outbox is unreadable; discarding")
            items = []
            try? FileManager.default.removeItem(at: fileURL)
        }

        // どのメッセージからも参照されていないメディアファイルを掃除する.
        let alive = Set(items.compactMap(\.attachmentID))
        mediaStore.purgeOrphanedOutboxFiles(keeping: alive)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.outbox.error("failed to persist outbox")
        }
    }

    // MARK: - 操作

    func all() -> [OutgoingMessage] {
        items
    }

    func items(in conversationID: ConversationID) -> [OutgoingMessage] {
        items.filter { $0.conversationID == conversationID }
    }

    func enqueue(_ message: OutgoingMessage) {
        // 同じ ID が既にあれば置き換える(二重登録を防ぐ).
        if let index = items.firstIndex(where: { $0.id == message.id }) {
            items[index] = message
        } else {
            items.append(message)
        }
        persist()
    }

    /// 送信が完了したので取り除く. 添付ファイルも消す.
    func complete(_ id: MessageID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        if case .media(let media) = removed.body {
            mediaStore.remove(at: media.fileURL)
        }
        persist()
    }

    /// ユーザが送信を取り消した.
    func cancel(_ id: MessageID) {
        complete(id)
    }

    /// 失敗を記録する. 一時的な失敗なら次回試行時刻を設定し, そうでなければ諦める.
    func recordFailure(_ id: MessageID, error: AppError) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].attemptCount += 1
        items[index].lastFailureReason = error.errorDescription

        let attempts = items[index].attemptCount
        if error.isRetryable && attempts < AppConstants.Timing.maxRetryAttempts {
            let delay = error.suggestedRetryDelay
                ?? AsyncRetry.backoffDelay(attempt: attempts, baseDelay: AppConstants.Timing.retryBaseDelay)
            items[index].nextAttemptAt = Date.now.addingTimeInterval(delay)
            items[index].isPermanentlyFailed = false
        } else {
            items[index].nextAttemptAt = nil
            items[index].isPermanentlyFailed = true
        }
        persist()
    }

    /// ユーザが「再送信」を押したときに, 試行回数をリセットして即時対象に戻す.
    func resetForManualRetry(_ id: MessageID) -> OutgoingMessage? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].attemptCount = 0
        items[index].nextAttemptAt = nil
        items[index].isPermanentlyFailed = false
        items[index].lastFailureReason = nil
        persist()
        return items[index]
    }

    /// いま送ってよいものを, 作成順に返す.
    func ready(now: Date = .now) -> [OutgoingMessage] {
        items
            .filter { !$0.isPermanentlyFailed }
            .filter { ($0.nextAttemptAt ?? .distantPast) <= now }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 自動再送を諦めた(＝ユーザ操作待ちの)ものがあるか.
    func hasFailures() -> Bool {
        items.contains(where: \.isPermanentlyFailed)
    }
}
