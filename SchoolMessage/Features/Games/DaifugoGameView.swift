import SwiftUI

/// 大富豪(グループ)の対戦画面.
///
/// オセロ・色勝負と違い 3 人以上で遊ぶため, 先に「参加者を募る(ロビー)」を
/// 経てから対戦が始まる. 1 手 = 1 メッセージという仕組み自体は他の対戦と同じ.
struct DaifugoGameView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let conversationID: ConversationID

    @State private var isSending = false
    /// 復号済みの自分の手札. 他のプレイヤーの手札は復号する手立てが無い.
    @State private var myHand: [PlayingCard] = []
    @State private var selectedCards: Set<PlayingCard> = []
    /// 7わたしで渡す札, または 10捨てで捨てる札.
    @State private var extraCard: PlayingCard?
    /// 7わたしで渡す相手.
    @State private var giveRecipientID: UserID?
    /// Qバンバー(クイーンを出したとき)で宣言する数字.
    @State private var declaredRank: PlayingRank?

    private var store: ChatStore { environment.store }

    private var snapshot: DaifugoSnapshot? {
        store.activeGame(kind: .daifugo, in: conversationID)?.daifugo
    }

    private var currentRound: DaifugoSnapshot.Round? {
        if case .round(let round) = snapshot?.phase { return round }
        return nil
    }

    private var me: UserID? { store.currentUserID }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    switch snapshot.phase {
                    case .lobby(let lobby):
                        lobbyView(snapshot, lobby: lobby)
                    case .round(let round):
                        if let me, round.seating.contains(me) {
                            roundView(round, me: me)
                        } else {
                            ContentUnavailableView(
                                String(localized: "参加していません"),
                                systemImage: "suit.spade.fill",
                                description: Text("この対戦が始まる前に参加していなかったため、見ることはできますが参加できません。")
                            )
                        }
                    }
                } else {
                    startPrompt
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.chatBackground)
            .navigationTitle("大富豪")
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
        // 手札は暗号化されているため, 対戦の状態が変わるたびに自分の分だけ
        // 復号し直す(色勝負と同じ考え方).
        .task(id: snapshot) {
            guard currentRound != nil else { return }
            myHand = Self.sorted(await store.decryptedDaifugoHand(in: conversationID))
        }
        .onChange(of: snapshot) { _, _ in
            selectedCards = []
            extraCard = nil
            giveRecipientID = nil
            declaredRank = nil
        }
    }

    // MARK: - 対戦が無いとき

    private var startPrompt: some View {
        ContentUnavailableView {
            Label(String(localized: "大富豪をする"), systemImage: "suit.spade.fill")
        } description: {
            Text(Self.rulesText)
                .multilineTextAlignment(.leading)
        } actions: {
            Button(String(localized: "参加者を募る")) {
                Task { await store.createDaifugoLobby(in: conversationID) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private static let rulesText = String(localized: """
        3人以上のグループで遊びます。前の人と同じ枚数で、より強い数字を出していきます(3が一番弱く、2が一番強い)。出せる/出したくない番はパスできます。

        5を出すと次の人の番を飛ばし、8を出すとその場で場が流れて自分がまた先に出せます。Jを出すとその場だけ強さが逆転します。7を出すと手札を1枚好きな相手に渡せ、10を出すと手札を1枚捨てられます。同じ数字を4枚以上出すと「革命」で強さが逆転し、次の革命が起きるまで続きます。クイーン(Q)を出すと数字をひとつ宣言でき、自分以外の全員がその数字の札を持っていれば捨てさせられます(通称「Qバンバー」)。

        早く手札を出し切った順に「大富豪・富豪・平民・貧民・大貧民」になります。
        """)

    // MARK: - ロビー

    private func lobbyView(_ snapshot: DaifugoSnapshot, lobby: DaifugoSnapshot.Lobby) -> some View {
        let hasJoined = me.map(lobby.joinedPlayerIDs.contains) ?? false
        let isHost = me == snapshot.hostID

        return VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
            Text("参加者(\(lobby.joinedPlayerIDs.count)人)")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lobby.joinedPlayerIDs, id: \.self) { playerID in
                        HStack {
                            Text(store.displayName(for: playerID))
                            if playerID == snapshot.hostID {
                                Text("(募集した人)")
                                    .font(.caption)
                                    .foregroundStyle(Palette.subdued)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if lobby.joinedPlayerIDs.count < DaifugoSnapshot.Lobby.minimumPlayers {
                Text("あと \(DaifugoSnapshot.Lobby.minimumPlayers - lobby.joinedPlayerIDs.count) 人以上参加すると始められます")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            }

            HStack(spacing: AppConstants.Layout.standardSpacing) {
                if !hasJoined {
                    Button(String(localized: "参加する")) {
                        Task {
                            isSending = true
                            await store.joinDaifugoLobby(in: conversationID)
                            isSending = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending)
                } else if !isHost {
                    Button(String(localized: "参加を取りやめる"), role: .destructive) {
                        Task {
                            isSending = true
                            await store.leaveGameLobby(kind: .daifugo, in: conversationID)
                            isSending = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSending)
                }

                if isHost {
                    Button(String(localized: "対戦を始める")) {
                        Task {
                            isSending = true
                            await store.startDaifugoRound(in: conversationID)
                            isSending = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || lobby.joinedPlayerIDs.count < DaifugoSnapshot.Lobby.minimumPlayers)
                }

                if store.canCancelGame(kind: .daifugo, in: conversationID) {
                    Button(String(localized: "募集を取り消す"), role: .destructive) {
                        Task {
                            isSending = true
                            await store.cancelGame(kind: .daifugo, in: conversationID)
                            isSending = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSending)
                }
            }
        }
        .padding(AppConstants.Layout.standardSpacing)
    }

    // MARK: - 対戦中

    private func roundView(_ round: DaifugoSnapshot.Round, me: UserID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppConstants.Layout.standardSpacing) {
                if round.isFinished {
                    resultSection(round)
                } else {
                    statusSection(round, me: me)
                    fieldSection(round)
                }

                Divider()
                othersSection(round, me: me)
                Divider()
                myHandSection(round, me: me)
            }
            .padding(AppConstants.Layout.standardSpacing)
        }
    }

    private func statusSection(_ round: DaifugoSnapshot.Round, me: UserID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if round.isRevolution {
                    tagLabel(String(localized: "革命中"), systemImage: "arrow.triangle.2.circlepath")
                }
                if round.isTrickReversed {
                    tagLabel(String(localized: "Jバック"), systemImage: "arrow.up.arrow.down")
                }
            }
            Text(round.isTurn(of: me)
                 ? String(localized: "あなたの番です")
                 : String(localized: "\(store.displayName(for: round.currentPlayerID)) の番です"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(round.isTurn(of: me) ? Color.accentColor : Palette.subdued)
        }
    }

    private func tagLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.incomingBubble, in: Capsule())
    }

    @ViewBuilder
    private func fieldSection(_ round: DaifugoSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(round.fieldCards.isEmpty ? String(localized: "場が流れています。自由に出せます") : String(localized: "場に出ている札"))
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            if !round.fieldCards.isEmpty {
                playingCardRow(round.fieldCards, size: .small)
            }
        }
    }

    private func othersSection(_ round: DaifugoSnapshot.Round, me: UserID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("他のプレイヤー")
                .font(.caption)
                .foregroundStyle(Palette.subdued)
            ForEach(round.seating.filter { $0 != me }, id: \.self) { playerID in
                HStack(spacing: 6) {
                    Text(store.displayName(for: playerID))
                    if round.currentPlayerID == playerID, !round.isFinished {
                        Image(systemName: "hand.point.right.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if let rankTitle = round.rankTitle(for: playerID) {
                        Text(rankTitle)
                            .font(.caption.weight(.semibold))
                    } else {
                        Text("残り\(round.handCount(for: playerID))枚")
                            .font(.caption)
                            .foregroundStyle(Palette.subdued)
                    }
                }
            }
        }
    }

    private func resultSection(_ round: DaifugoSnapshot.Round) -> some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.compactSpacing) {
            Text("対戦終了")
                .font(.title3.weight(.semibold))
            ForEach(Array(round.finishedOrder.enumerated()), id: \.offset) { index, playerID in
                HStack {
                    Text("\(index + 1)位")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, alignment: .leading)
                    Text(store.displayName(for: playerID))
                    Spacer()
                    Text(DaifugoSnapshot.Round.rankTitle(place: index + 1, totalPlayers: round.seating.count))
                        .foregroundStyle(Palette.subdued)
                }
            }
            Button(String(localized: "もう一局")) {
                Task { await store.createDaifugoLobby(in: conversationID) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 手札

    private func myHandSection(_ round: DaifugoSnapshot.Round, me: UserID) -> some View {
        let canAct = round.isTurn(of: me) && !isSending && !round.isFinished
        return VStack(alignment: .leading, spacing: 6) {
            Text("あなたの手札")
                .font(.caption)
                .foregroundStyle(Palette.subdued)

            if myHand.isEmpty {
                Text("なし")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
            } else {
                // 横スクロールにせず, 手札の枚数に応じてカード幅を縮めて
                // 1 画面に収める(枚数が多い対戦でもスクロールなしで見渡せるように).
                GeometryReader { geometry in
                    let width = Self.handCardWidth(count: myHand.count, availableWidth: geometry.size.width)
                    HStack(spacing: Self.handCardSpacing) {
                        ForEach(myHand) { card in
                            let isSelectable = isCardSelectable(card, in: round)
                            Button {
                                toggleSelection(card)
                            } label: {
                                PlayingCardView(card: card, size: .fit(width: width))
                                    .overlay {
                                        if selectedCards.contains(card) {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                        }
                                    }
                                    // 選べるものは実態のまま, 選べない
                                    // (組み合わせとして成立しない・場に勝てない)ものは半透明にする.
                                    .opacity(isSelectable ? 1 : 0.35)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canAct || !isSelectable)
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                }
                .frame(height: PlayingCardView.Size.fit(width: Self.handCardMaxWidth).height)
                .opacity(canAct ? 1 : 0.55)
            }

            if canAct {
                actionControls(round, me: me)
            }
        }
    }

    /// 手札を 1 画面に収めるためのカード幅. 枚数が多いほど狭くする
    /// (読みやすさを保つため下限は設ける).
    private static func handCardWidth(count: Int, availableWidth: CGFloat) -> CGFloat {
        guard count > 0, availableWidth > 0 else { return handCardMaxWidth }
        let totalSpacing = handCardSpacing * CGFloat(count - 1)
        let widthPerCard = (availableWidth - totalSpacing) / CGFloat(count)
        return min(handCardMaxWidth, max(handCardMinWidth, widthPerCard))
    }

    private static let handCardMaxWidth: CGFloat = 58
    private static let handCardMinWidth: CGFloat = 26
    private static let handCardSpacing: CGFloat = 6

    /// 標準的な並び(3が一番左, 2が一番右)に自動で並べ替える.
    /// 革命中でも, 手札の並び自体は見慣れた順のまま変えない
    /// (強さの逆転は場との比較だけに反映する).
    private static func sorted(_ cards: [PlayingCard]) -> [PlayingCard] {
        cards.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank.rawValue < rhs.rank.rawValue }
            let suits = PlayingSuit.allCases
            return (suits.firstIndex(of: lhs.suit) ?? 0) < (suits.firstIndex(of: rhs.suit) ?? 0)
        }
    }

    /// この札(が属する数字)を選べるか.
    ///
    /// 既に選んでいる札は(選択を外せるように)常に選べる扱いにする. まだ何も
    /// 選んでいなければ, 場に対して出せる見込みがあるかだけを見る. 既に
    /// 何か選んでいれば, 同じ数字の札しか(大富豪では複数枚出すとき同じ数字
    /// でなければならないため)追加で選べない.
    private func isCardSelectable(_ card: PlayingCard, in round: DaifugoSnapshot.Round) -> Bool {
        if selectedCards.contains(card) { return true }
        guard canEverBeat(rank: card.rank, in: round) else { return false }
        return selectedRanks.isEmpty || selectedRanks.contains(card.rank)
    }

    /// 手元にあるこの数字の枚数で, 今の場に勝てる見込みがあるか
    /// (場が空なら, 何を出しても自由に出せるので常に true).
    private func canEverBeat(rank: PlayingRank, in round: DaifugoSnapshot.Round) -> Bool {
        guard let fieldRank = round.fieldCards.first?.rank else { return true }
        let reversed = round.isRevolution != round.isTrickReversed
        guard DaifugoSnapshot.Round.isStronger(rank, than: fieldRank, reversed: reversed) else { return false }
        let countInHand = myHand.filter { $0.rank == rank }.count
        return countInHand >= round.fieldCards.count
    }

    @ViewBuilder
    private func actionControls(_ round: DaifugoSnapshot.Round, me: UserID) -> some View {
        if needsExtraCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedSpecialRank == .seven
                     ? String(localized: "渡す札を選んでください")
                     : String(localized: "捨てる札を選んでください"))
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(remainingHandAfterSelection) { card in
                            Button {
                                extraCard = card
                            } label: {
                                PlayingCardView(card: card, size: .small)
                                    .overlay {
                                        if extraCard == card {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if selectedSpecialRank == .seven {
                    Picker(String(localized: "渡す相手"), selection: $giveRecipientID) {
                        Text(String(localized: "渡す相手を選ぶ")).tag(UserID?.none)
                        ForEach(round.seating.filter { $0 != me && !round.finishedOrder.contains($0) }, id: \.self) { playerID in
                            Text(store.displayName(for: playerID)).tag(UserID?.some(playerID))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }

        if needsDeclaredRank {
            VStack(alignment: .leading, spacing: 6) {
                Text("Qバンバー: 宣言する数字を選んでください")
                    .font(.caption)
                    .foregroundStyle(Palette.subdued)
                Picker(String(localized: "宣言する数字"), selection: $declaredRank) {
                    Text(String(localized: "数字を選ぶ")).tag(PlayingRank?.none)
                    ForEach(PlayingRank.allCases, id: \.self) { rank in
                        Text(rank.label).tag(PlayingRank?.some(rank))
                    }
                }
                .pickerStyle(.menu)
                Text("あなた以外の全員が, 持っていればその数字の札を捨てさせられます")
                    .font(.caption2)
                    .foregroundStyle(Palette.subdued)
            }
        }

        HStack(spacing: AppConstants.Layout.standardSpacing) {
            Button(String(localized: "出す")) {
                Task { await playSelected() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmitPlay)

            if round.fieldOwnerID != nil {
                Button(String(localized: "パス")) {
                    Task { await pass() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func playingCardRow(_ cards: [PlayingCard], size: PlayingCardView.Size) -> some View {
        HStack(spacing: 8) {
            ForEach(cards) { card in
                PlayingCardView(card: card, size: size)
            }
        }
    }

    // MARK: - 選択の状態

    private var selectedRanks: Set<PlayingRank> { Set(selectedCards.map(\.rank)) }

    /// 選んだ札が単一の数字だけのとき, その数字.
    private var selectedSpecialRank: PlayingRank? {
        guard selectedRanks.count == 1 else { return nil }
        return selectedRanks.first
    }

    private var remainingHandAfterSelection: [PlayingCard] {
        myHand.filter { !selectedCards.contains($0) }
    }

    /// 7わたし・10捨てで, 追加の 1 枚を選ぶ必要があるか.
    private var needsExtraCard: Bool {
        guard let rank = selectedSpecialRank, rank == .seven || rank == .ten else { return false }
        return !remainingHandAfterSelection.isEmpty
    }

    /// Qバンバー: クイーンを出すときは, 宣言する数字を選ぶ必要がある.
    /// (これで上がる場合でも, 他の全員に影響する効果なので選ばせる).
    private var needsDeclaredRank: Bool {
        selectedSpecialRank == .queen
    }

    private var canSubmitPlay: Bool {
        guard let currentRound, !selectedCards.isEmpty else { return false }
        guard currentRound.canPlay(Array(selectedCards)) else { return false }
        if needsExtraCard {
            guard extraCard != nil else { return false }
            if selectedSpecialRank == .seven {
                guard giveRecipientID != nil else { return false }
            }
        }
        if needsDeclaredRank {
            guard declaredRank != nil else { return false }
        }
        return true
    }

    private func toggleSelection(_ card: PlayingCard) {
        if selectedCards.contains(card) {
            selectedCards.remove(card)
        } else {
            selectedCards.insert(card)
        }
        if !needsExtraCard {
            extraCard = nil
            giveRecipientID = nil
        }
        if !needsDeclaredRank {
            declaredRank = nil
        }
    }

    // MARK: - 動作

    private func playSelected() async {
        isSending = true
        defer { isSending = false }
        await store.playDaifugoCards(
            Array(selectedCards),
            extraCard: extraCard,
            giveTo: giveRecipientID,
            declaredRank: declaredRank,
            in: conversationID
        )
        selectedCards = []
        extraCard = nil
        giveRecipientID = nil
        declaredRank = nil
    }

    private func pass() async {
        isSending = true
        defer { isSending = false }
        await store.passDaifugo(in: conversationID)
    }
}

/// トランプ 1 枚の見た目.
struct PlayingCardView: View {

    enum Size {
        case small
        case large
        /// 手札を 1 画面に収めるため, 幅を自由な値に縮められるようにしたもの.
        case fit(width: CGFloat)

        var width: CGFloat {
            switch self {
            case .small: 40
            case .large: 58
            case .fit(let width): width
            }
        }
        /// 「大」の縦横比(80/58)に合わせる.
        var height: CGFloat {
            switch self {
            case .small: 56
            case .large: 80
            case .fit(let width): width * (80.0 / 58.0)
            }
        }
        var rankFontSize: CGFloat { width * 0.42 }
        var suitFontSize: CGFloat { width * 0.24 }
    }

    let card: PlayingCard
    var size: Size = .large

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: card.suit.symbolName)
                .font(.system(size: size.suitFontSize))
            Text(card.rank.label)
                .font(.system(size: size.rankFontSize, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(card.suit.isRed ? Color.red : Color.primary)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.rank.label) \(card.suit.rawValue)")
    }
}

#Preview {
    DaifugoGameView(conversationID: ConversationID("preview"))
        .environment(AppEnvironment.preview())
}
