# 今日 Mac でやること（最初から全部）

前回のプッシュ以降に増えたもの:
**掲示板 / オセロ / 色勝負 / すれ違い通信**、
それと **通知が来ない問題の修正**。

やる順番に並べてあります。上から順にやれば漏れません。

| # | やること | 場所 | 目安 | 必須 |
|---|---|---|---|---|
| 1 | `git pull` | ターミナル | 1 分 | ✅ |
| 2 | CloudKit スキーマを取り込んで Deploy | ブラウザ | 10 分 | ✅ |
| 3 | Push Notifications capability の確認 | Xcode | 3 分 | ✅（通知の本命）|
| 4 | ビルドして 2 台に入れる | Xcode | 10 分 | ✅ |
| 5 | アプリ内の診断を実行 | iPad | 3 分 | ✅ |
| 6 | Console.app でログを見られるようにする | Mac | 5 分 | 推奨 |
| 7 | すれ違い通信を確認 | iPad × 2 | 20 分 | 推奨 |
| 8 | TestFlight に上げる | Xcode | 15 分 | 任意 |

**Xcode でのターゲット追加も、Apple Developer サイトでの作業も、一切ありません。**
すべて「pull してビルドする」の範囲で終わります。

---

## 1. `git pull`

```sh
cd ~/path/to/school_Message      # 自分の場所に読み替え
git checkout claude/ipad-school-chat-app-q1ce5n
git pull origin claude/ipad-school-chat-app-q1ce5n
```

> **`xcodegen` は使わないでください。** Bundle ID などが書き換わります。
> `project.yml` はリポジトリから消してあります。

`SchoolMessage.xcodeproj` を Xcode で開きます。
新しいファイルは自動で取り込まれます（Xcode 16 の同期フォルダ方式のため、
ドラッグ＆ドロップなどは不要）。

---

## 2. CloudKit スキーマを取り込んで Deploy

**掲示板を使うために必要。** これをやらないと掲示板だけ動きません
（チャット・通知・ゲーム・すれ違い通信には影響しません）。

> **今日すでに一度この手順をやった場合も、もう一度やり直してください。**
> `docs/cloudkit-schema.ckdb` に `Message.conversationKey` フィールドが
> 追加されました（通知が来ない問題の実際の原因への対処。詳細は
> `docs/CLOUDKIT_MANUAL_SETUP.md`「購読の作成自体が Production で
> 一律に失敗する場合」）。Import → Deploy をやり直さないと、この
> フィールドが Production に反映されません。

### 2-1. Development に取り込む

1. https://icloud.developer.apple.com/dashboard/ を開く
2. コンテナ **`iCloud.com.schoolmessage.app`** を選ぶ
3. 右上の環境が **Development** になっていることを確認
4. 左メニュー **Schema → Record Types**
5. 右上の **… → Import Schema**（または `Import Schema` ボタン）
6. リポジトリの **`docs/cloudkit-schema.ckdb`** を選ぶ
7. 差分の確認画面が出るので、**Import** を押す

これで足りていなかったもの（`BoardThread`, `BoardPost`,
`UserProfile.avatar`, `ConversationLeave` など）が一度に入ります。

> Import が使えない場合は、`docs/CLOUDKIT_MANUAL_SETUP.md` に
> 手作業で 1 つずつ作る手順があります。

### 2-2. Production へ反映する

**ここを忘れると TestFlight 版だけ古いままになります。**

1. 左メニュー下部の **Deploy Schema Changes…**
2. 追加される型とインデックスの一覧を確認
3. **Deploy**

### 2-3. 反映されたか確かめる

1. 右上の環境を **Production** に切り替える
2. **Schema → Record Types** に `BoardThread` / `BoardPost` があるか
3. **Schema → Indexes** で `Message` に `participantIDs`・`conversation`・
   **`conversationKey`**（すべて QUERYABLE）があるか

---

## 3. Push Notifications capability の確認 ← 通知が来ない問題の本命

