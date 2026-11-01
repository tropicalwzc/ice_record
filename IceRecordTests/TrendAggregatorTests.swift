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

    /// 上限的含义变了：现在是「最多加载多少历史」，一屏能看多少由 `TrendWindow` 决定。
    /// 45 天远小于日粒度的加载上限，所以一条都不该被截掉。
    func testDailyAggregationKeepsEverythingUnderTheLoadLimit() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let snapshots = (0..<45).map { offset -> AssetSnapshot in
            let day = DayKey.calendar.date(byAdding: .day, value: offset, to: start)!
            return snapshot(Int64(offset + 1), day, Double(offset))
        }

        let points = TrendAggregator.aggregate(snapshots, period: .day)

        XCTAssertEqual(points.count, 45)
        XCTAssertEqual(points.first?.total ?? .nan, 0, accuracy: 0.000_001)
        XCTAssertEqual(points.last?.total ?? .nan, 44, accuracy: 0.000_001)
    }

    /// 超过加载上限才截断，且保留最近的那一段
    func testAggregationIsCappedToTheLoadLimit() {
        let start = DayKey.startOfDay(date(2024, 1, 1))
        let total = StatsPeriod.day.maxPoints + 20
        let snapshots = (0..<total).map { offset -> AssetSnapshot in
            let day = DayKey.calendar.date(byAdding: .day, value: offset, to: start)!
            return snapshot(Int64(offset + 1), day, Double(offset))
        }

        let points = TrendAggregator.aggregate(snapshots, period: .day)

        XCTAssertEqual(points.count, StatsPeriod.day.maxPoints)
        XCTAssertEqual(points.last?.total ?? .nan, Double(total - 1), accuracy: 0.000_001)
    }

    // MARK: - 可视窗口（TrendWindow）

    private func makePoints(_ count: Int, startingAt start: Date) -> [TrendPoint] {
        (0..<count).map { offset in
            let date = DayKey.calendar.date(byAdding: .day, value: offset, to: start)!
            return TrendPoint(
                id: DayKey.string(from: date),
                date: date,
                total: Double(offset),
                average: Double(offset),
                minimum: Double(offset),
                maximum: Double(offset),
                sampleCount: 1,
                change: 0,
                changeRatio: 0
            )
        }
    }

    /// 正好一屏不给滑条，多一个点才给——数据不够时给控件会让人以为还能往两边翻
    func testSliderOnlyAppearsBeyondOneScreen() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let limit = StatsPeriod.visiblePointLimit

        XCTAssertEqual(limit, 60)
        XCTAssertFalse(TrendWindow(points: makePoints(limit, startingAt: start)).isScrollable)
        XCTAssertTrue(TrendWindow(points: makePoints(limit + 1, startingAt: start)).isScrollable)
    }

    /// 默认停最新一屏：起点偏移 = 总点数 - 一屏点数
    func testDefaultOffsetIsTheLatestWindow() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let window = TrendWindow(points: makePoints(100, startingAt: start))

        XCTAssertEqual(window.visibleCount, StatsPeriod.visiblePointLimit)
        XCTAssertEqual(window.maximumOffset, 40)
        XCTAssertEqual(window.defaultOffset, 40)

        let latest = window.points(atOffset: window.defaultOffset)
        XCTAssertEqual(latest.count, StatsPeriod.visiblePointLimit)
        XCTAssertEqual(latest.last?.total ?? .nan, 99, accuracy: 0.000_001)
        XCTAssertEqual(latest.first?.total ?? .nan, 40, accuracy: 0.000_001)
    }

    /// 滑条给浮点、四舍五入后可能越界，必须夹回合法区间
    func testOffsetsAreClamped() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let window = TrendWindow(points: makePoints(100, startingAt: start))

        XCTAssertEqual(window.clampedOffset(-5), 0)
        XCTAssertEqual(window.clampedOffset(999), 40)
        XCTAssertEqual(window.points(atOffset: -5).first?.total ?? .nan, 0, accuracy: 0.000_001)
        XCTAssertEqual(window.points(atOffset: 999).last?.total ?? .nan, 99, accuracy: 0.000_001)
    }

    /// 滑到最左边就是最早的一屏，时间范围跟着偏移走
    func testRangeFollowsTheOffset() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let window = TrendWindow(points: makePoints(100, startingAt: start))

        let earliest = try! XCTUnwrap(window.range(atOffset: 0))
        XCTAssertEqual(earliest.lowerBound, start)
        XCTAssertEqual(window.points(atOffset: 0).last?.total ?? .nan, 59, accuracy: 0.000_001)

        let latest = try! XCTUnwrap(window.range(atOffset: window.defaultOffset))
        XCTAssertEqual(latest.upperBound, window.fullRange?.upperBound)
    }

    /// 数据不到一屏时窗口就是全部，不引入任何裁剪，滑条也不显示
    func testShortSeriesIsNotWindowed() {
        let start = DayKey.startOfDay(date(2026, 1, 1))
        let window = TrendWindow(points: makePoints(10, startingAt: start))

        XCTAssertFalse(window.isScrollable)
        XCTAssertEqual(window.maximumOffset, 0)
        XCTAssertEqual(window.points(atOffset: 5).count, 10)
        XCTAssertEqual(window.range(atOffset: 0)?.lowerBound, start)
        XCTAssertEqual(window.range(atOffset: 0)?.upperBound, window.fullRange?.upperBound)
    }

    func testEmptySeriesProducesNoRange() {
        let window = TrendWindow(points: [])
        XCTAssertFalse(window.isScrollable)
        XCTAssertEqual(window.maximumOffset, 0)
        XCTAssertNil(window.fullRange)
        XCTAssertNil(window.range(atOffset: 0))
    }
}
