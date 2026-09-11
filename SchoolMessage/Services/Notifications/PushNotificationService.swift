import Foundation
import UIKit
import UserNotifications
import CloudKit

/// プッシュ通知の許可要求・登録・表示.
///
/// ## 本文をどう出すか
/// メッセージ本文は会話鍵で暗号化されており, サーバ(CloudKit)には復号できない.
/// そのため CloudKit が生成する通知には送信者名しか載せられない.
///
/// アプリがサイレント通知で起こされたときは端末内で復号できるので,
/// そこで「送信者 + 本文」のローカル通知に差し替える. 起こされなかった場合でも
/// 送信者名の通知は届くので, 「誰かから来た」ことは分かる.
///
/// より確実に本文を出すには Notification Service Extension が必要になる.
/// 設計と実装手順は `docs/NOTIFICATIONS.md` に記載.
@MainActor
final class PushNotificationService: NSObject {

    private let preferences: NotificationPreferences
    private weak var store: ChatStore?

    /// APNs への端末登録の結果.
    ///
    /// 「通知が来ない」の原因は, 許可・端末登録・購読・配信のどこで切れても
    /// 同じ症状になる. 段階ごとに結果を残し, 画面で切り分けられるようにする.
    enum DeviceTokenState: Equatable {
        case notRequested
        case registered(suffix: String)
        case failed(String)

        var isRegistered: Bool {
            if case .registered = self { return true }
            return false
        }
    }

    private(set) var deviceTokenState: DeviceTokenState = .notRequested

    init(preferences: NotificationPreferences) {
        self.preferences = preferences
        super.init()
    }

    func attach(store: ChatStore) {
        self.store = store
    }

    // MARK: - 端末登録の結果(AppDelegate から通知される)

    func handleDeviceToken(_ token: Data) {
        // トークン全体は秘密情報なので末尾だけ残す. 同一端末かの判別には足りる.
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceTokenState = .registered(suffix: String(hex.suffix(6)))
        Log.push.info("registered for remote notifications")
    }

    func handleDeviceTokenFailure(_ error: any Error) {
        deviceTokenState = .failed(error.localizedDescription)
        Log.push.notice("remote notification registration failed")
    }

    /// 通知の許可状態を OS に問い合わせる.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - 診断

    /// 通知が届くまでの各段階の状態.
    ///
    /// 通知は「許可 → 端末登録 → 購読 → 配信」の 4 段階を全部通らないと届かず,
    /// どこで切れても症状は同じ「通知が来ない」になる. 段階ごとに結果を出して
    /// 原因を 1 回で特定できるようにする.
    struct Diagnostics: Equatable {
        var authorization: UNAuthorizationStatus
        var deviceToken: DeviceTokenState
        var serverSubscriptionIDs: [String]
        var subscriptionLookupError: String?

        /// 新着メッセージの購読がサーバ上に存在するか.
        ///
        /// グローバルな購読が使えない環境では会話ごとの購読に切り替わるので,
        /// どちらの形でも「ある」と判定する.
        var hasMessageSubscription: Bool {
            serverSubscriptionIDs.contains(CKSchema.SubscriptionID.newMessages)
                || serverSubscriptionIDs.contains(where: CKSchema.SubscriptionID.isPerConversation)
        }

        /// 会話ごとの購読で動いているか(診断の表示に使う).
        var usesPerConversationSubscriptions: Bool {
            serverSubscriptionIDs.contains(where: CKSchema.SubscriptionID.isPerConversation)
        }

        /// すべての段階を通過しているか.
        var isHealthy: Bool {
            authorization == .authorized
                && deviceToken.isRegistered
                && hasMessageSubscription
        }
    }

    /// いまの状態を集めて返す.
    func runDiagnostics(using backend: any ChatBackend) async -> Diagnostics {
        let status = await authorizationStatus()

        var subscriptionIDs: [String] = []
        var lookupError: String?
        do {
            subscriptionIDs = try await backend.fetchSubscriptionIDs()
        } catch {
            lookupError = AppError.wrap(error).errorDescription
        }

        return Diagnostics(
            authorization: status,
            deviceToken: deviceTokenState,
            serverSubscriptionIDs: subscriptionIDs,
            subscriptionLookupError: lookupError
        )
    }

    // MARK: - 登録

