import SwiftUI

/// 全画面ビューア(写真・動画)の「閉じる」「保存」ボタン共通の見た目.
///
/// 以前は `Image(systemName:).symbolRenderingMode(.palette)` の 2 色塗り
/// (前景の白いアイコン + 背景の半透明の円)で表現していたが, これを
/// `UIViewRepresentable`(`ZoomableImageView` の `UIScrollView`)の上に重ねると,
/// 背景の半透明円だけが画像の**裏**に回り込んで見える描画順の不具合があった
/// (アイコン自体は正しく手前に出るが, シンボルの多層合成が UIKit 側の
/// レイヤーとうまく合成されなかったとみられる). シンボルの多層合成に頼らず,
/// 普通の `Circle` を背景にした素朴な構成に変えることで, 常に手前に描画される
/// ようにしてある.
extension View {
    func viewerControlBadge() -> some View {
        self
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: Circle())
    }
}

struct CircleIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .viewerControlBadge()
        }
    }
}

/// 上下にスワイプして閉じる.
///
/// 拡大表示中(ピンチで等倍より大きくしている間)は, 画像をパンする操作と
/// 衝突しないよう働かない(`isZoomedIn` が true の間は無視する).
struct SwipeToDismissModifier: ViewModifier {
    var isZoomedIn: Bool
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    /// これより大きく動かしたら閉じる.
    private static let distanceThreshold: CGFloat = 120
    /// 指を離す速さがこれを超えていれば, 距離が足りなくても閉じる(勢いよく払った場合).
    private static let velocityThreshold: CGFloat = 500

    func body(content: Content) -> some View {
        content
            .offset(y: dragOffset)
            .opacity(1 - min(0.6, abs(dragOffset) / 400))
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !isZoomedIn else { return }
                        // 縦方向の動きが主体のときだけ反応する
                        // (横方向のドラッグは無視して, 他の操作と混同しないようにする).
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        guard !isZoomedIn else {
                            dragOffset = 0
                            return
                        }
                        let farEnough = abs(value.translation.height) > Self.distanceThreshold
                        let fastEnough = abs(value.predictedEndTranslation.height - value.translation.height)
                            > Self.velocityThreshold
                        if farEnough || fastEnough {
                            onDismiss()
                        } else {
                            withAnimation(.interactiveSpring()) { dragOffset = 0 }
                        }
                    }
            )
    }
}

extension View {
    /// 上下スワイプで `onDismiss` を呼ぶ. `isZoomedIn` が true の間は働かない.
    func swipeToDismiss(isZoomedIn: Bool, onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismissModifier(isZoomedIn: isZoomedIn, onDismiss: onDismiss))
    }
}
