import UIKit

/// APNs のトークン登録とリモート通知の受け口.
///
/// SwiftUI だけではサイレント通知(content-available)を受け取れないため,
/// `UIApplicationDelegateAdaptor` 経由でこのクラスを使う.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// `SchoolMessageApp` から注入される. 通知処理をストアに橋渡しする.
    @MainActor static var environment: AppEnvironment?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 起動直後は通知の許可を求めない.
        // 「まず会話できること」を優先し, 最初のチャットを開いた後に依頼する.
        true
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
