import Foundation
import Observation

/// すれ違い通信の画面側の窓口.
///
/// 実体は `StreetPassKit`(アプリ起動のいちばん早い段階で組み立てられる).
/// ここは**表示と操作のための薄い包み**でしかない.
///
/// この分け方には理由がある. 無線の生死を画面が握っていると, CoreBluetooth の
/// 復元条件(起動直後にマネージャを作り直していること)を満たせず,
/// 「アプリを開いていないときのすれ違い」が成立しなくなる.
/// 詳しくは `StreetPassKit` と `docs/STREETPASS.md`.
@MainActor
@Observable
final class StreetPassStore {

    @ObservationIgnored private let kit: StreetPassKit
    @ObservationIgnored private weak var chatStore: ChatStore?

    private(set) var status: StreetPassRadio.Status
    /// すれ違った相手. 新しい順.
    private(set) var encounters: [StreetPassEncounter]

    // 実体は `StreetPassKit`(画面より下)にある. 画面が変化に気付けるよう,
    // 観測できる形の控えをここに持ち, 書き込みは必ず下へ流す.
    private var enabledMirror: Bool
    private var commentMirror: String

    var isEnabled: Bool {
        get { enabledMirror }
        set {
            enabledMirror = newValue
            kit.setEnabled(newValue)
            syncProfileIntoCard()
            status = kit.status
        }
    }

    var comment: String {
        get { commentMirror }
        set {
            let trimmed = String(newValue.prefix(StreetPassCard.commentMaxLength))
            guard commentMirror != trimmed else { return }
            commentMirror = trimmed
            kit.setComment(trimmed)
        }
    }

    /// まだ確認していない人数.
    var unseenCount: Int {
        encounters.filter(\.isUnseen).count
    }

    /// 診断用. システムに起こされた回数(バックグラウンドで動いている証拠).
    var restoreCount: Int { kit.settings.restoreCount }
    var lastRestoredAt: Date? { kit.settings.lastRestoredAt }

    init(kit: StreetPassKit = .shared) {
        self.kit = kit
        self.status = kit.status
        self.encounters = kit.log.encounters
        self.enabledMirror = kit.isEnabled
        self.commentMirror = kit.comment

        // 記録も状態も, 無線側(画面より下)から届く. 画面へ写し取るだけにする.
        kit.log.onChange = { [weak self] encounters in
            Task { @MainActor in self?.encounters = encounters }
        }
        kit.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
    }

    // MARK: - 組み立て

    func attach(store: ChatStore) {
        chatStore = store
    }

    /// プロフィールが読めた / 変わったときに呼ぶ.
    func refresh() {
        syncProfileIntoCard()
        status = kit.status
    }

    /// 前面に戻ったとき. 近くにいる相手を拾い直す.
    func handleForeground() {
        kit.handleForeground()
        encounters = kit.log.encounters
        status = kit.status
    }

    private func syncProfileIntoCard() {
        guard let profile = chatStore?.myProfile else { return }
        kit.updateCard(from: profile)
    }

    // MARK: - 記録の操作

    func markAllSeen() {
        kit.log.markAllSeen()
        encounters = kit.log.encounters
    }

    func remove(_ encounter: StreetPassEncounter) {
        kit.log.remove(encounter.id)
        encounters = kit.log.encounters
    }

    func removeAll() {
        kit.log.removeAll()
        encounters = kit.log.encounters
    }
}
