import Foundation
import CoreGraphics

/// リモートに保存されたバイト列への参照.
///
/// CloudKit の `CKAsset` は `CKRecord` から切り離すと fileURL が無効になるため,
/// 「どのレコードのどのフィールドか」だけを保持し, 実体は必要になった時点で取得する.
struct MediaReference: Hashable, Sendable, Codable {
    /// 添付が乗っている CKRecord の recordName.
    let recordName: String
    /// レコード内のフィールド名(本体 / サムネイル).
    let fieldName: String
    /// バイト数(概算). ダウンロード前に容量を提示するために使う.
    let byteCount: Int

    init(recordName: String, fieldName: String, byteCount: Int) {
        self.recordName = recordName
        self.fieldName = fieldName
        self.byteCount = byteCount
    }

    /// ローカルキャッシュのファイル名として使える一意なキー.
    var cacheKey: String {
        "\(recordName)_\(fieldName)"
    }
}

/// 写真・動画の種別.
enum MediaKind: String, Hashable, Sendable, Codable, CaseIterable {
    case image
    case video
}

/// メッセージに添付された写真または動画.
///
/// `remote` が nil の間はまだアップロードされていない(送信中/失敗)状態.
/// `localURL` は自分が送ったもの, または一度ダウンロードしたもののキャッシュ位置.
struct MediaAttachment: Identifiable, Hashable, Sendable {

    let id: AttachmentID
    let kind: MediaKind

    /// 本体(圧縮済み・暗号化済み)の参照.
    var remote: MediaReference?
    /// 一覧で即座に出すための小さなサムネイルの参照.
    var remoteThumbnail: MediaReference?

    /// 復号済みの本体のローカル位置(キャッシュ). アプリ再起動で消えても再取得できる.
    var localURL: URL?
    /// 復号済みサムネイルのバイト列. 小さいので直接メモリに載せる.
    var thumbnailData: Data?

    /// 元メディアのピクセルサイズ. 吹き出しのアスペクト比をダウンロード前に確定させる.
    var pixelWidth: Int
    var pixelHeight: Int

    /// 動画の長さ(秒). 画像では nil.
    var duration: TimeInterval?

    /// 本体のバイト数.
    var byteCount: Int

    init(
        id: AttachmentID = .generate(),
        kind: MediaKind,
        remote: MediaReference? = nil,
        remoteThumbnail: MediaReference? = nil,
        localURL: URL? = nil,
        thumbnailData: Data? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval? = nil,
        byteCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.remote = remote
        self.remoteThumbnail = remoteThumbnail
        self.localURL = localURL
        self.thumbnailData = thumbnailData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.byteCount = byteCount
    }

    /// 吹き出しのレイアウトに使う縦横比. 0 除算を避けるため下限を設ける.
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// 動画の長さの表示用文字列 (例: "1:05").
    var formattedDuration: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 暗号化して保存するメディアのメタデータ.
///
/// ピクセルサイズや再生時間も内容の推測材料になりうるので,
/// レコードのプレーンなフィールドではなく暗号化ペイロードに含める.
struct MediaMetadata: Hashable, Sendable, Codable {
    var attachmentID: AttachmentID
    var kind: MediaKind
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: TimeInterval?
    var byteCount: Int
}
