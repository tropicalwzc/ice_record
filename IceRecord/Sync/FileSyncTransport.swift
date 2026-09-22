import Foundation

/// 基于 iCloud 云盘文件（ubiquity container）的同步实现。
///
/// 文件布局（都放在容器的 `Documents/IceRecord/` 下）：
/// ```
/// items.json.deflate            ← 全部资产条目
/// snapshots-2025.json.deflate   ← 2025 年的每日快照
/// snapshots-2026.json.deflate   ← 2026 年的每日快照
/// ```
/// 每个文件都是 raw DEFLATE 压缩后的 `[SyncRecord]` JSON。
///
/// 为什么按年分片：一年最多 365 条快照，单文件体积天然有上界；
/// 平时改动只重写当年的那个文件，不用整坨重写。
///
/// 增量靠**文件指纹**（大小 + 修改时间）而不是服务端游标：
/// 指纹没变的文件直接跳过，不下载也不解码。
final class FileSyncTransport: SyncTransport, @unchecked Sendable {

    private let store: CloudFileStore
    private let lock = NSLock()
    /// 文件名 → 指纹。push 写完会立刻更新它，这样紧接着的 pull 就不用重读自己刚写的文件。
    private var index: [String: String] = [:]
    private var indexLoaded = false

    var isConfigured: Bool { true }
    var containerIdentifier: String? { store.locationDescription }

    init(store: CloudFileStore = CloudFileStoreFactory.make()) {
        self.store = store
    }

    // MARK: - 账号状态

    func accountState() async -> CloudAccountState {
        let available = store.isAvailable()
        SyncLog.debug("iCloud 云盘：\(available ? "可用" : "不可用")（\(store.locationDescription)）")
        return available ? .available : .noAccount
    }

    // MARK: - 拉取

    func pull(since token: Data?) async throws -> SyncPullResult {
        loadIndexIfNeeded(from: token)

        let names = try store.fileNames()
        var records: [SyncRecord] = []
        var skipped = 0
        var readFiles: [String] = []

        for name in names {
            let fingerprint = try store.fingerprint(of: name)
            if let fingerprint, index[name] == fingerprint {
                skipped += 1
                continue
            }
            guard let data = try store.read(name) else { continue }
            records.append(contentsOf: try decode(data, fileName: name))
            if let fingerprint { index[name] = fingerprint }
            readFiles.append(name)
        }

        SyncLog.info("拉取：扫描 \(names.count) 个文件，下载 \(readFiles.count) 个（跳过未变化的 \(skipped) 个），共 \(records.count) 条记录")

        return SyncPullResult(records: records, newToken: encodeIndex())
    }

    // MARK: - 推送

    func push(_ records: [SyncRecord]) async throws -> SyncPushResult {
        guard !records.isEmpty else { return .empty }

        loadIndexIfNeeded(from: nil)

        // 按目标文件分组：条目一个文件，快照按年分片
        var grouped: [String: [SyncRecord]] = [:]
        for record in records {
            guard let fileName = SyncFileLayout.fileName(for: record) else {
                SyncLog.warning("跳过无法定位文件的记录：\(record.name)")
                continue
            }
            grouped[fileName, default: []].append(record)
        }

        var summary: [String] = []
        for (fileName, group) in grouped.sorted(by: { $0.key < $1.key }) {
            let existing = try loadRecords(fileName: fileName)
            var byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })

            var written = 0
            for record in group {
                // 和合并规则保持一致：远端更新就保留远端
                if let current = byName[record.name], current.updatedAt > record.updatedAt { continue }
                byName[record.name] = record
                written += 1
            }

            let merged = byName.values.sorted { $0.name < $1.name }
            let data = try encode(merged)
            try store.write(data, to: fileName)

            // 更新指纹，避免接下来的 pull 重读刚写的文件
            if let fingerprint = try store.fingerprint(of: fileName) {
                index[fileName] = fingerprint
            }
            summary.append("\(fileName) +\(written)/\(merged.count)（\(data.count) 字节）")
        }

        SyncLog.info("推送：\(records.count) 条 → \(summary.joined(separator: "，"))")

        return SyncPushResult(pushedNames: records.map(\.name), failureSummary: nil)
    }

    // MARK: - 诊断

    func fileSummary() -> String {
        guard let names = try? store.fileNames() else { return "读取失败" }
        guard !names.isEmpty else { return "（空）" }
        return names.map { name in
            let size = (try? store.read(name))?.count ?? 0
            return "\(name) \(size)B"
        }.joined(separator: "、")
    }

    // MARK: - 内部

    private func loadIndexIfNeeded(from token: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let token, let decoded = try? JSONDecoder().decode([String: String].self, from: token) else {
            return
        }
        index = decoded
    }

    private func encodeIndex() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? JSONEncoder().encode(index)
    }

    private func loadRecords(fileName: String) throws -> [SyncRecord] {
        guard let data = try store.read(fileName) else { return [] }
        return try decode(data, fileName: fileName)
    }

    private func decode(_ data: Data, fileName: String) throws -> [SyncRecord] {
        do {
            let json = try (data as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode([SyncRecord].self, from: json)
        } catch {
            // 单个文件坏了就跳过它，不要让整轮同步永久失败；
            // 下一次推送会用本机数据把这个文件重建起来。
            SyncLog.error("文件 \(fileName) 解析失败，按空处理：\(error.localizedDescription)")
            return []
        }
    }

    private func encode(_ records: [SyncRecord]) throws -> Data {
        let json = try JSONEncoder().encode(records)
        return try (json as NSData).compressed(using: .zlib) as Data
    }
}
