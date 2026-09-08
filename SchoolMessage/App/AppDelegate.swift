import UIKit

/// APNs のトークン登録とリモート通知の受け口.
///
/// SwiftUI だけではサイレント通知(content-available)を受け取れないため,
/// `UIApplicationDelegateAdaptor` 経由でこのクラスを使う.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// `SchoolMessageApp` から注入される. 通知処理をストアに橋渡しする.
    @MainActor static var environment: AppEnvironment?

    /// 起動のいちばん早い段階. 画面はまだ何も無い.
    ///
    /// ここで Bluetooth を組み立てるのは, CoreBluetooth の復元
    /// (State Restoration)がそれを条件にしているため.
    /// このタイミングでマネージャを作り直していないと, iOS が
    /// 「近くに相手が現れた」とアプリを起こしても, 復元先がいないと判断されて
    /// 復元は捨てられる. つまり **「アプリを開いていないときのすれ違い」は,
    /// ここに置くかどうかで成否が決まる**.
    ///
    /// 画面(`AppEnvironment` → `RootView`)の組み立てを待つ形では間に合わない.
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        StreetPassKit.shared.bootstrap()
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 起動直後は通知の許可を求めない.
        // 「まず会話できること」を優先し, 最初のチャットを開いた後に依頼する.
        //
        // Bluetooth に起こされた起動かどうかは, ここで分かる(記録用).
        if launchOptions?[.bluetoothCentrals] != nil || launchOptions?[.bluetoothPeripherals] != nil {
            Log.streetPass.info("launched by bluetooth")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // 結果をサービスに残し, プロフィール画面の診断から確認できるようにする.
        Task { @MainActor in
            AppDelegate.environment?.pushService.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // 通知が使えなくてもアプリは動く(ポーリングで新着に気付く).
        Task { @MainActor in
            AppDelegate.environment?.pushService.handleDeviceTokenFailure(error)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let service = await MainActor.run { AppDelegate.environment?.pushService }
        guard let service else { return .noData }
        let fetchedNewData = await service.handleRemoteNotification(userInfo: userInfo)
        return fetchedNewData ? .newData : .noData
    }
}
