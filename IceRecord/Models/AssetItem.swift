import Foundation

/// 一条资产条目，例如「股票 10.5 万」。
struct AssetItem: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 单位：万元
    var amount: Double
    var category: AssetCategory
    var note: String
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        amount: Double,
        category: AssetCategory = .other,
        note: String = "",
        sortIndex: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.category = category
        self.note = note
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 元为单位的金额，仅用于展示
    var amountInYuan: Double { amount * 10_000 }
}
