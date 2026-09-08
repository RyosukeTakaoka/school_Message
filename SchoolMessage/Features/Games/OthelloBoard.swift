import Foundation

/// オセロの石.
enum OthelloDisc: String, Codable, Sendable, Hashable {
    case black
    case white

    var opponent: OthelloDisc {
        self == .black ? .white : .black
    }

    var label: String {
        self == .black ? String(localized: "黒") : String(localized: "白")
    }
}

/// オセロの盤面と手番.
///
/// ## ルールをここに閉じ込める理由
/// 「置ける場所」「裏返る石」「パス」「終局」の判定は, 画面にも通信にも
/// 依存しない純粋な計算. ここに閉じ込めておけば, 盤面の見た目を変えても
/// 通信の仕組みを変えても, ルールは触らずに済む.
///
/// 盤面は 64 マスの 1 次元配列で持つ. 8×8 の二重配列より添字の計算が単純で,
/// そのまま文字列に直して通信・保存できる.
struct OthelloBoard: Codable, Sendable, Hashable {

    static let size = 8
    static let squareCount = size * size

    /// 各マスの石. `nil` は空きマス.
    private(set) var squares: [OthelloDisc?]

    /// 次に打つ番の色.
    private(set) var turn: OthelloDisc

    /// 直前に置かれたマス(盤面で光らせるのに使う).
    private(set) var lastMove: Int?

    /// 初期配置.
    static func initial() -> OthelloBoard {
        var squares = [OthelloDisc?](repeating: nil, count: squareCount)
        squares[index(row: 3, column: 3)] = .white
        squares[index(row: 3, column: 4)] = .black
        squares[index(row: 4, column: 3)] = .black
        squares[index(row: 4, column: 4)] = .white
        return OthelloBoard(squares: squares, turn: .black, lastMove: nil)
    }

    // MARK: - 座標

    static func index(row: Int, column: Int) -> Int {
        row * size + column
    }

    static func row(of index: Int) -> Int { index / size }
    static func column(of index: Int) -> Int { index % size }

    // MARK: - ルール

    /// 8 方向の進み方(行, 列).
    private static let directions: [(Int, Int)] = [
        (-1, -1), (-1, 0), (-1, 1),
        (0, -1),           (0, 1),
        (1, -1),  (1, 0),  (1, 1)
    ]

    /// そこに `disc` を置いたときに裏返る石の位置.
    /// 空であれば, そこには置けない.
    func flips(at index: Int, for disc: OthelloDisc) -> [Int] {
        guard squares.indices.contains(index), squares[index] == nil else { return [] }

        let startRow = Self.row(of: index)
        let startColumn = Self.column(of: index)
        var result: [Int] = []

        for (deltaRow, deltaColumn) in Self.directions {
            var row = startRow + deltaRow
            var column = startColumn + deltaColumn
            var candidates: [Int] = []

            // 相手の石が続く限り進み, 自分の石で挟めていれば確定する.
            while (0..<Self.size).contains(row), (0..<Self.size).contains(column) {
                let position = Self.index(row: row, column: column)
                guard let occupant = squares[position] else { break }
                if occupant == disc.opponent {
                    candidates.append(position)
                } else {
                    if !candidates.isEmpty { result.append(contentsOf: candidates) }
                    break
                }
                row += deltaRow
                column += deltaColumn
            }
        }
        return result
    }

    /// `disc` が置けるマス.
    func legalMoves(for disc: OthelloDisc) -> [Int] {
        (0..<Self.squareCount).filter { !flips(at: $0, for: disc).isEmpty }
    }

    /// 手番の色が置けるマス.
    var legalMoves: [Int] { legalMoves(for: turn) }

    /// 石を置いた結果の盤面を返す.
    ///
    /// 置けないマスなら `nil`. 置けた場合は手番を進め, 相手が置けなければ
    /// パスして手番を戻す(オセロの規則どおり).
    func placing(at index: Int) -> OthelloBoard? {
        let flipped = flips(at: index, for: turn)
        guard !flipped.isEmpty else { return nil }

        var next = self
        next.squares[index] = turn
        for position in flipped {
            next.squares[position] = turn
        }
        next.lastMove = index

        // 相手が置けなければパス. 両者置けなければそのまま終局.
        let opponent = turn.opponent
        if !next.legalMoves(for: opponent).isEmpty {
            next.turn = opponent
        }
        return next
    }

    /// 決着したか(両者とも置けない).
    var isFinished: Bool {
        legalMoves(for: .black).isEmpty && legalMoves(for: .white).isEmpty
    }

    /// 直前の手で相手がパスしたか(手番が変わらなかった).
    func didPass(comparedTo previous: OthelloBoard) -> Bool {
        previous.turn == turn && previous.lastMove != lastMove
    }

    func count(of disc: OthelloDisc) -> Int {
        squares.reduce(into: 0) { total, square in
            if square == disc { total += 1 }
        }
    }

    /// 勝者. 引き分けなら `nil`.
    var winner: OthelloDisc? {
        let black = count(of: .black)
        let white = count(of: .white)
        if black == white { return nil }
        return black > white ? .black : .white
    }

    // MARK: - 文字列との相互変換

    /// 盤面を 64 文字に直す(`b` 黒 / `w` 白 / `.` 空き).
    ///
    /// 配列をそのまま JSON にすると `null` が並んで無駄に大きくなるため,
    /// 通信・保存にはこの形を使う.
    var encoded: String {
        let characters: [Character] = squares.map { square in
            switch square {
            case .black: "b"
            case .white: "w"
            case nil: "."
            }
        }
        return String(characters)
    }

    init?(encoded: String, turn: OthelloDisc, lastMove: Int?) {
        guard encoded.count == Self.squareCount else { return nil }
        self.squares = encoded.map { character -> OthelloDisc? in
            switch character {
            case "b": .black
            case "w": .white
            default: nil
            }
        }
        self.turn = turn
        self.lastMove = lastMove
    }

    private init(squares: [OthelloDisc?], turn: OthelloDisc, lastMove: Int?) {
        self.squares = squares
        self.turn = turn
        self.lastMove = lastMove
    }
}
