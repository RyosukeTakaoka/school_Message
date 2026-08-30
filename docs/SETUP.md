# セットアップ手順

## 必要なもの

- Xcode 16 以降（プロジェクトは同期グループ形式 `objectVersion = 77` を使用）
- iOS 17.0 以降の iPad **2 台**、または iPad 1 台 + Mac のシミュレータ
- 有償の Apple Developer Program アカウント
  （CloudKit と APNs は無料アカウントでは使えません）
- **別々の iCloud アカウント 2 つ**（1 対 1 チャットの確認に必要）

## 1. プロジェクトを開く

```
open SchoolMessage.xcodeproj
```

ソースは `PBXFileSystemSynchronizedRootGroup` で同期しているため、
`SchoolMessage/` にファイルを足せば自動でターゲットに入ります。
`.pbxproj` を手で編集する必要はありません。

## 2. 識別子を自分のものに変える

3 か所を揃えてください。

| 場所 | 変更するもの |
|---|---|
| プロジェクト設定 → Signing & Capabilities | Team、Bundle Identifier |
| `Config/SchoolMessage.entitlements` | `iCloud.<あなたの Bundle ID>` |
| `SchoolMessage/App/AppConstants.swift` | `cloudKitContainerIdentifier` |

```swift
// AppConstants.swift
static let cloudKitContainerIdentifier = "iCloud.com.example.schoolmessage"
```

## 3. Capabilities を追加する

Signing & Capabilities で以下を追加します。

- **iCloud** → CloudKit にチェック → 上で決めたコンテナを選択
- **Push Notifications**
- **Background Modes** → Remote notifications

`Config/SchoolMessage.entitlements` には既に対応する項目が入っているので、
Xcode 側でコンテナ名を選び直すだけで揃います。

配布時は `aps-environment` を `development` から `production` に変えてください。

## 4. CloudKit のスキーマを作る

いちばん早い順序:

1. Development 環境でアプリを一度動かし、プロフィール登録とメッセージ送信を試す
   → レコードタイプとフィールドが自動生成される
2. [CloudKit Console](https://icloud.developer.apple.com/) →
   対象コンテナ → **Schema → Indexes** で、
   [`CLOUDKIT_SCHEMA.md`](CLOUDKIT_SCHEMA.md) の表にある
   QUERYABLE / SORTABLE を設定する

**最低限これだけは必須**（無いとチャットが表示されません）:

| レコードタイプ | フィールド | インデックス |
|---|---|---|
| Message | `conversation` | QUERYABLE |
| Message | `sentAt` | QUERYABLE, SORTABLE |
| Message | `participantIDs` | QUERYABLE |
| Conversation | `participantIDs` | QUERYABLE |
| ConversationKey | `conversation`, `recipientID` | QUERYABLE |
| ReadState | `userID` | QUERYABLE |
| UserProfile | `handle` | QUERYABLE |
| Friendship | `ownerID` | QUERYABLE |
| ConversationLeave | `userID` | QUERYABLE |

あると良いもの: `UserProfile.displayName` を QUERYABLE にすると名前での検索が効きます
（無くてもユーザID の完全一致検索は動きます）。

**セキュリティロールは既定のまま**にしてください。
理由は [`SECURITY.md`](SECURITY.md#書き込み権限) にあります。

## 5. 2 台にインストールする

- それぞれの iPad で**別々の iCloud アカウント**にサインインしておく
- 設定 → Apple ID → iCloud がオンであることを確認
- Xcode から Run

初回起動時に、表示名とユーザID を登録する画面が出ます。
ユーザID は後から変更できないので、`tanaka_2a` のような分かりやすいものにしてください。

## 6. 動作確認

[`TESTING.md`](TESTING.md) のシナリオ A〜E を順に実施してください。

## よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| 「iCloud にサインインしていません」から進まない | 設定アプリで iCloud にサインイン。サインイン済みなら iCloud Drive をオンに |
| チャット一覧が空のまま | インデックス未設定。Console でエラーログ（Logs → 該当コンテナ）を確認 |
| ユーザ検索で見つからない | 相手がまだプロフィール登録をしていない／`handle` の QUERYABLE 未設定 |
| 「このチャットの鍵を取得できませんでした」 | `ConversationKey` のインデックス未設定。または相手の公開鍵が未登録（相手が一度アプリを開けば解決） |
| 通知が来ない | 実機か確認。`aps-environment` と Push Notifications capability を確認 |
| Production で動かない | Development のスキーマを「Deploy Schema Changes」で本番へ反映していない |

## 開発中に便利なこと

- `AppEnvironment.preview()` に切り替えると、iCloud もネットワークも使わずに
  UI を動かせます（`InMemoryChatBackend`）。SwiftUI プレビューはこれを使っています。
- CloudKit Console の **Records** タブでレコードを直接見られます。
  `payload` が読めない（バイナリ）ことを確認すると、暗号化が効いているのが分かります。
