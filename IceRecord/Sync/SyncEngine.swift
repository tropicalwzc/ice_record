import Foundation

/// 一次同步的结果
struct SyncOutcome: Equatable, Sendable {
    var pushed: Int = 0
    var pulled: Int = 0
    /// 真正改动了本地数据的条数（界面需要刷新）
    var applied: Int = 0
    /// 有记录被云端拒绝时的说明（不阻断整轮同步，但要让用户看见）
    var pushFailureSummary: String?
    var didChangeLocalData: Bool { applied > 0 }

    static let skipped = SyncOutcome()
}

/// 一次同步尝试的最终结果。用 enum 而不是 throw，
/// 是为了能安全地穿过 `withTimeout` 的 `Sendable` 边界。
enum SyncAttempt: Equatable, Sendable {
    case success(SyncOutcome)
    case notConfigured(String)
    /// 不是故障：没登录 iCloud / 云盘没开。本地改动保留，下次再传
    case accountUnavailable(String)
    case failed(String)
}

/// 同步编排：**先推本地脏数据，再拉远端，然后按 last-writer-wins 合并**。
///
/// 这一层不依赖任何云 SDK，只依赖 `SyncTransport`，所以可以用 mock 完整测试。
@MainActor
final class SyncEngine {

    private let database: AppDatabase
    private let transport: SyncTransport

    /// 上次成功同步时间
    static let lastSyncKey = "cloudkit.lastSyncAt"
    /// 文件指纹索引。用来跳过没变过的文件，实现增量拉取。
    static let fileIndexKey = "sync.fileIndex"
    /// 查询账号状态的超时时间
    static let accountStatusTimeout: Double = 8
    /// 整轮同步的超时时间
    static let overallTimeout: Double = 40

    init(database: AppDatabase, transport: SyncTransport) {
        self.database = database
        self.transport = transport
    }

    var lastSyncDate: Date? {
        guard let raw = try? database.syncStateValue(Self.lastSyncKey) else { return nil }
        return Date(timeIntervalSince1970: Double(raw) ?? 0)
    }

    /// 查询账号状态。只用于展示，所以套一层超时防止界面卡住。
    func resolvedAccountState() async -> CloudAccountState {
        await withTimeout(seconds: Self.accountStatusTimeout, fallback: .temporarilyUnavailable) {
            await self.transport.accountState()
        }
    }

    /// 执行一次完整同步。
    ///
    /// iCloud 不可用时直接返回（抛 `accountUnavailable`），**一个字都不动本地数据**，
    /// 脏标记保留，等 iCloud 可用时整批补传。
    @discardableResult
    func sync() async throws -> SyncOutcome {
        guard transport.isConfigured else {
            throw SyncError.notConfigured("这个 build 没有开启 iCloud")
        }

        let accountState = await resolvedAccountState()
        guard accountState == .available else {
            SyncLog.info("iCloud 不可用（\(accountState.displayText)），本轮跳过；本地改动会保留到下次")
            throw SyncError.accountUnavailable(accountState.displayText)
        }

        SyncLog.info("开始同步")

        var outcome = SyncOutcome()

        // 1. 先把本地未推送的改动写上去（含删除墓碑）
        let dirty = try database.fetchDirtyRecords()
        SyncLog.info("待上传 \(dirty.count) 条本地改动")
        if !dirty.isEmpty {
            let pushResult = try await transport.push(dirty)
            // 只把真正送达的清成「已同步」；被拒绝的留在脏列表里下次重试
            try database.markRecordsSynced(pushResult.pushedNames)
            outcome.pushed = pushResult.pushedNames.count
            outcome.pushFailureSummary = pushResult.failureSummary
            if let summary = pushResult.failureSummary {
                SyncLog.error("部分记录未能上传：\(summary)")
            }
        }

        // 2. 再拉远端。带上文件指纹索引，没变过的文件直接跳过。
        let pull = try await transport.pull(since: currentFileIndex())
        outcome.pulled = pull.records.count

        // 3. 合并（last-writer-wins）
        var applied = 0
        for record in pull.records {
            if try database.applyRemote(record) {
                applied += 1
            }
        }
        outcome.applied = applied

        // 4. 整轮都成功了才推进索引，避免中途失败漏数据
        if let newToken = pull.newToken {
            try saveFileIndex(newToken)
        }
        try database.setSyncStateValue(Self.lastSyncKey, String(Date.now.timeIntervalSince1970))

        SyncLog.info("同步完成：上传 \(outcome.pushed) 条，拉取 \(outcome.pulled) 条，本地更新 \(applied) 条")
        return outcome
    }

    private func currentFileIndex() -> Data? {
        guard let raw = try? database.syncStateValue(Self.fileIndexKey) else { return nil }
        return Data(base64Encoded: raw)
    }

    private func saveFileIndex(_ data: Data) throws {
        try database.setSyncStateValue(Self.fileIndexKey, data.base64EncodedString())
    }

    /// 给设置页「同步诊断」用的快照
    func diagnostics(containerID: String, accountState: CloudAccountState, fileSummary: String?) -> SyncDiagnostics {
        let counts = (try? database.dirtyRecordCounts()) ?? (items: 0, snapshots: 0)
        return SyncDiagnostics(
            containerID: containerID,
            accountState: accountState,
            pendingItems: counts.items,
            pendingSnapshots: counts.snapshots,
            fileSummary: fileSummary,
            lastSyncDate: lastSyncDate
        )
    }
}

/// 同步状态快照（设置页展示用）
struct SyncDiagnostics: Equatable, Sendable {
    var containerID: String
    var accountState: CloudAccountState
    var pendingItems: Int
    var pendingSnapshots: Int
    var fileSummary: String?
    var lastSyncDate: Date?

    var pendingTotal: Int { pendingItems + pendingSnapshots }
    var descriptionText: String {
        """
        位置：\(containerID)
        账号：\(accountState.displayText)
        待上传：\(pendingItems) 个条目 / \(pendingSnapshots) 天快照
        云端文件：\(fileSummary ?? "—")
        上次同步：\(lastSyncDate.map { DateDisplay.timestamp($0) } ?? "从未成功")
        """
    }
}
