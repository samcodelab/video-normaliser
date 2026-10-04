import CoreImage
import Foundation

enum SpatialRenderer {
    // CI works in linear light. The same scalar gain multiplies RGB; only
    // source pixels are used. Highlight protection reduces gain, not channels.
    private static let kernel = CIColorKernel(source: """
        kernel vec4 spatialExposure(__sample source, __sample field, float globalEV) {
            float gain = exp2(clamp(globalEV + field.r, -2.0, 2.0));
            float peak = max(source.r, max(source.g, source.b));
            if (gain > 1.0 && peak > 0.0) {
                gain = min(gain, max(1.0, 0.995 / peak));
            }
            return vec4(source.rgb * gain, source.a);
        }
        """)!

    static func render(_ source: CIImage, global: Double, field: SpatialField?, diagnostic: PreviewMode = .corrected) -> CIImage {
        guard let field else { return source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: global]) }
        if diagnostic.isDiagnostic {
            let columns = diagnostic == .field ? field.columns : field.sampleColumns
            let rows = diagnostic == .field ? field.rows : field.sampleRows
            let values = diagnostic == .field ? field.stops.map { max(0, min(1, ($0+global)/2 + 0.5)) }
                : diagnostic == .motion ? field.motion : field.confidence
            var rgba = [Float]()
            for value in values {
                if diagnostic == .field { rgba += [Float(max(0,(value-0.5)*2)), Float(1-abs(value-0.5)*2), Float(max(0,(0.5-value)*2)), 1] }
                else { rgba += [Float(value), Float(value), Float(value), 1] }
            }
            return map(rgba, columns: columns, rows: rows, extent: source.extent, smooth: diagnostic == .field)
        }
        let rgba = field.stops.flatMap { [Float($0), Float(0), Float(0), Float(1)] }
        let image = map(rgba, columns: field.columns, rows: field.rows, extent: source.extent, smooth: true)
        return kernel.apply(extent: source.extent, arguments: [source, image, global]) ?? source
    }

    private static func map(_ values: [Float], columns: Int, rows: Int, extent: CGRect, smooth: Bool) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        // Node centres span the image edges; clamp before scaling to avoid
        // transparent borders. Bilinear interpolation gives a continuous field.
        let image = CIImage(bitmapData: data, bytesPerRow: columns * 16, size: CGSize(width: columns, height: rows), format: .RGBAf, colorSpace: nil)
        let sx = extent.width / Double(columns-1), sy = extent.height / Double(rows-1)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -0.5, y: -0.5))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
