// Draws the app icon: a glass island holding a lyric line and a fainter next line.
// Run: swift scripts/make-icon.swift Resources/AppIcon.icns docs/icon.png
import AppKit

let canvas: CGFloat = 1024
let tileInset: CGFloat = 100 // Apple's icon grid leaves this margin around the tile.
let tile = CGRect(x: tileInset, y: tileInset, width: canvas - 2 * tileInset, height: canvas - 2 * tileInset)

func gradient(_ top: NSColor, _ bottom: NSColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func draw(_ c: CGContext) {
    // Tile, with the drop shadow macOS icons carry.
    let tilePath = squircle(tile, radius: 186)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    c.addPath(tilePath)
    c.setFillColor(NSColor.black.cgColor)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    c.drawLinearGradient(gradient(NSColor(srgbRed: 0.13, green: 0.09, blue: 0.27, alpha: 1),
                                  NSColor(srgbRed: 0.03, green: 0.03, blue: 0.08, alpha: 1)),
                         start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Colored light behind the glass, like artwork tinting the island.
    let glow = [(CGPoint(x: 300, y: 660), NSColor(srgbRed: 0.98, green: 0.22, blue: 0.56, alpha: 0.95), CGFloat(390)),
                (CGPoint(x: 730, y: 380), NSColor(srgbRed: 0.27, green: 0.42, blue: 1.00, alpha: 0.95), CGFloat(430)),
                (CGPoint(x: 690, y: 740), NSColor(srgbRed: 0.62, green: 0.25, blue: 0.98, alpha: 0.70), CGFloat(300))]
    for (center, color, radius) in glow {
        c.drawRadialGradient(gradient(color, color.withAlphaComponent(0)),
                             startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // The island: translucent fill with a bright rim, Liquid Glass style.
    let island = CGRect(x: 172, y: 372, width: 680, height: 280)
    let islandPath = squircle(island, radius: 104)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    c.addPath(islandPath)
    c.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(islandPath)
    c.clip()
    c.drawLinearGradient(gradient(NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0.02)),
                         start: CGPoint(x: 0, y: island.maxY), end: CGPoint(x: 0, y: island.midY), options: [])
    c.restoreGState()

    c.addPath(squircle(island.insetBy(dx: 2.5, dy: 2.5), radius: 102))
    c.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
    c.setLineWidth(5)
    c.strokePath()

    // Current line, then next line: the app's whole idea.
    func bar(_ rect: CGRect, alpha: CGFloat) {
        c.addPath(squircle(rect, radius: rect.height / 2))
        c.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        c.fillPath()
    }
    bar(CGRect(x: 248, y: 520, width: 528, height: 56), alpha: 1)
    bar(CGRect(x: 248, y: 432, width: 340, height: 40), alpha: 0.45)

    c.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    c.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(c)
    return rep.representation(using: .png, properties: [:])!
}

let icnsPath = CommandLine.arguments[1]
let previewPath = CommandLine.arguments[2]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Lyps-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try FileManager.default.createDirectory(at: URL(fileURLWithPath: previewPath).deletingLastPathComponent(), withIntermediateDirectories: true)
try png(size: 512).write(to: URL(fileURLWithPath: previewPath))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsPath]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
