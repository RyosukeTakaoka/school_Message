import Foundation
import Observation

/// 通知に関するユーザ設定.
///
/// 学校では iPad を机に置いたまま離れることがあり, ロック画面に本文が出ると
/// 周囲から読まれてしまう. そのため「本文を出すか」を利用者が選べるようにする.
@MainActor
@Observable
final class NotificationPreferences {

    private enum Key {
        static let isEnabled = "notifications.enabled"
        static let showsMessagePreview = "notifications.showsMessagePreview"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // 観測対象の実体. `didSet` は `@Observable` と併用できないため,
    // 保存は下の計算プロパティの setter で行う.
    private var enabledStorage: Bool
    private var previewStorage: Bool

    /// 通知そのものを受け取るか.
    var isEnabled: Bool {
        get { enabledStorage }
        set {
            enabledStorage = newValue
            defaults.set(newValue, forKey: Key.isEnabled)
        }
    }

    /// 通知に本文(または「写真」「動画」)を出すか.
    /// off のときは送信者名だけを出す.
    var showsMessagePreview: Bool {
        get { previewStorage }
        set {
            previewStorage = newValue
            defaults.set(newValue, forKey: Key.showsMessagePreview)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 既定値は「通知あり・本文あり」.
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.showsMessagePreview: true
        ])
        self.enabledStorage = defaults.bool(forKey: Key.isEnabled)
        self.previewStorage = defaults.bool(forKey: Key.showsMessagePreview)
    }
}
