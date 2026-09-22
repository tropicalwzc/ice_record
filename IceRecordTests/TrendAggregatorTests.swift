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
}
