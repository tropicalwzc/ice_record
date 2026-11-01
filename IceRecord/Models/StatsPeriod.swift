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

    /// 归并时最多保留多少个点（**不是**屏幕上同时能看到多少个）。
    ///
    /// 早先这里是日 30 / 周 26 / 月 24 / 年 10，等于「历史超过一个月就看不见了」。
    /// 现在曲线支持左右滑动翻看，这里改成「加载多少历史」的上限：
    /// 载入足够长的历史，屏幕上一屏只显示最近 90 个点，其余靠滑动去看。
    /// 上限仍然要有，否则几年的日快照会让归并和绘制都变慢。
    var maxPoints: Int {
        switch self {
        case .day: 730      // 两年
        case .week: 260     // 五年
        case .month: 120    // 十年
        case .year: 50
        }
    }

    /// 一屏最多显示多少个点。超过这个数就在图表下方给一条滑条，用来切换区间。
    ///
    /// 从 90 收到 60：60 个点在 393pt 宽上每点约 5pt，曲线还看得出形状，
    /// 再多就变成一条锯齿；而且一屏跨两个月，日常查看的密度刚好。
    static let visiblePointLimit = 60

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

}
