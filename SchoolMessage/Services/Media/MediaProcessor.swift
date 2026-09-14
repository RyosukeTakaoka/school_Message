import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics

/// 選択された写真・動画を「送信できる形」に変換する.
///
/// 実行時間の長い処理なので actor に閉じ込め, メインスレッドを止めない.
/// 出来上がるのは常に `OutgoingMessage.LocalMedia`(圧縮済み本体 + サムネイル)で,
/// これ以降の層は元ファイルを一切意識しない.
actor MediaProcessor {

    private let store: MediaStore

    init(store: MediaStore) {
        self.store = store
    }

    // MARK: - 画像

    /// 元画像データから送信用の画像を作る.
    func prepareImage(
        originalData: Data,
        attachmentID: AttachmentID = .generate()
    ) throws -> OutgoingMessage.LocalMedia {
        guard let downsampled = Self.downsample(
            data: originalData,
            maxPixelEdge: MediaLimits.imageMaxPixelEdge
        ) else {
            throw AppError.unsupportedMedia
        }

        guard let jpegData = Self.encodeJPEG(
            downsampled,
            targetByteCount: MediaLimits.imageMaxByteCount
        ) else {
            throw AppError.mediaProcessingFailed
        }

        guard jpegData.count <= MediaLimits.imageMaxByteCount else {
            throw AppError.mediaTooLarge(limitMB: MediaLimits.megabytes(MediaLimits.imageMaxByteCount))
        }

        let destination = store.outboxURL(attachmentID: attachmentID, kind: .image)
        try jpegData.write(to: destination, options: .atomic)

        let thumbnail = Self.makeThumbnailData(from: downsampled) ?? Data()

        return OutgoingMessage.LocalMedia(
            attachmentID: attachmentID,
            kind: .image,
            fileURL: destination,
            thumbnailData: thumbnail,
            pixelWidth: Int(downsampled.size.width * downsampled.scale),
            pixelHeight: Int(downsampled.size.height * downsampled.scale),
            duration: nil,
            byteCount: jpegData.count
        )
    }

    /// プロフィール画像 / グループ画像用の小さな JPEG を作る.
    func prepareAvatarData(originalData: Data) throws -> Data {
        guard let image = Self.downsample(
            data: originalData,
            maxPixelEdge: MediaLimits.avatarMaxPixelEdge
        ) else {
            throw AppError.unsupportedMedia
        }
        guard let data = Self.encodeJPEG(image, targetByteCount: MediaLimits.avatarMaxByteCount) else {
            throw AppError.mediaProcessingFailed
        }
        return data
    }

    // MARK: - 動画

    /// 元動画を H.264 / 540p 相当に再エンコードし, サムネイルを添えて返す.
    func prepareVideo(
        sourceURL: URL,
        attachmentID: AttachmentID = .generate()
    ) async throws -> OutgoingMessage.LocalMedia {
        let asset = AVURLAsset(url: sourceURL)

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw AppError.unsupportedMedia }
        guard seconds <= MediaLimits.videoMaxDuration else {
            throw AppError.videoTooLong(limitSeconds: Int(MediaLimits.videoMaxDuration))
        }

        let destination = store.outboxURL(attachmentID: attachmentID, kind: .video)
        store.remove(at: destination) // 既存ファイルがあると export が失敗する

        try await Self.export(asset: asset, to: destination)

        let byteCount = store.byteCount(at: destination)
        guard byteCount > 0 else { throw AppError.mediaProcessingFailed }
        guard byteCount <= MediaLimits.videoMaxByteCount else {
            store.remove(at: destination)
            throw AppError.mediaTooLarge(limitMB: MediaLimits.megabytes(MediaLimits.videoMaxByteCount))
        }

        let exported = AVURLAsset(url: destination)
        let pixelSize = try await Self.naturalPixelSize(of: exported)
        let thumbnail = await Self.videoThumbnailData(from: exported)

        return OutgoingMessage.LocalMedia(
            attachmentID: attachmentID,
            kind: .video,
            fileURL: destination,
            thumbnailData: thumbnail ?? Data(),
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height),
            duration: seconds,
            byteCount: byteCount
        )
    }

    // MARK: - 実装詳細

    /// ImageIO で元画像を全解像度展開せずに縮小する.
    /// `UIImage(data:)` からの `draw(in:)` と違い, 巨大な写真でもメモリが跳ねない.
    private static func downsample(data: Data, maxPixelEdge: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // EXIF の向きを反映させる. これを省くと横向き写真が回って表示される.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 目標サイズに収まるまで品質を落として JPEG 化する.
    private static func encodeJPEG(_ image: UIImage, targetByteCount: Int) -> Data? {
        var quality = MediaLimits.imageCompressionQuality
        var data = image.jpegData(compressionQuality: quality)

        while let current = data,
              current.count > targetByteCount,
              quality > MediaLimits.imageMinimumCompressionQuality {
            quality -= 0.1
            data = image.jpegData(compressionQuality: quality)
        }
        return data
    }

    private static func makeThumbnailData(from image: UIImage) -> Data? {
        let maxEdge = MediaLimits.thumbnailMaxPixelEdge
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return encodeJPEG(resized, targetByteCount: MediaLimits.thumbnailMaxByteCount)
    }

    private static func export(asset: AVAsset, to destination: URL) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset960x540
        ) else {
            throw AppError.unsupportedMedia
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        // 位置情報などのメタデータを落とす. 写真に写った場所が意図せず共有されるのを防ぐ.
        session.metadata = []
        session.shouldOptimizeForNetworkUse = true

        // iOS 18 で追加された async 版 `export(to:as:)` は使わず, iOS 17 でも動く
        // コールバック版を継続に包む. `resume` が二重に呼ばれないよう完了は 1 回だけ.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            let message = session.error?.localizedDescription
            Log.media.error("video export failed: \(message ?? "unknown", privacy: .public)")
            throw AppError.mediaProcessingFailed
        }
    }

    private static func naturalPixelSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.unsupportedMedia
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // 縦位置で撮った動画は naturalSize が横のままなので, 変換行列を適用して実表示サイズを得る.
        let transformed = naturalSize.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func videoThumbnailData(from asset: AVAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: MediaLimits.thumbnailMaxPixelEdge,
            height: MediaLimits.thumbnailMaxPixelEdge
        )
        // 先頭フレームは暗転していることがあるので少しだけ進める.
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let image = UIImage(cgImage: result.image)
        return encodeJPEG(image, targetByteCount: MediaLimits.thumbnailMaxByteCount)
    }
}
