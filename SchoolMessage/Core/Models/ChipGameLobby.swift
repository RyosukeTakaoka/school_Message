import Foundation

/// CHIP を使うゲームに共通の「募集」段階.
///
/// 募集した人が賭ける額を先に決め, 参加する人はその額を見てから参加する.
/// 全員が同じ額を出すので, 勝った人が総取りしても CHIP の総量が釣り合う.
struct ChipGameLobby: Hashable, Sendable, Codable {
    var joinedPlayerIDs: [UserID]
    var bet: Int

    init(hostID: UserID, bet: Int) {
        self.joinedPlayerIDs = [hostID]
        self.bet = bet
    }

    func canStart(minimumPlayers: Int) -> Bool {
        joinedPlayerIDs.count >= minimumPlayers
    }
}
