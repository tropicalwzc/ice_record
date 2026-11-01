import Charts
import SwiftUI
import UIKit

/// 走势页的视图切换：总资产 / 复合 / 单个资产类别。
enum TrendScope: Hashable {
    case total
    case composite
    case category(AssetCategory)

    var title: String {
        switch self {
        case .total: "总资产"
        case .composite: "复合"
        case .category(let category): category.title
        }
    }
}

/// 资产变化曲线：按 日 / 周 / 月 / 年 统计，下面附带历史记录用于检索查看。
struct TrendView: View {
    @Environment(AssetStore.self) private var store

    @State private var period: StatsPeriod = .day
    @State private var scope: TrendScope = .total

    @State private var selectedDate: Date?
    @State private var showAllHistory = false
    /// 图表实际宽度，用来决定柱状图放几组柱
    @State private var chartWidth: CGFloat = 0
    /// 长历史时当前这一屏的起点（点数偏移）。`nil` 表示停在最近的默认窗口。
    @State private var windowOffset: Int?

    private let collapsedHistoryCount = 30

    /// 图表高度。240 时上下的卡片留白占比太大，抬到 300 让曲线有地方舒展。
    private static let chartHeight: CGFloat = 300

    private var allPoints: [TrendPoint] { store.trend(for: period) }
    private var rows: [SnapshotHistoryRow] { store.historyRows() }
    private var visibleRows: [SnapshotHistoryRow] {
        showAllHistory ? rows : Array(rows.prefix(collapsedHistoryCount))
    }

    /// 当前视图要画的折线数据。复合视图不用它（走柱状图）。
    private var linePoints: [TrendPoint] {
        switch scope {
        case .total:
            return allPoints
        case .category(let category):
            return CategoryTrendAggregator.series(
                for: category,
                from: store.snapshots,
                period: period
            )
        case .composite:
            return []
        }
    }

    /// 折线的可视窗口：超过一屏就只画其中一段
    private var lineWindow: TrendWindow {
        TrendWindow(points: linePoints)
    }

    /// 当前这一屏的起点偏移
    private var activeOffset: Int {
        lineWindow.clampedOffset(windowOffset ?? lineWindow.defaultOffset)
    }

    /// 当前这一屏的点。纵轴范围、区间统计、长按读数都跟着它走，
    /// 否则加载了两年数据、图上只有两个月，却报出两年的涨跌，读起来自相矛盾。
    private var visiblePoints: [TrendPoint] {
        lineWindow.points(atOffset: activeOffset)
    }

    /// 当前这一屏的时间范围
    private var visibleRange: ClosedRange<Date>? {
        lineWindow.range(atOffset: activeOffset)
    }

    /// 滑条的绑定：0 表示最早一段，上界表示最新一段
    private var offsetBinding: Binding<Double> {
        Binding(
            get: { Double(activeOffset) },
            set: { windowOffset = lineWindow.clampedOffset(Int($0.rounded())) }
        )
    }

