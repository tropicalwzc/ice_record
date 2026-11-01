import XCTest
@testable import IceRecord

/// 分类小计的落库行为：v3 迁移、批量读取、覆盖写、墓碑级联。
///
/// 这一层的关键约定都在这里被钉住：
/// **一天固定 7 行（含 0）、写入与总额同事务、删除快照时分类行跟着删。**
@MainActor
final class SnapshotCategoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceRecordSnapshotCategoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(directory: directory)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return DayKey.startOfDay(DayKey.calendar.date(from: components)!)
    }

    private func fullBreakdown(stock: Double = 0, fund: Double = 0) -> [AssetCategory: Double] {
        var result: [AssetCategory: Double] = [:]
        for category in AssetCategory.allCases { result[category] = 0 }
        result[.stock] = stock
        result[.fund] = fund
        return result
    }

    // MARK: - 1.1 迁移

    func testNewDatabaseStartsAtSchemaVersionThree() throws {
        let database = try makeDatabase()
        XCTAssertEqual(database.schemaVersion, 3)
        XCTAssertEqual(try database.snapshotCategoryRowCount(), 0)
    }

    /// 从 v2 旧库升级：分类表被建出来，能正常读写，老数据不丢
    func testUpgradeFromVersionTwoCreatesCategoryTable() throws {
        let fileURL = directory.appendingPathComponent("IceRecord.sqlite")

        // 手工造一个 v2 的库（v1 建表 + v2 加列），并塞一条历史快照
        try {
            let legacy = try SQLiteDatabase(path: fileURL.path)
            try legacy.execute(
                """
                CREATE TABLE asset_snapshot (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    day           TEXT    NOT NULL UNIQUE,
                    total_amount  REAL    NOT NULL,
                    item_count    INTEGER NOT NULL DEFAULT 0,
                    recorded_at   REAL    NOT NULL,
                    updated_at    REAL    NOT NULL
                );
                """
            )
            try legacy.execute("ALTER TABLE asset_snapshot ADD COLUMN deleted_at REAL;")
            try legacy.execute("ALTER TABLE asset_snapshot ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1;")
            try legacy.execute(
                "INSERT INTO asset_snapshot (day, total_amount, item_count, recorded_at, updated_at, sync_dirty) VALUES ('2026-10-01', 10, 1, 0, 0, 0);"
            )
            try legacy.execute("PRAGMA user_version = 2;")
        }()

        let database = try makeDatabase()
        XCTAssertEqual(database.schemaVersion, 3)
        XCTAssertEqual(try database.snapshotCount(), 1, "升级不能丢历史快照")

        try database.replaceSnapshotCategories(dayKey: "2026-10-01", categories: fullBreakdown(stock: 10))
        let fetched = try database.fetchSnapshotCategories(for: ["2026-10-01"])
        XCTAssertEqual(fetched["2026-10-01"]?[.stock], 10)
    }

    // MARK: - 1.2 批量读取

    func testCategoriesAreGroupedByDayInOneStatement() throws {
        let database = try makeDatabase()
        let days = [
            DayKey.string(from: date(2026, 10, 1)),
            DayKey.string(from: date(2026, 10, 2))
        ]
        try database.replaceSnapshotCategories(dayKey: days[0], categories: fullBreakdown(stock: 5, fund: 2))
        try database.replaceSnapshotCategories(dayKey: days[1], categories: fullBreakdown(stock: 6, fund: 3))

        let before = database.snapshotCategoryStatementCount
        let fetched = try database.fetchSnapshotCategories(for: days)
        let usedStatements = database.snapshotCategoryStatementCount - before

        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[days[0]]?[.stock], 5)
        XCTAssertEqual(fetched[days[1]]?[.fund], 3)
        XCTAssertEqual(fetched[days[0]]?.count, AssetCategory.allCases.count)
        XCTAssertEqual(usedStatements, 1, "两天 14 行必须一次查回来，不能退化成 N+1")
    }

    func testFetchingEmptyDayListDoesNotQuery() throws {
        let database = try makeDatabase()
        let before = database.snapshotCategoryStatementCount
        XCTAssertTrue(try database.fetchSnapshotCategories(for: []).isEmpty)
        XCTAssertEqual(database.snapshotCategoryStatementCount, before)
    }

    // MARK: - 1.3 墓碑级联

    func testDeletingSnapshotRemovesItsCategoryRows() throws {
        let database = try makeDatabase()
        let day = date(2026, 10, 1)
        try database.upsertSnapshot(
            day: day,
            totalAmount: 7,
            itemCount: 2,
            categories: fullBreakdown(stock: 5, fund: 2)
        )
        XCTAssertEqual(try database.snapshotCategoryRowCount(), AssetCategory.allCases.count)

        try database.deleteSnapshot(day: day)
        XCTAssertEqual(try database.snapshotCategoryRowCount(), 0, "墓碑后不能留下无主的分类行")
        XCTAssertEqual(try database.snapshotCount(), 0)
    }

    func testDeletingAllSnapshotsRemovesAllCategoryRows() throws {
        let database = try makeDatabase()
        try database.upsertSnapshot(
            day: date(2026, 10, 1), totalAmount: 7, itemCount: 2, categories: fullBreakdown(stock: 7)
        )
        try database.upsertSnapshot(
            day: date(2026, 10, 2), totalAmount: 8, itemCount: 2, categories: fullBreakdown(stock: 8)
        )
        XCTAssertEqual(try database.snapshotCategoryRowCount(), AssetCategory.allCases.count * 2)

        try database.deleteAllSnapshots()
        XCTAssertEqual(try database.snapshotCategoryRowCount(), 0)
    }

    // MARK: - 2.1 覆盖写

    func testUpsertReplacesCategoriesInsteadOfAccumulating() throws {
        let database = try makeDatabase()
        let day = date(2026, 10, 1)

        try database.upsertSnapshot(
            day: day, totalAmount: 7, itemCount: 2, categories: fullBreakdown(stock: 5, fund: 2)
        )
        try database.upsertSnapshot(
            day: day, totalAmount: 4, itemCount: 2, categories: fullBreakdown(stock: 3, fund: 1)
        )

        let fetched = try database.fetchSnapshotCategories(for: [DayKey.string(from: day)])
        let breakdown = try XCTUnwrap(fetched[DayKey.string(from: day)])

        XCTAssertEqual(breakdown.count, AssetCategory.allCases.count, "同一天永远只有 7 行")
        XCTAssertEqual(breakdown[.stock], 3, "是覆盖，不是累加")
        XCTAssertEqual(breakdown[.fund], 1)
        XCTAssertEqual(try database.snapshotCategoryRowCount(), AssetCategory.allCases.count)

        let total = try XCTUnwrap(try database.fetchSnapshots().first?.totalAmount)
        XCTAssertEqual(breakdown.values.reduce(0, +), total, accuracy: 0.000_001, "分类合计必须等于总额")
    }

    func testClearingCategoryWritesZeroInsteadOfDroppingRow() throws {
        let database = try makeDatabase()
        let day = date(2026, 10, 1)
        try database.upsertSnapshot(
            day: day, totalAmount: 5, itemCount: 1, categories: fullBreakdown(stock: 5)
        )
        // 把股票清空，只留基金
        try database.upsertSnapshot(
            day: date(2026, 10, 2), totalAmount: 2, itemCount: 1, categories: fullBreakdown(fund: 2)
        )

        let fetched = try database.fetchSnapshotCategories(for: [DayKey.string(from: date(2026, 10, 2))])
        let breakdown = try XCTUnwrap(fetched[DayKey.string(from: date(2026, 10, 2))])
        XCTAssertEqual(breakdown[.stock], 0, "清空要写成 0，曲线才能落回零")
        XCTAssertEqual(breakdown.count, AssetCategory.allCases.count)
    }

    // MARK: - 2.3 快照上的分类字段

    func testCategoriesRoundTripThroughSnapshot() throws {
        let database = try makeDatabase()
        let day = date(2026, 10, 1)
        try database.upsertSnapshot(
            day: day, totalAmount: 7, itemCount: 2, categories: fullBreakdown(stock: 5, fund: 2)
        )

        let snapshot = try XCTUnwrap(try database.fetchSnapshots().first)
        let categories = try XCTUnwrap(snapshot.categories)
        XCTAssertEqual(categories.count, AssetCategory.allCases.count)
        XCTAssertEqual(categories[.stock], 5)
    }

    func testSnapshotWithoutCategoryDetailStaysNil() throws {
        let database = try makeDatabase()
        // 分类功能上线前的老数据：只写总额，不传 categories
        try database.upsertSnapshot(day: date(2026, 9, 1), totalAmount: 10, itemCount: 3)

        let snapshot = try XCTUnwrap(try database.fetchSnapshots().first)
        XCTAssertNil(snapshot.categories, "没有明细必须读成 nil，而不是 7 个 0")
        XCTAssertEqual(try database.snapshotCategoryRowCount(), 0)
    }
}
