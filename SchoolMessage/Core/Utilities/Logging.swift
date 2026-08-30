import Foundation
import OSLog

/// カテゴリ別のロガー.
///
/// メッセージ本文やユーザ名など個人情報はログに出さない.
/// OSLog の文字列補間は既定で `private` 扱いになるため, 明示的に `public` を
/// 指定するのは ID や状態などの非個人情報だけに限ること.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.schoolmessage.app"

    static let backend = Logger(subsystem: subsystem, category: "backend")
    static let crypto = Logger(subsystem: subsystem, category: "crypto")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let outbox = Logger(subsystem: subsystem, category: "outbox")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
