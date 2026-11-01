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

    /// 当前库的 schema 版本（`PRAGMA user_version`），供诊断与测试读取
    var schemaVersion: Int {
        (try? userVersion()) ?? 0
    }

    #if DEBUG
    /// 仅测试使用：`fetchSnapshotCategories` 实际发出的语句条数，用来守住「不许退化成 N+1」
    private(set) var snapshotCategoryStatementCount = 0
    #endif

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

    /// v3：每日快照的分类小计。
    ///
    /// - 主键 `(day, category)`：一天固定 7 行（金额为 0 也写），
    ///   这样某类别被清空后曲线能落回 0，读取时也不必向前回溯最近一次非零值。
    /// - 不再额外建 `day` 单列索引：`(day, category)` 的最左前缀已经覆盖按 `day` 的查询，
    ///   再加一个是纯冗余，只增加写放大。
    /// - 不建指向 `asset_snapshot` 的外键：快照是墓碑删除（`deleted_at`），
    ///   `ON DELETE CASCADE` 在墓碑模型下等于没写，级联由写路径显式完成。
    /// - 不回填历史：分类明细只从本版本上线当天起积累。
    private static let schemaV3: [String] = [
        """
        CREATE TABLE IF NOT EXISTS snapshot_category (
            day       TEXT NOT NULL,
            category  TEXT NOT NULL,
            amount    REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (day, category)
        );
        """
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
        if version < 3 {
            try db.transaction {
                for statement in Self.schemaV3 {
                    try db.execute(statement)
                }
            }
            try setUserVersion(3)
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
    ///
    /// - Parameter categories: 当日的分类小计。传 `nil` 表示这一天**没有**分类明细
    ///   （例如分类功能上线之前的日期），此时不写分类行；传非 `nil` 时按
    ///   「先删后插」整体覆盖，7 个类别无论金额是否为 0 都会写入。
    func upsertSnapshot(
        day: Date,
        totalAmount: Double,
        itemCount: Int,
        categories: [AssetCategory: Double]? = nil,
        at moment: Date = .now
    ) throws {
        let dayKey = DayKey.string(from: day)
        try db.transaction {
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
                    .text(dayKey),
                    .real(totalAmount),
                    .int(itemCount),
                    .date(moment),
                    .date(moment)
                ]
            )
            // 分类小计与总额必须在同一事务里落地，读的时候不可能出现一新一旧
            if let categories {
                try replaceSnapshotCategories(dayKey: dayKey, categories: categories)
            }
        }
    }

    func fetchSnapshots() throws -> [AssetSnapshot] {
        let snapshots = try db.query(
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

        // 分类小计一次性批量取回再挂上去，避免逐日查询退化成 N+1
        let categories = try fetchSnapshotCategories(for: snapshots.map(\.dayKey))
        guard !categories.isEmpty else { return snapshots }

        return snapshots.map { snapshot in
            var copy = snapshot
            copy.categories = categories[snapshot.dayKey]
            return copy
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

    // MARK: - 分类小计的读写

    /// 一次查出若干天的分类小计，按 `dayKey` 分组返回。
    ///
    /// 给整段历史挂分类时逐日查会退化成 N+1，所以走 `IN (...)` 批量取；
    /// 单条语句的参数个数有上限（老版本 SQLite 只有 999），超过就分批，
    /// 小数据量下仍然是**一次**查询。
    func fetchSnapshotCategories(for dayKeys: [String]) throws -> [String: [AssetCategory: Double]] {
        guard !dayKeys.isEmpty else { return [:] }

        let chunkSize = 500
        var result: [String: [AssetCategory: Double]] = [:]
        var index = 0

        while index < dayKeys.count {
            let chunk = Array(dayKeys[index..<min(index + chunkSize, dayKeys.count)])
            index += chunkSize

            #if DEBUG
            snapshotCategoryStatementCount += 1
            #endif

            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try db.query(
                """
                SELECT day, category, amount
                FROM snapshot_category
                WHERE day IN (\(placeholders))
                ORDER BY day ASC
                """,
                chunk.map { SQLValue.text($0) }
            ) { row in
                (day: row.text(0), category: AssetCategory(rawValue: row.text(1)), amount: row.double(2))
            }

            for row in rows {
                guard let category = row.category else { continue }
                result[row.day, default: [:]][category] = row.amount
            }
        }

        return result
    }

    /// 整体覆盖某一天的分类小计（先删后插，与快照同事务）。
    ///
    /// 用 DELETE + INSERT 而不是逐行 UPSERT：类别集合将来可能增减，
    /// upsert 会把「这次不该存在的旧类别」留在表里。
    func replaceSnapshotCategories(dayKey: String, categories: [AssetCategory: Double]) throws {
        try db.run("DELETE FROM snapshot_category WHERE day = ?", [.text(dayKey)])
        for category in AssetCategory.allCases {
            try db.run(
                "INSERT INTO snapshot_category (day, category, amount) VALUES (?, ?, ?)",
                [.text(dayKey), .text(category.rawValue), .real(categories[category] ?? 0)]
            )
        }
    }

    func snapshotCategoryRowCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM snapshot_category;") { $0.int(0) } ?? 0
    }

    func deleteSnapshot(day: Date, at moment: Date = .now) throws {
        let dayKey = DayKey.string(from: day)
        try db.transaction {
            try db.run(
                "UPDATE asset_snapshot SET deleted_at = ?, updated_at = ?, sync_dirty = 1 WHERE day = ?",
                [.date(moment), .date(moment), .text(dayKey)]
            )
            try db.run("DELETE FROM snapshot_category WHERE day = ?", [.text(dayKey)])
        }
    }

    func deleteAllSnapshots(at moment: Date = .now) throws {
        try db.transaction {
            try db.run(
                "UPDATE asset_snapshot SET deleted_at = ?, updated_at = ?, sync_dirty = 1 WHERE deleted_at IS NULL",
                [.date(moment), .date(moment)]
            )
            // 快照是墓碑删除，分类行没有自己墓碑，必须跟着一起清；
            // 否则会留下一堆指向已删除日期的无主分类记录。
            try db.run("DELETE FROM snapshot_category", [])
        }
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

                // 演示数据也必须带分类明细，否则 --seed-demo-history 下复合视图永远是空的，
                // 没法验收柱状图与幅度列表。拆分比例固定，保证 7 类之和严格等于总额。
                let stock = (total * 0.6 * 100).rounded() / 100
                let fund = (total * 0.2 * 100).rounded() / 100
                let cash = (total * 0.15 * 100).rounded() / 100
                let other = ((total - stock - fund - cash) * 100).rounded() / 100
                var categories: [AssetCategory: Double] = [:]
                for category in AssetCategory.allCases { categories[category] = 0 }
                categories[.stock] = stock
                categories[.fund] = fund
                categories[.cash] = cash
                categories[.other] = other
                try replaceSnapshotCategories(dayKey: DayKey.string(from: day), categories: categories)
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

        let snapshotRows = try db.query(
            """
            SELECT day, total_amount, item_count, recorded_at, updated_at, deleted_at
            FROM asset_snapshot
            WHERE sync_dirty = 1
            """
        ) { row in
            (
                dayKey: row.text(0),
                totalAmount: row.double(1),
                itemCount: row.int(2),
                recordedAt: row.date(3),
                updatedAt: row.date(4),
                isDeleted: !row.isNull(5)
            )
        }

        // 分类小计跟着当天的快照一起走，不单独成记录：两者的生命周期完全一致，
        // 拆开会让推送 / 拉取 / 冲突处理的路径翻倍，还会出现「总额来自 A 设备、
        // 分类来自 B 设备」的错配。
        let categories = try fetchSnapshotCategories(for: snapshotRows.map(\.dayKey))
        let snapshots: [SyncRecord] = snapshotRows.map { row in
            SyncRecord.snapshot(
                dayKey: row.dayKey,
                totalAmount: row.totalAmount,
                itemCount: row.itemCount,
                recordedAt: row.recordedAt,
                updatedAt: row.updatedAt,
                isDeleted: row.isDeleted,
                categories: categories[row.dayKey]
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

        let categories = record.snapshotCategories
        if !record.isDeleted, let categories {
            let total = record.double(SyncField.totalAmount) ?? 0
            let sum = categories.values.reduce(0, +)
            // 容差 0.01 万（100 元）：四舍五入与浮点累加的正常误差。
            // 超过它说明这条记录自己就自相矛盾，宁可跳过并留下记录，也不照抄。
            if abs(sum - total) > 0.01 {
                SyncLog.error("云端快照 \(dayKey) 的分类合计 \(sum) 与总额 \(total) 不一致，跳过")
                throw SyncError.inconsistentSnapshot(dayKey: dayKey, total: total, categorySum: sum)
            }
        }

        let localUpdatedAt = try db.scalar(
            "SELECT updated_at FROM asset_snapshot WHERE day = ?",
            [.text(dayKey)]
        ) { $0.date(0) }

        guard let localUpdatedAt else {
            try db.transaction {
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
                try mirrorRemoteCategories(dayKey: dayKey, categories: categories)
            }
            return true
        }

        if record.updatedAt > localUpdatedAt {
            try db.transaction {
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
                try mirrorRemoteCategories(dayKey: dayKey, categories: categories)
            }
            return true
        }

        if record.updatedAt < localUpdatedAt {
            try db.run("UPDATE asset_snapshot SET sync_dirty = 1 WHERE day = ?", [.text(dayKey)])
            return false
        }

        try db.run("UPDATE asset_snapshot SET sync_dirty = 0 WHERE day = ?", [.text(dayKey)])
        return false
    }

    /// 把远端带来的分类明细落到本地：有明细就整体覆盖，没有就清空。
    ///
    /// 「没有」要清空而不是留着旧值：一条更新的记录若是旧版本客户端写的（不认识分类字段），
    /// 它才是这一天的最新事实，留着本地的旧分类会让总额与分类长期对不上。
    private func mirrorRemoteCategories(dayKey: String, categories: [AssetCategory: Double]?) throws {
        if let categories {
            try replaceSnapshotCategories(dayKey: dayKey, categories: categories)
        } else {
            try db.run("DELETE FROM snapshot_category WHERE day = ?", [.text(dayKey)])
        }
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
