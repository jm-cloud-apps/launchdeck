import AppKit

// Renders icon_1024.png: a blue squircle with a white gamecontroller glyph.

let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let full = NSRect(x: 0, y: 0, width: size, height: size)
let margin: CGFloat = 96
let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)

// Rounded background with a vertical blue gradient.
ctx.saveGraphicsState()
NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190).addClip()
NSGradient(
    starting: NSColor(srgbRed: 0.40, green: 0.61, blue: 1.00, alpha: 1),
    ending:   NSColor(srgbRed: 0.16, green: 0.40, blue: 0.86, alpha: 1)
)!.draw(in: rect, angle: -90)
ctx.restoreGraphicsState()

// White glyph rendered on its own layer (tinted via .sourceAtop), then composited.
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let glyphRect = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height)

    let glyph = NSImage(size: NSSize(width: size, height: size))
    glyph.lockFocus()
    symbol.draw(in: glyphRect)
    NSColor.white.set()
    glyphRect.fill(using: .sourceAtop)
    glyph.unlockFocus()

    glyph.draw(in: full, from: full, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "icon_1024.png")
if let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: out)
    print("wrote \(out.lastPathComponent)")
} else {
    print("failed to encode PNG")
    exit(1)
}
