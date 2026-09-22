import Foundation

/// 把每日快照按 日 / 周 / 月 / 年 归并成曲线上的点。
enum TrendAggregator {

    static func aggregate(
        _ snapshots: [AssetSnapshot],
        period: StatsPeriod,
        limit: Int? = nil,
        calendar: Calendar = DayKey.calendar
    ) -> [TrendPoint] {
        guard !snapshots.isEmpty else { return [] }

        // 1. 按时间正序，保证桶内顺序 = 时间顺序
        let sorted = snapshots.sorted { $0.day < $1.day }

        // 2. 分桶（用有序字典的方式保持顺序）
        var bucketOrder: [Date] = []
        var buckets: [Date: [AssetSnapshot]] = [:]
        for snapshot in sorted {
            let key = period.bucketStart(for: snapshot.day, calendar: calendar)
            if buckets[key] == nil {
                bucketOrder.append(key)
            }
            buckets[key, default: []].append(snapshot)
        }

        // 3. 每个桶取最后一次记录作为曲线值，同时统计均值 / 极值
        var points: [TrendPoint] = []
        points.reserveCapacity(bucketOrder.count)

        for key in bucketOrder {
            guard let group = buckets[key], let last = group.last else { continue }
            let totals = group.map(\.totalAmount)
            let previousTotal = points.last?.total

            let change: Double
            let ratio: Double
            if let previousTotal {
                change = last.totalAmount - previousTotal
                ratio = previousTotal == 0 ? 0 : change / abs(previousTotal) * 100
            } else {
                change = 0
                ratio = 0
            }

            points.append(
                TrendPoint(
                    id: DayKey.string(from: key),
                    date: key,
                    total: last.totalAmount,
                    average: totals.reduce(0, +) / Double(totals.count),
                    minimum: totals.min() ?? last.totalAmount,
                    maximum: totals.max() ?? last.totalAmount,
                    sampleCount: group.count,
                    change: change,
                    changeRatio: ratio
                )
            )
        }

        // 4. 只保留最近 N 个点（change 已经在全量序列上算好，所以第一个点的变化仍然有参照）
        let cap = limit ?? period.maxPoints
        if cap > 0, points.count > cap {
            return Array(points.suffix(cap))
        }
        return points
    }
}
