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
}
