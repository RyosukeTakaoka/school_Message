import Foundation

/// 競馬の結果アニメーションを, この端末で自動再生したことがあるかの記録.
///
/// `BoardReadState` と同じ考え方で, サーバには置かず端末だけに残す
/// (「見たかどうか」は他人と共有する必要が無いため).
///
/// ## なぜ必要か
/// 結果画面を開くたびに `HorseRaceView` の `@State` は作り直されるので,
/// 何も覚えていないと「初めて結果を見たとき」の判定(`state?.run == nil`)が
/// 毎回真になり, 同じレースを開き直すたびに演出が最初から流れてしまう.
/// このレースを一度でも自動再生していれば, 次からは結果だけを出し,
/// 見返したいときは「もう一度見る」ボタン(任意リプレイ)に任せる.
enum HorseRaceWatchState {

    private static let key = "horserace.autoPlayedRaceIDs"
    /// 記録しておく開催日の数の上限. 増え続ける記録を溜め続けないための保険で,
    /// 厳密な運用ルールがあるわけではない(`BoardReadState.limit` と同じ考え方).
    private static let limit = 30

    /// このレースの結果を, 過去にこの端末で自動再生したか.
    static func hasAutoPlayed(raceID: String, defaults: UserDefaults = .standard) -> Bool {
        raceIDs(defaults: defaults).contains(raceID)
    }

    /// このレースの結果を自動再生した, とこの端末に記録する.
    static func markAutoPlayed(raceID: String, defaults: UserDefaults = .standard) {
        var ids = raceIDs(defaults: defaults)
        guard !ids.contains(raceID) else { return }
        ids.append(raceID)
        if ids.count > limit {
            ids.removeFirst(ids.count - limit)
        }
        defaults.set(ids, forKey: key)
    }

    private static func raceIDs(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}
