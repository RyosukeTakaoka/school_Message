import SwiftUI

@main
struct SchoolMessageApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()
    @State private var demoTrigger = DemoModeTrigger()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(demoTrigger)
                .task {
                    AppDelegate.environment = environment
                    await environment.store.start()
                }
                .onChange(of: demoTrigger.isRequested) { _, requested in
                    guard requested else { return }
                    Task { await enterDemoMode() }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // 復帰時に取りこぼした新着を取り込み, 送信待ちを流す.
                environment.store.handleForeground()
            case .background:
                Task { await environment.pushService.updateBadge() }
            default:
                break
            }
        }
    }

    /// バックエンドをサンプルデータ入りのインメモリ実装に差し替える.
    ///
    /// iCloud サインインが使えない/友達がいない状態でアプリの機能を確認したい
    /// 場合(App Store 審査など)のための入り口. 実データには一切触れない.
    private func enterDemoMode() async {
        let demo = AppEnvironment.preview()
        await demo.store.start()
        AppDelegate.environment = demo
        environment = demo
        demoTrigger.isRequested = false
    }
}
