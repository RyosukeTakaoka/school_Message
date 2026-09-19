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
    case bust(BustSnapshot)
    case slingo(SlingoSnapshot)

    /// 遊びの種類.
    enum Kind: String, Hashable, Sendable, Codable, Identifiable, CaseIterable {
        case othello
        case colorBattle
        case daifugo
        case indianPoker
        case doubt
        case blackjack
        case chinchiro
        case bust
        case slingo

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
            case .bust: String(localized: "CRASH")
            case .slingo: String(localized: "スリンゴ")
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
            case .bust: "flame.fill"
            case .slingo: "square.grid.3x3.fill"
            }
        }

        /// 1 対 1(direct)向けか, グループ向けか.
        var supportedConversationKinds: Set<ConversationKind> {
            switch self {
            case .othello, .colorBattle, .indianPoker: [.direct]
            case .daifugo, .doubt: [.group]
            case .blackjack, .chinchiro, .bust, .slingo: [.direct, .group]
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
            case .bust: BustSnapshot.maxBet
            case .slingo: SlingoSnapshot.maxBet
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
            case .bust: BustSnapshot.minimumPlayers
            case .slingo: SlingoSnapshot.minimumPlayers
            }
        }

        /// 参加できる上限人数. 上限が無い遊びは nil.
        ///
        /// BUST と Slingo だけの特別な制約. 人数が増えるほど「早く動いた人」が
        /// 有利になりすぎるバランス崩れが大きくなるため, 上限を設けている
        /// (`BustSnapshot` のコメント参照)。
        var maximumPlayers: Int? {
            switch self {
            case .othello, .colorBattle, .daifugo, .indianPoker, .doubt, .blackjack, .chinchiro: nil
            case .bust: BustSnapshot.maximumPlayers
            case .slingo: SlingoSnapshot.maximumPlayers
            }
        }

        /// ルール説明. ランキング画面から見られる「対戦ルール一覧」でまとめて使う.
        var rules: String {
            switch self {
            case .othello:
                String(localized: """
                    8x8の盤に、交互に石を置いていきます。相手の石を自分の石で挟むと、挟んだ石をすべて自分の色にひっくり返せます。置ける場所が無ければ自動でパスになり、相手の番が続きます。

                    両者とも置ける場所が無くなるか盤が埋まると対戦終了です。盤上の石が多いほうの勝ちです。
                    """)
            case .colorBattle:
                String(localized: """
                    毎回戦、切り札の色が決まりますが、両者が札を出し終えるまで何色かは分かりません。切り札の色の札は、数字に関係なく切り札でない札に勝ちます。どちらも切り札か、どちらも切り札でないときは、数字の大きいほうが勝ちです。

                    先に出す人は相手の出方を知らずに出すので、同じ数字なら先に出した人の勝ちです。先に出す人は 1 回戦ごとに交代します。

                    勝った人は、2 枚の数字の合計を得点します。手札を出しきったときに、得点の多いほうが勝ちです。
                    """)
            case .daifugo:
                String(localized: """
                    3人以上のグループで遊びます。前の人と同じ枚数で、より強い数字を出していきます(3が一番弱く、2が一番強い)。出せる/出したくない番はパスできます。

                    5を出すと次の人の番を飛ばし、8を出すとその場で場が流れて自分がまた先に出せます。Jを出すとその場だけ強さが逆転します。7を出すと手札を1枚好きな相手に渡せ、10を出すと手札を1枚捨てられます。同じ数字を4枚以上出すと「革命」で強さが逆転し、次の革命が起きるまで続きます。クイーン(Q)を出すと数字をひとつ宣言でき、自分以外の全員がその数字の札を持っていれば捨てさせられます(通称「Qバンバー」)。

                    早く手札を出し切った順に「大富豪・富豪・平民・貧民・大貧民」になります。
                    """)
            case .indianPoker:
                String(localized: """
                    自分のカードは見えません。見えるのは相手のカードだけです。相手の様子から自分のカードの強さを読んで、勝負するか降りるかを決めます。

                    強さは A が一番強く、2 が一番弱い順です。両方が「勝負する」を選ぶと見せ合い、強いほうが賭けた分をもらいます。降りた人はその時点で負けです。
                    """)
            case .doubt:
                String(localized: """
                    順番に、場が決めた数字を宣言しながら札を伏せて出していきます。数字は3から順に上がっていき、持っていなければ嘘をつくしかありません。

                    怪しいと思ったら「ダウト」。嘘だったら出した人が、本当だったら宣言した人が、その札を引き取ります。先に手札を出し切った人の勝ちで、負けた人のCHIPを総取りします。最後の1枚は必ず公開されるので、嘘で上がることはできません。
                    """)
            case .blackjack:
                String(localized: """
                    参加者どうしで勝負します。21に近いほうが勝ちで、21を超えたら負け(バースト)です。絵札は10、Aは11か1の都合のよいほうで数えます。

                    操作は HIT(もう1枚引く)と STAND(そこで止める)だけ。全員が止めるかバーストしたら決着で、21を超えなかった人のうち一番大きい人が、みんなの賭けたCHIPを総取りします。同じ点数で並んだら山分け、全員バーストなら増減なしです。
                    """)
            case .chinchiro:
                String(localized: """
                    3個のサイコロを1回だけ振ります。STOPを押すと3個とも同時に止まります。

                    役の強さは、ピンゾロ(1-1-1)が一番強く、次にゾロ目、シゴロ(4-5-6)、目(2個そろって残りが目になる)、目無し、ヒフミ(1-2-3)が一番弱い順です。全員が振り終えると、一番強い役を出した人が全員の賭けを総取りします。同じ強さで並んだら山分けです。
                    """)
            case .bust:
                String(localized: """
                    倍率は1.00倍から始まり、0.01倍ずつ上がっていきます。好きなタイミングでSTOPできます。STOPするまで他の人の状況は見えず、自分がSTOPした瞬間にみんなの状況が公開されます。

                    倍率が上がるほどCRASHしやすくなります。CRASHが起きると、まだSTOPしていない人は全員まとめて脱落します。

                    誰もCRASHしなかったときは、一番高い倍率でSTOPした人が「自分の賭け金×倍率」(ただし参加者の賭け金の合計が上限)を受け取り、残りは他の参加者に払い戻されます。CRASHが起きたときは、脱落した人の賭け金を、生き残った人たちで倍率の低い人ほど多くなるように分け合います。誰もSTOPしないままCRASHしたときは、全員の賭け金がそのまま戻ります。
                    """)
            case .slingo:
                String(localized: """
                    5×5のカードに1〜50の数字が25個ずつ並びます(カードは一人ひとり違い、他の人のカードも常に見えます)。ターン制で、自分の番が来たらSPINします。出た数字は、それを持っている全員のカードで自動的に開きます。

                    スロットには数字のほかに「？」も混ざっています。「？」はWILDかハズレのどちらかで、どちらが何枚あるかは最後まで分かりません。WILDだった場合は、スピンした本人だけが自分のカードの未開放マスを1つ選んで開けられます。

                    縦・横・斜めのどれか1列(5マス)を開けた人がスリンゴです。最初にスリンゴした人が参加者の賭け金の合計を総取りします。同じSPINの結果で複数人が同時に完成したときは、その人たちで山分けします。
                    """)
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
        case .bust: .bust
        case .slingo: .slingo
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
        case .bust(let state): state.gameID
        case .slingo(let state): state.gameID
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
        case .bust(let state): state.isFinished
        case .slingo(let state): state.isFinished
        }
    }

    /// 募集した人. 募集の段階がある遊びだけ持つ.
    var hostID: UserID? {
        switch self {
        case .othello, .colorBattle: nil
        case .daifugo(let state): state.hostID
        case .indianPoker(let state): state.hostID
        case .doubt(let state): state.hostID
        case .blackjack(let state): state.hostID
        case .chinchiro(let state): state.hostID
        case .bust(let state): state.hostID
        case .slingo(let state): state.hostID
        }
    }

    /// この対戦に関わっている人.
    var playerIDs: [UserID] {
        switch self {
        case .othello(let state):
            return [state.blackPlayerID, state.whitePlayerID]
        case .colorBattle(let state):
            return [state.firstPlayerID, state.secondPlayerID]
        case .daifugo(let state):
            switch state.phase {
            case .lobby(let lobby): return lobby.joinedPlayerIDs
            case .round(let round): return round.seating
            }
        case .indianPoker(let state):
            return state.playerIDs
        case .doubt(let state):
            return state.playerIDs
        case .blackjack(let state):
            return state.playerIDs
        case .chinchiro(let state):
            return state.playerIDs
        case .bust(let state):
            return state.playerIDs
        case .slingo(let state):
            return state.playerIDs
        }
    }

    /// 取り消された対戦か.
    var isCancelled: Bool {
        switch self {
        case .othello(let state): state.isCancelled == true
        case .colorBattle(let state): state.isCancelled == true
        case .daifugo(let state): state.isCancelled == true
        case .indianPoker(let state): state.isCancelled == true
        case .doubt(let state): state.isCancelled == true
        case .blackjack(let state): state.isCancelled == true
        case .chinchiro(let state): state.isCancelled == true
        case .bust(let state): state.isCancelled == true
        case .slingo(let state): state.isCancelled == true
        }
    }

    /// まだ始まっていない(参加者を募っている)段階か.
    var isWaitingForPlayers: Bool {
        switch self {
        case .othello, .colorBattle:
            // この 2 つは募集の段階が無く, 始めた時点で対戦が始まる.
            return false
        case .daifugo(let state):
            if case .lobby = state.phase { return true }
            return false
        case .indianPoker(let state): return state.lobby != nil
        case .doubt(let state): return state.lobby != nil
        case .blackjack(let state): return state.lobby != nil
        case .chinchiro(let state): return state.lobby != nil
        case .bust(let state): return state.lobby != nil
        case .slingo(let state): return state.lobby != nil
        }
    }

    /// いまこの人がこの対戦を取り消せるか.
    ///
    /// CHIP を賭ける遊びは**まだ始まっていない(募集中の)ときだけ**, 募集した人が
    /// 取り消せる. 始まったあとにも取り消せると, 負けそうな人が賭けを無かったことに
    /// できてしまうため.
    ///
    /// CHIP を使わない遊び(オセロ・色勝負・大富豪の募集)は賭けが無いので,
    /// オセロと色勝負は参加者なら途中でもやめられる.
    ///
    /// - Parameter allowsAnyPlayer: 1 対 1 のチャットでは true を渡す.
    ///   相手が作った募集も取りやめられるようにするため(相手が戻ってこないと
    ///   いつまでも次を始められない). グループでは募集した人だけが取り消せる.
    func canCancel(by userID: UserID, allowsAnyPlayer: Bool = false) -> Bool {
        guard !isCancelled, !isFinished else { return false }
        switch self {
        case .othello(let state):
            return state.blackPlayerID == userID || state.whitePlayerID == userID
        case .colorBattle(let state):
            return state.isPlayer(userID)
        case .daifugo, .indianPoker, .doubt, .blackjack, .chinchiro, .bust, .slingo:
            guard isWaitingForPlayers else { return false }
            if hostID == userID { return true }
            return allowsAnyPlayer && playerIDs.contains(userID)
        }
    }

    /// 取り消した状態.
    func cancelling() -> GameSnapshot {
        switch self {
        case .othello(var state):
            state.isCancelled = true
            return .othello(state)
        case .colorBattle(var state):
            state.isCancelled = true
            return .colorBattle(state)
        case .daifugo(var state):
            state.isCancelled = true
            return .daifugo(state)
        case .indianPoker(var state):
            state.isCancelled = true
            return .indianPoker(state)
        case .doubt(var state):
            state.isCancelled = true
            return .doubt(state)
        case .blackjack(var state):
            state.isCancelled = true
            return .blackjack(state)
        case .chinchiro(var state):
            state.isCancelled = true
            return .chinchiro(state)
        case .bust(var state):
            state.isCancelled = true
            return .bust(state)
        case .slingo(var state):
            state.isCancelled = true
            return .slingo(state)
        }
    }

    /// 募集から抜けた状態. 抜けられない場面(募集中でない・募集した人本人)なら nil.
    ///
    /// 募集した人は抜けるのではなく, 募集ごと取り消す(`cancelling`).
    func leavingLobby(by userID: UserID) -> GameSnapshot? {
        guard isWaitingForPlayers, !isCancelled else { return nil }
        switch self {
        case .othello, .colorBattle:
            return nil
        case .daifugo(var state):
            guard case .lobby(var lobby) = state.phase,
                  state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID)
            else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .daifugo(state)
        case .indianPoker(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .indianPoker(state)
        case .doubt(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .doubt(state)
        case .blackjack(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .blackjack(state)
        case .chinchiro(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .chinchiro(state)
        case .bust(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .bust(state)
        case .slingo(var state):
            guard var lobby = state.lobby, state.hostID != userID,
                  lobby.joinedPlayerIDs.contains(userID) else { return nil }
            lobby.joinedPlayerIDs.removeAll { $0 == userID }
            state.phase = .lobby(lobby)
            return .slingo(state)
        }
    }

    /// 決着した対戦の CHIP 増減. CHIP を使わない / まだ決着していないなら空.
    ///
    /// 各自の端末は, ここから**自分のぶんだけ**を取り出して自分の残高に反映する
    /// (他人の残高は書き換えられない仕組みのため).
    var chipDeltas: [UserID: Int] {
        // 取り消した対戦では CHIP を動かさない(賭ける前に取り消しているため).
        guard !isCancelled else { return [:] }
        switch self {
        case .othello, .colorBattle, .daifugo: return [:]
        case .indianPoker(let state): return state.chipDeltas
        case .doubt(let state): return state.chipDeltas
        case .blackjack(let state): return state.chipDeltas
        case .chinchiro(let state): return state.chipDeltas
        case .bust(let state): return state.chipDeltas
        case .slingo(let state): return state.chipDeltas
        }
    }

    /// チャット一覧や通知に出す 1 行.
    var previewText: String {
        if isCancelled { return String(localized: "\(kind.title)(取り消し)") }
        return isFinished
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

    var bust: BustSnapshot? {
        if case .bust(let state) = self { return state }
        return nil
    }

    var slingo: SlingoSnapshot? {
        if case .slingo(let state) = self { return state }
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
        case bust
        case slingo
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
            if let state = try? container.decode(BustSnapshot.self, forKey: .bust) {
                self = .bust(state)
                return
            }
            if let state = try? container.decode(SlingoSnapshot.self, forKey: .slingo) {
                self = .slingo(state)
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
        case .bust(let state): try container.encode(state, forKey: .bust)
        case .slingo(let state): try container.encode(state, forKey: .slingo)
        }
    }
}
