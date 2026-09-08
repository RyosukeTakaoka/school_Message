import Foundation
import UserNotifications

/// すれ違い通信の本体. 画面より先に, アプリ起動のいちばん早い段階で組み立てる.
///
/// ## なぜ画面(SwiftUI)の下に置かないのか
/// CoreBluetooth の復元(State Restoration)には条件がある.
/// **`application(_:willFinishLaunchingWithOptions:)` の時点でマネージャを
/// 作り直していること**. ここを外すと, iOS がせっかくアプリを起こしても
/// 「復元先がいない」と判断され, 復元は捨てられる.
///
/// 画面の組み立て(`AppEnvironment` → `RootView`)を待ってから無線を起こす形だと,
/// この条件を満たせない. だから無線の生死を画面に握らせず, ここが持つ.
///
/// ```
/// アプリ起動
///   └─ AppDelegate.willFinishLaunching
///        └─ StreetPassKit.bootstrap()   ← 無線はここで動き出す
///             ├─ 設定(入り切り・一言・名刺の控え)
///             ├─ 記録(ファイル)
///             └─ 無線(CoreBluetooth + 復元)
///   └─ SwiftUI (AppEnvironment → StreetPassStore)  ← 表示するだけ
/// ```
///
/// 画面側の `StreetPassStore` は, ここを見に来るだけの薄い包み.
/// 画面が無い状態(バックグラウンドで起こされた直後)でも, 記録と通知は成立する.
///
/// メインスレッドからのみ触る前提で `@unchecked Sendable` にしている.
final class StreetPassKit: @unchecked Sendable {

    static let shared = StreetPassKit()

    let settings: StreetPassSettings
    let log: StreetPassLog
    let liveActivity: StreetPassLiveActivity

    private var radio: StreetPassRadio?
    private var hasBootstrapped = false

    /// 状態が変わったときに画面へ知らせる. メインスレッドで呼ばれる.
    var onStatusChange: ((StreetPassRadio.Status) -> Void)?

    private(set) var status: StreetPassRadio.Status = .idle

    init(
        settings: StreetPassSettings = StreetPassSettings(),
        log: StreetPassLog = StreetPassLog(),
        liveActivity: StreetPassLiveActivity = StreetPassLiveActivity()
    ) {
        self.settings = settings
        self.log = log
        self.liveActivity = liveActivity
    }

    // MARK: - 起動

    /// `AppDelegate.application(_:willFinishLaunchingWithOptions:)` から呼ぶ.
    ///
    /// プロフィールの取得(iCloud)は待たない. 待つと, 起こされた理由である
    /// そのすれ違い自体を取りこぼす. 最後に分かっていた名刺の控えで走り出し,
    /// 本物が読めたら `updateCard(from:)` で差し替える.
    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        guard settings.isEnabled else { return }
        // ロック画面の表示は, すでに出ているものがあれば引き継ぐだけにする.
        // ActivityKit の決まりで, 新しく出せるのは前面にいるときだけ.
        liveActivity.adoptExisting()
        startRadio()
    }

    // MARK: - 入り切り

    var isEnabled: Bool {
        settings.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        if enabled {
            startRadio()
            startLiveActivity()
        } else {
            stopRadio()
            liveActivity.stop()
        }
    }

    var comment: String {
        settings.comment
    }

    func setComment(_ comment: String) {
        guard settings.comment != comment else { return }
        settings.comment = comment
        // 一言だけ差し替えた名刺を作り直す.
        if let card = settings.card {
            updateCard(
                StreetPassCard(
                    userID: card.userID,
                    handle: card.handle,
                    displayName: card.displayName,
                    comment: settings.comment
                )
            )
        }
    }

    // MARK: - 名刺

    /// iCloud から読めた本物のプロフィールを反映する.
    func updateCard(from profile: UserProfile) {
        updateCard(
            StreetPassCard(
                userID: profile.id,
                handle: profile.handle,
                displayName: profile.displayName,
                comment: settings.comment
            )
        )
    }

    private func updateCard(_ card: StreetPassCard) {
        guard let data = card.encoded() else { return }
        settings.cardData = data
        radio?.updateCard(data)
        // 名前が分かって初めて配れるようになる場合がある.
        if settings.isEnabled { startRadio() }
    }

    // MARK: - 前面復帰

    func handleForeground() {
        guard settings.isEnabled else { return }
        startRadio()
        radio?.rescan()
        // 開始は前面からしかできない. 8 時間ほどで system に終了させられるので,
        // 前面に戻るたびに出し直す(すでに出ていれば内容の更新だけになる).
        startLiveActivity()
    }

    // MARK: - 無線

    private func startRadio() {
        // 名刺が無い状態で電波を出しても相手側で捨てられるので, 揃うまで待つ.
        guard let cardData = settings.cardData else { return }

        if radio == nil {
            radio = StreetPassRadio(
                onEncounter: { [weak self] card, rssi in
                    self?.handleEncounter(card, rssi: rssi)
                },
                onStatusChange: { [weak self] status in
                    guard let self else { return }
                    self.status = status
                    self.onStatusChange?(status)
                },
                onRestore: { [weak self] in
                    self?.settings.noteRestored()
                    Log.streetPass.info("woken up by bluetooth")
                }
            )
        }
        radio?.updateCard(cardData)
        radio?.start()
    }

    private func stopRadio() {
        radio?.stop()
        radio = nil
        status = .idle
        onStatusChange?(.idle)
    }

    // MARK: - すれ違いの記録

    private func handleEncounter(_ card: StreetPassCard, rssi: Int?) {
        // 自分自身は数えない(同じ iCloud アカウントの端末を 2 台持っている場合).
        guard card.userID != settings.card?.userID else { return }

        switch log.record(card, rssi: rssi) {
        case .first:
            notify(card, isFirstTime: true)
        case .again:
            notify(card, isFirstTime: false)
        case .duplicate:
            // 同じすれ違いの続き. 通知は出さない.
            break
        }
        // 更新はバックグラウンドからでもできる.
        liveActivity.update(activityState())
    }

    // MARK: - ロック画面の表示

    private func startLiveActivity() {
        guard settings.isEnabled else { return }
        liveActivity.start(
            ownerName: settings.card?.displayName ?? String(localized: "自分"),
            state: activityState()
        )
    }

    private func activityState() -> StreetPassActivityAttributes.ContentState {
        let latest = log.encounters.first
        return StreetPassActivityAttributes.ContentState(
            todayCount: log.todayCount(),
            totalCount: log.encounters.count,
            latestName: latest?.card.displayName,
            latestAt: latest?.lastMetAt
        )
    }

    /// すれ違ったことを端末内の通知で知らせる.
    ///
    /// サーバは通さない(相手とすれ違ったことを外に出さないため).
    /// 通知が許可されていなければ, 黙って何も起きない.
    private func notify(_ card: StreetPassCard, isFirstTime: Bool) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "すれ違い通信")
        content.body = isFirstTime
            ? String(localized: "\(card.displayName) とはじめてすれ違いました")
            : String(localized: "\(card.displayName) とすれ違いました")
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "streetpass-\(card.userID.rawValue)-\(Int(Date.now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
