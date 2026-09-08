# CloudKit を手動で設定する手順

> **いちばん速い方法: [`cloudkit-schema.ckdb`](cloudkit-schema.ckdb) を読み込む**
>
> このリポジトリの `docs/cloudkit-schema.ckdb` は、**アプリが必要とする
> スキーマの完成形**です。CloudKit Console の
> **Development** 環境で **Import Schema...** から読み込み、そのあと
> **Deploy Schema Changes...** で Production へ反映すれば、
> 下の手動手順をすべて省略できます。
>
> 2026-09-08 時点の実機の Development 環境と比べて、次の 2 つが不足していました。
> - `UserProfile.avatar`（ASSET）… **プロフィール画像を変更できない原因**
> - `ConversationLeave` レコードタイプ … グループ退出に必要


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
| **`avatar`** | **Asset** |
| `avatarByteCount` | Int(64) |
| `publicKey` | Bytes |
| `updatedAt` | Date/Time |

> **`avatar` は自動生成されにくいフィールドです。**
> プロフィール画像を設定した人が一度もいないと作られません。
> 無い状態でプロフィール画像を保存しようとすると、Production では
> 「サーバ側の設定がこの機能に追いついていません」と出て**画像だけ保存できません**。
> 表示名の変更は成功するので、原因に気付きにくい項目です。

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
>
> **確認のしかた**: Record Types の一覧に出る「N fields」には、CloudKit の
> システム項目 6 つが含まれます。`Conversation` が **10 fields** なら
> 自前のフィールドは 4 つ（`kind` / `participantIDs` / `ownerID` / `createdAt`）で、
> **`titleCipher` と `imageCipher` が無い**状態です。12 fields になれば揃っています。

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
| **Message** | `participantIDs` | **QUERYABLE** | プッシュ購読を作れず、通知が一切来ない |
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

> **`Message.participantIDs` の QUERYABLE について**
> アプリは「自分が参加者に含まれる新着メッセージ」という条件でプッシュ購読を
> 作ります。この条件は `participantIDs` を検索できることが前提なので、
> インデックスが無いと購読の作成そのものが失敗します。このとき
> **メッセージの送受信は正常に動いたまま、通知だけが来ない**状態になります。
>
> ただし 2026-09-08 時点の本プロジェクトでは、**この索引は Development にも
> Production にも既に存在することを確認済み**です。したがって通知が来ない
> 原因は別にあります（→ 付録「それでも通知が来ないとき」）。

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

### まず切り分ける（CloudKit Console だけでできる）

アプリを更新しなくても、**購読がサーバに作られているか**は Console で見られます。

1. CloudKit Console → 左メニュー **Data → Subscriptions**
2. 環境を確認する（**TestFlight 版の話をするなら Production**、
   Xcode から実行した版の話なら Development）
3. **`sub-new-messages-v1`** があるか見る

| 結果 | 意味 | 次にすること |
|---|---|---|
| ある | 購読は正常。CloudKit は通知を送ろうとしている | **配信側の問題**。下記「Xcode 側の確認」へ |
| ない | 購読の作成に失敗している | アプリの「購読をもう一度設定する」を押し、エラー内容を確認する |

> Console にはログイン中の Apple ID 自身の購読が出ます。アプリを使っている
> iPad と同じ Apple ID でログインしていれば、そこに現れます。

### アプリ側で切り分ける

プロフィール画面の **「通知の状態を調べる」** を実行してください。
結果ごとに、見るべき場所が変わります。

| 結果 | 原因と対処 |
|---|---|
| 「1. 通知の許可」が × | iPad の「設定」→「通知」→ SchoolMessage で許可する。一度拒否すると、アプリ側からは二度と聞けません |
| 「2. 端末の登録」が × | **下記「Xcode 側の確認」へ。** 通信できる状態で開き直しても直らない場合、capability の設定漏れが濃厚です。実機かどうかも確認（シミュレータでは APNs に登録できません） |
| 「3. サーバの購読」が × | 本文書の手順 3（インデックス）と 4（デプロイ）を実施。そのうえで「購読をもう一度設定する」を押す |
| **すべて ✅ なのに来ない** | **下記「Xcode 側の確認」へ。** 購読も端末登録もできているのに届かない場合、APNs の環境（sandbox / production）の食い違いが最有力です |

### iPadOS の版を確認する（Development では届くのに Production だけ届かない場合）

**iOS / iPadOS 26.4 に、CloudKit のプッシュが届かなくなる不具合があった。**
26.4.1（2026年4月8日公開）で修正済み。

症状がこれと一致する場合、アプリ側では直せない。

| 症状 | この不具合か |
|---|---|
| Xcode から実行した版（Development）では通知が届く | ○ |
| TestFlight 版（Production）では届かない | ○ |
| 購読は Console に存在し、診断も全部 ✅ | ○ |
| 端末が **26.4 ちょうど** | ○ |

**確認**: iPad の 設定 → 一般 → 情報 → ソフトウェアバージョン。
**対処**: 26.4.1 以降に更新する。**2 台とも**確認すること。

出典:
- [CKQuerySubscription on public database never triggers APNS push in Production environment](https://developer.apple.com/forums/thread/820562)
- [Apple Releases OS 26.4.1 to Fix CloudKit Syncing Bug](https://tidbits.com/2026/04/09/apple-releases-ios-26-4-1-and-ipados-26-4-1-to-fix-cloudkit-syncing-bug/)

---

### Xcode 側の確認（購読が ✅ でも通知が来ない場合）

`Config/SchoolMessage.entitlements` には `aps-environment = development` と
書いてあります。Xcode の**自動署名がこの値を配布ビルド用に書き換えてくれる**のは、
**Push Notifications capability が Xcode の画面上で有効になっている場合だけ**です。

この capability が付いていないと、TestFlight 版でも `development`（sandbox）の
まま署名され、**Production の CloudKit から送られるプッシュが一切届きません**。
このとき、メッセージの送受信・既読はすべて正常に動いたままなので、
「アプリは動くのに通知だけ来ない」という症状になります。

**確認手順**

1. Xcode でプロジェクトを開く
2. 左のファイル一覧で **SchoolMessage**（青いアイコン）を選ぶ
3. **TARGETS → SchoolMessage → Signing & Capabilities** タブを開く
4. 一覧に次の 2 つがあるか確認する
   - **Push Notifications**
   - **Background Modes**（中の「Remote notifications」にチェック）
   - **iCloud**（CloudKit にチェック、コンテナが `iCloud.com.schoolmessage.app`）
5. 足りないものがあれば、左上の **「+ Capability」** から追加する
6. 追加後、**Archive し直して TestFlight に上げ直す**

> 5 で Push Notifications を追加すると、Xcode が Apple Developer 側の
> App ID にも自動で capability を登録します。追加した直後は
> 「Provisioning profile が更新されました」という表示が出ることがありますが、
> そのまま進めて構いません。
