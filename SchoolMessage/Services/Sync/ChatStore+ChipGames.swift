import Foundation

/// CHIP を使う 4 つの遊び(インディアンポーカー・ダウト・ブラックジャック・チンチロ)と,
/// その精算.
///
/// 1 手 = 1 メッセージという既存の仕組みはそのまま使う(`sendGameMove`).
/// CHIP の残高だけはメッセージではなく専用のレコードに持つ(`PlayerWallet` 参照).
extension ChatStore {

    // MARK: - 残高

    func refreshWallet() async {
        guard let wallet = try? await backend.fetchMyWallet() else { return }
        myWallet = wallet
    }

    /// いま CHIP を賭けて遊べるか(足りなければ遊べない).
    var canPlayChipGames: Bool {
        guard let myWallet else { return false }
        return !myWallet.isBankrupt()
    }

    var chipBalance: Int { myWallet?.balance ?? 0 }

    /// CHIP を使う対戦を 1 回でも終えたか(ランキングに載る条件).
    var hasPlayedChipGame: Bool {
        !(myWallet?.settledGameIDs.isEmpty ?? true)
    }

    /// 復活のルーレットを回せる状態か.
    var isRevivalDue: Bool {
        myWallet?.isRevivalDue() ?? false
    }

    /// CHIP が足りないときに出す案内.
    var bankruptNotice: String? {
        guard let myWallet, myWallet.isBankrupt() else { return nil }
        if myWallet.isRevivalDue() {
            return String(localized: "CHIPが0です。復活ルーレットを回せます")
        }
        guard let revivalDate = myWallet.revivalDate() else {
            return String(localized: "CHIPが0です")
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return String(localized: "CHIPが0になりました。\(formatter.string(from: revivalDate))に復活ルーレットを回せます")
    }

    /// 復活のルーレットを回して受け取る. 回せる状態でなければ nil.
    ///
    /// 出る額は「0 になった日時」から決まっているので, 回し直しはできない.
    /// 戻り値は当たった額(画面の演出に使う).
    func claimRevivalIfDue() async -> Int? {
        guard let wallet = myWallet, wallet.isRevivalDue() else { return nil }
        let amount = wallet.revivalAmount
        do {
            myWallet = try await backend.claimChipRevival()
            return amount
        } catch {
            banner = AppError.wrap(error)
            return nil
        }
    }

    /// 決着した対戦の CHIP を自分のぶんだけ反映する.
    ///
    /// 他人の残高は書き換えられない(書き込めるのは本人だけ)ので, 各自の端末が
    /// 自分のぶんを反映する. 同じ対戦で二重に増減しないよう, 対戦 ID を
    /// 残高と一緒に記録している(`PlayerWallet.settledGameIDs`).
    @discardableResult
    func settleChipsIfNeeded(for snapshot: GameSnapshot) async -> Int? {
        guard snapshot.isFinished, let me = currentUserID else { return nil }
        guard let delta = snapshot.chipDeltas[me] else { return nil }
        if let myWallet, myWallet.hasSettled(gameID: snapshot.gameID) { return nil }

        do {
            myWallet = try await backend.applyChipDelta(delta, gameID: snapshot.gameID)
            return delta
        } catch {
            banner = AppError.wrap(error)
            return nil
        }
    }

    func fetchChipRanking(limit: Int = 50) async -> [ChipRankingEntry] {
        do {
            let entries = try await backend.fetchChipRanking(limit: limit)
            // 表示名を出すために, まだ持っていないプロフィールをまとめて取る.
            let missing = Set(entries.map(\.ownerID)).subtracting(profilesByID.keys)
            if !missing.isEmpty, let profiles = try? await backend.fetchProfiles(ids: Array(missing)) {
                for profile in profiles { profilesByID[profile.id] = profile }
            }
            return entries
        } catch {
            banner = AppError.wrap(error)
            return []
        }
    }

    // MARK: - 共通の下ごしらえ

    /// ベットできるかを確かめる. 足りない・破産中なら理由をバナーに出して false.
    private func assertCanBet(_ bet: Int, maxBet: Int) -> Bool {
        guard let myWallet else { return false }
        if myWallet.isBankrupt() {
            banner = .underlying(bankruptNotice ?? String(localized: "いまは CHIP を使う遊びができません"))
            return false
        }
        guard ChipRules.isValidBet(bet, maxBet: maxBet, balance: myWallet.balance) else {
            banner = .underlying(String(localized: "その額は賭けられません(持っている CHIP を確認してください)"))
            return false
        }
        return true
    }

    /// 参加者全員が賭け金を払えるかを, 対戦を始める直前に確かめる.
    ///
    /// ## なぜ始める直前にもう一度見るのか
    /// 賭けられるかどうかは募集に参加した時点でも確かめている(`assertCanBet`)が,
    /// そのあと別のチャットの対戦で CHIP が減ることがある. 払えない人が混ざったまま
    /// 始めてしまうと, 精算のときに**負けた人の残高は 0 で止まる**のに
    /// (`PlayerWallet.applying` は残高を 0 未満にしない)**勝った人は満額受け取る**ため,
    /// 差額の CHIP が無から生まれてしまう.
    ///
    /// 掛け持ちで何人もの相手に同時に負けると, 負けた人は持っている分しか減らないのに
    /// 勝った人それぞれが満額もらえるので, ここを見ないと CHIP を増やす手口になる.
    private func assertEveryoneCanPay(_ playerIDs: [UserID], bet: Int) async -> Bool {
        let balances: [UserID: Int]
        do {
            balances = try await backend.fetchWalletBalances(ownerIDs: playerIDs)
        } catch {
            banner = AppError.wrap(error)
            return false
        }

        // 見つからない人は, まだ一度も CHIP を触っていない(財布のレコードが
        // 作られていない)人なので, 初期値を持っているものとして扱う.
        // ここを 0 扱いにすると, 初めて遊ぶ人が対戦を始められなくなってしまう.
        let shortIDs = playerIDs.filter { (balances[$0] ?? PlayerWallet.initialBalance) < bet }
        guard shortIDs.isEmpty else {
            let names = shortIDs.map { displayName(for: $0) }.joined(separator: "、")
            banner = .underlying(String(localized: "\(names) の CHIP が足りないため始められません"))
            return false
        }
        return true
    }

    /// 参加者全員の公開鍵. 1 人でも欠けていれば nil(暗号化して配れないため).
    private func publicKeys(for playerIDs: [UserID]) -> [UserID: Data]? {
        var keys: [UserID: Data] = [:]
        for playerID in playerIDs {
            guard let key = profilesByID[playerID]?.publicKeyData else {
                banner = .recipientHasNoPublicKey(
                    displayName: profilesByID[playerID]?.displayName ?? String(localized: "参加者")
                )
                return nil
            }
            keys[playerID] = key
        }
        return keys
    }

    // MARK: - インディアンポーカー

    func createIndianPokerLobby(bet: Int, in conversationID: ConversationID) async {
        guard let me = currentUserID, assertCanBet(bet, maxBet: IndianPokerSnapshot.maxBet) else { return }
        await sendGameMove(.indianPoker(.newLobby(hostID: me, bet: bet)), in: conversationID)
    }

    func joinIndianPoker(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .indianPoker, in: conversationID)?.indianPoker,
              var lobby = snapshot.lobby,
              !lobby.joinedPlayerIDs.contains(me),
              assertCanBet(lobby.bet, maxBet: IndianPokerSnapshot.maxBet)
        else { return }
        lobby.joinedPlayerIDs.append(me)
        var next = snapshot
        next.phase = .lobby(lobby)
        await sendGameMove(.indianPoker(next), in: conversationID)
    }

