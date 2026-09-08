import Foundation

/// 型安全な識別子.
///
/// `String` をそのまま ID として持ち回すと `conversationID` と `senderID` の取り違えが
/// コンパイル時に検出できない. Phantom Type で用途ごとに別の型として扱う.
///
/// `Subject` は値として保持しないため, 実体は `String` ひとつ分のコストしかない.
struct Identifier<Subject: Sendable>: Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// 新規レコード用の識別子を生成する.
    ///
    /// クライアント側で採番することで, 送信前(オフライン)のメッセージにも
    /// 確定した ID を与えられる. これが送信リトライ時の重複排除の土台になる.
    static func generate() -> Self {
        Self(UUID().uuidString)
    }
}

extension Identifier: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension Identifier: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

extension Identifier: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Identifier: CustomStringConvertible {
    var description: String { rawValue }
}

// MARK: - 用途別のタグ

enum UserTag: Sendable {}
enum ConversationTag: Sendable {}
enum MessageTag: Sendable {}
enum AttachmentTag: Sendable {}
enum ThreadTag: Sendable {}
enum PostTag: Sendable {}

/// アプリ内部のユーザ ID. CloudKit の `CKRecord.ID.recordName`(userRecordID) と一致させる.
/// サーバが押印する値と同一にすることで, なりすましをサーバ側の情報だけで検出できる.
typealias UserID = Identifier<UserTag>
typealias ConversationID = Identifier<ConversationTag>
typealias MessageID = Identifier<MessageTag>
typealias AttachmentID = Identifier<AttachmentTag>
typealias ThreadID = Identifier<ThreadTag>
typealias PostID = Identifier<PostTag>
