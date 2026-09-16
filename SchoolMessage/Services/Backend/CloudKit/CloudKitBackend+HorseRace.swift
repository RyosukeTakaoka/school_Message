import Foundation
import CloudKit

/// 競馬の `CloudKitBackend` 実装.
///
/// ## 暗号化しない理由
/// 掲示板と同じで, 誰でも読める場所として作っている. 締切後の種は
/// 「出そろった馬券」から計算するので, **全員が全員の馬券を読める**ことが
/// そもそも前提になっている(読めないと各自で検算ができない).
///
/// なりすましはチャットや掲示板と同じ方法で防ぐ. `bettorID` はクライアントの
/// 申告値なので, サーバが押印する `creatorUserRecordID` と突き合わせ,
/// 一致しないレコードは捨てる.
extension CloudKitBackend {

    // MARK: - 馬券

    func fetchHorseRaceBets(raceID: String) async throws -> [HorseRaceBet] {
        let me = try await currentUserID()
        let query = CKQuery(
            recordType: CKSchema.HorseRaceBet.recordType,
            predicate: NSPredicate(format: "%K == %@", CKSchema.HorseRaceBet.raceID, raceID)
        )
        query.sortDescriptors = [NSSortDescriptor(key: CKSchema.HorseRaceBet.createdAt, ascending: true)]

        let records = try await queryWithRetry(query, limit: Self.horseRaceBetLimit)
        return records.compactMap { Self.bet(from: $0, currentUserID: me) }
    }

    func placeHorseRaceBet(_ bet: HorseRaceBet) async throws {
        let record = CKRecord(
            recordType: CKSchema.HorseRaceBet.recordType,
            recordID: CKRecord.ID(recordName: bet.id)
        )
        record[CKSchema.HorseRaceBet.raceID] = bet.raceID as CKRecordValue
        record[CKSchema.HorseRaceBet.bettorID] = bet.bettorID.rawValue as CKRecordValue
        record[CKSchema.HorseRaceBet.kind] = bet.kind.rawValue as CKRecordValue
        record[CKSchema.HorseRaceBet.selections] = bet.selections as CKRecordValue
        record[CKSchema.HorseRaceBet.amount] = NSNumber(value: bet.amount)
        record[CKSchema.HorseRaceBet.createdAt] = bet.createdAt as CKRecordValue

        do {
            _ = try await saveWithRetry(record)
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    // MARK: - 結果の確定

    func fetchHorseRaceResult(raceID: String) async throws -> HorseRaceResult? {
        let recordID = CKRecord.ID(recordName: HorseRaceResult.recordName(raceID: raceID))
        do {
            let record = try await fetchWithRetry(recordID)
            return Self.result(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            // まだ誰も確定させていない.
            return nil
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }

    func lockHorseRaceResult(raceID: String, bets: [HorseRaceBet]) async throws -> HorseRaceResult {
        // すでに誰かが確定させていれば, それをそのまま使う.
        if let existing = try await fetchHorseRaceResult(raceID: raceID) { return existing }

        let result = HorseRaceResult(
            raceID: raceID,
            seed: HorseRaceResult.makeSeed(raceID: raceID, bets: bets),
            betIDs: bets.map(\.id).sorted(),
            lockedAt: .now
        )

        let record = CKRecord(
            recordType: CKSchema.HorseRaceResult.recordType,
            recordID: CKRecord.ID(recordName: result.recordName)
        )
        record[CKSchema.HorseRaceResult.raceID] = raceID as CKRecordValue
        record[CKSchema.HorseRaceResult.seed] = result.seed as CKRecordValue
        record[CKSchema.HorseRaceResult.betIDs] = result.betIDs as CKRecordValue
        record[CKSchema.HorseRaceResult.lockedAt] = result.lockedAt as CKRecordValue

        do {
            let saved = try await saveWithRetry(record)
            return Self.result(from: saved) ?? result
        } catch {
            // ほぼ同時に別の端末が確定させた場合は, 先にできたほうを使う.
            // recordName を開催日から決め打ちにしているので, ここで必ず 1 件に収束する.
            guard CloudKitErrorMapping.isAlreadyExists(error) else {
                throw CloudKitErrorMapping.appError(from: error)
            }
            guard let existing = try await fetchHorseRaceResult(raceID: raceID) else {
                throw CloudKitErrorMapping.appError(from: error)
            }
            return existing
        }
    }

    // MARK: - 内部

    private static func bet(from record: CKRecord, currentUserID: UserID) -> HorseRaceBet? {
        guard let raceID = record[CKSchema.HorseRaceBet.raceID] as? String,
              let bettorRaw = record[CKSchema.HorseRaceBet.bettorID] as? String,
              let kindRaw = record[CKSchema.HorseRaceBet.kind] as? String,
              let kind = HorseRaceBetKind(rawValue: kindRaw),
              let selections = Self.intList(record[CKSchema.HorseRaceBet.selections]),
              let amount = record[CKSchema.HorseRaceBet.amount] as? Int
        else { return nil }

        // なりすまし対策. 他人名義の馬券は数えない.
        guard CloudKitMapper.resolvedCreatorName(of: record, currentUserID: currentUserID) == bettorRaw else {
            Log.backend.notice("ignoring horse race bet with mismatched creator")
            return nil
        }
        // 買い目として成立していないものは捨てる(種の材料にも入れない).
        guard kind.isValid(selections: selections, horseCount: HorseRaceRules.horseCount),
              amount > 0
        else { return nil }

        return HorseRaceBet(
            id: record.recordID.recordName,
            raceID: raceID,
            bettorID: UserID(bettorRaw),
            kind: kind,
            selections: selections,
            amount: amount,
            createdAt: record[CKSchema.HorseRaceBet.createdAt] as? Date ?? record.creationDate ?? .now,
            // サーバが打刻した時刻. 種の材料にするので, ここは必ずサーバ側の値を使う.
            serverCreatedAt: record.creationDate
        )
    }

    private static func result(from record: CKRecord) -> HorseRaceResult? {
        guard let raceID = record[CKSchema.HorseRaceResult.raceID] as? String,
              let seed = record[CKSchema.HorseRaceResult.seed] as? String
        else { return nil }

        return HorseRaceResult(
            raceID: raceID,
            seed: seed,
            betIDs: record[CKSchema.HorseRaceResult.betIDs] as? [String] ?? [],
            lockedAt: record[CKSchema.HorseRaceResult.lockedAt] as? Date ?? record.creationDate ?? .now
        )
    }

    /// 整数の List を取り出す.
    ///
    /// CloudKit の Int(64) の List は `[Int]` としても `[NSNumber]` としても
    /// 返り得るため, どちらでも読めるようにしておく.
    private static func intList(_ value: Any?) -> [Int]? {
        if let numbers = value as? [Int] { return numbers }
        if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
        return nil
    }

    /// 1 レースで取ってくる馬券の上限.
    private static var horseRaceBetLimit: Int { 1000 }
}
