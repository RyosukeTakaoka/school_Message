import SwiftUI

/// オセロの対戦画面.
///
/// 盤面はチャットのメッセージとして送り合うので, この画面は
/// 「いまの盤面を描いて, 置いたら 1 手ぶん送る」だけを受け持つ.
/// 相手の手は通常のメッセージ同期で流れてきて, 自動的に反映される.
struct OthelloGameView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let conversationID: ConversationID

    @State private var isSending = false
    /// 直前に「相手がパスになった」ことを一時的に伝えるための文言.
    @State private var passNoticeText: String?

    private var store: ChatStore { environment.store }

    /// いまの盤面. メッセージ側が更新されると自動で追従する.
    private var snapshot: OthelloSnapshot? {
        store.currentGame(kind: .othello, in: conversationID)?.othello
    }

    private var myDisc: OthelloDisc? {
        guard let snapshot, let me = store.currentUserID else { return nil }
        return snapshot.disc(for: me)
    }

    private var isMyTurn: Bool {
        guard let snapshot, let me = store.currentUserID else { return false }
        return snapshot.isTurn(of: me)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppConstants.Layout.standardSpacing) {
                if let snapshot, let board = snapshot.othelloBoard {
                    scoreBar(board)
                    statusLine(snapshot, board: board)
                    if let passNoticeText {
                        Text(passNoticeText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Palette.incomingBubble, in: Capsule())
                            .transition(.opacity)
                    }
                    boardView(board)
                    Spacer(minLength: 0)
                    footer(snapshot)
                } else {
                    startPrompt
                }
            }
            .padding(AppConstants.Layout.standardSpacing)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.chatBackground)
            .navigationTitle("オセロ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                if let error = store.banner {
                    ErrorBannerView(error: error) { store.setBanner(nil) }
                }
            }
        }
        // オセロは「置ける場所が無い側は自動でパスになる」ルールがあり,
        // 盤面の計算としては既に正しく処理されていた(`OthelloBoard.placing`)が,
        // 画面には一切出ていなかったため, 急に自分の番が 2 回続くように見えて
        // 分かりにくかった. パスが起きた瞬間だけ, 誰がパスになったかを知らせる.
        .onChange(of: snapshot) { oldValue, newValue in
            guard let oldBoard = oldValue?.othelloBoard, let newBoard = newValue?.othelloBoard,
                  newBoard.didPass(comparedTo: oldBoard)
            else { return }
            showPassNotice(for: oldBoard.turn.opponent)
        }
    }

    private func showPassNotice(for disc: OthelloDisc) {
        withAnimation { passNoticeText = String(localized: "\(disc.label)は置ける場所が無かったため、パスになりました") }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { passNoticeText = nil }
        }
    }

    // MARK: - 対戦が無いとき

    private var startPrompt: some View {
        ContentUnavailableView {
            Label(String(localized: "オセロで対戦する"), systemImage: "circle.righthalf.filled")
        } description: {
            Text("このチャットの相手と 1 対 1 で遊べます。盤面はチャットに保存されるので、アプリを閉じても続きから遊べます。")
        } actions: {
            Button(String(localized: "対戦を始める")) {
                Task { await startGame() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending || opponentID == nil)
        }
    }

    // MARK: - 盤面

    private func scoreBar(_ board: OthelloBoard) -> some View {
        HStack(spacing: AppConstants.Layout.standardSpacing) {
            scoreChip(.black, count: board.count(of: .black))
            scoreChip(.white, count: board.count(of: .white))
        }
    }

    private func scoreChip(_ disc: OthelloDisc, count: Int) -> some View {
        HStack(spacing: 6) {
            discShape(disc)
                .frame(width: 20, height: 20)
            Text("\(disc.label) \(count)")
                .font(.subheadline.weight(.medium))
            if myDisc == disc {
                Text("(自分)")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.incomingBubble, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusLine(_ snapshot: OthelloSnapshot, board: OthelloBoard) -> some View {
        if snapshot.isFinished {
            let winner = board.winner
            Text(resultText(winner: winner))
                .font(.headline)
        } else if isMyTurn {
            Text("あなたの番です（\(snapshot.turn.label)）")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
        } else {
            Text("相手の番です（\(snapshot.turn.label)）")
                .font(.subheadline)
                .foregroundStyle(Palette.subdued)
        }
    }

    private func resultText(winner: OthelloDisc?) -> String {
        guard let winner else { return String(localized: "引き分けです") }
        if let myDisc, myDisc == winner {
            return String(localized: "あなたの勝ちです")
        }
        if myDisc != nil {
            return String(localized: "あなたの負けです")
        }
        return String(localized: "\(winner.label)の勝ちです")
    }

    private func boardView(_ board: OthelloBoard) -> some View {
        let legal = isMyTurn ? Set(board.legalMoves) : []

        return VStack(spacing: 1) {
            ForEach(0..<OthelloBoard.size, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<OthelloBoard.size, id: \.self) { column in
                        let index = OthelloBoard.index(row: row, column: column)
                        square(board, index: index, isLegal: legal.contains(index))
                    }
                }
            }
        }
        .padding(4)
        .background(Palette.boardLine, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
    }

    private func square(_ board: OthelloBoard, index: Int, isLegal: Bool) -> some View {
        Button {
            Task { await place(at: index) }
        } label: {
            ZStack {
                Palette.boardSquare
                if let disc = board.squares[index] {
                    discShape(disc)
                        .padding(3)
                } else if isLegal {
                    // 置けるマスは小さな点で示す. 色だけに頼らない表現にする.
                    Circle()
                        .fill(Color.accentColor.opacity(0.5))
                        .padding(14)
                }
            }
            .overlay {
                if board.lastMove == index {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isLegal || isSending)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(squareLabel(board, index: index, isLegal: isLegal))
    }

    private func squareLabel(_ board: OthelloBoard, index: Int, isLegal: Bool) -> String {
        let row = OthelloBoard.row(of: index) + 1
        let column = OthelloBoard.column(of: index) + 1
        if let disc = board.squares[index] {
            return String(localized: "\(row)行\(column)列 \(disc.label)")
        }
        return isLegal
            ? String(localized: "\(row)行\(column)列 ここに置けます")
            : String(localized: "\(row)行\(column)列 空き")
    }

    private func discShape(_ disc: OthelloDisc) -> some View {
        Circle()
            .fill(disc == .black ? Color.black : Color.white)
            .overlay {
                // 白い石が白背景に埋もれないよう, 縁を描く.
                Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func footer(_ snapshot: OthelloSnapshot) -> some View {
        if snapshot.isFinished {
            Button(String(localized: "もう一局")) {
                Task { await startGame() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
        } else if isSending {
            ProgressView()
        }
    }

    // MARK: - 動作

    private var opponentID: UserID? {
        guard let me = store.currentUserID,
              let conversation = store.conversation(conversationID) else { return nil }
        return conversation.participantIDs.first { $0 != me }
    }

    private func startGame() async {
        guard let me = store.currentUserID, let opponent = opponentID else { return }
        isSending = true
        defer { isSending = false }
        // 先手(黒)は始めた人にする.
        await store.sendGameMove(
            .othello(.new(black: me, white: opponent)),
            in: conversationID
        )
    }

    private func place(at index: Int) async {
        guard isMyTurn, let snapshot, let next = snapshot.placing(at: index) else { return }
        isSending = true
        defer { isSending = false }
        await store.sendGameMove(.othello(next), in: conversationID)
    }
}

#Preview {
    OthelloGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
