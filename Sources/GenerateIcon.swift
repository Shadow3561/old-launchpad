import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in iconSizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon bitmap at \(size)px")
    }

    graphics.imageInterpolation = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.clear.setFill()
    canvas.fill()

    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 34, dy: 34), xRadius: 220, yRadius: 220)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.53, alpha: 1),
        NSColor(calibratedRed: 0.19, green: 0.36, blue: 0.70, alpha: 1),
        NSColor(calibratedRed: 0.39, green: 0.27, blue: 0.67, alpha: 1)
    ])?.draw(in: background, angle: -45)

    let glassPanel = NSBezierPath(
        roundedRect: canvas.insetBy(dx: 102, dy: 102),
        xRadius: 168,
        yRadius: 168
    )
    let panelShadow = NSShadow()
    panelShadow.shadowColor = NSColor(calibratedWhite: 0.02, alpha: 0.34)
    panelShadow.shadowBlurRadius = 34
    panelShadow.shadowOffset = NSSize(width: 0, height: -18)
    panelShadow.set()
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.35),
        NSColor(calibratedRed: 0.77, green: 0.87, blue: 1, alpha: 0.14),
        NSColor.white.withAlphaComponent(0.08)
    ])?.draw(in: glassPanel, angle: 90)
    NSGraphicsContext.current?.saveGraphicsState()
    glassPanel.addClip()
    let glassHighlight = NSBezierPath(ovalIn: NSRect(x: 76, y: 545, width: 900, height: 630))
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.28),
        NSColor.white.withAlphaComponent(0)
    ])?.draw(in: glassHighlight, relativeCenterPosition: NSPoint(x: -0.15, y: -0.1))
    NSGraphicsContext.current?.restoreGraphicsState()
    panelShadow.shadowBlurRadius = 0
    panelShadow.shadowOffset = .zero
    panelShadow.set()
    glassPanel.lineWidth = 6
    NSColor.white.withAlphaComponent(0.56).setStroke()
    glassPanel.stroke()

    let tileSize: CGFloat = 202
    let gap: CGFloat = 34
    let start: CGFloat = 172
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = NSRect(
                x: start + CGFloat(column) * (tileSize + gap),
                y: start + CGFloat(2 - row) * (tileSize + gap),
                width: tileSize,
                height: tileSize
            )
            let tile = NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58)
            let tileShadow = NSShadow()
            tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            tileShadow.shadowBlurRadius = 18
            tileShadow.shadowOffset = NSSize(width: 0, height: -9)
            tileShadow.set()
            let hue = CGFloat((column + row * 2) % 3)
            NSGradient(colors: [
                [
                    NSColor(calibratedRed: 0.36, green: 0.76, blue: 1, alpha: 0.98),
                    NSColor(calibratedRed: 0.53, green: 0.87, blue: 0.73, alpha: 0.98),
                    NSColor(calibratedRed: 1, green: 0.65, blue: 0.47, alpha: 0.98)
                ][Int(hue)],
                [
                    NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.91, alpha: 0.94),
                    NSColor(calibratedRed: 0.17, green: 0.61, blue: 0.54, alpha: 0.94),
                    NSColor(calibratedRed: 0.83, green: 0.31, blue: 0.55, alpha: 0.94)
                ][Int(hue)]
            ])?.draw(in: tile, angle: 90)
            tileShadow.shadowBlurRadius = 0
            tileShadow.shadowOffset = .zero
            tileShadow.set()
            tile.lineWidth = 4
            NSColor.white.withAlphaComponent(0.82).setStroke()
            tile.stroke()

            NSGraphicsContext.current?.saveGraphicsState()
            tile.addClip()
            let gloss = NSBezierPath(ovalIn: rect.insetBy(dx: 14, dy: rect.height * 0.46))
            NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.38),
                NSColor.white.withAlphaComponent(0)
            ])?.draw(in: gloss, relativeCenterPosition: NSPoint(x: -0.2, y: -0.1))
            NSGraphicsContext.current?.restoreGraphicsState()

            if row == 1 && column == 1 {
                let sparkle = NSBezierPath()
                sparkle.lineWidth = 14
                sparkle.lineCapStyle = .round
                sparkle.move(to: NSPoint(x: rect.midX - 38, y: rect.midY))
                sparkle.line(to: NSPoint(x: rect.midX + 38, y: rect.midY))
                sparkle.move(to: NSPoint(x: rect.midX, y: rect.midY - 38))
                sparkle.line(to: NSPoint(x: rect.midX, y: rect.midY + 38))
                NSColor.white.withAlphaComponent(0.96).setStroke()
                sparkle.stroke()
            }
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(filename)")
    }
    try png.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
}
