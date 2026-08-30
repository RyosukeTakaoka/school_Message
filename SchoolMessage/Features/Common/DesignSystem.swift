import SwiftUI

/// 配色とスタイルの定義.
///
/// 具体的な色をビューに直接書かず, ここに集約する.
/// システムのセマンティックカラーを土台にしているので, ダークモードと
/// アクセシビリティのコントラスト設定に自動で追従する.
enum Palette {

    /// 自分のメッセージの背景.
    static let outgoingBubble = Color.accentColor
    /// 自分のメッセージの文字色.
    static let outgoingText = Color.white
    /// 相手のメッセージの背景.
    static let incomingBubble = Color(uiColor: .secondarySystemBackground)
    /// 相手のメッセージの文字色.
    static let incomingText = Color.primary

    static let sidebarBackground = Color(uiColor: .systemGroupedBackground)
    static let chatBackground = Color(uiColor: .systemBackground)
    static let composerBackground = Color(uiColor: .secondarySystemBackground)

    static let unreadBadge = Color.accentColor
    static let failure = Color.red
    static let subdued = Color.secondary

    /// アバターの背景色. ID から決まるので, 同じ人はいつも同じ色になる.
    ///
    /// `String.hashValue` は起動ごとに種が変わるため使えない
    /// (アプリを開き直すたびに色が変わってしまう). 決定的なハッシュを自前で計算する.
    static func avatarBackground(for seed: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// メッセージ吹き出しの形.
///
/// 連続する同じ送信者のメッセージで角の丸みを変えることで,
/// 発言のまとまりが目で追いやすくなる.
struct BubbleShape: Shape {
    let isOutgoing: Bool
    let isGroupedWithPrevious: Bool

    func path(in rect: CGRect) -> Path {
        let radius = AppConstants.Layout.bubbleCornerRadius
        let tight: CGFloat = 6

        var topLeft = radius
        var topRight = radius
        if isGroupedWithPrevious {
            if isOutgoing { topRight = tight } else { topLeft = tight }
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