    private var hasContent: Bool {
        switch scope {
        case .composite: !barBuckets.isEmpty
        default: !linePoints.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            List {
                periodSection

                if hasContent {
                    chartSection
                    if case .composite = scope {
                        amplitudeSection
                    } else {
                        statsSection
                    }
                } else {
                    emptySection
                }

                historySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("资产走势")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.recordSnapshotForToday()
                    } label: {
                        Label("记录今日", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    // MARK: - 周期切换

    private var periodSection: some View {
        Section {
            Picker("统计周期", selection: $period) {
                ForEach(StatsPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .onChange(of: period) { _, _ in
                selectedDate = nil
                // 换粒度后点数完全变了，窗口得回到最新的一段
                windowOffset = nil
            }
        } footer: {
            Text(period.bucketDescription)
        }
    }

    // MARK: - 图表容器

    private var chartSection: some View {
        // 图表挂在 **section 的 header** 上，而不是放进 section 的 body。
        //
        // body 的每一行都会被 section 卡片裁成圆角，而行内容与行背景都躲不开那把裁刀
        // （试过 `listRowBackground` 换形状、也试过行内自绘背景，都会被切回圆角）。
        // header 不属于卡片，不会被裁，于是左侧两个角可以真正做成直角——
        // 纵轴数字就长在那里，圆角会把它们啃掉。
        Section {
            EmptyView()
        } header: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(chartTitle)
                    Spacer(minLength: 8)
                    scopeMenu
                }

                VStack(spacing: 0) {
                    Group {
                        if case .composite = scope {
                            compositeChart
                        } else {
                            chart(visiblePoints)
                        }
                    }
                    .frame(height: Self.chartHeight)
                    // Charts 不会把自己裁到 frame 里：面积图的填充会溢出到框外。
                    // 以前图表在 List 行里，被卡片的圆角裁切顺带盖住了，挪到 header 后没东西裁它。
                    .clipped()
                    .padding(.vertical, 8)
                    // 纵轴数字本来就贴着内容左缘（实测只剩 3pt），再让它顶到卡片边就太挤
                    .padding(.leading, 4)

                    if lineWindow.isScrollable, !isCompositeScope {
                        windowSlider
                    }
                }
                // 先铺底色，再把整块向外扩——**顺序不能反**。
                // 负 padding 只把「内容」撑大，本视图对外报的尺寸仍是没撑开的那一份；
                // 底色若加在 padding 之后，就会按没撑开的尺寸画，于是纵轴数字与面积填充
                // 从卡片两侧漏到页面底色上（实测左端 7pt、右端 5pt）。
                .background(cardShape.fill(Color(.secondarySystemGroupedBackground)))
                // 再按同一个形状裁一次：四边都是直边，这里只为兜住绘制溢出
                .clipShape(cardShape)
                // header 自带的左右内边距比 section 卡片多出 20pt，这里补回来，
                // 让图表卡片的左右边缘与上下相邻的卡片严格对齐
                .padding(.horizontal, -Self.cardSideOverhang)
            }
        } footer: {
            if case .composite = scope {
                Text(compositeFooter)
            } else {
                Text(lineFooter)
            }
        }
    }

    /// 横轴不画日期之后，区间信息改由这行小字承担——否则用户没法知道这张图覆盖了哪段时间。
    ///
    /// 可滑动时同时给出「这一屏」和「全部」两个范围：只给这一屏，用户不知道自己滑到了哪；
    /// 只给全部，又看不出当前停在哪儿。
    private var lineFooter: String {
        guard let range = visibleRange else {
            return "长按曲线可以查看某个点的具体数值；单位：万。"
        }
        let current = "显示 \(rangeLabel(range.lowerBound)) – \(rangeLabel(range.upperBound))"

        guard lineWindow.isScrollable, let full = lineWindow.fullRange else {
            return "\(current)；长按曲线可以看某一天的具体数值，单位：万。"
        }
        return "\(current) · 全部 \(rangeLabel(full.lowerBound)) – \(rangeLabel(full.upperBound))，共 \(linePoints.count) 个点；拖动下方滑条看更早的区间，单位：万。"
    }

    private func rangeLabel(_ date: Date) -> String {
        switch period {
        case .day, .week: DateDisplay.monthDayNumeric(date)
        case .month: DateDisplay.yearMonthNumeric(date)
        case .year: DateDisplay.yearNumeric(date)
        }
    }

    /// section header 的内容比卡片本身窄多少（每侧）。
    ///
    /// insetGrouped 里卡片离屏幕边缘 20pt，而 header 里的内容还要再往里缩一截
    /// （在 393 / 440pt 宽上实测约为 20pt）。图表卡片要对齐其他卡片，就得把这一截补回去。
    private static let cardSideOverhang: CGFloat = 20

    /// 图表卡片的形状：**四角全为直角**。
    ///
    /// 左侧两角原本是圆角，而纵轴数字正好长在那两处，圆角会把它们啃掉；右侧跟着削平之后，
    /// 只剩右边圆、左边方反而显得整块是歪的，所以四角一路做直。
    /// 同一份形状既当底色又当裁切边界，两者不会出现偏差。
    private var cardShape: Rectangle { Rectangle() }

    private var isCompositeScope: Bool {
        if case .composite = scope { return true }
        return false
    }

    /// 长历史的区间控制条。
    ///
    /// 原本想用 `chartScrollableAxes` 让曲线本身可拖，但它和长按选点抢同一个手势，
    /// 拖一下出气泡、想翻页反而选中了某天。改成图表下方一条独立的滑条，
    /// 两者各管一段，互不干扰；滑条也更容易停到想要的区间。
    private var windowSlider: some View {
        VStack(spacing: 2) {
            Slider(
                value: offsetBinding,
                in: 0...Double(max(lineWindow.maximumOffset, 1)),
                step: 1
            )
            .tint(Color.accentColor)
            .accessibilityIdentifier("trendWindowSlider")

            HStack {
                Text("更早")
                Spacer()
                Text("共 \(linePoints.count) 个点，每屏 \(lineWindow.visibleCount) 个")
                Spacer()
                Text("更新")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var chartTitle: String {
        switch scope {
        case .total: "总资产曲线"
        case .composite: "各模块每期变化"
        case .category(let category): "\(category.title)曲线"
        }
    }

    /// 视图切换：候选项有 9 个（总资产 + 复合 + 7 个类别），
    /// 分段控制器在 393pt 上会被挤断，所以用带勾选态的菜单。
    private var scopeMenu: some View {
        Menu {
            Picker("视图", selection: $scope) {
                Text("总资产").tag(TrendScope.total)
                Text("复合（各模块变化）").tag(TrendScope.composite)
                Divider()
                ForEach(AssetCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbolName)
                        .tag(TrendScope.category(category))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(scope.title)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .onChange(of: scope) { _, _ in
                selectedDate = nil
                windowOffset = nil
            }
        }
        .accessibilityIdentifier("trendScopeMenu")
    }

    // MARK: - 折线（总资产 / 单个类别）

    @ViewBuilder
    private func chart(_ points: [TrendPoint]) -> some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("金额", point.total)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [areaColor.opacity(0.35), areaColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("金额", point.total)
                )
                .foregroundStyle(areaColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)

                if points.count <= 40 {
                    PointMark(
                        x: .value("日期", point.date),
                        y: .value("金额", point.total)
                    )
                    .foregroundStyle(areaColor)
                    .symbolSize(28)
                }
            }

            if let selected = selectedPoint(in: points) {
                RuleMark(x: .value("选中", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // 气泡挂在被选中的那个点上（而不是 RuleMark 的顶端），
                // 再根据该点在纵轴上的相对高度决定朝上还是朝下弹，
                // 这样既不会跑到绘图区外面被裁掉，也不需要用 chartPlotStyle 改绘图区
                // —— 那样会让数据区和坐标轴刻度错位。
                PointMark(
                    x: .value("日期", selected.date),
                    y: .value("金额", selected.total)
                )
                .foregroundStyle(areaColor)
                .symbolSize(90)
                .annotation(
                    position: calloutPosition(for: selected),
                    spacing: 10,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    selectionCallout(selected)
                }
            }
        }
        .chartXScale(domain: xDomain(points))
        .chartYScale(domain: yAxis(for: visiblePoints).domain)
        .chartXAxis {
            // 横轴不显示日期：那块标签区既占高度、又逼着两端各让出一段留白，
            // 而它提供的信息（具体是哪一天）长按气泡里本来就有。
            // 刻度只留网格线，用来对齐和判断疏密；数量交给系统按「好看的日期」取，
            // 反正它们只影响竖向参考线，不会出现标签重叠或被截断的问题。
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            }
        }
        .chartYAxis {
            let ticks = yAxis(for: visiblePoints).ticks
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(tickLabel(amount, ticks: ticks))
                            .font(.system(size: Self.axisLabelFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            chartWidth = width
        }
        .accessibilityIdentifier("trendChart")
    }

    /// 曲线配色：总资产用强调色，单个类别用类别色。
    private var areaColor: Color {
        if case .category(let category) = scope { return category.tint }
        return .accentColor
    }

    /// 绘图区宽度：图表总宽扣掉左侧纵轴标签占的一截。
    ///
    /// 只用于估算柱状图的桶数上限和柱宽，不参与折线的绘制。
    /// 纵轴标签改成整数后（见 `AmountFormatter.axisInteger`）这一截明显变窄，
    /// 常量从 64 收到 52。仍然按偏小估：估小了只会少画几个桶。
    private var plotWidth: CGFloat {
        max(chartWidth - 52, 0)
    }

    // MARK: - 量宽

    static let axisLabelFontSize: CGFloat = 11

    /// 和纵轴 / 柱状图标签里渲染用的字体保持一致，量出来的宽度才是真的
    private static let axisLabelFont: UIFont = {
        let base = UIFont.systemFont(ofSize: axisLabelFontSize, weight: .semibold)
        var descriptor = base.fontDescriptor
        if let rounded = descriptor.withDesign(.rounded) {
            descriptor = rounded
        }
        descriptor = descriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        ])
        return UIFont(descriptor: descriptor, size: axisLabelFontSize)
    }()

    private func axisLabelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Self.axisLabelFont]).width)
    }

    /// 选中的点画在绘图区上半部分时，气泡朝下弹；否则朝上弹。
    /// 这样气泡永远不会跑出绘图区（也就不会被裁掉）。
    private func calloutPosition(for point: TrendPoint) -> AnnotationPosition {
        let domain = yAxis(for: visiblePoints).domain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return .top }
        let ratio = (point.total - domain.lowerBound) / span
        return ratio > 0.55 ? .bottom : .top
    }

