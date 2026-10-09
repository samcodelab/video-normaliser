import AppKit

// Frame genuine, unaltered app captures on Apple's 2560 × 1600 Mac canvas.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : root.appendingPathComponent("docs/app-store/screenshots")
let captures = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : directory.appendingPathComponent("raw")
let shots = [
    ("01-workspace", "Reduce stop-motion flicker", "Bring more consistent exposure to your animation."),
    ("02-comparison", "Compare every frame", "Original and corrected footage, side by side."),
    ("03-controls", "Fine-tune each scene", "Adjust strength, smoothing and local correction."),
    ("04-review", "Review. Loop. Refine.", "Repeat a scene and check the frames that matter."),
    ("05-export", "Export and keep creating", "H.264 and HEVC for sharing. ProRes 422 for editing.")
]
// Read every source first so missing captures cannot publish a partial set.
let images = shots.map { name, _, _ -> NSImage in
    guard let image = NSImage(contentsOf: captures.appendingPathComponent("\(name).png")) else {
        fatalError("Missing capture: \(name)")
    }
    return image
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (index, shot) in shots.enumerated() {
    let (name, title, subtitle) = shot

    let capture = images[index]
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1600,
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
