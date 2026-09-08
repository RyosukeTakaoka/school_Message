import Foundation
import CloudKit

/// 掲示板の `CloudKitBackend` 実装.
///
/// ## チャットとの違い
/// 掲示板は「誰でも読める場所」なので, 会話鍵での暗号化を行わない。
/// 暗号化しても全員が鍵を持つことになり, 守っているように見えて何も
/// 守れないため(その状態を「暗号化済み」と呼ぶほうが有害).
///
/// 代わりに, 書き込みの真正性はチャットと同じ仕組みで守る。
/// `authorID` はクライアントの申告値なので, サーバが押印する
/// `creatorUserRecordID` と突き合わせ, 一致しないレコードは捨てる。
extension CloudKitBackend {

    // MARK: - スレッド

    func fetchBoardThreads() async throws -> [BoardThread] {
        let me = try await currentUserID()

        let query = CKQuery(
            recordType: CKSchema.BoardThread.recordType,
            predicate: NSPredicate(value: true)
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.BoardThread.lastPostedAt, ascending: false)]

        let records = try await queryWithRetry(query, limit: Self.boardThreadLimit)
        let threads = records.compactMap { Self.thread(from: $0, currentUserID: me) }
        guard !threads.isEmpty else { return [] }

        // 書き込み数はスレッド側に持たせていない(作成者しか更新できないため).
        // 一覧を出すときにまとめて数える.
        let counts = try await postCounts(for: threads.map(\.id), me: me)
        return threads.map { thread in
            var updated = thread
            updated.postCount = counts[thread.id] ?? 0
            return updated
        }
    }

    func createBoardThread(title: String, body: String) async throws -> BoardThread {
        let me = try await currentUserID()
        let validTitle = try BoardThread.validateTitle(title)
        let validBody = try BoardPost.validateBody(body)

        let thread = BoardThread(title: validTitle, authorID: me, postCount: 1)

        let record = CKRecord(
            recordType: CKSchema.BoardThread.recordType,
            recordID: CKRecord.ID(recordName: thread.id.rawValue)
        )
        record[CKSchema.BoardThread.title] = validTitle as CKRecordValue
        record[CKSchema.BoardThread.authorID] = me.rawValue as CKRecordValue
        record[CKSchema.BoardThread.createdAt] = thread.createdAt as CKRecordValue
        record[CKSchema.BoardThread.lastPostedAt] = thread.lastPostedAt as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        // 1 番目の書き込み. ここで失敗してもスレッド自体は残るので,
        // 「タイトルだけのスレッド」になるだけで壊れはしない.
        _ = try await createBoardPost(in: thread.id, body: validBody)
        return thread
    }

    // MARK: - 書き込み

    func fetchBoardPosts(in threadID: ThreadID) async throws -> [BoardPost] {
        let me = try await currentUserID()
        let records = try await postRecords(in: threadID)

        // 通し番号は保存せず, 古い順に並べてから振る.
        // 番号をレコードに持たせると, 同時書き込みで重複や欠番が生じるため.
        let posts = records
            .compactMap { Self.post(from: $0, currentUserID: me) }
            .sorted { $0.createdAt < $1.createdAt }

        return posts.enumerated().map { index, post in
            var numbered = post
            numbered.number = index + 1
            return numbered
        }
    }

    func createBoardPost(in threadID: ThreadID, body: String) async throws -> BoardPost {
        let me = try await currentUserID()
        let validBody = try BoardPost.validateBody(body)

        let post = BoardPost(threadID: threadID, authorID: me, body: validBody)
        let record = CKRecord(
            recordType: CKSchema.BoardPost.recordType,
            recordID: CKRecord.ID(recordName: post.id.rawValue)
        )
        record[CKSchema.BoardPost.thread] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: threadID.rawValue),
            action: .none
        )
        record[CKSchema.BoardPost.authorID] = me.rawValue as CKRecordValue
        record[CKSchema.BoardPost.body] = validBody as CKRecordValue
        record[CKSchema.BoardPost.createdAt] = post.createdAt as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }

        await touchThreadIfMine(threadID, me: me)
        return post
    }

    /// スレッドの「最後の書き込み時刻」を更新する.
    ///
    /// Public Database ではレコードを更新できるのは作成者だけなので,
    /// **自分が立てたスレッドのときしか成功しない**. 他人のスレッドに
    /// 書き込んだ場合は一覧の並び順が古いままになるが, 書き込み自体は
    /// 正しく保存される. 並び順のためだけに書き込み権限を緩めると,
    /// 第三者にスレッドを書き換えられる余地が生まれるので, ここは諦める.
    private func touchThreadIfMine(_ threadID: ThreadID, me: UserID) async {
        let recordID = CKRecord.ID(recordName: threadID.rawValue)
        guard let record = try? await fetchWithRetry(recordID),
              CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == me.rawValue
        else { return }

        record[CKSchema.BoardThread.lastPostedAt] = Date.now as CKRecordValue
        _ = try? await saveWithRetry(record)
    }

    // MARK: - 内部

    private func postRecords(in threadID: ThreadID) async throws -> [CKRecord] {
        let query = CKQuery(
            recordType: CKSchema.BoardPost.recordType,
            predicate: NSPredicate(
                format: "%K == %@",
                CKSchema.BoardPost.thread,
                CKRecord.Reference(recordID: CKRecord.ID(recordName: threadID.rawValue), action: .none)
            )
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.BoardPost.createdAt, ascending: true)]
        return try await queryWithRetry(query, limit: Self.boardPostLimit)
    }

    /// スレッドごとの書き込み数.
    private func postCounts(for threadIDs: [ThreadID], me: UserID) async throws -> [ThreadID: Int] {
        let references = threadIDs.map {
            CKRecord.Reference(recordID: CKRecord.ID(recordName: $0.rawValue), action: .none)
        }
        let query = CKQuery(
            recordType: CKSchema.BoardPost.recordType,
            predicate: NSPredicate(format: "%K IN %@", CKSchema.BoardPost.thread, references)
        )
        // 数えるだけなので本文は運ばない.
        let records = try await queryWithRetry(query, desiredKeys: [CKSchema.BoardPost.thread], limit: Self.boardPostLimit)

        var counts: [ThreadID: Int] = [:]
        for record in records {
            guard let reference = record[CKSchema.BoardPost.thread] as? CKRecord.Reference else { continue }
            counts[ThreadID(reference.recordID.recordName), default: 0] += 1
        }
        return counts
    }

    private static func thread(from record: CKRecord, currentUserID: UserID) -> BoardThread? {
        guard let title = record[CKSchema.BoardThread.title] as? String,
              let authorRaw = record[CKSchema.BoardThread.authorID] as? String
        else { return nil }
        // なりすまし対策. 申告された作者とサーバ押印の作成者が一致するものだけ採用する.
        guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: currentUserID) == authorRaw else {
            Log.backend.notice("ignoring board thread with mismatched creator")
            return nil
        }

        let createdAt = record[CKSchema.BoardThread.createdAt] as? Date ?? record.creationDate ?? .now
        return BoardThread(
            id: ThreadID(record.recordID.recordName),
            title: title,
            authorID: UserID(authorRaw),
            createdAt: createdAt,
            lastPostedAt: record[CKSchema.BoardThread.lastPostedAt] as? Date ?? createdAt,
            postCount: 0
        )
    }

    private static func post(from record: CKRecord, currentUserID: UserID) -> BoardPost? {
        guard let reference = record[CKSchema.BoardPost.thread] as? CKRecord.Reference,
              let body = record[CKSchema.BoardPost.body] as? String,
              let authorRaw = record[CKSchema.BoardPost.authorID] as? String
        else { return nil }
        guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: currentUserID) == authorRaw else {
            Log.backend.notice("ignoring board post with mismatched creator")
            return nil
        }

        return BoardPost(
            id: PostID(record.recordID.recordName),
            threadID: ThreadID(reference.recordID.recordName),
            authorID: UserID(authorRaw),
            body: body,
            createdAt: record[CKSchema.BoardPost.createdAt] as? Date ?? record.creationDate ?? .now,
            number: 0
        )
    }

    /// 一覧に出すスレッド数の上限.
    private static var boardThreadLimit: Int { 200 }
    /// 1 スレッドあたりの書き込み取得数の上限.
    private static var boardPostLimit: Int { 500 }
}
