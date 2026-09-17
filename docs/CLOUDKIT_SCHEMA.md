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
>
> **グループの @ メンションも同じ理由でフィールドを増やしていません。**
> 本文中で誰を @ で指定したかは、相手の userRecordName の配列として
> 同じ `payload` の中に入れています。CloudKit のスキーマ変更は不要です。

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

## PlayerWallet

アプリ内ゲームのポイント「CHIP」の残高。プロフィールとは別レコードにしている
(プロフィールは全員に配って回る情報なので、ゲームのたびに書き換えたくないため)。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `ownerID` | String | QUERYABLE, SEARCHABLE, SORTABLE | 持ち主（`creatorUserRecordID` と突き合わせて検証） |
| `balance` | Int(64) | **QUERYABLE, SORTABLE** | 残高。ランキングの並べ替えに使うので索引が必須 |
| `bankruptAt` | Date/Time | — | CHIP が 0 になった日時（最初に挑戦できる日の計算に使う） |
| `lastRevivalAttemptAt` | Date/Time | — | 最後に復活ルーレットに挑戦した日時（はずれたあとの再挑戦日の計算に使う） |
| `settledGameIDs` | String（リスト） | — | 精算済みの対戦 ID。二重に増減させないための記録 |
| `updatedAt` | Date/Time | — | |

recordName: `wallet-<userRecordName>`（`UserProfile` と同じく接頭辞を付けて、
CloudKit 予約の `Users` レコードとの衝突を避ける）

> 残高は**差分で**更新する。同時に別のゲームが精算しても片方の更新が消えないよう、
> 保存が競合したら最新を取り直して同じ差分を当て直す
> (`CloudKitBackend+Wallet.swift`)。
>
> 書き込めるのは作成者本人だけなので、他人の残高は書き換えられない。

> 復活ルーレットに挑戦できるまでの待ち時間は2段階（`PlayerWallet.swift`）。
> 0になった日から`bankruptRestDays`（2日）で最初の挑戦ができるようになり、
> そこではずれても`bankruptAt`は動かさず、`lastRevivalAttemptAt`だけ進める。
> 以降は`revivalRetryRestDays`（1日）ごとに再挑戦できる。「はずれるたびに
> また2日待つ」にすると運が悪いだけで長期間CHIPを使えなくなるため、
> 最初の待機とその後の再挑戦を分けてある。
> 逆に言えば、各自の端末が自分のぶんだけを反映する仕組みになっている。
>
> `bankruptAt` は復活ルーレットの種でもある。出る額は
> 「持ち主 + 0 になった日時」から決まるので、アプリを開き直しても結果は変わらない。

---

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
| `imageKind` | String | — | 現在は使っていない（GIF機能を廃止したため, 常に `"image"` 扱い）。フィールド自体は残しているが, アプリからは書き込まない |

recordName: クライアントが採番した UUID

> 写真の 5 フィールド（`imageAsset` 以下）は, 書き込みに添付したときだけ
> 値が入る。文章だけの書き込みでは触れないので, 未設定のままで構わない。

## HorseRaceBet / HorseRaceResult

競馬（平日 15:05 発走）の馬券と、レース結果の確定レコード。

出走表（9 頭の馬名・脚質・調子・オッズ）はレコードに持たない。開催日から
決まる種でどの端末でも同じ表を組み立てられるため、保存する必要がない。

### HorseRaceBet

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `raceID` | String | QUERYABLE | 開催日（`2026-09-16`） |
| `bettorID` | String | QUERYABLE | 買った人（`creatorUserRecordID` と突き合わせて検証） |
| `kind` | String | QUERYABLE | 券種（`win` / `place` / `quinella` / `exacta` / `wide` / `trio` / `trifecta`） |
| `selections` | Int(64) (List) | — | 選んだ馬番。券種によって 1〜3 個 |
| `amount` | Int(64) | — | 賭けた CHIP |
| `createdAt` | Date/Time | QUERYABLE, SORTABLE | 締切（14:55）より前のものだけ有効 |

recordName: クライアントが採番した UUID

### HorseRaceResult

レースの種を確定させる 1 件。**recordName を `race-<開催日>` に固定**しているため、
複数の端末が同時に作ろうとしてもサーバ側で 1 件しか作れない（2 件目は
「既にある」で弾かれ、既存のものを読みに行く）。これで全員が必ず同じ種を見る。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `raceID` | String | QUERYABLE | 開催日 |
| `seed` | String | — | レースを再現する種 |
| `betIDs` | String (List) | — | 種の計算に入れた馬券。各端末が検算できるようにするため |
| `lockedAt` | Date/Time | QUERYABLE, SORTABLE | 確定した時刻 |

recordName: `race-<開催日>`（例: `race-2026-09-16`）

> 種は「締切時点で出そろった馬券の内容と、CloudKit がサーバ側で打刻した作成時刻」
> から計算する。作成時刻はクライアントが選べないので、誰も狙った結果を作れない。

## AppRelease

**古いビルドを使い続けている人に更新してもらうための、1 件だけのレコード。**
アプリは読むだけで、書き込みは CloudKit Console から手で行う。

| フィールド | 型 | インデックス | 用途 |
|---|---|---|---|
| `minimumBuild` | Int(64) | — | これ未満のビルドはアプリを使えない（例: `202609152323`） |
| `message` | String | — | 更新をお願いする理由。画面にそのまま出る。空でもよい |

recordName: **`minimum-build` に固定**（1 件しか作らない）。ID 直指定で読むので
インデックスは不要。

> **`GRANT CREATE TO "_icloud"` を付けていない。** 他のレコードタイプと違い,
> ここだけ意図的に外してある。付けてしまうと, 管理者がまだ作っていない
> `minimum-build` を先にアプリの利用者が(SDK 経由で)作れてしまい,
> 「作った本人にしか書き込めない」という CloudKit の既定ルールにより,
> 以後だれもその中身を書き換えられなくなる恐れがある。CloudKit Console からの
> 作成・編集はこの権限設定の対象外(コンテナ管理者としての操作)なので,
> 外しても手順 1 の「Console で作る」操作には影響しない。

### 使い方

1. CloudKit Console → Records → `AppRelease` を開く。**まだ 1 件も無い**ので,
   新規作成で recordName に `minimum-build` を指定して作る
2. `minimumBuild` に, **更新を強いたいビルド番号**を入れる(`message` は任意)
3. 保存。以降, それ未満のビルドの人は起動時に更新をお願いする画面で止まる

以降, 下限を上げたいときは, この 1 件のレコードの `minimumBuild` を
書き換えて保存するだけでよい(作り直す必要はない)。

**「最新のビルド番号」を入れないこと。** ここに入れた値が下限になるので、
最新を入れると毎回全員に更新を強いることになる。入れるのは「これを入れて
いないと困る」ビルドの番号だけ。それ以外の更新は任意のままになる。

レコードを作っていない場合や、通信に失敗した場合は誰も止めない
（`AppUpdateGate` 参照）。

> **この仕組みは、これを含むビルド以降にしか効きません。** 古いビルドには
> 確認するコード自体が入っていないため、さかのぼって止めることはできません。
> 最初の 1 回だけは、掲示板などで更新をお願いする必要があります。

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
