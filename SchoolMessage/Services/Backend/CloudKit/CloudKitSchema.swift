import Foundation

/// CloudKit のレコードタイプ / フィールド名.
///
/// 文字列リテラルを各所に散らすと, ダッシュボード側のスキーマ変更に追随できなくなる.
/// ここ 1 箇所に集約し, `docs/CLOUDKIT_SCHEMA.md` と対応させる.
enum CKSchema {

    // MARK: - UserProfile

    enum UserProfile {
        static let recordType = "UserProfile"

        /// 検索用の一意なハンドル. QUERYABLE / SORTABLE.
        static let handle = "handle"
        /// 表示名. QUERYABLE / SEARCHABLE(名前での部分検索に使う).
        static let displayName = "displayName"
        /// プロフィール画像(暗号化しない. 公開ディレクトリの一部).
        static let avatar = "avatar"
        static let avatarByteCount = "avatarByteCount"
        /// Curve25519 公開鍵(raw representation, 32 バイト).
        static let publicKey = "publicKey"
        static let updatedAt = "updatedAt"

        /// レコードIDに接頭辞を付ける.
        ///
        /// CloudKit の Public Database は, ユーザーが初めてコンテナにアクセスした時点で
        /// システム予約の `Users` レコードタイプを, そのユーザーの `userRecordID` と
        /// **同じ recordName** で自動的に作成する. recordName はレコードタイプが違っても
        /// データベース内で一意でなければならないため, ここで `userID.rawValue` を
        /// そのまま recordName に使うと, 既存の `Users` システムレコードと衝突し,
        /// `UserProfile` として保存・取得ができなくなる(「未知のデータ形式です(Users)」).
        /// 接頭辞を付けて名前空間を分けることでこれを避ける.
        static func recordName(for userID: UserID) -> String {
            "userprofile-\(userID.rawValue)"
        }
    }

    // MARK: - Friendship

    enum Friendship {
        static let recordType = "Friendship"

        /// 友達登録した側の userRecordName. QUERYABLE.
        static let ownerID = "ownerID"
        /// 登録された側の userRecordName. QUERYABLE.
        static let friendID = "friendID"
        static let createdAt = "createdAt"

        /// 双方向に重複を作らないよう recordName を決定的に組み立てる.
        static func recordName(owner: UserID, friend: UserID) -> String {
            "friendship-\(owner.rawValue)-\(friend.rawValue)"
        }
    }

    // MARK: - Conversation

    enum Conversation {
        static let recordType = "Conversation"

        /// "direct" / "group".
        static let kind = "kind"
        /// 参加者の userRecordName の配列. QUERYABLE(CONTAINS で自分の会話を引く).
        static let participantIDs = "participantIDs"
        static let ownerID = "ownerID"
        static let createdAt = "createdAt"
        /// 会話鍵で暗号化したグループ名. 非メンバーには読めない.
        static let titleCipher = "titleCipher"
        /// 会話鍵で暗号化したグループ画像.
        static let imageCipher = "imageCipher"

        // 補足: ここに「最終メッセージ」を非正規化して持たせる案は採らなかった.
        //
        // Public Database の既定の書き込み権限は「レコードの作成者のみ」なので,
        // グループの作成者以外がメッセージを送っても会話レコードを更新できない.
        // 全員が書けるようにセキュリティロールを緩めると, 参加者一覧を第三者に
        // 書き換えられる余地が生まれ, 本アプリの前提(メンバー管理の一貫性)が崩れる.
        //
        // 代わりにチャット一覧は Message 側への 1 本のまとめクエリで組み立てる
        // (`CloudKitBackend.fetchConversations()` を参照).
    }

    // MARK: - ConversationKey

    /// 参加者 1 人につき 1 レコード. その人の公開鍵で封緘した会話鍵が入る.
    enum ConversationKey {
        static let recordType = "ConversationKey"

        static let conversation = "conversation"       // CKRecord.Reference, QUERYABLE
        static let recipientID = "recipientID"         // QUERYABLE
        static let ephemeralPublicKey = "ephemeralPublicKey"
        static let wrappedKey = "wrappedKey"

