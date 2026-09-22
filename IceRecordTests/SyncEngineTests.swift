import XCTest
@testable import IceRecord

/// 可控的假云端：记录推了什么、按脚本返回拉取结果。
final class MockSyncTransport: SyncTransport, @unchecked Sendable {
    var isConfigured = true
    var containerIdentifier: String? = "iCloud 键值存储（测试）"
    var state: CloudAccountState = .available
    var remoteRecords: [SyncRecord] = []
    var pushError: Error?
    var pullError: Error?
    /// 只把这些记录算作推送成功（用来模拟部分记录被云端拒绝）
    var acceptedNames: Set<String>?
    var pushFailureSummary: String?

    private(set) var pushedBatches: [[SyncRecord]] = []

    func accountState() async -> CloudAccountState { state }

    func pull(since token: Data?) async throws -> SyncPullResult {
        if let pullError { throw pullError }
        return SyncPullResult(records: remoteRecords, newToken: nil)
    }

    func push(_ records: [SyncRecord]) async throws -> SyncPushResult {
        if let pushError { throw pushError }
        pushedBatches.append(records)
        if let acceptedNames {
            return SyncPushResult(
                pushedNames: records.map(\.name).filter { acceptedNames.contains($0) },
                failureSummary: pushFailureSummary
            )
        }
        return SyncPushResult(pushedNames: records.map(\.name))
    }

    var pushedRecords: [SyncRecord] { pushedBatches.flatMap { $0 } }

    func pushedRecord(named name: String) -> SyncRecord? {
        pushedRecords.first { $0.name == name }
    }
}

