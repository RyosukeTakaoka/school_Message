import Foundation
import CloudKit
import CryptoKit

/// CloudKit(Public Database)を使ったバックエンド実装.
///
/// ## なぜ Public Database なのか
/// - Private Database はユーザ間で共有できない.
/// - Shared Database(CKShare)はサーバ側 ACL が最も強固だが, 参加には共有 URL の
///   受け渡しと承認が必要で「ユーザIDを検索して即チャット」という要件と噛み合わない.
///   グループにメンバーを足すたびに招待の承認待ちが発生する.
/// - Public Database は全員が同じ空間を見るため, レコードの取得自体は誰でもできる.
///   そこで本文とメディアは会話鍵で暗号化し, 会話鍵は参加者の公開鍵で封緘して配る.
///   結果として「レコードは取れても読めない」状態を作る.
///
/// ## なりすまし対策
/// `senderID` はクライアントが書き込む値なので信用できない. 読み出し時に
/// CloudKit がサーバ側で押印する `creatorUserRecordID` と一致するかを必ず検証し,
/// 一致しないレコードは破棄する(`CloudKitMapper`).
///
/// ## 書き込み権限の前提
/// Public Database の既定では「レコードを更新できるのは作成者のみ」. この前提に
/// 寄りかかった設計にしてある(会話の参加者一覧を第三者が書き換えられない).
/// 代わりに, 会話レコードへの非正規化(最終メッセージのキャッシュ等)はできない.
actor CloudKitBackend: ChatBackend {

    let container: CKContainer
    let database: CKDatabase
    let crypto: CryptoService
    let mediaStore: MediaStore
    let eventHub = BackendEventHub()

    /// サインイン中のユーザ ID.
    private var cachedUserID: UserID?
    /// プッシュ通知に載せる自分の表示名.
    private var cachedDisplayName: String?
    /// 会話ごとの参加者一覧(メッセージ保存時の複製に使う).
    private var participantCache: [ConversationID: [UserID]] = [:]
    /// 会話ごとの作成者(鍵レコードの正当性判定に使う).
    private var ownerCache: [ConversationID: UserID] = [:]

    init(
        containerIdentifier: String = AppConstants.cloudKitContainerIdentifier,
        crypto: CryptoService,
        mediaStore: MediaStore
    ) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.publicCloudDatabase
        self.crypto = crypto
        self.mediaStore = mediaStore
    }

    // MARK: - 共通ヘルパ

    /// 現在のユーザ ID. 未解決なら CloudKit に問い合わせる.
    func currentUserID() async throws -> UserID {
        if let cachedUserID { return cachedUserID }
        guard case .available(let userID) = try await accountStatus() else {
            throw AppError.iCloudAccountUnavailable
        }
        return userID
    }

    /// クエリを実行し, カーソルを辿って最大 `limit` 件まで集める.
    ///
    /// 個々のレコードの失敗(部分失敗)は捨てて残りを返す. 壊れたレコード 1 件で
    /// チャット一覧全体が出せなくなるのを避けるため.
    private func runQuery(
        _ query: CKQuery,
        desiredKeys: [CKRecord.FieldKey]?,
        limit: Int
    ) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let remaining = max(0, limit - collected.count)
            if remaining == 0 { break }
            let pageSize = min(remaining, CKQueryOperation.maximumResults)

            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            do {
                if let cursor {
                    page = try await database.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: pageSize
                    )
                } else {
                    page = try await database.records(
                        matching: query,
                        desiredKeys: desiredKeys,
                        resultsLimit: pageSize
                    )
                }
            } catch {
                guard CloudKitErrorMapping.isUnknownItem(error) else { throw error }
                // レコードタイプがまだ CloudKit のスキーマに一度も存在しない場合
                // (＝そのタイプのレコードを一度も保存したことがない)にここに来る.
                // これはアプリの初回利用時に必ず起きる正常な状態であり,
                // 「該当するレコードが 0 件」として扱う. エラーとして投げてしまうと
                // ユーザ登録・友達一覧・チャット一覧などすべての機能が
                // 初回起動時に原因不明のまま失敗する.
                Log.backend.notice("record type '\(query.recordType, privacy: .public)' not found yet; treating query as empty")
                return collected
            }

            for (_, result) in page.matchResults {
                switch result {
                case .success(let record):
                    collected.append(record)
                case .failure(let error):
                    Log.backend.error("skipped record: \(CloudKitErrorMapping.appError(from: error).localizedDescription, privacy: .public)")
                }
            }
            cursor = page.queryCursor
        } while cursor != nil && collected.count < limit

        return collected
    }

    /// リトライ付きのクエリ.
    ///
    /// `AsyncRetry` の `@Sendable` クロージャに `CKQuery` を渡すと
    /// Sendable 検査に引っかかるため, actor 内で完結する形で書いている.
    func queryWithRetry(
        _ query: CKQuery,
        desiredKeys: [CKRecord.FieldKey]? = nil,
        limit: Int = 500
    ) async throws -> [CKRecord] {
        var attempt = 0
        while true {
            do {
                return try await runQuery(query, desiredKeys: desiredKeys, limit: limit)
            } catch {
                attempt += 1
                let appError = CloudKitErrorMapping.appError(from: error)
                guard appError.isRetryable, attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw appError
                }
                try await sleepBeforeRetry(attempt: attempt, appError: appError)
            }
        }
    }

    /// リトライ付きの保存.
    func saveWithRetry(_ record: CKRecord) async throws -> CKRecord {
        var attempt = 0
        while true {
            do {
                return try await database.save(record)
            } catch {
                attempt += 1
                let appError = CloudKitErrorMapping.appError(from: error)
                guard appError.isRetryable, attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw error   // 呼び出し側が CKError を見て冪等判定できるよう元のまま投げる
                }
                try await sleepBeforeRetry(attempt: attempt, appError: appError)
            }
        }
    }

    /// リトライ付きの単一レコード取得.
    func fetchWithRetry(_ recordID: CKRecord.ID) async throws -> CKRecord {
        var attempt = 0
        while true {
            do {
                return try await database.record(for: recordID)
            } catch {
                attempt += 1
                let appError = CloudKitErrorMapping.appError(from: error)
                guard appError.isRetryable, attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw error
                }
                try await sleepBeforeRetry(attempt: attempt, appError: appError)
            }
        }
    }

    private func sleepBeforeRetry(attempt: Int, appError: AppError) async throws {
        let delay = appError.suggestedRetryDelay
            ?? AsyncRetry.backoffDelay(attempt: attempt, baseDelay: AppConstants.Timing.retryBaseDelay)
        try await Task.sleep(for: .seconds(delay))
    }

    /// `creatorUserRecordID` が反映されるまで待ちながら取得する.
    ///
    /// この値は保存直後だけでなく, その少しあとの読み込みでも
    /// まだサーバ側で反映しきれていないことがある(CloudKit のレプリケーション遅延).
    /// なりすまし検証(`CloudKitMapper`)がこの値を必須にしているため,
    /// 空のまま検証に回すと「本人のデータなのに, なりすましとして拒否される」
    /// 誤判定が起きる. 数回だけ間を置いて再取得することで, 一時的な遅延を吸収する.
    private func fetchRecordWithPopulatedCreator(
        _ recordID: CKRecord.ID,
        attempts: Int = 3
    ) async throws -> CKRecord {
        var lastRecord: CKRecord?
        for attempt in 0..<attempts {
            let record = try await fetchWithRetry(recordID)
            if record.creatorUserRecordID != nil {
                return record
            }
            lastRecord = record
            if attempt < attempts - 1 {
                Log.backend.notice("creatorUserRecordID not yet populated; retrying")
                try await Task.sleep(for: .seconds(1))
            }
        }
        // 最終的に埋まらなければ, そのまま返す. 呼び出し側の検証で
        // MappingError.impersonation として明確に失敗する.
        guard let lastRecord else {
            throw AppError.underlying(String(localized: "データを取得できませんでした"))
        }
        return lastRecord
    }

    // MARK: - アカウント

    func accountStatus() async throws -> BackendAccountStatus {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        switch status {
        case .available:
            do {
                let recordID = try await container.userRecordID()
                let userID = UserID(recordID.recordName)
                cachedUserID = userID
                return .available(userID)
            } catch {
                throw CloudKitErrorMapping.appError(from: error)
            }
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .temporarilyUnavailable
        @unknown default:
            return .temporarilyUnavailable
        }
    }

    // MARK: - プロフィール

    func fetchMyProfile() async throws -> UserProfile? {
        let userID = try await currentUserID()
        let recordID = CKRecord.ID(recordName: CKSchema.UserProfile.recordName(for: userID))
        do {
            let record = try await fetchRecordWithPopulatedCreator(recordID)
            let profile = try CloudKitMapper.userProfile(from: record)
            cachedDisplayName = profile.displayName
            return profile
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    func registerProfile(handle: String, displayName: String, avatarData: Data?) async throws -> UserProfile {
        let normalizedHandle = try UserProfile.validateHandle(handle)
        let normalizedName = try UserProfile.validateDisplayName(displayName)
        let userID = try await currentUserID()

        try await assertHandleAvailable(normalizedHandle, for: userID)

        let publicKeyData = try await crypto.identityPublicKeyData()
        let recordID = CKRecord.ID(recordName: CKSchema.UserProfile.recordName(for: userID))

        // 既存があれば上書き, 無ければ新規.
        let record: CKRecord
        do {
            record = try await fetchWithRetry(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: CKSchema.UserProfile.recordType, recordID: recordID)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        record[CKSchema.UserProfile.handle] = normalizedHandle as CKRecordValue
        record[CKSchema.UserProfile.displayName] = normalizedName as CKRecordValue
        record[CKSchema.UserProfile.publicKey] = publicKeyData as CKRecordValue
        record[CKSchema.UserProfile.updatedAt] = Date.now as CKRecordValue
        try attachAvatar(avatarData, to: record)

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        // 保存直後にサーバから返るレコードは `creatorUserRecordID` がまだ
        // 反映されていないことがあり, なりすまし検証(CloudKitMapper.userProfile)を
        // 通せないことがある. しかしこれは「たった今, 自分自身が書き込んだ
        // 自分のレコード」であり, 書き込みが成功した時点で本人であることは
        // CloudKit 側の権限制御(既定では作成者しか書き込めない)によって
        // 保証済みなので, サーバの値を再検証する必要はない. 手元の値から
        // そのまま組み立てる.
        let profile = UserProfile(
            id: userID,
            handle: normalizedHandle,
            displayName: normalizedName,
            avatarData: avatarData,
            publicKeyData: publicKeyData,
            updatedAt: .now
        )
        cachedDisplayName = profile.displayName
        eventHub.emit(.profilesChanged)
        return profile
    }

    func updateProfile(displayName: String?, avatarData: Data?) async throws -> UserProfile {
        let userID = try await currentUserID()
        let recordID = CKRecord.ID(recordName: CKSchema.UserProfile.recordName(for: userID))

        let record: CKRecord
        do {
            record = try await fetchWithRetry(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            throw AppError.notRegistered
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        // 変更しないフィールドは, 更新前に取得できている既存レコードの値を使う.
        // (`record` はこの時点では変更前の内容なので, 上書きする前に読んでおく)
        let existingHandle = record[CKSchema.UserProfile.handle] as? String ?? ""
        let existingPublicKey = record[CKSchema.UserProfile.publicKey] as? Data

        let resolvedDisplayName: String
        if let displayName {
            resolvedDisplayName = try UserProfile.validateDisplayName(displayName)
            record[CKSchema.UserProfile.displayName] = resolvedDisplayName as CKRecordValue
        } else {
            resolvedDisplayName = record[CKSchema.UserProfile.displayName] as? String ?? ""
        }

        let resolvedAvatarData: Data?
        if let avatarData {
            resolvedAvatarData = avatarData
            try attachAvatar(avatarData, to: record)
        } else {
            resolvedAvatarData = Self.readAvatarData(from: record)
        }

        record[CKSchema.UserProfile.updatedAt] = Date.now as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        // registerProfile と同じ理由で, 保存結果の再検証はせず手元の値で組み立てる.
        let profile = UserProfile(
            id: userID,
            handle: existingHandle,
            displayName: resolvedDisplayName,
            avatarData: resolvedAvatarData,
            publicKeyData: existingPublicKey,
            updatedAt: .now
        )
        cachedDisplayName = profile.displayName
        eventHub.emit(.profilesChanged)
        return profile
    }

    /// ハンドルの重複確認. 完全一致でしか衝突しないので 1 クエリで足りる.
    private func assertHandleAvailable(_ handle: String, for userID: UserID) async throws {
        let predicate = NSPredicate(format: "%K == %@", CKSchema.UserProfile.handle, handle)
        let query = CKQuery(recordType: CKSchema.UserProfile.recordType, predicate: predicate)
        let records = try await queryWithRetry(query, desiredKeys: [], limit: 2)
        let ownRecordName = CKSchema.UserProfile.recordName(for: userID)
        if records.contains(where: { $0.recordID.recordName != ownRecordName }) {
            throw AppError.handleAlreadyTaken(handle)
        }
    }

    private func attachAvatar(_ avatarData: Data?, to record: CKRecord) throws {
        guard let avatarData else {
            record[CKSchema.UserProfile.avatar] = nil as CKRecordValue?
            record[CKSchema.UserProfile.avatarByteCount] = NSNumber(value: 0)
            return
        }
        let url = mediaStore.scratchURL(suffix: "jpg")
        try avatarData.write(to: url, options: .atomic)
        record[CKSchema.UserProfile.avatar] = CKAsset(fileURL: url)
        record[CKSchema.UserProfile.avatarByteCount] = NSNumber(value: avatarData.count)
    }

    /// 既存レコードから, 変更しない場合の現在のアバター画像を読み出す.
    ///
    /// (`attachAvatar` で今まさにアップロードした CKAsset は, 保存直後の
    /// ローカルオブジェクトでは `fileURL` が有効とは限らないため, ここでは
    /// 使わない. あくまで「更新前から既にサーバにあった, 変更しないアバター」
    /// を読むためのもの)
    private static func readAvatarData(from record: CKRecord) -> Data? {
        guard let asset = record[CKSchema.UserProfile.avatar] as? CKAsset,
              let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - ユーザ検索

    func searchUsers(matching query: String) async throws -> [UserProfile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var found: [UserID: UserProfile] = [:]

        // 1) ユーザIDの完全一致. 確実に効く主経路.
        let handlePredicate = NSPredicate(
            format: "%K == %@",
            CKSchema.UserProfile.handle,
            trimmed.lowercased()
        )
        let handleQuery = CKQuery(recordType: CKSchema.UserProfile.recordType, predicate: handlePredicate)
        for record in try await queryWithRetry(handleQuery, limit: 5) {
            if let profile = try? CloudKitMapper.userProfile(from: record) {
                found[profile.id] = profile
            }
        }

        // 2) 表示名の前方一致. インデックス設定に依存するので, 失敗しても
        //    完全一致の結果だけは返す(検索がまったく使えない状態にしない).
        let namePredicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            CKSchema.UserProfile.displayName,
            trimmed
        )
        let nameQuery = CKQuery(recordType: CKSchema.UserProfile.recordType, predicate: namePredicate)
        do {
            for record in try await queryWithRetry(nameQuery, limit: AppConstants.Paging.userSearchResultLimit) {
                if let profile = try? CloudKitMapper.userProfile(from: record) {
                    found[profile.id] = profile
                }
            }
        } catch {
            Log.backend.notice("display name search unavailable")
        }

        let me = try await currentUserID()
        return found.values
            .filter { $0.id != me }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func fetchProfiles(ids: [UserID]) async throws -> [UserProfile] {
        guard !ids.isEmpty else { return [] }
        // 一度に大量の ID を投げないよう分割する.
        let chunks = Array(Set(ids)).chunked(into: 100)
        var profiles: [UserProfile] = []
        for chunk in chunks {
            let recordIDs = chunk.map { CKRecord.ID(recordName: CKSchema.UserProfile.recordName(for: $0)) }
            do {
                let results = try await database.records(for: recordIDs)
                for result in results.values {
                    guard case .success(let record) = result else { continue }
                    if let profile = try? CloudKitMapper.userProfile(from: record) {
                        profiles.append(profile)
                    }
                }
            } catch {
                throw CloudKitErrorMapping.appError(from: error)
            }
        }
        return profiles
    }

    // MARK: - 友達

    func fetchFriends() async throws -> [UserProfile] {
        let me = try await currentUserID()
        let predicate = NSPredicate(format: "%K == %@", CKSchema.Friendship.ownerID, me.rawValue)
        let query = CKQuery(recordType: CKSchema.Friendship.recordType, predicate: predicate)
        let records = try await queryWithRetry(query)

        // 他人が勝手に作った Friendship を拾わないよう作成者を検証する.
        let friendIDs = records.compactMap { record -> UserID? in
            guard record.creatorUserRecordID?.recordName == me.rawValue,
                  let friendID = record[CKSchema.Friendship.friendID] as? String
            else { return nil }
            return UserID(friendID)
        }
        guard !friendIDs.isEmpty else { return [] }

        return try await fetchProfiles(ids: friendIDs)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func addFriend(_ userID: UserID) async throws {
        let me = try await currentUserID()
        guard userID != me else { return }

        let recordID = CKRecord.ID(recordName: CKSchema.Friendship.recordName(owner: me, friend: userID))
        let record = CKRecord(recordType: CKSchema.Friendship.recordType, recordID: recordID)
        record[CKSchema.Friendship.ownerID] = me.rawValue as CKRecordValue
        record[CKSchema.Friendship.friendID] = userID.rawValue as CKRecordValue
        record[CKSchema.Friendship.createdAt] = Date.now as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            // すでに追加済みなら成功として扱う(二重タップで失敗表示にしない).
            if CloudKitErrorMapping.isAlreadyExists(error) { return }
            throw CloudKitErrorMapping.appError(from: error)
        }
        eventHub.emit(.profilesChanged)
    }

    func removeFriend(_ userID: UserID) async throws {
        let me = try await currentUserID()
        let recordID = CKRecord.ID(recordName: CKSchema.Friendship.recordName(owner: me, friend: userID))
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
        eventHub.emit(.profilesChanged)
    }

    // MARK: - 変更通知

    nonisolated func events() -> AsyncStream<BackendEvent> {
        eventHub.stream()
    }

    func configureSubscriptions() async throws {
        let me = try await currentUserID()

        // 自分が参加者に含まれる新着メッセージ.
        let messagePredicate = NSPredicate(
            format: "%K CONTAINS %@",
            CKSchema.Message.participantIDs,
            me.rawValue
        )
        let messageSubscription = CKQuerySubscription(
            recordType: CKSchema.Message.recordType,
            predicate: messagePredicate,
            subscriptionID: CKSchema.SubscriptionID.newMessages,
            options: [.firesOnRecordCreation]
        )
        messageSubscription.notificationInfo = Self.messageNotificationInfo()

        // 自分が参加者に追加された会話(グループへの招待など).
        let conversationPredicate = NSPredicate(
            format: "%K CONTAINS %@",
            CKSchema.Conversation.participantIDs,
            me.rawValue
        )
        let conversationSubscription = CKQuerySubscription(
            recordType: CKSchema.Conversation.recordType,
            predicate: conversationPredicate,
            subscriptionID: CKSchema.SubscriptionID.conversations,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let silentInfo = CKSubscription.NotificationInfo()
        silentInfo.shouldSendContentAvailable = true
        conversationSubscription.notificationInfo = silentInfo

        var lastError: (any Error)?
        for subscription in [messageSubscription, conversationSubscription] {
            do {
                _ = try await database.save(subscription)
            } catch let error as CKError where error.code == .serverRejectedRequest {
                // 同じ ID の購読が既にある. 冪等に扱う.
                Log.push.debug("subscription already exists: \(subscription.subscriptionID, privacy: .public)")
            } catch {
                // 購読を作れなくてもアプリは動く(定期ポーリングにフォールバックする).
                Log.push.error("subscription failed: \(CloudKitErrorMapping.appError(from: error).localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        if let lastError {
            throw CloudKitErrorMapping.appError(from: lastError)
        }
    }

    /// プッシュに載せる情報.
    ///
    /// 本文は暗号化されておりサーバでは復号できないため, サーバ生成の通知には
    /// 送信者名だけを載せる. 本文入りの通知は, アプリが起動して復号できたときに
    /// ローカル通知として差し替える(`PushNotificationService`).
    private static func messageNotificationInfo() -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "PUSH_NEW_MESSAGE_TITLE"
        info.alertLocalizationKey = "PUSH_NEW_MESSAGE_BODY"
        info.alertLocalizationArgs = [CKSchema.Message.senderDisplayName]
        info.shouldBadge = true
        // アプリを起こして本文を復号し, より詳しい通知に差し替えるために使う.
        info.shouldSendContentAvailable = true
        info.desiredKeys = [CKSchema.Message.conversation]
        return info
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return
        }
        guard let queryNotification = notification as? CKQueryNotification else {
            eventHub.emit(.conversationsChanged)
            return
        }

        switch queryNotification.subscriptionID {
        case CKSchema.SubscriptionID.newMessages:
            // 参照フィールドは payload では recordName の文字列として届くが,
            // 環境によっては CKRecord.Reference のまま渡ることがあるため両方受ける.
            let raw = queryNotification.recordFields?[CKSchema.Message.conversation]
            let conversationName = (raw as? String) ?? (raw as? CKRecord.Reference)?.recordID.recordName
            if let conversationName {
                eventHub.emit(.messagesChanged(ConversationID(conversationName)))
            } else {
                eventHub.emit(.conversationsChanged)
            }
        case CKSchema.SubscriptionID.conversations:
            eventHub.emit(.conversationsChanged)
        default:
            eventHub.emit(.conversationsChanged)
        }
    }

    // MARK: - 内部キャッシュ

    func cacheConversationMetadata(participants: [UserID], owner: UserID, for conversationID: ConversationID) {
        participantCache[conversationID] = participants
        ownerCache[conversationID] = owner
    }

    func cachedParticipants(for conversationID: ConversationID) -> [UserID]? {
        participantCache[conversationID]
    }

    func cachedOwner(for conversationID: ConversationID) -> UserID? {
        ownerCache[conversationID]
    }

    func currentDisplayName() -> String? {
        cachedDisplayName
    }

    func setCachedDisplayName(_ name: String) {
        cachedDisplayName = name
    }
}

// MARK: -

extension Array {
    /// 一度にサーバへ投げる件数を抑えるための分割.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
