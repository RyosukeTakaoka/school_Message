import Foundation
import Observation

/// ゲームに関するユーザ設定.
///
/// いまのところ振動(触覚フィードバック)のオン/オフだけを持つ. チンチロ・
/// ブラックジャック・ダウト・インディアンポーカーなど, `GameHaptics` を
/// 使うすべての遊びに共通で効く(ゲームごとの個別設定にはしていない).
@MainActor
@Observable
final class GamePreferences {

    private enum Key {
        static let hapticsEnabled = "games.haptics.enabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // 観測対象の実体. `didSet` は `@Observable` と併用できないため,
    // 保存は下の計算プロパティの setter で行う(`NotificationPreferences` と同じ考え方).
    private var hapticsEnabledStorage: Bool

    /// ゲーム中の振動(触覚フィードバック)を鳴らすか. 既定はオン.
    var hapticsEnabled: Bool {
        get { hapticsEnabledStorage }
        set {
            hapticsEnabledStorage = newValue
            defaults.set(newValue, forKey: Key.hapticsEnabled)
        }
    }

    /// `GameHaptics` は静的な関数で, `@MainActor` の `AppEnvironment` を
    /// 経由せずに呼ばれる(各ゲーム画面から直接呼んでいる). そこから読めるよう,
    /// 同じキーを直接 `UserDefaults` から読む生の値も用意しておく.
    nonisolated static func hapticsEnabledRawValue(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.hapticsEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.hapticsEnabled)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.hapticsEnabled: true])
        self.hapticsEnabledStorage = defaults.bool(forKey: Key.hapticsEnabled)
    }
}
