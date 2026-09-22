import SwiftUI

/// 新增 / 编辑一条资产条目。
struct AssetEditorView: View {
    /// nil 表示新建
    let item: AssetItem?

    @Environment(AssetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: AssetCategory = .cash
    @State private var amountText: String = ""
    @State private var note: String = ""
    @FocusState private var isAmountFocused: Bool

    private var isEditing: Bool { item != nil }

    private var parsedAmount: Double? { AmountFormatter.parse(amountText) }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保存之后今天的总资产会变成多少
    private var projectedTotal: Double {
        store.totalAmount - (item?.amount ?? 0) + (parsedAmount ?? 0)
    }

    private var canSave: Bool {
        guard let amount = parsedAmount else { return false }
        return !trimmedName.isEmpty && amount >= 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称与类别") {
                    TextField("例如：股票", text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .accessibilityIdentifier("itemNameField")

                    Picker("类别", selection: $category) {
                        ForEach(AssetCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbolName).tag(category)
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .focused($isAmountFocused)
                            .accessibilityIdentifier("itemAmountField")
                        Text("万")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("金额")
                } footer: {
                    if let amount = parsedAmount {
                        Text("≈ \(AmountFormatter.yuan(amount)) 元")
                    } else {
                        Text("支持小数，例如 10.5 表示 10.5 万（105,000 元）。")
                    }
                }

                Section("备注") {
                    TextField("可选，例如：券商 A / 活期", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    LabeledContent("今日总资产") {
                        Text(AmountFormatter.wan(projectedTotal))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    LabeledContent("折合人民币") {
                        Text("\(AmountFormatter.yuan(projectedTotal)) 元")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("保存后")
                } footer: {
                    Text("保存后会自动把今天（\(DateDisplay.fullDay(.now))）的总资产写入本地数据库，同一天重复修改只保留最新值。")
                }
            }
            .navigationTitle(isEditing ? "编辑条目" : "新增条目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveItemButton")
                }
            }
            .onAppear(perform: fillFromItem)
        }
    }

    private func fillFromItem() {
        guard let item else {
            isAmountFocused = true
            return
        }
        name = item.name
        category = item.category
        amountText = AmountFormatter.editingText(item.amount)
        note = item.note
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        if let item {
            store.updateItem(
                id: item.id,
                name: trimmedName,
                amount: amount,
                category: category,
                note: trimmedNote
            )
        } else {
            store.addItem(
                name: trimmedName,
                amount: amount,
                category: category,
                note: trimmedNote
            )
        }
        dismiss()
    }
}

#Preview("新增") {
    AssetEditorView(item: nil)
        .environment(AssetStore())
}

#Preview("编辑") {
    AssetEditorView(item: AssetItem(name: "股票", amount: 10.5, category: .stock))
        .environment(AssetStore())
}
