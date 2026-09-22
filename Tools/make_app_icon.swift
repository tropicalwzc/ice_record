// 生成 App 图标（1024x1024 PNG）
// 用法：swift Tools/make_app_icon.swift <输出路径>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let width = CGFloat(side)
let height = CGFloat(side)

guard
    let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    fatalError("无法创建绘图上下文")
}

// 背景渐变（深蓝 → 亮蓝）
let colorSpace = CGColorSpaceCreateDeviceRGB()
let backgroundColors = [
    CGColor(colorSpace: colorSpace, components: [0.06, 0.16, 0.38, 1])!,
    CGColor(colorSpace: colorSpace, components: [0.13, 0.42, 0.72, 1])!
] as CFArray
let background = CGGradient(colorsSpace: colorSpace, colors: backgroundColors, locations: [0, 1])!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 0, y: height),
    end: CGPoint(x: width, y: 0),
    options: []
)

// 柔光装饰
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.20])!,
        CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.0])!
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: width * 0.24, y: height * 0.90),
    startRadius: 0,
    endCenter: CGPoint(x: width * 0.24, y: height * 0.90),
    endRadius: width * 0.62,
    options: []
)

// 折线数据点（归一化坐标，原点在左下）
let normalized: [(CGFloat, CGFloat)] = [
    (0.16, 0.30),
    (0.33, 0.44),
    (0.47, 0.35),
    (0.63, 0.56),
    (0.83, 0.76)
]
let points = normalized.map { CGPoint(x: $0.0 * width, y: $0.1 * height) }

// 折线下方的面积填充
let area = CGMutablePath()
area.move(to: CGPoint(x: points[0].x, y: height * 0.16))
area.addLine(to: points[0])
for point in points.dropFirst() {
    area.addLine(to: point)
}
area.addLine(to: CGPoint(x: points[points.count - 1].x, y: height * 0.16))
area.closeSubpath()

let areaGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.34])!,
        CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.04])!
    ] as CFArray,
    locations: [0, 1]
)!
context.saveGState()
context.addPath(area)
context.clip()
context.drawLinearGradient(
    areaGradient,
    start: CGPoint(x: 0, y: height * 0.80),
    end: CGPoint(x: 0, y: height * 0.16),
    options: []
)
context.restoreGState()

// 折线
let line = CGMutablePath()
line.move(to: points[0])
for point in points.dropFirst() {
    line.addLine(to: point)
}
context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
context.setLineWidth(width * 0.058)
context.setLineCap(.round)
context.setLineJoin(.round)
context.addPath(line)
context.strokePath()

// 数据点
for (index, point) in points.enumerated() {
    let isLast = index == points.count - 1
    let radius = width * (isLast ? 0.052 : 0.032)
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.fillEllipse(
        in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    )
    if isLast {
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.13, 0.42, 0.72, 1])!)
        let inner = radius * 0.45
        context.fillEllipse(
            in: CGRect(x: point.x - inner, y: point.y - inner, width: inner * 2, height: inner * 2)
        )
    }
}

guard let image = context.makeImage() else { fatalError("无法生成图片") }

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"
let url = URL(fileURLWithPath: outputPath)
guard
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    fatalError("无法写入 \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("写入失败") }
print("已生成 \(outputPath)")
