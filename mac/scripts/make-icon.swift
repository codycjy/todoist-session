// 生成 App 图标（不依赖设计工具，用 Ink 配色直接画）。
// 用法：swift scripts/make-icon.swift [方案]     → Assets/AppIcon.icns（默认 now）
//       swift scripts/make-icon.swift preview <png>  → 所有方案的对比图
// 方案：ruler 进度尺 / block 时间块 / mark 墨底方块 / span 时间括号 / focus 回字 /
//       letter 字母 S / page 日程页 / now 当前线 / cursor 终端光标
import AppKit
import CoreGraphics

for w in ["Bold", "Medium"] {
    let url = URL(fileURLWithPath: "Sources/SessionApp/Resources/Fonts/JetBrainsMono-\(w).ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

func rgb(_ h: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}
let paper = 0xF2F3EF, panel = 0xFBFBF8, ink = 0x0F120F, rule = 0xCBD0C6, hi = 0xF4DD3F, faint = 0x6E756D

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
func squircle() -> CGPath { CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil) }

func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 系统图标规范的柔和投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0.28))
    ctx.addPath(squircle()); ctx.setFillColor(rgb(paper)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squircle()); ctx.clip()
    draw(ctx)
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// 硬投影卡片：先画偏移的实心墨块，再画带墨线边框的面。
func hardCard(_ ctx: CGContext, _ r: CGRect, fill: Int, border: CGFloat, shadow: CGFloat) {
    ctx.setFillColor(rgb(ink)); ctx.fill(r.offsetBy(dx: shadow, dy: -shadow))
    ctx.setFillColor(rgb(fill)); ctx.fill(r)
    ctx.setStrokeColor(rgb(ink)); ctx.setLineWidth(border); ctx.stroke(r.insetBy(dx: border / 2, dy: border / 2))
}

// A 刻度尺：进度尺的放大版——荧光笔涂到 60%，下面每分钟一刻度。
let ruler = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    let bar = CGRect(x: 214, y: 470, width: 572, height: 150)
    ctx.setFillColor(rgb(ink)); ctx.fill(bar.offsetBy(dx: 26, dy: -26))
    ctx.setFillColor(rgb(panel)); ctx.fill(bar)
    ctx.setFillColor(rgb(hi)); ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * 0.6, height: bar.height))
    ctx.setStrokeColor(rgb(ink)); ctx.setLineWidth(22); ctx.stroke(bar.insetBy(dx: 11, dy: 11))
    let n = 10
    for i in 0...n {
        let x = bar.minX + 11 + (bar.width - 22) * CGFloat(i) / CGFloat(n)
        let long = i % 5 == 0
        ctx.setFillColor(rgb(long ? ink : faint))
        ctx.fill(CGRect(x: x - 7, y: bar.minY - 26 - 30 - (long ? 70 : 34), width: 14, height: long ? 70 : 34))
    }
}

// B 时间块：日程纸上的一块「实际」专注，左边分类色条，后面是虚线的「计划」块。
let block = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    ctx.setFillColor(rgb(rule))
    for y in [300, 512, 724] { ctx.fill(CGRect(x: 100, y: CGFloat(y) - 4, width: 824, height: 8)) }
    // 计划（虚线框）
    ctx.setStrokeColor(rgb(faint)); ctx.setLineWidth(14); ctx.setLineDash(phase: 0, lengths: [30, 22])
    ctx.stroke(CGRect(x: 214, y: 470, width: 300, height: 300))
    ctx.setLineDash(phase: 0, lengths: [])
    // 实际（荧光黄、墨框、硬投影）
    let r = CGRect(x: 390, y: 236, width: 400, height: 400)
    hardCard(ctx, r, fill: hi, border: 22, shadow: 26)
    ctx.setFillColor(rgb(ink)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: 46, height: r.height))
}

// C 标记：墨底上一块荧光方块（侧栏 logo 的方块），下面一排刻度。
let mark = canvas { ctx in
    ctx.setFillColor(rgb(ink)); ctx.fill(body)
    let sq = CGRect(x: 302, y: 372, width: 420, height: 420)
    ctx.setFillColor(rgb(hi)); ctx.fill(sq)
    for i in 0...10 {
        let x = 302 + 420 * CGFloat(i) / 10
        let long = i % 5 == 0
        ctx.setFillColor(rgb(long ? 0xEEF1EC : 0x838B82))
        ctx.fill(CGRect(x: x - 7, y: 330 - (long ? 92 : 50), width: 14, height: long ? 92 : 50))
    }
}

let now = 0xE0442B

func monoText(_ ctx: CGContext, _ text: String, size: CGFloat, color: Int, at p: CGPoint, weight: String = "Bold") {
    let font = CTFontCreateWithName("JetBrainsMono-\(weight)" as CFString, size, nil)
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(color)])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = p
    CTLineDraw(line, ctx)
}
func textWidth(_ text: String, size: CGFloat, weight: String = "Bold") -> CGFloat {
    let font = CTFontCreateWithName("JetBrainsMono-\(weight)" as CFString, size, nil)
    let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
}

// D 时间括号：时间轴上框出的一段，荧光笔涂满括号之间。
let span = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    ctx.setFillColor(rgb(hi)); ctx.fill(CGRect(x: 300, y: 400, width: 424, height: 224))
    ctx.setFillColor(rgb(ink))
    for (x, dir) in [(250.0, 1.0), (774.0, -1.0)] {
        ctx.fill(CGRect(x: x - 18, y: 330, width: 36, height: 364))
        ctx.fill(CGRect(x: dir > 0 ? x - 18 : x - 90, y: 330, width: 108, height: 36))
        ctx.fill(CGRect(x: dir > 0 ? x - 18 : x - 90, y: 658, width: 108, height: 36))
    }
}