    func startIndianPoker(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .indianPoker, in: conversationID)?.indianPoker,
              let lobby = snapshot.lobby,
              me == snapshot.hostID,
              lobby.joinedPlayerIDs.count >= IndianPokerSnapshot.minimumPlayers,
              let keys = publicKeys(for: lobby.joinedPlayerIDs)
        else { return }
        guard await assertEveryoneCanPay(lobby.joinedPlayerIDs, bet: lobby.bet) else { return }

        let first = lobby.joinedPlayerIDs[0]
        let second = lobby.joinedPlayerIDs[1]
        do {
            let round = try await IndianPokerSnapshot.startRound(
                gameID: snapshot.gameID,
                first: first,
                second: second,
                bet: lobby.bet,
                firstPublicKey: keys[first] ?? Data(),
                secondPublicKey: keys[second] ?? Data(),
                crypto: crypto
            )
            var next = snapshot
            next.phase = .playing(round)
            await sendGameMove(.indianPoker(next), in: conversationID)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 勝負する / 降りる. 相手がすでに選んでいれば, 同時に相手の札を公開する.
    func actIndianPoker(_ action: IndianPokerSnapshot.Action, in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .indianPoker, in: conversationID)?.indianPoker
        else { return }
        let opponentCard = try? await snapshot.decryptedOpponentCard(for: me, crypto: crypto)
        guard let next = snapshot.acting(action, by: me, revealingOpponentCard: opponentCard) else { return }
        await sendGameMove(.indianPoker(next), in: conversationID)
        await settleChipsIfNeeded(for: .indianPoker(next))
    }

