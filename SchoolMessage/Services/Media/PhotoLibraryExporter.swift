import Foundation
import Photos

/// ダウンロード済みの写真・動画を「写真」アプリに保存する.
///
/// チャットのメディアは復号後もアプリのキャッシュ領域にしか残らないため,
/// 他のアプリで見返したり誰かに送ったりするには, 明示的に写真ライブラリへ
/// 書き出す必要がある. 読み取り専用の `NSPhotoLibraryUsageDescription`
/// (送信用に選ぶとき)とは別に, 追加専用の `NSPhotoLibraryAddUsageDescription`
/// を使う(ライブラリ全体を読む必要が無いため).
enum PhotoLibraryExporter {

    /// 保存先の許可を確認し, 無ければ求める.
    private static func ensureAddOnlyAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let requested = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return requested == .authorized || requested == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// 端末内のファイルを写真ライブラリへコピーする(画像・動画共通).
    static func save(fileAt url: URL, kind: MediaKind) async throws {
        guard await ensureAddOnlyAccess() else {
            throw AppError.photoLibraryAccessDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                switch kind {
                case .image:
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
        } catch {
            throw AppError.mediaSaveFailed
        }
    }
}
