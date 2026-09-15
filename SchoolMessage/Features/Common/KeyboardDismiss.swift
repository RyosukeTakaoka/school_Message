import SwiftUI

/// キーボードを閉じる.
///
/// 入力欄は画面によって作りが違う(SwiftUI の `TextField` と, 自前の `UITextView`)
/// ため, どちらにも効くよう「いま入力中のものを終わらせる」という UIKit の
/// 仕組みをそのまま呼ぶ. 画面ごとにフォーカス用の状態を配線して回るより単純で,
/// 入力欄が増えても手を入れずに済む.
enum KeyboardDismisser {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

extension View {
    /// 何も無いところをタップしたらキーボードを閉じる.
    ///
    /// `simultaneousGesture` を使うのは, 中に置いてあるボタンや行のタップを
    /// 邪魔しないため(ボタンを押したときも一緒にキーボードが閉じる).
    func dismissesKeyboardOnTap() -> some View {
        simultaneousGesture(
            TapGesture().onEnded { KeyboardDismisser.dismiss() }
        )
    }
}
