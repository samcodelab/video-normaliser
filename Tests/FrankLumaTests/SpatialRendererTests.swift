import XCTest
import CoreImage
@testable import FrankLuma

final class SpatialRendererTests: XCTestCase {
    private func render(_ rgb: [Float], field: SpatialField) -> [Float] {
        let cs=CGColorSpace(name:CGColorSpace.linearSRGB)!
        let source=CIImage(color:CIColor(red:CGFloat(rgb[0]),green:CGFloat(rgb[1]),blue:CGFloat(rgb[2]),alpha:1,colorSpace:cs)!).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        let context=CIContext(options:[.workingColorSpace:cs])
        let output=SpatialRenderer.render(source,global:0,field:field)
        var pixels=[Float](repeating:0,count:16*16*4)
        pixels.withUnsafeMutableBytes { context.render(output,toBitmap:$0.baseAddress!,rowBytes:16*16,bounds:source.extent,format:.RGBAf,colorSpace:cs) }
        return Array(pixels[(8*16+8)*4..<(8*16+8)*4+3])
    }
    func testToneCorrectionPreservesBlackAndSaturatedColour() {
        var field=SpatialField()
        field.offsets=Array(repeating:0.15,count:54)
        for colour: [Float] in [[0,0,0],[0.01,0.01,0.01],[0.6,0.25,0.03]] {
            let output=render(colour,field:field)
            for c in 0..<3 { XCTAssertEqual(output[c],colour[c],accuracy:0.001) }
        }
        let neutral=render([0.3,0.3,0.3],field:field)
        XCTAssertEqual(neutral[0],0.45,accuracy:0.001)
    }
    func testToneCorrectionPreservesLinearChromaticityAndHighlights() {
        var field=SpatialField()
        field.offsets=Array(repeating:0.15,count:54)
        let input: [Float]=[0.32,0.30,0.29]
        let output=render(input,field:field)
        XCTAssertEqual(output[0]/output[1],input[0]/input[1],accuracy:0.001)
        XCTAssertEqual(output[2]/output[1],input[2]/input[1],accuracy:0.001)
        let bright=render([0.96,0.95,0.94],field:field)
        XCTAssertLessThanOrEqual(bright.max()!,0.996)
    }

    func testVerifiedDarkTextureUsesContrastFitWithoutChangingBrightColour() {
        var field = SpatialField()
        field.stops = Array(repeating: log2(0.7), count: 54)
        field.exposureStops = Array(repeating: log2(0.9), count: 54)
        field.offsets = Array(repeating: 0.015, count: 54)
        let dark: [Float] = [0.16, 0.025, 0.012]
        let exposureOnly = render(dark, field: field)
        XCTAssertEqual(exposureOnly[0], dark[0]*0.9, accuracy: 0.001)

        let sum = Double(dark.reduce(0,+))
        field.patchTone = SpatialPatchTone(stops: Array(repeating: log2(0.7), count: 336),
            offsets: Array(repeating: 0.015, count: 336),
            red: Array(repeating: Double(dark[0])/sum, count: 336),
            green: Array(repeating: Double(dark[1])/sum, count: 336),
            confidence: Array(repeating: 1, count: 336))
        let corrected = render(dark, field: field)
        let light = 0.2126*Double(dark[0])+0.7152*Double(dark[1])+0.0722*Double(dark[2])
        let gain = 0.7+0.015/light
        XCTAssertEqual(Double(corrected[0]), Double(dark[0])*gain, accuracy: 0.001)
        XCTAssertEqual(corrected[0]/corrected[1], dark[0]/dark[1], accuracy: 0.001)
        XCTAssertEqual(corrected[2]/corrected[1], dark[2]/dark[1], accuracy: 0.001)
        XCTAssertEqual(render([0,0,0], field: field), [0,0,0])

        let bright: [Float] = [0.65, 0.50, 0.05]
        let output = render(bright, field: field)
        for channel in 0..<3 { XCTAssertEqual(output[channel], bright[channel]*0.9, accuracy: 0.001) }
    }

    func testEstimatedShadowContrastActuallyStabilisesRenderedColour() {
        let w = 64, h = 40
        let frames = (0..<9).map { frame -> SpatialThumbnail in
            var rgb: [Float] = []
            for y in 0..<h { for x in 0..<w {
                let texture = 0.8+0.35*sin(Double(x)*0.65)*cos(Double(y)*0.8)
                let colour = y < 20 ? [0.25,0.25,0.25] : [0.16,0.025,0.012]
                for value in colour {
                    let base = value*texture
                    rgb.append(Float(frame == 4 && y >= 20 ? base*1.45+value*0.10 : base))
                }
            } }
            return SpatialThumbnail(width: w, height: h, rgb: rgb)
        }
        let samples = frames.enumerated().map {
            ExposureSample(time: Double($0.offset)/12, level: 0, segment: 0, thumbnail: $0.element)
        }
        let field = SpatialLighting.estimate(samples: samples, global: Array(repeating: 0, count: 9), radius: 0.5, strength: 1)[4]
        XCTAssertNil(field.fallback)
        let cs = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: cs])
        let rgba = stride(from: 0, to: frames[4].rgb.count, by: 3).flatMap {
            [frames[4].rgb[$0], frames[4].rgb[$0+1], frames[4].rgb[$0+2], Float(1)]
        }
        let source = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: w*16,
                             size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: cs)
        func error(_ field: SpatialField) -> Double {
            let corrected = SpatialRenderer.render(source, global: 0, field: field)
            var pixels = [Float](repeating: 0, count: w*h*4)
            pixels.withUnsafeMutableBytes {
                context.render(corrected, toBitmap: $0.baseAddress!, rowBytes: w*16,
                               bounds: source.extent, format: .RGBAf, colorSpace: cs)
            }
            var total = 0.0, count = 0
            for y in 28..<36 { for x in 8..<56 {
                let expected = Double(frames[3].rgb[(y*w+x)*3])
                total += pow(Double(pixels[(y*w+x)*4])-expected,2); count += 1
            } }
            return sqrt(total/Double(count))
        }
        var exposureOnly = field
        exposureOnly.patchTone = nil
        XCTAssertLessThan(error(field), error(exposureOnly)*0.5,
                          "Contrast flicker must improve in rendered saturated pixels, not only the estimated field")
        XCTAssertLessThan(error(field), 0.005)
    }
}
