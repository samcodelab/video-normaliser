import AppKit

// Frame genuine, unaltered app captures on Apple's 2560 × 1600 Mac canvas.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("docs/app-store/screenshots")
let shots = [
    ("01-comparison", "Compare before you export", "Original and corrected previews, side by side."),
    ("02-scenes", "Fine-tune each scene", "Refine scene cuts and correction on a zoomable timeline."),
    ("03-reference", "Choose a stable reference", "Use background lighting to guide exposure correction."),
    ("04-export", "Choose your delivery format", "H.264 and HEVC for sharing. ProRes 422 for editing.")
]
for (name, title, subtitle) in shots {
    guard let capture = NSImage(contentsOf: directory.appendingPathComponent("raw/\(name).png")),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1600,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Missing capture: \(name)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.075, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 2560, height: 1600).fill()
    ("FRANKLUMA" as NSString).draw(at: NSPoint(x: 100, y: 1510), withAttributes: [
        .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.7, green: 0.87, blue: 0.46, alpha: 1)])
    (title as NSString).draw(at: NSPoint(x: 100, y: 1415), withAttributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.white])
    (subtitle as NSString).draw(at: NSPoint(x: 100, y: 1360), withAttributes: [
        .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.lightGray])
    let scale = min(2360 / capture.size.width, 1220 / capture.size.height)
    let size = NSSize(width: capture.size.width * scale, height: capture.size.height * scale)
    let captureRect = NSRect(x: (2560 - size.width) / 2, y: 70, width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: captureRect, xRadius: 42 * scale, yRadius: 42 * scale).addClip()
    capture.draw(in: captureRect,
                 from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}
