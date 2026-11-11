import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("usage: swift script/render_icon.swift [output.icns] (default: AppIcon.icns)")
    exit(0)
}
guard arguments.count <= 1, arguments.first?.hasPrefix("-") != true,
      arguments.first.map({ URL(fileURLWithPath: $0).pathExtension == "icns" }) ?? true else {
    FileHandle.standardError.write(Data("usage: swift script/render_icon.swift [output.icns]\n".utf8))
    exit(2)
}

do {
    try generateIcon(at: URL(fileURLWithPath: arguments.first ?? "AppIcon.icns"))
} catch {
    FileHandle.standardError.write(Data("Icon rendering failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

func generateIcon(at outputURL: URL) throws {
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
        .appendingPathComponent("TaskScopeIcon-" + UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: temporaryURL) }
    let iconsetURL = temporaryURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: false)
    let specs: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2)
    ]

    for spec in specs {
        let pixels = spec.points * spec.scale
        let bitmap = try renderIcon(pixels: pixels)
        // `NSImage.lockFocus` rendered at the display's backing scale, so a 16-point
        // member came out at 32 pixels and iconutil silently dropped the 16 and 128
        // point members. Drawing into an explicit bitmap makes the size exact.
        guard bitmap.pixelsWide == pixels, bitmap.pixelsHigh == pixels else {
            throw NSError(
                domain: "TaskScopeIcon",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) pixels for a \(pixels)-pixel member."
                ]
            )
        }
        let suffix = spec.scale == 1 ? "" : "@2x"
        let filename = "icon_\(spec.points)x\(spec.points)\(suffix).png"
        try writePNG(bitmap: bitmap, to: iconsetURL.appendingPathComponent(filename))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        throw NSError(
            domain: "TaskScopeIcon",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
        )
    }
}

func renderIcon(pixels: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "TaskScopeIcon",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate a \(pixels)-pixel bitmap."]
        )
    }
    // One point per pixel: the drawing code below works in the pixel grid.
    bitmap.size = NSSize(width: pixels, height: pixels)

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
            domain: "TaskScopeIcon",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not create a graphics context for \(pixels) pixels."]
        )
    }

    NSGraphicsContext.saveGraphicsState()
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let dimension = CGFloat(pixels)
    let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    let cornerRadius = dimension * 0.22
    let backgroundPath = NSBezierPath(
        roundedRect: bounds.insetBy(dx: dimension * 0.05, dy: dimension * 0.05),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )

    let gradient = NSGradient(colors: [
        NSColor(red: 0.05, green: 0.08, blue: 0.10, alpha: 1),
        NSColor(red: 0.12, green: 0.22, blue: 0.25, alpha: 1),
        NSColor(red: 0.16, green: 0.36, blue: 0.40, alpha: 1)
    ])
    gradient?.draw(in: backgroundPath, angle: -45)

    NSColor.white.withAlphaComponent(0.15).setStroke()
    backgroundPath.lineWidth = max(1, dimension * 0.012)
    backgroundPath.stroke()

    drawActivityLines(in: bounds, size: dimension)
    drawWaveform(in: bounds, size: dimension)
    drawPowerAccent(in: bounds, size: dimension)

    graphicsContext.flushGraphics()
    return bitmap
}

func drawActivityLines(in bounds: CGRect, size: CGFloat) {
    let left = bounds.minX + size * 0.24
    let right = bounds.maxX - size * 0.25
    let rows = [0.62, 0.50, 0.38].map { bounds.minY + size * CGFloat($0) }
    let lineWidth = max(2, size * 0.026)

    for (index, y) in rows.enumerated() {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: left, y: y))
        path.line(to: CGPoint(x: right - CGFloat(index) * size * 0.08, y: y))
        path.lineCapStyle = .round
        path.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(index == 1 ? 0.70 : 0.42).setStroke()
        path.stroke()
    }
}

func drawWaveform(in bounds: CGRect, size: CGFloat) {
    let path = NSBezierPath()
    let points = [
        CGPoint(x: 0.22, y: 0.73),
        CGPoint(x: 0.34, y: 0.73),
        CGPoint(x: 0.39, y: 0.64),
        CGPoint(x: 0.46, y: 0.83),
        CGPoint(x: 0.53, y: 0.58),
        CGPoint(x: 0.61, y: 0.73),
        CGPoint(x: 0.78, y: 0.73)
    ].map { point in
        CGPoint(
            x: bounds.minX + size * point.x,
            y: bounds.minY + size * point.y
        )
    }

    guard let first = points.first else {
        return
    }

    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }

    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = max(3, size * 0.045)
    NSColor(red: 0.63, green: 0.96, blue: 0.94, alpha: 1).setStroke()
    path.stroke()
}

func drawPowerAccent(in bounds: CGRect, size: CGFloat) {
    let center = CGPoint(
        x: bounds.maxX - size * 0.28,
        y: bounds.minY + size * 0.28
    )
    let radius = size * 0.13
    let accentRect = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )

    NSColor(red: 0.96, green: 0.30, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: accentRect).fill()

    NSColor.white.setStroke()

    let ring = NSBezierPath()
    ring.appendArc(
        withCenter: center,
        radius: radius * 0.48,
        startAngle: 132,
        endAngle: 408,
        clockwise: false
    )
    ring.lineWidth = max(1.5, size * 0.018)
    ring.lineCapStyle = .round
    ring.stroke()

    let stem = NSBezierPath()
    stem.move(to: CGPoint(x: center.x, y: center.y + radius * 0.12))
    stem.line(to: CGPoint(x: center.x, y: center.y + radius * 0.62))
    stem.lineWidth = max(1.5, size * 0.018)
    stem.lineCapStyle = .round
    stem.stroke()
}

func writePNG(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "TaskScopeIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"]
        )
    }

    try pngData.write(to: url)
}
