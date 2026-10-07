import AppKit

// 生成应用图标各尺寸 PNG（供 iconutil 打包 .icns）
// 用法: swift make_icon.swift <输出目录 AppIcon.iconset>

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 背景：GitLab 橙渐变 + 大圆角（macOS 图标风格，四周留 10% 边距）
let inset = size * 0.1
let radius = size * 0.185
let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
bg.addClip()
if let gradient = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.52, blue: 0.18, alpha: 1),
                             ending: NSColor(calibratedRed: 0.86, green: 0.25, blue: 0.13, alpha: 1)) {
    gradient.draw(in: bg, angle: -90)
}

// 管线：三个节点连线（构建 → 部署 → 通过）
let nodes = [NSPoint(x: size * 0.34, y: size * 0.34),
             NSPoint(x: size * 0.50, y: size * 0.50),
             NSPoint(x: size * 0.66, y: size * 0.66)]

let line = NSBezierPath()
line.lineWidth = size * 0.042
line.lineCapStyle = .round
line.move(to: nodes[0])
line.line(to: nodes[1])
line.line(to: nodes[2])
NSColor.white.setStroke()
line.stroke()

// 前两个节点：淡色填充 + 白描边
for p in [nodes[0], nodes[1]] {
    let r = size * 0.075
    let circle = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    NSColor(calibratedRed: 0.99, green: 0.82, blue: 0.68, alpha: 1).setFill()
    circle.fill()
    NSColor.white.setStroke()
    circle.lineWidth = size * 0.035
    circle.stroke()
}

// 最后一个节点：实心白圆 + 橙色对勾
let r2 = size * 0.095
let done = NSBezierPath(ovalIn: NSRect(x: nodes[2].x - r2, y: nodes[2].y - r2, width: 2 * r2, height: 2 * r2))
NSColor.white.setFill()
done.fill()
let check = NSBezierPath()
check.lineWidth = size * 0.030
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.13, alpha: 1).setStroke()
check.move(to: NSPoint(x: nodes[2].x - r2 * 0.45, y: nodes[2].y - r2 * 0.02))
check.line(to: NSPoint(x: nodes[2].x - r2 * 0.08, y: nodes[2].y - r2 * 0.40))
check.line(to: NSPoint(x: nodes[2].x + r2 * 0.50, y: nodes[2].y + r2 * 0.40))
check.stroke()

image.unlockFocus()

func writePNG(_ pixel: Int, _ name: String, _ dir: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: dir + "/" + name))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
writePNG(16, "icon_16x16.png", outDir)
writePNG(32, "icon_16x16@2x.png", outDir)
writePNG(32, "icon_32x32.png", outDir)
writePNG(64, "icon_32x32@2x.png", outDir)
writePNG(128, "icon_128x128.png", outDir)
writePNG(256, "icon_128x128@2x.png", outDir)
writePNG(256, "icon_256x256.png", outDir)
writePNG(512, "icon_256x256@2x.png", outDir)
writePNG(512, "icon_512x512.png", outDir)
writePNG(1024, "icon_512x512@2x.png", outDir)
print("iconset 已生成: \(outDir)")
