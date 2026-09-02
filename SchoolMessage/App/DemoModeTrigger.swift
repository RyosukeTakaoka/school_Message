import Foundation
import Observation

/// 「デモモードで試す」ボタンから, アプリのバックエンドをインメモリ実装に
/// 差し替えるための合図.
///
/// `AppEnvironment` は `SchoolMessageApp` の `@State` として保持されており,
/// 深い階層にある `BlockedView` / `RegistrationView` から直接差し替えることは
/// できない. Environment 越しにこの小さなオブジェクトへ「要求した」ことだけを
/// 伝え, 実際の差し替えはアプリのルートで行う.
///
/// ## なぜデモモードが必要か
/// このアプリは iCloud アカウントでサインインする方式のため, 従来型の
/// ユーザー名/パスワードによるデモアカウントを用意できない。また新規に
/// サインインしても友達が誰もいない状態から始まるため, App Store の
/// 審査担当者がチャット機能を確認できず, 「アプリの一部にアクセスできない」
/// という指摘(Guideline 2.1(a))を受けやすい。
///
/// Apple のガイドラインでは, デモアカウントの代わりに「アプリの全機能を
/// 提示するデモンストレーションモード」を用意することも明示的に認められている。
/// そこで, 友達・グループ・メッセージ履歴があらかじめ入った状態の
/// インメモリ実装(`InMemoryChatBackend`, 元々 SwiftUI プレビュー用に用意していた
/// もの)を, 審査時にも実際に選べるようにする.
@MainActor
@Observable
final class DemoModeTrigger {
    var isRequested = false
}
