import Foundation

/// 金额格式化工具。
///
/// 全 App 的统一口径是 **万元**：数据库、模型、图表纵轴全部存/显示“万”。
enum AmountFormatter {

    /// 数值 → 带千分位的字符串，例如 12345.6 → "12,345.60"
    static func number(_ value: Double, digits: Int = 2) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(digits))
                .grouping(.automatic)
        )
    }

    /// 万 → "10.50 万"
    static func wan(_ value: Double, digits: Int = 2, symbol: Bool = true) -> String {
        let text = number(value, digits: digits)
        return symbol ? "\(text) 万" : text
    }

    /// 万 → 元，例如 10.5 → "105,000"
    static func yuan(_ value: Double) -> String {
        number(value * 10_000, digits: 0)
    }

    /// 大额时附带“亿”换算，否则退回“万”
    static func compact(_ value: Double) -> String {
        if abs(value) >= 10_000 {
            return "\(number(value / 10_000, digits: 2)) 亿"
        }
        return wan(value)
    }

    /// 带符号的数值，不带单位，例如 +0.20 / -1.30
    static func signedNumber(_ value: Double, digits: Int = 2) -> String {
        "\(signPrefix(value))\(number(abs(value), digits: digits))"
    }

    /// 带符号的增量，例如 +0.20 万 / -1.30 万
    static func signed(_ value: Double, digits: Int = 2) -> String {
        "\(signedNumber(value, digits: digits)) 万"
    }

    /// 带符号的百分比
    static func percent(_ value: Double) -> String {
        "\(signPrefix(value))\(number(abs(value), digits: 2))%"
    }

    /// 纵轴刻度用的整数文本：`211.5` → `212`，`0.4` → `0`
    ///
    /// 纵轴只承担「定位」，精度由长按气泡和下方的幅度列表负责。
    /// 带小数会让纵轴标签宽出七八个点，那点宽度是从绘图区身上割的。
    static func axisInteger(_ value: Double) -> String {
        number(value.rounded(), digits: 0)
    }

    /// 纵轴刻度文案：步长够大就用整数；只有变化量小到零点几万时才保留一位小数
    /// （那种量级下强行取整，整根轴上只会剩一根「0」，等于没有刻度）。
    /// 小数步长下整数值仍然写成整数，避免一排「19.0 / 19.5 / 20.0」里混着没意义的 .0。
    static func axisTick(_ value: Double, step: Double) -> String {
        if step >= 1 || value == value.rounded() {
            return axisInteger(value)
        }
        return number(value, digits: 1)
    }

    private static func signPrefix(_ value: Double) -> String {
        if value > 0 { return "+" }
        if value < 0 { return "-" }
        return ""
    }

    /// 解析用户输入的金额文本（容忍中文逗号、空格、千分位）
    static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// 把 Double 回填到输入框时使用，去掉无意义的小数 0
    static func editingText(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
