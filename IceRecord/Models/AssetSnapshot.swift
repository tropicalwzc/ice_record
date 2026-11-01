import Foundation

/// 某个自然日的总资产快照。`day` 唯一，同一天重复记录会覆盖旧值。
struct AssetSnapshot: Identifiable, Hashable, Sendable {
    var id: Int64
    /// 该自然日的 00:00（本地时区）
    var day: Date
    /// 当日总资产，单位：万元
    var totalAmount: Double
    /// 当日条目数量
    var itemCount: Int
    /// 当日各资产类别的金额（万元）。
    ///
    /// `nil` 表示这一天**没有**分类明细：分类功能上线之前的日期、
    /// 或旧版本客户端写入的远端快照。与「7 个类别全为 0」是两回事——
    /// 后者是「确实清空了」，前者是「当时没记录」，图表要区别对待。
    var categories: [AssetCategory: Double]? = nil
    /// 首次记录时间
    var recordedAt: Date
    /// 最后一次更新时间
    var updatedAt: Date

    var dayKey: String { DayKey.string(from: day) }

    /// 只要当天被修改过，就会留下 updatedAt 和 recordedAt 不一致的痕迹
    var wasRevised: Bool { updatedAt.timeIntervalSince(recordedAt) > 1 }
}
