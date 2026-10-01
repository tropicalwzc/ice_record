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

}

/// 曲线横轴刻度的选取。
///
/// 三条硬性要求：
/// 1. 刻度**按时间等距**，不是按下标等距——横轴是时间轴，屏幕上等距 = 时间上等距。
///    按下标挑，遇到疏密不均的真实记录（中间几个月没记、最近天天记），
///    末尾几个日期就会挤成一团。
/// 2. 刻度数量**按文字实际渲染宽度收敛**（见 `fittingTickDates`）：标签一律居中，
///    每一对相邻标签都量出来放得下才采用。用固定常量估宽度，宽屏上会多塞一个刻度，
///    实测「10月1日」直接压住「9月28日」。
/// 3. 刻度**自己算**，不交给系统按「好看的日期」自动生成：自动生成的刻度可能落在
///    数据范围之外，被挤到绘图区边缘后互相重叠，甚至被截断。
enum TrendAxis {

    /// 绘图区左右各留多少比例的白边（拿不到绘图区宽度时的兜底值）
    static let domainPaddingRatio = 0.03

    /// 在放得下的前提下取尽量多的刻度。
    ///
    /// 从 `limit` 个开始往下试，用**真实文字宽度**算一遍相邻标签的间隙，
    /// 全部满足 `minimumGap` 才采用；都不满足时退回 2 个。
    ///
    /// 标签一律**居中**放在自己的刻度上（不依赖任何按版本变化的对齐行为），
    /// 所以两端各留出 `edgePadding` 的时间白边，让首尾日期完整落在绘图区内。
    ///
    /// - Parameters:
    ///   - edgePadding: 数据区间两端各留出的时间白边（由视图按半个标签宽算出）。
    ///   - labelWidth: 量某个文案要占多少宽度（由视图用渲染时的同一套字体测）。
    static func fittingTickDates(
        from start: Date,
        to end: Date,
        edgePadding: TimeInterval,
        period: StatsPeriod,
        limit: Int,
        plotWidth: CGFloat,
        minimumGap: CGFloat,
        labelWidth: (String) -> CGFloat
    ) -> [Date] {
        guard limit > 1, end > start else {
            return tickDates(from: start, to: end, period: period, limit: max(limit, 1))
        }
        guard plotWidth > 0 else {
            return tickDates(from: start, to: end, period: period, limit: limit)
        }

        for count in stride(from: limit, through: 2, by: -1) {
            let dates = tickDates(from: start, to: end, period: period, limit: count)
            if dates.count < 2 { return dates }
            if fits(
                dates,
                dataStart: start,
                dataSpan: end.timeIntervalSince(start),
                edgePadding: edgePadding,
                period: period,
                plotWidth: plotWidth,
                minimumGap: minimumGap,
                labelWidth: labelWidth
            ) {
                return dates
            }
        }

        return tickDates(from: start, to: end, period: period, limit: 2)
    }

    /// 相邻标签之间是否都留得下 `minimumGap`（标签居中，各占半个字宽）。
    private static func fits(
        _ dates: [Date],
        dataStart: Date,
        dataSpan: TimeInterval,
        edgePadding: TimeInterval,
        period: StatsPeriod,
        plotWidth: CGFloat,
        minimumGap: CGFloat,
        labelWidth: (String) -> CGFloat
    ) -> Bool {
        let widths = dates.enumerated().map { index, date in
            labelWidth(label(for: period, on: date, isRangeStart: index == 0))
        }

        let paddedSpan = dataSpan + edgePadding * 2
        let positions = dates.map { date in
            (date.timeIntervalSince(dataStart) + edgePadding) / paddedSpan * plotWidth
        }

        for index in 0..<(dates.count - 1) {
            let needed = (widths[index] + widths[index + 1]) / 2 + minimumGap
            if positions[index + 1] - positions[index] < needed { return false }
        }
        return true
    }

    /// 首尾数据点之间按时间等距取 `limit` 个刻度；相邻刻度落进同一个桶的合并成一个。
    static func tickDates(from start: Date, to end: Date, period: StatsPeriod, limit: Int) -> [Date] {
        let dates = evenlySpaced(from: start, to: end, count: limit)
        return mergingSameBucket(dates, period: period)
    }

    /// 在 `start` 和 `end` 之间等距取 `count` 个时间点，首尾一定在里面。
    static func evenlySpaced(from start: Date, to end: Date, count: Int) -> [Date] {
        guard count > 1, end > start else { return [start] }

        let span = end.timeIntervalSince(start)
        return (0..<count).map { index in
            start.addingTimeInterval(span * (Double(index) / Double(count - 1)))
        }
    }

    /// 相邻刻度落进同一个桶时只保留前一个。
    ///
    /// 年 / 月粒度下刻度间隔可能比一个桶还短（比如一整年只放得下 4 个刻度，
    /// 4 个都会落在同一年），不去重就会出现两个一模一样的「2026年」。
    static func mergingSameBucket(_ dates: [Date], period: StatsPeriod) -> [Date] {
        var result: [Date] = []
        var lastBucket: Date?
        for date in dates {
            let bucket = period.bucketStart(for: date)
            guard bucket != lastBucket else { continue }
            result.append(date)
            lastBucket = bucket
        }
        return result
    }

    /// 刻度的展示文案。
    ///
    /// - Parameter isRangeStart: 是否是区间最左边的那个刻度。
    ///   月粒度只在区间开头和跨年（1 月）时写上「2026年」，避免每个刻度都重复年份。
    static func label(for period: StatsPeriod, on date: Date, isRangeStart: Bool) -> String {
        switch period {
        case .day, .week:
            return DateDisplay.monthDay(date)
        case .month:
            let month = DayKey.calendar.component(.month, from: date)
            return (isRangeStart || month == 1) ? DateDisplay.yearMonth(date) : DateDisplay.month(date)
        case .year:
            return DateDisplay.year(date)
        }
    }
}
