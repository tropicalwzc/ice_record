import Foundation

/// 曲线的可视窗口：把一长串点切成「屏幕上显示哪一段」。
///
/// 点数不超过 `StatsPeriod.visiblePointLimit` 时整段显示；超过就按偏移切一屏，
/// 由底部的滑条控制偏移。抽成纯逻辑是为了能测——模拟器里没有图形界面，
/// 拖滑条的手感只能人工确认，但「切哪一段、越界怎么夹」必须被自动验证。
struct TrendWindow {

    let points: [TrendPoint]

    init(points: [TrendPoint]) {
        self.points = points
    }

    /// 一屏最多显示多少个点
    var visibleCount: Int {
        min(points.count, StatsPeriod.visiblePointLimit)
    }

    /// 是否需要滑条。只有超过一屏才给，否则整段静态显示。
    var isScrollable: Bool {
        points.count > StatsPeriod.visiblePointLimit
    }

    /// 窗口起点能取到的最大值（滑条的上界）
    var maximumOffset: Int {
        max(points.count - visibleCount, 0)
    }

    /// 默认窗口起点：停在最新的一段
    var defaultOffset: Int { maximumOffset }

    /// 把任意偏移夹回合法区间。滑条给的是浮点，取整后仍可能越界。
    func clampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), maximumOffset)
    }

    /// 从某个偏移开始的那一屏
    func points(atOffset offset: Int) -> [TrendPoint] {
        guard isScrollable else { return points }
        let start = clampedOffset(offset)
        return Array(points[start..<(start + visibleCount)])
    }

    /// 那一屏的时间范围
    func range(atOffset offset: Int) -> ClosedRange<Date>? {
        let slice = points(atOffset: offset)
        guard let first = slice.first?.date, let last = slice.last?.date, first <= last else { return nil }
        return first...last
    }

    /// 全部数据的时间范围
    var fullRange: ClosedRange<Date>? {
        guard let first = points.first?.date, let last = points.last?.date, first <= last else { return nil }
        return first...last
    }
}
