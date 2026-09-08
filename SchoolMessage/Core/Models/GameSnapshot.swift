import Foundation

/// チャットに付随する対戦の 1 手ぶんの記録.
///
/// ## メッセージとして送る理由
/// 対戦の状態を CloudKit の独自レコードで持つ案もあったが, Public Database では
/// **レコードを更新できるのは作成者だけ**なので, 1 つの状態レコードを両者が
/// 交互に書き換えることができない.
///
/// そこで「1 手 = 1 メッセージ」とし, その時点の状態をまるごと載せる.
/// - 既存のメッセージ同期(プッシュ・定期取得)がそのまま使える
/// - 会話鍵で暗号化されるので, 対戦内容も第三者には読めない
/// - CloudKit のスキーマを変えずに済む
/// - 最新の 1 通が現在の状態なので, 復元も単純
///
/// 状態は毎回まるごと送る. 差分にすると, 途中の 1 通を取りこぼしただけで
/// 以降ずっと食い違うため, 状態そのものを送るほうが堅い.
enum GameSnapshot: Hashable, Sendable, Codable {

    case othello(OthelloSnapshot)
    case colorBattle(ColorBattleSnapshot)

    /// 遊びの種類.
    enum Kind: String, Hashable, Sendable, Codable, Identifiable, CaseIterable {
        case othello
        case colorBattle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .othello: String(localized: "オセロ")
            case .colorBattle: String(localized: "色勝負")
            }
        }

        var symbolName: String {
            switch self {
            case .othello: "circle.righthalf.filled"
            case .colorBattle: "square.stack.3d.up"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .othello: .othello
        case .colorBattle: .colorBattle
        }
    }

    /// 対戦の識別子. 同じチャットで何回でも遊べるよう, 対戦ごとに変える.
    var gameID: String {
        switch self {
        case .othello(let state): state.gameID
        case .colorBattle(let state): state.gameID
        }
    }

    var isFinished: Bool {
        switch self {
        case .othello(let state): state.isFinished
        case .colorBattle(let state): state.isFinished
        }
    }

    /// チャット一覧や通知に出す 1 行.
    var previewText: String {
        isFinished
            ? String(localized: "\(kind.title)(対戦終了)")
            : kind.title
    }

    var othello: OthelloSnapshot? {
        if case .othello(let state) = self { return state }
        return nil
    }

    var colorBattle: ColorBattleSnapshot? {
        if case .colorBattle(let state) = self { return state }
        return nil
    }
}

// MARK: - 保存の形

extension GameSnapshot {

    private enum CodingKeys: String, CodingKey {
        case othello
        case colorBattle
    }

    /// 遊びが 1 種類しか無かった頃に送られたメッセージも読めるようにする.
    ///
    /// 以前は `GameSnapshot` がオセロの状態そのものだったため, 既に送信済みの
    /// メッセージには種類の目印が入っていない. 新しい形で読めなければ,
    /// 旧い形(オセロ)として読み直す. ここで拾わないと, 過去の対戦を含む
    /// 会話全体が復号できずに壊れて見えてしまう.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let state = try? container.decode(OthelloSnapshot.self, forKey: .othello) {
                self = .othello(state)
                return
            }
            if let state = try? container.decode(ColorBattleSnapshot.self, forKey: .colorBattle) {
                self = .colorBattle(state)
                return
            }
        }
        let legacy = try OthelloSnapshot(from: decoder)
        self = .othello(legacy)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .othello(let state): try container.encode(state, forKey: .othello)
        case .colorBattle(let state): try container.encode(state, forKey: .colorBattle)
        }
    }
}
