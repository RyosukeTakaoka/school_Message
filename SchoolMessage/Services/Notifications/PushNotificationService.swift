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

    init(preferences: NotificationPreferences) {
        self.preferences = preferences
        super.init()
    }

    func attach(store: ChatStore) {
        self.store = store
    }

    // MARK: - 登録

    /// 通知の許可を求め, APNs に登録する.
    ///
    /// 許可が得られなくてもアプリは動く(定期ポーリングで新着に気付く)ので,
    /// 失敗を致命的な扱いにはしない.
    func requestAuthorizationAndRegister() async {
        UNUserNotificationCenter.current().delegate = self

        guard preferences.isEnabled else { return }

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
           preferences.isEnabled,
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
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let raw = userInfo[Self.conversationUserInfoKey] as? String
        return await MainActor.run {
            if let raw, ConversationID(raw) == self.store?.selectedConversationID {
                return []
            }
            return [.banner, .sound, .badge]
        }
    }

    /// 通知をタップした. 対象のチャットを開く.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[Self.conversationUserInfoKey] as? String else { return }
        await MainActor.run {
            // 開くべきチャットをストアに伝える. 画面遷移は RootView が行う.
            self.store?.pendingNotificationConversationID = ConversationID(raw)
        }
    }
}
