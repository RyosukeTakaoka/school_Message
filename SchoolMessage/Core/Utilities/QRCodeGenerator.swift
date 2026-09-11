import CoreImage.CIFilterBuiltins
import UIKit

/// 文字列から QR コード画像を作る.
enum QRCodeGenerator {

    /// - Parameter scale: 生成される画像の粗さの倍率. QR コードは元々小さい
    ///   画素数で作られるため, そのまま拡大表示するとぼやける. 描画前に
    ///   ここで拡大しておくことで, 画面上でくっきり出す.
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
