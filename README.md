# School Message

学校で iPad を使って友達と連絡するためのメッセージアプリ。

> スマートフォンが使えない学校生活でも、iPad から友達と簡単に連絡できる。

休み時間・昼休み・放課後・部活・クラス連絡といった短いやりとりに絞り、
**テキスト / 写真 / 動画** の 3 つだけを速く送れることを目標にしています。

## できること

| 分類 | 機能 |
|---|---|
| メッセージ | 1 対 1 チャット、グループチャット、テキスト / 写真 / 動画の送信、履歴、送信時刻、自分と相手の区別 |
| ユーザ | iCloud アカウントでの登録、表示名、プロフィール画像、ユーザID 検索、友達追加 / 一覧 |
| グループ | 作成、グループ名 / 画像、メンバー追加 / 一覧、退出 |
| 写真・動画 | フォトライブラリからの選択、その場で撮影、圧縮とサムネイル生成、タップで拡大 / 全画面再生 |
| 未読 | チャットごとの未読数、開いたら既読 |
| 通知 | 新着メッセージのプッシュ通知（本文表示の on/off つき） |

音声通話・スタンプ・タイムライン・広告などは意図的に入れていません。

## 動かすまで

1. `SchoolMessage.xcodeproj` を Xcode 16 以降で開く
2. **Signing & Capabilities** で自分の Team を選ぶ
3. Bundle Identifier と CloudKit コンテナ名を自分のものに変える
   （`Config/`、`SchoolMessage/App/AppConstants.swift`）
4. CloudKit ダッシュボードでレコードタイプとインデックスを作る
5. iPad 2 台（または iPad + シミュレータ）に、**別々の iCloud アカウント**でインストール

詳しい手順は [`docs/SETUP.md`](docs/SETUP.md) にあります。

## 構成

```
SchoolMessage/
  App/          アプリ起動、依存の組み立て、定数
  Core/         モデルと小さなユーティリティ（UI にも通信にも依存しない）
  Services/
    Backend/    ChatBackend プロトコルと CloudKit / インメモリの実装
    Crypto/     鍵管理と暗号化
    Media/      写真・動画の圧縮、保存先、遅延ダウンロード
    Outbox/     送信待ちの永続キュー
    Sync/       ChatStore（画面が読む唯一の状態）
    Network/    到達性の監視
    Notifications/  プッシュと通知設定
  Features/     画面（SwiftUI）
Config/         Info.plist と entitlements
docs/           設計・スキーマ・手順書
```

- **View にロジックを置かない**。画面は `ChatStore` を読むだけで、
  取得・送信・整合性の維持はすべてサービス層にあります。
- **重い処理は actor に逃がす**。暗号化・圧縮・通信はメインスレッドを止めません。
- **バックエンドは差し替え可能**。`ChatBackend` プロトコルにより、
  CloudKit 実装とプレビュー用のインメモリ実装を入れ替えられます。

## ドキュメント

| ファイル | 内容 |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 全体設計と、設計上の判断とその理由 |
| [`docs/CLOUDKIT_SCHEMA.md`](docs/CLOUDKIT_SCHEMA.md) | レコードタイプ、フィールド、必要なインデックス |
| [`docs/SECURITY.md`](docs/SECURITY.md) | 暗号化の設計、なりすまし対策、既知の限界 |
| [`docs/NOTIFICATIONS.md`](docs/NOTIFICATIONS.md) | 通知の仕組みと、本文を確実に出すための次の一手 |
| [`docs/SETUP.md`](docs/SETUP.md) | Xcode / CloudKit の設定手順 |
| [`docs/TESTING.md`](docs/TESTING.md) | 実機での確認シナリオ（A〜E） |

## 現状

このリポジトリには **実装一式と設定手順** が入っていますが、
**まだ Xcode でのビルドと実機確認を行っていません**。
Phase 12（実機確認）は [`docs/TESTING.md`](docs/TESTING.md) の手順で実施してください。