**これが今日いちばん大事な確認です。**

`Config/SchoolMessage.entitlements` には `aps-environment = development` と
書いてあります。Xcode の自動署名がこれを配布用（`production`）に
書き換えてくれるのは、**Push Notifications capability が
Xcode の画面上で有効になっている場合だけ**です。

付いていないと、TestFlight 版でも sandbox のまま署名され、
**Production の CloudKit から送られるプッシュが一切届きません。**
このときメッセージの送受信・既読は全部正常に動くので、
「アプリは動くのに通知だけ来ない」という、いまの症状そのものになります。

### 手順

1. Xcode で左のプロジェクト名 **SchoolMessage** をクリック
2. TARGETS の **SchoolMessage** を選ぶ
3. **Signing & Capabilities** タブ
4. 一覧に次の 3 つがあるか見る

   | Capability | 中身 |
   |---|---|
   | **Push Notifications** | （設定項目なし。あるかないかだけ） |
   | **iCloud** | CloudKit にチェック / コンテナ `iCloud.com.schoolmessage.app` |
   | **Background Modes** | Remote notifications にチェック |

5. **Push Notifications が無ければ**、左上の **+ Capability** →
   `Push Notifications` を検索してダブルクリック
6. **Signing** の欄で
   - **Automatically manage signing** にチェック
   - Team が自分の Team
   - Status に赤いエラーが出ていないこと

> **Background Modes の中身は触らなくて大丈夫です。**
> Remote notifications / Uses Bluetooth LE accessories /
> Acts as a Bluetooth LE accessory は、リポジトリの
> `Config/Info.plist` に書いてあるので自動で入ります。
> （Background Modes は entitlement を持たないため、Info.plist だけで有効になります）

---

## 4. ビルドして 2 台に入れる

1. iPad を Mac に繋ぐ（または同じネットワークでワイヤレス）
2. Xcode 上部でスキーム **SchoolMessage**、実行先に iPad を選ぶ
3. **⌘R**
4. もう 1 台にも同じように入れる（**別々の iCloud アカウント**であること）

初回は iPad 側で「デベロッパを信頼」が必要:
**設定 → 一般 → VPN とデバイス管理 → 自分の Apple ID → 信頼**

### 許可のダイアログ

順に出るので、**すべて許可**してください。

| いつ | 何を聞かれる |
|---|---|
| 最初にチャットを開いたとき | 通知の許可 |
| すれ違い通信を入れたとき | Bluetooth の使用 |
| 写真を送るとき | 写真ライブラリ |

> 通知は**一度「許可しない」を押すと、アプリからは二度と聞けません**。
> 間違えたら iPad の 設定 → 通知 → School Message から許可してください。

---

## 5. アプリ内の診断を実行

1. アプリを開く → 左上のアイコン → **プロフィール**
2. **「通知の状態を調べる」** を押す

| 結果 | 意味 | 対処 |
|---|---|---|
| 1. 通知の許可 ✅ / 2. 端末の登録 ✅ / 3. サーバの購読 ✅ | 経路は開通 | 実際に送って確かめる |
| 1 が × | 通知が拒否されている | 設定 → 通知 → School Message |
| 2 が × | APNs に登録できていない | **手順 3 の Push Notifications capability** を疑う。実機かどうかも確認（シミュレータでは登録できません）|
| 3 が × | 購読が作れていない | 手順 2 の Deploy を確認 →「購読をもう一度設定する」を押す。エラー文が出たらそれを見る |

### CloudKit 側からも確かめる

1. CloudKit Console → **Data → Subscriptions**
2. 環境を合わせる（**Xcode から実行した版なら Development**、
   **TestFlight 版なら Production**）
3. `sub-new-messages-v1` があるか

> 前回ここが**空**でした。それが通知が来なかった直接の原因です。
> 購読の作成失敗を握りつぶしていたコードを直し、
> 作れなかった場合の代替のやり方も入れたので、今回は作られるはずです。
> それでも空なら、アプリの「購読をもう一度設定する」を押して、
> 出てくるエラー文を教えてください。

