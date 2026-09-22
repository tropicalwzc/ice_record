import Foundation

/// 记录 → 云端文件的映射规则。
///
/// 快照**按年分片**：一年一个文件。好处是
/// - 每次改动只重写当年的那个小文件，不用整坨重写；
/// - 单文件体积天然有上界（一年 = 365 条）；
/// - 将来要按年裁剪/归档也很直接。
///
/// 条目数量少而且经常改，放一个 `items.json.deflate` 里就够了。
enum SyncFileLayout {

    static let itemsFileName = "items.json.deflate"
    static let snapshotPrefix = "snapshots-"
    /// 注意是 **raw DEFLATE**，不是 gzip：Apple 的 `NSData.compressed(using: .zlib)`
    /// 输出的就是裸 deflate 流（没有 gzip / zlib 头）。名字如实写清楚，
    /// 免得以后有人拿 gunzip 去解。
    static let fileSuffix = ".json.deflate"

    static func snapshotsFileName(year: Int) -> String {
        "\(snapshotPrefix)\(year)\(fileSuffix)"
    }

    /// 这条记录该写进哪个文件
    static func fileName(for record: SyncRecord) -> String? {
        switch record.kind {
        case .item:
            return itemsFileName
        case .snapshot:
            guard let dayKey = record.dayKey, let year = year(fromDayKey: dayKey) else { return nil }
            return snapshotsFileName(year: year)
        }
    }

    /// 从 `yyyy-MM-dd` 里取年份
    static func year(fromDayKey dayKey: String) -> Int? {
        guard let prefix = dayKey.split(separator: "-").first else { return nil }
        return Int(prefix)
    }

    static func isSnapshotFile(_ name: String) -> Bool {
        name.hasPrefix(snapshotPrefix) && name.hasSuffix(fileSuffix)
    }

    /// 列出所有可能涉及的文件名（用于诊断）
    static func sortedFileNames(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            // items 排最前，快照按年份
            if lhs == itemsFileName { return true }
            if rhs == itemsFileName { return false }
            return lhs < rhs
        }
    }
}
