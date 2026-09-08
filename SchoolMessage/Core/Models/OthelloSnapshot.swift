import Foundation

/// オセロの状態.
struct OthelloSnapshot: Hashable, Sendable, Codable {

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
    static func new(black: UserID, white: UserID) -> OthelloSnapshot {
        let board = OthelloBoard.initial()
        return OthelloSnapshot(
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
    func placing(at index: Int) -> OthelloSnapshot? {
        guard !isFinished, let board = othelloBoard, let next = board.placing(at: index) else { return nil }
        var updated = self
        updated.board = next.encoded
        updated.turn = next.turn
        updated.lastMove = next.lastMove
        updated.isFinished = next.isFinished
        return updated
    }
}
