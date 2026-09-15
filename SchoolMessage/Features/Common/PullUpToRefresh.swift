import SwiftUI
import UIKit

/// 下端でさらに引き上げたときに更新する目印.
///
/// ## なぜ自前で作るか
/// SwiftUI の `.refreshable`(引き下げて更新)は**上端でしか働かない**.
/// 掲示板のスレッドは新しい書き込みが下に増えていくので, 読む人はたいてい
/// 一番下を見ている. そこからわざわざ一番上まで戻って引き下げるのは遠いため,
/// 「下端からさらに引き上げる」で更新できるようにする.
///
/// ## 作り
/// スクロールの中に置くと, 自分が入っている `UIScrollView` を親からたどって
/// 見つけ, スクロール位置を見張る. 位置の計算を UIKit 側の数値
/// (`contentSize` と `adjustedContentInset`)で行うので, 安全領域や
/// 入力欄の差し込みがあってもずれない.
///
/// スクロールの担当(delegate)は SwiftUI が握っているため, 横取りせずに
/// 値の変化を見張るだけ(KVO)にしている.
struct PullUpToRefresh: UIViewRepresentable {

    /// これだけ引き上げたら更新する.
    private static let threshold: CGFloat = 80

    let action: () -> Void

    /// 親のスクロールに載った瞬間に見張りを始めるための入れ物.
    ///
    /// 描画のたびに確かめるだけだと, まだ親に組み込まれていない時点で
    /// 呼ばれて見つけ損ねることがあるため, 載ったことを知らせてくれる
    /// `didMoveToWindow` も使う.
    final class SentinelView: UIView {
        /// 見張りを始める処理. UIKit の呼び出しはメインスレッドなので
        /// `@MainActor` を明示しておく.
        var onAttach: (@MainActor () -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttach?()
        }
    }

    func makeUIView(context: Context) -> SentinelView {
        let view = SentinelView(frame: .zero)
        // 目印そのものは何も出さないし, タップも受けない.
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear

        let coordinator = context.coordinator
        view.onAttach = { [weak view] in
            guard let view else { return }
            coordinator.startObserving(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: SentinelView, context: Context) {
        context.coordinator.action = action
        context.coordinator.startObserving(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: Self.threshold)
    }

    @MainActor
    final class Coordinator {

        var action: () -> Void = {}

        private let threshold: CGFloat
        /// 持っている間だけ見張る. 破棄されると自動で外れる.
        private var observation: NSKeyValueObservation?
        /// 引き上げ 1 回につき 1 度だけ更新する(指を戻すまで繰り返さない).
        private var hasTriggered = false

        init(threshold: CGFloat) {
            self.threshold = threshold
        }

        func startObserving(from view: UIView) {
            guard observation == nil, let scrollView = Self.enclosingScrollView(of: view) else { return }
            // 自分が見張りを持ち, 見張りが自分を呼ぶので, 弱い参照にして輪を切る.
            observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                // スクロールの通知はメインスレッドで来る.
                MainActor.assumeIsolated {
                    self?.handle(scrollView)
                }
            }
        }

        private func handle(_ scrollView: UIScrollView) {
            let insets = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - insets.top - insets.bottom
            // 中身が画面に収まりきっているときは, 下端の引き上げが起きない.
            guard visibleHeight > 0, scrollView.contentSize.height > visibleHeight else { return }

            // 下端をどれだけ超えて引き上げたか.
            let bottomEdge = scrollView.contentOffset.y + scrollView.bounds.height - insets.bottom
            let overscroll = bottomEdge - scrollView.contentSize.height

            if overscroll > threshold {
                guard !hasTriggered else { return }
                hasTriggered = true
                action()
            } else if overscroll < threshold / 2 {
                // 指を戻したら, 次の引き上げでまた更新できるようにする.
                hasTriggered = false
            }
        }

        private static func enclosingScrollView(of view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }
    }
}
