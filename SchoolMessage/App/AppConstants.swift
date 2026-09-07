import Foundation
import CoreGraphics

/// アプリ全体で使う定数. マジックナンバーをコード中に散らさないための置き場.
enum AppConstants {

    /// CloudKit コンテナ識別子. Xcode の Signing & Capabilities と一致させること.
    static let cloudKitContainerIdentifier = "iCloud.com.schoolmessage.app"

    enum Legal {
        /// 起動時に利用規約・プライバシーポリシーへの同意を要求するか.
        ///
        /// 友人・知人など身内だけで使っている段階では, App Store Connect 側の
        /// 準備(プライバシーポリシーの公開 URL, 「App のプライバシー」申告,
        /// 開発者名・連絡先の記入)を済ませなくても TestFlight に出せるよう,
        /// 既定で無効にしている.
        ///
        /// 本文自体は `LegalText.swift` / `docs/PRIVACY_POLICY.md` /
        /// `docs/TERMS_OF_SERVICE.md` に残したままなので, 配布先を広げる
        /// (学校の生徒全体, 一般公開など)タイミングで `true` に戻すだけでよい.
        /// その際は `docs/SETUP.md` の「公開前にやること」の手順を先に行うこと.
        static let requiresConsent = false
    }

    enum Layout {
        /// NavigationSplitView のサイドバー幅. iPad 縦向きでも一覧が読める幅を確保する.
        static let sidebarIdealWidth: CGFloat = 320
        static let sidebarMinWidth: CGFloat = 280
        static let sidebarMaxWidth: CGFloat = 420

        /// 吹き出しの最大幅比率. iPad の大画面で一行が長くなりすぎるのを防ぐ.
        static let bubbleMaxWidthRatio: CGFloat = 0.62
        static let bubbleCornerRadius: CGFloat = 18
        static let bubbleHorizontalPadding: CGFloat = 14
        static let bubbleVerticalPadding: CGFloat = 9

        static let avatarSmall: CGFloat = 36
        static let avatarMedium: CGFloat = 48
        static let avatarLarge: CGFloat = 96

        /// チャット内のメディアサムネイルの最大表示辺長.
        static let mediaBubbleMaxEdge: CGFloat = 260

        static let composerMinHeight: CGFloat = 38
        static let composerMaxHeight: CGFloat = 140

        static let standardSpacing: CGFloat = 12
        static let compactSpacing: CGFloat = 6
    }

    enum Paging {
        /// 1 チャットあたり初回に読み込むメッセージ数.
        /// 起動直後の表示速度と, 会話の文脈が読めることのバランス.
        static let initialMessagePageSize = 50
        /// 追加読み込み時の件数.
        static let olderMessagePageSize = 50
        /// ユーザ検索の最大件数.
        static let userSearchResultLimit = 30
    }

    enum Timing {
        /// CloudKit 操作のタイムアウト.
        static let networkTimeout: TimeInterval = 30
        /// プッシュが届かない環境(通知拒否など)のためのフォールバックポーリング間隔.
        static let fallbackPollInterval: TimeInterval = 25
        /// チャットを開いている間のポーリング間隔.
        /// プッシュ通知(CloudKit 購読)の到達を待たずに, 相手の新着メッセージを
        /// 短い間隔で拾いにいく. 会話中は体感速度を優先する.
        static let activeConversationPollInterval: TimeInterval = 3
        /// 送信取り消しなど, 既存メッセージの書き換えを確認する間隔.
        /// 新着ほど頻度は要らないので, 新着の取得より長めにする.
        static let revisionCheckInterval: TimeInterval = 12
        /// 送信リトライの初期待機時間. 以降は指数バックオフ.
        static let retryBaseDelay: TimeInterval = 1.5
        static let maxRetryAttempts = 4
        /// 「送信中」表示をこの時間を超えて維持しない(ハングして見えるのを防ぐ).
        static let sendingStallThreshold: TimeInterval = 60
    }

    enum Validation {
        static let displayNameMaxLength = 24
        static let handleMinLength = 3
        static let handleMaxLength = 20
        static let groupNameMaxLength = 32
        static let messageTextMaxLength = 2000
        static let groupMemberMaxCount = 100
        /// 使用可能なハンドル文字(英小文字・数字・アンダースコア).
        static let handleAllowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
    }
}
