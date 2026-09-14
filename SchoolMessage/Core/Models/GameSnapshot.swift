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
    /// グループでの大富豪. 他の 2 つと違い 3 人以上で遊ぶ
    /// (`ChatDetailView` で会話の種類ごとにメニューを分けている).
    case daifugo(DaifugoSnapshot)
    /// ここから下は CHIP(アプリ内ポイント)を使う遊び.
    case indianPoker(IndianPokerSnapshot)
    case doubt(DoubtSnapshot)
    case blackjack(BlackjackSnapshot)
    case chinchiro(ChinchiroSnapshot)

    /// 遊びの種類.
    enum Kind: String, Hashable, Sendable, Codable, Identifiable, CaseIterable {
        case othello
        case colorBattle
        case daifugo
        case indianPoker
        case doubt
        case blackjack
        case chinchiro

        var id: String { rawValue }

        var title: String {
            switch self {
            case .othello: String(localized: "オセロ")
            case .colorBattle: String(localized: "色勝負")
            case .daifugo: String(localized: "大富豪")
            case .indianPoker: String(localized: "インディアンポーカー")
            case .doubt: String(localized: "ダウト")
            case .blackjack: String(localized: "ブラックジャック")
            case .chinchiro: String(localized: "チンチロ")
            }
        }

        var symbolName: String {
            switch self {
            case .othello: "circle.righthalf.filled"
            case .colorBattle: "square.stack.3d.up"
            case .daifugo: "suit.spade.fill"
            case .indianPoker: "eye.slash"
            case .doubt: "questionmark.app"
            case .blackjack: "suit.club.fill"
            case .chinchiro: "die.face.5"
            }
        }

        /// 1 対 1(direct)向けか, グループ向けか.
        var supportedConversationKinds: Set<ConversationKind> {
            switch self {
            case .othello, .colorBattle, .indianPoker: [.direct]
            case .daifugo, .doubt: [.group]
            case .blackjack, .chinchiro: [.direct, .group]
            }
        }

        /// CHIP を賭けて遊ぶか.
        var usesChip: Bool {
            maxBet != nil
        }

        /// 1 回に賭けられる上限. CHIP を使わない遊びは nil.
        var maxBet: Int? {
            switch self {
            case .othello, .colorBattle, .daifugo: nil
            case .indianPoker: IndianPokerSnapshot.maxBet
            case .doubt: DoubtSnapshot.maxBet
            case .blackjack: BlackjackSnapshot.maxBet
            case .chinchiro: ChinchiroSnapshot.maxBet
            }
        }

        /// 遊ぶのに必要な人数.
        var minimumPlayers: Int {
            switch self {
            case .othello, .colorBattle, .indianPoker: 2
            case .daifugo: DaifugoSnapshot.Lobby.minimumPlayers
            case .doubt: DoubtSnapshot.minimumPlayers
            case .blackjack: BlackjackSnapshot.minimumPlayers
            case .chinchiro: ChinchiroSnapshot.minimumPlayers
            }
        }
    }

    var kind: Kind {
        switch self {
        case .othello: .othello
        case .colorBattle: .colorBattle
        case .daifugo: .daifugo
        case .indianPoker: .indianPoker
        case .doubt: .doubt
        case .blackjack: .blackjack
        case .chinchiro: .chinchiro
        }
    }

    /// 対戦の識別子. 同じチャットで何回でも遊べるよう, 対戦ごとに変える.
    var gameID: String {
        switch self {
        case .othello(let state): state.gameID
        case .colorBattle(let state): state.gameID
        case .daifugo(let state): state.gameID
        case .indianPoker(let state): state.gameID
        case .doubt(let state): state.gameID
        case .blackjack(let state): state.gameID
        case .chinchiro(let state): state.gameID
        }
    }

    var isFinished: Bool {
        switch self {
        case .othello(let state): state.isFinished
        case .colorBattle(let state): state.isFinished
        case .daifugo(let state): state.isFinished
        case .indianPoker(let state): state.isFinished
        case .doubt(let state): state.isFinished
        case .blackjack(let state): state.isFinished
        case .chinchiro(let state): state.isFinished
        }
    }

    /// 決着した対戦の CHIP 増減. CHIP を使わない / まだ決着していないなら空.
    ///
    /// 各自の端末は, ここから**自分のぶんだけ**を取り出して自分の残高に反映する
    /// (他人の残高は書き換えられない仕組みのため).
    var chipDeltas: [UserID: Int] {
        switch self {
        case .othello, .colorBattle, .daifugo: [:]
        case .indianPoker(let state): state.chipDeltas
        case .doubt(let state): state.chipDeltas
        case .blackjack(let state): state.chipDeltas
        case .chinchiro(let state): state.chipDeltas
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

    var daifugo: DaifugoSnapshot? {
        if case .daifugo(let state) = self { return state }
        return nil
    }

    var indianPoker: IndianPokerSnapshot? {
        if case .indianPoker(let state) = self { return state }
        return nil
    }

    var doubt: DoubtSnapshot? {
        if case .doubt(let state) = self { return state }
        return nil
    }

    var blackjack: BlackjackSnapshot? {
        if case .blackjack(let state) = self { return state }
        return nil
    }

    var chinchiro: ChinchiroSnapshot? {
        if case .chinchiro(let state) = self { return state }
        return nil
    }
}

// MARK: - 保存の形

extension GameSnapshot {

    private enum CodingKeys: String, CodingKey {
        case othello
        case colorBattle
        case daifugo
        case indianPoker
        case doubt
        case blackjack
        case chinchiro
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
            if let state = try? container.decode(DaifugoSnapshot.self, forKey: .daifugo) {
                self = .daifugo(state)
                return
            }
            if let state = try? container.decode(IndianPokerSnapshot.self, forKey: .indianPoker) {
                self = .indianPoker(state)
                return
            }
            if let state = try? container.decode(DoubtSnapshot.self, forKey: .doubt) {
                self = .doubt(state)
                return
            }
            if let state = try? container.decode(BlackjackSnapshot.self, forKey: .blackjack) {
                self = .blackjack(state)
                return
            }
            if let state = try? container.decode(ChinchiroSnapshot.self, forKey: .chinchiro) {
                self = .chinchiro(state)
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
        case .daifugo(let state): try container.encode(state, forKey: .daifugo)
        case .indianPoker(let state): try container.encode(state, forKey: .indianPoker)
        case .doubt(let state): try container.encode(state, forKey: .doubt)
        case .blackjack(let state): try container.encode(state, forKey: .blackjack)
        case .chinchiro(let state): try container.encode(state, forKey: .chinchiro)
        }
    }
}
