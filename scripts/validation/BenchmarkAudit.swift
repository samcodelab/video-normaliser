// Step-one benchmark. Generated ground truth and masks are independent of the
// correction algorithm. Scores come from decoded native exports, not EV curves.
import Foundation
import AVFoundation
import CoreImage
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct BenchmarkCase: Codable {
    let id: String
    let category: String
    let expectedCuts: [Int]
    let recommendedMode: String
}
struct BenchmarkManifest: Codable {
    let version: Int
    let width: Int
    let height: Int
    let frames: Int
    let fps: Int
    let cases: [BenchmarkCase]
}
struct RegionScore: Codable {
    let samples: Int
    let medianErrorEV: Double
    let p95AbsoluteErrorEV: Double
    let worstAbsoluteErrorEV: Double
    let residualFlickerRMSEV: Double
    let linearRGBRMSE: Double
    let chromaticityMAE: Double
    let edgeMAE: Double
    let clippedFraction: Double
    var peakTileErrorEV: Double? = nil
    var peakAdjacentErrorEV: Double? = nil
    var peakErrorFrame: Int? = nil
}
struct CaseScore: Codable {
    let id: String
    let expectedCuts: [Int]
    let detectedCuts: [Int]
    let frameCount: Int
    let timingAndGeometryPreserved: Bool
    let seconds: Double
    let source: [String: RegionScore]
    let corrected: [String: RegionScore]
    let codecFloor: [String: RegionScore]
}

