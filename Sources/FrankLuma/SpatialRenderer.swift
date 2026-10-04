import CoreImage
import Foundation

enum SpatialRenderer {
    // CI works in linear light. The fitted affine luminance map changes
    // contrast on neutral midtones and verified matching surfaces.
    // Unsupported patches retain the coarse map. One gain multiplies RGB,
    // preserving linear chromaticity; no neighbouring image pixels are blended.
    private static let kernel = CIColorKernel(source: """
        kernel vec4 spatialExposure(__sample source, __sample field, __sample localMap, __sample guide, float globalEV, float showField) {
            float gain = exp2(clamp(globalEV + field.r, -2.0, 2.0));
            float peak = max(source.r, max(source.g, source.b));
            float light = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
            float low = min(source.r, min(source.g, source.b));
            float chroma = (peak-low) / max(0.001,peak);
            float exposureGain = exp2(clamp(globalEV + field.b, -2.0, 2.0));
            float estimatedLight = light * exposureGain;
            float toneSupport = smoothstep(0.03, 0.12, light) * (1.0-smoothstep(0.15,0.45,chroma));
            float toneGain = max(0.0, gain + field.g / max(0.001,light));
            gain = mix(exposureGain, toneGain, toneSupport);
            // Normalised confidence-weighted interpolation avoids diluting a
            // valid affine match with zero-valued occluded patches. Colour
            // guidance prevents it spilling onto a different physical surface.
            float confidence = max(0.001,localMap.b);
            float sumRGB = max(0.001,source.r+source.g+source.b);
            float colourError = abs(source.r/sumRGB-guide.r/confidence) + abs(source.g/sumRGB-guide.g/confidence);
            float tolerance = guide.b/confidence;
            float patchSupport = smoothstep(0.08,0.35,localMap.b) * (1.0-smoothstep(0.04+tolerance,0.10+tolerance,colourError));
            patchSupport *= smoothstep(0.003,0.025,estimatedLight);
            patchSupport *= 1.0-smoothstep(0.08,0.18,tolerance)*smoothstep(0.12,0.22,estimatedLight);
            patchSupport *= 1.0-smoothstep(0.65,0.90,peak);
            float patchGain = exp2(clamp(globalEV+localMap.r/confidence,-2.0,2.0)) + localMap.g/confidence/max(0.001,light);
            // Mixed printed patches need the shared contrast fit; a uniform
            // coloured surface retains its independently matched patch map.
            patchGain = mix(patchGain,toneGain,smoothstep(0.05,0.15,tolerance) * (1.0-smoothstep(0.07,0.12,estimatedLight)));
            gain = mix(gain,clamp(patchGain,0.25,4.0),patchSupport);
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
        let count = field.sampleColumns*field.sampleRows
        let tone = field.patchTone
        let photoValues = (0..<count).flatMap { p -> [Float] in
            let confidence = tone?.confidence[p] ?? 0
            return [Float((tone?.stops[p] ?? 0)*confidence), Float((tone?.offsets[p] ?? 0)*confidence), Float(confidence), 1]
        }
        let guideValues = (0..<count).flatMap { p -> [Float] in
            let confidence = tone?.confidence[p] ?? 0
            return [Float((tone?.red[p] ?? 0)*confidence), Float((tone?.green[p] ?? 0)*confidence), Float((tone?.colourTolerance?[p] ?? 0)*confidence), 1]
        }
        let photo = map(photoValues, columns: field.sampleColumns, rows: field.sampleRows, extent: source.extent, sampleCentres: true)
        let guide = map(guideValues, columns: field.sampleColumns, rows: field.sampleRows, extent: source.extent, sampleCentres: true)
        return kernel.apply(extent: source.extent, arguments: [source, image, photo, guide, global, diagnostic == .field ? 1.0 : 0.0]) ?? source
    }

    private static func map(_ values: [Float], columns: Int, rows: Int, extent: CGRect, sampleCentres: Bool = false) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        // Coarse nodes span the edges; measured patches occupy cell centres.
        // Clamp before scaling and interpolate to avoid transparent borders.
        let image = CIImage(bitmapData: data, bytesPerRow: columns * 16, size: CGSize(width: columns, height: rows), format: .RGBAf, colorSpace: nil)
        let sx = extent.width / Double(sampleCentres ? columns : columns-1)
        let sy = extent.height / Double(sampleCentres ? rows : rows-1)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: sampleCentres ? 0 : -0.5, y: sampleCentres ? 0 : -0.5))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
