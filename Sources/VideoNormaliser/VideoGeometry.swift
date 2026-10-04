import CoreGraphics

/// Track transforms use top-left video coordinates; Core Image uses bottom-left
/// coordinates. Convert both axes so masks and fields match AVPlayer's display.
enum VideoGeometry {
    static func coreImageTransform(preferred: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        let display = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let inputFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: naturalSize.height)
        let normalise = CGAffineTransform(translationX: -display.minX, y: -display.minY)
        let outputFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height)
        return inputFlip.concatenating(preferred).concatenating(normalise).concatenating(outputFlip)
    }
}
