import Foundation
import CloudKit

/// `CKRecord` とドメインモデルの変換.
///
/// ここで必ず「作成者の検証」を行う. CloudKit の Public Database では
/// 誰でもレコードを作れるため, レコード内の `senderID` / `ownerID` を
/// そのまま信用するとなりすましが成立してしまう.
/// `creatorUserRecordID` はサーバが押印する値でクライアントから改変できないので,
/// これと突き合わせたレコードだけを採用する.
enum CloudKitMapper {

    enum MappingError: LocalizedError {
        case missingField(String)
        /// `reason` は DEBUG ビルドでのみ画面に表示する診断用の英語メモ.
        /// (どのレコード・どの比較で不一致になったかを, Console.app 無しで
        /// スクリーンショット 1 枚から追えるようにするため)
        case impersonation(reason: String)
        case unknownRecordType(String)

        var errorDescription: String? {
            switch self {
            case .missingField(let name):
                return String(localized: "データの項目 \(name) が欠けています")
            case .impersonation(let reason):
                let base = String(localized: "送信者を確認できないデータを無視しました")
                #if DEBUG
                return "\(base)\n[詳細: \(reason)]"
                #else
                return base
                #endif
            case .unknownRecordType(let type):
                return String(localized: "未知のデータ形式です (\(type))")
            }
        }
    }

    /// CloudKit の既知の挙動: `creatorUserRecordID` は, **記録の作成者が
    /// 自分自身でそのレコードを読むとき限り**, 実際の userRecordID ではなく
    /// `__defaultOwner__` という匿名化されたプレースホルダを返す
    /// (他人がそのレコードを読むときは, 実際の ID がそのまま返る)。
    ///
    /// これに気づかずに文字列としてそのまま比較すると, 「自分が作った
    /// データを自分で読む」という最も基本的な操作が, 常に「なりすまし」と
    /// 誤判定されてしまう。呼び出し側が知っている「今ログインしている
    /// 自分の ID」でこのプレースホルダを解決してから比較する.
    private static let currentUserPlaceholder = "__defaultOwner__"

    static func resolvedCreatorName(of record: CKRecord, currentUserID: UserID) -> String? {
        guard let raw = record.creatorUserRecordID?.recordName else { return nil }
        return raw == currentUserPlaceholder ? currentUserID.rawValue : raw
    }

    // MARK: - UserProfile

    static func userProfile(from record: CKRecord, currentUserID: UserID) throws -> UserProfile {
        guard record.recordType == CKSchema.UserProfile.recordType else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        // プロフィールの recordName は "userprofile-<作成者の userRecordID>" という
        // 決定的な形でなければならない. 他人が他人の ID でプロフィールを作っても,
        // 作成者から逆算した名前と実際の recordName が一致せず, ここで弾かれる.
        guard let creator = resolvedCreatorName(of: record, currentUserID: currentUserID) else {
            throw MappingError.impersonation(
                reason: "UserProfile \(record.recordID.recordName): creatorUserRecordID is nil"
            )
        }
        let creatorID = UserID(creator)
        let expectedName = CKSchema.UserProfile.recordName(for: creatorID)
        guard record.recordID.recordName == expectedName else {
            throw MappingError.impersonation(
                reason: "UserProfile: recordID=\(record.recordID.recordName) creator=\(creator) expected=\(expectedName)"
            )
        }
        guard let handle = record[CKSchema.UserProfile.handle] as? String else {
            throw MappingError.missingField(CKSchema.UserProfile.handle)
        }
        guard let displayName = record[CKSchema.UserProfile.displayName] as? String else {
            throw MappingError.missingField(CKSchema.UserProfile.displayName)
        }

        let avatarData: Data?
        if let asset = record[CKSchema.UserProfile.avatar] as? CKAsset,
           let url = asset.fileURL {
            avatarData = try? Data(contentsOf: url)
        } else {
            avatarData = nil
        }

        return UserProfile(
            id: creatorID,
            handle: handle,
            displayName: displayName,
            avatarData: avatarData,
            publicKeyData: record[CKSchema.UserProfile.publicKey] as? Data,
            updatedAt: record[CKSchema.UserProfile.updatedAt] as? Date ?? record.modificationDate ?? .now
        )
    }

    // MARK: - Conversation

    /// 会話レコードの復号前の素データ.
    struct RawConversation {
        var id: ConversationID
        var kind: ConversationKind
        var participantIDs: [UserID]
        var ownerID: UserID
        var createdAt: Date
        var titleCipher: Data?
        var imageCipher: Data?
    }

