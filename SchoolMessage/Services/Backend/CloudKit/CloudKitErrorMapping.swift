import Foundation
import CloudKit

/// CloudKit のエラーをアプリのエラーに翻訳する.
///
/// `CKError` をそのまま UI まで持ち上げると英語のメッセージが出てしまい,
/// 「何が起きたのか / 次に何をすればよいのか」が伝わらない. ここで
/// 「再試行して意味があるか」も含めて判断できる形に落とす.
enum CloudKitErrorMapping {

    static func appError(from error: any Error) -> AppError {
        guard let ckError = error as? CKError else {
            return AppError.wrap(error)
        }

        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return .offline

        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            let retryAfter = ckError.retryAfterSeconds
            return .serverBusy(retryAfter: retryAfter)

        case .notAuthenticated:
            return .iCloudAccountUnavailable

        case .managedAccountRestricted, .permissionFailure:
            return .iCloudAccountRestricted

        case .quotaExceeded:
            return .quotaExceeded

        case .limitExceeded:
            // 1 リクエストが大きすぎる. 呼び出し側で分割して再試行する想定.
            return .underlying(String(localized: "一度に送るデータが多すぎます"))

        case .unknownItem:
            // どの操作でこれが起きたかを追えるよう, 生のエラー内容を残しておく.
            // (「データが見つかりませんでした」自体は正常系でも出る文言なので,
            // 想定外の場面で出ている場合はここのログで切り分ける)
            Log.backend.notice("unknownItem: \(ckError.localizedDescription, privacy: .public)")
            return .underlying(String(localized: "データが見つかりませんでした"))

        case .serverRecordChanged:
            return .underlying(String(localized: "他の端末での変更と競合しました"))

        case .partialFailure:
            // 部分失敗の中で最も深刻なものを代表として返す.
            if let partial = ckError.partialErrorsByItemID?.values.first {
                return appError(from: partial)
            }
            return .underlying(ckError.localizedDescription)

        case .changeTokenExpired:
            return .underlying(String(localized: "同期状態を再取得します"))

        default:
            Log.backend.error("unmapped CKError code \(ckError.code.rawValue, privacy: .public)")
            return .underlying(ckError.localizedDescription)
        }
    }

    /// このエラーで自動リトライしてよいか.
    static func isRetryable(_ error: any Error) -> Bool {
        appError(from: error).isRetryable
    }

    /// 保存済みレコードとの競合か(再送時の冪等判定に使う).
    static func isAlreadyExists(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged { return true }
        if ckError.code == .partialFailure,
           let partials = ckError.partialErrorsByItemID?.values {
            return partials.contains { ($0 as? CKError)?.code == .serverRecordChanged }
        }
        return false
    }

    /// 「対象のレコード(タイプ)が存在しない」を表すエラーか.
    ///
    /// クエリ操作では, レコードタイプがまだスキーマに一度も存在しない場合,
    /// 単純な `.unknownItem` としてではなく `.partialFailure` に包まれて
    /// 返ってくることがある. 呼び出し側の判定を 1 箇所にまとめる.
    static func isUnknownItem(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .unknownItem { return true }
        if ckError.code == .partialFailure,
           let partials = ckError.partialErrorsByItemID?.values {
            return partials.contains { ($0 as? CKError)?.code == .unknownItem }
        }
        return false
    }
}
