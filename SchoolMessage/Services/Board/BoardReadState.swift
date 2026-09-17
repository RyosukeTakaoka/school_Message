import Foundation

/// 掲示板を「どこまで読んだか」の, この端末だけの記録.
///
/// チャットの既読(`ReadState`)と違い, 掲示板はサーバ側に既読を置く仕組みが無い
/// (掲示板は暗号化もせず, 誰が読んだかを外に見せない場所として作っているため,
/// 「誰がどこまで読んだか」をサーバに残すのはその方針に合わない).
///
/// そこでスレッドごとに「最後に確認した書き込み数」だけをこの端末に覚えておく.
/// 新着の有無は, いまの書き込み数とこの記録を比べるだけで分かるので,
/// 書き込みの内容そのものを保存しておく必要が無い(`ChatStore+Board.swift` 参照).
final class BoardReadState: @unchecked Sendable {

    private static let key = "board.seenPostCounts"
    /// 記録しておくスレッドの数の上限. 増え続けるスレッドを無限に溜め続けない
    /// ための保険で, 厳密な運用ルールがあるわけではない.
    private static let limit = 500

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var seenPostCounts: [String: Int] {
        get { defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// 最後に確認したときの書き込み数. まだ開いたことが無ければ 0.
    func seenPostCount(for threadID: ThreadID) -> Int {
        seenPostCounts[threadID.rawValue] ?? 0
    }

    /// 開いた時点までの書き込みを「読んだ」ことにする.
    ///
    /// すでに覚えている数より小さい値では上書きしない. 一覧の取得が
    /// 前後することがあっても, 既読の位置が後退しないようにするため.
    func markSeen(_ threadID: ThreadID, postCount: Int) {
        var current = seenPostCounts
        current[threadID.rawValue] = max(postCount, current[threadID.rawValue] ?? 0)

        if current.count > Self.limit {
            let overflow = current.count - Self.limit
            for key in current.keys.prefix(overflow) { current.removeValue(forKey: key) }
        }
        seenPostCounts = current
    }
}