    static func rawConversation(from record: CKRecord, currentUserID: UserID) throws -> RawConversation {
        guard record.recordType == CKSchema.Conversation.recordType else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        guard let kindRaw = record[CKSchema.Conversation.kind] as? String,
              let kind = ConversationKind(rawValue: kindRaw) else {
            throw MappingError.missingField(CKSchema.Conversation.kind)
        }
        guard let participants = record[CKSchema.Conversation.participantIDs] as? [String] else {
            throw MappingError.missingField(CKSchema.Conversation.participantIDs)
        }
        guard let ownerRaw = record[CKSchema.Conversation.ownerID] as? String else {
            throw MappingError.missingField(CKSchema.Conversation.ownerID)
        }
        // 会話の作成者も検証する. 他人が「自分が作った」と偽った会話は採用しない.
        // (メンバー追加による更新があるため, 更新者ではなく作成者だけを見る)
        let creator = resolvedCreatorName(of: record, currentUserID: currentUserID)
        guard creator == ownerRaw else {
            throw MappingError.impersonation(
                reason: "Conversation \(record.recordID.recordName): creator=\(creator ?? "nil") ownerID=\(ownerRaw)"
            )
        }

        return RawConversation(
            id: ConversationID(record.recordID.recordName),
            kind: kind,
            participantIDs: participants.map(UserID.init),
            ownerID: UserID(ownerRaw),
            createdAt: record[CKSchema.Conversation.createdAt] as? Date ?? record.creationDate ?? .now,
            titleCipher: record[CKSchema.Conversation.titleCipher] as? Data,
            imageCipher: record[CKSchema.Conversation.imageCipher] as? Data
        )
    }

    // MARK: - Message

    /// メッセージレコードの復号前の素データ.
    struct RawMessage {
        var id: MessageID
        var conversationID: ConversationID
        var senderID: UserID
        var sentAt: Date
        var payloadCipher: Data
        var thumbnailCipher: Data?
        var mediaAssetByteCount: Int
        var hasMediaAsset: Bool
        /// サーバ上で最後に書き換えられた時刻.
        ///
        /// 通常メッセージは作成後に変更されないが, 送信取り消しだけは
        /// 既存レコードの書き換えとして届く. 「取得済みのメッセージが
        /// あとから変わったか」を安く判定するために持つ.
        var modifiedAt: Date
    }

    static func rawMessage(from record: CKRecord, currentUserID: UserID) throws -> RawMessage {
        guard record.recordType == CKSchema.Message.recordType else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        guard let senderRaw = record[CKSchema.Message.senderID] as? String else {
            throw MappingError.missingField(CKSchema.Message.senderID)
        }
        // なりすまし対策の要. サーバ押印の作成者と申告された送信者が一致しなければ捨てる.
        let creator = resolvedCreatorName(of: record, currentUserID: currentUserID)
        guard creator == senderRaw else {
            throw MappingError.impersonation(
                reason: "Message \(record.recordID.recordName): creator=\(creator ?? "nil") senderID=\(senderRaw)"
            )
        }
        guard let conversationRef = record[CKSchema.Message.conversation] as? CKRecord.Reference else {
            throw MappingError.missingField(CKSchema.Message.conversation)
        }
        guard let payload = record[CKSchema.Message.payload] as? Data else {
            throw MappingError.missingField(CKSchema.Message.payload)
        }

        let asset = record[CKSchema.Message.mediaAsset] as? CKAsset
        let assetByteCount: Int
        if let url = asset?.fileURL,
           let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            assetByteCount = size
        } else {
            assetByteCount = 0
        }

        return RawMessage(
            id: MessageID(record.recordID.recordName),
            conversationID: ConversationID(conversationRef.recordID.recordName),
            senderID: UserID(senderRaw),
            sentAt: record[CKSchema.Message.sentAt] as? Date ?? record.creationDate ?? .now,
            payloadCipher: payload,
            thumbnailCipher: record[CKSchema.Message.thumbnailCipher] as? Data,
            mediaAssetByteCount: assetByteCount,
            hasMediaAsset: asset != nil,
            modifiedAt: record.modificationDate ?? record.creationDate ?? .distantPast
        )
    }

    // MARK: - ConversationKey

    static func wrappedKey(from record: CKRecord) throws -> (conversation: ConversationID, key: WrappedConversationKey) {
        guard let reference = record[CKSchema.ConversationKey.conversation] as? CKRecord.Reference else {
            throw MappingError.missingField(CKSchema.ConversationKey.conversation)
        }
        guard let ephemeral = record[CKSchema.ConversationKey.ephemeralPublicKey] as? Data else {
            throw MappingError.missingField(CKSchema.ConversationKey.ephemeralPublicKey)
        }
        guard let wrapped = record[CKSchema.ConversationKey.wrappedKey] as? Data else {
            throw MappingError.missingField(CKSchema.ConversationKey.wrappedKey)
        }
        return (
            ConversationID(reference.recordID.recordName),
            WrappedConversationKey(ephemeralPublicKey: ephemeral, ciphertext: wrapped)
        )
    }
}
