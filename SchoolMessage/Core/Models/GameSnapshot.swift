import Foundation

/// チャットに付随する対戦の 1 手ぶんの記録.
///
/// ## メッセージとして送る理由
/// 対戦の状態を CloudKit の独自レコードで持つ案もあったが, Public Database では
/// **レコードを更新できるのは作成者だけ**なので, 1 つの盤面レコードを両者が
/// 交互に書き換えることができない.
///
/// そこで「1 手 = 1 メッセージ」とし, その時点の盤面をまるごと載せる.
/// - 既存のメッセージ同期(プッシュ・定期取得)がそのまま使える
/// - 会話鍵で暗号化されるので, 対戦内容も第三者には読めない
/// - CloudKit のスキーマを変えずに済む
/// - 最新の 1 通が現在の盤面なので, 復元も単純
///
/// 盤面は毎回まるごと送る. 差分(置いた位置だけ)にすると, 途中の 1 通を
/// 取りこぼしただけで以降ずっと食い違うため, 状態そのものを送るほうが堅い.
struct GameSnapshot: Hashable, Sendable, Codable {

    /// 対戦の種類. 将来ほかの遊びを足せるようにしておく.
    enum Kind: String, Hashable, Sendable, Codable {
        case othello
    }

    var kind: Kind
    /// 対戦の識別子. 同じチャットで何回でも遊べるよう, 対戦ごとに変える.
    var gameID: String
    /// 盤面(64 文字).
    var board: String
    /// 次の手番.
    var turn: OthelloDisc
    /// 直前に置かれたマス.
    var lastMove: Int?
    /// 黒を持っている人.
    var blackPlayerID: UserID
    /// 白を持っている人.
    var whitePlayerID: UserID
    /// 決着したか.
    var isFinished: Bool

    /// 盤面を組み立て直す.
    var othelloBoard: OthelloBoard? {
        OthelloBoard(encoded: board, turn: turn, lastMove: lastMove)
    }

    /// この人が持っている色.
    func disc(for userID: UserID) -> OthelloDisc? {
        if userID == blackPlayerID { return .black }
        if userID == whitePlayerID { return .white }
        return nil
    }

    /// この人の手番か.
    func isTurn(of userID: UserID) -> Bool {
        !isFinished && disc(for: userID) == turn
    }

    /// 新しい対戦を始める.
    static func newOthello(black: UserID, white: UserID) -> GameSnapshot {
        let board = OthelloBoard.initial()
        return GameSnapshot(
            kind: .othello,
            gameID: UUID().uuidString,
            board: board.encoded,
            turn: board.turn,
            lastMove: nil,
            blackPlayerID: black,
            whitePlayerID: white,
            isFinished: false
        )
    }

    /// 石を置いた次の状態を返す. 置けないマスなら `nil`.
    func placing(at index: Int) -> GameSnapshot? {
        guard !isFinished, let board = othelloBoard, let next = board.placing(at: index) else { return nil }
        var updated = self
        updated.board = next.encoded
        updated.turn = next.turn
        updated.lastMove = next.lastMove
        updated.isFinished = next.isFinished
        return updated
    }

    /// チャット一覧や通知に出す 1 行.
    var previewText: String {
        isFinished
            ? String(localized: "オセロ(対戦終了)")
            : String(localized: "オセロ")
    }
}
