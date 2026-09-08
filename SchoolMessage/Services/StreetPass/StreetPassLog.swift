import Foundation

/// すれ違いの記録.
///
/// ## なぜ画面から切り離すのか
/// Bluetooth に起こされた起動では, 画面(SwiftUI)が組み上がっているとは限らない.
/// 記録を画面側の持ち物にしてしまうと, せっかく起こされたのに書き残せない,
/// という取りこぼしが起きる. だから記録はファイルを持つ独立した部品にして,
/// 無線から直接書けるようにする.
///
/// サーバへは送らない. 「誰と誰がいつ同じ場所にいたか」は, 本人たち以外が
/// 持つべき情報ではないため.
///
/// メインスレッドからのみ触る前提で `@unchecked Sendable` にしている.
final class StreetPassLog: @unchecked Sendable {

    /// 記録の上限. これを超えたら古い順に捨てる.
    private static let maxEncounters = 300

    /// この時間内の再受信は, 同じ 1 回のすれ違いとして扱う.
    ///
    /// 1 回すれ違うと「こちらが相手を読む」経路と「相手がこちらへ書き込む」経路の
    /// 両方が成立しうる. そのまま数えると 1 回のすれ違いが 2 回になる.
    private static let sameEncounterWindow: TimeInterval = 90

    /// 記録した結果.
    enum Outcome {
        /// はじめて会った.
        case first
        /// 前に会ったことがある相手と, あらためてすれ違った.
        case again
        /// さっきのすれ違いの続き(数えない).
        case duplicate
    }

    private let fileURL: URL

    /// 新しい順.
    private(set) var encounters: [StreetPassEncounter] = []

    /// 記録が変わったときに呼ばれる(画面の更新用). メインスレッドで呼ばれる.
    var onChange: (([StreetPassEncounter]) -> Void)?

    init(fileManager: FileManager = .default) {
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

    // MARK: - 記録

    @discardableResult
    func record(_ card: StreetPassCard, rssi: Int?, at date: Date = .now) -> Outcome {
        let outcome: Outcome

        if let index = encounters.firstIndex(where: { $0.card.userID == card.userID }) {
            var encounter = encounters.remove(at: index)
            if date.timeIntervalSince(encounter.lastMetAt) < Self.sameEncounterWindow {
                encounter.card = card
                encounter.touch(rssi: rssi, at: date)
                outcome = .duplicate
            } else {
                encounter.met(with: card, rssi: rssi, at: date)
                outcome = .again
            }
            encounters.insert(encounter, at: 0)
        } else {
            encounters.insert(StreetPassEncounter(card: card, rssi: rssi, at: date), at: 0)
            outcome = .first
        }

        if encounters.count > Self.maxEncounters {
            encounters.removeLast(encounters.count - Self.maxEncounters)
        }
        persist()
        return outcome
    }

    var unseenCount: Int {
        encounters.filter(\.isUnseen).count
    }

    /// 今日すれ違った人数(ロック画面の表示に使う).
    func todayCount(calendar: Calendar = .current, now: Date = .now) -> Int {
        encounters.filter { calendar.isDate($0.lastMetAt, inSameDayAs: now) }.count
    }

    func markAllSeen() {
        guard unseenCount > 0 else { return }
        for index in encounters.indices {
            encounters[index].isUnseen = false
        }
        persist()
    }

    func remove(_ id: String) {
        encounters.removeAll { $0.id == id }
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
        onChange?(encounters)
    }
}
