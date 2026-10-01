import XCTest
@testable import IceRecord

/// 日 / 周 / 月 / 年 归并逻辑的测试。
final class TrendAggregatorTests: XCTestCase {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return DayKey.calendar.date(from: components)!
    }

    private func snapshot(_ id: Int64, _ day: Date, _ total: Double) -> AssetSnapshot {
        let start = DayKey.startOfDay(day)
        return AssetSnapshot(
            id: id,
            day: start,
            totalAmount: total,
            itemCount: 1,
            recordedAt: start,
            updatedAt: start
        )
    }

    // MARK: - 日

    func testDailyAggregationKeepsEveryDay() {
        let snapshots = [
            snapshot(1, date(2026, 3, 1), 10),
            snapshot(2, date(2026, 3, 2), 11),
            snapshot(3, date(2026, 3, 3), 9.5)
        ]

        let points = TrendAggregator.aggregate(snapshots, period: .day)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.total), [10, 11, 9.5])
        XCTAssertEqual(points.map(\.sampleCount), [1, 1, 1])
        XCTAssertEqual(points[0].change, 0, accuracy: 0.000_001, "第一个点没有参照物")
        XCTAssertEqual(points[1].change, 1, accuracy: 0.000_001)
        XCTAssertEqual(points[2].change, -1.5, accuracy: 0.000_001)
        XCTAssertEqual(points[2].changeRatio, -13.636_363, accuracy: 0.000_1)
        XCTAssertTrue(points[2].isDown)
        XCTAssertEqual(points[1].id, DayKey.string(from: DayKey.startOfDay(date(2026, 3, 2))))
    }

    // MARK: - 周（周一为一周开始）

    func testWeeklyAggregationUsesLastSnapshotOfEachWeek() {
        let snapshots = [
            snapshot(1, date(2026, 1, 5), 10),   // 周一
            snapshot(2, date(2026, 1, 7), 12),   // 同一周
            snapshot(3, date(2026, 1, 12), 15)   // 下一周的周一
        ]

        let points = TrendAggregator.aggregate(snapshots, period: .week)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].total, 12, "应取该周最后一次记录")
        XCTAssertEqual(points[0].sampleCount, 2)
        XCTAssertEqual(points[0].average, 11, accuracy: 0.000_001)
        XCTAssertEqual(points[0].minimum, 10, accuracy: 0.000_001)
        XCTAssertEqual(points[0].maximum, 12, accuracy: 0.000_001)
        XCTAssertEqual(points[1].total, 15, accuracy: 0.000_001)
        XCTAssertEqual(points[1].change, 3, accuracy: 0.000_001)
        XCTAssertEqual(
            DayKey.string(from: points[0].date),
            DayKey.string(from: DayKey.startOfDay(date(2026, 1, 5))),
            "周桶应从周一开始"
        )
    }

    // MARK: - 月

    func testMonthlyAggregation() {
        let snapshots = [
            snapshot(1, date(2026, 1, 5), 10),
            snapshot(2, date(2026, 1, 31), 11),
            snapshot(3, date(2026, 2, 2), 15),
            snapshot(4, date(2026, 2, 20), 14)
        ]

        let points = TrendAggregator.aggregate(snapshots, period: .month)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].total, 11, "一月应取 1/31 的值")
        XCTAssertEqual(points[0].sampleCount, 2)
        XCTAssertEqual(points[1].total, 14, "二月应取 2/20 的值")
        XCTAssertEqual(points[1].sampleCount, 2)
        XCTAssertEqual(points[1].change, 3, accuracy: 0.000_001)
        XCTAssertEqual(DayKey.string(from: points[0].date), DayKey.string(from: DayKey.startOfDay(date(2026, 1, 1))))
        XCTAssertEqual(DayKey.string(from: points[1].date), DayKey.string(from: DayKey.startOfDay(date(2026, 2, 1))))
    }

    // MARK: - 年

    func testYearlyAggregation() {
        let snapshots = [
            snapshot(1, date(2024, 12, 31), 5),
            snapshot(2, date(2025, 6, 1), 8),
            snapshot(3, date(2025, 12, 31), 9),
            snapshot(4, date(2026, 1, 5), 10)
        ]

        let points = TrendAggregator.aggregate(snapshots, period: .year)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.total), [5, 9, 10])
        XCTAssertEqual(points.map(\.sampleCount), [1, 2, 1])
        XCTAssertEqual(DayKey.string(from: points[1].date), DayKey.string(from: DayKey.startOfDay(date(2025, 1, 1))))
        XCTAssertEqual(DayKey.string(from: points[2].date), DayKey.string(from: DayKey.startOfDay(date(2026, 1, 1))))
    }

    // MARK: - 采样上限

    func testDailyAggregationIsCappedToMostRecentPoints() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let snapshots = (0..<45).map { offset -> AssetSnapshot in
            let day = DayKey.calendar.date(byAdding: .day, value: offset, to: start)!
            return snapshot(Int64(offset + 1), day, Double(offset))
        }

        let points = TrendAggregator.aggregate(snapshots, period: .day)

        XCTAssertEqual(points.count, StatsPeriod.day.maxPoints)
        XCTAssertEqual(points.last?.total ?? .nan, 44, accuracy: 0.000_001)
        XCTAssertEqual(points.first?.total ?? .nan, 15, accuracy: 0.000_001, "应保留最近 30 个点")
    }

    func testEmptyInputProducesNoPoints() {
        for period in StatsPeriod.allCases {
            XCTAssertTrue(TrendAggregator.aggregate([], period: period).isEmpty)
        }
    }

    func testUnorderedInputIsSorted() {
        let snapshots = [
            snapshot(3, date(2026, 3, 3), 12),
            snapshot(1, date(2026, 3, 1), 10),
            snapshot(2, date(2026, 3, 2), 11)
        ]

        let points = TrendAggregator.aggregate(snapshots, period: .day)

        XCTAssertEqual(points.map(\.total), [10, 11, 12])
    }

    // MARK: - 格式化

    func testAmountFormatterParsingAndDisplay() {
        XCTAssertEqual(AmountFormatter.parse("10.5") ?? 0, 10.5, accuracy: 0.000_001)
        XCTAssertEqual(AmountFormatter.parse(" 1,234.56 ") ?? 0, 1234.56, accuracy: 0.000_001)
        XCTAssertEqual(AmountFormatter.parse("１") ?? -1, -1, "全角数字不应被解析")
        XCTAssertNil(AmountFormatter.parse(""))
        XCTAssertNil(AmountFormatter.parse("abc"))

        XCTAssertEqual(AmountFormatter.yuan(10.5), "105,000")
        XCTAssertEqual(AmountFormatter.signed(0.2), "+0.20 万")
        XCTAssertEqual(AmountFormatter.signed(-1.3), "-1.30 万")
        XCTAssertEqual(AmountFormatter.signedNumber(3.33), "+3.33")
        XCTAssertEqual(AmountFormatter.signedNumber(-5.49), "-5.49")
        XCTAssertEqual(AmountFormatter.signedNumber(0), "0.00")
        XCTAssertEqual(AmountFormatter.editingText(10.5), "10.5")
        XCTAssertEqual(AmountFormatter.editingText(10.0), "10")
    }

    func testDayKeyRoundTrip() {
        let day = date(2026, 3, 5)
        let key = DayKey.string(from: day)
        XCTAssertEqual(key, "2026-03-05")
        let parsed = DayKey.date(from: key)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(DayKey.string(from: parsed!), key)
    }

    // MARK: - 横轴刻度

    func testAxisTicksAreEvenlySpacedInTime() {
        let start = date(2026, 1, 1)
        let end = date(2026, 1, 5)

        let ticks = TrendAxis.evenlySpaced(from: start, to: end, count: 5)

        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(ticks.first, start)
        XCTAssertEqual(ticks.last, end)
        for (previous, next) in zip(ticks, ticks.dropFirst()) {
            XCTAssertEqual(next.timeIntervalSince(previous), 86_400, accuracy: 0.001)
        }
    }

    func testAxisTicksDegenerateInputs() {
        let day = date(2026, 3, 5)
        XCTAssertEqual(TrendAxis.evenlySpaced(from: day, to: day, count: 4), [day], "只有一个点时只给一个刻度")
        XCTAssertEqual(TrendAxis.evenlySpaced(from: day, to: day, count: 1), [day])
    }

    /// 回归：以前按「下标」等距挑刻度，真实记录疏密不均时，
    /// 末尾几个日期在屏幕上会挤到一起（实测「9月28日」和「10月1日」叠字）。
    /// 改成按时间等距之后，任意相邻刻度的间隔都应该是总跨度的 1/(刻度数-1)。
    func testAxisTicksNeverCrowdWhenRecordsAreUneven() {
        // 3 月记了一条，然后一直到 9 月底才天天记
        let points = [
            date(2026, 3, 1),
            date(2026, 9, 28),
            date(2026, 9, 29),
            date(2026, 9, 30),
            date(2026, 10, 1)
        ]

        let ticks = TrendAxis.tickDates(from: points[0], to: points[4], period: .day, limit: 4)

        XCTAssertEqual(ticks.count, 4)
        XCTAssertEqual(ticks.first, points[0])
        XCTAssertEqual(ticks.last, points[4])

        let span = points[4].timeIntervalSince(points[0])
        let expected = span / 3
        for (previous, next) in zip(ticks, ticks.dropFirst()) {
            XCTAssertEqual(
                next.timeIntervalSince(previous),
                expected,
                accuracy: 60,
                "相邻刻度必须按时间等距，否则末尾会叠在一起"
            )
        }
        // 最后两个刻度至少隔开整个区间的四分之一，不可能再叠字
        XCTAssertGreaterThan(ticks[3].timeIntervalSince(ticks[2]), span / 4)
    }

    func testAxisTicksMergeSameMonthIntoOne() {
        let ticks = TrendAxis.tickDates(
            from: date(2026, 3, 3),
            to: date(2026, 3, 25),
            period: .month,
            limit: 4
        )

        XCTAssertEqual(ticks.count, 1, "四个刻度都落在同一个月，只留一个「3月」")
    }

    func testAxisTicksMergeSameYearIntoOne() {
        let ticks = TrendAxis.tickDates(
            from: date(2026, 3, 1),
            to: date(2026, 10, 1),
            period: .year,
            limit: 4
        )

        XCTAssertEqual(ticks.count, 1, "四个刻度都落在同一年，只留一个「2026年」")
    }

    func testAxisTicksKeepDistinctMonthsAndYears() {
        let months = TrendAxis.tickDates(
            from: date(2026, 1, 1),
            to: date(2026, 12, 1),
            period: .month,
            limit: 4
        )
        XCTAssertEqual(months.count, 4, "跨 12 个月的刻度本来就是不同的月份")

        let years = TrendAxis.tickDates(
            from: date(2020, 1, 1),
            to: date(2026, 1, 1),
            period: .year,
            limit: 4
        )
        XCTAssertEqual(years.count, 4)
    }

    func testDayAndWeekAxisLabelsUseChineseMonthDay() {
        let day = date(2026, 3, 5)
        XCTAssertEqual(TrendAxis.label(for: .day, on: day, isRangeStart: false), "3月5日")
        XCTAssertEqual(TrendAxis.label(for: .week, on: day, isRangeStart: true), "3月5日")
    }

    /// 月粒度只在区间开头和跨年时写年份，避免每个刻度都是「2026年x月」。
    func testMonthAxisLabelShowsYearOnlyAtStartAndJanuary() {
        XCTAssertEqual(TrendAxis.label(for: .month, on: date(2026, 3, 1), isRangeStart: true), "2026年3月")
        XCTAssertEqual(TrendAxis.label(for: .month, on: date(2026, 3, 1), isRangeStart: false), "3月")
        XCTAssertEqual(TrendAxis.label(for: .month, on: date(2027, 1, 1), isRangeStart: false), "2027年1月")
    }

    func testYearAxisLabelUsesChineseYear() {
        XCTAssertEqual(TrendAxis.label(for: .year, on: date(2026, 1, 1), isRangeStart: false), "2026年")
    }

    // MARK: - 按文字宽度收敛刻度数量

    /// 实测「10月1日」这类文案在 11pt semibold 圆体下大约 46pt 宽
    private let labelWidth46: (String) -> CGFloat = { _ in 46 }

    /// 标签一律居中，所以每一对相邻标签需要的间距是「一个字宽 + 空隙」。
    /// 绘图区不够宽时应当减少刻度，而不是让日期挤在一起。
    func testFittingTicksDropsToFourWhenFiveWouldCrowd() {
        let start = date(2026, 9, 22)
        let end = date(2026, 10, 1)

        let dates = TrendAxis.fittingTickDates(
            from: start,
            to: end,
            edgePadding: 0.8 * 86_400,
            period: .day,
            limit: 5,
            plotWidth: 240,
            minimumGap: 14,
            labelWidth: labelWidth46
        )

        XCTAssertEqual(dates.count, 4, "5 个刻度放不下时应当收敛到 4 个")
        XCTAssertEqual(dates.first, start, "首尾日期仍然要标出来")
        XCTAssertEqual(dates.last, end)
    }

    func testFittingTicksKeepsFiveOnAWideScreen() {
        let dates = TrendAxis.fittingTickDates(
            from: date(2026, 9, 22),
            to: date(2026, 10, 1),
            edgePadding: 0.8 * 86_400,
            period: .day,
            limit: 5,
            plotWidth: 600,
            minimumGap: 14,
            labelWidth: labelWidth46
        )

        XCTAssertEqual(dates.count, 5, "屏幕够宽就放 5 个")
    }

    /// 不管绘图区多宽，相邻标签之间都不许重叠。
    func testFittingTicksNeverOverlapAtAnyWidth() {
        let start = date(2026, 9, 22)
        let end = date(2026, 10, 1)
        let edgePadding = 0.8 * 86_400.0
        let span = end.timeIntervalSince(start)

        for plotWidth in stride(from: 140.0, through: 900.0, by: 11.0) {
            let dates = TrendAxis.fittingTickDates(
                from: start,
                to: end,
                edgePadding: edgePadding,
                period: .day,
                limit: 5,
                plotWidth: plotWidth,
                minimumGap: 14,
                labelWidth: labelWidth46
            )
            XCTAssertGreaterThanOrEqual(dates.count, 2, "plotWidth = \(plotWidth)")

            let paddedSpan = span + edgePadding * 2
            let positions = dates.map { ($0.timeIntervalSince(start) + edgePadding) / paddedSpan * plotWidth }

            for index in 0..<(dates.count - 1) {
                // 标签居中：每个占半个字宽
                let gap = positions[index + 1] - positions[index] - 46
                XCTAssertGreaterThanOrEqual(
                    gap,
                    14 - 0.01,
                    "plotWidth = \(plotWidth) 时第 \(index) 个间隙只有 \(gap)pt"
                )
            }
        }
    }

    /// 文字更宽（月粒度带年份）时会更早收敛
    func testFittingTicksAccountsForWiderLabels() {
        let narrowLabels = TrendAxis.fittingTickDates(
            from: date(2026, 1, 1), to: date(2026, 12, 1), edgePadding: 0,
            period: .month, limit: 5, plotWidth: 400, minimumGap: 14, labelWidth: { _ in 30 }
        )
        let wideLabels = TrendAxis.fittingTickDates(
            from: date(2026, 1, 1), to: date(2026, 12, 1), edgePadding: 0,
            period: .month, limit: 5, plotWidth: 400, minimumGap: 14, labelWidth: { _ in 90 }
        )

        XCTAssertGreaterThan(narrowLabels.count, wideLabels.count)
    }
}
