import Foundation

/// 分类曲线上的一个点（某个类别、某个时间桶）。
struct CategoryTrendPoint: Identifiable, Hashable, Sendable {
    /// 桶起始日的 key，与 `TrendPoint.id` 同一套
    var dayKey: String
    /// 桶起始时间
    var date: Date
    var category: AssetCategory
    /// 该类在本桶的金额（万元）
    var value: Double
    /// 相对**上一个有该类数据的桶**的变化量（万元）。
    ///
    /// `nil` 与 `0` 是两件事：
    /// - `nil`：没有比较基准（序列的第一个桶），柱状图不画柱；
    /// - `0`：确实没动，柱状图画一根 0 高的柱，列表里标注「持平」。
    var delta: Double?

    var id: String { "\(category.rawValue)-\(dayKey)" }

    var isUp: Bool { (delta ?? 0) > 0 }
    var isDown: Bool { (delta ?? 0) < 0 }
    var isFlat: Bool { delta == 0 }
}

/// 把带分类明细的每日快照按 日 / 周 / 月 / 年 归并成分类序列。
///
/// 归并规则与 `TrendAggregator` 完全一致（桶内取最后一次记录，存量语义），
/// 区别只有两点：
/// 1. 只认**带分类明细**的快照，分类功能上线之前的日期不参与；
/// 2. 变化量按类别各自跟上一个桶比，而且首桶是 `nil` 而不是 `0`。
enum CategoryTrendAggregator {

    /// 复合视图用的完整矩阵：每个桶 × 每个有数据的类别。
    static func aggregate(
        _ snapshots: [AssetSnapshot],
        period: StatsPeriod,
        calendar: Calendar = DayKey.calendar
    ) -> [CategoryTrendPoint] {
        let buckets = bucketed(snapshots, period: period, calendar: calendar)
        guard !buckets.isEmpty else { return [] }

        // 先把「桶 → 各类金额」摊平，再逐类算前后差
        var previous: [AssetCategory: Double] = [:]
        var points: [CategoryTrendPoint] = []
        points.reserveCapacity(buckets.count * AssetCategory.allCases.count)

        for bucket in buckets {
            guard let categories = bucket.snapshot.categories else { continue }
            let dayKey = DayKey.string(from: bucket.key)
            for category in AssetCategory.allCases {
                guard let value = categories[category] else { continue }
                points.append(
                    CategoryTrendPoint(
                        dayKey: dayKey,
                        date: bucket.key,
                        category: category,
                        value: value,
                        delta: previous[category].map { value - $0 }
                    )
                )
                previous[category] = value
            }
        }
        return points
    }

    /// 单个类别的曲线，复用 `TrendPoint` 让图表层不必区分「总资产」与「某个类别」。
    ///
    /// 每个桶只有一个点，所以均值 / 极值都等于取值本身。
    static func series(
        for category: AssetCategory,
        from snapshots: [AssetSnapshot],
        period: StatsPeriod,
        calendar: Calendar = DayKey.calendar
    ) -> [TrendPoint] {
        let buckets = bucketed(snapshots, period: period, calendar: calendar)
        var points: [TrendPoint] = []
        points.reserveCapacity(buckets.count)

        var previous: Double?
        for bucket in buckets {
            guard let categories = bucket.snapshot.categories,
                  let value = categories[category]
            else { continue }

            let change = previous.map { value - $0 } ?? 0
            let ratio = (previous ?? 0) == 0 ? 0 : change / abs(previous!) * 100
            points.append(
                TrendPoint(
                    id: DayKey.string(from: bucket.key),
                    date: bucket.key,
                    total: value,
                    average: value,
                    minimum: value,
                    maximum: value,
                    sampleCount: 1,
                    change: change,
                    changeRatio: ratio
                )
            )
            previous = value
        }
        return points
    }

    /// 按粒度分桶，每桶只保留**最后一次带分类明细**的记录。
    ///
    /// 没有明细的快照直接不参与，所以不存在的桶不会凭空补出一个 0 值点。
    private static func bucketed(
        _ snapshots: [AssetSnapshot],
        period: StatsPeriod,
        calendar: Calendar
    ) -> [(key: Date, snapshot: AssetSnapshot)] {
        let withDetail = snapshots
            .filter { $0.categories != nil }
            .sorted { $0.day < $1.day }
        guard !withDetail.isEmpty else { return [] }

        let capped: [AssetSnapshot]
        let cap = period.maxPoints
        if cap > 0, withDetail.count > cap * 4 {
            // 先粗筛再分桶：桶数上限远小于天数，没必要把全部历史都拿进来
            capped = Array(withDetail.suffix(cap * 4))
        } else {
            capped = withDetail
        }

        var order: [Date] = []
        var latest: [Date: AssetSnapshot] = [:]
        for snapshot in capped {
            let key = period.bucketStart(for: snapshot.day, calendar: calendar)
            if latest[key] == nil { order.append(key) }
            latest[key] = snapshot
        }

        let all = order.compactMap { key in latest[key].map { (key: key, snapshot: $0) } }
        guard cap > 0, all.count > cap else { return all }
        return Array(all.suffix(cap))
    }
}
