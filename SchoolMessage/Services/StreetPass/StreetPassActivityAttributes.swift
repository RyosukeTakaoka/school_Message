import ActivityKit
import Foundation

/// ロック画面に出す「すれ違い通信」の中身.
///
/// ## この型はアプリと Widget Extension の両方から使う
/// ActivityKit は, アプリ側が渡した内容を Widget Extension 側の画面に届ける.
/// 同じ型定義が両方の的(ターゲット)に入っている必要がある.
///
/// Xcode で `StreetPassActivityAttributes.swift` を選び, 右側の
/// **Target Membership** で `StreetPassWidget` にもチェックを入れること.
/// 手順は `docs/LIVE_ACTIVITY.md`.
struct StreetPassActivityAttributes: ActivityAttributes {

    /// 動いている間, 変わっていく部分.
    struct ContentState: Codable, Hashable {
        /// 今日すれ違った人数.
        var todayCount: Int
        /// これまでにすれ違った人数.
        var totalCount: Int
        /// 直近にすれ違った相手の名前.
        var latestName: String?
        /// 直近にすれ違った時刻.
        var latestAt: Date?
    }

    /// 始めるときに決まり, 以降変わらない部分.
    var ownerName: String
}
