# 通知

## いまの仕組み

メッセージ本文は会話鍵で暗号化されており、**CloudKit は復号できません**。
そのためサーバが組み立てる通知に本文を載せることは原理的にできません。

2 段構えにしています。

```
新着メッセージ
   │
   ├─ ① CloudKit が生成する通知（必ず届く）
   │     「新しいメッセージ」
   │     「田中 さんからメッセージが届きました」
   │        ← senderDisplayName（平文フィールド）だけを使う
   │
   └─ ② 同時にサイレント通知でアプリを起こす
         アプリが端末内で復号できたら、
         本文入りのローカル通知に差し替える
            「田中」
            「今日どこ集合？」
```

- ①は `CKSubscription.NotificationInfo` の
  `alertLocalizationKey` + `alertLocalizationArgs` で実現しています。
  文言は `SchoolMessage/Resources/{ja,en}.lproj/Localizable.strings` の
  `PUSH_NEW_MESSAGE_TITLE` / `PUSH_NEW_MESSAGE_BODY`。
- ②は `shouldSendContentAvailable = true` + `UIBackgroundModes: remote-notification`。
  `AppDelegate.application(_:didReceiveRemoteNotification:)` が受け、
  `PushNotificationService` が復号してローカル通知を出します。

iOS がアプリを起こさなかった場合は①だけが表示されます。
「誰から来たか」は必ず分かり、本文は開けば読める、という状態になります。

## 掲示板の通知

掲示板の書き込みは元から暗号化していない（誰でも読める前提の場所な
ので暗号化しても意味がない）ため、メッセージのような「サイレント通知
で起こしてから端末内で復号」という手順は要らず、**CloudKit が生成する
アラートだけで完結します**。

- 購読 ID は `sub-new-board-posts-v1`（`CKSchema.SubscriptionID.newBoardPosts`）。
  述語を持たない（`NSPredicate(value: true)`）ため、参加者などで絞り込む
  必要がある会話の購読と違い、**誰の書き込みでも、通知をオンにしている
  全員に届きます**。
- 文言は `PUSH_NEW_BOARD_POST_TITLE` / `PUSH_NEW_BOARD_POST_BODY`
  （「掲示板」「新しい書き込みがあります」）。内容は平文でも、
  誰が書いたかまでは通知に出しません。
- 既定は**オフ**です。誰の書き込みでも届く場所なので、使いたい人だけが
  プロフィール画面から個別にオンにする想定です。
- オン/オフを切り替えるたびに、`PushNotificationService` が
  `configureBoardSubscription()` / `removeBoardSubscription()` を呼んで
  サーバ側の購読を作成・削除します（メッセージの購読とは独立していて、
  掲示板だけを個別に止められます）。

## 通知の種類ごとのオン・オフ（LINE 風の設定画面）

プロフィール画面の「通知」セクションから、種類ごとに個別で選べます。

| 種類 | 既定 | 補足 |
|---|---|---|
| メッセージ | オン | 「本文を表示」をオフにすると、ローカル通知の本文は「新しいメッセージ」に置き換わります |
| すれ違い通信 | オン | すれ違い通信そのものの入り切り（プロフィール → すれ違い通信）とは別の設定です。すれ違い通信自体がオフなら、そもそも出会いが起きないのでこの設定に関わらず通知は出ません |
| 掲示板 | オフ | 上記の通り、既定でオフです |

## プライバシー配慮

- 本文表示をオフにすると、ローカル通知の本文は「新しいメッセージ」に置き換わります。
  iPad を机に置いたままにする学校での利用を想定した設定です。
- いま開いているチャットの通知は表示しません（画面に既に見えているため）。
- 通知の許可は**起動直後には求めません**。最初にチャットを開いた時点で求めます。
  何のための通知かが伝わっている状態のほうが許可されやすく、
  「起動してすぐ会話できる」体験も損ないません。

## 本文を確実に出したい場合（次の一手）

**Notification Service Extension** を追加するのが正攻法です。
アプリが起こされたかどうかに関係なく、通知の表示直前に本文を差し替えられます。

手順の概要:

1. Xcode で **File → New → Target → Notification Service Extension** を追加
2. サブスクリプションの `NotificationInfo` に
   `shouldSendMutableContent = true` を追加する
   （`CloudKitBackend.messageNotificationInfo()`）
3. `desiredKeys` に `payload` と `senderDisplayName` を加える
4. Extension 側で以下を行う
   - `request.content.userInfo` から CloudKit の `CKQueryNotification` を復元
   - Keychain から長期鍵を読む（**App Group + Keychain Sharing の設定が必要**）
   - 会話鍵を復号し、`payload` を開いて `bestAttemptContent.body` に入れる
5. 失敗した場合は元の内容のまま返す（本文が出ないだけで通知は届く）

この構成にすると、Extension が Keychain と CloudKit にアクセスできる必要があるため、
- App Group（`group.com.schoolmessage.app`）
- Keychain Sharing（共有アクセスグループ）
- Extension 側にも iCloud コンテナの entitlement

を追加することになります。MVP の範囲を超えるため今回は入れていません。

## トラブルシューティング

| 症状 | 確認すること |
|---|---|
| 通知がまったく来ない | 実機か（シミュレータでは APNs が動かない）／`aps-environment` が正しいか／設定アプリで通知が許可されているか |
| 購読の作成でエラーが出る | `Message.participantIDs` と `Conversation.participantIDs` が QUERYABLE か。失敗してもアプリは 25 秒間隔のポーリングで動きます |
| 送信者名が「友達」になる | 自分のプロフィールを取得する前に送信した場合。アプリを開き直すと直ります |
| 本文が出ない | サイレント通知でアプリが起きなかった場合。iOS の判断なので確実にするには Service Extension が必要 |
