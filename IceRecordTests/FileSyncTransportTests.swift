import XCTest
@testable import IceRecord

/// 文件同步 transport 的测试。
///
/// 用本地临时目录当「云盘」，跑真实的编解码、**按年分片**、指纹增量和 LWW 合并逻辑。
/// iCloud 云盘的真机行为没法在测试里伪造，但这一层之外没有别的业务逻辑了。
final class FileSyncTransportTests: XCTestCase {

    private var cloudDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        cloudDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceRecordCloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let cloudDirectory { try? FileManager.default.removeItem(at: cloudDirectory) }
        try super.tearDownWithError()
    }

    private func makeStore() -> LocalDirectoryFileStore {
        LocalDirectoryFileStore(directory: cloudDirectory, locationDescription: "测试云盘")
    }

    private func makeTransport() -> FileSyncTransport {
        FileSyncTransport(store: makeStore())
    }

    private func itemRecord(
        id: UUID = UUID(),
        name: String = "股票",
        amount: Double = 10.5,
        updatedAt: Date,
        isDeleted: Bool = false
    ) -> SyncRecord {
        .item(
            id: id,
            name: name,
            amount: amount,
            category: .stock,
            note: "备注",
            sortIndex: 3,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }

    private func snapshotRecord(dayKey: String, total: Double, updatedAt: Date) -> SyncRecord {
        .snapshot(
            dayKey: dayKey,
            totalAmount: total,
            itemCount: 2,
            recordedAt: Date(timeIntervalSince1970: 200),
            updatedAt: updatedAt,
            isDeleted: false
        )
    }

    private func filesOnCloud() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: cloudDirectory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    // MARK: - 分片规则

    func testRecordsAreShardedByYear() async throws {
        let transport = makeTransport()
        let records = [
            itemRecord(updatedAt: .now),
            snapshotRecord(dayKey: "2024-12-31", total: 1, updatedAt: .now),
            snapshotRecord(dayKey: "2025-01-01", total: 2, updatedAt: .now),
            snapshotRecord(dayKey: "2025-06-15", total: 3, updatedAt: .now),
            snapshotRecord(dayKey: "2026-09-22", total: 4, updatedAt: .now)
        ]

        _ = try await transport.push(records)

        XCTAssertEqual(
            try filesOnCloud(),
            ["items.json.deflate", "snapshots-2024.json.deflate", "snapshots-2025.json.deflate", "snapshots-2026.json.deflate"],
            "快照应该按年分片，条目单独一个文件"
        )
    }

    /// 一年一个文件的核心好处：改 2026 年的一天，不该重写 2025 年的文件
    func testOnlyTheTouchedYearIsRewritten() async throws {
        let transport = makeTransport()
        _ = try await transport.push([
            snapshotRecord(dayKey: "2025-06-15", total: 1, updatedAt: Date(timeIntervalSince1970: 1_000)),
            snapshotRecord(dayKey: "2026-09-22", total: 2, updatedAt: Date(timeIntervalSince1970: 1_000))
        ])

        let file2025 = cloudDirectory.appendingPathComponent("snapshots-2025.json.deflate")
        let before2025 = try FileManager.default.attributesOfItem(atPath: file2025.path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(1_100))
        _ = try await transport.push([
            snapshotRecord(dayKey: "2026-09-23", total: 3, updatedAt: Date(timeIntervalSince1970: 2_000))
        ])

        let after2025 = try FileManager.default.attributesOfItem(atPath: file2025.path)[.modificationDate] as? Date
        XCTAssertEqual(before2025, after2025, "没有改动的年份不应该被重写")
    }

    func testEachYearFileStaysSmall() async throws {
        let transport = makeTransport()
        // 一整年的每日快照
        let records = (0..<365).map { offset -> SyncRecord in
            let day = DayKey.calendar.date(byAdding: .day, value: offset, to: Date(timeIntervalSince1970: 1_767_225_600))!
            return snapshotRecord(dayKey: DayKey.string(from: day), total: 20 + Double(offset) / 100, updatedAt: day)
        }
        _ = try await transport.push(records)

        let files = try filesOnCloud()
        XCTAssertFalse(files.isEmpty)
        for name in files {
            let size = try XCTUnwrap(try makeStore().read(name)).count
            XCTAssertLessThan(size, 50_000, "\(name) 体积 \(size) 字节，单年文件应该很小")
            print("一年 365 天快照 → \(name)：\(size) 字节")
        }
    }

    // MARK: - 往返

    func testPushThenPullRoundTrips() async throws {
        let id = UUID()
        _ = try await makeTransport().push([
            itemRecord(id: id, amount: 12.34, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            snapshotRecord(dayKey: "2026-09-22", total: 14.3, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])

        // 换一个 transport 实例 + 空索引，模拟「另一台设备」
        let pulled = try await makeTransport().pull(since: nil)

        XCTAssertEqual(pulled.records.count, 2)
        let item = try XCTUnwrap(pulled.records.first { $0.kind == .item })
        XCTAssertEqual(item.itemID, id)
        XCTAssertEqual(item.double(SyncField.amount) ?? 0, 12.34, accuracy: 0.000_001)
        XCTAssertEqual(item.string(SyncField.category), AssetCategory.stock.rawValue)
        XCTAssertEqual(item.date(SyncField.createdAt)?.timeIntervalSince1970 ?? 0, 100, accuracy: 0.001)

        let snapshot = try XCTUnwrap(pulled.records.first { $0.kind == .snapshot })
        XCTAssertEqual(snapshot.dayKey, "2026-09-22")
        XCTAssertEqual(snapshot.double(SyncField.totalAmount) ?? 0, 14.3, accuracy: 0.000_001)
    }

    // MARK: - 增量（指纹）

    func testUnchangedFilesAreSkippedOnSecondPull() async throws {
        // 先由「另一台设备」写上去
        _ = try await makeTransport().push([snapshotRecord(dayKey: "2026-09-22", total: 1, updatedAt: .now)])

        // 新实例、没有索引 → 应该读到
        let first = try await makeTransport().pull(since: nil)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertNotNil(first.newToken)

        // 带着上一轮的索引再拉：文件指纹没变，一条都不该返回
        let second = try await makeTransport().pull(since: first.newToken)
        XCTAssertTrue(second.records.isEmpty, "文件指纹没变就不该再下载解码")

        // 索引可以跨实例复用（持久化在 sync_state 里）
        let third = try await makeTransport().pull(since: second.newToken)
        XCTAssertTrue(third.records.isEmpty)
    }

    /// push 刚写过的文件，紧接着的 pull 不应该把内容再下载一遍
    func testPullRightAfterPushDoesNotRereadOwnWrite() async throws {
        let transport = makeTransport()
        _ = try await transport.push([snapshotRecord(dayKey: "2026-09-22", total: 1, updatedAt: .now)])

        let pulled = try await transport.pull(since: nil)
        XCTAssertTrue(pulled.records.isEmpty, "自己刚写的文件不该被自己重读")
    }

    func testNewFileIsPickedUpEvenWithOldIndex() async throws {
        let deviceA = makeTransport()
        _ = try await deviceA.push([snapshotRecord(dayKey: "2025-01-01", total: 1, updatedAt: .now)])
        let index = try await deviceA.pull(since: nil).newToken

        // 另一台设备新增了 2026 年的文件
        let deviceB = makeTransport()
        _ = try await deviceB.push([snapshotRecord(dayKey: "2026-09-22", total: 9, updatedAt: .now)])

        // A 带着旧索引再拉，应该只拿到新增年份的数据
        let pulled = try await deviceA.pull(since: index)
        XCTAssertEqual(pulled.records.count, 1)
        XCTAssertEqual(pulled.records.first?.dayKey, "2026-09-22")
    }

    // MARK: - 合并

    func testNewerRemoteRecordSurvivesPush() async throws {
        let id = UUID()
        _ = try await makeTransport().push([
            itemRecord(id: id, name: "远端版", amount: 20, updatedAt: Date(timeIntervalSince1970: 2_000))
        ])

        _ = try await makeTransport().push([
            itemRecord(id: id, name: "本机旧版", amount: 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        ])

        let pulled = try await makeTransport().pull(since: nil)
        XCTAssertEqual(pulled.records.count, 1, "同一条记录不应该变成两条")
        XCTAssertEqual(pulled.records.first?.string(SyncField.name), "远端版", "更新的一方必须赢")
    }

    func testNewerLocalRecordOverwritesRemote() async throws {
        let id = UUID()
        _ = try await makeTransport().push([
            itemRecord(id: id, name: "旧版本", amount: 1, updatedAt: Date(timeIntervalSince1970: 1_000))
        ])
        _ = try await makeTransport().push([
            itemRecord(id: id, name: "新版本", amount: 99, updatedAt: Date(timeIntervalSince1970: 2_000))
        ])

        let pulled = try await makeTransport().pull(since: nil)
        XCTAssertEqual(pulled.records.count, 1)
        XCTAssertEqual(pulled.records.first?.string(SyncField.name), "新版本")
    }

    func testTombstoneIsPreserved() async throws {
        let id = UUID()
        _ = try await makeTransport().push([
            itemRecord(id: id, amount: 5, updatedAt: Date(timeIntervalSince1970: 1_000))
        ])
        _ = try await makeTransport().push([
            itemRecord(id: id, amount: 5, updatedAt: Date(timeIntervalSince1970: 2_000), isDeleted: true)
        ])

        let pulled = try await makeTransport().pull(since: nil)
        XCTAssertEqual(pulled.records.count, 1)
        XCTAssertTrue(try XCTUnwrap(pulled.records.first).isDeleted)
    }

    func testTwoDevicesDoNotLoseEachOthersRecords() async throws {
        let idA = UUID()
        let idB = UUID()
        _ = try await makeTransport().push([itemRecord(id: idA, name: "A 的条目", updatedAt: .now)])
        _ = try await makeTransport().push([itemRecord(id: idB, name: "B 的条目", updatedAt: .now)])

        let pulled = try await makeTransport().pull(since: nil)
        XCTAssertEqual(pulled.records.count, 2, "两台设备的条目都要在")
    }

    // MARK: - 容错

    func testCorruptFileIsTreatedAsEmpty() async throws {
        try Data("这不是压缩数据".utf8)
            .write(to: cloudDirectory.appendingPathComponent(SyncFileLayout.itemsFileName))

        let pulled = try await makeTransport().pull(since: nil)
        XCTAssertTrue(pulled.records.isEmpty, "坏文件不能抛错，否则同步会永久卡死")

        // 之后一次正常推送应该能把文件重建起来
        _ = try await makeTransport().push([itemRecord(updatedAt: .now)])
        let rebuilt = try await makeTransport().pull(since: nil)
        XCTAssertEqual(rebuilt.records.count, 1)
    }

    func testUnavailableStoreReportsNoAccount() async {
        let store = LocalDirectoryFileStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)")
        )
        try? FileManager.default.removeItem(at: store.directory)

        let transport = FileSyncTransport(store: store)
        let state = await transport.accountState()
        XCTAssertEqual(state, .noAccount)
    }

    // MARK: - 文件名规则

    func testFileLayoutRules() {
        XCTAssertEqual(
            SyncFileLayout.fileName(for: itemRecord(updatedAt: .now)),
            "items.json.deflate"
        )
        XCTAssertEqual(
            SyncFileLayout.fileName(for: snapshotRecord(dayKey: "2026-09-22", total: 1, updatedAt: .now)),
            "snapshots-2026.json.deflate"
        )
        XCTAssertEqual(SyncFileLayout.year(fromDayKey: "2024-01-05"), 2024)
        XCTAssertNil(SyncFileLayout.year(fromDayKey: "bad-key"))
        XCTAssertNil(SyncFileLayout.fileName(for: snapshotRecord(dayKey: "bad-key", total: 1, updatedAt: .now)))
    }
}
