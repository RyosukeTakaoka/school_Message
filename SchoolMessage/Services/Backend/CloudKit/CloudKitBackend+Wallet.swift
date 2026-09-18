import Foundation
import CloudKit

/// CHIP(アプリ内ゲームのポイント)の保存.
///
/// ## なぜ「差分」で更新するのか
/// 残高を「読んで → 足して → まるごと書き戻す」とき, 別のゲームの精算が
/// 同時に走ると, 後から書いたほうが前の更新を消してしまう
/// (Aのゲームで -100, Bのゲームで +50 が同時に起きると片方が消える).
///
/// そこで, 呼び出し側からは**差分だけ**を受け取る. CloudKit が
/// 「サーバ側のレコードが変わっている」と教えてきたら, 取り直した最新の残高に
/// 同じ差分をもう一度当てて保存し直す. これで両方の増減が残る.
extension CloudKitBackend {

    func fetchMyWallet() async throws -> PlayerWallet {
        let userID = try await currentUserID()
        let record = try await fetchOrCreateWalletRecord(for: userID)
        let wallet = Self.wallet(from: record, ownerID: userID)

        // 0 になった起点が抜けていれば補う(抜けていると復活日が決まらないため).
        guard let stamped = wallet.stampingBankruptcyIfNeeded() else { return wallet }
        Self.write(stamped, into: record)
        guard let saved = try? await database.save(record) else { return stamped }
        return Self.wallet(from: saved, ownerID: userID)
    }

