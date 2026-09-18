import SwiftUI
import Foundation
import Combine
import CloudKit

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
                .onChange(of: environment.store.myProfile) { _, profile in
                    // 名前が決まってから電波を出す(名前の無い名刺は相手側で捨てられる).
                    environment.streetPass.refresh()
                    // サインインが完了した(= プロフィールが読めた)ところで,
                    // 掲示板の通知をオンにしている利用者のために購読を作り直す.
                    if profile != nil {
                        Task { await environment.pushService.configureBoardSubscriptionIfNeeded() }
                    }
                }
                .onChange(of: demoTrigger.isRequested) { _, requested in
                    guard requested else { return }
                    Task { await enterDemoMode() }
                }
                // 設定アプリで iCloud をサインアウト / サインインし直したときに
                // 届く合図. これを見ていなかったため, アプリを起動し直すまで
                // 「前のアカウントの自分」でデータを探し続けていた
                // (`ChatStore.handleAccountChange` 参照).
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .CKAccountChanged)
                        // この通知は任意のスレッドから飛んでくる. 画面の状態を
                        // 触るので, 必ずメインスレッドに寄せてから受け取る.
                        .receive(on: DispatchQueue.main)
                ) { _ in
                    Task { await handleAccountChange() }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // 復帰時に取りこぼした新着を取り込み, 送信待ちを流す.
                environment.store.handleForeground()
                environment.streetPass.handleForeground()
                // アプリを開きっぱなしの人にも, 下限が上がったことが届くようにする.
                Task { await environment.updateGate.refresh(using: environment.backend) }
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
        // 古いビルドを使い続けている人に更新してもらうための確認.
        // 圏外だと再試行で時間がかかることがあるので, 起動を待たせず並行して行う
        // (読めなければ何も起きない. `AppUpdateGate` 参照).
        Task { await environment.updateGate.refresh(using: environment.backend) }
        // サイレント通知でアプリを起こせるようにするための登録.
        // 許可のダイアログは出ない(許可を求めるのは最初のチャットを開いたとき).
        environment.pushService.registerForRemoteNotifications()
        await environment.store.start()
    }

    /// iCloud アカウントが切り替わったときに, セッションを作り直す.
    ///
    /// 同意前は通信を始めない(`startIfConsented` と同じ考え方)ので,
    /// 同意していない間は何もしない.
    private func handleAccountChange() async {
        guard !AppConstants.Legal.requiresConsent || environment.consent.hasAgreedToCurrentVersion else { return }
        await environment.store.handleAccountChange()
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
