import AppKit

// Native vector drawing keeps the app icon reproducible without external assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift <output.icns>\n", stderr)
    exit(1)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MacStatus.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 215, yRadius: 215)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 0.105, green: 0.19, blue: 0.18, alpha: 1),
               ending: NSColor(srgbRed: 0.055, green: 0.09, blue: 0.09, alpha: 1))!.draw(in: tile, angle: -75)
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.09).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // Subtle inset plot grid.
    NSColor(srgbRed: 0.55, green: 0.83, blue: 0.76, alpha: 0.10).setStroke()
    for y in [320, 480, 640] {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 238, y: y))
        line.line(to: NSPoint(x: 786, y: y))
        line.lineWidth = 3
        line.stroke()
    }

    let mint = NSColor(srgbRed: 0.52, green: 0.90, blue: 0.74, alpha: 1)
    let bars: [(CGFloat, CGFloat, CGFloat)] = [(274, 265, 0.48), (454, 400, 0.75), (634, 535, 1)]
    for (x, height, alpha) in bars {
        mint.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 247, width: 116, height: height), xRadius: 36, yRadius: 36).fill()
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MacStatus.Icon", code: 2)
    }
    return png
}

func bigEndianLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

// Modern ICNS stores PNG representations in typed chunks. Writing the container
// directly avoids iconutil's image-service sandbox dependency on managed hosts.
var representations: [Int: Data] = [:]
for size in [16, 32, 64, 128, 256, 512, 1024] { representations[size] = try drawIcon(size: size) }
var chunks = Data()
let entries = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
for (type, size) in entries {
    let png = representations[size]!
    chunks.append(Data(type.utf8))
    chunks.append(bigEndianLength(png.count + 8))
    chunks.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndianLength(chunks.count + 8))
icon.append(chunks)
try icon.write(to: outputURL)