### 「全部 ✅」でも安心しないこと

診断が緑なのは、**そのビルドが使っている環境**についてだけ。

| ビルド | CloudKit 環境 | 購読の置き場所 |
|---|---|---|
| Xcode から実行 | **Development** | Development |
| TestFlight | **Production** | Production |

購読は**環境ごと・利用者ごと**に作られる。Xcode 版で作られた
`sub-new-messages-v1` は Development にしか無く、TestFlight 版は
Production 側にもう一度作り直す（アプリが起動時に自動でやる）。

**つまり Xcode 版が全部 ✅ でも、TestFlight 版で同じとは限らない。**
TestFlight に上げたら、その版でもう一度診断すること。

また、Development と Production はデータも別なので、
**Xcode 版で作ったプロフィール・友達・メッセージは TestFlight 版には出てこない**
（逆も同じ）。消えたわけではないので慌てないこと。

### 通知が実際に届くか

1. iPad A でチャットを開き、**iPad B はホーム画面に戻す**
2. A から B へメッセージを送る
3. B にバナーが出れば成功

---

## 6. Console.app でログを見られるようにする

すれ違い通信の確認で使います。

1. Mac の **アプリケーション → ユーティリティ → コンソール** を開く
2. 左の一覧から **iPad の名前** を選ぶ
3. 上の **「開始」** を押す（これを押さないと流れません）
4. 右上の検索欄に入れる

```
subsystem:app.takaoka.com.schoolmessage
```

さらに絞るなら:

| 検索文字列 | 見えるもの |
|---|---|
| `category:streetpass` | すれ違い通信 |
| `category:push` | 通知・購読 |
| `category:sync` | メッセージの取得 |
| `category:backend` | CloudKit とのやり取り |

**見ておくと嬉しいログ**

| ログ | 意味 |
|---|---|
| `launched by bluetooth` | Bluetooth に起こされた起動 |
| `woken up by bluetooth` | 復元の入り口を通った |
| `restored N peripheral(s)` | 復元された |
| `read a card over bluetooth` | 相手の名刺を読んだ |
| `received a dropped card over bluetooth` | 相手に名刺を置かれた |

> ログが 1 行も出ない場合、手順 3 の「開始」を押していないことが多いです。

---

## 7. すれ違い通信を確認（iPad 2 台）

### 7-1. まず前面同士（ここが通らなければ先に進まない）

1. 2 台とも Bluetooth を入れる（コントロールセンターの青いアイコン）
2. 2 台とも チャット一覧右上の **すれ違い通信**（歩く人のアイコン）を開く
3. **「すれ違い通信を使う」** を入れる → Bluetooth の許可を **許可**
4. **「いまの状態」が「探しています」** になることを確認
5. 一言を入れる（任意）
6. 2 台を 1m 以内に置いて 10 秒ほど待つ
7. 双方に「○○とすれ違いました」の通知が出て、一覧に相手が並ぶ

**ここで出ない場合の確認順**

1. 2 台とも Bluetooth が入っているか
2. 2 台とも「いまの状態」が「探しています」か
   - 「Bluetooth の使用が許可されていません」→ 設定 → School Message → Bluetooth
3. 2 台とも**表示名を設定済み**か（名前の無い名刺は相手側で捨てられます）
4. Console.app の `category:streetpass` に何か出ているか

### 7-2. 背面（ここが本番）

1. 双方でトグルを切って入れ直す（記録も消しておくと分かりやすい）
2. 2 台とも**ホーム画面に戻す**（**上スワイプで終了はしない**）
3. 10m 離してから近づける
4. 数十秒〜数分で通知が出れば成功

### 7-3. 復元（システムに落とされた後）

1. 2 台ともホーム画面に戻したまま、数時間放置
   （他のアプリを使ってメモリを使わせると起きやすい）
