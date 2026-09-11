import Foundation

/// メッセージへの絵文字リアクション.
///
/// メッセージ本体とは別のレコードとして持つ.
/// Public Database では「レコードを更新できるのは作成者だけ」という制約があるため,
/// 他人が送ったメッセージのレコードに自分の反応を書き足すことはできない
/// (`docs/CLOUDKIT_SCHEMA.md` / `Conversation` の補足を参照).
/// 代わりに, リアクションした本人だけが作れる専用レコードにして,
/// メッセージ ID で結びつける.
///
/// 1 人が 1 件のメッセージに付けられるリアクションは 1 個まで
/// (同じ絵文字を選び直すと外れ, 別の絵文字を選ぶと差し替わる. LINE 等と同じ考え方).
struct MessageReaction: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var conversationID: ConversationID
    var userID: UserID
    var emoji: String
    var createdAt: Date

    var id: String { "\(messageID.rawValue)-\(userID.rawValue)" }
}
