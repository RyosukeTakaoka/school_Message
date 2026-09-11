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

recordName: `userprofile-<作成者の userRecordID>`

> CloudKit の Public Database は, ユーザが初めてコンテナへアクセスした時点でシステム予約の
> `Users` レコードタイプを, そのユーザの `userRecordID` と同じ recordName で自動生成します。
> recordName はレコードタイプが違ってもデータベース内で一意でなければならないため,
> `UserProfile` の recordName をそのまま `userRecordID` にすると `Users` システムレコードと
> 衝突し, 「未知のデータ形式です(Users)」というエラーになります。`userprofile-` の接頭辞で
> 名前空間を分けて回避しています。なりすまし対策は「作成者の userRecordID から逆算した
> recordName と実際の recordName が一致するか」で行います。

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
| `conversationKey` | String | QUERYABLE, SEARCHABLE, SORTABLE | 会話ごとの購読（`conversationKey == "<文字列>"`）の絞り込みに使う |
| `senderID` | String | QUERYABLE | 送信者（`creatorUserRecordID` と突き合わせて検証） |
| `sentAt` | Date/Time | **QUERYABLE, SORTABLE** | 並び替えとページングに必須 |
| `payload` | Bytes | — | 暗号化した本文・メディアのメタデータ・返信先（引用） |
| `mediaAsset` | Asset | — | 暗号化した写真・動画の本体 |
| `thumbnailCipher` | Bytes | — | 暗号化したサムネイル（レコードに同梱） |
| `participantIDs` | String (List) | **QUERYABLE** | プッシュ購読の述語に必要 |
| `senderDisplayName` | String | — | プッシュ通知に出す送信者名（平文） |

recordName: クライアントが採番した UUID（再送しても同じ = 重複しない）

> **返信（引用）はフィールドを増やしていません。** 返信先のメッセージ ID・送信者・
> 本文の抜粋は `payload` の中（暗号化される JSON）に入れています。
> こうすることで、引用文が平文でサーバに残らず、レコードタイプの変更も要らないため
> Production へのスキーマ再デプロイなしで機能を追加できます。

## ReadState

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | |
| `userID` | String | QUERYABLE | |
| `lastReadAt` | Date/Time | QUERYABLE, SORTABLE | ここまで読んだ |

recordName: `readstate-<会話>-<ユーザ>`（本人しか書けない）

> 「自分の送信に付く既読」は、同じ会話の**他の参加者**の `ReadState` を読んで求めます。
> recordName が決まっているので、参加者一覧から recordName を組み立てて一括取得しており、
> `conversation` のインデックス設定に依存しません（インデックスが無くても既読は動きます）。
> 取得した既読は「申告された `userID` とサーバが押印した作成者が一致するもの」だけ採用します。

## ConversationLeave

退出の記録。会話レコードの参加者一覧は作成者しか書き換えられないため、
退出者本人が作れるこのレコードで代用します。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | |
| `userID` | String | QUERYABLE | |
| `leftAt` | Date/Time | — | |

recordName: `leave-<会話>-<ユーザ>`

## MessageReaction

メッセージへの絵文字リアクション。`Message` とは別のレコードタイプにしているのは、
Public Database では「更新できるのは作成者だけ」であり、他人が送ったメッセージの
レコードに自分の反応を書き足すことができないためです。代わりに、リアクションした
本人だけが作れる専用レコードにして、メッセージ ID で結びつけています。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `conversation` | Reference | QUERYABLE | 会話ぶんまとめて取得するための絞り込み |
| `message` | Reference | QUERYABLE | どのメッセージへのリアクションか |
| `userID` | String | QUERYABLE | リアクションした本人（`creatorUserRecordID` と突き合わせて検証） |
| `emojiCipher` | Bytes | — | 暗号化した絵文字 1 文字 |
| `createdAt` | Date/Time | — | |

recordName: `reaction-<メッセージ>-<ユーザ>`（1 人 1 メッセージにつき 1 件に決定的に収束する。
選び直し・取り消しは同じレコードの上書き・削除で済む）

> プッシュ購読は用意していません（絵文字 1 つのために CloudKit の購読をもう 1 種類
> 増やすほどではないと判断したため）。既存のメッセージ取得のポーリングに相乗りして
> 取得し直しているので、チャットを開いている間は数秒〜十数秒の遅延で反映されます。

## BoardThread / BoardPost

掲示板のスレッドと書き込み。チャットと違い**誰でも読める前提**なので、会話鍵での
暗号化は行わない（本文が平文で保存されることは画面と規約で明示している）。

### BoardThread

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `title` | String | — | 平文 |
| `authorID` | String | QUERYABLE | 立てた人（`creatorUserRecordID` と突き合わせて検証） |
| `createdAt` | Date/Time | QUERYABLE, SORTABLE | |
| `lastPostedAt` | Date/Time | QUERYABLE, SORTABLE | 一覧の並べ替えに使う |

recordName: クライアントが採番した UUID

### BoardPost

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `thread` | Reference | QUERYABLE | どのスレッドの書き込みか |
| `authorID` | String | QUERYABLE | 書き込んだ人（`creatorUserRecordID` と突き合わせて検証） |
| `body` | String | — | 平文。写真だけの書き込みでは空文字列 |
| `createdAt` | Date/Time | QUERYABLE, SORTABLE | |
| `imageAsset` | Asset | — | 添付した写真本体（暗号化しない） |
| `imageThumbnail` | Bytes | — | 一覧にすぐ出す小さなサムネイル（平文, レコードに同梱） |
| `imageWidth` | Int(64) | — | |
| `imageHeight` | Int(64) | — | |
| `imageByteCount` | Int(64) | — | |

recordName: クライアントが採番した UUID

> 写真の 4 フィールド（`imageAsset` 以下）は, 書き込みに写真を添付したときだけ
> 値が入る。文章だけの書き込みでは触れないので, 未設定のままで構わない。

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
