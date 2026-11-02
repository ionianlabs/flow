// Renders Ionian Flow's app icon into an .iconset and converts it to .icns (plus a 1024 px PNG next to it).
// The icon is the brand's Flow tile (app/Resources/Chrome/tile-flow.jpg) with the white Flow sign at 72.6%
// and 23.4% corners (AIC-01..06). Keep the sign geometry in sync with FlowSign in app/Sources/IonianFlow/Theme.swift.
// Usage (from the repo root): swift scripts/make-icon.swift <out.icns>
import AppKit

/// The sign's bars on the viewBox `17 0.5 30 30`: x, y, height (width 2.4, radius 1.2).
let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
    (18.55, 13.0, 5), (22.05, 10.5, 10), (25.55, 7.0, 17), (29.05, 4.5, 22),
    (32.55, 8.5, 14), (36.05, 6.0, 19), (39.55, 11.0, 9), (43.05, 13.0, 5),
]
let tileURL = URL(fileURLWithPath: "app/Resources/Chrome/tile-flow.jpg")  // run from the repo root
guard let tileImage = NSImage(contentsOf: tileURL), let tileCG = tileImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(tileURL.path)")
}

func srgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a).cgColor
}

func renderIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024  // design on a 1024 grid
    ctx.interpolationQuality = .high

    // macOS icon grid: 824 pt tile centered, corners at 23.4%, with a soft drop shadow.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let corner = 824 * 0.234 * s
    let shape = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: srgb(0x051940, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(srgb(0x02060C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(tileCG, in: tile)
    ctx.restoreGState()

    // the 1 px white rim every brand icon shadow starts with
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1 * s, dy: 1 * s), cornerWidth: corner - s, cornerHeight: corner - s, transform: nil))
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.55))
    ctx.setLineWidth(2 * s)
    ctx.strokePath()
    ctx.restoreGState()

    // the sign: white, 72.6% of the tile, with the drop shadow from ICO-05
    let u = 824 * 0.726 * s / 30, ox = tile.midX - 15 * u, oy = tile.midY + 15 * u
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1 * u), blur: 1.5 * u, color: srgb(0x000000, 0.55))
    ctx.setFillColor(srgb(0xFFFFFF))
    for b in bars {
        let r = CGRect(x: ox + (b.x - 17) * u, y: oy - (b.y - 0.5 + b.h) * u, width: 2.4 * u, height: b.h * u)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.2 * u, cornerHeight: 1.2 * u, transform: nil))
    }
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("IonianFlow-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try renderIcon(px: pt * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try renderIcon(px: 1024).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