    func claimChipRevival(now: Date) async throws -> PlayerWallet {
        let userID = try await currentUserID()
        var attempt = 0

        while true {
            let record = try await fetchOrCreateWalletRecord(for: userID)
            let current = Self.wallet(from: record, ownerID: userID)
            // まだ回せない(挑戦できる日の前 / すでに受け取り済み)なら何もしない.
            guard current.isRevivalDue(now: now) else { return current }

            Self.write(current.claimingRevival(now: now), into: record)
            do {
                let saved = try await database.save(record)
                return Self.wallet(from: saved, ownerID: userID)
            } catch let error as CKError where error.code == .serverRecordChanged {
                attempt += 1
                guard attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw CloudKitErrorMapping.appError(from: error)
                }
            } catch {
                throw CloudKitErrorMapping.appError(from: error)
            }
        }
    }

    func applyChipDelta(_ delta: Int, gameID: String?) async throws -> PlayerWallet {
        let userID = try await currentUserID()
        var attempt = 0

        while true {
            let record = try await fetchOrCreateWalletRecord(for: userID)
            let current = Self.wallet(from: record, ownerID: userID)

            // 同じ対戦をもう一度精算しない(端末を変えても効くよう, 残高と一緒に記録している).
            if let gameID, current.hasSettled(gameID: gameID) { return current }

            let updated = current.applying(delta: delta, gameID: gameID)
            Self.write(updated, into: record)

            do {
                let saved = try await database.save(record)
                return Self.wallet(from: saved, ownerID: userID)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // 別のゲームの精算と競合した. 最新を取り直して同じ差分を当て直す.
                attempt += 1
                guard attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw CloudKitErrorMapping.appError(from: error)
                }
                Log.backend.notice("chip balance conflicted; re-applying delta")
            } catch {
                throw CloudKitErrorMapping.appError(from: error)
            }
        }
    }

    /// CHIP ランキングを組み立てる.
    ///
    /// ## 以前の実装の問題(取りこぼし)
    /// 「遊んだかどうか」は CloudKit の検索条件(`NSPredicate`)には書けない
    /// フィールド(`settledGameIDs` が空かどうか)なので, 以前は
    /// 「残高の高い順に `limit * 3` 件だけ先に取ってから, 遊んでいない人を
    /// あとで除く」という作りだった.
    ///
    /// これだと, 配られたままの初期値(1,000 CHIP)で止まっている**未プレイの
    /// 人**が `limit * 3` 人より多くいると, 実際に遊んで**負けて残高が
    /// 1,000 を下回った人**は全員その未プレイの塊より下に並ぶことになり,
    /// 最初に取ってきた分の中に一度も入らないまま「遊んでいない人」と
    /// 一緒に切り捨てられてしまう. 本人の CHIP はサーバ側で正しく精算
    /// されているのに, ランキングにだけ永久に出てこない, という不具合になる.
    ///
    /// ここでは, 残高の高い順にページを読み進めながらその場で選別し,
    /// 「実際に遊んだ人」が `limit` 人集まるか, 読める分をすべて読み終える
    /// までページを取り続ける.
    func fetchChipRanking(limit: Int) async throws -> [ChipRankingEntry] {
        let me = try await currentUserID()

        // `recordID` を Queryable にしなくて済むよう, 元から索引のある
        // `balance` への比較で全件を拾う(掲示板のスレッド一覧と同じ考え方).
        let query = CKQuery(
            recordType: CKSchema.PlayerWallet.recordType,
            predicate: NSPredicate(format: "%K >= %@", CKSchema.PlayerWallet.balance, NSNumber(value: 0))
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: CKSchema.PlayerWallet.balance, ascending: false)
        ]

        var entries: [ChipRankingEntry] = []
        var cursor: CKQueryOperation.Cursor?
        var scanned = 0
        var attempt = 0
        let pageSize = min(max(limit, 1) * 3, CKQueryOperation.maximumResults)

        pagingLoop: while true {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            do {
                if let cursor {
                    page = try await database.records(continuingMatchFrom: cursor, resultsLimit: pageSize)
                } else {
                    page = try await database.records(matching: query, resultsLimit: pageSize)
                }
            } catch {
                // レコード型がまだ CloudKit のスキーマに一度も存在しない
                // (＝誰も CHIP を触ったことがない)場合はここに来る. 0 件として扱う.
                guard !CloudKitErrorMapping.isUnknownItem(error) else { break pagingLoop }

                let appError = CloudKitErrorMapping.appError(from: error)
                attempt += 1
                guard appError.isRetryable, attempt < AppConstants.Timing.maxRetryAttempts else {
                    throw appError
                }
                let delay = appError.suggestedRetryDelay
                    ?? AsyncRetry.backoffDelay(attempt: attempt, baseDelay: AppConstants.Timing.retryBaseDelay)
                try await Task.sleep(for: .seconds(delay))
                continue pagingLoop  // cursor は進めていないので, 同じページをもう一度試す.
            }
            attempt = 0

            for (_, result) in page.matchResults {
                scanned += 1
                guard case .success(let record) = result else { continue }
                guard let ownerRaw = record[CKSchema.PlayerWallet.ownerID] as? String else { continue }
                // なりすまし対策. 他人ぶんの財布を勝手に作られても採用しない.
                guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == ownerRaw else {
                    Log.backend.notice("ignoring wallet with mismatched creator")
                    continue
                }
                let playedGameIDs = record[CKSchema.PlayerWallet.settledGameIDs] as? [String] ?? []
                // 配られたままの 1,000 CHIP で並ばれるとおもしろくないので,
                // 1 回も遊んでいない人はランキングに入れない.
                guard !playedGameIDs.isEmpty else { continue }

                entries.append(
                    ChipRankingEntry(
                        ownerID: UserID(ownerRaw),
                        balance: record[CKSchema.PlayerWallet.balance] as? Int ?? 0,
                        playedGameCount: playedGameIDs.count,
                        updatedAt: record[CKSchema.PlayerWallet.updatedAt] as? Date ?? record.modificationDate ?? .now
                    )
                )
            }

            cursor = page.queryCursor
            // 欲しい人数が集まった / これ以上ページが無い / 読みすぎを防ぐ上限に
            // 達した, のいずれかで打ち切る.
            guard cursor != nil, entries.count < limit, scanned < Self.rankingScanLimit else { break pagingLoop }
        }

        return Array(entries.prefix(limit))
    }

    func fetchWalletBalances(ownerIDs: [UserID]) async throws -> [UserID: Int] {
        guard !ownerIDs.isEmpty else { return [:] }
        let me = try await currentUserID()

        let query = CKQuery(
            recordType: CKSchema.PlayerWallet.recordType,
            predicate: NSPredicate(format: "%K IN %@", CKSchema.PlayerWallet.ownerID, ownerIDs.map(\.rawValue))
        )
        let records = try await queryWithRetry(
            query,
            desiredKeys: [CKSchema.PlayerWallet.ownerID, CKSchema.PlayerWallet.balance],
            limit: max(ownerIDs.count, 1)
        )

        var balances: [UserID: Int] = [:]
        for record in records {
            guard let ownerRaw = record[CKSchema.PlayerWallet.ownerID] as? String else { continue }
            // なりすまし対策. 他人ぶんの財布を勝手に作られても読まない.
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == ownerRaw else {
                Log.backend.notice("ignoring wallet with mismatched creator")
                continue
            }
            balances[UserID(ownerRaw)] = record[CKSchema.PlayerWallet.balance] as? Int ?? 0
        }
        return balances
    }

    /// ランキングを組み立てるとき, ページを読み進めて調べる財布の総数の上限.
    ///
    /// 「遊んだ人」がなかなか集まらない場合(未プレイの人がとても多い等)に,
    /// 際限なくページを読み続けないための保険. 学校 1 クラス〜数クラス分の
    /// 利用者数であれば, 全員を読み切ってなお足りる余裕のある値にしてある.
    private static var rankingScanLimit: Int { 2000 }

    // MARK: - 内部

    /// 自分の財布レコード. 無ければ初期値で作って保存する
    /// (作っておくことで, 初回からランキングにも並ぶ).
    private func fetchOrCreateWalletRecord(for userID: UserID) async throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: CKSchema.PlayerWallet.recordName(for: userID))
        do {
            return try await fetchWithRetry(recordID)
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: CKSchema.PlayerWallet.recordType, recordID: recordID)
            Self.write(PlayerWallet(ownerID: userID), into: record)
            do {
                return try await saveWithRetry(record)
            } catch {
                // 同時に 2 か所から作ろうとした場合は, 先に出来たものを使う.
                guard CloudKitErrorMapping.isAlreadyExists(error) else {
                    throw CloudKitErrorMapping.appError(from: error)
                }
                return try await fetchWithRetry(recordID)
            }
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    private static func write(_ wallet: PlayerWallet, into record: CKRecord) {
        record[CKSchema.PlayerWallet.ownerID] = wallet.ownerID.rawValue as CKRecordValue
        record[CKSchema.PlayerWallet.balance] = NSNumber(value: wallet.balance)
        if let bankruptAt = wallet.bankruptAt {
            record[CKSchema.PlayerWallet.bankruptAt] = bankruptAt as CKRecordValue
        } else {
            record[CKSchema.PlayerWallet.bankruptAt] = nil
        }
        if let lastRevivalAttemptAt = wallet.lastRevivalAttemptAt {
            record[CKSchema.PlayerWallet.lastRevivalAttemptAt] = lastRevivalAttemptAt as CKRecordValue
        } else {
            record[CKSchema.PlayerWallet.lastRevivalAttemptAt] = nil
        }
        record[CKSchema.PlayerWallet.settledGameIDs] = wallet.settledGameIDs as CKRecordValue
        record[CKSchema.PlayerWallet.updatedAt] = wallet.updatedAt as CKRecordValue
    }

    private static func wallet(from record: CKRecord, ownerID: UserID) -> PlayerWallet {
        PlayerWallet(
            ownerID: ownerID,
            balance: record[CKSchema.PlayerWallet.balance] as? Int ?? PlayerWallet.initialBalance,
            bankruptAt: record[CKSchema.PlayerWallet.bankruptAt] as? Date,
            lastRevivalAttemptAt: record[CKSchema.PlayerWallet.lastRevivalAttemptAt] as? Date,
            settledGameIDs: record[CKSchema.PlayerWallet.settledGameIDs] as? [String] ?? [],
            updatedAt: record[CKSchema.PlayerWallet.updatedAt] as? Date ?? record.modificationDate ?? .now
        )
    }
}
