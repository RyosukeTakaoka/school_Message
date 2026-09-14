import SwiftUI
import ImageIO

/// GIF のバイト列をアニメーションしたまま表示する.
///
/// SwiftUI 標準の `Image` は, `UIImage.animatedImage(with:duration:)` で
/// 作ったアニメーション画像を渡しても最初の 1 コマしか描画しない
/// (SwiftUI の `Image` はアニメーションを再生する仕組みを持たないため).
/// 実際にコマを再生できるのは `UIImageView` なので, それを直接使う.
struct AnimatedGIFView: UIViewRepresentable {

    let data: Data
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode
        // 同じデータを毎回デコードし直すと重いので, 変わったときだけ処理する.
        guard context.coordinator.loadedData != data else { return }
        context.coordinator.loadedData = data
        uiView.image = Self.decode(data)
        uiView.startAnimating()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedData: Data?
    }

    /// GIF の全コマをデコードし, コマごとの表示時間を持つアニメーション画像を作る.
    /// アニメーションしない(1 コマだけの)GIF はただの静止画として返す.
    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            totalDuration += frameDuration(source: source, index: index)
            frames.append(UIImage(cgImage: cgImage))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(
            with: frames,
            duration: totalDuration > 0 ? totalDuration : Double(frames.count) * 0.1
        )
    }

    /// 1 コマぶんの表示時間(秒).
    /// 主要ブラウザの実装に合わせ, 極端に短い/無効な値は 0.1 秒扱いにする.
    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }
        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }
}
