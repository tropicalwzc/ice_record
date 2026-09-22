import Foundation
import Observation

/// 全 App 唯一的数据源。
///
/// 关键约定：**任何一次对条目的增 / 删 / 改 / 排序，都会立刻重算总资产，
/// 并写回“今天”这个自然日的快照**（同一天重复修改只会覆盖当天的值）。
@MainActor
@Observable
final class AssetStore {

    private let database: AppDatabase

    private(set) var items: [AssetItem] = []
    /// 按自然日正序排列的全部快照
    private(set) var snapshots: [AssetSnapshot] = []
    /// 最近一次出错的文案，供界面提示
    private(set) var lastErrorMessage: String?

    /// 本地数据被改动后回调（用于触发 iCloud 同步）
    var onLocalMutation: (() -> Void)?

    init(database: AppDatabase? = nil) {
        self.database = database ?? AppDatabase.shared
        bootstrap()
    }

    // MARK: - 派生数据

    /// 当前总资产（万元）
    var totalAmount: Double {
        items.reduce(0) { $0 + $1.amount }
    }

    /// 今天的快照
    var todaySnapshot: AssetSnapshot? {
        let todayKey = DayKey.string(from: .now)
        return snapshots.last { $0.dayKey == todayKey }
    }

    /// 今天之前最近的一次快照
    var previousSnapshot: AssetSnapshot? {
        let todayKey = DayKey.string(from: .now)
        return snapshots.last { $0.dayKey < todayKey }
    }

    /// 相对上一次记录的变化量（万元）
    var changeSincePreviousSnapshot: Double? {
        guard let today = todaySnapshot else { return nil }
        guard let previous = snapshots.last(where: { $0.day < today.day }) else { return nil }
        return today.totalAmount - previous.totalAmount
    }

    var changeRatioSincePreviousSnapshot: Double? {
        guard let change = changeSincePreviousSnapshot,
              let previous = previousSnapshot,
              previous.totalAmount != 0
        else { return nil }
        return change / abs(previous.totalAmount) * 100
    }

    var isTodayRecorded: Bool { todaySnapshot != nil }

    /// 按类别汇总（用于占比展示）
    var categoryTotals: [(category: AssetCategory, amount: Double)] {
        Dictionary(grouping: items, by: \.category)
            .map { (category: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .filter { $0.amount != 0 }
            .sorted { $0.amount > $1.amount }
    }

    func trend(for period: StatsPeriod) -> [TrendPoint] {
        TrendAggregator.aggregate(snapshots, period: period)
    }

    /// 历史记录（最新在前），附带与上一条记录的差值
    func historyRows() -> [SnapshotHistoryRow] {
        let sorted = snapshots.sorted { $0.day < $1.day }
        var rows: [SnapshotHistoryRow] = []
        rows.reserveCapacity(sorted.count)
        for (index, snapshot) in sorted.enumerated() {
            let previous = index > 0 ? sorted[index - 1] : nil
            rows.append(
                SnapshotHistoryRow(
                    snapshot: snapshot,
                    change: previous.map { snapshot.totalAmount - $0.totalAmount }
                )
            )
        }
        return rows.reversed()
    }

    // MARK: - 条目操作（每次都会自动写入当日快照）

    func addItem(name: String, amount: Double, category: AssetCategory, note: String = "") {
        mutate {
            let nextIndex = (items.map(\.sortIndex).max() ?? -1) + 1
            let item = AssetItem(
                name: name,
                amount: amount,
                category: category,
                note: note,
                sortIndex: nextIndex
            )
            try database.insert(item)
        }
    }

    func updateItem(id: UUID, name: String, amount: Double, category: AssetCategory, note: String) {
        mutate {
            guard let existing = items.first(where: { $0.id == id }) else { return }
            var updated = existing
            updated.name = name
            updated.amount = amount
            updated.category = category
            updated.note = note
            updated.updatedAt = .now
            try database.update(updated)
        }
    }

    func deleteItems(withIDs ids: [UUID]) {
        mutate {
            for id in ids {
                try database.deleteItem(id: id)
            }
        }
    }

    func deleteItem(_ item: AssetItem) {
        deleteItems(withIDs: [item.id])
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        mutate {
            var reordered = items
            reordered.move(fromOffsets: source, toOffset: destination)
            let normalized = reordered.enumerated().map { index, item -> AssetItem in
                var copy = item
                copy.sortIndex = index
                return copy
            }
            try database.updateSortIndexes(normalized)
        }
    }

    /// 手动补记今天的快照（例如今天没有改动过任何条目）
    func recordSnapshotForToday() {
        mutate { }
    }

    func clearErrorMessage() {
        lastErrorMessage = nil
    }

    /// 同步引擎把远端数据合并进本地后调用：只重新读一遍，不写快照
    func reloadFromDatabase() {
        do {
            items = try database.fetchItems()
            snapshots = try database.fetchSnapshots()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - 内部

    private func bootstrap() {
        do {
            #if DEBUG
            try database.seedDemoHistoryIfNeeded()
            #endif

            // 注意：**不自动写示例数据**。
            // iCloud 上的数据会异步回灌（系统可能在我们读完之后才把远端内容送过来），
            // 只要自动播种，重装 App 就一定会和同步回来的条目重名重复。
            // 示例数据改成空状态里的一个显式按钮。
            items = try database.fetchItems()
            snapshots = try database.fetchSnapshots()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// 空状态里的「添加示例条目」按钮：写入用户举例的那两条数据。
    /// 只在列表为空时生效，避免和同步回来的数据重名重复。
    func addExampleItems() {
        guard items.isEmpty else { return }
        addItem(name: "股票", amount: 10.5, category: .stock)
        addItem(name: "流动资金", amount: 1.3, category: .cash)
    }

    /// 所有写操作的统一入口：
    /// 1. 落库；2. 重新读取条目；3. 重算并写入当日快照；4. 重新读取快照列表；5. 通知同步。
    private func mutate(_ body: () throws -> Void) {
        do {
            try body()
            items = try database.fetchItems()
            try persistSnapshotForToday()
            snapshots = try database.fetchSnapshots()
            lastErrorMessage = nil
            onLocalMutation?()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func persistSnapshotForToday() throws {
        try database.upsertSnapshot(
            day: DayKey.startOfDay(.now),
            totalAmount: totalAmount,
            itemCount: items.count
        )
    }
}

/// 历史记录列表的一行
struct SnapshotHistoryRow: Identifiable, Hashable, Sendable {
    var snapshot: AssetSnapshot
    /// 相对上一条记录的变化（万元），最早一条为 nil
    var change: Double?

    var id: Int64 { snapshot.id }
}
