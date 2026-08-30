import Foundation

/// 日時の表示整形.
///
/// `DateFormatter` の生成は重いので使い回す. またチャット一覧は
/// スクロールのたびに評価されるため, ここでの割り当てを最小限にする.
enum DateDisplay {

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    /// チャット一覧用. 今日なら時刻, 今週なら曜日, それ以前なら日付.
    static func listTimestamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "昨日")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
            return weekdayFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }

    /// 吹き出しの脇に出す送信時刻.
    static func messageTimestamp(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// メッセージ群の間に挟む日付区切り.
    static func daySeparator(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "今日") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨日") }
        return fullDateFormatter.string(from: date)
    }

    /// VoiceOver 用の, 省略しない読み上げ文字列.
    static func accessibilityTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
