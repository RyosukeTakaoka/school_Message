import Foundation
import Observation

/// サーバ側が決めている「これ未満のビルドでは遊べない」下限.
struct RequiredRelease: Sendable, Hashable {
    /// 必要な最小のビルド番号(`202609161222` のような数値).
    let minimumBuild: Int
    /// 更新をお願いする理由. 画面にそのまま出す.
    let message: String?
}

/// 古いビルドを使い続けている人に更新してもらうための判定.
///
/// ## なぜサーバから下限を配るのか
/// ビルドに下限を焼き込んでも, **そのビルドを入れた人にしか届かない**.
/// 「古いビルドの人に更新してもらう」には, 古いビルド側が動いている最中に
/// 「もう古い」と知る必要があるので, 下限は必ず外から配る.
///
/// 下限は CloudKit の `AppRelease` レコード 1 件で, CloudKit Console から
/// 書き換える. アプリを配り直さずに, いつでも下限を上げられる.
///
/// ## 全部のビルドに更新を強いない
/// 最新かどうかは見ない. 見るのは下限だけなので, 「直さないと困る不具合を
/// 直したビルド」だけを下限に指定すれば, それ以外の更新は任意のままにできる.
///
/// ## 通信に失敗したら通す
/// 下限が読めなかったときは**必ず通す**. ここで止めてしまうと, 圏外や
/// CloudKit の不調だけで全員がアプリを開けなくなる. 締め出す判断は
/// 「下限がはっきり読めて, かつ自分がそれ未満だった」ときだけに限る.
@MainActor
@Observable
final class AppUpdateGate {

    /// いま動いているビルド番号. 読めなければ nil.
    let currentBuild: Int?

    /// サーバから読めた下限. まだ読んでいない/読めなかったときは nil.
    private(set) var required: RequiredRelease?

    /// 更新してもらうまでアプリを使えなくするか.
    var isBlocking: Bool {
        guard let required, let currentBuild else { return false }
        return currentBuild < required.minimumBuild
    }

    init(bundle: Bundle = .main) {
        self.currentBuild = (bundle.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// 下限を読み直す. 失敗しても何もしない(前に読めた値はそのまま残す).
    func refresh(using backend: any ChatBackend) async {
        guard let release = try? await backend.fetchRequiredRelease() else { return }
        required = release
    }
}
