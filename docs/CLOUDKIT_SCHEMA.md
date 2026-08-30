# CloudKit スキーマ

すべて **Public Database / Default Zone** に置きます。
フィールド名は `SchoolMessage/Services/Backend/CloudKit/CloudKitSchema.swift` と対応します。

インデックス列の意味:

- **QUERYABLE** — 述語で絞り込める（`==`, `>`, `CONTAINS` など）
- **SORTABLE** — `sortDescriptors` に使える
- **SEARCHABLE** — 部分一致検索に使える

---

## UserProfile

公開ディレクトリ。誰でも検索できる前提の情報だけを置きます。
**recordName は必ずそのユーザの userRecordName と一致させます。**

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `handle` | String | QUERYABLE, SORTABLE | 検索用の一意な ID（`tanaka_2a`） |
| `displayName` | String | QUERYABLE, SORTABLE | 表示名 |
| `avatar` | Asset | — | プロフィール画像（暗号化しない） |
| `avatarByteCount` | Int(64) | — | サイズ |
| `publicKey` | Bytes | — | Curve25519 公開鍵（32 バイト） |
| `updatedAt` | Date/Time | QUERYABLE, SORTABLE | 更新時刻 |

> `displayName` の前方一致検索を使うには QUERYABLE が必要です。
> 設定していなくてもアプリは動きます（ユーザID の完全一致検索にフォールバックする）。

## Friendship

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `ownerID` | String | QUERYABLE | 追加した側の userRecordName |
| `friendID` | String | QUERYABLE | 追加された側 |
| `createdAt` | Date/Time | — | |

recordName: `friendship-<owner>-<friend>`（決定的なので重複しない）

## Conversation

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `kind` | String | QUERYABLE | `direct` / `group` |
| `participantIDs` | String (List) | QUERYABLE | 参加者の userRecordName |
| `ownerID` | String | QUERYABLE | 作成者 |
| `createdAt` | Date/Time | QUERYABLE, SORTABLE | |
| `titleCipher` | Bytes | — | 会話鍵で暗号化したグループ名 |
| `imageCipher` | Bytes | — | 会話鍵で暗号化したグループ画像 |

recordName: 1 対 1 は `direct-<小さい方のID>-<大きい方のID>`（両者が同時に開いても収束する）、
グループは UUID。

## ConversationKey

参加者 1 人につき 1 レコード。その人の公開鍵で封緘した会話鍵。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | 対象の会話 |
| `recipientID` | String | QUERYABLE | 鍵を受け取る人 |
| `ephemeralPublicKey` | Bytes | — | 使い捨て X25519 公開鍵 |
| `wrappedKey` | Bytes | — | 封緘した会話鍵（AES-GCM） |

recordName: `convkey-<会話>-<受信者>-<作成者>`

> 作成者を名前に含めるのは、1 対 1 会話を両者が同時に開いたときに、
> 負けた側の鍵が正しい鍵を上書きするのを防ぐためです。
> 読み出し時は「会話の作成者が書いた鍵」だけを採用します。

## Message

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | 対象の会話 |
| `senderID` | String | QUERYABLE | 送信者（`creatorUserRecordID` と突き合わせて検証） |
| `sentAt` | Date/Time | **QUERYABLE, SORTABLE** | 並び替えとページングに必須 |
| `payload` | Bytes | — | 暗号化した本文とメディアのメタデータ |
| `mediaAsset` | Asset | — | 暗号化した写真・動画の本体 |
| `thumbnailCipher` | Bytes | — | 暗号化したサムネイル（レコードに同梱） |
| `participantIDs` | String (List) | **QUERYABLE** | プッシュ購読の述語に必要 |
| `senderDisplayName` | String | — | プッシュ通知に出す送信者名（平文） |

recordName: クライアントが採番した UUID（再送しても同じ = 重複しない）

## ReadState

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | |
| `userID` | String | QUERYABLE | |
| `lastReadAt` | Date/Time | QUERYABLE, SORTABLE | ここまで読んだ |

recordName: `readstate-<会話>-<ユーザ>`（本人しか書けない）

## ConversationLeave

退出の記録。会話レコードの参加者一覧は作成者しか書き換えられないため、
退出者本人が作れるこのレコードで代用します。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | |
| `userID` | String | QUERYABLE | |
| `leftAt` | Date/Time | — | |

recordName: `leave-<会話>-<ユーザ>`

---

## セキュリティロール

Public Database の既定（`_icloud` ロールが Read + Create、更新は作成者のみ）
のままにしてください。**書き込み権限を緩めないこと。**

このアプリは「レコードを更新できるのは作成者だけ」という CloudKit の保証に
以下を依存させています。

- 参加者一覧を第三者が書き換えられない
- 既読位置を他人に書き換えられない
- 他人になりすましたメッセージを作れない（`creatorUserRecordID` で検証）

## インデックスの作り方

CloudKit Dashboard → 対象コンテナ → **Schema → Indexes** で、
上の表の QUERYABLE / SORTABLE を設定します。

開発中は、アプリを一度動かすと Development 環境にレコードタイプが
自動生成されます（フィールドの型も推論される）。そのあと
インデックスだけを手で追加するのが早いです。

**Production へ反映する前に**、Development のスキーマを
「Deploy Schema Changes」で本番へコピーしてください。
