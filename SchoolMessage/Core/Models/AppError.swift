import Foundation

/// ユーザに提示するエラー.
///
/// 「原因不明のまま止まる」状態を作らないことが目的なので, すべてのケースが
/// 日本語の説明文と, 可能なら次にとるべき行動を持つ.
enum AppError: LocalizedError, Equatable {

    // MARK: アカウント / サインイン
    case iCloudAccountUnavailable
    case iCloudAccountRestricted
    case notRegistered
    case handleAlreadyTaken(String)

    // MARK: ネットワーク
    case offline
    case timedOut
    case serverBusy(retryAfter: TimeInterval?)
    case quotaExceeded

    // MARK: 権限 / 整合性
    case notAParticipant
    case senderMismatch
    case missingEncryptionKey
    case decryptionFailed
    case recipientHasNoPublicKey(displayName: String)

    // MARK: メディア
    case mediaTooLarge(limitMB: Int)
    case unsupportedMedia
    case mediaProcessingFailed
    case videoTooLong(limitSeconds: Int)

    // MARK: その他
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .iCloudAccountUnavailable:
            String(localized: "iCloud にサインインしていません")
        case .iCloudAccountRestricted:
            String(localized: "この iPad では iCloud の利用が制限されています")
        case .notRegistered:
            String(localized: "プロフィールが未登録です")
        case .handleAlreadyTaken(let handle):
            String(localized: "ユーザID「\(handle)」はすでに使われています")
        case .offline:
            String(localized: "インターネットに接続していません")
        case .timedOut:
            String(localized: "通信がタイムアウトしました")
        case .serverBusy:
            String(localized: "混み合っています")
        case .quotaExceeded:
            String(localized: "iCloud の保存容量の上限に達しました")
        case .notAParticipant:
            String(localized: "このチャットのメンバーではありません")
        case .senderMismatch:
            String(localized: "送信者を確認できないメッセージがありました")
        case .missingEncryptionKey:
            String(localized: "このチャットの鍵を取得できませんでした")
        case .decryptionFailed:
            String(localized: "メッセージを復号できませんでした")
        case .recipientHasNoPublicKey(let name):
            String(localized: "\(name) さんはまだ暗号鍵の準備ができていません")
        case .mediaTooLarge(let limit):
            String(localized: "ファイルが大きすぎます(上限 \(limit)MB)")
        case .unsupportedMedia:
            String(localized: "対応していない形式のファイルです")
        case .mediaProcessingFailed:
            String(localized: "写真・動画を準備できませんでした")
        case .videoTooLong(let limit):
            String(localized: "動画は \(limit) 秒までです")
        case .underlying(let message):
            message
        }
    }

    /// 次にとるべき行動. 提示できない場合は nil.
    ///
    /// `switch` 式ではなく `return` で書いているのは, `nil` を返す分岐が混ざると
    /// 各分岐の型(`String` と `String?`)が揃わず推論が通りにくいため.
    var recoverySuggestion: String? {
        switch self {
        case .iCloudAccountUnavailable:
            return String(localized: "「設定」アプリから iCloud にサインインしてください")
        case .iCloudAccountRestricted:
            return String(localized: "スクリーンタイムや機能制限の設定を確認してください")
        case .notRegistered:
            return String(localized: "表示名とユーザIDを登録してください")
        case .handleAlreadyTaken:
            return String(localized: "別のユーザIDを入力してください")
        case .offline:
            return String(localized: "Wi-Fi の接続を確認してください。接続が戻ると自動で送信します")
        case .timedOut, .serverBusy:
            return String(localized: "しばらくしてからもう一度お試しください")
        case .quotaExceeded:
            return String(localized: "iCloud の空き容量を増やしてください")
        case .missingEncryptionKey, .decryptionFailed:
            return String(localized: "チャットを開き直すか、送信者に再送を依頼してください")
        case .recipientHasNoPublicKey:
            return String(localized: "相手がアプリを一度起動すると送れるようになります")
        case .mediaTooLarge, .videoTooLong:
            return String(localized: "短く切り出すか、別のファイルを選んでください")
        case .unsupportedMedia, .mediaProcessingFailed:
            return String(localized: "別の写真・動画を選んでください")
        case .notAParticipant, .senderMismatch, .underlying:
            return nil
        }
    }

    /// 自動リトライして意味があるか. 恒久的な失敗を無限に叩き続けないための判断.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .serverBusy:
            true
        case .iCloudAccountUnavailable, .iCloudAccountRestricted, .notRegistered,
             .handleAlreadyTaken, .quotaExceeded, .notAParticipant, .senderMismatch,
             .missingEncryptionKey, .decryptionFailed, .recipientHasNoPublicKey,
             .mediaTooLarge, .unsupportedMedia, .mediaProcessingFailed, .videoTooLong,
             .underlying:
            false
        }
    }

    /// サーバから指定された再試行までの待ち時間.
    var suggestedRetryDelay: TimeInterval? {
        if case .serverBusy(let retryAfter) = self { return retryAfter }
        return nil
    }

    /// 任意の `Error` を `AppError` に寄せる.
    static func wrap(_ error: any Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .underlying(String(localized: "処理が中断されました")) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return .offline
            case NSURLErrorTimedOut:
                return .timedOut
            default:
                break
            }
        }
        return .underlying(error.localizedDescription)
    }
}
