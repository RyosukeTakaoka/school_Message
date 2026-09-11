import Foundation
import CloudKit

/// メッセージへの絵文字リアクションに関する `CloudKitBackend` の実装.
extension CloudKitBackend {

    func fetchReactions(in conversationID: ConversationID) async throws -> [MessageReaction] {
        let me = try await currentUserID()
        let key = try await conversationKey(for: conversationID)

        let query = CKQuery(
            recordType: CKSchema.MessageReaction.recordType,
            predicate: NSPredicate(
                format: "%K == %@",
                CKSchema.MessageReaction.conversation, reference(to: conversationID)
            )
        )
        let records = try await queryWithRetry(query, limit: Self.reactionFetchLimit)

        var reactions: [MessageReaction] = []
        for record in records {
            guard let messageRef = record[CKSchema.MessageReaction.message] as? CKRecord.Reference,
                  let rawUser = record[CKSchema.MessageReaction.userID] as? String,
                  let cipher = record[CKSchema.MessageReaction.emojiCipher] as? Data,
                  let createdAt = record[CKSchema.MessageReaction.createdAt] as? Date
            else { continue }
            // 申告された userID と, サーバが押印した作成者が一致するものだけ採用する
            // (他人になりすまして偽のリアクションを付けられないようにする).
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == rawUser else { continue }
            guard let plaintext = try? await crypto.open(cipher, with: key),
                  let emoji = String(data: plaintext, encoding: .utf8)
            else { continue }

            reactions.append(
                MessageReaction(
                    messageID: MessageID(messageRef.recordID.recordName),
                    conversationID: conversationID,
                    userID: UserID(rawUser),
                    emoji: emoji,
                    createdAt: createdAt
                )
            )
        }
        return reactions
    }

    /// `emoji` が `nil` なら自分のリアクションを外す. それ以外なら新規作成 / 差し替える.
    ///
    /// レコード名を `(メッセージ, 自分)` から決定的に組み立てているため,
    /// 常に「自分が作ったレコード」だけを書き換えることになり,
    /// Public Database の「作成者だけが書き換えられる」という制約とそのまま噛み合う.
    func setReaction(_ emoji: String?, on messageID: MessageID, in conversationID: ConversationID) async throws {
        let me = try await currentUserID()
        let recordID = CKRecord.ID(
            recordName: CKSchema.MessageReaction.recordName(message: messageID, user: me)
        )

        guard let emoji else {
            do {
                _ = try await database.deleteRecord(withID: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                // 既に外れている. 何もしなくてよい.
            } catch {
                throw CloudKitErrorMapping.appError(from: error)
            }
            return
        }

        let key = try await conversationKey(for: conversationID)

        let record: CKRecord
        do {
            record = try await fetchWithRetry(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: CKSchema.MessageReaction.recordType, recordID: recordID)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        record[CKSchema.MessageReaction.conversation] = reference(to: conversationID)
        record[CKSchema.MessageReaction.message] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: messageID.rawValue),
            action: .none
        )
        record[CKSchema.MessageReaction.userID] = me.rawValue as CKRecordValue
        record[CKSchema.MessageReaction.emojiCipher] = try await crypto.seal(
            Data(emoji.utf8), with: key
        ) as CKRecordValue
        record[CKSchema.MessageReaction.createdAt] = Date.now as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    /// 会話 1 件ぶんのリアクションの取得上限.
    fileprivate static let reactionFetchLimit = 2000
}
