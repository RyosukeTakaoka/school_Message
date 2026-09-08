import Foundation
import Observation
import UserNotifications

/// すれ違いの記録と, 無線の入り切り.
///
/// ## 既定で切ってある理由
/// すれ違い通信は, 周りにいる人へ自分の名前を電波で配る仕組み. 気付かないうちに
/// 配られているのが一番良くないので, **利用者が自分で入れるまで動かさない**.
/// 画面にも何が配られるかを書いてから入れてもらう.
///
/// 記録は端末の中だけに持つ. 「誰と誰がいつ同じ場所にいたか」はサーバに
/// 集めてよい情報ではないため, iCloud には送らない.
@MainActor
@Observable
final class StreetPassStore {

    private enum Key {
        static let isEnabled = "streetpass.enabled"
        static let comment = "streetpass.comment"
    }

    /// 記録の上限. これを超えたら古い順に捨てる.
    private static let maxEncounters = 300

    /// 走査を仕切り直す間隔(前面にいるとき).
    private static let rescanInterval: TimeInterval = 90

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private weak var chatStore: ChatStore?
    @ObservationIgnored private var radio: StreetPassRadio?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    private var enabledStorage: Bool
    private var commentStorage: String

    /// すれ違い通信を動かすか.
    var isEnabled: Bool {
        get { enabledStorage }
        set {
            guard enabledStorage != newValue else { return }
            enabledStorage = newValue
            defaults.set(newValue, forKey: Key.isEnabled)
            if newValue { startRadio() } else { stopRadio() }
        }
    }

    /// すれ違った相手に見せる一言.
    var comment: String {
        get { commentStorage }
        set {
            let trimmed = String(newValue.prefix(StreetPassCard.commentMaxLength))
            guard commentStorage != trimmed else { return }
            commentStorage = trimmed
            defaults.set(trimmed, forKey: Key.comment)
            // 電波に載っている名刺も差し替える.
            radio?.updateCard(myCard?.encoded())
        }
    }

    private(set) var status: StreetPassRadio.Status = .idle

    /// すれ違った相手. 新しい順.
    private(set) var encounters: [StreetPassEncounter] = []

    /// まだ確認していない人数.
    var unseenCount: Int {
        encounters.filter(\.isUnseen).count
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.enabledStorage = defaults.bool(forKey: Key.isEnabled)
        self.commentStorage = defaults.string(forKey: Key.comment) ?? ""

        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let directory = root.appendingPathComponent("StreetPass", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("encounters.json")

        load()
    }

    // MARK: - 組み立て

    func attach(store: ChatStore) {
        chatStore = store
    }

    /// プロフィールが読めた / 変わったときに呼ぶ.
    ///
    /// 名前が入っていない状態で電波を出しても相手側で捨てられるので,
    /// プロフィールが揃ってから始める.
    func refresh() {
        guard isEnabled else { return }
        startRadio()
    }

    /// 前面に戻ったとき. 近くにいる相手を拾い直す.
    func handleForeground() {
        guard isEnabled else { return }
        startRadio()
        radio?.rescan()
    }

    // MARK: - 無線

    private var myCard: StreetPassCard? {
        guard let profile = chatStore?.myProfile else { return nil }
        return StreetPassCard(
            userID: profile.id,
            handle: profile.handle,
            displayName: profile.displayName,
            comment: commentStorage
        )
    }

    private func startRadio() {
        guard let card = myCard, let data = card.encoded() else { return }

        if radio == nil {
            radio = StreetPassRadio(
                onEncounter: { [weak self] card in
                    Task { @MainActor in self?.record(card) }
                },
                onStatusChange: { [weak self] status in
                    Task { @MainActor in self?.status = status }
                }
            )
        }
        radio?.updateCard(data)
        radio?.start()
        startRescanLoop()
    }

    private func stopRadio() {
        rescanTask?.cancel()
        rescanTask = nil
        radio?.stop()
        radio = nil
        status = .idle
    }

    /// 走査は「同じ端末を何度も報告しない」設定なので, 定期的に仕切り直す.
    /// 背面では iOS 側が間引くため, これは主に前面での再会用.
    private func startRescanLoop() {
        guard rescanTask == nil else { return }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.rescanInterval))
                guard !Task.isCancelled else { return }
                self?.radio?.rescan()
            }
        }
    }

    // MARK: - 記録

    private func record(_ card: StreetPassCard) {
        // 自分自身は数えない(同じ iCloud アカウントの端末を 2 台持っている場合).
        guard card.userID != chatStore?.myProfile?.id else { return }

        if let index = encounters.firstIndex(where: { $0.card.userID == card.userID }) {
            var encounter = encounters.remove(at: index)
            encounter.met(with: card)
            encounters.insert(encounter, at: 0)
            notify(card, isFirstTime: false)
        } else {
            encounters.insert(StreetPassEncounter(card: card), at: 0)
            notify(card, isFirstTime: true)
        }

        if encounters.count > Self.maxEncounters {
            encounters.removeLast(encounters.count - Self.maxEncounters)
        }
        persist()
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

    func markAllSeen() {
        guard unseenCount > 0 else { return }
        for index in encounters.indices {
            encounters[index].isUnseen = false
        }
        persist()
    }

    func remove(_ encounter: StreetPassEncounter) {
        encounters.removeAll { $0.id == encounter.id }
        persist()
    }

    func removeAll() {
        encounters = []
        persist()
    }

    // MARK: - 保存

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            encounters = try JSONDecoder().decode([StreetPassEncounter].self, from: data)
        } catch {
            // 壊れた記録で起動できなくなるのが最悪なので, 捨てて先へ進む.
            Log.streetPass.error("the encounter log is unreadable; discarding")
            encounters = []
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(encounters)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.streetPass.error("failed to persist the encounter log")
        }
    }
}
