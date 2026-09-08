import Foundation

/// すれ違い通信の設定と, 起動直後に必要な「自分の名刺」の控え.
///
/// ## なぜ名刺の控えを持つのか
/// Bluetooth に起こされた起動では, iCloud からプロフィールを読み終わるより先に
/// 電波を出し始める必要がある. 読み終わるのを待つと, 起こされた理由である
/// そのすれ違い自体を取りこぼす.
///
/// そこで最後に分かっていた名刺をここに残し, 起動直後はそれを配る.
/// 本物のプロフィールが読めたら差し替える.
///
/// メインスレッドからのみ触る前提で `@unchecked Sendable` にしている
/// (CoreBluetooth の通知もメインスレッドで受けるため, 実際に競合しない).
final class StreetPassSettings: @unchecked Sendable {

    private enum Key {
        static let isEnabled = "streetpass.enabled"
        static let comment = "streetpass.comment"
        static let cardData = "streetpass.card"
        static let restoreCount = "streetpass.restoreCount"
        static let lastRestoredAt = "streetpass.lastRestoredAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    var comment: String {
        get { defaults.string(forKey: Key.comment) ?? "" }
        set { defaults.set(String(newValue.prefix(StreetPassCard.commentMaxLength)), forKey: Key.comment) }
    }

    /// 起動直後に配る名刺(JSON).
    var cardData: Data? {
        get { defaults.data(forKey: Key.cardData) }
        set { defaults.set(newValue, forKey: Key.cardData) }
    }

    var card: StreetPassCard? {
        cardData.flatMap { StreetPassCard.decoded(from: $0) }
    }

    // MARK: - 診断
    //
    // 「バックグラウンドでも本当に動いているのか」は, 動いていないことの
    // 証明が難しい. 復元された回数を残しておくと, 画面で確かめられる.

    /// 更新は `noteRestored()` から行う.
    var restoreCount: Int {
        get { defaults.integer(forKey: Key.restoreCount) }
        set { defaults.set(newValue, forKey: Key.restoreCount) }
    }

    var lastRestoredAt: Date? {
        get { defaults.object(forKey: Key.lastRestoredAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRestoredAt) }
    }

    func noteRestored(at date: Date = .now) {
        restoreCount += 1
        lastRestoredAt = date
    }
}
