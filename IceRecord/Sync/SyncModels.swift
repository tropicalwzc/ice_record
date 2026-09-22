import Foundation

/// 同步的记录类型。
enum SyncRecordKind: String, Codable, CaseIterable, Sendable {
    /// 短码，尽量压缩 iCloud 键值存储里的体积（KVS 总配额只有 1MB）
    case item = "i"
    case snapshot = "s"

    var displayName: String {
        switch self {
        case .item: "AssetItem"
        case .snapshot: "AssetSnapshot"
        }
    }
}

/// 记录里的字段名。集中放一处，本地库和云端用同一套 key。
enum SyncField {
    static let name = "name"
    static let amount = "amount"
    static let category = "category"
    static let note = "note"
    static let sortIndex = "sortIndex"
    static let createdAt = "createdAt"

    static let totalAmount = "totalAmount"
    static let itemCount = "itemCount"
    static let recordedAt = "recordedAt"
}

/// 与云端交换的一条记录。
///
/// 刻意不依赖任何云 SDK 类型，这样合并逻辑可以用 mock 完整测试。
/// `updatedAt` / `isDeleted` 是**顶层字段**而不是塞在 `fields` 里——
/// 它们参与冲突裁决和墓碑判断，体积占比又高，单独拿出来编码更省空间。
struct SyncRecord: Equatable, Sendable, Codable {
    var name: String
    var kind: SyncRecordKind
    /// 冲突比较的唯一依据：谁的时间更新，谁说了算（last-writer-wins）
    var updatedAt: Date
    /// 墓碑标记。删除不做物理删除，而是留一条 `isDeleted = true` 的记录，
    /// 这样离线设备也能通过时间戳判断「删除」和「后来的修改」谁更新。
    var isDeleted: Bool
    var fields: [String: SyncValue]

    // 紧凑的编码键，iCloud 键值存储只有 1MB 配额
    enum CodingKeys: String, CodingKey {
        case name = "n"
        case kind = "k"
        case updatedAt = "u"
        case isDeleted = "d"
        case fields = "f"
    }

    static let itemPrefix = "item-"
    static let snapshotPrefix = "snapshot-"

    static func recordName(forItemID id: UUID) -> String {
        itemPrefix + id.uuidString
    }

    static func recordName(forDayKey key: String) -> String {
        snapshotPrefix + key
    }

    var itemID: UUID? {
        guard kind == .item, name.hasPrefix(Self.itemPrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(Self.itemPrefix.count)))
    }

    var dayKey: String? {
        guard kind == .snapshot, name.hasPrefix(Self.snapshotPrefix) else { return nil }
        return String(name.dropFirst(Self.snapshotPrefix.count))
    }

    // MARK: 取值

    func string(_ key: String) -> String? {
        if case .string(let value)? = fields[key] { return value }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case .double(let value)? = fields[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let value)? = fields[key] { return value }
        return nil
    }

    func date(_ key: String) -> Date? {
        if case .date(let value)? = fields[key] { return value }
        return nil
    }
}

/// 记录里的字段值。
///
/// 手写 Codable 而不是用合成实现：合成出来是 `{"string":{"_0":"…"}}` 这种啰嗦结构，
/// 几千条快照就会顶到 iCloud 键值存储的配额上限。
enum SyncValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case date(Date)
}

extension SyncValue: Codable {
    private enum Tag: Int {
        case string = 0
        case double = 1
        case int = 2
        case date = 3
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(Int.self)
        switch Tag(rawValue: tag) {
        case .string: self = .string(try container.decode(String.self))
        case .double: self = .double(try container.decode(Double.self))
        case .int: self = .int(try container.decode(Int.self))
        case .date: self = .date(Date(timeIntervalSince1970: try container.decode(Double.self)))
        case nil:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "未知的字段类型标记 \(tag)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .string(let value):
            try container.encode(Tag.string.rawValue)
            try container.encode(value)
        case .double(let value):
            try container.encode(Tag.double.rawValue)
            try container.encode(value)
        case .int(let value):
            try container.encode(Tag.int.rawValue)
            try container.encode(value)
        case .date(let value):
            try container.encode(Tag.date.rawValue)
            try container.encode(value.timeIntervalSince1970)
        }
    }
}

// MARK: - 从领域模型构造记录

extension SyncRecord {
    static func item(
        id: UUID,
        name itemName: String,
        amount: Double,
        category: AssetCategory,
        note: String,
        sortIndex: Int,
        createdAt: Date,
        updatedAt: Date,
        isDeleted: Bool
    ) -> SyncRecord {
        SyncRecord(
            name: recordName(forItemID: id),
            kind: .item,
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            fields: [
                SyncField.name: .string(itemName),
                SyncField.amount: .double(amount),
                SyncField.category: .string(category.rawValue),
                SyncField.note: .string(note),
                SyncField.sortIndex: .int(sortIndex),
                SyncField.createdAt: .date(createdAt)
            ]
        )
    }

    static func snapshot(
        dayKey: String,
        totalAmount: Double,
        itemCount: Int,
        recordedAt: Date,
        updatedAt: Date,
        isDeleted: Bool
    ) -> SyncRecord {
        SyncRecord(
            name: recordName(forDayKey: dayKey),
            kind: .snapshot,
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            fields: [
                SyncField.totalAmount: .double(totalAmount),
                SyncField.itemCount: .int(itemCount),
                SyncField.recordedAt: .date(recordedAt)
            ]
        )
    }
}

// MARK: - 错误

enum SyncError: LocalizedError {
    /// 这个 build 没有开启同步
    case notConfigured(String)
    /// iCloud 当前不可用（没登录 / 云盘关着）。不是故障，本地改动会留着等下次
    case accountUnavailable(String)
    case transport(String)
    case malformedRecord(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason):
            "iCloud 同步未开启：\(reason)"
        case .accountUnavailable(let reason):
            "iCloud 当前不可用：\(reason)"
        case .transport(let message):
            "iCloud 同步失败\n\(message)"
        case .malformedRecord(let name):
            "无法解析云端记录：\(name)"
        }
    }
}
