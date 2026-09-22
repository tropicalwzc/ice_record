import Foundation

/// 本地 SQLite 库。所有访问都发生在主线程 / 主 actor 上，避免并发访问同一个连接。
@MainActor
final class AppDatabase {

    static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("无法初始化本地数据库：\(error.localizedDescription)")
        }
    }()

    private let db: SQLiteDatabase

    /// 数据库文件位置
    var fileURL: URL { URL(fileURLWithPath: db.path) }

    init(directory: URL? = nil) throws {
        let folder = try directory ?? Self.makeDefaultDirectory()
        let url = folder.appendingPathComponent("IceRecord.sqlite", isDirectory: false)
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("PRAGMA foreign_keys = ON;")
        try database.execute("PRAGMA journal_mode = WAL;")
        try database.execute("PRAGMA synchronous = NORMAL;")
        self.db = database
        try migrate()
    }

    private static func makeDefaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("IceRecord", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    // MARK: - 建表 / 迁移

    private static let schemaV1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS asset_item (
            id          TEXT    PRIMARY KEY NOT NULL,
            name        TEXT    NOT NULL,
            amount      REAL    NOT NULL DEFAULT 0,
            category     TEXT    NOT NULL DEFAULT 'other',
            note        TEXT    NOT NULL DEFAULT '',
            sort_index  INTEGER NOT NULL DEFAULT 0,
            created_at  REAL    NOT NULL,
            updated_at  REAL    NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS asset_snapshot (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            day           TEXT    NOT NULL UNIQUE,
            total_amount  REAL    NOT NULL,
            item_count    INTEGER NOT NULL DEFAULT 0,
            recorded_at   REAL    NOT NULL,
            updated_at    REAL    NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_snapshot_day ON asset_snapshot(day);",
        """
        CREATE TABLE IF NOT EXISTS app_meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """
    ]

    /// v2：加上 iCloud 同步需要的元数据。
    /// - `deleted_at`：墓碑。删除不做物理删除，否则离线设备无法得知「这里被删了」。
    /// - `sync_dirty`：本地有未推送的改动。
    private static let schemaV2: [String] = [
        "ALTER TABLE asset_item ADD COLUMN deleted_at REAL;",
        "ALTER TABLE asset_item ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1;",
        "ALTER TABLE asset_snapshot ADD COLUMN deleted_at REAL;",
        "ALTER TABLE asset_snapshot ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1;",
        """
        CREATE TABLE IF NOT EXISTS sync_state (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_item_dirty ON asset_item(sync_dirty);",
        "CREATE INDEX IF NOT EXISTS idx_snapshot_dirty ON asset_snapshot(sync_dirty);"
    ]

    private func migrate() throws {
        let version = try userVersion()
        if version < 1 {
            try db.transaction {
                for statement in Self.schemaV1 {
                    try db.execute(statement)
                }
            }
            try setUserVersion(1)
        }
        if version < 2 {
            try db.transaction {
                for statement in Self.schemaV2 {
                    try db.execute(statement)
                }
            }
            try setUserVersion(2)
        }
    }

    private func userVersion() throws -> Int {
        try db.scalar("PRAGMA user_version;") { $0.int(0) } ?? 0
    }

    private func setUserVersion(_ version: Int) throws {
        try db.execute("PRAGMA user_version = \(version);")
    }

    // MARK: - 条目的读写

    func fetchItems() throws -> [AssetItem] {
        try db.query(
            """
            SELECT id, name, amount, category, note, sort_index, created_at, updated_at
            FROM asset_item
            WHERE deleted_at IS NULL
            ORDER BY sort_index ASC, created_at ASC
            """
        ) { row in
            AssetItem(
                id: UUID(uuidString: row.text(0)) ?? UUID(),
                name: row.text(1),
                amount: row.double(2),
                category: AssetCategory(rawValue: row.text(3)) ?? .other,
                note: row.text(4),
                sortIndex: row.int(5),
                createdAt: row.date(6),
                updatedAt: row.date(7)
            )
        }
    }

    func insert(_ item: AssetItem) throws {
        try db.run(
            """
            INSERT INTO asset_item (id, name, amount, category, note, sort_index, created_at, updated_at, deleted_at, sync_dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 1)
            """,
            [
                .text(item.id.uuidString),
                .text(item.name),
                .real(item.amount),
                .text(item.category.rawValue),
                .text(item.note),
                .int(item.sortIndex),
                .date(item.createdAt),
                .date(item.updatedAt)
            ]
        )
    }

    /// 插入一条已经与云端一致的记录（拉取远端数据时用）
    func insert(_ item: AssetItem, synced: Bool) throws {
        guard synced else {
            try insert(item)
            return
        }
        try db.run(
            """
            INSERT INTO asset_item (id, name, amount, category, note, sort_index, created_at, updated_at, deleted_at, sync_dirty)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 0)
            """,
            [
                .text(item.id.uuidString),
                .text(item.name),
                .real(item.amount),
                .text(item.category.rawValue),
                .text(item.note),
                .int(item.sortIndex),
                .date(item.createdAt),
                .date(item.updatedAt)
            ]
        )
    }

    func update(_ item: AssetItem) throws {
        try db.run(
            """
            UPDATE asset_item
            SET name = ?, amount = ?, category = ?, note = ?, updated_at = ?, sync_dirty = 1
            WHERE id = ?
            """,
            [
                .text(item.name),
                .real(item.amount),
                .text(item.category.rawValue),
                .text(item.note),
                .date(item.updatedAt),
                .text(item.id.uuidString)
            ]
        )
    }

    /// 墓碑删除：保留行以便把删除同步出去，界面上通过 `deleted_at IS NULL` 过滤掉。
    func deleteItem(id: UUID, at moment: Date = .now) throws {
        try db.run(
            "UPDATE asset_item SET deleted_at = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?",
            [.date(moment), .date(moment), .text(id.uuidString)]
        )
    }

    /// 把数组顺序写回 sort_index（下标即目标顺序）
    func updateSortIndexes(_ items: [AssetItem]) throws {
        try db.transaction {
            for (index, item) in items.enumerated() {
                try db.run(
                    "UPDATE asset_item SET sort_index = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?",
                    [.int(index), .date(.now), .text(item.id.uuidString)]
                )
            }
        }
    }

    func itemCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM asset_item WHERE deleted_at IS NULL;") { $0.int(0) } ?? 0
    }

    // MARK: - 快照的读写

    /// 写入/更新某个自然日的总资产（同一天只保留一条，重复记录覆盖）。
    func upsertSnapshot(day: Date, totalAmount: Double, itemCount: Int, at moment: Date = .now) throws {
        try db.run(
            """
            INSERT INTO asset_snapshot (day, total_amount, item_count, recorded_at, updated_at, deleted_at, sync_dirty)
            VALUES (?, ?, ?, ?, ?, NULL, 1)
            ON CONFLICT(day) DO UPDATE SET
                total_amount = excluded.total_amount,
                item_count   = excluded.item_count,
                updated_at   = excluded.updated_at,
                deleted_at   = NULL,
                sync_dirty   = 1
            """,
            [
                .text(DayKey.string(from: day)),
                .real(totalAmount),
                .int(itemCount),
                .date(moment),
                .date(moment)
            ]
        )
    }

    func fetchSnapshots() throws -> [AssetSnapshot] {
        try db.query(
            """
            SELECT id, day, total_amount, item_count, recorded_at, updated_at
            FROM asset_snapshot
            WHERE deleted_at IS NULL
            ORDER BY day ASC
            """
        ) { row in
            let rawDay = row.text(1)
            return AssetSnapshot(
                id: row.int64(0),
                day: DayKey.date(from: rawDay) ?? DayKey.startOfDay(.now),
                totalAmount: row.double(2),
                itemCount: row.int(3),
                recordedAt: row.date(4),
                updatedAt: row.date(5)
            )
        }
    }

    /// 拉取远端数据时插入一条已经同步过的快照
    func insertSnapshot(
        dayKey: String,
        totalAmount: Double,
        itemCount: Int,
        recordedAt: Date,
        updatedAt: Date,
        synced: Bool
    ) throws {
        try db.run(
            """
            INSERT INTO asset_snapshot (day, total_amount, item_count, recorded_at, updated_at, deleted_at, sync_dirty)
            VALUES (?, ?, ?, ?, ?, NULL, ?)
            ON CONFLICT(day) DO UPDATE SET
                total_amount = excluded.total_amount,
                item_count   = excluded.item_count,
                updated_at   = excluded.updated_at,
                deleted_at   = NULL,
                sync_dirty   = excluded.sync_dirty
            """,
            [
                .text(dayKey),
                .real(totalAmount),
                .int(itemCount),
                .date(recordedAt),
                .date(updatedAt),
                .int(synced ? 0 : 1)
            ]
        )
    }

    func snapshotCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM asset_snapshot WHERE deleted_at IS NULL;") { $0.int(0) } ?? 0
    }

    func deleteSnapshot(day: Date, at moment: Date = .now) throws {
        try db.run(
            "UPDATE asset_snapshot SET deleted_at = ?, updated_at = ?, sync_dirty = 1 WHERE day = ?",
            [.date(moment), .date(moment), .text(DayKey.string(from: day))]
        )
    }

    func deleteAllSnapshots(at moment: Date = .now) throws {
        try db.run(
            "UPDATE asset_snapshot SET deleted_at = ?, updated_at = ?, sync_dirty = 1 WHERE deleted_at IS NULL",
            [.date(moment), .date(moment)]
        )
    }

    // MARK: - 元数据

    private func metaValue(_ key: String) throws -> String? {
        try db.scalar("SELECT value FROM app_meta WHERE key = ?;", [.text(key)]) { $0.text(0) }
    }

    private func setMetaValue(_ key: String, _ value: String) throws {
        try db.run(
            """
            INSERT INTO app_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(value)]
        )
    }

    // MARK: - 仅 Debug：生成演示曲线，用于验证图表

    #if DEBUG
    private static let demoFlagKey = "did_seed_demo_history"

    /// 生成一段随机游走的历史快照。仅当启动参数包含 `--seed-demo-history` 时调用。
    @discardableResult
    func seedDemoHistoryIfNeeded(days: Int = 200) throws -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--seed-demo-history") else { return false }
        if try metaValue(Self.demoFlagKey) == "1" { return false }

        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextRandom() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0xFFFFFFFF) / Double(0xFFFFFFFF)
        }

        let calendar = DayKey.calendar
        let today = DayKey.startOfDay(.now)
        var value = 8.0
        var recorded: [(Date, Double)] = []

        for offset in stride(from: days, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let drift = (nextRandom() - 0.46) * 0.9
            value = max(1.0, value + drift)
            recorded.append((day, (value * 100).rounded() / 100))
        }

        try db.transaction {
            for (day, total) in recorded {
                // 演示数据标记成「已同步」，避免把它们推到真实的 iCloud 里
                try db.run(
                    """
                    INSERT INTO asset_snapshot (day, total_amount, item_count, recorded_at, updated_at, deleted_at, sync_dirty)
                    VALUES (?, ?, ?, ?, ?, NULL, 0)
                    ON CONFLICT(day) DO UPDATE SET total_amount = excluded.total_amount
                    """,
                    [.text(DayKey.string(from: day)), .real(total), .int(2), .date(day), .date(day)]
                )
            }
        }
        try setMetaValue(Self.demoFlagKey, "1")
        return true
    }
    #endif

    // MARK: - iCloud 同步

    /// 本地待推送的记录（含墓碑）
    func fetchDirtyRecords() throws -> [SyncRecord] {
        let items: [SyncRecord] = try db.query(
            """
            SELECT id, name, amount, category, note, sort_index, created_at, updated_at, deleted_at
            FROM asset_item
            WHERE sync_dirty = 1
            """
        ) { row in
            let deletedAt = row.isNull(8) ? nil : row.date(8)
            let updatedAt = row.date(7)
            return SyncRecord.item(
                id: UUID(uuidString: row.text(0)) ?? UUID(),
                name: row.text(1),
                amount: row.double(2),
                category: AssetCategory(rawValue: row.text(3)) ?? .other,
                note: row.text(4),
                sortIndex: row.int(5),
                createdAt: row.date(6),
                updatedAt: updatedAt,
                isDeleted: deletedAt != nil
            )
        }

        let snapshots: [SyncRecord] = try db.query(
            """
            SELECT day, total_amount, item_count, recorded_at, updated_at, deleted_at
            FROM asset_snapshot
            WHERE sync_dirty = 1
            """
        ) { row in
            let deletedAt = row.isNull(5) ? nil : row.date(5)
            return SyncRecord.snapshot(
                dayKey: row.text(0),
                totalAmount: row.double(1),
                itemCount: row.int(2),
                recordedAt: row.date(3),
                updatedAt: row.date(4),
                isDeleted: deletedAt != nil
            )
        }

        return items + snapshots
    }

    /// 供诊断页显示：还有多少条没推上去
    func dirtyRecordCounts() throws -> (items: Int, snapshots: Int) {
        let items = try db.scalar("SELECT COUNT(*) FROM asset_item WHERE sync_dirty = 1;") { $0.int(0) } ?? 0
        let snapshots = try db.scalar("SELECT COUNT(*) FROM asset_snapshot WHERE sync_dirty = 1;") { $0.int(0) } ?? 0
        return (items, snapshots)
    }

    /// 推送成功后清掉脏标记
    func markRecordsSynced(_ names: [String]) throws {        guard !names.isEmpty else { return }
        try db.transaction {
            for name in names {
                if let id = itemID(fromRecordName: name) {
                    try db.run("UPDATE asset_item SET sync_dirty = 0 WHERE id = ?", [.text(id)])
                } else if let dayKey = dayKey(fromRecordName: name) {
                    try db.run("UPDATE asset_snapshot SET sync_dirty = 0 WHERE day = ?", [.text(dayKey)])
                }
            }
        }
    }

    /// 合并一条远端记录（last-writer-wins）。
    /// - Returns: 是否真的改动了本地数据（用于决定要不要刷新界面）
    @discardableResult
    func applyRemote(_ record: SyncRecord) throws -> Bool {
        switch record.kind {
        case .item: return try applyRemoteItem(record)
        case .snapshot: return try applyRemoteSnapshot(record)
        }
    }

    private func applyRemoteItem(_ record: SyncRecord) throws -> Bool {
        guard let itemID = record.itemID else { throw SyncError.malformedRecord(record.name) }
        let id = itemID.uuidString

        let localUpdatedAt = try db.scalar(
            "SELECT updated_at FROM asset_item WHERE id = ?",
            [.text(id)]
        ) { $0.date(0) }

        guard let localUpdatedAt else {
            // 本地没有 → 直接插入
            try db.run(
                """
                INSERT INTO asset_item (id, name, amount, category, note, sort_index, created_at, updated_at, deleted_at, sync_dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                [
                    .text(id),
                    .text(record.string(SyncField.name) ?? ""),
                    .real(record.double(SyncField.amount) ?? 0),
                    .text(record.string(SyncField.category) ?? AssetCategory.other.rawValue),
                    .text(record.string(SyncField.note) ?? ""),
                    .int(record.int(SyncField.sortIndex) ?? 0),
                    .date(record.date(SyncField.createdAt) ?? record.updatedAt),
                    .date(record.updatedAt),
                    record.isDeleted ? .date(record.updatedAt) : .null
                ]
            )
            return true
        }

        if record.updatedAt > localUpdatedAt {
            try db.run(
                """
                UPDATE asset_item
                SET name = ?, amount = ?, category = ?, note = ?, sort_index = ?,
                    updated_at = ?, deleted_at = ?, sync_dirty = 0
                WHERE id = ?
                """,
                [
                    .text(record.string(SyncField.name) ?? ""),
                    .real(record.double(SyncField.amount) ?? 0),
                    .text(record.string(SyncField.category) ?? AssetCategory.other.rawValue),
                    .text(record.string(SyncField.note) ?? ""),
                    .int(record.int(SyncField.sortIndex) ?? 0),
                    .date(record.updatedAt),
                    record.isDeleted ? .date(record.updatedAt) : .null,
                    .text(id)
                ]
            )
            return true
        }

        if record.updatedAt < localUpdatedAt {
            // 本地更新 → 保持脏，等下一次推送把本地的版本发上去
            try db.run("UPDATE asset_item SET sync_dirty = 1 WHERE id = ?", [.text(id)])
            return false
        }

        // 时间相同 → 视为已一致
        try db.run("UPDATE asset_item SET sync_dirty = 0 WHERE id = ?", [.text(id)])
        return false
    }

    private func applyRemoteSnapshot(_ record: SyncRecord) throws -> Bool {
        guard let dayKey = record.dayKey else { throw SyncError.malformedRecord(record.name) }

        let localUpdatedAt = try db.scalar(
            "SELECT updated_at FROM asset_snapshot WHERE day = ?",
            [.text(dayKey)]
        ) { $0.date(0) }

        guard let localUpdatedAt else {
            try db.run(
                """
                INSERT INTO asset_snapshot (day, total_amount, item_count, recorded_at, updated_at, deleted_at, sync_dirty)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """,
                [
                    .text(dayKey),
                    .real(record.double(SyncField.totalAmount) ?? 0),
                    .int(record.int(SyncField.itemCount) ?? 0),
                    .date(record.date(SyncField.recordedAt) ?? record.updatedAt),
                    .date(record.updatedAt),
                    record.isDeleted ? .date(record.updatedAt) : .null
                ]
            )
            return true
        }

        if record.updatedAt > localUpdatedAt {
            try db.run(
                """
                UPDATE asset_snapshot
                SET total_amount = ?, item_count = ?, recorded_at = ?, updated_at = ?, deleted_at = ?, sync_dirty = 0
                WHERE day = ?
                """,
                [
                    .real(record.double(SyncField.totalAmount) ?? 0),
                    .int(record.int(SyncField.itemCount) ?? 0),
                    .date(record.date(SyncField.recordedAt) ?? record.updatedAt),
                    .date(record.updatedAt),
                    record.isDeleted ? .date(record.updatedAt) : .null,
                    .text(dayKey)
                ]
            )
            return true
        }

        if record.updatedAt < localUpdatedAt {
            try db.run("UPDATE asset_snapshot SET sync_dirty = 1 WHERE day = ?", [.text(dayKey)])
            return false
        }

        try db.run("UPDATE asset_snapshot SET sync_dirty = 0 WHERE day = ?", [.text(dayKey)])
        return false
    }

    // MARK: 同步游标 / 开关

    func syncStateValue(_ key: String) throws -> String? {
        try db.scalar("SELECT value FROM sync_state WHERE key = ?;", [.text(key)]) { $0.text(0) }
    }

    func setSyncStateValue(_ key: String, _ value: String?) throws {
        if let value {
            try db.run(
                """
                INSERT INTO sync_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                [.text(key), .text(value)]
            )
        } else {
            try db.run("DELETE FROM sync_state WHERE key = ?", [.text(key)])
        }
    }

    // MARK: 记录名解析

    private func itemID(fromRecordName name: String) -> String? {
        guard name.hasPrefix(SyncRecord.itemPrefix) else { return nil }
        return String(name.dropFirst(SyncRecord.itemPrefix.count))
    }

    private func dayKey(fromRecordName name: String) -> String? {
        guard name.hasPrefix(SyncRecord.snapshotPrefix) else { return nil }
        return String(name.dropFirst(SyncRecord.snapshotPrefix.count))
    }
}
