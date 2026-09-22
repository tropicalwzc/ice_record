import Foundation
import os

/// 同步过程的日志。
///
/// 用 `os.Logger` 而不是 `print`：在 Xcode 控制台和「Console.app」里都能按
/// subsystem / category 过滤。文案统一带 `[iCloud]` 前缀，方便直接搜。
///
/// 在 Xcode 里过滤：控制台搜索框输入 `category:iCloud`
/// 在 Console.app 里：选择本机 → 输入 `subsystem:com.icerecord.app`
enum SyncLog {
    static let subsystem = "com.icerecord.app"
    private static let logger = Logger(subsystem: subsystem, category: "iCloud")

    static func info(_ message: String) {
        logger.info("[iCloud] \(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("[iCloud] \(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("[iCloud] \(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("[iCloud] \(message, privacy: .public)")
    }
}