    /// 气泡：固定浅灰底 + 黑色字体 + 描边。
    /// 刻意不用 `.regularMaterial`，材质在不同背景下可能解析成深色，导致黑底黑字看不见。
    private func selectionCallout(_ point: TrendPoint) -> some View {
        VStack(spacing: 1) {
            Text(period.label(for: point.date))
                .font(.system(size: 10))
                .foregroundStyle(Color.black.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(AmountFormatter.wan(point.total))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.black)
                    .monospacedDigit()
                if !point.isFlat {
                    Text("\(point.isUp ? "▲" : "▼") \(AmountFormatter.signed(point.change))")
                        .font(.system(size: 10).weight(.semibold))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .monospacedDigit()
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func selectedPoint(in points: [TrendPoint]) -> TrendPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private func xDomain(_ points: [TrendPoint]) -> ClosedRange<Date> {
        guard let first = points.first?.date, let last = points.last?.date else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now
        }
        if first == last {
            // 只有一个数据点时，撑开一个与统计粒度相称的区间，避免坐标轴出现重复标签
            let half = singlePointSpan / 2
            return first.addingTimeInterval(-half)...last.addingTimeInterval(half)
        }
        // 横轴不再有日期标签，两端只需要一点点余量：
        // 让首尾点不贴着卡片边缘（圆角会啃掉一点），同时把绘图区尽量交还给曲线。
        let padding = last.timeIntervalSince(first) * Self.xDomainPaddingRatio
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    /// 首尾数据点之外各留出的时间白边比例。没有标签要避让，1.5% 足够。
    private static let xDomainPaddingRatio: Double = 0.015

    private var singlePointSpan: TimeInterval {
        let day: TimeInterval = 86_400
        switch period {
        case .day: return 2 * day
        case .week: return 14 * day
        case .month: return 62 * day
        case .year: return 2 * 365 * day
        }
    }

    /// 纵轴的取值域与刻度。
    ///
    /// 两件事绑在一起算：
    /// 1. **只按当前这一屏的数值定范围**。用全量数据算，早年的 8 万会把今天 15~20 万的曲线压成一条贴顶的线。
    /// 2. **范围等于首尾刻度**，且刻度用 floor/ceil 对齐到步长的整数倍——这样既保证数据全部落在域内
    ///    （不会把 20.54 的峰值压在 20 这条线上），又让刻度正好落在绘图区上下边缘。
    private struct YAxisModel {
        var domain: ClosedRange<Double>
        var ticks: [Double]
    }

    private func yAxis(for points: [TrendPoint]) -> YAxisModel {
        let values = points.map(\.total)
        guard let minimum = values.min(), let maximum = values.max() else {
            return YAxisModel(domain: 0...1, ticks: [0, 1])
        }

        // 上下各留 18% 的余量：曲线不贴边，峰值和谷值都能完整看出来。
        // 曾经把域吸附到「首尾刻度」上（为了滑动时不抖），结果 20.54 的峰顶被压在 20 这条线上，
        // 比例尺看着比吸附之前更紧、更不好读——安全空间不该被刻度吃掉。
        let span = maximum - minimum
        let padding = span > 0 ? span * 0.18 : max(abs(minimum) * 0.1, 1)
        let low = minimum - padding
        let high = maximum + padding

        // 刻度可以落在域内任意位置，不要求贴边
        let ticks = axisTicks(low: low, high: high).filter { $0 >= low && $0 <= high }
        return YAxisModel(domain: low...high, ticks: ticks)
    }

    /// 按「好看的步长」（1/2/5 × 10^k）切刻度。
    ///
    /// 首尾刻度用 floor/ceil 对齐到步长的整数倍，保证**包住**数据：
    /// 只取落在范围内的刻度会把峰值切掉（实测 20.54 的顶被压在 20 这条线上）。
    private func axisTicks(low: Double, high: Double, desiredCount: Int = 4) -> [Double] {
        var lower = low
        var upper = high
        if upper - lower <= 0 {
            let padding = max(abs(lower) * 0.1, 1)
            lower -= padding
            upper += padding
        }

        var step = niceStep(atLeast: (upper - lower) / Double(max(desiredCount - 1, 1)))
        var ticks = buildTicks(low: lower, high: upper, step: step)

        // 太密就加粗，太稀就细分；只在「好看」的档位之间走，绝不出现 2.5 这种步长
        //（那会让 17.5 被四舍五入成 18，同一根轴上出现 15 / 18 / 20 这种不等距标签）
        while ticks.count > desiredCount + 2 {
            step = nextNiceStep(step, coarser: true)
            ticks = buildTicks(low: lower, high: upper, step: step)
        }
        while ticks.count < 3 && step > (upper - lower) / 100 {
            step = nextNiceStep(step, coarser: false)
            ticks = buildTicks(low: lower, high: upper, step: step)
        }

        // 兜底不能返回区间端点：端点贴着绘图区上下边缘，而边缘正是卡片圆角裁切的位置，
        // 数字会被切掉。退回两个明显内缩的刻度。
        guard !ticks.isEmpty else {
            let inset = (upper - lower) * 0.25
            return [lower + inset, upper - inset]
        }
        return ticks
    }

    /// 只生成**落在区间内**的刻度。
    ///
    /// 不用 floor 向外扩：纵轴范围已经带 18% 余量、不再等于首尾刻度，
    /// 向外扩出来的刻度会被过滤掉，而「数量够不够」的判断却把它们算进去了——
    /// 结果就是明明只该有 2 根刻度却以为有 4 根，永远不细化，轴上只剩 18 和 20。
    private func buildTicks(low: Double, high: Double, step: Double) -> [Double] {
        guard step > 0 else { return [] }
        var value = ceil(low / step) * step
        var ticks: [Double] = []
        while value <= high + step * 0.001 {
            ticks.append((value * 1000).rounded() / 1000)
            value += step
        }
        return ticks
    }

    /// 不小于 `raw` 的最小「好看」步长：1 / 2 / 5 / 10 × 10^k
    private func niceStep(atLeast raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let normalized = raw / magnitude
        let multiplier: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return multiplier * magnitude
    }

    /// 在 1 / 2 / 5 / 10 这条阶梯上走一格
    private func nextNiceStep(_ step: Double, coarser: Bool) -> Double {
        let magnitude = pow(10, floor(log10(step)))
        let normalized = (step / magnitude * 10).rounded() / 10

        if coarser {
            if normalized < 1.5 { return 2 * magnitude }
            if normalized < 3.5 { return 5 * magnitude }
            return 10 * magnitude
        } else {
            if normalized < 1.5 { return magnitude / 2 }
            if normalized < 3.5 { return magnitude }
            return 2 * magnitude
        }
    }

    /// 刻度文案。步长 ≥ 1 万时一律整数；只有变化量小到零点几万时才带一位小数
    /// （那种量级下整数刻度只剩一根 0，等于没有刻度）。
    private func tickLabel(_ value: Double, ticks: [Double]) -> String {
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
        return AmountFormatter.axisTick(value, step: step)
    }

    // MARK: - 复合：按期的分组柱状图

    /// 柱状图的一期
    private struct BarBucket: Identifiable {
        var dayKey: String
        var date: Date
        var points: [CategoryTrendPoint]
        var id: String { dayKey }
    }

    /// 当前绘图区宽度下，每根柱子至少要有这么宽才看得清
    private static let minimumBarWidth: CGFloat = 5
    /// 桶与桶之间留给视觉分隔的宽度
    private static let barGroupSpacing: CGFloat = 8
    /// 桶数下限。再少就不像「走势」了。
    private static let minimumBucketCount = 5
    /// 桶内最多画几个类别，超出的按本期变化绝对值取前几名
    private static let maximumSeriesCount = 6

    /// 参与绘制的类别：只取**真正有金额**的，按「本期累计变化绝对值」排序取前几名。
    ///
    /// 每天都会把 7 个类别全量写进快照（含 0），所以不能见到类别就画，
    /// 否则图例里会挂着一堆永远是 0 的条目，把真正在动的几个挤没了。
    private var plottedCategories: [AssetCategory] {
        let all = CategoryTrendAggregator.aggregate(store.snapshots, period: period)
        var magnitude: [AssetCategory: Double] = [:]
        var hasValue: Set<AssetCategory> = []
        for point in all {
            if point.value != 0 { hasValue.insert(point.category) }
            if let delta = point.delta {
                magnitude[point.category, default: 0] += abs(delta)
            }
        }
        let ordered = hasValue.sorted {
            let lhs = magnitude[$0] ?? 0
            let rhs = magnitude[$1] ?? 0
            if lhs == rhs { return $0.rawValue < $1.rawValue }
            return lhs > rhs
        }
        return Array(ordered.prefix(Self.maximumSeriesCount))
    }

    /// 实际绘制的桶：第一个桶没有比较基准，直接不画；其余按宽度反算上限。
    private var barBuckets: [BarBucket] {
        let categories = Set(plottedCategories)
        guard !categories.isEmpty else { return [] }

        let all = CategoryTrendAggregator.aggregate(store.snapshots, period: period)
        var order: [String] = []
        var dates: [String: Date] = [:]
        var grouped: [String: [CategoryTrendPoint]] = [:]
        for point in all where categories.contains(point.category) {
            if grouped[point.dayKey] == nil {
                order.append(point.dayKey)
                dates[point.dayKey] = point.date
            }
            grouped[point.dayKey, default: []].append(point)
        }

        // 首桶只是基准，没有柱子可画
        let drawable = order.dropFirst()
        let capacity = bucketCapacity(seriesCount: categories.count)
        let kept = drawable.suffix(capacity)

        return kept.map { key in
            BarBucket(
                dayKey: key,
                date: dates[key] ?? .now,
                points: (grouped[key] ?? []).sorted { $0.category.rawValue < $1.category.rawValue }
            )
        }
    }

    /// 桶数按绘图区宽度反算：柱子挤成一条线的时候，少画几期比强行把整个周期塞进来更有用。
    ///
    /// 两个天花板取小：一个是不让柱子细过 `minimumBarWidth`，一个是不让桶下的日期标签互相压住。
    /// 只按柱子算的话，类别从 6 个降到 3 个时桶数会翻倍，日期直接连成「10-2310-24…」。
    private func bucketCapacity(seriesCount: Int) -> Int {
        guard plotWidth > 0 else { return Self.minimumBucketCount }
        let perBucket = CGFloat(seriesCount) * (Self.minimumBarWidth + 1)
        let barCapacity = Int((plotWidth + Self.barGroupSpacing) / (perBucket + Self.barGroupSpacing))

        let labelWidth = axisLabelWidth(DateDisplay.monthDayNumeric(.now)) + 6
        let labelCapacity = Int(plotWidth / labelWidth)

        return max(Self.minimumBucketCount, min(barCapacity, labelCapacity))
    }

    private var barWidth: CGFloat {
        guard !barBuckets.isEmpty else { return 4 }
        let seriesCount = max(plottedCategories.count, 1)
        let available = plotWidth - CGFloat(barBuckets.count - 1) * Self.barGroupSpacing
        let width = available / CGFloat(barBuckets.count * seriesCount)
        return max(2, min(12, width - 1))
    }

    private func barDomain() -> ClosedRange<Double> {
        let deltas = barBuckets.flatMap { $0.points.compactMap(\.delta) }
        guard let minimum = deltas.min(), let maximum = deltas.max() else { return -1...1 }
        let padding = max((maximum - minimum) * 0.15, 0.1)
        return (min(minimum, 0) - padding)...(max(maximum, 0) + padding)
    }

    private var compositeChart: some View {
        let buckets = barBuckets
        let categories = plottedCategories

        return Chart {
            ForEach(buckets) { bucket in
                ForEach(bucket.points) { point in
                    BarMark(
                        x: .value("期", bucket.dayKey),
                        y: .value("变化", point.delta ?? 0),
                        width: .fixed(barWidth)
                    )
                    .foregroundStyle(by: .value("类别", point.category.title))
                    .position(by: .value("类别", point.category.title))
                    .cornerRadius(1.5)
                }
            }

            // 零轴要显眼：柱子画在上还是下，就是涨还是跌
            RuleMark(y: .value("零轴", 0))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartForegroundStyleScale(
            domain: categories.map(\.title),
            range: categories.map(\.tint)
        )
        .chartYScale(domain: barDomain())
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                if let key = value.as(String.self), let date = bucketDate(for: key) {
                    AxisValueLabel {
                        Text(DateDisplay.monthDayNumeric(date))
                            .font(.system(size: Self.axisLabelFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            let ticks = axisTicks(low: barDomain().lowerBound, high: barDomain().upperBound)
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(tickLabel(amount, ticks: ticks))
                            .font(.system(size: Self.axisLabelFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            chartWidth = width
        }
        .accessibilityIdentifier("trendCompositeChart")
    }

    private func bucketDate(for dayKey: String) -> Date? {
        barBuckets.first { $0.dayKey == dayKey }?.date
    }

    private var compositeFooter: String {
        let count = barBuckets.count
        var text = "共 \(count) 期；柱高是各模块相对上一期的变化量，指向上方为涨、下方为跌。"
        let allCount = AssetCategory.allCases.filter { category in
            store.snapshots.contains { $0.categories?[category] != nil }
        }.count
        if allCount > Self.maximumSeriesCount {
            text += "图中只画变化最大的 \(Self.maximumSeriesCount) 个模块，全部模块见下方列表。"
        }
        return text
    }

    // MARK: - 复合：本周期各模块变化幅度

    /// 一段周期内某个模块的变化：金额、变化额、变化率。
    private struct CategoryDeltaRow: Identifiable {
        var category: AssetCategory
        /// 期末金额（万元）
        var endValue: Double
        /// 期初金额（万元）。用「期末 - 累计变化」反推，保证与柱子严丝合缝。
        var startValue: Double
        var delta: Double
        var id: String { category.rawValue }

        var ratio: Double? {
            guard startValue != 0 else { return nil }
            return delta / abs(startValue) * 100
        }
    }

    private var deltaRows: [CategoryDeltaRow] {
        var endValues: [AssetCategory: Double] = [:]
        var deltaSums: [AssetCategory: Double] = [:]
        for bucket in barBuckets {
            for point in bucket.points {
                endValues[point.category] = point.value
                if let delta = point.delta {
                    deltaSums[point.category, default: 0] += delta
                }
            }
        }
        return deltaSums.map { category, delta in
            let end = endValues[category] ?? 0
            return CategoryDeltaRow(
                category: category,
                endValue: end,
                startValue: end - delta,
                delta: delta
            )
        }
        .sorted { abs($0.delta) > abs($1.delta) }
    }

    private var totalDelta: Double {
        deltaRows.reduce(0) { $0 + $1.delta }
    }

    private var amplitudeSection: some View {
        Section {
            if deltaRows.isEmpty {
                Text("本周期没有可比较的变化")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deltaRows) { row in
                    amplitudeRow(row)
                }
                Divider()
                HStack {
                    Text("合计")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(AmountFormatter.signed(totalDelta))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint(for: totalDelta))
                }
            }
        } header: {
            HStack {
                Text("本周期各模块变化幅度")
                Spacer()
                if !barBuckets.isEmpty {
                    Text("\(barBuckets.count) 期")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("幅度按「本期期末 - 本期期初」计算，累计值等于上方所有柱子之和。")
        }
    }

    private func amplitudeRow(_ row: CategoryDeltaRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.category.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(row.category.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.category.title)
                    .font(.subheadline)
                Text("期初 \(AmountFormatter.wan(row.startValue, symbol: false))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Text(AmountFormatter.wan(row.endValue, symbol: false))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Text(tintText(for: row.delta))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint(for: row.delta))
                }
                HStack(spacing: 4) {
                    Text(deltaText(row.delta))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(tint(for: row.delta))
                    if let ratio = row.ratio {
                        Text("（\(AmountFormatter.percent(ratio))）")
                            .font(.caption2)
                            .foregroundStyle(tint(for: row.delta))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func deltaText(_ delta: Double) -> String {
        delta == 0 ? "持平" : AmountFormatter.signed(delta)
    }

    private func tintText(for delta: Double) -> String {
        guard delta != 0 else { return "" }
        return delta > 0 ? "▲" : "▼"
    }

    /// 涨红跌绿，与整个 App 的口径一致
    private func tint(for delta: Double) -> Color {
        if delta > 0 { return .red }
        if delta < 0 { return .green }
        return .secondary
    }

    // MARK: - 区间统计

    private var statsSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                statTile(
                    title: "最新",
                    value: AmountFormatter.number(visiblePoints.last?.total ?? 0),
                    unit: "万",
                    tint: .primary,
                    subtitle: nil
                )

                statTile(
                    title: "区间变化",
                    value: changeText,
                    unit: changeValue == nil ? nil : "万",
                    tint: changeTint,
                    subtitle: ratioText
                )

                statTile(
                    title: "区间最高",
                    value: AmountFormatter.number(visiblePoints.map(\.maximum).max() ?? 0),
                    unit: "万",
                    tint: .primary,
                    subtitle: nil
                )

                statTile(
                    title: "区间最低",
                    value: AmountFormatter.number(visiblePoints.map(\.minimum).min() ?? 0),
                    unit: "万",
                    tint: .primary,
                    subtitle: nil
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("区间统计（\(period.pickerTitle)）")
        } footer: {
            Text("本屏 \(visiblePoints.count) 个数据点；\(period.bucketDescription)。")
        }
    }

    private var changeValue: Double? {
        guard visiblePoints.count > 1, let first = visiblePoints.first, let last = visiblePoints.last else { return nil }
        return last.total - first.total
    }

    /// 只有数值，单位由 statTile 的 unit 负责，避免出现「万 万」
    private var changeText: String {
        guard let changeValue else { return "—" }
        return AmountFormatter.signedNumber(changeValue)
    }

    private var ratioText: String? {
        guard let changeValue, let first = visiblePoints.first, first.total != 0 else {
            return nil
        }
        return AmountFormatter.percent(changeValue / abs(first.total) * 100)
    }

    private var changeTint: Color {
        guard let changeValue else { return .primary }
        if changeValue > 0 { return .red }
        if changeValue < 0 { return .green }
        return .primary
    }

    private func statTile(
        title: String,
        value: String,
        unit: String?,
        tint: Color,
        subtitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color(.secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // MARK: - 空状态

    private var emptySection: some View {
        Section {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyDescription)
            } actions: {
                // 视图切换必须在这里也留一个入口：
                // 切到复合/某个类别后如果没有足够数据，图表 Section 整个不渲染，
                // 挂在它 header 上的菜单就跟着消失——用户会被困在这个视图里出不去。
                scopeMenu
                    .buttonStyle(.bordered)
                if case .total = scope {
                    Button("立即记录今天") {
                        store.recordSnapshotForToday()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .total: "还没有资产记录"
        case .composite: "还不够画出变化"
        case .category(let category): "还没有\(category.title)的记录"
        }
    }

    private var emptySymbol: String {
        switch scope {
        case .total: "chart.xyaxis.line"
        case .composite: "chart.bar"
        case .category(let category): category.symbolName
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .total:
            return "到「资产」页添加或修改条目，就会自动记录当天的总资产。"
        case .composite:
            return compositeEmptyDescription
        case .category:
            return categoryEmptyDescription
        }
    }

    /// 分类明细是按天记的，起点晚于总资产。空状态要把这个起点说出来，
    /// 而不是画一条 0 值曲线冒充历史。
    private var trackingStartText: String {
        guard let start = store.categoryTrackingStartDay else {
            return "分类明细还没有开始记录，改动一次资产后就会有。"
        }
        return "分类明细自 \(DateDisplay.fullDay(start)) 起记录，更早的日期只有总资产。"
    }

    private var compositeEmptyDescription: String {
        if store.categoryTrackingStartDay == nil {
            return trackingStartText
        }
        return "复合视图至少需要两期分类明细才能比出变化。\(trackingStartText)"
    }

    private var categoryEmptyDescription: String {
        if store.categoryTrackingStartDay == nil {
            return trackingStartText
        }
        return "这一类还没有金额记录。\(trackingStartText)"
    }

    // MARK: - 历史记录

    private var historySection: some View {
        Section {
            if rows.isEmpty {
                Text("还没有任何记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleRows) { row in
                    historyRow(row)
                }
                if rows.count > collapsedHistoryCount {
                    Button(showAllHistory ? "收起" : "显示全部 \(rows.count) 天记录") {
                        withAnimation(.snappy) { showAllHistory.toggle() }
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            HStack {
                Text("历史记录")
                Spacer()
                Text("共 \(rows.count) 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !rows.isEmpty {
                Text("每天只保留一条记录，同一天多次修改会覆盖为最新值。")
            }
        }
    }

    private func historyRow(_ row: SnapshotHistoryRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(DateDisplay.fullDay(row.snapshot.day))
                    .font(.subheadline)
                HStack(spacing: 6) {
                    Text("\(row.snapshot.itemCount) 个条目")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if row.snapshot.wasRevised {
                        Text("已更新")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(AmountFormatter.wan(row.snapshot.totalAmount))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                changeLabel(row.change)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func changeLabel(_ change: Double?) -> some View {
        if let change {
            if change == 0 {
                Text("持平")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(AmountFormatter.signed(change))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(change > 0 ? .red : .green)
            }
        } else {
            Text("首次记录")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    TrendView()
        .environment(AssetStore())
}
