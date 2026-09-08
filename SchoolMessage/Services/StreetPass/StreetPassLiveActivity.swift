import ActivityKit
import Foundation

/// ロック画面の「すれ違い通信」表示(Live Activity)の出し入れ.
///
/// ## これは成功率を上げる仕組みではない
/// よくある誤解だが, Live Activity は**バックグラウンド実行を与えない**.
/// ロック画面に出る表示であって, アプリを動かし続ける仕組みではないので,
/// Bluetooth の成功率そのものは 1% も変わらない.
///
/// 効くのは別の経路.
/// - ロック画面に「すれ違い通信 ON / 今日 3 人」と出ていれば,
///   **利用者がアプリを上スワイプで終了させにくくなる**.
///   強制終了された後のすれ違いは実装では救えないので,
///   「起こさせない」ことが唯一の緩和策になる
/// - すれ違いで起こされたその実行機会に表示を更新できるので,
///   アプリを開かずに今日の人数が分かる
///
/// ## 始められるのは前面にいるときだけ
/// ActivityKit の決まりで, **開始は前面からしかできない**(更新と終了は
/// バックグラウンドからでもできる). そのため
/// - 開始: 利用者がすれ違い通信を入れたとき / 前面に戻ったとき
/// - 更新: すれ違ったとき(バックグラウンドで起こされた場合も含む)
/// - 終了: すれ違い通信を切ったとき
/// という形にしている.
///
/// ## 表示が出ない場合
/// Widget Extension が無い, 端末や設定が対応していない, といった理由で
/// 開始に失敗することがある. その場合も**すれ違い通信そのものは通常どおり動く**.
/// 失敗の理由は画面の診断欄に出す.
///
/// メインスレッドからのみ触る前提で `@unchecked Sendable` にしている.
final class StreetPassLiveActivity: @unchecked Sendable {

    /// この時間を過ぎたら「情報が古い」扱いにする.
    /// 更新はすれ違うたびに来るので, 半日ほど余裕を持たせる.
    private static let staleAfter: TimeInterval = 12 * 60 * 60

    private var activity: Activity<StreetPassActivityAttributes>?

    /// 端末と設定がロック画面表示に対応しているか.
    ///
    /// 対応していない端末と, 利用者が設定で切っている場合を区別する方法は無い.
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool {
        activity?.activityState == .active
    }

    /// 開始に失敗した理由(診断用).
    private(set) var lastError: String?

    // MARK: - 出し入れ

    /// すでに出ている表示があれば引き継ぐ.
    ///
    /// バックグラウンドで起こし直された直後は `activity` が空なので,
    /// これをやらないと同じ表示を二重に作ってしまう.
    func adoptExisting() {
        guard activity == nil else { return }
        activity = Activity<StreetPassActivityAttributes>.activities
            .first { $0.activityState == .active }
    }

    /// 表示を出す(前面からのみ). すでに出ていれば内容だけ更新する.
    func start(ownerName: String, state: StreetPassActivityAttributes.ContentState) {
        adoptExisting()
        if activity != nil {
            update(state)
            return
        }
        guard isAvailable else {
            lastError = String(localized: "この端末または設定ではロック画面表示を使えません")
            return
        }

        do {
            activity = try Activity.request(
                attributes: StreetPassActivityAttributes(ownerName: ownerName),
                content: content(state),
                pushType: nil          // 更新はすべて端末の中から行う. サーバは通さない.
            )
            lastError = nil
            Log.streetPass.info("started the live activity")
        } catch {
            // Widget Extension が入っていない場合もここに来る.
            // すれ違い通信そのものは動くので, 記録だけして先へ進む.
            lastError = error.localizedDescription
            Log.streetPass.notice("could not start the live activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 内容を差し替える(バックグラウンドからでもできる).
    func update(_ state: StreetPassActivityAttributes.ContentState) {
        adoptExisting()
        guard let activity else { return }
        let updated = content(state)
        Task { await activity.update(updated) }
    }

    /// 表示を消す.
    func stop() {
        adoptExisting()
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func content(
        _ state: StreetPassActivityAttributes.ContentState
    ) -> ActivityContent<StreetPassActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(Self.staleAfter))
    }
}
