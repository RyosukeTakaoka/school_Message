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

        // 1 回も遊んでいない人をあとで外すので, その分だけ多めに取っておく
        // (「遊んだかどうか」は CloudKit の検索条件では書けないため).
        let records = try await queryWithRetry(query, limit: min(limit * 3, Self.rankingFetchLimit))

        let entries: [ChipRankingEntry] = records.compactMap { record in
            guard let ownerRaw = record[CKSchema.PlayerWallet.ownerID] as? String else { return nil }
            // なりすまし対策. 他人ぶんの財布を勝手に作られても採用しない.
            guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: me) == ownerRaw else {
                Log.backend.notice("ignoring wallet with mismatched creator")
                return nil
            }
            let playedGameIDs = record[CKSchema.PlayerWallet.settledGameIDs] as? [String] ?? []
            // 配られたままの 1,000 CHIP で並ばれるとおもしろくないので,
            // 1 回も遊んでいない人はランキングに入れない.
            guard !playedGameIDs.isEmpty else { return nil }

            return ChipRankingEntry(
                ownerID: UserID(ownerRaw),
                balance: record[CKSchema.PlayerWallet.balance] as? Int ?? 0,
                playedGameCount: playedGameIDs.count,
                updatedAt: record[CKSchema.PlayerWallet.updatedAt] as? Date ?? record.modificationDate ?? .now
            )
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

    /// ランキングを組み立てるときに, 1 度に取ってくるレコード数の上限.
    private static var rankingFetchLimit: Int { 200 }

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
