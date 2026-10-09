import XCTest
@testable import FrankLuma

final class QuietColourContinuityTests: XCTestCase {
    func testPreservesLuminanceAndHonoursGainBudget() throws {
        let old = [0.02,-0.01,0.04],rgb = [0.18,0.25,0.1]
        let new = try XCTUnwrap(QuietColourContinuity.preservingLuminance(old:old,shape:[0,0,0],rgb:rgb,global:0.1,limit:0.05))
        let weights = [0.2126,0.7152,0.0722]
        func light(_ gains:[Double]) -> Double {(0..<3).reduce(0) {$0+weights[$1]*rgb[$1]*exp2(gains[$1])}}
        XCTAssertEqual(light(old),light(new),accuracy:1e-12)
        for c in 0..<3 {XCTAssertLessThanOrEqual(abs(new[c]-old[c]),0.05+1e-9)}
        XCTAssertNil(QuietColourContinuity.preservingLuminance(old:old,shape:[0,0,0],rgb:[0,0.2,0.1],global:0,limit:0.05))
        XCTAssertNil(QuietColourContinuity.preservingLuminance(old:[2,0,0],shape:[0,0,0],rgb:rgb,global:0,limit:0.05))
    }

    func testSourceQuietRequiresAllPixelsAndChannels() {
        let a = SpatialThumbnail(width:8,height:8,rgb:Array(repeating:0.2,count:8*8*3))
        XCTAssertTrue(QuietColourContinuity.quiet(a,a,x:3,y:3))
        var b = a.rgb;b[(3*8+3)*3+2] *= 1.02
        XCTAssertFalse(QuietColourContinuity.quiet(a,.init(width:8,height:8,rgb:b),x:3,y:3))
        b = a.rgb;b[(2*8+2)*3] = 0.001
        XCTAssertFalse(QuietColourContinuity.quiet(a,.init(width:8,height:8,rgb:b),x:3,y:3))
    }

    func testQuietColourEchoIsReducedWithoutChangingBrightnessOrSliderZero() {
        let rgb = (0..<(64*48)).flatMap {p -> [Float] in let light = Float(0.15+Double((p%64+p/64)%3)*0.03);return [light,light,light]}
        let image = SpatialThumbnail(width:64,height:48,rgb:rgb)
        var beforeRGB = rgb;for p in stride(from:2,to:rgb.count,by:3) {beforeRGB[p] *= 0.8}
        let beforeImage = SpatialThumbnail(width:64,height:48,rgb:beforeRGB)
        let samples = (0..<5).map {ExposureSample(time:Double($0)/12,level:log2(0.2),segment:0,thumbnail:$0 == 0 ? beforeImage : image)}
        let fields = [0.0,0.03,-0.03,0.02,-0.02].enumerated().map {index,blue -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width:64,height:48,channelEV:(0..<(64*48)).flatMap {_ in [Float(0),Float(0),Float(blue)]},guide:index == 0 ? beforeRGB : image.rgb)
            return field
        }
        let output = QuietColourContinuity.apply(samples:samples,stops:Array(repeating:0,count:5),fields:fields,options:.init())
        let centre = (24*64+32)*3
        let before = fields.dropFirst().map {Double($0.surface!.channelEV[centre+2]-$0.surface!.channelEV[centre])}
        let after = output.dropFirst().map {Double($0.surface!.channelEV[centre+2]-$0.surface!.channelEV[centre])}
        XCTAssertLessThan(after.max()!-after.min()!,before.max()!-before.min()!)
        let zero = QuietColourContinuity.apply(samples:samples,stops:Array(repeating:0,count:5),fields:fields,options:.init(colourStrength:0))
        for i in fields.indices {XCTAssertEqual(zero[i].surface!.channelEV,fields[i].surface!.channelEV)}
        let quietSamples = samples.map {ExposureSample(time:$0.time,level:0,segment:0,thumbnail:image)}
        let noEvent = QuietColourContinuity.apply(samples:quietSamples,stops:Array(repeating:0,count:5),fields:fields,options:.init())
        for i in fields.indices {XCTAssertEqual(noEvent[i].surface!.channelEV,fields[i].surface!.channelEV)}
    }

    func testIntentionalColourRampAndTinyImagesAreUntouched() {
        for size in [2,8] {
            let images = (0..<4).map {i in SpatialThumbnail(width:size,height:size,rgb:(0..<(size*size)).flatMap {_ in [Float(0.2),Float(0.2),Float(0.2*exp2(Double(i)*0.1))]})}
            let samples = images.enumerated().map {ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element)}
            let fields = images.enumerated().map {i,image -> SpatialField in
                var f = SpatialField()
                f.surface = .init(width:size,height:size,channelEV:Array(repeating:Float(Double(i)*0.01),count:size*size*3),guide:image.rgb)
                return f
            }
            let output = QuietColourContinuity.apply(samples:samples,stops:[0,0,0,0],fields:fields,options:.init())
            for i in fields.indices {XCTAssertEqual(output[i].surface!.channelEV,fields[i].surface!.channelEV)}
        }
    }
}
