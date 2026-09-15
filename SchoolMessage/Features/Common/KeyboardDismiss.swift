import SwiftUI
import UIKit

/// キーボードを閉じる.
///
/// 入力欄は画面によって作りが違う(SwiftUI の `TextField` と, 自前の `UITextView`)
/// ため, どちらにも効くよう「いま入力中のものを終わらせる」という UIKit の
/// 仕組みをそのまま呼ぶ. 画面ごとにフォーカス用の状態を配線して回るより単純で,
/// 入力欄が増えても手を入れずに済む.
enum KeyboardDismisser {
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

/// 「入力欄以外をタップしたらキーボードを閉じる」をアプリ全体で効かせる仕組み.
///
/// ## 画面ごとに付けない理由
/// 画面ごとにタップ判定を足して回ると, 付け忘れた画面だけ閉じられない, という
/// ちぐはぐな状態になりやすい. 窓(`UIWindow`)に 1 つだけタップ認識を足せば,
/// チャット・掲示板・プロフィール・グループ作成など, どの画面でも同じように
/// 閉じられる.
///
/// ## 既存の操作を邪魔しない工夫
/// - `cancelsTouchesInView = false`: タップを横取りしないので, ボタンや行の
///   タップはこれまで通り通る.
/// - `shouldReceive touch:`: 入力欄の上のタップでは何もしない. ここを抜くと,
///   入力欄をタップした瞬間に閉じてしまい, 文字が打てなくなる.
@MainActor
final class KeyboardDismissGesture: NSObject, UIGestureRecognizerDelegate {

    static let shared = KeyboardDismissGesture()

    /// この窓に付けたことが分かるよう, 専用の型にしておく(二重に付けない判定に使う).
    private final class Recognizer: UITapGestureRecognizer {}

    func attach(to window: UIWindow) {
        let isAlreadyAttached = window.gestureRecognizers?.contains { $0 is Recognizer } ?? false
        guard !isAlreadyAttached else { return }

        let tap = Recognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        KeyboardDismisser.dismiss()
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let view = touch.view else { return true }
        return !Self.isTextInput(view)
    }

    /// ボタンやスクロールなど, ほかの操作と同時に成立してよい.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// タップされたのが入力欄(またはその中)か.
    private static func isTextInput(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate is UITextField || candidate is UITextView { return true }
            current = candidate.superview
        }
        return false
    }
}

private struct KeyboardDismissAttacher: UIViewRepresentable {

    /// 窓に載った瞬間に仕掛ける.
    ///
    /// 作られた時点ではまだ窓が決まっていないので, 窓に載ったことを知らせて
    /// くれる `didMoveToWindow` を使う(描画のたびに確かめる形だと,
    /// 再描画が起きない画面で付け損ねることがある).
    final class AttachingView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window = self.window else { return }
            KeyboardDismissGesture.shared.attach(to: window)
        }
    }

    func makeUIView(context: Context) -> AttachingView {
        let view = AttachingView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: AttachingView, context: Context) {
        guard let window = uiView.window else { return }
        KeyboardDismissGesture.shared.attach(to: window)
    }
}

extension View {
    /// この画面が載っている窓に「入力欄以外をタップしたら閉じる」を仕込む.
    /// アプリの一番外側で 1 回だけ呼べばよい.
    func dismissesKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissAttacher().frame(width: 0, height: 0))
    }
}
