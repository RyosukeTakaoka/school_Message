import Foundation
import CoreGraphics

/// 写真・動画の上限と圧縮の目標値.
///
/// 元ファイルをそのまま送らないのは 3 つの理由による.
/// 1. 学校の Wi-Fi は共有帯域で, 数十 MB の送信が他の生徒の通信を圧迫する.
/// 2. CloudKit の無料枠(コンテナ全体の転送量)を数人の動画で使い切ってしまう.
/// 3. 受信側の表示が遅くなり「すぐ見られる」という体験を損なう.
enum MediaLimits {

    // MARK: 画像

    /// 長辺の上限. iPad Pro 12.9" の実表示は約 2732px だが, チャット内では
    /// 最大でも画面の半分程度なので 1600px あれば拡大表示でも十分.
    static let imageMaxPixelEdge: CGFloat = 1600

    /// JPEG 圧縮品質.
    static let imageCompressionQuality: CGFloat = 0.8

    /// 圧縮後の画像の上限. 超えたら品質を落として再試行する.
    static let imageMaxByteCount = 3 * 1024 * 1024

    /// 品質を落として再試行するときの下限品質.
    static let imageMinimumCompressionQuality: CGFloat = 0.4

    // MARK: 動画

    /// 送信できる動画の長さの上限.
    static let videoMaxDuration: TimeInterval = 60

    /// 圧縮後の動画の上限.
    static let videoMaxByteCount = 25 * 1024 * 1024

    // MARK: サムネイル

    /// 一覧・吹き出しで先に出す小さな画像の長辺.
    static let thumbnailMaxPixelEdge: CGFloat = 320

    static let thumbnailCompressionQuality: CGFloat = 0.6

    /// サムネイルはメッセージレコードに同梱するので, レコードを重くしない範囲に抑える.
    static let thumbnailMaxByteCount = 120 * 1024

    // MARK: プロフィール / グループ画像

    static let avatarMaxPixelEdge: CGFloat = 512
    static let avatarMaxByteCount = 400 * 1024

    // MARK: 表示用

    static func megabytes(_ byteCount: Int) -> Int {
        max(1, byteCount / (1024 * 1024))
    }

    static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()

    static func formatted(byteCount: Int) -> String {
        byteCountFormatter.string(fromByteCount: Int64(byteCount))
    }
}
