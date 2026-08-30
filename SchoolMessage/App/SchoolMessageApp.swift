import SwiftUI

@main
struct SchoolMessageApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    AppDelegate.environment = environment
                    await environment.store.start()
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
}
