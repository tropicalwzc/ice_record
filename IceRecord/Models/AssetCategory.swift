import SwiftUI

/// 资产类别。只影响展示（图标 / 配色 / 分类占比），不参与计算。
enum AssetCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case stock
    case fund
    case cash
    case deposit
    case property
    case crypto
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stock: "股票"
        case .fund: "基金"
        case .cash: "流动资金"
        case .deposit: "存款理财"
        case .property: "房产"
        case .crypto: "数字资产"
        case .other: "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .stock: "chart.line.uptrend.xyaxis"
        case .fund: "chart.pie"
        case .cash: "banknote"
        case .deposit: "building.columns"
        case .property: "house"
        case .crypto: "bitcoinsign.circle"
        case .other: "shippingbox"
        }
    }

    var tint: Color {
        switch self {
        case .stock: .red
        case .fund: .orange
        case .cash: .green
        case .deposit: .blue
        case .property: .purple
        case .crypto: .pink
        case .other: .gray
        }
    }
}
