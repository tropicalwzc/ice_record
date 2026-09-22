import SwiftUI

struct AssetsView: View {
    @Environment(AssetStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @State private var editorTarget: EditorTarget?

    var body: some View {
        NavigationStack {
            List {
                if let warning = syncWarning {
                    syncWarningSection(warning)
                }
                summarySection
                if !store.categoryTotals.isEmpty {
                    breakdownSection
                }
                itemsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的资产")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.items.count > 1 {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorTarget = EditorTarget(item: nil)
                    } label: {
                        Label("新增条目", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addItemButton")
                }
            }
            .sheet(item: $editorTarget) { target in
                AssetEditorView(item: target.item)
            }
            .alert("操作失败", isPresented: errorBinding) {
                Button("好") { store.clearErrorMessage() }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
        }
    }

    // MARK: - 顶部总资产

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("总资产")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AmountFormatter.number(store.totalAmount))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: store.totalAmount)
                    Text("万")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("totalAmountLabel")

                Text("≈ \(AmountFormatter.yuan(store.totalAmount)) 元")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let change = store.changeSincePreviousSnapshot {
                        deltaChip(change: change, ratio: store.changeRatioSincePreviousSnapshot)
                    }
                    recordStatusChip
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 6)
        }
    }

    private func deltaChip(change: Double, ratio: Double?) -> some View {
        let tint: Color = change > 0 ? .red : (change < 0 ? .green : .secondary)
        let symbol = change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "equal")
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2.weight(.black))
            Text(AmountFormatter.signed(change))
            if let ratio {
                Text("(\(AmountFormatter.percent(ratio)))")
                    .foregroundStyle(tint.opacity(0.75))
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private var recordStatusChip: some View {
        let recorded = store.isTodayRecorded
        let tint: Color = recorded ? .accentColor : .orange
        let content = HStack(spacing: 4) {
            Image(systemName: recorded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(recorded ? "今日已记录" : "今日未记录")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())

        if recorded {
            content
        } else {
            Button {
                store.recordSnapshotForToday()
            } label: {
                content
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 类别占比

    private var breakdownSection: some View {
        Section("类别占比") {
            ForEach(store.categoryTotals, id: \.category) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.category.symbolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.category.tint)
                            .frame(width: 18)
                        Text(entry.category.title)
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(AmountFormatter.wan(entry.amount))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        Text(percentText(entry.amount))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    ProgressView(value: max(entry.amount, 0), total: max(store.totalAmount, 0.0001))
                        .progressViewStyle(.linear)
                        .tint(entry.category.tint)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func percentText(_ amount: Double) -> String {
        guard store.totalAmount != 0 else { return "—" }
        return AmountFormatter.number(amount / store.totalAmount * 100, digits: 1) + "%"
    }

    // MARK: - 条目列表

    private var itemsSection: some View {
        Section {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("还没有资产条目", systemImage: "tray")
                } description: {
                    Text("点击右上角 + 添加，例如「股票 10.5 万」。\n如果别的设备已经记过，同步回来后会出现在这里。")
                } actions: {
                    Button("添加条目") { editorTarget = EditorTarget(item: nil) }
                        .buttonStyle(.borderedProminent)
                    Button("添加示例条目") { store.addExampleItems() }
                        .accessibilityIdentifier("addExampleItemsButton")
                }
            } else {
                ForEach(store.items) { item in
                    Button {
                        editorTarget = EditorTarget(item: item)
                    } label: {
                        AssetItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.deleteItems(withIDs: offsets.map { store.items[$0].id })
                }
                .onMove { source, destination in
                    store.moveItems(from: source, to: destination)
                }
            }
        } header: {
            HStack {
                Text("资产条目")
                Spacer()
                Text("单位：万")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !store.items.isEmpty {
                Text("点击修改，左滑删除，长按拖动可排序。任何一次改动都会自动重算总资产并写入今天的快照。")
            }
        }
    }

    // MARK: - iCloud 同步异常提示
    //
    // 正常同步时这里什么都不显示，只有出问题才提醒，避免主页面变啰嗦。

    private var syncWarning: String? {
        if let failure = sync.lastWarningMessage {
            return "iCloud 同步部分失败：\(failure)"
        }
        if case .failed(let message) = sync.status {
            return "iCloud 同步失败：\(message)"
        }
        // .unavailable（没登录 iCloud）不算故障，只在设置页说明，不打扰主页面
        return nil
    }

    private func syncWarningSection(_ message: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.footnote)
                    Button("重试") {
                        Task { await sync.syncNow() }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.clearErrorMessage() } }
        )
    }
}

// MARK: - 行视图

private struct AssetItemRow: View {
    let item: AssetItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(item.category.tint.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: item.category.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.category.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(AmountFormatter.wan(item.amount))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("≈ \(AmountFormatter.yuan(item.amount)) 元")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let trimmedNote = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNote.isEmpty ? item.category.title : "\(item.category.title) · \(trimmedNote)"
    }
}

// MARK: - 弹窗目标

private struct EditorTarget: Identifiable {
    let id = UUID()
    /// nil 表示新建
    let item: AssetItem?
}

#Preview {
    AssetsView()
        .environment(AssetStore())
        .environment(SyncCoordinator(database: .shared, transport: DisabledSyncTransport()))
}
