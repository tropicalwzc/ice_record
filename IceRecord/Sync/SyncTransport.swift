import Foundation

/// iCloud 账号 / 容器的可用状态，直接反映到界面上。
enum CloudAccountState: Equatable, Sendable {
    /// 还没查询过
    case unknown
    /// 可用
    case available
    /// 没有登录 iCloud（数据仍会先存在本机，登录后自动同步）
    case noAccount
    /// 家长控制等限制
    case restricted
    /// 暂时不可用（网络等）
    case temporarilyUnavailable
    /// 这个 build 没有开启 iCloud
    case notConfigured

    var displayText: String {
        switch self {
        case .unknown: "检查中…"
        case .available: "iCloud 可用"
        case .noAccount: "未登录 iCloud"
        case .restricted: "iCloud 受限"
        case .temporarilyUnavailable: "iCloud 暂时不可用"
        case .notConfigured: "未开启 iCloud 同步"
        }
    }
}

/// 一次拉取的结果
struct SyncPullResult: Sendable {
    var records: [SyncRecord]
    /// 增量游标。iCloud 键值存储是全量读写，用不到，恒为 nil。
    var newToken: Data?
    /// 服务端说游标过期了（KVS 用不到）
    var tokenExpired: Bool = false

    static let empty = SyncPullResult(records: [], newToken: nil)
}

/// 一次推送的结果
struct SyncPushResult: Sendable {
    /// 已经落到远端的记录名
    var pushedNames: [String] = []
    /// 单条失败的原因（不中断整轮同步，这些记录留在脏列表里下次重试）
    var failureSummary: String?

    static let empty = SyncPushResult()
}

/// 云端的抽象。生产实现是 iCloud 键值存储，测试里换成 mock。
protocol SyncTransport: Sendable {
    /// 这个 build 是否开启了同步
    var isConfigured: Bool { get }

    /// 容器描述（诊断页展示用）
    var containerIdentifier: String? { get }

    /// 当前账号状态。**仅用于展示**，不用来阻断同步——
    /// 没登录 iCloud 时数据先存本机，登录后系统会自动补传。
    func accountState() async -> CloudAccountState

    /// 拉取远端的全部记录
    func pull(since token: Data?) async throws -> SyncPullResult

    /// 推送本地变更（含墓碑）。
    /// 单条失败只反映在 `failureSummary` 里，不抛错——否则一条坏记录会永远卡住整轮同步。
    func push(_ records: [SyncRecord]) async throws -> SyncPushResult
}

/// 没有开启 iCloud 时使用：什么也不做。
struct DisabledSyncTransport: SyncTransport {
    var isConfigured: Bool { false }
    var containerIdentifier: String? { nil }
    func accountState() async -> CloudAccountState { .notConfigured }
    func pull(since token: Data?) async throws -> SyncPullResult { .empty }
    func push(_ records: [SyncRecord]) async throws -> SyncPushResult { .empty }
}
