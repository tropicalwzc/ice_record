import Foundation

/// 全局统一的“自然日”口径。
///
/// 记账里的“最新自然日”= 设备当前时区下的今天 00:00。
/// 数据库里用 `yyyy-MM-dd` 字符串作为唯一键，保证同一天只会有一条快照。
enum DayKey {
    /// 统一使用的日历：公历 + 当前时区 + 周一为一周开始（符合国内习惯）。
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        dayKeyFormatter.date(from: string)
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}

/// 界面上的日期展示（固定中文格式，和界面文案保持一致）。
enum DateDisplay {
    private static let locale = Locale(identifier: "zh_CN")

    /// 2026年3月5日
    static func fullDay(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(locale))
    }

    /// 3月5日
    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(locale))
    }

    /// 2026年3月
    static func yearMonth(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().locale(locale))
    }

    /// 2026年
    static func year(_ date: Date) -> String {
        date.formatted(.dateTime.year().locale(locale))
    }

    /// 3/5
    static func shortMonthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().locale(locale))
    }

    /// 2026/3/5 14:30
    static func timestamp(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year().month(.defaultDigits).day()
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                .locale(locale)
        )
    }
}
