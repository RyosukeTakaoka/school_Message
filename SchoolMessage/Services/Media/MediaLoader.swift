import Foundation
import Observation

/// チャット内の写真・動画の本体を必要になったときだけ取りに行く.
///
/// 一覧に並ぶすべての動画を先読みすると通信量も待ち時間も跳ね上がるため,
/// - サムネイルはメッセージと一緒に届いたものを即座に表示し,
/// - 本体はタップされた(拡大 / 再生)時点で初めてダウンロードする.
@MainActor
@Observable
final class MediaLoader {

    enum LoadState: Equatable {
        case idle
        case loading
        case ready(URL)
        case failed(AppError)
    }

    private var states: [AttachmentID: LoadState] = [:]
    @ObservationIgnored private var inFlight: [AttachmentID: Task<Void, Never>] = [:]
    @ObservationIgnored private let backend: any ChatBackend

    init(backend: any ChatBackend) {
        self.backend = backend
    }

    func state(for attachment: MediaAttachment) -> LoadState {
        // 自分が送ったものはローカルに残っているので, ダウンロード不要.
        if let localURL = attachment.localURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            return .ready(localURL)
        }
        return states[attachment.id] ?? .idle
    }

    /// 本体を取得する. 同じ添付への重複リクエストはまとめる.
    func load(_ attachment: MediaAttachment, in conversationID: ConversationID) {
        if case .ready = state(for: attachment) { return }
        if inFlight[attachment.id] != nil { return }
        guard let reference = attachment.remote else {
            states[attachment.id] = .failed(.underlying(String(localized: "データの場所が分かりません")))
            return
        }

        states[attachment.id] = .loading
        inFlight[attachment.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.backend.downloadMedia(
                    reference,
                    kind: attachment.kind,
                    conversationID: conversationID
                )
                self.states[attachment.id] = .ready(url)
            } catch {
                self.states[attachment.id] = .failed(AppError.wrap(error))
            }
            self.inFlight[attachment.id] = nil
        }
    }

    /// 失敗したものをもう一度取りに行く.
    func retry(_ attachment: MediaAttachment, in conversationID: ConversationID) {
        states[attachment.id] = .idle
        load(attachment, in: conversationID)
    }
}