/// iCloud 同步的合并语义测试。
///
/// 真实实现是 iCloud 键值存储，但这层被 `SyncTransport` 隔离掉了；
/// 「推什么、拉回来怎么合并、冲突谁赢、删除怎么传播」这些真正的逻辑都在这里被覆盖。
@MainActor
final class SyncEngineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceRecordSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(directory: directory)
    }

    /// 建一个干净起点：一条已同步的条目 + 一条已同步的今日快照
    private func makeSyncedFixture() throws -> (AppDatabase, SyncEngine, MockSyncTransport, AssetItem) {
        let database = try makeDatabase()
        let item = AssetItem(name: "股票", amount: 10.5, category: .stock, sortIndex: 0)
        try database.insert(item, synced: true)
        try database.insertSnapshot(
            dayKey: DayKey.string(from: .now),
            totalAmount: 10.5,
            itemCount: 1,
            recordedAt: .now,
            updatedAt: .now,
            synced: true
        )
        let transport = MockSyncTransport()
        let engine = SyncEngine(database: database, transport: transport)
        return (database, engine, transport, item)
    }

    // MARK: - 推送

    func testDirtyRecordsAreEmptyForAFreshlySyncedDatabase() throws {
        let (database, _, _, _) = try makeSyncedFixture()
        XCTAssertTrue(try database.fetchDirtyRecords().isEmpty)
    }

    func testLocalEditIsPushedAndDirtyFlagCleared() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()

        var edited = item
        edited.amount = 12
        edited.updatedAt = .now
        try database.update(edited)

        XCTAssertEqual(try database.fetchDirtyRecords().count, 1)

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertEqual(transport.pushedBatches.count, 1)
        let pushed = try XCTUnwrap(transport.pushedRecord(named: SyncRecord.recordName(forItemID: item.id)))
        XCTAssertEqual(pushed.double(SyncField.amount) ?? 0, 12, accuracy: 0.000_001)
        XCTAssertFalse(pushed.isDeleted)
        XCTAssertTrue(try database.fetchDirtyRecords().isEmpty, "推送成功后脏标记应被清掉")
    }

    func testLocalDeletionIsPushedAsTombstone() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()

        try database.deleteItem(id: item.id)
        XCTAssertTrue(try database.fetchItems().isEmpty, "界面上应看不到被删除的条目")

        _ = try await engine.sync()

        let pushed = try XCTUnwrap(transport.pushedRecord(named: SyncRecord.recordName(forItemID: item.id)))
        XCTAssertTrue(pushed.isDeleted, "删除应作为墓碑推送，而不是物理删除")
    }

    func testStoreMutationMarksRecordDirtyAndNotifies() throws {
        let database = try makeDatabase()
        let store = AssetStore(database: database)

        // 示例数据由空状态按钮显式写入（自动播种会和云端回灌的数据重名重复）
        store.addExampleItems()
        XCTAssertEqual(store.items.count, 2)

        let expectation = expectation(description: "本地改动通知")
        store.onLocalMutation = { expectation.fulfill() }

        try database.markRecordsSynced(try database.fetchDirtyRecords().map(\.name))
        XCTAssertTrue(try database.fetchDirtyRecords().isEmpty)

        store.addItem(name: "基金", amount: 2, category: .fund)
        wait(for: [expectation], timeout: 1)

        let dirty = try database.fetchDirtyRecords()
        XCTAssertEqual(dirty.count, 2, "新增条目 + 新的今日快照都应该是脏的")
        XCTAssertTrue(dirty.contains { $0.kind == .item })
        XCTAssertTrue(dirty.contains { $0.kind == .snapshot })
    }

    // MARK: - 合并（last-writer-wins）

    func testRemoteRecordIsInsertedWhenMissingLocally() async throws {
        let (database, engine, transport, _) = try makeSyncedFixture()
        let remoteID = UUID()
        transport.remoteRecords = [
            .item(
                id: remoteID,
                name: "黄金",
                amount: 3.5,
                category: .other,
                note: "",
                sortIndex: 1,
                createdAt: .now,
                updatedAt: .now,
                isDeleted: false
            )
        ]

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.pulled, 1)
        XCTAssertEqual(outcome.applied, 1)
        XCTAssertTrue(outcome.didChangeLocalData)
        let items = try database.fetchItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first { $0.id == remoteID }?.name, "黄金")
        XCTAssertTrue(try database.fetchDirtyRecords().isEmpty, "拉下来的记录不应再被推回去")
    }

    func testRemoteNewerVersionOverwritesLocal() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()
        let localTime = Date(timeIntervalSince1970: 1_000)
        let remoteTime = Date(timeIntervalSince1970: 2_000)

        var local = item
        local.amount = 10
        local.updatedAt = localTime
        try database.update(local)
        try database.markRecordsSynced([SyncRecord.recordName(forItemID: item.id)])

        transport.remoteRecords = [
            .item(
                id: item.id,
                name: "股票",
                amount: 20,
                category: .stock,
                note: "远端改的",
                sortIndex: 0,
                createdAt: item.createdAt,
                updatedAt: remoteTime,
                isDeleted: false
            )
        ]

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.applied, 1)
        let stored = try XCTUnwrap(database.fetchItems().first { $0.id == item.id })
        XCTAssertEqual(stored.amount, 20, accuracy: 0.000_001, "远端更新，应该覆盖本地")
        XCTAssertEqual(stored.note, "远端改的")
    }

    func testLocalNewerVersionIsKept() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()
        let remoteTime = Date(timeIntervalSince1970: 1_000)
        let localTime = Date(timeIntervalSince1970: 2_000)

        var local = item
        local.amount = 99
        local.updatedAt = localTime
        try database.update(local)

        transport.remoteRecords = [
            .item(
                id: item.id,
                name: "股票",
                amount: 1,
                category: .stock,
                note: "",
                sortIndex: 0,
                createdAt: item.createdAt,
                updatedAt: remoteTime,
                isDeleted: false
            )
        ]

        _ = try await engine.sync()

        let stored = try XCTUnwrap(database.fetchItems().first { $0.id == item.id })
        XCTAssertEqual(stored.amount, 99, accuracy: 0.000_001, "本地更新，不应被旧数据覆盖")
        XCTAssertEqual(
            transport.pushedRecord(named: SyncRecord.recordName(forItemID: item.id))?.double(SyncField.amount) ?? 0,
            99,
            accuracy: 0.000_001,
            "本地版本应该被推上去"
        )
    }

    func testRemoteDeletionPropagatesLocally() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()

        transport.remoteRecords = [
            .item(
                id: item.id,
                name: item.name,
                amount: item.amount,
                category: item.category,
                note: "",
                sortIndex: 0,
                createdAt: item.createdAt,
                updatedAt: Date(timeIntervalSince1970: item.updatedAt.timeIntervalSince1970 + 1_000),
                isDeleted: true
            )
        ]

        _ = try await engine.sync()

        XCTAssertTrue(try database.fetchItems().isEmpty, "远端删除应传播到本地")
    }

    func testSnapshotMergesByDay() async throws {
        let (database, engine, transport, _) = try makeSyncedFixture()
        let dayKey = DayKey.string(from: DayKey.calendar.date(byAdding: .day, value: -3, to: .now)!)

        transport.remoteRecords = [
            .snapshot(
                dayKey: dayKey,
                totalAmount: 42,
                itemCount: 3,
                recordedAt: .now,
                updatedAt: .now,
                isDeleted: false
            )
        ]

        _ = try await engine.sync()

        let snapshots = try database.fetchSnapshots()
        let merged = try XCTUnwrap(snapshots.first { $0.dayKey == dayKey })
        XCTAssertEqual(merged.totalAmount, 42, accuracy: 0.000_001)
        XCTAssertEqual(merged.itemCount, 3)
    }

    func testTodaySnapshotUsesLastWriterWins() async throws {
        let (database, engine, transport, _) = try makeSyncedFixture()
        let todayKey = DayKey.string(from: .now)

        transport.remoteRecords = [
            .snapshot(
                dayKey: todayKey,
                totalAmount: 777,
                itemCount: 9,
                recordedAt: .now,
                // 远端时间更晚 → 应该赢
                updatedAt: Date(timeIntervalSince1970: Date.now.timeIntervalSince1970 + 600),
                isDeleted: false
            )
        ]

        _ = try await engine.sync()

        let today = try XCTUnwrap(database.fetchSnapshots().first { $0.dayKey == todayKey })
        XCTAssertEqual(today.totalAmount, 777, accuracy: 0.000_001)
    }

    // MARK: - 部分记录被云端拒绝

    func testRecordsRejectedByServerStayDirtyAndDoNotBlockSync() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()

        var edited = item
        edited.amount = 12
        edited.updatedAt = .now
        try database.update(edited)
        // 再让今日快照也变脏，这样一次要推两条
        try database.upsertSnapshot(day: DayKey.startOfDay(.now), totalAmount: 12, itemCount: 1)

        // 云端只接受快照，拒绝条目
        let itemRecordName = SyncRecord.recordName(forItemID: item.id)
        transport.acceptedNames = Set(
            try database.fetchDirtyRecords().map(\.name).filter { $0 != itemRecordName }
        )
        transport.pushFailureSummary = "1/2 条记录被云端拒绝"
        transport.remoteRecords = [
            .snapshot(
                dayKey: DayKey.string(from: DayKey.calendar.date(byAdding: .day, value: -2, to: .now)!),
                totalAmount: 5,
                itemCount: 1,
                recordedAt: .now,
                updatedAt: .now,
                isDeleted: false
            )
        ]

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertEqual(outcome.pushFailureSummary, "1/2 条记录被云端拒绝")
        XCTAssertEqual(outcome.applied, 1, "推送部分失败不应该阻断后续拉取")
        let dirty = try database.fetchDirtyRecords()
        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty.first?.name, itemRecordName, "被拒绝的记录要留在脏列表里等下次重试")
    }

    // MARK: - 账号状态

    /// iCloud 不可用（没登录 / 云盘没开）时应该整轮跳过：
    /// 一个字都不动本地数据，脏标记保留，等 iCloud 可用了整批补传。
    func testUnavailableAccountSkipsSyncAndKeepsChangesDirty() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()
        transport.state = .noAccount

        var edited = item
        edited.amount = 55
        edited.updatedAt = .now
        try database.update(edited)

        do {
            _ = try await engine.sync()
            XCTFail("iCloud 不可用时应该抛 accountUnavailable")
        } catch let error as SyncError {
            guard case .accountUnavailable = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }

        XCTAssertTrue(transport.pushedBatches.isEmpty, "iCloud 不可用时不应该推送")
        XCTAssertEqual(try database.fetchDirtyRecords().count, 1, "脏数据要保留，等下次再推")
        XCTAssertEqual(try database.fetchItems().first?.amount ?? 0, 55, accuracy: 0.000_001)
    }

    func testPushFailureKeepsRecordsDirty() async throws {
        let (database, engine, transport, item) = try makeSyncedFixture()
        transport.pushError = SyncError.transport("存储不可用")

        var edited = item
        edited.amount = 8
        edited.updatedAt = .now
        try database.update(edited)

        do {
            _ = try await engine.sync()
            XCTFail("推送失败应该抛错")
        } catch {
            // 预期
        }

        XCTAssertEqual(try database.fetchDirtyRecords().count, 1, "推送失败时不能清脏标记，否则会丢改动")
    }

    func testDisabledTransportReportsNotConfigured() async throws {
        let transport = DisabledSyncTransport()
        XCTAssertFalse(transport.isConfigured)
        let state = await transport.accountState()
        XCTAssertEqual(state, .notConfigured)

        let engine = SyncEngine(database: try makeDatabase(), transport: transport)
        do {
            _ = try await engine.sync()
            XCTFail("没开启同步时应该抛 notConfigured")
        } catch let error as SyncError {
            guard case .notConfigured = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        }
    }

    // MARK: - 数据库层

    func testTombstonedRowsAreHiddenFromQueries() throws {
        let database = try makeDatabase()
        let item = AssetItem(name: "股票", amount: 1, category: .stock)
        try database.insert(item)
        XCTAssertEqual(try database.itemCount(), 1)

        try database.deleteItem(id: item.id)
        XCTAssertEqual(try database.itemCount(), 0)
        XCTAssertTrue(try database.fetchItems().isEmpty)

        // 墓碑行还在，用于同步
        XCTAssertEqual(try database.fetchDirtyRecords().count, 1)
    }

    func testMigrationAddsSyncColumnsOnExistingDatabase() throws {
        let database = try makeDatabase()
        try database.insert(AssetItem(name: "旧数据", amount: 5, category: .other))

        // 同目录重新打开（迁移已经跑过，不应报错也不应丢数据）
        let reopened = try AppDatabase(directory: directory)
        XCTAssertEqual(try reopened.itemCount(), 1)
        XCTAssertEqual(try reopened.fetchItems().first?.name, "旧数据")
    }
}
