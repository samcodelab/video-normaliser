import CoreImage
import Foundation

enum SpatialRenderer {
    // CI works in linear light. The fitted affine luminance map changes
    // contrast only where neutral midtones support it. Shadows and saturated
    // subjects use the exposure-only field. One common gain multiplies RGB,
    // preserving linear chromaticity; no neighbouring image pixels are blended.
    private static let kernel = CIColorKernel(source: """
        kernel vec4 spatialExposure(__sample source, __sample field, float globalEV, float showField) {
            float gain = exp2(clamp(globalEV + field.r, -2.0, 2.0));
            float peak = max(source.r, max(source.g, source.b));
            float light = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
            float low = min(source.r, min(source.g, source.b));
            float chroma = (peak-low) / max(0.001,peak);
            float toneSupport = smoothstep(0.03, 0.12, light) * (1.0-smoothstep(0.15,0.45,chroma));
            float toneGain = max(0.0, gain + field.g / max(0.001,light));
            float exposureGain = exp2(clamp(globalEV + field.b, -2.0, 2.0));
            gain = mix(exposureGain, toneGain, toneSupport);
            if (gain > 1.0 && peak > 0.0) {
                gain = min(gain, max(1.0, 0.995 / peak));
            }
            if (showField > 0.5) {
                float ev = clamp(log2(max(0.0001,gain)), -1.0, 1.0);
                return vec4(max(0.0,ev), 1.0-abs(ev), max(0.0,-ev), 1.0);
            }
            return vec4(source.rgb * gain, source.a);
        }
        """)!

    static func render(_ source: CIImage, global: Double, field: SpatialField?, diagnostic: PreviewMode = .corrected) -> CIImage {
        guard let field else { return source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: global]) }
        if diagnostic == .confidence || diagnostic == .motion {
            let values = diagnostic == .motion ? field.motion : field.confidence
            let rgba = values.flatMap { [Float($0), Float($0), Float($0), Float(1)] }
            return map(rgba, columns: field.sampleColumns, rows: field.sampleRows, extent: source.extent)
        }
        let rgba = field.stops.indices.flatMap { [Float(field.stops[$0]), Float(field.offsets[$0]), Float(field.exposureStops[$0]), Float(1)] }
        let image = map(rgba, columns: field.columns, rows: field.rows, extent: source.extent)
        return kernel.apply(extent: source.extent, arguments: [source, image, global, diagnostic == .field ? 1.0 : 0.0]) ?? source
    }

    private static func map(_ values: [Float], columns: Int, rows: Int, extent: CGRect) -> CIImage {
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
