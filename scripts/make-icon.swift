// Renders Keet's app icon (a waveform on a dark tile) to a 1024 px PNG.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824 px tile centered on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1),
             CGColor(srgbRed: 0.035, green: 0.04, blue: 0.045, alpha: 1)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// A soft green glow behind the bars.
let glow = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 0.30),
             CGColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 0)] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512), endRadius: 380, options: [])

// Waveform: seven rounded bars, tallest in the middle.
let heights: [CGFloat] = [150, 270, 390, 500, 390, 270, 150]
let barWidth: CGFloat = 58
let gap: CGFloat = 34
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = 512 - total / 2
let barGradient = CGGradient(
    colorsSpace: space,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
             CGColor(srgbRed: 0.80, green: 0.97, blue: 0.87, alpha: 1)] as CFArray,
    locations: [0, 1])!
for h in heights {
    let rect = CGRect(x: x, y: 512 - h / 2, width: barWidth, height: h)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(barGradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()
    x += barWidth + gap
}

// Hairline edge highlight.
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print(output)
