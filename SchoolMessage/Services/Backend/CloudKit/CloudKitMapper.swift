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
        case impersonation
        case unknownRecordType(String)

        var errorDescription: String? {
            switch self {
            case .missingField(let name):
                String(localized: "データの項目 \(name) が欠けています")
            case .impersonation:
                String(localized: "送信者を確認できないデータを無視しました")
            case .unknownRecordType(let type):
                String(localized: "未知のデータ形式です (\(type))")
            }
        }
    }

    // MARK: - UserProfile

    static func userProfile(from record: CKRecord) throws -> UserProfile {
        guard record.recordType == CKSchema.UserProfile.recordType else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        // プロフィールの recordName は本人の userRecordName と等しくなければならない.
        // 他人が他人の ID でプロフィールを作っても, ここで弾かれる.
        guard let creator = record.creatorUserRecordID?.recordName,
              creator == record.recordID.recordName else {
            throw MappingError.impersonation
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
            id: UserID(record.recordID.recordName),
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

    static func rawConversation(from record: CKRecord) throws -> RawConversation {
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
        guard let creator = record.creatorUserRecordID?.recordName, creator == ownerRaw else {
            throw MappingError.impersonation
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
    }

    static func rawMessage(from record: CKRecord) throws -> RawMessage {
        guard record.recordType == CKSchema.Message.recordType else {
            throw MappingError.unknownRecordType(record.recordType)
        }
        guard let senderRaw = record[CKSchema.Message.senderID] as? String else {
            throw MappingError.missingField(CKSchema.Message.senderID)
        }
        // なりすまし対策の要. サーバ押印の作成者と申告された送信者が一致しなければ捨てる.
        guard let creator = record.creatorUserRecordID?.recordName, creator == senderRaw else {
            throw MappingError.impersonation
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
            hasMediaAsset: asset != nil
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