// E 回字：一层层收进去的墨框，中心是荧光方块——「专注」。
let focus = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    ctx.setStrokeColor(rgb(ink))
    for (i, inset) in [190.0, 280.0].enumerated() {
        ctx.setLineWidth(i == 0 ? 26 : 22)
        ctx.stroke(CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset))
    }
    hardCard(ctx, CGRect(x: 380, y: 380, width: 264, height: 264), fill: hi, border: 20, shadow: 0)
}

// F 字母 S：荧光底，JetBrains Mono 粗体 S，带硬投影。
let letter = canvas { ctx in
    ctx.setFillColor(rgb(hi)); ctx.fill(body)
    let size: CGFloat = 640, w = textWidth("S", size: size)
    let origin = CGPoint(x: 512 - w / 2, y: 512 - size * 0.36)
    monoText(ctx, "S", size: size, color: ink, at: origin.applying(.init(translationX: 22, y: -22)))
    monoText(ctx, "S", size: size, color: ink, at: origin)
}

// G 日程页：一张纸，一行被荧光笔划出来（今天要专注的那件事）。
let page = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    hardCard(ctx, CGRect(x: 250, y: 200, width: 500, height: 620), fill: panel, border: 20, shadow: 26)
    ctx.setFillColor(rgb(hi)); ctx.fill(CGRect(x: 300, y: 498, width: 400, height: 84))
    ctx.setFillColor(rgb(ink)); ctx.fill(CGRect(x: 320, y: 524, width: 300, height: 30))
    ctx.setFillColor(rgb(rule))
    for (y, w) in [(700.0, 360.0), (630.0, 280.0), (430.0, 330.0), (360.0, 240.0), (290.0, 300.0)] {
        ctx.fill(CGRect(x: 320, y: y, width: w, height: 26))
    }
}

// H 当前线：时间轴的一格，红色「现在」线穿过荧光块。
let nowLine = canvas { ctx in
    ctx.setFillColor(rgb(paper)); ctx.fill(body)
    ctx.setFillColor(rgb(rule))
    for y in [260.0, 512.0, 764.0] { ctx.fill(CGRect(x: 100, y: y - 5, width: 824, height: 10)) }
    hardCard(ctx, CGRect(x: 330, y: 330, width: 420, height: 420), fill: hi, border: 22, shadow: 24)
    ctx.setFillColor(rgb(now)); ctx.fill(CGRect(x: 100, y: 470, width: 824, height: 22))
    ctx.fill(CGRect(x: 170, y: 436, width: 120, height: 90))
}

// I 终端光标：墨底，提示符 › 加一个荧光块光标。
let cursor = canvas { ctx in
    ctx.setFillColor(rgb(ink)); ctx.fill(body)
    monoText(ctx, ">", size: 420, color: 0xEEF1EC, at: CGPoint(x: 230, y: 380))
    ctx.setFillColor(rgb(hi)); ctx.fill(CGRect(x: 520, y: 380, width: 220, height: 300))
}

func save(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let variants: [(String, CGImage)] = [("ruler", ruler), ("block", block), ("mark", mark), ("span", span), ("focus", focus),
                                    ("letter", letter), ("page", page), ("now", nowLine), ("cursor", cursor)]
let variant = CommandLine.arguments.dropFirst().first ?? "now"

if variant == "preview" {
    // 每个方案：256 大图 + 64 / 32 / 16，浅色、深色桌面底各一行。
    let cols = 3, cellW = 380, cellH = 300
    let rows = (variants.count + cols - 1) / cols
    let W = cols * cellW, H = rows * cellH * 2
    let pv = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pv.interpolationQuality = .high
    for (k, (name, img)) in variants.enumerated() {
        for (dark, bg) in [0xE9E9EC, 0x2A2A2E].enumerated() {
            let r = (k / cols) * 2 + dark, c = k % cols
            let ox = CGFloat(c * cellW), oy = CGFloat(H - (r + 1) * cellH)
            pv.setFillColor(rgb(bg)); pv.fill(CGRect(x: ox, y: oy, width: CGFloat(cellW), height: CGFloat(cellH)))
            pv.draw(img, in: CGRect(x: ox + 8, y: oy + 30, width: 256, height: 256))
            var y = oy + 222
            for sz in [64, 32, 16] as [CGFloat] { pv.draw(img, in: CGRect(x: ox + 284, y: y, width: sz, height: sz)); y -= sz + 26 }
            monoText(pv, "\(k + 1) \(name)", size: 18, color: dark == 0 ? ink : 0xEEF1EC, at: CGPoint(x: ox + 14, y: oy + 8), weight: "Medium")
        }
    }
    save(pv.makeImage()!, CommandLine.arguments[2])
    exit(0)
}
guard let image = variants.first(where: { $0.0 == variant })?.1 else {
    fatalError("unknown variant \(variant); use \(variants.map(\.0).joined(separator: " | "))")
}
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        save(ctx.makeImage()!, iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png").path)
    }
}
try! fm.createDirectory(atPath: "Assets", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Assets/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "OK: Assets/AppIcon.icns (\(variant))" : "iconutil failed")
