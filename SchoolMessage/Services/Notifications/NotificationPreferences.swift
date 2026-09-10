import Foundation
import Observation

/// 通知に関するユーザ設定.
///
/// LINEなどと同じく, 種類ごとに個別でオン/オフを選べるようにしている.
/// - メッセージ: 既定でオン. 学校では iPad を机に置いたまま離れることがあり,
///   ロック画面に本文が出ると周囲から読まれてしまうため, 本文表示だけは別に選べる.
/// - すれ違い通信: 既定でオン. すれ違い通信そのものの入り切り(`StreetPassSettings`)
///   とは別で, 「すれ違えたときに通知するか」だけを扱う.
/// - 掲示板: 既定でオフ. 誰の書き込みでも届く共有の場所なので, 望まない人まで
///   毎回通知が来ると煩わしいと考え, 使いたい人だけが選ぶ形にしている.
@MainActor
@Observable
final class NotificationPreferences {

    private enum Key {
        static let messagesEnabled = "notifications.messages.enabled"
        static let showsMessagePreview = "notifications.showsMessagePreview"
        static let streetPassEnabled = "notifications.streetPass.enabled"
        static let boardEnabled = "notifications.board.enabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // 観測対象の実体. `didSet` は `@Observable` と併用できないため,
    // 保存は下の計算プロパティの setter で行う.
    private var messagesEnabledStorage: Bool
    private var previewStorage: Bool
    private var streetPassEnabledStorage: Bool
    private var boardEnabledStorage: Bool

    /// 新着メッセージの通知を受け取るか.
    var messagesEnabled: Bool {
        get { messagesEnabledStorage }
        set {
            messagesEnabledStorage = newValue
            defaults.set(newValue, forKey: Key.messagesEnabled)
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

    /// すれ違い通信で相手を見つけたときに通知するか.
    var streetPassEnabled: Bool {
        get { streetPassEnabledStorage }
        set {
            streetPassEnabledStorage = newValue
            defaults.set(newValue, forKey: Key.streetPassEnabled)
        }
    }

    /// 掲示板に新しい書き込みがあったときに通知するか.
    var boardEnabled: Bool {
        get { boardEnabledStorage }
        set {
            boardEnabledStorage = newValue
            defaults.set(newValue, forKey: Key.boardEnabled)
        }
    }

    /// いずれかの種類の通知を使うか. システムへの許可要求(ダイアログ)を
    /// 出すかどうかの判断に使う(1 種類でも使うなら許可は必要なため).
    var isAnyCategoryEnabled: Bool {
        messagesEnabled || streetPassEnabled || boardEnabled
    }

    /// `streetPassEnabled` の生の値. `@MainActor` を跨げない場所
    /// (すれ違い通信の CoreBluetooth コールバックなど)から読むために使う.
    ///
    /// このインスタンスの `init` より先に読まれる可能性がある
    /// (`StreetPassKit` はアプリ起動の最も早い段階でブートストラップされ,
    /// `NotificationPreferences` の生成を待たない)ため, `register(defaults:)`
    /// による既定値の登録には頼らず, 「未設定なら true」をここでも判定する.
    nonisolated static func streetPassEnabledRawValue(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.streetPassEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.streetPassEnabled)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyKeyIfNeeded(defaults)
        // 既定値: メッセージ・すれ違い通信はオン, 掲示板はオフ.
        defaults.register(defaults: [
            Key.messagesEnabled: true,
            Key.showsMessagePreview: true,
            Key.streetPassEnabled: true,
            Key.boardEnabled: false
        ])
        self.messagesEnabledStorage = defaults.bool(forKey: Key.messagesEnabled)
        self.previewStorage = defaults.bool(forKey: Key.showsMessagePreview)
        self.streetPassEnabledStorage = defaults.bool(forKey: Key.streetPassEnabled)
        self.boardEnabledStorage = defaults.bool(forKey: Key.boardEnabled)
    }

    /// 種類ごとに分ける前は, 1 つの `"notifications.enabled"` だけで
    /// 通知の全体をオン/オフしていた. 既にオフにしていた利用者の意思を
    /// 引き継ぐため, 値が残っていれば「メッセージ」の設定として移す.
    private static func migrateLegacyKeyIfNeeded(_ defaults: UserDefaults) {
        let legacyKey = "notifications.enabled"
        guard defaults.object(forKey: legacyKey) != nil else { return }
        defaults.set(defaults.bool(forKey: legacyKey), forKey: Key.messagesEnabled)
        defaults.removeObject(forKey: legacyKey)
    }
}
