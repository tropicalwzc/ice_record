import Foundation

/// 曲线图上的一个点（一个时间桶）。
struct TrendPoint: Identifiable, Hashable, Sendable {
    /// 桶起始日的 key，同时作为 Identifiable 的 id
    var id: String
    /// 桶起始时间
    var date: Date
    /// 该桶最后一次记录的总资产（万元）——曲线取这个值
    var total: Double
    /// 该桶内所有记录的平均值
    var average: Double
    var minimum: Double
    var maximum: Double
    /// 该桶内包含多少个自然日快照
    var sampleCount: Int
    /// 与上一个桶相比的变化量（万元）
    var change: Double
    /// 与上一个桶相比的变化率（%）
    var changeRatio: Double

    var isUp: Bool { change > 0 }
    var isDown: Bool { change < 0 }
    var isFlat: Bool { change == 0 }
}
