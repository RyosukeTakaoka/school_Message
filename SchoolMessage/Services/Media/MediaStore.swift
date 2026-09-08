import Foundation

/// ローカルのメディア置き場.
///
/// 用途で 2 つに分ける.
/// - `outbox`: 送信待ちの圧縮済みファイル. アプリが強制終了しても残す必要があるので
///   Application Support 配下(バックアップ対象外の属性を付与)に置く.
/// - `cache`: ダウンロード済みメディア. 消えても再取得できるので Caches 配下に置き,
///   ストレージ逼迫時に OS が回収するのに任せる.
struct MediaStore: Sendable {

    /// `FileManager` は Sendable ではないので保持しない.
    /// `.default` は複数スレッドからの利用を想定した共有インスタンスなので,
    /// 必要なときに都度取り出す.
    private var fileManager: FileManager { .default }

    let outboxDirectory: URL
    let cacheDirectory: URL
    /// 復号前の一時ファイル用.
    let scratchDirectory: URL

    /// 生成に失敗しない.
    ///
    /// 標準のディレクトリが取得できない状況(まず起きないが)でアプリが起動不能に
    /// なるのは望ましくないので, 一時ディレクトリにフォールバックする.
    init() {
        let fileManager = FileManager.default
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? temporaryRoot
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? temporaryRoot

        self.outboxDirectory = appSupport.appendingPathComponent("Outbox", isDirectory: true)
        self.cacheDirectory = caches.appendingPathComponent("Media", isDirectory: true)
        self.scratchDirectory = caches.appendingPathComponent("Scratch", isDirectory: true)

        for directory in [outboxDirectory, cacheDirectory, scratchDirectory] {
            Self.createDirectoryIfNeeded(directory, fileManager: fileManager)
        }

        // 送信待ちの写真・動画を iCloud バックアップに含めない
        // (端末内の一時データであり, 復元しても送信済みかどうか判断できないため).
        var outbox = outboxDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? outbox.setResourceValues(resourceValues)
    }

    private static func createDirectoryIfNeeded(_ url: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        // 端末ロック中でもバックグラウンドのアップロードが続けられるように
        // `completeUntilFirstUserAuthentication` を使う.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// 送信待ちファイルの保存先.
    func outboxURL(attachmentID: AttachmentID, kind: MediaKind) -> URL {
        outboxDirectory.appendingPathComponent("\(attachmentID.rawValue).\(Self.fileExtension(for: kind))")
    }

    /// ダウンロード済みメディアのキャッシュ先.
    func cachedURL(for reference: MediaReference, kind: MediaKind) -> URL {
        cacheDirectory.appendingPathComponent("\(reference.cacheKey).\(Self.fileExtension(for: kind))")
    }

    func scratchURL(suffix: String) -> URL {
        scratchDirectory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func byteCount(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    func remove(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// 一時ファイルを片付ける. 起動時に呼ぶ.
    func purgeScratch() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: scratchDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Outbox に残っていて, どの送信待ちにも紐づかないファイルを削除する.
    /// (アップロード完了直後にアプリが落ちた場合などのゴミ掃除)
    func purgeOrphanedOutboxFiles(keeping keepIDs: Set<AttachmentID>) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: outboxDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let keepNames = Set(keepIDs.map(\.rawValue))
        for url in contents {
            let base = url.deletingPathExtension().lastPathComponent
            if !keepNames.contains(base) {
                try? fileManager.removeItem(at: url)
                Log.media.debug("purged orphaned outbox file")
            }
        }
    }

    private static func fileExtension(for kind: MediaKind) -> String {
        switch kind {
        case .image: "jpg"
        case .video: "mp4"
        }
    }
}
