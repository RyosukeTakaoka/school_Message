import Foundation

/// バックエンドの変更イベントを複数の購読者に配る.
///
/// `AsyncStream` は 1 本につき 1 消費者しか想定していないため, 購読ごとに
/// ストリームを作り, ここで束ねて同じイベントを配る.
/// actor ではなく lock を使うのは, `events()` が同期メソッドとして
/// `ChatBackend` プロトコルに要求されているため.
final class BackendEventHub: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]

    func stream() -> AsyncStream<BackendEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: BackendEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}