2. 近づける → 通知が出る
3. すれ違い通信の画面で **「システムに起こされた回数」が 1 以上**になっていれば、
   閉じている間も動いている証拠

### 7-4. 成功率を測る（余裕があれば）

20 回ずつすれ違って、記録された回数を数えます。

| 状態 | 20 回中 |
|---|---|
| 両方アプリ表示中 | / 20 |
| 片方表示中・片方ホーム画面 | / 20 |
| **両方ホーム画面** | **/ 20** ← 本当の指標 |
| 片方を上スワイプ終了 | / 20 ← 0 に近いはず（仕様）|

数字が取れたら教えてください。低ければ調整します。

---

## 8. TestFlight に上げる

1. Xcode 上部の実行先を **Any iOS Device (arm64)** にする
2. **Product → Archive**
3. Organizer が開く → **Distribute App**
4. **TestFlight & App Store** → Next → Upload
5. App Store Connect の処理を待つ（10〜30 分）
6. TestFlight のテスターに配信

> **App Store Connect 側の操作は不要です。**
> 規約への同意画面は `AppConstants.Legal.requiresConsent = false` で
> 止めてあるので、プライバシーポリシーの公開 URL も
> 「App のプライバシー」申告も要りません。
> 身内以外に配るときに `true` に戻してください（文書は残してあります）。

### 上げた後の確認

TestFlight 版は **Production** の CloudKit を使います。

1. CloudKit Console の環境を **Production** にする
2. **Data → Subscriptions** に `sub-new-messages-v1` があるか
3. アプリのプロフィール →「通知の状態を調べる」で 3 つとも ✅ か

---

## 困ったときの一覧

| 症状 | 見るところ |
|---|---|
| 通知が来ない | 手順 3（capability）→ 手順 5（診断）→ `docs/CLOUDKIT_MANUAL_SETUP.md` |
| Development では届くが TestFlight では届かない | **まず 2 台の iPadOS の版を確認**。26.4 ちょうどなら既知の OS 不具合。26.4.1 以降に更新する（`docs/CLOUDKIT_MANUAL_SETUP.md`）|
| Console.app に `attempting to create a subscription in a production container` | **これが実際の原因だった。** `docs/CLOUDKIT_MANUAL_SETUP.md`「購読の作成自体が Production で一律に失敗する場合」を見て、`Message.conversationKey` を追加・Deploy する |
| 掲示板が動かない | 手順 2（Deploy し忘れ） |
| すれ違わない | `docs/STREETPASS.md` の「7. うまくいかないときの確認順」 |
| ビルドエラー | エラー文をそのまま貼ってください |
| プロジェクトが壊れた | `git checkout SchoolMessage.xcodeproj` |

---

## 参考: 今回のぶんで **不要** な作業

- ❌ `xcodegen`（使わないでください）
- ❌ Apple Developer サイトでの作業（App ID、証明書、プロファイル）
- ❌ ゲーム（オセロ・色勝負）のための CloudKit 変更
  → 対戦の状態は暗号化されたメッセージの中に入っているため
- ❌ すれ違い通信のための CloudKit 変更
  → サーバーを一切通らないため
- ❌ すれ違い通信のための Xcode 設定
  → Bluetooth の Background Modes は entitlement を持たず、Info.plist だけで有効
- ❌ App Store Connect でのプライバシー申告
  → 同意画面を止めてあるため
- ❌ **Widget Extension の追加（ロック画面表示 / Live Activity）**
  → 見送り。Live Activity はバックグラウンド実行を与えないので、
  **すれ違い通信の成功率は 1% も上がらない**。効果は「動いているのが見えていれば
  アプリを強制終了されにくくなる」という見かけ上のものだけで、
  Xcode でのターゲット追加に見合わないと判断した。
  アプリ側のコードは残してあるので、やりたくなったら
  [`docs/LIVE_ACTIVITY.md`](LIVE_ACTIVITY.md) の手順で追加できる
