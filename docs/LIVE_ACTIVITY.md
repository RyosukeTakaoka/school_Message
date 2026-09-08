# ロック画面表示（Live Activity）を出す

すれ違い通信が動いていることを、ロック画面に出す。

```
┌──────────────────────────────────────┐
│ 🚶  すれ違い通信                  3  │
│     さいごは たかおか            今日 │
└──────────────────────────────────────┘
```

---

## 先に確認すること（ここが最重要）

**この作業をする前に、アプリで使えるかどうかを確かめてください。**

1. `git pull` してビルドし、アプリを iPad に入れる
2. チャット一覧右上の「すれ違い通信」を開く
3. トグルを入れて、**「ロック画面表示」** の行を見る

| 表示 | 意味 | この作業を |
|---|---|---|
| **使えます（まだ出ていません）** | 端末は対応している | **やる価値あり** |
| **この端末または設定では使えません** | 端末が非対応、または設定でオフ | **やらなくていい** |
| 何かのエラー文 | そのエラー次第 | 文面を見て判断 |

理由: Live Activity が iPad で使えるかは iPadOS の版によって違う。
推測で作業時間を使うより、実機に聞いたほうが早くて確実。
使えない場合、この作業をしてもロック画面には何も出ない
（すれ違い通信そのものは変わらず動く）。

---

## 何のためにやるのか（期待値の調整）

**Bluetooth の成功率は 1% も上がらない。**
Live Activity はバックグラウンド実行を与えない。ロック画面に出る表示であって、
アプリを動かし続ける仕組みではない。

効くのはここだけ。

- ロック画面に出ていれば、**アプリを上スワイプで終了させにくくなる**。
  強制終了された後のすれ違いは実装では救えないので、
  「起こさせない」ことが唯一の緩和策になる
- すれ違いで起こされたその実行機会に表示を更新できるので、
  アプリを開かずに今日の人数が分かる

これを理解した上でやるかどうか決めてください。

---

## 手順

所要 10 分程度。**Xcode でのターゲット追加が必要な、唯一の作業**です。

### 1. Widget Extension ターゲットを追加する

1. Xcode で `SchoolMessage.xcodeproj` を開く
2. メニュー **File > New > Target…**
3. **iOS** タブ → **Widget Extension** を選んで **Next**
4. 入力・チェック

   | 項目 | 値 |
   |---|---|
   | Product Name | `StreetPassWidget` ← **この名前ちょうど** |
   | Team | 自分の Team |
   | **Include Live Activity** | ✅ **チェックを入れる** |
   | Include Configuration App Intent | どちらでもよい |

5. **Finish**
6. 「Activate "StreetPassWidget" scheme?」と聞かれたら **Cancel**
   （実行するのは本体アプリなので、スキームは切り替えない）

これで `StreetPassWidget/` フォルダとターゲットができる。
Bundle ID は自動で `app.takaoka.com.schoolmessage.StreetPassWidget` になり、
署名も自動（Automatically manage signing）なので、
**Apple Developer サイトでの作業は不要**。

### 2. ひな形を、用意してある中身で置き換える

ターミナルでリポジトリのフォルダに移動して、1 行:

```sh
cp WidgetSource/StreetPassWidgetLiveActivity.swift \
   StreetPassWidget/StreetPassWidgetLiveActivity.swift
```

Xcode 側は自動で読み直す（読まなければ Xcode を再起動）。

> ひな形の他のファイル（`StreetPassWidget.swift`、`AppIntent.swift`、
> `StreetPassWidgetControl.swift` など）は**そのままでよい**。
> ホーム画面ウィジェットとして残るだけで、害はない。

### 3. 共有する型を、Widget ターゲットにも入れる

これを忘れるとビルドが通らない（`StreetPassActivityAttributes` が見つからない）。

1. Xcode 左のファイル一覧で
   `SchoolMessage/Services/StreetPass/StreetPassActivityAttributes.swift` を選ぶ
2. 右側のインスペクタ（無ければ ⌥⌘0）→ **Target Membership**
3. **`StreetPassWidget` にもチェックを入れる**
   （`SchoolMessage` のチェックはそのまま）

```
Target Membership
  ☑ SchoolMessage
  ☑ StreetPassWidget   ← これを追加
```

### 4. ビルドして確認

1. スキームが **SchoolMessage**（本体アプリ）になっていることを確認
2. iPad を選んで ⌘R
3. すれ違い通信を開き、トグルを入れる
4. 「ロック画面表示」の行が **出ています** になる
5. iPad をロックする → ロック画面に出る

---

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `Cannot find 'StreetPassActivityAttributes' in scope` | 手順 3 のチェックが入っていない |
| ビルドは通るが「この端末または設定では使えません」 | 端末が非対応、または 設定 > Face ID とパスコード > ロック中にアクセスを許可 / 設定 > App > ライブアクティビティ を確認 |
| 「まだ出ていません」から変わらない | いったんトグルを切って入れ直す（開始は前面からしかできない） |
| 数時間後に消える | 仕様。system が一定時間で終了させる。アプリを前面に戻すと出し直す |
| ターゲット追加でビルドが壊れた | `git checkout SchoolMessage.xcodeproj` で元に戻せる（追加したターゲットは消える） |

---

## 仕組みのメモ

| いつ | 何をする | どこから |
|---|---|---|
| 開始 | `Activity.request` | **前面のみ**（ActivityKit の決まり） |
| 更新 | `Activity.update` | バックグラウンドからでも可 |
| 終了 | `Activity.end` | どこからでも可 |

だから、
- すれ違い通信を入れたとき / 前面に戻ったときに**出す**
- すれ違ったとき（バックグラウンドで起こされた場合も含む）に**更新する**
- すれ違い通信を切ったときに**消す**

という形にしてある。実装は `StreetPassLiveActivity.swift`。

サーバ（プッシュ）は使わない。更新はすべて端末の中で完結する。
