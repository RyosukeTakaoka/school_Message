import Foundation
import Network
import Observation

/// ネットワーク到達性の監視.
///
/// 「送れなかった」ときに, 圏外なのかサーバの問題なのかを区別して伝えるために使う.
/// また接続が戻ったタイミングで送信待ちを自動的に流し直す起点にもなる.
@MainActor
@Observable
final class NetworkMonitor {

    private(set) var isOnline: Bool = true
    /// 従量制回線(テザリングなど). 動画の自動ダウンロードを抑えるために見る.
    private(set) var isExpensive: Bool = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.schoolmessage.network-monitor")

    /// オンラインに復帰した瞬間に呼ばれる. 送信待ちの再送に使う.
    @ObservationIgnored var onReconnect: (@MainActor () -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                if wasOffline && online {
                    Log.sync.info("network restored")
                    self.onReconnect?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
