import XCTest
@testable import IceRecord

/// 数据库与 Store 的行为测试。
///
/// 重点验证需求里的这条约定：
/// **每次修改条目都会立刻重算「今天」的总资产，并写进 SQLite；同一天只保留一条记录。**
final class AssetStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    @MainActor
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(directory: directory)
    }

    /// 建好 store 并写入示例数据。
    /// 现在**不会自动播种**（自动播种会在重装 App 时和云端回灌的数据重名重复），
    /// 示例数据由空状态里的按钮显式触发，所以测试里也要显式调一次。
    @MainActor
    private func makeSeededStore(_ database: AppDatabase) -> AssetStore {
        let store = AssetStore(database: database)
        store.addExampleItems()
        return store
    }

    // MARK: - 建表 & 迁移

    @MainActor
    func testSchemaIsCreatedAndVersionIsOne() throws {
        let database = try makeDatabase()
        XCTAssertEqual(try database.itemCount(), 0)
        XCTAssertEqual(try database.snapshotCount(), 0)
        XCTAssertEqual(try database.fetchItems().count, 0)
        XCTAssertEqual(try database.fetchSnapshots().count, 0)
    }

    /// 同一个数据库文件重复打开不应重复建表或丢数据
    @MainActor
    func testReopeningSameFileKeepsData() throws {
        let first = try makeDatabase()
        try first.insert(AssetItem(name: "股票", amount: 10.5, category: .stock))
        try first.upsertSnapshot(day: DayKey.startOfDay(.now), totalAmount: 10.5, itemCount: 1)

        let second = try makeDatabase()
        XCTAssertEqual(try second.fetchItems().count, 1)
        XCTAssertEqual(try second.fetchSnapshots().count, 1)
        XCTAssertEqual(try second.fetchSnapshots().first?.totalAmount ?? 0, 10.5, accuracy: 0.000_001)
    }

    // MARK: - 首次启动的示例数据

    @MainActor
    func testFirstLaunchSeedsItemsAndRecordsTodaysSnapshot() throws {
        let store = makeSeededStore(try makeDatabase())

        XCTAssertEqual(store.items.count, 2, "首次启动应写入两条示例条目")
        XCTAssertEqual(store.totalAmount, 11.8, accuracy: 0.000_001)
        XCTAssertEqual(store.snapshots.count, 1, "首次启动应记录今天的快照")
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? 0, 11.8, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.itemCount, 2)
        XCTAssertTrue(store.isTodayRecorded)
    }

    @MainActor
    func testAddExampleItemsOnlyAppliesToAnEmptyList() throws {
        let database = try makeDatabase()
        let store = makeSeededStore(database)
        XCTAssertEqual(store.items.count, 2)

        // 列表非空时再点一次，不应该出现重复条目
        store.addExampleItems()
        XCTAssertEqual(store.items.count, 2, "已经有条目时不应重复写入示例数据")
        XCTAssertEqual(Set(store.items.map(\.id)).count, 2, "id 不能重复")

        // 清空之后重新点，是允许的（按钮本来就只出现在空状态里）
        store.deleteItems(withIDs: store.items.map(\.id))
        XCTAssertEqual(store.items.count, 0)
        store.addExampleItems()
        XCTAssertEqual(store.items.count, 2)
    }

    /// 回归：iCloud 上的数据会回灌，播种必须发生在第一次同步**之后**，
    /// 否则重装 App 时示例条目会和同步回来的条目重名重复。
    @MainActor
    func testAddExampleItemsIsSkippedWhenDataExists() throws {
        let database = try makeDatabase()
        // 模拟「同步已经把云端数据拉回来了」
        try database.insert(
            AssetItem(name: "股票", amount: 88, category: .stock, sortIndex: 0),
            synced: true
        )
        try database.insertSnapshot(
            dayKey: DayKey.string(from: .now),
            totalAmount: 88,
            itemCount: 1,
            recordedAt: .now,
            updatedAt: .now,
            synced: true
        )

        let store = AssetStore(database: database)
        store.addExampleItems()

        XCTAssertEqual(store.items.count, 1, "已经有数据时点「添加示例条目」不应该重复写入")
        XCTAssertEqual(store.items.first?.amount ?? 0, 88, accuracy: 0.000_001)
    }

    // MARK: - 核心：每次修改都会更新当日快照

    @MainActor
    func testAddItemUpdatesTodaysSnapshotInPlace() throws {
        let database = try makeDatabase()
        let store = makeSeededStore(database)
        let originalRecordedAt = try XCTUnwrap(store.todaySnapshot?.recordedAt)

        store.addItem(name: "基金", amount: 2.5, category: .fund)

        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.totalAmount, 14.3, accuracy: 0.000_001)
        XCTAssertEqual(store.snapshots.count, 1, "同一天多次修改只应保留一条快照")
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? 0, 14.3, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.itemCount, 3)

        let snapshot = try XCTUnwrap(store.todaySnapshot)
        XCTAssertEqual(snapshot.recordedAt.timeIntervalSince1970,
                       originalRecordedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "首次记录时间不应被覆盖")
        XCTAssertGreaterThanOrEqual(snapshot.updatedAt, snapshot.recordedAt)

        // 落库校验
        let persisted = try XCTUnwrap(database.fetchSnapshots().first)
        XCTAssertEqual(persisted.totalAmount, 14.3, accuracy: 0.000_001)
        XCTAssertEqual(DayKey.string(from: persisted.day), DayKey.string(from: .now))
    }

    @MainActor
    func testUpdateItemRecomputesTotal() throws {
        let store = makeSeededStore(try makeDatabase())
        let stock = try XCTUnwrap(store.items.first { $0.name == "股票" })

        store.updateItem(id: stock.id, name: "股票", amount: 20, category: .stock, note: "加仓")

        XCTAssertEqual(store.totalAmount, 21.3, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? 0, 21.3, accuracy: 0.000_001)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.items.first { $0.id == stock.id }?.note, "加仓")
    }

    @MainActor
    func testDeleteItemRecomputesTotal() throws {
        let store = makeSeededStore(try makeDatabase())
        let cash = try XCTUnwrap(store.items.first { $0.name == "流动资金" })

        store.deleteItem(cash)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.totalAmount, 10.5, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? 0, 10.5, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.itemCount, 1)
    }

    @MainActor
    func testDeleteAllItemsRecordsZeroTotal() throws {
        let store = makeSeededStore(try makeDatabase())
        store.deleteItems(withIDs: store.items.map(\.id))

        XCTAssertEqual(store.totalAmount, 0, accuracy: 0.000_001)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? -1, 0, accuracy: 0.000_001)
        XCTAssertEqual(store.todaySnapshot?.itemCount, 0)
    }

    @MainActor
    func testManualRecordSnapshotForToday() throws {
        let store = makeSeededStore(try makeDatabase())
        store.recordSnapshotForToday()

        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.todaySnapshot?.totalAmount ?? 0, 11.8, accuracy: 0.000_001)
    }

    @MainActor
    func testEarlierDaysAreNeverTouchedByTodaysEdits() throws {
        let database = try makeDatabase()
        _ = makeSeededStore(database)

        // 手工补一条昨天的历史记录
        let yesterday = try XCTUnwrap(
            DayKey.calendar.date(byAdding: .day, value: -1, to: DayKey.startOfDay(.now))
        )
        try database.upsertSnapshot(day: yesterday, totalAmount: 5, itemCount: 1)

        let reloaded = AssetStore(database: database)
        reloaded.addItem(name: "黄金", amount: 1, category: .other)

        let yesterdayRow = try XCTUnwrap(
            reloaded.snapshots.first { DayKey.string(from: $0.day) == DayKey.string(from: yesterday) }
        )
        XCTAssertEqual(yesterdayRow.totalAmount, 5, accuracy: 0.000_001, "历史记录不应被今天的修改覆盖")
        XCTAssertEqual(reloaded.snapshots.count, 2)
        XCTAssertEqual(reloaded.todaySnapshot?.totalAmount ?? 0, 12.8, accuracy: 0.000_001)
    }

    @MainActor
    func testChangeSincePreviousSnapshot() throws {
        let database = try makeDatabase()
        let store = makeSeededStore(database)
        XCTAssertNil(store.changeSincePreviousSnapshot, "只有一天记录时没有可比对象")

        let yesterday = try XCTUnwrap(
            DayKey.calendar.date(byAdding: .day, value: -1, to: DayKey.startOfDay(.now))
        )
        try database.upsertSnapshot(day: yesterday, totalAmount: 10, itemCount: 2)

        let reloaded = AssetStore(database: database)
        XCTAssertEqual(reloaded.changeSincePreviousSnapshot ?? 0, 1.8, accuracy: 0.000_001)
        XCTAssertEqual(reloaded.changeRatioSincePreviousSnapshot ?? 0, 18, accuracy: 0.000_001)
    }

    @MainActor
    func testReorderingPersists() throws {
        let database = try makeDatabase()
        let store = makeSeededStore(database)
        let namesBefore = store.items.map(\.name)

        store.moveItems(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(store.items.map(\.name), namesBefore.reversed().map { $0 })
        let reloaded = AssetStore(database: database)
        XCTAssertEqual(reloaded.items.map(\.name), namesBefore.reversed().map { $0 },
                       "排序结果应持久化到数据库")
    }

    @MainActor
    func testCategoryTotals() throws {
        let store = makeSeededStore(try makeDatabase())
        let totals = store.categoryTotals
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.first?.category, .stock)
        XCTAssertEqual(totals.first?.amount ?? 0, 10.5, accuracy: 0.000_001)
    }
}
