import Foundation
import Observation

/// 依存関係の組み立てと保持.
///
/// View から `@Environment(AppEnvironment.self)` で取り出す. 生成箇所を 1 つに
/// することで, プレビュー用のインメモリ実装と本番の CloudKit 実装を
/// 差し替えるのがここだけで済む.
@MainActor
@Observable
final class AppEnvironment {

    let backend: any ChatBackend
    let store: ChatStore
    let mediaLoader: MediaLoader
    let networkMonitor: NetworkMonitor
    let notificationPreferences: NotificationPreferences
    let pushService: PushNotificationService
    let consent: ConsentStore
    let streetPass: StreetPassStore

    private init(
        backend: any ChatBackend,
        store: ChatStore,
        mediaLoader: MediaLoader,
        networkMonitor: NetworkMonitor,
        notificationPreferences: NotificationPreferences,
        pushService: PushNotificationService,
        consent: ConsentStore,
        streetPass: StreetPassStore
    ) {
        self.backend = backend
        self.store = store
        self.mediaLoader = mediaLoader
        self.networkMonitor = networkMonitor
        self.notificationPreferences = notificationPreferences
        self.pushService = pushService
        self.consent = consent
        self.streetPass = streetPass
        pushService.attach(store: store)
        streetPass.attach(store: store)
    }

    /// 本番構成(CloudKit).
    static func live() -> AppEnvironment {
        let mediaStore = MediaStore()
        let crypto = CryptoService()
        let backend = CloudKitBackend(crypto: crypto, mediaStore: mediaStore)
        return make(backend: backend, crypto: crypto, mediaStore: mediaStore)
    }

    /// プレビュー / UI テスト構成(ネットワークも iCloud も使わない).
    static func preview() -> AppEnvironment {
        let mediaStore = MediaStore()
        let crypto = CryptoService()
        let backend = InMemoryChatBackend()
        return make(backend: backend, crypto: crypto, mediaStore: mediaStore)
    }

    private static func make(
        backend: any ChatBackend,
        crypto: CryptoService,
        mediaStore: MediaStore
    ) -> AppEnvironment {
        let networkMonitor = NetworkMonitor()
        let outbox = Outbox(mediaStore: mediaStore)
        let processor = MediaProcessor(store: mediaStore)
        let store = ChatStore(
            backend: backend,
            outbox: outbox,
            mediaProcessor: processor,
            mediaStore: mediaStore,
            crypto: crypto,
            networkMonitor: networkMonitor
        )
        let preferences = NotificationPreferences()
        return AppEnvironment(
            backend: backend,
            store: store,
            mediaLoader: MediaLoader(backend: backend),
            networkMonitor: networkMonitor,
            notificationPreferences: preferences,
            pushService: PushNotificationService(preferences: preferences),
            consent: ConsentStore(),
            streetPass: StreetPassStore()
        )
    }
}
