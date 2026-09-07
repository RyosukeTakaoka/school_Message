import Foundation
import Observation

/// 利用規約とプライバシーポリシーへの同意状態.
///
/// ## 保存先に UserDefaults を選んだ理由
/// 同意の記録は「この端末の利用者が同意したか」を表すだけの情報で,
/// 秘匿性は無く, 他の端末と共有する必要もない(端末ごとに同意画面を出すのが
/// 一般的な挙動). CloudKit に置くと iCloud にサインインする前の段階で
/// 同意を取れなくなるため, 端末内で完結させる.
///
/// ## 版を持たせる理由
/// 規約を改定したときに, 旧版にしか同意していない利用者へもう一度提示する
/// 必要がある. 同意の有無ではなく「どの版に同意したか」を保存する.
@MainActor
@Observable
final class ConsentStore {

    /// 現在提示している規約の版.
    ///
    /// 規約・ポリシーの内容を実質的に変更したら, この値を必ず更新すること.
    /// 更新すると, 既に同意済みの利用者にも同意画面がもう一度表示される.
    static let currentVersion = "2026-09-07"

    private let defaults: UserDefaults
    private let storageKey = "legal.agreedVersion"

    /// 同意済みの版. 未同意なら nil.
    private(set) var agreedVersion: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.agreedVersion = defaults.string(forKey: storageKey)
    }

    /// 現在の版に同意済みか.
    var hasAgreedToCurrentVersion: Bool {
        agreedVersion == Self.currentVersion
    }

    /// 旧版には同意しているが, 改定後の版には同意していない状態.
    /// 初回の利用者と区別して案内を変えるために使う.
    var needsReconsentAfterUpdate: Bool {
        guard let agreedVersion else { return false }
        return agreedVersion != Self.currentVersion
    }

    func agree() {
        agreedVersion = Self.currentVersion
        defaults.set(Self.currentVersion, forKey: storageKey)
    }

    /// 同意を取り消す(動作確認用).
    func reset() {
        agreedVersion = nil
        defaults.removeObject(forKey: storageKey)
    }
}
