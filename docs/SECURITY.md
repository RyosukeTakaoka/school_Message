# セキュリティとプライバシー

## 出発点となった問題

要件には次の 4 つがありました。

1. 他人のチャットを閲覧できない
2. 他人になりすませない
3. グループ外のユーザがグループメッセージを取得できない
4. 不正なレコード取得を防止

CloudKit の各データベースを検討した結果は次のとおりです。

| 案 | 判定 |
|---|---|
| Private Database | 他ユーザと共有できない。却下 |
| Shared Database (CKShare) | サーバ側 ACL は最も強固。ただし参加には共有 URL の受け渡しと承認が必要で、「ユーザIDを検索して即チャット」と噛み合わない。グループにメンバーを足すたびに承認待ちが発生する |
| Public Database のみ | **行単位のアクセス制御が存在しない**。読み取り権限はレコードタイプ単位でしか設定できず、チャットを成立させるために読み取りを許可すると、同じコンテナを使う全員が全メッセージを取得できる。改造クライアントを想定するとアプリ側の絞り込みは防御にならない。要件 1・3 を満たさない |
| **Public Database + クライアント側暗号化** ← 採用 | レコードは取れても読めない状態を作る |

## 採用した仕組み

### 鍵

- 各ユーザは初回登録時に **Curve25519 (X25519) の鍵ペア** を生成する。
- **公開鍵**だけを `UserProfile` に載せる（誰でも読める）。
- **秘密鍵**は Keychain に `kSecAttrSynchronizable = true` /
  `kSecAttrAccessibleAfterFirstUnlock` で保存する。
  iCloud Keychain 経由で同じ Apple ID の端末に同期されるので、
  機種変更や 2 台目の iPad でも過去の会話を読める。

### 会話鍵の配布

会話ごとにランダムな 256 bit 対称鍵を作り、参加者ごとに封緘して配ります。

```
送信者                                    受信者
  |                                         |
  | 使い捨て鍵ペア eph を生成                 |
  | shared = X25519(eph.priv, 受信者.pub)    |
  | wrapKey = HKDF-SHA256(shared, salt,      |
  |             info = eph.pub ‖ 受信者.pub) |
  | ciphertext = AES-GCM(会話鍵, wrapKey)    |
  |                                         |
  |--- ConversationKey レコード ------------>|
  |    { eph.pub, ciphertext }              |
  |                                         | shared = X25519(自分.priv, eph.pub)
  |                                         | 同じ HKDF で wrapKey を導出
  |                                         | 会話鍵を取り出す
```

使い捨て鍵を使うのは、送信者の長期秘密鍵が後に漏れても
この 1 回分の会話鍵が復元されないようにするためです。

### メッセージの暗号化

- 本文とメディアのメタデータ（サイズ・再生時間）は `MessagePayload` に
  まとめて **AES-GCM** で封緘し、`Message.payload` に置く。
- 写真・動画の本体も同じ会話鍵で暗号化してから `CKAsset` にする。
- サムネイルも暗号化して同じレコードに同梱する。

平文で残るのは以下だけです（＝メタデータとして漏れる情報）。

- 会話の参加者一覧（`Conversation.participantIDs`, `Message.participantIDs`）
- 送信時刻（`sentAt`）
- 送信者名（`senderDisplayName` — プッシュ通知に出すため）
- プロフィール（ハンドル・表示名・アイコン）

「誰がいつ誰とやりとりしたか」は隠れません。**本文と写真・動画は隠れます。**

### なりすまし対策

`senderID` はクライアントが書き込む値なので信用できません。
CloudKit が**サーバ側で押印する** `creatorUserRecordID` は改変できないので、
読み出し時に必ず突き合わせ、一致しないレコードは破棄します
（`CloudKitMapper`）。同じ検証を以下にも適用しています。

| レコード | 検証内容 |
|---|---|
| `UserProfile` | recordName == creatorUserRecordID（他人の ID でプロフィールを作れない） |
| `Message` | `senderID` == creatorUserRecordID |
| `Conversation` | `ownerID` == creatorUserRecordID |
| `ConversationKey` | creatorUserRecordID == その会話の `ownerID` |
| `Friendship` | `ownerID` == creatorUserRecordID |
| `ReadState` / `ConversationLeave` | `userID` == creatorUserRecordID |

### 書き込み権限

Public Database の既定（更新できるのは作成者のみ）に依存しています。
**CloudKit Dashboard でこの権限を緩めないでください。**
緩めると参加者一覧や既読位置を第三者に書き換えられます。

## 端末内の保護

- 秘密鍵・会話鍵は Keychain。ファイルにも UserDefaults にも書かない。
- 送信待ちの写真・動画は Application Support 配下に置き、
  `isExcludedFromBackup = true` でバックアップ対象から外す。
- ディレクトリには `completeUntilFirstUserAuthentication` のファイル保護を設定。
  端末ロック中でもバックグラウンドのアップロードを続けられる範囲で保護する。
- ダウンロード済みメディアは Caches 配下。消えても再取得できる。
- ログにメッセージ本文・ユーザ名を出さない（OSLog の既定は private。
  `privacy: .public` を付けているのは ID や件数などの非個人情報だけ）。
- 動画の書き出し時にメタデータ（撮影場所を含む）を削除する。

## 既知の限界

正直に書いておきます。

1. **メタデータは隠れない。** 誰と誰がいつやりとりしたかは Public Database から読めます。
   完全に隠すには自前のサーバか、CKShare ベースの設計が必要です。

2. **退出後の鍵ローテーションを行っていない。** グループを退出した人が
   会話鍵を保持し続けていれば、その後のメッセージも技術的には復号できます。
   きちんと対応するには、退出のたびに新しい会話鍵を作って残りのメンバーへ
   配り直す必要があります（MVP には含めていません）。

3. **鍵の検証（Safety Number）がない。** サーバが公開鍵を差し替える
   中間者攻撃は検出できません。少人数の学校コミュニティという前提での
   割り切りですが、公開鍵のフィンガープリントを画面に出して
   口頭確認できるようにするのが次の一手です。

4. **サムネイルの大きさは内容をわずかに漏らす。** 暗号文の長さから
   おおよその情報量が分かります。実害は小さいと判断しています。

5. **輸出コンプライアンス。** エンドツーエンド暗号化を行うため、
   `ITSAppUsesNonExemptEncryption = false` を単純に宣言できません。
   App Store Connect で自己分類レポートの要否を確認してください。
   `Config/Info.plist` では意図的に未設定にしてあります。

## 学校で使う前に

- 生徒同士のトラブル時に、教員が内容を確認する手段はありません
  （設計上、端末の持ち主以外は復号できない）。運用ルールを先に決めてください。
- 通知の本文表示は既定でオンです。iPad を机に置いたままにする運用なら、
  プロフィール画面から「通知に本文を表示」をオフにするよう案内してください。
