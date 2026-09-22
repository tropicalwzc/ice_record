// 裁剪 PNG 的指定区域并按倍数放大，便于肉眼核对细节。
// 用法：swift Tools/crop_png.swift <输入> <输出> <x> <y> <w> <h> [放大倍数]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 7 else {
    print("用法: crop_png.swift <输入> <输出> <x> <y> <w> <h> [scale]")
    exit(1)
}
let scale = a.count > 7 ? (Double(a[7]) ?? 1) : 1
let rect = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)

guard
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
    let cropped = image.cropping(to: rect)
else {
    print("裁剪失败")
    exit(1)
}

let outW = Int(Double(cropped.width) * scale)
let outH = Int(Double(cropped.height) * scale)
guard
    let ctx = CGContext(
        data: nil,
        width: outW,
        height: outH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
else {
    print("无法创建上下文")
    exit(1)
}
ctx.interpolationQuality = .none
ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
guard let out = ctx.makeImage() else { exit(1) }

guard
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: a[2]) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    print("无法写入")
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("已输出 \(a[2])  \(outW)x\(outH)")
