import Foundation
import Observation

/// 驱动同步的入口：管开关、管生命周期触发、把状态暴露给界面。
@MainActor
@Observable
final class SyncCoordinator {

    enum Status: Equatable {
        /// 用户关了开关，或者这个 build 没有开启 iCloud
        case disabled
        /// 空闲（上次同步时间由 `lastSyncDate` 给出）
        case idle
        case syncing
        /// 没登录 iCloud / 云盘没开。不是故障，本地改动会留着等下次
        case unavailable(String)
        case failed(String)

        var isBusy: Bool { self == .syncing }
    }

    private(set) var status: Status = .disabled
    private(set) var accountState: CloudAccountState = .unknown
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?
    /// 同步成功了，但有些记录被云端拒绝（不阻断整轮同步）
    private(set) var lastWarningMessage: String?

    /// iCloud 同步开关
    private(set) var isEnabled: Bool

    /// 拉取到远端改动、需要刷新界面时调用
    var onRemoteChanges: (() -> Void)?

    private let transport: SyncTransport
    private let engine: SyncEngine
    private var scheduledTask: Task<Void, Never>?
    private var observerTokens: [NSObjectProtocol] = []

    private static let enabledKey = "icloud.sync.enabled"
    /// 本地改动后延迟多久自动同步，避免连续编辑时频繁请求
    private nonisolated static let debounce: Duration = .seconds(3)

    var isConfigured: Bool { transport.isConfigured }

    init(database: AppDatabase, transport: SyncTransport) {
        self.transport = transport
        self.engine = SyncEngine(database: database, transport: transport)
        self.lastSyncDate = engine.lastSyncDate

        let storedValue = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        self.isEnabled = transport.isConfigured && (storedValue ?? true)
        applyIdleStatus()
        observeCloudChanges()
    }

    /// 监听「其它设备改了 iCloud 数据」的通知。
    /// iCloud 键值存储不需要推送证书，系统会直接投递这个通知。
    private func observeCloudChanges() {
        guard transport.isConfigured else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? -1
            SyncLog.info("收到 iCloud 数据变化通知（reason=\(reason)），准备同步")
            MainActor.assumeIsolated {
                self?.scheduleSync(after: .zero)
            }
        }
        observerTokens.append(token)
    }

    // MARK: - 开关

    func setEnabled(_ enabled: Bool) {
        guard transport.isConfigured else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        SyncLog.info("iCloud 同步开关 → \(enabled ? "开" : "关")")
        if enabled {
            scheduleSync(after: .zero)
        } else {
            scheduledTask?.cancel()
            lastErrorMessage = nil
            applyIdleStatus()
        }
    }

    // MARK: - 触发

    /// App 启动 / 回到前台时调用
    func syncOnAppear() {
        guard isEnabled else { return }
        scheduleSync(after: .zero)
    }

    /// 启动时用：**等第一次同步真的跑完**再返回。
    ///
    /// 调用方需要这个时序——只有等云端数据回灌之后，才能判断
    /// 「本机是不是真的空」，从而决定要不要写示例数据。
    func performInitialSync() async {
        guard isEnabled else { return }
        await syncNow()
    }

    /// 本地数据改动后调用（带去抖）
    func scheduleSync(after delay: Duration = SyncCoordinator.debounce) {
        guard isEnabled else { return }
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// 立即同步一次
    func syncNow() async {
        guard isEnabled else {
            applyIdleStatus()
            return
        }
        guard status != .syncing else { return }

        status = .syncing

        // 整轮同步套一层超时：iCloud 偶发卡住时，界面不能一直停在「正在同步…」
        let attempt = await withTimeout(
            seconds: SyncEngine.overallTimeout,
            fallback: SyncAttempt.failed("iCloud 响应超时，请稍后再试")
        ) { [engine] in
            do {
                return SyncAttempt.success(try await engine.sync())
            } catch let error as SyncError {
                switch error {
                case .notConfigured(let reason):
                    return SyncAttempt.notConfigured(reason)
                case .accountUnavailable(let reason):
                    return SyncAttempt.accountUnavailable(reason)
                case .transport, .malformedRecord:
                    return SyncAttempt.failed(error.localizedDescription)
                }
            } catch {
                return SyncAttempt.failed(error.localizedDescription)
            }
        }

        accountState = await engine.resolvedAccountState()

        switch attempt {
        case .success(let outcome):
            lastSyncDate = engine.lastSyncDate
            lastErrorMessage = nil
            lastWarningMessage = outcome.pushFailureSummary
            status = .idle
            if outcome.didChangeLocalData {
                onRemoteChanges?()
            }
        case .notConfigured(let reason):
            lastErrorMessage = reason
            lastWarningMessage = nil
            status = .disabled
        case .accountUnavailable(let reason):
            accountState = .noAccount
            lastErrorMessage = nil
            lastWarningMessage = nil
            status = .unavailable(reason)
        case .failed(let message):
            lastErrorMessage = message
            lastWarningMessage = nil
            status = .failed(message)
            SyncLog.error("同步失败：\(message)")
        }
    }

    /// 设置页「重置同步状态」：清掉上次同步时间等本机记录，
    /// 下次同步会把本机数据重新完整写一遍远端。
    func resetSyncState() {
        lastErrorMessage = nil
        lastWarningMessage = nil
        lastSyncDate = nil
        status = isEnabled ? .idle : .disabled
        SyncLog.info("已重置同步状态")
    }

    /// 诊断信息（设置页展示）
    var diagnostics: SyncDiagnostics {
        engine.diagnostics(
            containerID: transport.containerIdentifier ?? "（未开启）",
            accountState: accountState,
            fileSummary: (transport as? FileSyncTransport)?.fileSummary()
        )
    }

    private func applyIdleStatus() {
        if !transport.isConfigured {
            accountState = .notConfigured
            status = .disabled
        } else if !isEnabled {
            status = .disabled
        } else {
            status = .idle
        }
    }

    // MARK: - 给界面用的文案

    var statusText: String {
        switch status {
        case .disabled:
            return isConfigured ? "iCloud 同步已关闭" : "未开启 iCloud 同步"
        case .idle:
            guard let lastSyncDate else { return "等待同步" }
            return "已同步 · \(DateDisplay.timestamp(lastSyncDate))"
        case .syncing:
            return "正在同步…"
        case .unavailable(let reason):
            return "\(reason) · 数据只保存在本机，登录 iCloud 后自动同步"
        case .failed(let message):
            return "同步失败：\(message)"
        }
    }

    var symbolName: String {
        switch status {
        case .disabled: "icloud.slash"
        case .idle: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .unavailable: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }
}
