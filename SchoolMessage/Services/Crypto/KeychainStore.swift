import Foundation
import Security

/// Keychain への薄いラッパ.
///
/// 秘密鍵をファイルや UserDefaults に置くと, バックアップやファイル共有経由で
/// 流出しうるため Keychain に置く.
///
/// 項目ごとに保護レベルを選べるようにしている.
/// - 本人確認用の長期鍵は `.synchronized` (iCloud Keychain 同期). 機種変更や
///   2 台目の iPad でも同じ鍵が使え, 過去の会話を復号できる.
/// - 会話鍵のキャッシュは `.deviceOnly`. 失っても CloudKit 上のラップ済み鍵から
///   復元できるので, 端末外に出す必要がない.
struct KeychainStore: Sendable {

    enum Protection: Sendable {
        /// この端末のみ. 端末を初期化すると失われる.
        case deviceOnly
        /// iCloud Keychain で同じ Apple ID の端末間に同期する.
        case synchronized
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataCorrupted

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                String(localized: "キーチェーンの操作に失敗しました (コード \(Int(status)))")
            case .dataCorrupted:
                String(localized: "保存された鍵が壊れています")
            }
        }
    }

    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.schoolmessage.app") + ".keys") {
        self.service = service
    }

    private func baseQuery(account: String, protection: Protection) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // synchronizable は検索条件としても効くため, 読み書き双方で一致させる.
        query[kSecAttrSynchronizable as String] = (protection == .synchronized)
        return query
    }

    private func accessibility(for protection: Protection) -> CFString {
        switch protection {
        case .deviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .synchronized:
            // 同期対象の項目に ThisDeviceOnly は指定できない.
            kSecAttrAccessibleAfterFirstUnlock
        }
    }

    func data(forAccount account: String, protection: Protection = .deviceOnly) throws -> Data? {
        var query = baseQuery(account: account, protection: protection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.dataCorrupted }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func set(_ data: Data, forAccount account: String, protection: Protection = .deviceOnly) throws {
        let query = baseQuery(account: account, protection: protection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: protection)
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func removeItem(forAccount account: String, protection: Protection = .deviceOnly) throws {
        let status = SecItemDelete(baseQuery(account: account, protection: protection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// このサービスに属する項目をすべて消す(ログアウト時).
    ///
    /// 同期対象と非同期対象は別々に削除する必要がある
    /// (`kSecAttrSynchronizable` を省くと非同期項目だけが対象になるため).
    func removeAll() throws {
        for synchronizable in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: synchronizable
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }
}
