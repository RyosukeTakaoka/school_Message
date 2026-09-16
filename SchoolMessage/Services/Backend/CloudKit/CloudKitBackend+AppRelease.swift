import Foundation
import CloudKit

/// 「これ未満のビルドでは遊べない」下限の取得.
///
/// レコードは 1 件だけで, recordName を決め打ちにしているのでクエリしない
/// (クエリ用のインデックスが要らない). 書き込みはアプリからは行わず,
/// CloudKit Console から手で直す(`docs/CLOUDKIT_SCHEMA.md` 参照).
extension CloudKitBackend {

    func fetchRequiredRelease() async throws -> RequiredRelease? {
        let recordID = CKRecord.ID(recordName: CKSchema.AppRelease.recordName)
        do {
            let record = try await fetchWithRetry(recordID)
            guard let minimum = record[CKSchema.AppRelease.minimumBuild] as? Int else { return nil }
            let message = record[CKSchema.AppRelease.message] as? String
            return RequiredRelease(
                minimumBuild: minimum,
                message: message?.isEmpty == true ? nil : message
            )
        } catch let error as CKError where error.code == .unknownItem {
            // 下限をまだ決めていない(レコードが無い). 誰も止めない.
            return nil
        } catch {
            throw CloudKitErrorMapping.appError(from: error)
        }
    }
}
