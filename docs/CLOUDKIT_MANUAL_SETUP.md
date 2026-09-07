# CloudKit を手動で設定する手順

アプリを動かしてスキーマを自動生成させる代わりに、CloudKit Console から手で
レコードタイプ・フィールド・インデックスを作る手順です。

**この手順が必要になる場面**

- TestFlight（Production 環境）で「サーバ側の設定がこの機能に追いついていません」
  「`Cannot create new type/field ... in production schema`」と出る
- 通知が届かない（後述のとおり、**インデックス不足が原因のことが多い**）

---

## 0. 前提：Development と Production の関係

CloudKit の環境は 2 つあります。

| 環境 | 使われる場面 | スキーマの自動生成 |
|---|---|---|
| **Development** | Xcode から実機・シミュレータで実行したとき | **される**（レコードを保存すると型が自動で作られる） |
| **Production** | **TestFlight・App Store 版** | **されない** |

**Production のスキーマは直接編集できません。** 必ず Development で作ってから
「Deploy Schema Changes」で反映します。この文書もその順序で書いています。

CloudKit Console: https://icloud.developer.apple.com/dashboard/

コンテナは **`iCloud.com.schoolmessage.app`** を選んでください
（左上のコンテナ名で切り替えます。別アプリのコンテナを開いていないか毎回確認してください）。

---

## 1. Development 環境に切り替える

1. CloudKit Console を開く
2. 左上でコンテナ `iCloud.com.schoolmessage.app` を選ぶ
3. 環境の選択で **Development** を選ぶ
4. 左メニューの **Schema → Record Types** を開く

---

## 2. レコードタイプとフィールドを作る

`Record Types` の右上「+」で作成し、各タイプに以下のフィールドを追加します。
**型を間違えると保存時に失敗する**ので、型は正確に合わせてください。

### UserProfile

| フィールド | 型 |
|---|---|
| `handle` | String |
| `displayName` | String |
| `avatar` | Asset |
| `avatarByteCount` | Int(64) |
| `publicKey` | Bytes |
| `updatedAt` | Date/Time |

### Friendship

| フィールド | 型 |
|---|---|
| `ownerID` | String |
| `friendID` | String |
| `createdAt` | Date/Time |

### Conversation

| フィールド | 型 |
|---|---|
| `kind` | String |
| `participantIDs` | String **List** |
| `ownerID` | String |
| `createdAt` | Date/Time |
| `titleCipher` | Bytes |
| `imageCipher` | Bytes |

> `titleCipher` / `imageCipher` は**グループでしか使いません**。
> Development でグループを一度も作っていないと自動生成されないため、
> 「グループ作成だけ Production で失敗する」の直接の原因になります。

### ConversationKey

| フィールド | 型 |
|---|---|
| `conversation` | Reference |
| `recipientID` | String |
| `ephemeralPublicKey` | Bytes |
| `wrappedKey` | Bytes |

### ConversationLeave

| フィールド | 型 |
|---|---|
| `conversation` | Reference |
| `userID` | String |
| `leftAt` | Date/Time |

> グループを退出したときだけ作られるレコードです。こちらも
> Development で一度も退出していないと存在しません。

### Message

| フィールド | 型 |
|---|---|
| `conversation` | Reference |
| `senderID` | String |
| `sentAt` | Date/Time |
| `payload` | Bytes |
| `mediaAsset` | Asset |
| `thumbnailCipher` | Bytes |
| `participantIDs` | String **List** |
| `senderDisplayName` | String |

### ReadState

| フィールド | 型 |
|---|---|
| `conversation` | Reference |
| `userID` | String |
| `lastReadAt` | Date/Time |

---

## 3. インデックスを作る（**通知が来ない原因はここが多い**）

**Schema → Indexes** で、レコードタイプごとに以下を追加します。

CloudKit は「インデックスの無いフィールドでは絞り込めない」ため、
インデックスが 1 つ足りないだけで、その機能だけが静かに動かなくなります。

| レコードタイプ | フィールド | 必要なインデックス | これが無いと |
|---|---|---|---|
| **Message** | `participantIDs` | **QUERYABLE** | **プッシュ購読を作れず、通知が一切来ない** |
| Message | `conversation` | QUERYABLE | メッセージを読めない |
| Message | `sentAt` | QUERYABLE, **SORTABLE** | 並び替え・ページングができない |
| Conversation | `participantIDs` | QUERYABLE | チャット一覧が空になる |
| ConversationKey | `conversation` | QUERYABLE | 「鍵を取得できませんでした」 |
| ConversationKey | `recipientID` | QUERYABLE | 同上 |
| ReadState | `userID` | QUERYABLE | 未読数が出ない |
| ConversationLeave | `userID` | QUERYABLE | 退出が反映されない |
| UserProfile | `handle` | QUERYABLE | ユーザ検索ができない |
| UserProfile | `displayName` | QUERYABLE | 名前での検索ができない（任意） |
| Friendship | `ownerID` | QUERYABLE | 友達一覧が空になる |

> **`Message.participantIDs` の QUERYABLE を最優先で確認してください。**
> アプリは「自分が参加者に含まれる新着メッセージ」という条件でプッシュ購読を
> 作ります。この条件は `participantIDs` を検索できることが前提なので、
> インデックスが無いと購読の作成そのものが失敗します。
> このとき**メッセージの送受信は正常に動いたまま、通知だけが来ない**状態になり、
> 原因に気付きにくくなります。

なお、レコードタイプによっては CloudKit が `recordName` などのシステム
インデックスを自動で付けます。上の表に無いものは触らなくて構いません。

---

## 4. Production へ反映する

1. 左メニュー下部の **Deploy Schema Changes...** を押す
2. 「Confirm Deployment」に、作成した型とインデックスの一覧が出る
3. 内容を確認して **Deploy** を押す

> Development のスキーマを変えるたびに、この手順が必要です。
> 変更を反映しない限り、TestFlight 版だけが古いスキーマのままになります。

---

## 5. 反映されたか確かめる

1. 環境を **Production** に切り替える
2. Schema → Record Types / Indexes に、追加したものが並んでいるか見る
3. TestFlight のアプリを開き直す
   - **プロフィール画面 →「通知の状態を調べる」** を実行する
   - 「3. サーバの購読」に ✅ が付けば、通知の経路は開通しています
   - グループ作成も試す

---

## 付録：それでも通知が来ないとき

プロフィール画面の「通知の状態を調べる」の結果ごとに、見るべき場所が変わります。

| 結果 | 原因と対処 |
|---|---|
| 「1. 通知の許可」が × | iPad の「設定」→「通知」→ SchoolMessage で許可する。一度拒否すると、アプリ側からは二度と聞けません |
| 「2. 端末の登録」が × | 通信できる状態でアプリを開き直す。実機かどうかも確認（シミュレータでは APNs に登録できません） |
| 「3. サーバの購読」が × | 本文書の手順 3（インデックス）と 4（デプロイ）を実施。そのうえで「購読をもう一度設定する」を押す |
| すべて ✅ なのに来ない | 送信側と受信側が**別々の Apple ID** か確認（同じ Apple ID の 2 台では、自分の送信に自分への通知は飛びません）。iPad の「おやすみモード」「集中モード」も確認 |
