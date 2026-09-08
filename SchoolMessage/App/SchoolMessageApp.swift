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
                    await startIfConsented()
                }
                .onChange(of: environment.consent.hasAgreedToCurrentVersion) { _, agreed in
                    guard agreed else { return }
                    Task { await startIfConsented() }
                }
                .onChange(of: environment.store.myProfile) { _, _ in
                    // 名前が決まってから電波を出す(名前の無い名刺は相手側で捨てられる).
                    environment.streetPass.refresh()
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
                environment.streetPass.handleForeground()
            case .background:
                Task { await environment.pushService.updateBadge() }
            default:
                break
            }
        }
    }

    /// 同意が要らない設定(`AppConstants.Legal.requiresConsent == false`)か,
    /// 規約に同意済みのときだけ, iCloud への接続を開始する.
    ///
    /// 同意を求めている段階では, 同意前にサーバへ問い合わせないことで
    /// 「同意していないのに通信が始まっている」状態を作らない. 同意した瞬間に
    /// 呼び直される.
    private func startIfConsented() async {
        guard !AppConstants.Legal.requiresConsent || environment.consent.hasAgreedToCurrentVersion else { return }
        // サイレント通知でアプリを起こせるようにするための登録.
        // 許可のダイアログは出ない(許可を求めるのは最初のチャットを開いたとき).
        environment.pushService.registerForRemoteNotifications()
        await environment.store.start()
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
