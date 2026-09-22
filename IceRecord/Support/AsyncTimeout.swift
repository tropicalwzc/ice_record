import Foundation

/// 只让第一个结果生效的续体盒子（线程安全）。
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var isResumed = false

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if isResumed {
            lock.unlock()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) {
        lock.lock()
        guard !isResumed, let continuation else {
            lock.unlock()
            return
        }
        isResumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// 让 `operation` 和一个超时赛跑，谁先给出结果就用谁。
///
/// CloudKit 的 `accountStatus()` 在没有登录 iCloud / 没有 iCloud entitlement 的环境下
/// 可能**永远不回调**，如果不设超时，界面会一直卡在「正在同步…」。
/// 超时后不再等待 `operation`（它在后台跑完就被丢弃），保证 UI 状态一定能恢复。
@MainActor
func withTimeout<T: Sendable>(
    seconds: Double,
    fallback: T,
    operation: @escaping @MainActor () async -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let box = ResumeOnce<T>()
        box.attach(continuation)

        Task { @MainActor in
            let value = await operation()
            box.resume(returning: value)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            box.resume(returning: fallback)
        }
    }
}