    /// APNs への端末登録だけを行う(通知の許可ダイアログは出さない).
    ///
    /// サイレント通知(`content-available`)は通知の許可が無くても届き,
    /// アプリを起こして新着を取り込むために使える. 一方で, 端末が APNs に
    /// 登録されていないとサイレント通知自体が届かない.
    ///
    /// 許可を求めるのは最初のチャットを開いた時点のままにしつつ, 登録だけは
    /// 起動直後に済ませることで, 「許可する前でも相手の送信が自動で画面に出る」
    /// 状態にする. 登録自体はダイアログを伴わないので, 利用者の邪魔をしない.
    func registerForRemoteNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 通知の許可を求め, APNs に登録する.
    ///
    /// 許可が得られなくてもアプリは動く(定期ポーリングで新着に気付く)ので,
    /// 失敗を致命的な扱いにはしない.
    func requestAuthorizationAndRegister() async {
        UNUserNotificationCenter.current().delegate = self

        guard preferences.isAnyCategoryEnabled else { return }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                Log.push.notice("notification permission denied")
                return
            }
        } catch {
            Log.push.error("notification authorization failed")
            return
        }

        // サイレント通知(content-available)の受信自体は許可に関係なく必要.
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - 掲示板の通知

    /// サインイン直後に呼ぶ. 既に「掲示板」の通知をオンにしている利用者のために,
    /// 購読を作り直す(サーバ側の購読が何らかの理由で消えていても復旧できるように,
    /// 毎回の起動で呼んでよい設計にしてある).
    func configureBoardSubscriptionIfNeeded() async {
        guard preferences.boardEnabled else { return }
        guard let store, store.phase == .ready else { return }
        do {
            try await store.backend.configureBoardSubscription()
        } catch {
            Log.push.notice(
                "failed to configure board subscription: \(AppError.wrap(error).localizedDescription, privacy: .public)"
            )
        }
    }

    /// 設定画面で「掲示板」の通知トグルを切り替えたときに呼ぶ.
    /// トグルの状態はここで保存し, サーバ側の購読の作成・削除も同時に行う.
    func setBoardNotificationsEnabled(_ enabled: Bool) async {
        preferences.boardEnabled = enabled
        guard let store, store.phase == .ready else { return }
        do {
            if enabled {
                try await store.backend.configureBoardSubscription()
            } else {
                try await store.backend.removeBoardSubscription()
            }
        } catch {
            Log.push.notice(
                "failed to update board subscription: \(AppError.wrap(error).localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 受信

    /// リモート通知を処理し, 必要ならローカル通知に差し替える.
    /// - Returns: 新しいデータを取得したか(バックグラウンド実行結果に使う).
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let store else { return false }

        await store.backend.handleRemoteNotification(userInfo: userInfo)

        // 会話 ID が分かるなら, その会話だけ先に取り込む.
        let conversationID = Self.conversationID(from: userInfo)
        if let conversationID {
            await store.refreshMessages(in: conversationID)
        }
        await store.refreshConversations()
        await updateBadge()

        // 前面表示中の会話については, 通知を出さずに画面へ反映するだけにする.
        if let conversationID,
           conversationID != store.selectedConversationID,
           preferences.messagesEnabled,
           let latest = store.messagesByConversation[conversationID]?.last,
           latest.senderID != store.currentUserID {
            await presentLocalNotification(for: latest, in: conversationID, store: store)
        }

        return conversationID != nil
    }

    /// 復号済みの内容でローカル通知を出す.
    private func presentLocalNotification(
        for message: Message,
        in conversationID: ConversationID,
        store: ChatStore
    ) async {
        let content = UNMutableNotificationContent()
        let senderName = store.displayName(for: message.senderID)

        if let conversation = store.conversation(conversationID), conversation.kind == .group {
            content.title = store.title(for: conversation)
            content.subtitle = senderName
        } else {
            content.title = senderName
        }

        content.body = preferences.showsMessagePreview
            ? message.content.previewText
            : String(localized: "新しいメッセージ")
        content.sound = .default
        content.threadIdentifier = conversationID.rawValue
        content.userInfo = [Self.conversationUserInfoKey: conversationID.rawValue]
        content.badge = NSNumber(value: store.totalUnreadCount)

        let request = UNNotificationRequest(
            identifier: message.id.rawValue,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.push.error("failed to present local notification")
        }
    }

    /// アプリアイコンのバッジを未読合計に合わせる.
    func updateBadge() async {
        guard let store else { return }
        let count = store.totalUnreadCount
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            Log.push.notice("failed to update badge")
        }
    }

    // MARK: - payload の読み取り

    static let conversationUserInfoKey = "conversationID"

    private static func conversationID(from userInfo: [AnyHashable: Any]) -> ConversationID? {
        // 自前で出したローカル通知.
        if let raw = userInfo[conversationUserInfoKey] as? String {
            return ConversationID(raw)
        }
        // CloudKit のクエリ通知. payload の内部構造に依存せず公開 API で読む.
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let query = notification as? CKQueryNotification else {
            return nil
        }
        let raw = query.recordFields?[CKSchema.Message.conversation]
        let recordName = (raw as? String) ?? (raw as? CKRecord.Reference)?.recordID.recordName
        return recordName.map(ConversationID.init)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationService: UNUserNotificationCenterDelegate {

    /// アプリ表示中でも通知を出す.
    /// ただし, いま開いているチャットの通知は出さない(画面に既に見えているため).
    ///
    /// `nonisolated` を付けていない(このクラスは `@MainActor` なので,
    /// 何も付けなければメインアクターに隔離される). 以前は `nonisolated` にした上で
    /// 中身だけ `MainActor.run` で処理していたが, その形だと Swift が
    /// UIKit 側(Objective-C)に渡す完了ハンドラの呼び出し自体がメインアクター上で
    /// 行われる保証がなくなる. これが, 通知をタップして起動した直後に
    /// `UIApplication` の状態復元(State Restoration)の内部処理と競合して
    /// クラッシュしていた実際の原因だった(実機のクラッシュログで確認済み.
    /// `_updateStateRestorationArchiveForBackgroundEvent` 内のアサーション失敗).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let raw = userInfo[Self.conversationUserInfoKey] as? String
        if let raw, ConversationID(raw) == store?.selectedConversationID {
            return []
        }
        return [.banner, .sound, .badge]
    }

    /// 通知をタップした. 対象のチャットを開く.
    /// メインアクターに隔離する理由は上の `willPresent` と同じ.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[Self.conversationUserInfoKey] as? String else { return }
        // 開くべきチャットをストアに伝える. 画面遷移は RootView が行う.
        store?.pendingNotificationConversationID = ConversationID(raw)
    }
}
