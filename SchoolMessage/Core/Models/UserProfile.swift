import Foundation

/// 公開ディレクトリに載るユーザ情報.
///
/// ここに載る情報は「アプリを使う全員が検索できる」前提で設計する.
/// 本文やメディアと違い暗号化しない(検索できなくなるため)ので,
/// 個人を特定しうる情報(本名・メールアドレス・クラス名など)は入れない.
struct UserProfile: Identifiable, Hashable, Sendable {

    /// CloudKit の userRecordID と一致する不変の ID.
    let id: UserID

    /// 検索用の一意なハンドル(例: `tanaka_2a`). 小文字英数字とアンダースコアのみ.
    var handle: String

    /// 画面に出る名前. 重複可.
    var displayName: String

    /// プロフィール画像(JPEG).
    ///
    /// 上限 400KB に圧縮済みで, プロフィールを取得した時点で一緒に届く.
    /// 別途ダウンロードする経路を作るより, そのまま持つほうが表示が速く実装も単純.
    var avatarData: Data?

    /// 会話鍵をこの人に渡すための Curve25519 公開鍵(raw representation).
    ///
    /// `nil` の場合は旧バージョンのクライアントで登録された等の理由で
    /// 鍵交換ができないため, 会話を開始できない旨を UI で伝える.
    var publicKeyData: Data?

    var updatedAt: Date

    init(
        id: UserID,
        handle: String,
        displayName: String,
        avatarData: Data? = nil,
        publicKeyData: Data? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarData = avatarData
        self.publicKeyData = publicKeyData
        self.updatedAt = updatedAt
    }

    /// 暗号化された会話に招待できるか.
    var canReceiveEncryptedMessages: Bool {
        publicKeyData != nil
    }

    /// アバター画像がないときに表示する頭文字.
    var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

// MARK: - 入力値の検証

extension UserProfile {

    enum ValidationError: LocalizedError, Equatable {
        case displayNameEmpty
        case displayNameTooLong(limit: Int)
        case handleTooShort(limit: Int)
        case handleTooLong(limit: Int)
        case handleHasInvalidCharacters

        var errorDescription: String? {
            switch self {
            case .displayNameEmpty:
                String(localized: "表示名を入力してください")
            case .displayNameTooLong(let limit):
                String(localized: "表示名は \(limit) 文字までです")
            case .handleTooShort(let limit):
                String(localized: "ユーザIDは \(limit) 文字以上にしてください")
            case .handleTooLong(let limit):
                String(localized: "ユーザIDは \(limit) 文字までです")
            case .handleHasInvalidCharacters:
                String(localized: "ユーザIDに使えるのは英小文字・数字・_ だけです")
            }
        }
    }

    /// 表示名を検証して正規化した文字列を返す.
    static func validateDisplayName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.displayNameEmpty }
        guard trimmed.count <= AppConstants.Validation.displayNameMaxLength else {
            throw ValidationError.displayNameTooLong(limit: AppConstants.Validation.displayNameMaxLength)
        }
        return trimmed
    }

    /// ハンドルを検証して正規化(小文字化・トリム)した文字列を返す.
    static func validateHandle(_ raw: String) throws -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count >= AppConstants.Validation.handleMinLength else {
            throw ValidationError.handleTooShort(limit: AppConstants.Validation.handleMinLength)
        }
        guard normalized.count <= AppConstants.Validation.handleMaxLength else {
            throw ValidationError.handleTooLong(limit: AppConstants.Validation.handleMaxLength)
        }
        let allowed = AppConstants.Validation.handleAllowedCharacters
        guard normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ValidationError.handleHasInvalidCharacters
        }
        return normalized
    }
}
