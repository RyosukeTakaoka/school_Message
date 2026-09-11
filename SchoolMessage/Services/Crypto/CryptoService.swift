import Foundation
import CryptoKit

/// 会話鍵を受信者ごとに封緘したもの.
///
/// 送信側はその都度使い捨ての X25519 鍵ペア(ephemeral)を作り, 受信者の公開鍵と
/// 鍵合意する. 受信者は自分の長期秘密鍵と `ephemeralPublicKey` から同じ共有秘密を
/// 導出できる. 送信者の秘密鍵が後に漏れても, この 1 回分の鍵は復元されない.
struct WrappedConversationKey: Hashable, Sendable, Codable {
    var ephemeralPublicKey: Data
    var ciphertext: Data
}

/// 端末内の鍵管理と暗号化・復号.
///
/// ### なぜアプリ側で暗号化するのか
/// CloudKit の Public Database には行単位のアクセス制御が無い. レコードの
/// 読み取り権限は「レコードタイプ単位」でしか設定できないため, チャットを
/// 成立させるために読み取りを許可すると, 同じコンテナを使うすべてのユーザが
/// 全メッセージを取得できてしまう(改造クライアントを想定すると, アプリ側で
/// 絞り込むだけでは防御にならない).
///
/// そこで本文とメディアは会話鍵で暗号化し, 会話鍵は参加者の公開鍵でのみ
/// 開けられる形で配る. これにより「グループ外のユーザがグループメッセージを
/// 取得できない(取得できても読めない)」を満たす.
actor CryptoService {

    enum CryptoError: LocalizedError {
        case invalidPublicKey
        case unwrapFailed
        case sealFailed
        case openFailed

        var errorDescription: String? {
            switch self {
            case .invalidPublicKey:
                String(localized: "相手の暗号鍵が正しくありません")
            case .unwrapFailed:
                String(localized: "チャットの鍵を開けませんでした")
            case .sealFailed:
                String(localized: "メッセージを暗号化できませんでした")
            case .openFailed:
                String(localized: "メッセージを復号できませんでした")
            }
        }
    }

    private enum Account {
        static let identityPrivateKey = "identity.x25519.private"
        static func conversationKey(_ id: ConversationID) -> String { "conversation.key.\(id.rawValue)" }
    }

    /// HKDF のソルト. 固定値だが, 用途分離が目的なので秘密である必要はない.
    private static let keyWrapSalt = Data("SchoolMessage.KeyWrap.v1".utf8)

    private let keychain: KeychainStore
    private var cachedIdentityKey: Curve25519.KeyAgreement.PrivateKey?
    private var cachedConversationKeys: [ConversationID: SymmetricKey] = [:]

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: - 長期鍵

    /// 長期鍵を取り出す. 無ければ生成して保存する.
    private func identityKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let cachedIdentityKey { return cachedIdentityKey }

        if let stored = try keychain.data(forAccount: Account.identityPrivateKey, protection: .synchronized) {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
            cachedIdentityKey = key
            return key
        }

        let key = Curve25519.KeyAgreement.PrivateKey()
        try keychain.set(key.rawRepresentation, forAccount: Account.identityPrivateKey, protection: .synchronized)
        cachedIdentityKey = key
        Log.crypto.info("generated new identity key")
        return key
    }

    /// プロフィールに載せる公開鍵.
    func identityPublicKeyData() throws -> Data {
        try identityKey().publicKey.rawRepresentation
    }

    /// ログアウト時に鍵を破棄する.
    ///
    /// 長期鍵まで消すと過去の会話が二度と読めなくなるため, ここでは
    /// 会話鍵のキャッシュのみを消す. 長期鍵は同じ Apple ID で再ログインしたときに
    /// 再利用する.
    func clearCachedConversationKeys() {
        cachedConversationKeys.removeAll()
    }

    /// 端末から鍵をすべて消す(端末の譲渡など, 明示的に要求されたときのみ).
    func destroyAllKeys() throws {
        cachedIdentityKey = nil
        cachedConversationKeys.removeAll()
        try keychain.removeAll()
    }

    // MARK: - 会話鍵

    func makeConversationKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// 会話鍵を受信者の公開鍵に向けて封緘する.
    func wrap(_ key: SymmetricKey, forRecipientPublicKey publicKeyData: Data) throws -> WrappedConversationKey {
        let recipientKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.keyWrapSalt,
            sharedInfo: ephemeral.publicKey.rawRepresentation + publicKeyData,
            outputByteCount: 32
        )

        let keyBytes = key.withUnsafeBytes { Data($0) }
        guard let sealed = try? AES.GCM.seal(keyBytes, using: wrappingKey).combined else {
            throw CryptoError.sealFailed
        }
        return WrappedConversationKey(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealed
        )
    }

    /// 自分宛に封緘された会話鍵を開ける.
    func unwrap(_ wrapped: WrappedConversationKey) throws -> SymmetricKey {
        let identity = try identityKey()
        let ephemeralPublic: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: wrapped.ephemeralPublicKey)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        let sharedSecret = try identity.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.keyWrapSalt,
            sharedInfo: wrapped.ephemeralPublicKey + identity.publicKey.rawRepresentation,
            outputByteCount: 32
        )

        guard
            let box = try? AES.GCM.SealedBox(combined: wrapped.ciphertext),
            let raw = try? AES.GCM.open(box, using: wrappingKey)
        else {
            throw CryptoError.unwrapFailed
        }
        return SymmetricKey(data: raw)
    }

    /// 開けた会話鍵をキャッシュしておく(毎回 CloudKit から取りに行かないため).
    func cache(_ key: SymmetricKey, for conversationID: ConversationID) {
        cachedConversationKeys[conversationID] = key
        let raw = key.withUnsafeBytes { Data($0) }
        try? keychain.set(raw, forAccount: Account.conversationKey(conversationID))
    }

    func cachedKey(for conversationID: ConversationID) -> SymmetricKey? {
        if let inMemory = cachedConversationKeys[conversationID] { return inMemory }
        // `try?` は入れ子の Optional を平坦化するため, 1 回の束縛で Data が得られる.
        guard let stored = try? keychain.data(forAccount: Account.conversationKey(conversationID)) else {
            return nil
        }
        let key = SymmetricKey(data: stored)
        cachedConversationKeys[conversationID] = key
        return key
    }

    func forgetKey(for conversationID: ConversationID) {
        cachedConversationKeys.removeValue(forKey: conversationID)
        try? keychain.removeItem(forAccount: Account.conversationKey(conversationID))
    }

    // MARK: - 公開鍵宛ての封緘(自分専用のデータを作るのにも使う)

    /// 任意のバイト列を, 指定した公開鍵でしか開けない形に封緘する.
    ///
    /// `wrap` は会話鍵(`SymmetricKey`)専用だが, こちらは汎用のバイト列向け.
    /// 「自分の公開鍵宛てに封じる」ことで, 自分以外(同じ会話の相手を含む)には
    /// 開けないデータを作れる. 色勝負で「自分の手札は自分にしか見えない」を
    /// 実現するのに使う(会話鍵は参加者全員が持つため, 会話鍵での暗号化だけでは
    /// 特定の 1 人にだけ見せる, ということができない).
    func sealToPublicKey(_ data: Data, recipientPublicKey publicKeyData: Data) throws -> WrappedConversationKey {
        let recipientKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.keyWrapSalt,
            sharedInfo: ephemeral.publicKey.rawRepresentation + publicKeyData,
            outputByteCount: 32
        )

        guard let sealed = try? AES.GCM.seal(data, using: wrappingKey).combined else {
            throw CryptoError.sealFailed
        }
        return WrappedConversationKey(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealed
        )
    }

    /// 自分の公開鍵宛てに `sealToPublicKey` で封じたバイト列を, 自分の秘密鍵で開ける.
    func openSealedToSelf(_ wrapped: WrappedConversationKey) throws -> Data {
        let identity = try identityKey()
        let ephemeralPublic: Curve25519.KeyAgreement.PublicKey
        do {
            ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: wrapped.ephemeralPublicKey)
        } catch {
            throw CryptoError.invalidPublicKey
        }

        let sharedSecret = try identity.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let wrappingKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.keyWrapSalt,
            sharedInfo: wrapped.ephemeralPublicKey + identity.publicKey.rawRepresentation,
            outputByteCount: 32
        )

        guard
            let box = try? AES.GCM.SealedBox(combined: wrapped.ciphertext),
            let raw = try? AES.GCM.open(box, using: wrappingKey)
        else {
            throw CryptoError.openFailed
        }
        return raw
    }

    // MARK: - ペイロードの暗号化

    func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try? AES.GCM.seal(data, using: key).combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard
            let box = try? AES.GCM.SealedBox(combined: data),
            let plaintext = try? AES.GCM.open(box, using: key)
        else {
            throw CryptoError.openFailed
        }
        return plaintext
    }

    /// ファイルを暗号化して別ファイルに書き出す.
    /// 上限サイズを設けているため一括読み込みで足りる(`MediaLimits` を参照).
    func sealFile(at source: URL, to destination: URL, with key: SymmetricKey) throws {
        let plaintext = try Data(contentsOf: source, options: .mappedIfSafe)
        let ciphertext = try seal(plaintext, with: key)
        try ciphertext.write(to: destination, options: .atomic)
    }

    /// 暗号化ファイルを復号して別ファイルに書き出す.
    func openFile(at source: URL, to destination: URL, with key: SymmetricKey) throws {
        let ciphertext = try Data(contentsOf: source, options: .mappedIfSafe)
        let plaintext = try open(ciphertext, with: key)
        try plaintext.write(to: destination, options: .atomic)
    }
}
