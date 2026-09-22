import Foundation

/// 云端文件存储的抽象。
///
/// 抽出来是为了能在单元测试里用内存 / 本地目录实现跑完整的推送、分片、合并逻辑——
/// iCloud 云盘的真机行为没法在测试里伪造。
protocol CloudFileStore: Sendable {
    /// 人类可读的位置描述（诊断页展示）
    var locationDescription: String { get }

    /// 云盘当前是否可用
    func isAvailable() -> Bool

    /// 同步目录下已有的文件名
    func fileNames() throws -> [String]

    func read(_ name: String) throws -> Data?

    func write(_ data: Data, to name: String) throws

    /// 内容指纹（大小 + 修改时间）。用来跳过没变过的文件。
    func fingerprint(of name: String) throws -> String?
}

// MARK: - 本地目录实现

/// 普通本地目录。用于单元测试，以及 Debug 下用 `--use-local-sync-directory` 跑端到端验证。
final class LocalDirectoryFileStore: CloudFileStore, @unchecked Sendable {
    let directory: URL
    let locationDescription: String

    private let lock = NSLock()

    init(directory: URL, locationDescription: String? = nil) {
        self.directory = directory
        self.locationDescription = locationDescription ?? directory.path
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    func fileNames() throws -> [String] {
        guard isAvailable() else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    func read(_ name: String) throws -> Data? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func fingerprint(of name: String) throws -> String? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values.fileSize ?? 0)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

// MARK: - iCloud 云盘实现

/// 存放在 App 的 iCloud 容器里（`Documents/IceRecord/`）。
///
/// 为什么用文件而不是键值存储：`NSUbiquitousKeyValueStore` 的 1MB 是**所有 key 加起来**的
/// 总配额，拆成多个 key 并不会变大。iCloud 云盘文件没有这个总上限，
/// 而且可以按年分片——某一年的文件只在真正需要时才下载。
final class UbiquityContainerFileStore: CloudFileStore, @unchecked Sendable {

    private let subdirectory = "Documents/IceRecord"
    private let lock = NSLock()
    private var resolvedDirectory: URL??

    var locationDescription: String {
        (try? resolveDirectory())??.path ?? "iCloud 云盘（当前不可用）"
    }

    func isAvailable() -> Bool {
        (try? resolveDirectory()) ?? nil != nil
    }

    /// 解析容器目录。`url(forUbiquityContainerIdentifier:)` 会阻塞，
    /// **不能在主线程调用**——本方法的调用方都在非主 actor 的 async 上下文里。
    private func resolveDirectory() throws -> URL? {
        lock.lock()
        if let cached = resolvedDirectory {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            lock.lock()
            resolvedDirectory = URL??.some(nil)
            lock.unlock()
            return nil
        }

        let directory = container.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        lock.lock()
        resolvedDirectory = URL??.some(directory)
        lock.unlock()
        return directory
    }

    func fileNames() throws -> [String] {
        guard let directory = try resolveDirectory() else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    func read(_ name: String) throws -> Data? {
        guard let directory = try resolveDirectory() else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // 用 NSFileCoordinator：iCloud 可能正在写入这个文件，
        // 直接读会拿到半截内容。没下载的话这里会触发按需下载。
        var coordinationError: NSError?
        var result: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            do { result = try Data(contentsOf: actual) } catch { readError = error }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        return result
    }

    func write(_ data: Data, to name: String) throws {
        guard let directory = try resolveDirectory() else {
            throw SyncError.transport("iCloud 云盘当前不可用")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { actual in
            do { try data.write(to: actual, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    func fingerprint(of name: String) throws -> String? {
        guard let directory = try resolveDirectory() else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values.fileSize ?? 0)-\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

// MARK: - 工厂

enum CloudFileStoreFactory {

    /// Debug 下可以把同步目录换成本地路径，方便在没有 iCloud 的模拟器里跑端到端验证。
    static let localDirectoryLaunchArgument = "--use-local-sync-directory"

    static func make() -> CloudFileStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(localDirectoryLaunchArgument) {
            let directory = URL.applicationSupportDirectory
                .appendingPathComponent("DebugSyncDirectory", isDirectory: true)
            return LocalDirectoryFileStore(
                directory: directory,
                locationDescription: "本地调试目录（\(localDirectoryLaunchArgument)）"
            )
        }
        #endif
        return UbiquityContainerFileStore()
    }
}
