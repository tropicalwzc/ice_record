import Charts
import SwiftUI
import UIKit

/// 资产变化曲线：按 日 / 周 / 月 / 年 统计，下面附带历史记录用于检索查看。
struct TrendView: View {
    @Environment(AssetStore.self) private var store

    @State private var period: StatsPeriod = .day

    @State private var selectedDate: Date?
    @State private var showAllHistory = false
    /// 图表实际宽度，用来决定横轴放几个日期刻度
    @State private var chartWidth: CGFloat = 0

    private let collapsedHistoryCount = 30

    private var points: [TrendPoint] { store.trend(for: period) }
    private var rows: [SnapshotHistoryRow] { store.historyRows() }
    private var visibleRows: [SnapshotHistoryRow] {
        showAllHistory ? rows : Array(rows.prefix(collapsedHistoryCount))
    }

    var body: some View {
        NavigationStack {
            List {
                periodSection

                if points.isEmpty {
                    emptySection
                } else {
                    chartSection
                    statsSection
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
            }
        } footer: {
            Text(period.bucketDescription)
        }
    }

    // MARK: - 曲线

    private var chartSection: some View {
        Section {
            chart(points)
                .frame(height: 240)
                .padding(.top, 6)
                .padding(.bottom, 2)
        } header: {
            HStack {
                Text("总资产曲线")
                Spacer()
                Text("单位：万")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("长按曲线可以查看某个点的具体数值。")
        }
    }

    @ViewBuilder
    private func chart(_ points: [TrendPoint]) -> some View {
        let tickDates = xAxisDates(points)

        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    y: .value("总资产", point.total)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("总资产", point.total)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)

                if points.count <= 40 {
                    PointMark(
                        x: .value("日期", point.date),
                        y: .value("总资产", point.total)
                    )
                    .foregroundStyle(Color.accentColor)
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
                    y: .value("总资产", selected.total)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(90)
                .annotation(
                    position: calloutPosition(for: selected, in: points),
                    spacing: 10,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    selectionCallout(selected)
                }
            }
        }
        .chartXScale(domain: xDomain(points))
        .chartYScale(domain: yDomain(points))
        .chartXAxis {
            // 刻度日期自己算（见 xAxisDates / TrendAxis）：按时间等距，且不落在数据范围之外，
            // 不会出现系统自动生成刻度被挤到边缘后互相重叠、被截断的情况。
            AxisMarks(values: tickDates) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                if let date = value.as(Date.self) {
                    // 关掉系统自带的「碰撞处理」：它会按自己的判断把贴边的日期截成省略号
                    // （实测 18.4 / 26 上末位日期被截成「1…」）。间距由 TrendAxis 按真实文字宽度保证。
                    AxisValueLabel(collisionResolution: .disabled) {
                        axisLabelText(for: date, in: tickDates)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel()
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

    /// 横轴刻度对应的日期：在首尾数据点之间按**时间**等距取，
    /// 再用**渲染时同一套字体量出来的文字宽度**收敛数量（见 TrendAxis.fittingTickDates）。
    private func xAxisDates(_ points: [TrendPoint]) -> [Date] {
        guard let first = points.first?.date, let last = points.last?.date else { return [] }
        return TrendAxis.fittingTickDates(
            from: first,
            to: last,
            edgePadding: xAxisEdgePadding(points),
            period: period,
            limit: maxAxisTickCount,
            plotWidth: plotWidth,
            minimumGap: Self.axisLabelMinimumGap,
            labelWidth: axisLabelWidth
        )
    }

    /// 绘图区宽度：图表总宽扣掉左侧纵轴标签占的一截。
    ///
    /// 纵轴标签可能比较宽（「211.5」这种 5 位数），这里按偏小的值估算：
    /// 估小了只会让日期刻度少放一个、往中间收一点，都不会叠字；
    /// 估大了才会把标签顶到绘图区外面被截断。
    private var plotWidth: CGFloat {
        max(chartWidth - 64, 0)
    }

    /// 刻度数量的上界，实际数量由 TrendAxis 按文字宽度收敛。
    private var maxAxisTickCount: Int {
        min(5, max(2, Int(plotWidth / 56)))
    }

    // MARK: - 横轴标签量宽

    static let axisLabelFontSize: CGFloat = 11
    /// 相邻两个日期刻度之间至少要留出的空隙
    static let axisLabelMinimumGap: CGFloat = 14

    /// 和 AxisValueLabel 里渲染用的字体保持一致，量出来的宽度才是真的
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

    /// 横轴刻度文字。
    ///
    /// 一律**居中**放在刻度上，刻意不碰 `AxisValueLabel(anchor:)`：
    /// 不同 iOS 版本对 anchor 的解释不一样（同一份代码在 iOS 18 / 26 上居中，
    /// 在 iOS 27 上变成左对齐，末尾两个日期就直接叠在一起——实测「10月1日」压在「9月28日」上）。
    /// 贴边那半个字宽的位置，改由 x 轴两端的时间留白让出来（见 `xAxisEdgePadding`）。
    private func axisLabelText(for date: Date, in dates: [Date]) -> some View {
        Text(TrendAxis.label(for: period, on: date, isRangeStart: date == dates.first))
            .font(.system(size: Self.axisLabelFontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// 首尾日期在绘图区两端各留出的时间白边：正好让「居中的整字标签」落进绘图区。
    private func xAxisEdgePadding(_ points: [TrendPoint]) -> TimeInterval {
        guard let first = points.first?.date, let last = points.last?.date, first < last else { return 0 }

        let span = last.timeIntervalSince(first)
        let halfLabel = axisEdgeHalfWidth(points)
        guard plotWidth > halfLabel * 2 + 1 else { return span * TrendAxis.domainPaddingRatio }

        // 解 halfLabel / plotWidth = padding / (span + 2 * padding)
        return halfLabel * span / (plotWidth - halfLabel * 2)
    }

    /// 首尾刻度标签的半个宽度（取两者较宽的那个，月粒度可能带年份）。
    /// 多留 8pt：坐标轴标签区比绘图区略窄，留一点富余免得贴边日期被顶出去。
    private func axisEdgeHalfWidth(_ points: [TrendPoint]) -> CGFloat {
        let firstLabel = TrendAxis.label(for: period, on: points.first?.date ?? .now, isRangeStart: true)
        let lastLabel = TrendAxis.label(for: period, on: points.last?.date ?? .now, isRangeStart: false)
        return max(axisLabelWidth(firstLabel), axisLabelWidth(lastLabel)) / 2 + 8
    }

    /// 选中的点画在绘图区上半部分时，气泡朝下弹；否则朝上弹。
    /// 这样气泡永远不会跑出绘图区（也就不会被裁掉）。
    private func calloutPosition(for point: TrendPoint, in points: [TrendPoint]) -> AnnotationPosition {
        let domain = yDomain(points)
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
        // 两端留白和 TrendAxis 里算刻度位置时用的是同一个值：
        // 半个标签宽，保证居中的首尾日期完整落在绘图区内
        let padding = xAxisEdgePadding(points)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    private var singlePointSpan: TimeInterval {
        let day: TimeInterval = 86_400
        switch period {
        case .day: return 2 * day
        case .week: return 14 * day
        case .month: return 62 * day
        case .year: return 2 * 365 * day
        }
    }

    private func yDomain(_ points: [TrendPoint]) -> ClosedRange<Double> {
        let values = points.map(\.total)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        if minimum == maximum {
            let padding = max(abs(minimum) * 0.1, 1)
            return (minimum - padding)...(maximum + padding)
        }
        let padding = (maximum - minimum) * 0.18
        return (minimum - padding)...(maximum + padding)
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
                    value: AmountFormatter.number(points.last?.total ?? 0),
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
                    value: AmountFormatter.number(points.map(\.maximum).max() ?? 0),
                    unit: "万",
                    tint: .primary,
                    subtitle: nil
                )

                statTile(
                    title: "区间最低",
                    value: AmountFormatter.number(points.map(\.minimum).min() ?? 0),
                    unit: "万",
                    tint: .primary,
                    subtitle: nil
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("区间统计（\(period.pickerTitle)）")
        } footer: {
            Text("共 \(points.count) 个数据点；\(period.bucketDescription)。")
        }
    }

    private var changeValue: Double? {
        guard points.count > 1, let first = points.first, let last = points.last else { return nil }
        return last.total - first.total
    }

    /// 只有数值，单位由 statTile 的 unit 负责，避免出现「万 万」
    private var changeText: String {
        guard let changeValue else { return "—" }
        return AmountFormatter.signedNumber(changeValue)
    }

    private var ratioText: String? {
        guard let changeValue, let first = points.first, first.total != 0 else {
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
                Label("还没有资产记录", systemImage: "chart.xyaxis.line")
            } description: {
                Text("到「资产」页添加或修改条目，就会自动记录当天的总资产。")
            } actions: {
                Button("立即记录今天") {
                    store.recordSnapshotForToday()
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
