import Charts
import SwiftUI
import UIKit

/// 资产变化曲线：按 日 / 周 / 月 / 年 统计，下面附带历史记录用于检索查看。
struct TrendView: View {
    @Environment(AssetStore.self) private var store

    @State private var period: StatsPeriod = .day
    @State private var selectedDate: Date?
    @State private var showAllHistory = false

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
            AxisMarks(preset: .extended, values: xAxisValues(points)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel(format: period.axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityIdentifier("trendChart")
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

    private func xAxisValues(_ points: [TrendPoint]) -> AxisMarkValues {
        switch period {
        case .day, .week, .month:
            return .automatic(desiredCount: 4)
        case .year:
            // 按整年分刻度，避免同一年被标成多个重复的 "yyyy"
            let years = Set(points.map { DayKey.calendar.component(.year, from: $0.date) }).count
            return .stride(by: .year, count: years > 6 ? 2 : 1)
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
        let padding = last.timeIntervalSince(first) * 0.03
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