@main struct BenchmarkAudit {
    static let width = 320, height = 192
    static var frameCount = 72, fps = 12
    static let cases = [
        BenchmarkCase(id: "global-static", category: "Multiplicative global flicker; static subject", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "global-moving", category: "Global flicker with moving subject", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "local-moving", category: "Background-only local flashes; unchanged moving subject", expectedCuts: [], recommendedMode: "steady"),
        BenchmarkCase(id: "camera-motion", category: "Global flicker and camera translation", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "intentional-ramp", category: "Gradual intended fade plus fast flicker", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "colour-flicker", category: "Changing colour channels, not only exposure", expectedCuts: [], recommendedMode: "steady"),
        BenchmarkCase(id: "rolling-bands", category: "Moving row-dependent illumination", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "scene-cut", category: "Two independently exposed shots", expectedCuts: [36], recommendedMode: "steady"),
        BenchmarkCase(id: "highlight-stress", category: "Brightening with clipped source highlights", expectedCuts: [], recommendedMode: "steady"),
        BenchmarkCase(id: "no-flicker-motion", category: "Negative control: motion with constant lighting", expectedCuts: [], recommendedMode: "smooth")
    ]
    static let motionCases = [
        BenchmarkCase(id: "camera-zoom", category: "Camera zoom with global exposure flicker", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "camera-rotation", category: "Camera rotation with global exposure flicker", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "parallax", category: "Foreground/background parallax with global flicker", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "occlusion", category: "A foreground object crosses and occludes a tracked subject", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-zoom", category: "Negative control: zoom without lighting change", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-rotation", category: "Negative control: rotation without lighting change", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-parallax", category: "Negative control: parallax without lighting change", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-occlusion", category: "Negative control: occlusion without lighting change", expectedCuts: [], recommendedMode: "smooth")
    ]
    static let holdoutCases = [
        BenchmarkCase(id: "camera-combined-holdout", category: "Held-out combined camera rotation/zoom and a different flash sequence", expectedCuts: [], recommendedMode: "smooth"),
        BenchmarkCase(id: "local-parallax-holdout", category: "Held-out local background flashes with parallax", expectedCuts: [], recommendedMode: "steady"),
        BenchmarkCase(id: "colour-occlusion-holdout", category: "Held-out RGB flicker during occlusion", expectedCuts: [], recommendedMode: "steady"),
        BenchmarkCase(id: "no-flicker-combined-holdout", category: "Held-out negative control: combined camera motion", expectedCuts: [], recommendedMode: "smooth")
    ]
    static let adversarialCases = [
        BenchmarkCase(id: "isolated-flash",category: "One strong global flash in a longer 25 fps shot",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "local-colour",category: "Independent background RGB flicker; unchanged foreground",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "mixed-light-rates",category: "Two lights fluctuate at different frequencies",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "low-texture-noisy",category: "Weak texture and deterministic sensor noise with global flicker",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "repeated-texture-motion",category: "Repeated patterns during fractional camera translation",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "camera-motion-bands",category: "Rolling bands in sensor coordinates during camera movement",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-nonlinear-fade",category: "Negative control: intentional nonlinear fade without flicker",expectedCuts: [],recommendedMode: "smooth"),
        BenchmarkCase(id: "no-flicker-noisy-motion",category: "Negative control: weak texture, noise and motion",expectedCuts: [],recommendedMode: "smooth")
    ]
    static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static func error(_ message: String) -> NSError { NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func camera(_ id: String, _ frame: Int) -> (Int, Int) {
        id == "camera-motion" ? (Int(14*sin(Double(frame)*0.13)), Int(7*cos(Double(frame)*0.17))) : (0,0)
    }
    static func world(_ id: String, _ frame: Int, _ x: Int, _ y: Int, foreground: Bool = false) -> (Double, Double) {
        if id == "repeated-texture-motion" || id == "camera-motion-bands" {
            return (Double(x)+18*sin(Double(frame)*0.031),Double(y)+7*cos(Double(frame)*0.024))
        }
        if id.contains("zoom") || id.contains("rotation") || id.contains("combined") {
            let phase = Double(frame)*(id.contains("holdout") ? 0.075 : 0.055)
            let scale = id.contains("zoom") || id.contains("combined") ? 1+0.22*sin(phase) : 1
            let angle = id.contains("rotation") || id.contains("combined") ? 0.16*sin(phase*1.3) : 0
            let xx = (Double(x)-160)/scale, yy = (Double(y)-96)/scale
            return (160+cos(angle)*xx+sin(angle)*yy,96-sin(angle)*xx+cos(angle)*yy)
        }
        if id.contains("parallax") {
            let shift = sin(Double(frame)*0.085)*Double(foreground ? 27 : 12)
            return (Double(x)+shift,Double(y))
        }
        let (dx,dy) = camera(id,frame)
        return (Double(x+dx),Double(y+dy))
    }
    static func occluder(_ id: String, _ frame: Int, _ x: Int, _ y: Int) -> Bool {
        guard id.contains("occlusion") else { return false }
        let centre = 55+Int(Double(frame)*3.1)
        return abs(x-centre)<22 && y>36 && y<161
    }
    static func subjectX(_ id: String, _ frame: Int) -> Int {
        id == "global-static" ? 160 : 160+Int(55*sin(Double(frame)*0.11))
    }
    // World-space shape. Its independently known mask follows camera and subject
    // motion; it does not use the app's background selection or motion detector.
    static func foreground(_ id: String, _ frame: Int, _ x: Int, _ y: Int) -> Bool {
        let (wx,wy) = world(id,frame,x,y,foreground: true), xx = wx-Double(subjectX(id,frame)), yy = wy
        return occluder(id,frame,x,y) || xx*xx+(yy-126)*(yy-126) < 17*17 || (abs(xx)<19 && yy>=65 && yy<112) ||
            (abs(xx)<30 && yy>=83 && yy<96) || (abs(xx)<22 && yy>=48 && yy<65)
    }
    static func pixel(_ id: String, _ frame: Int, _ x: Int, _ y: Int, corrupt: Bool) -> [Float] {
        let subject = foreground(id,frame,x,y)
        let (wx,wy) = world(id,frame,x,y,foreground: subject)
        let second = id == "scene-cut" && frame>=36
        let texture = id == "repeated-texture-motion" ? 0.025*sin(wx*Double.pi/12)*cos(wy*Double.pi/10) : id.contains("holdout") ? 0.016*sin(wx*0.18+0.7)*cos(wy*0.24) : 0.018*sin(wx*0.23)*cos(wy*0.19)
        var rgb: [Double]
        if subject {
            if wy>111 { rgb = [0.52+texture,0.43+texture,0.31+texture] }
            else if wy<65 { rgb = [0.07,0.09,0.12] }
            else { rgb = [0.33+texture,0.105+texture,0.055+texture] }
            if abs(wx-Double(subjectX(id,frame)))<12 && wy>122 && wy<125 { rgb = [0.035,0.03,0.025] }
        } else {
            let checker = ((Int(wx)/24+Int(wy)/24)%2 == 0 ? 0.012 : -0.012)
            if wy<46 { rgb = [0.20+checker,0.25+checker,0.12+checker] }
            else { rgb = second ? [0.12+texture,0.16+texture,0.30+texture] : [0.17+texture,0.25+texture,0.19+texture] }
            if id == "highlight-stress" && wx>250 && wy>130 { rgb = [0.80,0.76,0.69] }
        }
        if occluder(id,frame,x,y) { rgb = [0.11+texture,0.30+texture,0.36+texture] }
        if id.contains("noisy") {
            let noise = Double((x*37+y*59+frame*71+x*y*13)%101)/100-0.5
            rgb = rgb.map { 0.8*$0+0.04+noise*0.006 }
        }
        if second { rgb = rgb.map { $0*0.65 } }
        let ramp = id == "intentional-ramp" ? 0.5*Double(frame)/Double(frameCount-1)-0.25 : id == "no-flicker-nonlinear-fade" ? -0.7*(1-cos(Double(frame)/Double(frameCount-1)*Double.pi)) : 0
        rgb = rgb.map { $0*pow(2,ramp) }
        if corrupt {
            let ev = id.contains("holdout") ? [0.15,-0.30,0.55,0.0,-0.42,0.22,0.08][frame%7] : [0.0,-0.45,0.35,-0.25,0.5,-0.35,0.25,0.0][frame%8]
            switch id {
            case let name where name.hasPrefix("no-flicker-"): break
            case "isolated-flash": rgb = rgb.map { $0*pow(2,frame == 117 ? 0.9 : 0) }
            case "local-colour":
                if !subject { rgb = zip(rgb,[0.45,-0.20,0.10]).map { $0*pow(2,$1*sin(Double(frame)*0.37)) } }
            case "mixed-light-rates":
                let illumination = subject ? 0.23*sin(Double(frame)*0.73) : 0.38*sin(Double(frame)*0.27)
                rgb = rgb.map { $0*pow(2,illumination) }
            case "camera-motion-bands":
                rgb = rgb.map { $0*pow(2,0.4*sin(Double(y)/Double(height)*4*Double.pi+Double(frame)*0.18)) }
            case "local-moving", "local-parallax-holdout":
                // Deliberately does NOT change the subject's light. A global
                // correction from the background must not brighten the subject.
                if !subject {
                    let pulse = frame%24 == 11 ? 0.8 : frame%24 == 12 ? -0.65 : 0
                    let amount = exp(-pow((Double(wx)-95)/110,2))
                    rgb = rgb.map { $0*pow(2,pulse*amount) }
                }
            case "colour-flicker", "colour-occlusion-holdout":
                let phase = sin(Double(frame)*1.1)
                rgb = zip(rgb,[0.35,-0.15,-0.25]).map { $0*pow(2,$1*phase) }
            case "rolling-bands":
                let band = 0.45*sin(Double(wy)/Double(height)*4*Double.pi+Double(frame)*0.7)
                rgb = rgb.map { $0*pow(2,band) }
            case "highlight-stress": rgb = rgb.map { $0*pow(2,ev*1.8) }
            default: rgb = rgb.map { $0*pow(2,ev) }
            }
        }
        return rgb.map { Float(max(0,$0)) }
    }
    static func makeMovie(_ url: URL, id: String, corrupt: Bool) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw error("Refusing to overwrite \(url.path)") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: fps]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw error("Cannot encode fixture") }
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? error("Cannot start fixture") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? error("Fixture encoder failed") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try autoreleasepool {
                var rgba = [Float](); rgba.reserveCapacity(width*height*4)
                for y in 0..<height { for x in 0..<width { rgba += pixel(id,frame,x,y,corrupt:corrupt)+[1] } }
                let data = rgba.withUnsafeBytes { Data($0) }
                let image = CIImage(bitmapData: data, bytesPerRow: width*16, size: CGSize(width:width,height:height), format: .RGBAf, colorSpace: linear)
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { throw error("Cannot allocate fixture") }
                context.render(image,to:buffer,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:srgb)
                guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:Int32(fps))) else { throw writer.error ?? error("Cannot append fixture") }
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime:CMTime(value:Int64(frameCount),timescale:Int32(fps)))
        await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? error("Fixture failed") }
    }
    struct DecodedFrame { let time: CMTime; let duration: CMTime; let rgb: [Float] }
    static func decode(_ url: URL) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url:url)
        let reader = try AVAssetReader(asset:asset)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw error("No video") }
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); guard reader.startReading() else { throw reader.error ?? error("Decode failed") }
        let context = CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
        var frames: [DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            let frame: DecodedFrame = try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw error("No pixels") }
                let image = CIImage(cvPixelBuffer:buffer)
                guard Int(image.extent.width)==width, Int(image.extent.height)==height else { throw error("Unexpected benchmark dimensions") }
                var rgba = [Float](repeating:0,count:width*height*4)
                rgba.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:image.extent,format:.RGBAf,colorSpace:linear) }
                var rgb = [Float](); rgb.reserveCapacity(width*height*3)
                for p in 0..<width*height { rgb += rgba[p*4..<p*4+3] }
                return DecodedFrame(time:CMSampleBufferGetPresentationTimeStamp(sample),duration:CMSampleBufferGetDuration(sample),rgb:rgb)
            }
            frames.append(frame)
        }
        guard reader.status == .completed else { throw reader.error ?? error("Incomplete decode") }
        return frames
    }
    static func maskRuns(_ id: String) -> [[Int]] {
        (0..<frameCount).map { frame in
            var runs: [Int] = [], state = false, length = 0
            for y in 0..<height { for x in 0..<width {
                let next = foreground(id,frame,x,y)
                if next != state { runs.append(length); length = 0; state = next }
                length += 1
            } }
            runs.append(length); return runs
        }
    }
    static func masks(from url: URL) throws -> [[Bool]] {
        let runs = try JSONDecoder().decode([[Int]].self,from:Data(contentsOf:url))
        guard runs.count == frameCount else { throw error("Mask frame count mismatch") }
        return try runs.map { row in
            guard !row.isEmpty, row.allSatisfy({ $0 >= 0 && $0 <= width*height }), row.reduce(0,+) == width*height else { throw error("Invalid foreground mask") }
            return row.enumerated().flatMap { Array(repeating: $0.offset % 2 == 1, count: $0.element) }
        }
    }
    static func score(_ frames: [DecodedFrame], target: [DecodedFrame], item: BenchmarkCase, masks: [[Bool]]) -> [String: RegionScore] {
        var result: [String: RegionScore] = [:]
        for region in ["foreground","background"] {
            var errors: [Double] = [], squared=0.0, chroma=0.0, edges=0.0, clipped=0, count=0, edgeCount=0
            var peakTile = 0.0
            for frame in frames.indices {
                var measured=0.0, expected=0.0, pixels=0
                var tileMeasured = [Double](repeating: 0,count: 12),tileExpected = tileMeasured
                var tileCount = [Int](repeating: 0,count: 12)
                func light(_ rgb:[Float],_ p:Int)->Double { 0.2126*Double(rgb[p])+0.7152*Double(rgb[p+1])+0.0722*Double(rgb[p+2]) }
                let a=frames[frame].rgb,b=target[frame].rgb
                for y in 2..<height-2 { for x in 2..<width-2 {
                    let fg=masks[frame][y*width+x]
                    guard fg == (region == "foreground") else { continue }
                    // Keep background scores clear of moving edges/occlusions.
                    if !fg && (-2...2).contains(where: { dy in (-2...2).contains(where: { dx in masks[frame][(y+dy)*width+x+dx] }) }) { continue }
                    let p=(y*width+x)*3
                    measured += light(a,p); expected += light(b,p); pixels += 1
                    let tile = min(2,y*3/height)*4+min(3,x*4/width)
                    tileMeasured[tile] += light(a,p);tileExpected[tile] += light(b,p);tileCount[tile] += 1
                    let sa=max(0.001,Double(a[p]+a[p+1]+a[p+2])),sb=max(0.001,Double(b[p]+b[p+1]+b[p+2]))
                    for c in 0..<3 { squared += pow(Double(a[p+c]-b[p+c]),2); chroma += abs(Double(a[p+c])/sa-Double(b[p+c])/sb) }
                    if max(a[p],max(a[p+1],a[p+2])) >= 0.99 { clipped += 1 }
                    count += 1
                    if masks[frame][y*width+x+1]==fg && masks[frame][(y+1)*width+x]==fg {
                        for q in [p+3,p+width*3] { edges += abs((light(a,q)-light(a,p))-(light(b,q)-light(b,p))); edgeCount += 1 }
                    }
                } }
                if pixels>0 { errors.append(log2(max(0.000001,measured)/max(0.000001,expected))) }
                for tile in 0..<12 where tileCount[tile] >= 24 {
                    peakTile = max(peakTile,abs(log2(max(0.000001,tileMeasured[tile])/max(0.000001,tileExpected[tile]))))
                }
            }
            let absolute=errors.map(abs).sorted()
            let changes=(1..<errors.count).filter { !item.expectedCuts.contains($0) }.map { pow(errors[$0]-errors[$0-1],2) }
            let adjacent = (1..<errors.count).filter { !item.expectedCuts.contains($0) }
            let worstFrame = adjacent.max { abs(errors[$0]-errors[$0-1]) < abs(errors[$1]-errors[$1-1]) }
            result[region]=RegionScore(samples:count,medianErrorEV:ExposureMath.median(errors),
                p95AbsoluteErrorEV:absolute[min(absolute.count-1,Int(Double(absolute.count-1)*0.95))],worstAbsoluteErrorEV:absolute.last ?? 0,
                residualFlickerRMSEV:sqrt(changes.reduce(0,+)/Double(max(1,changes.count))),linearRGBRMSE:sqrt(squared/Double(max(1,count*3))),
                chromaticityMAE:chroma/Double(max(1,count*3)),edgeMAE:edges/Double(max(1,edgeCount)),clippedFraction:Double(clipped)/Double(max(1,count)),
                peakTileErrorEV: peakTile,peakAdjacentErrorEV: worstFrame.map { abs(errors[$0]-errors[$0-1]) },peakErrorFrame: worstFrame)
        }
        return result
    }
    static func contacts(source: [DecodedFrame], target: [DecodedFrame], output: [DecodedFrame], at url: URL, worstFrames: [Int] = []) throws {
        let usual = source.count == 72 ? [0,11,12,35,36,47,60,71] : [0,source.count/4,source.count/2,3*source.count/4,source.count-1]
        let indices = Array(Set(usual+worstFrames.flatMap { [$0-1,$0,$0+1] })).filter { source.indices.contains($0) }.sorted()
        let context=CGContext(data:nil,width:width*3,height:height*indices.count,bitsPerComponent:8,bytesPerRow:width*3*4,space:srgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ci=CIContext(options:[.workingColorSpace:linear])
        for (row,index) in indices.enumerated() { for (col,frames) in [source,target,output].enumerated() {
            var rgba=[Float](); for p in 0..<width*height { rgba += frames[index].rgb[p*3..<p*3+3]; rgba.append(1) }
            let data=rgba.withUnsafeBytes { Data($0) }
            let image=CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:linear)
            context.draw(ci.createCGImage(image,from:image.extent)!,in:CGRect(x:col*width,y:(indices.count-1-row)*height,width:width,height:height))
        } }
        let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,context.makeImage()!,nil); guard CGImageDestinationFinalize(dest) else { throw error("Contact sheet failed") }
    }
    static func selfTest() throws {
        let masks = (0..<2).map { frame in (0..<width*height).map { foreground("global-moving",frame,$0%width,$0/width) } }
        func frames(_ change: (Int,Int)->Float) -> [DecodedFrame] {
            (0..<2).map { frame in DecodedFrame(time:CMTime(value:Int64(frame),timescale:12),duration:CMTime(value:1,timescale:12),
                rgb:(0..<width*height).flatMap { Array(repeating:change(frame,$0),count:3) }) }
        }
        let clean = frames { _,_ in 0.2 }
        let item = BenchmarkCase(id:"self-test",category:"scorer sanity",expectedCuts:[],recommendedMode:"smooth")
        let identity = score(clean,target:clean,item:item,masks:masks)
        guard identity.values.allSatisfy({ $0.linearRGBRMSE == 0 && $0.residualFlickerRMSEV == 0 && $0.medianErrorEV == 0 }) else { throw error("Identity scorer failed") }
        let wrongSubject = frames { frame,p in masks[frame][p] ? 0.4 : 0.2 }
        let separate = score(wrongSubject,target:clean,item:item,masks:masks)
        guard abs(separate["foreground"]!.medianErrorEV-1)<0.000001, abs(separate["background"]!.medianErrorEV)<0.000001 else { throw error("Foreground error hidden by background score") }
        let ramp = frames { frame,_ in frame == 0 ? 0.2 : 0.4 }
        guard score(ramp,target:ramp,item:item,masks:masks).values.allSatisfy({ $0.residualFlickerRMSEV == 0 }) else { throw error("Intended ramp treated as flicker") }
        let cut = BenchmarkCase(id:"self-test",category:"scorer sanity",expectedCuts:[1],recommendedMode:"smooth")
        guard score(ramp,target:clean,item:cut,masks:masks).values.allSatisfy({ $0.residualFlickerRMSEV == 0 }) else { throw error("Metric crossed a scene cut") }
        print("SCORER SELF-TEST PASSED: identity, foreground isolation, intended ramp, cut exclusion")
    }

    static func main() async throws {
        let args=CommandLine.arguments
        if args.count == 2, args[1] == "self-test" { try selfTest(); return }
        guard args.count>=3, ["generate","run"].contains(args[1]) else { throw error("Usage: benchmark generate|run root [--mode smooth|steady] [--case id] [--label name]") }
        let root=URL(fileURLWithPath:args[2],isDirectory:true)
        if args[1]=="generate" {
            guard !FileManager.default.fileExists(atPath:root.path) else { throw error("Generate into a new directory") }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let suiteIndex = args.firstIndex(of: "--suite")
            let suite = suiteIndex.flatMap { $0+1<args.count ? args[$0+1] : nil } ?? "legacy"
            guard ["legacy","development","holdout","adversarial"].contains(suite) else { throw error("Unknown fixture suite") }
            if suite == "adversarial" { frameCount = 300;fps = 25 }
            let generatedCases = suite == "development" ? cases+motionCases : suite == "holdout" ? holdoutCases : suite == "adversarial" ? adversarialCases : cases
            for item in generatedCases {
                let folder=root.appendingPathComponent("cases/\(item.id)",isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try await makeMovie(folder.appendingPathComponent("target.mov"),id:item.id,corrupt:false)
                try await makeMovie(folder.appendingPathComponent("input.mov"),id:item.id,corrupt:true)
                try encode(maskRuns(item.id),to:folder.appendingPathComponent("foreground-rle.json"))
                print("GENERATED",item.id)
            }
            try encode(BenchmarkManifest(version: suite == "legacy" ? 1 : suite == "adversarial" ? 3 : 2,width:width,height:height,frames:frameCount,fps:fps,cases:generatedCases),to:root.appendingPathComponent("manifest.json"))
            return
        }
        func option(_ name:String)->String? { guard let index=args.firstIndex(of:name), index+1<args.count else { return nil }; return args[index+1] }
        let modeName=option("--mode") ?? "smooth"
        guard ["smooth","steady"].contains(modeName) else { throw error("Mode must be smooth or steady") }
        func amount(_ name: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let text = option(name) else {
                if args.contains(name) { throw error("Missing value for \(name)") }
                return fallback
            }
            guard let value = Double(text), value.isFinite, range.contains(value) else { throw error("Invalid value for \(name)") }
            return value
        }
        let correctionOptions = SceneSettings(
            strength: try amount("--strength",default: 1,range: 0...1),
            radius: try amount("--radius",default: 0.5,range: 0.1...3),
            mode: modeName == "smooth" ? .smooth : .steady,
            spatialStrength: try amount("--spatial-strength",default: 1,range: 0...1),
            colourStrength: try amount("--colour-strength",default: 1,range: 0...1))
        let label=option("--label") ?? "baseline-\(modeName)"
        guard !label.isEmpty, !label.contains("/"), label != ".", label != ".." else { throw error("Invalid output label") }
        let manifest=try JSONDecoder().decode(BenchmarkManifest.self,from:Data(contentsOf:root.appendingPathComponent("manifest.json")))
        if manifest.version == 3 { frameCount = 300;fps = 25 }
        let expectedCases = manifest.version == 3 ? adversarialCases : manifest.version == 1 ? cases : manifest.cases.map(\.id)==holdoutCases.map(\.id) ? holdoutCases : cases+motionCases
        let selected=expectedCases.filter { option("--case")==nil || $0.id==option("--case") }
        guard !selected.isEmpty else { throw error("Unknown case") }
        guard [1,2,3].contains(manifest.version),manifest.width==width,manifest.height==height,manifest.frames==frameCount,manifest.fps==fps,manifest.cases.map(\.id)==expectedCases.map(\.id) else { throw error("Manifest/generator mismatch") }
        let out=root.appendingPathComponent("results/\(label)",isDirectory:true)
        guard !FileManager.default.fileExists(atPath:out.path) else { throw error("Use a new baseline label; results are immutable") }
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        try encode(correctionOptions,to:out.appendingPathComponent("settings.json"))
        try encode(["surfacePipeline": SurfaceLighting.enabled,"surfaceTracking": SurfaceLighting.tracksEnabled,
                    "channelLighting": SurfaceLighting.colourEnabled,"rowLighting": SurfaceLighting.rowsEnabled,
                    "cameraGuidance": SurfaceLighting.cameraGuidanceEnabled,"sharedAnchor": SurfaceLighting.sharedAnchorEnabled,
                    "subpixelCorrespondence": SurfaceTracking.subpixelEnabled,
                    "curvatureCorrespondence": SurfaceTracking.curvatureEnabled,
                    "jointIllumination": SurfaceLighting.jointLightingEnabled,
                    "renderedRefinement": SurfaceLighting.refinementEnabled,
                    "sharedIllumination": ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_SHARED"] != "0"], to: out.appendingPathComponent("pipeline-options.json"))
        let experimentalKeys = ["FRANKLUMA_CONFIDENCE_TARGETS", "FRANKLUMA_PULSE_COMPOSITION",
            "FRANKLUMA_PULSE_DETAIL", "FRANKLUMA_PULSE_BOUNDARY_ANCHORS", "FRANKLUMA_PULSE_ITERATIONS", "FRANKLUMA_PULSE_MULTISCALE", "FRANKLUMA_PULSE_SUPPLEMENT", "FRANKLUMA_PULSE_UNCERTAINTY", "FRANKLUMA_PULSE_RENDERER_FIT", "FRANKLUMA_PULSE_BOUNDED_FIT", "FRANKLUMA_PULSE_BACKTRACK", "FRANKLUMA_PULSE_DENSE", "FRANKLUMA_PULSE_SIGNIFICANCE", "FRANKLUMA_PULSE_SPATIAL_PRIOR", "FRANKLUMA_PULSE_JOINT_INTERVALS", "FRANKLUMA_PULSE_JOINT_FIELD_FIT", "FRANKLUMA_PULSE_JOINT_FEASIBLE_STEP", "FRANKLUMA_PULSE_QUIET_SOURCE_GUARDS", "FRANKLUMA_PULSE_JOINT_SOURCE_INTERVAL", "FRANKLUMA_PULSE_JOINT_CONVERGED_FIT", "FRANKLUMA_PULSE_JOINT_SCALED_PENALTY", "FRANKLUMA_QUIET_COLOUR_CONTINUITY", "FRANKLUMA_PULSE_TEMPORAL_FIT", "FRANKLUMA_PULSE_PROJECTION", "FRANKLUMA_COMMON_PULSE_SMALL_FOOTPRINT", "FRANKLUMA_PULSE_ANALYSIS_PREFILTER", "FRANKLUMA_COMMON_PULSE_KERNEL_METER", "FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES", "FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_COLOUR_CLOCK",
            "FRANKLUMA_COMMON_PULSE_LUMINANCE", "FRANKLUMA_COMMON_PULSE_DONORS", "FRANKLUMA_COMMON_PULSE_TOLERANCE"]
        let environment = ProcessInfo.processInfo.environment
        try encode(Dictionary(uniqueKeysWithValues: experimentalKeys.compactMap { key in
            environment[key].map { (key,$0) }
        }),to:out.appendingPathComponent("experimental-options.json"))
        let executable = URL(fileURLWithPath:args[0]).standardizedFileURL
        let provenance = executable.deletingLastPathComponent().appendingPathComponent("build-provenance.json")
        let provenanceData = try Data(contentsOf:provenance)
        let metadata = try JSONSerialization.jsonObject(with:provenanceData) as? [String: Any]
        let hash = SHA256.hash(data:try Data(contentsOf:executable)).map { String(format:"%02x",$0) }.joined()
        guard metadata?["binarySha256"] as? String == hash else { throw error("Binary/provenance mismatch; rebuild the benchmark") }
        try provenanceData.write(to:out.appendingPathComponent("provenance.json"))
        let runner = out.appendingPathComponent("runner",isDirectory:true)
        try FileManager.default.createDirectory(at:runner,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:executable,to:runner.appendingPathComponent("audit"))
        try provenanceData.write(to:runner.appendingPathComponent("build-provenance.json"))
        var scores: [CaseScore]=[]
        // Serial native exports avoid competing AVFoundation jobs and make the
        // baseline repeatable. No automatic frame registration is used to score.
        for item in selected {
            let begin=Date(), folder=root.appendingPathComponent("cases/\(item.id)"), destination=out.appendingPathComponent(item.id)
            guard !FileManager.default.fileExists(atPath:destination.path) else { throw error("Refusing to overwrite \(destination.path)") }
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            let masks=try masks(from:folder.appendingPathComponent("foreground-rle.json"))
            let input=folder.appendingPathComponent("input.mov"), truth=folder.appendingPathComponent("target.mov")
            let analysis=try await VideoEngine.analyse(url:input,region:nil,progress:{_ in})
            let cuts=SceneMath.boundaries(in:analysis.samples)
            let settings=Dictionary(uniqueKeysWithValues:SceneMath.scenes(samples:analysis.samples,boundaries:cuts,duration:Double(frameCount)/Double(fps)).map { ($0.startFrame,correctionOptions) })
            let correction=await SceneCorrection.calculateAsync(base:analysis.samples,boundaries:cuts,settings:settings,references:[:],cache:[:])
            let globalPeak = correction.curve.stops.map(abs).max() ?? 0
            let localPeak = correction.curve.spatial.map { field -> Double in
                var values = field.stops + field.offsets + field.exposureStops
                values += field.validationStops ?? []
                if let tone = field.patchTone { values += tone.stops + tone.offsets + tone.red + tone.green }
                values += field.surface?.channelEV.map(Double.init) ?? []
                return values.map(abs).max() ?? 0
            }.max() ?? 0
            let brightnessPeak = correction.curve.spatial.compactMap(\.brightnessEV).map(abs).max() ?? 0
            guard [globalPeak,localPeak,brightnessPeak].allSatisfy(\.isFinite) else { throw error("Non-finite correction") }
            if correctionOptions.strength == 0 {
                guard max(globalPeak,localPeak,brightnessPeak) < 0.000001 else { throw error("Strength 0 applied automatic correction") }
            }
            if correctionOptions.spatialStrength == 0 {
                guard localPeak < 0.000001 else { throw error("Spatial 0 applied local correction") }
            }
            if correctionOptions.colourStrength == 0 {
                for field in correction.curve.spatial {
                    guard let rgb = field.surface?.channelEV else { continue }
                    guard stride(from: 0,to: rgb.count,by: 3).allSatisfy({
                        abs(rgb[$0]-rgb[$0+1]) < 0.00001 && abs(rgb[$0]-rgb[$0+2]) < 0.00001
                    }) else { throw error("Colour 0 applied chromatic correction") }
                }
            }
            try encode(["globalPeakEV":globalPeak,"localPeakEV":localPeak,"brightnessPeakEV":brightnessPeak],
                to:destination.appendingPathComponent("control-evidence.json"))
            try encode(["surfaceFrames": correction.curve.spatial.filter { $0.surface != nil }.count,
                        "rowModelFrames": correction.curve.spatial.filter { $0.surface?.rowModel == true }.count],to: destination.appendingPathComponent("model-evidence.json"))
            let movie=destination.appendingPathComponent("corrected.mp4")
            let floor=destination.appendingPathComponent("target-noop.mp4")
            let noop=ExposureCurve(times:analysis.samples.map(\.time),stops:Array(repeating:0,count:analysis.samples.count))
            if let external = option("--external-directory") {
                let externalCase = URL(fileURLWithPath: external).appendingPathComponent(item.id)
                try FileManager.default.copyItem(at: externalCase.appendingPathComponent("corrected.mp4"),to: movie)
                try FileManager.default.copyItem(at: externalCase.appendingPathComponent("target-noop.mp4"),to: floor)
            } else {
                try await VideoEngine.export(asset:AVURLAsset(url:input),curve:correction.curve,destination:movie,progress:{_ in})
                try await VideoEngine.export(asset:AVURLAsset(url:truth),curve:noop,destination:floor,progress:{_ in})
            }
            let sourceFrames=try await decode(input),targetFrames=try await decode(truth),correctedFrames=try await decode(movie),floorFrames=try await decode(floor)
            guard [sourceFrames.count,targetFrames.count,correctedFrames.count,floorFrames.count].allSatisfy({ $0==frameCount }) else { throw error("Frame count mismatch in \(item.id)") }
            if correctionOptions.strength == 0 {
                let sourceNoop = destination.appendingPathComponent("input-noop.mp4")
                try await VideoEngine.export(asset:AVURLAsset(url:input),curve:noop,destination:sourceNoop,progress:{_ in})
                let noopFrames = try await decode(sourceNoop)
                let identity = score(correctedFrames,target:noopFrames,item:item,masks:masks)
                try encode(identity,to:destination.appendingPathComponent("identity-check.json"))
                guard identity.count == 2, identity.values.allSatisfy({
                    $0.linearRGBRMSE < 0.001 && $0.residualFlickerRMSEV < 0.001
                }) else { throw error("Strength 0 changed encoded output beyond the no-op control") }
            }
            let info=try await VideoEngine.info(for:AVURLAsset(url:movie))
            let preserved=zip(sourceFrames,correctedFrames).allSatisfy { CMTimeCompare($0.time,$1.time)==0 && CMTimeCompare($0.duration,$1.duration)==0 } && info.width==width && info.height==height && abs(info.duration-Double(frameCount)/Double(fps))<0.000001
            let result=CaseScore(id:item.id,expectedCuts:item.expectedCuts,detectedCuts:cuts.sorted(),frameCount:correctedFrames.count,timingAndGeometryPreserved:preserved,seconds:Date().timeIntervalSince(begin),
                source:score(sourceFrames,target:targetFrames,item:item,masks:masks),corrected:score(correctedFrames,target:targetFrames,item:item,masks:masks),codecFloor:score(floorFrames,target:targetFrames,item:item,masks:masks))
            try encode(result,to:destination.appendingPathComponent("scores.json")); scores.append(result)
            try contacts(source:sourceFrames,target:targetFrames,output:correctedFrames,at:destination.appendingPathComponent("comparison.png"),
                worstFrames: (Array(result.source.values)+Array(result.corrected.values)).compactMap(\.peakErrorFrame))
            print("SCORED",item.id,"geometry+timing",preserved,"seconds",result.seconds)
            guard preserved else { throw error("Timing/geometry regression") }
            try encode(scores,to:out.appendingPathComponent("scores.json"))
        }
    }
}