        /// recordName に会話作成者も含める.
        ///
        /// 1 対 1 会話は両者が同時に「チャットを開始」しうる. 会話 ID は決定的なので
        /// レコードは 1 つに収束するが, 鍵レコード名まで固定にすると, 先に負けた側が
        /// 書いた鍵が残って正しい鍵を上書きできない状態になる.
        /// 作成者を名前に含めることで両者の鍵が別レコードになり, 読み出し時に
        /// 「会話の作成者が書いた鍵」を選べばよくなる.
        static func recordName(conversation: ConversationID, recipient: UserID, owner: UserID) -> String {
            "convkey-\(conversation.rawValue)-\(recipient.rawValue)-\(owner.rawValue)"
        }
    }

    // MARK: - ConversationLeave

    /// 退出の記録.
    ///
    /// Public Database では自分が作成していないレコード(=他人が作った会話)を
    /// 書き換えられないため, 参加者一覧から自分を消すことができない.
    /// 代わりに退出者本人が作れるこのレコードを置き, 各クライアントが
    /// 参加者一覧から差し引く.
    enum ConversationLeave {
        static let recordType = "ConversationLeave"

        static let conversation = "conversation"   // CKRecord.Reference, QUERYABLE
        static let userID = "userID"               // QUERYABLE
        static let leftAt = "leftAt"

        static func recordName(conversation: ConversationID, user: UserID) -> String {
            "leave-\(conversation.rawValue)-\(user.rawValue)"
        }
    }

    // MARK: - Message

    enum Message {
        static let recordType = "Message"

        static let conversation = "conversation"   // CKRecord.Reference, QUERYABLE
        /// 送信者の申告値. 取得時に creatorUserRecordID と突き合わせて検証する.
        static let senderID = "senderID"
        /// 送信時刻. QUERYABLE / SORTABLE(ページングとソートに必須).
        static let sentAt = "sentAt"
        /// 暗号化した `MessagePayload`(本文とメディアのメタデータ).
        static let payload = "payload"
        /// 暗号化した写真・動画の本体.
        static let mediaAsset = "mediaAsset"
        /// 暗号化したサムネイル. 小さいので Bytes として同梱し, 追加のフェッチを避ける.
        static let thumbnailCipher = "thumbnailCipher"

        /// 会話の参加者一覧のコピー. QUERYABLE.
        ///
        /// プッシュ購読の述語は「自分宛の新着だけ」を表現できる必要があるが,
        /// 参照先(Conversation)の値では絞り込めないため, ここに複製している.
        /// 会話レコード側で既に参加者は判明するので, 新たに漏れる情報はない.
        static let participantIDs = "participantIDs"

        /// 送信者の表示名(平文).
        ///
        /// プッシュ通知に「誰から来たか」を出すためだけに置く. 本文は暗号化された
        /// ままなので, サーバ側で作られる通知に本文は載らない.
        static let senderDisplayName = "senderDisplayName"
    }

    // MARK: - ReadState

    /// 「誰がどの会話をどこまで読んだか」. メッセージ 1 件ごとに既読フラグを持たず,
    /// 会話 × ユーザで 1 レコードにすることで既読化の書き込みを O(1) にする.
    enum ReadState {
        static let recordType = "ReadState"

        static let conversation = "conversation"
        static let userID = "userID"
        static let lastReadAt = "lastReadAt"

        static func recordName(conversation: ConversationID, user: UserID) -> String {
            "readstate-\(conversation.rawValue)-\(user.rawValue)"
        }
    }

    // MARK: - Subscription

    enum SubscriptionID {
        /// 自分が参加している会話への新着メッセージ(通知を表示する用).
        static let newMessages = "sub-new-messages-v2"
        /// 同上(アプリを起こして本文を復号する用のサイレント通知).
        static let newMessagesSilent = "sub-new-messages-silent-v2"
        /// 自分が参加者に追加された会話.
        static let conversations = "sub-conversations-v2"

        /// 会話ごとの購読(グローバルな述語が使えない環境向けの代替).
        static func perConversation(_ conversationID: ConversationID) -> String {
            "sub-conv-\(conversationID.rawValue)"
        }

        /// 会話ごとの購読か.
        static func isPerConversation(_ subscriptionID: String) -> Bool {
            subscriptionID.hasPrefix("sub-conv-")
        }
    }
}
