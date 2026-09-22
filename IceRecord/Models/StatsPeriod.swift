import Foundation

/// 曲线图的统计粒度。
///
/// 快照本身是按“自然日”存的；日/周/月/年只是把这些日快照归并到不同的时间桶里。
enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }

    var pickerTitle: String { "按\(title)" }

    /// 图上最多显示多少个点，超出只保留最近的
    var maxPoints: Int {
        switch self {
        case .day: 30
        case .week: 26
        case .month: 24
        case .year: 10
        }
    }

    /// 桶的说明文案
    var bucketDescription: String {
        switch self {
        case .day: "每个自然日一个点，取当天最后一次记录"
        case .week: "按自然周（周一起）归并，取该周最后一次记录"
        case .month: "按自然月归并，取该月最后一次记录"
        case .year: "按自然年归并，取该年最后一次记录"
        }
    }

    /// 某个日期落在哪个桶里（返回桶的起始时间）
    func bucketStart(for date: Date, calendar: Calendar = DayKey.calendar) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    /// 桶起始时间的展示文案
    func label(for bucketStart: Date) -> String {
        switch self {
        case .day: DateDisplay.fullDay(bucketStart)
        case .week: "\(DateDisplay.monthDay(bucketStart)) 起的一周"
        case .month: DateDisplay.yearMonth(bucketStart)
        case .year: DateDisplay.year(bucketStart)
        }
    }

    /// 图表 X 轴的日期格式
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day, .week: .dateTime.month(.defaultDigits).day()
        case .month: .dateTime.year(.twoDigits).month(.defaultDigits)
        case .year: .dateTime.year()
        }
    }
}
