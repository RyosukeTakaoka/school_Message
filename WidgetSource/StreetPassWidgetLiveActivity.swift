import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

/// ロック画面に出す「すれ違い通信」の見た目.
///
/// ## 置き場所
/// このファイルは **Widget Extension(`StreetPassWidget`)** の中身.
/// Xcode で Widget Extension を追加すると同じ名前のひな形が作られるので,
/// それをこの内容で置き換える. 手順は `docs/LIVE_ACTIVITY.md`.
///
/// 中身(`StreetPassActivityAttributes`)は本体アプリと共有する.
/// Xcode でそのファイルの Target Membership に `StreetPassWidget` を足すこと.
///
/// ## 何のために出すのか
/// この表示があってもバックグラウンドの通信は速くならない. 狙いは
/// **「すれ違い通信が動いていることが見えていれば, アプリを上スワイプで
/// 終了させにくくなる」**という一点. 強制終了された後のすれ違いは
/// 実装では救えないので, 起こさせないことが唯一の緩和策になる.
struct StreetPassWidgetLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StreetPassActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.4))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            // iPad に Dynamic Island は無いが, API として必要なので用意する
            // (同じアプリを iPhone に入れたときはこちらが使われる).
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("すれ違い", systemImage: "figure.walk.motion")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("今日 \(context.state.todayCount) 人")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(latestLine(context.state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "figure.walk.motion")
            } compactTrailing: {
                Text("\(context.state.todayCount)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "figure.walk.motion")
            }
        }
    }

    // MARK: - ロック画面

    private func lockScreen(
        _ context: ActivityViewContext<StreetPassActivityAttributes>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.walk.motion")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("すれ違い通信")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(latestLine(context.state))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text("\(context.state.todayCount)")
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("今日")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
    }

    /// 直近の相手, いなければ待機中の案内.
    private func latestLine(_ state: StreetPassActivityAttributes.ContentState) -> String {
        guard let name = state.latestName else {
            return String(localized: "近くの友達を探しています")
        }
        return String(localized: "さいごは \(name)")
    }
}