    /// 相手のカード(画面表示用). 自分のカードは自分では開けられない.
    func decryptedIndianPokerOpponentCard(in conversationID: ConversationID) async -> PlayingCard? {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .indianPoker, in: conversationID)?.indianPoker
        else { return nil }
        return try? await snapshot.decryptedOpponentCard(for: me, crypto: crypto)
    }

    /// 見せ合いの残り 1 枚を公開する(画面がこの状態を見つけたら自動で呼ぶ).
    func revealIndianPokerIfNeeded(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .indianPoker, in: conversationID)?.indianPoker,
              snapshot.isAwaitingReveal,
              snapshot.isPlayer(me),
              let card = try? await snapshot.decryptedOpponentCard(for: me, crypto: crypto),
              let next = snapshot.revealing(opponentCard: card, by: me)
        else { return }
        await sendGameMove(.indianPoker(next), in: conversationID)
        await settleChipsIfNeeded(for: .indianPoker(next))
    }

    // MARK: - ダウト

    func createDoubtLobby(bet: Int, in conversationID: ConversationID) async {
        guard let me = currentUserID, assertCanBet(bet, maxBet: DoubtSnapshot.maxBet) else { return }
        await sendGameMove(.doubt(.newLobby(hostID: me, bet: bet)), in: conversationID)
    }

    func joinDoubt(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt,
              var lobby = snapshot.lobby,
              !lobby.joinedPlayerIDs.contains(me),
              assertCanBet(lobby.bet, maxBet: DoubtSnapshot.maxBet)
        else { return }
        lobby.joinedPlayerIDs.append(me)
        var next = snapshot
        next.phase = .lobby(lobby)
        await sendGameMove(.doubt(next), in: conversationID)
    }

    func startDoubt(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt,
              let lobby = snapshot.lobby,
              me == snapshot.hostID,
              lobby.joinedPlayerIDs.count >= DoubtSnapshot.minimumPlayers,
              let keys = publicKeys(for: lobby.joinedPlayerIDs)
        else { return }
        guard await assertEveryoneCanPay(lobby.joinedPlayerIDs, bet: lobby.bet) else { return }
        do {
            guard let round = try await DoubtSnapshot.startRound(
                seating: lobby.joinedPlayerIDs,
                bet: lobby.bet,
                publicKeys: keys,
                crypto: crypto
            ) else { return }
            var next = snapshot
            next.phase = .round(round)
            await sendGameMove(.doubt(next), in: conversationID)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    func playDoubtCards(_ cards: [PlayingCard], in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt
        else { return }
        do {
            guard let next = try await snapshot.playing(cards, by: me, crypto: crypto) else { return }
            await sendGameMove(.doubt(next), in: conversationID)
            await settleChipsIfNeeded(for: .doubt(next))
        } catch {
            banner = AppError.wrap(error)
        }
    }

    /// 自分の手札(画面表示用).
    func decryptedDoubtHand(in conversationID: ConversationID) async -> [PlayingCard] {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt
        else { return [] }
        return (try? await snapshot.decryptedHand(for: me, crypto: crypto)) ?? []
    }

    func callDoubt(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt,
              let next = snapshot.callingDoubt(by: me)
        else { return }
        await sendGameMove(.doubt(next), in: conversationID)
    }

    /// ダウトされた本人の端末が, 使い捨ての鍵を公開して真偽を確定させる.
    func revealDoubtIfNeeded(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .doubt, in: conversationID)?.doubt,
              snapshot.isAwaitingReveal(by: me)
        else { return }
        do {
            guard let next = try await snapshot.revealing(by: me, crypto: crypto) else { return }
            await sendGameMove(.doubt(next), in: conversationID)
        } catch {
            banner = AppError.wrap(error)
        }
    }

    // MARK: - ブラックジャック

    func createBlackjackLobby(bet: Int, in conversationID: ConversationID) async {
        guard let me = currentUserID, assertCanBet(bet, maxBet: BlackjackSnapshot.maxBet) else { return }
        await sendGameMove(.blackjack(.newLobby(hostID: me, bet: bet)), in: conversationID)
    }

    func joinBlackjack(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .blackjack, in: conversationID)?.blackjack,
              var lobby = snapshot.lobby,
              !lobby.joinedPlayerIDs.contains(me),
              assertCanBet(lobby.bet, maxBet: BlackjackSnapshot.maxBet)
        else { return }
        lobby.joinedPlayerIDs.append(me)
        var next = snapshot
        next.phase = .lobby(lobby)
        await sendGameMove(.blackjack(next), in: conversationID)
    }

    func startBlackjack(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .blackjack, in: conversationID)?.blackjack,
              let lobby = snapshot.lobby,
              me == snapshot.hostID,
              lobby.joinedPlayerIDs.count >= BlackjackSnapshot.minimumPlayers
        else { return }
        guard await assertEveryoneCanPay(lobby.joinedPlayerIDs, bet: lobby.bet) else { return }
        var next = snapshot
        next.phase = .playing(BlackjackSnapshot.startRound(playerIDs: lobby.joinedPlayerIDs, bet: lobby.bet))
        await sendGameMove(.blackjack(next), in: conversationID)
    }

    func hitBlackjack(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .blackjack, in: conversationID)?.blackjack,
              let next = snapshot.hitting(by: me)
        else { return }
        await sendGameMove(.blackjack(next), in: conversationID)
        // 自分がバーストして全員が終わった場合は, ここで決着する.
        await settleChipsIfNeeded(for: .blackjack(next))
    }

    func standBlackjack(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .blackjack, in: conversationID)?.blackjack,
              let next = snapshot.standing(by: me)
        else { return }
        await sendGameMove(.blackjack(next), in: conversationID)
        await settleChipsIfNeeded(for: .blackjack(next))
    }

    // MARK: - チンチロ

    func createChinchiroLobby(bet: Int, in conversationID: ConversationID) async {
        guard let me = currentUserID, assertCanBet(bet, maxBet: ChinchiroSnapshot.maxBet) else { return }
        await sendGameMove(.chinchiro(.newLobby(hostID: me, bet: bet)), in: conversationID)
    }

    func joinChinchiro(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .chinchiro, in: conversationID)?.chinchiro,
              var lobby = snapshot.lobby,
              !lobby.joinedPlayerIDs.contains(me),
              assertCanBet(lobby.bet, maxBet: ChinchiroSnapshot.maxBet)
        else { return }
        lobby.joinedPlayerIDs.append(me)
        var next = snapshot
        next.phase = .lobby(lobby)
        await sendGameMove(.chinchiro(next), in: conversationID)
    }

    func startChinchiro(in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .chinchiro, in: conversationID)?.chinchiro,
              let lobby = snapshot.lobby,
              me == snapshot.hostID,
              lobby.joinedPlayerIDs.count >= ChinchiroSnapshot.minimumPlayers
        else { return }
        guard await assertEveryoneCanPay(lobby.joinedPlayerIDs, bet: lobby.bet) else { return }
        var next = snapshot
        next.phase = .rolling(
            ChinchiroSnapshot.Round(playerIDs: lobby.joinedPlayerIDs, bet: lobby.bet, rolls: [:])
        )
        await sendGameMove(.chinchiro(next), in: conversationID)
    }

    /// サイコロを振る. 出目は振った本人の端末で決める.
    func rollChinchiro(_ roll: ChinchiroRoll, in conversationID: ConversationID) async {
        guard let me = currentUserID,
              let snapshot = currentGame(kind: .chinchiro, in: conversationID)?.chinchiro,
              let next = snapshot.rolling(by: me, roll: roll)
        else { return }
        await sendGameMove(.chinchiro(next), in: conversationID)
        await settleChipsIfNeeded(for: .chinchiro(next))
    }
}
