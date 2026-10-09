// Diagnostic only: validate native optical-flow direction and lighting
// tolerance before considering it as a guide for exposure measurements.
import Foundation
import Vision
import CoreVideo

struct FlowImage: Decodable {
    let width: Int
    let height: Int
    let rgb: [Float]
}

@main struct VisionFlowAudit {
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted();guard !s.isEmpty else { return 0 }
        return s.count.isMultiple(of: 2) ? (s[s.count/2-1]+s[s.count/2])/2 : s[s.count/2]
    }
    static func buffer(_ image: FlowImage) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&result)
        guard status == kCVReturnSuccess,let result else { throw failure("Pixel buffer creation failed") }
        CVPixelBufferLockBaseAddress(result,[]);defer { CVPixelBufferUnlockBaseAddress(result,[]) }
        let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        let centre = (0..<3).map { c in median((0..<(image.width*image.height)).map { log2(max(0.003,Double(image.rgb[$0*3+c]))) }) }
        for y in 0..<image.height { for x in 0..<image.width {
            for c in 0..<3 {
                let value = 0.5+0.15*(log2(max(0.003,Double(image.rgb[(y*image.width+x)*3+c])))-centre[c])
                bytes[y*stride+x*4+(2-c)] = UInt8((255*max(0,min(1,value))).rounded())
            }
            bytes[y*stride+x*4+3] = 255
        } }
        return result
    }
    static func flow(_ a: FlowImage,_ b: FlowImage) throws -> [[Double]] {
        try autoreleasepool {
            let source = try buffer(a),target = try buffer(b)
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target,options: [:])
            request.computationAccuracy = .high
            request.revision = VNGenerateOpticalFlowRequestRevision1
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            let handler = VNImageRequestHandler(cvPixelBuffer: source,options: [:])
            try handler.perform([request])
            guard let output = request.results?.first?.pixelBuffer,
                  CVPixelBufferGetWidth(output) == a.width,CVPixelBufferGetHeight(output) == a.height else {
                throw failure("Unexpected flow dimensions")
            }
            CVPixelBufferLockBaseAddress(output,.readOnly);defer { CVPixelBufferUnlockBaseAddress(output,.readOnly) }
            let values = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: Float.self)
            let stride = CVPixelBufferGetBytesPerRow(output)/MemoryLayout<Float>.size
            return (0..<(a.width*a.height)).map { p in
                let start = (p/a.width)*stride+(p%a.width)*2
                return [Double(values[start]),Double(values[start+1])]
            }
        }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "VisionFlowAudit",code: 1,userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5,let first = Int(args[2]),let second = Int(args[3]) else {
            throw failure("Usage: thumbnails.json first-frame second-frame report.json")
        }
        let destination = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Report exists") }
        let images = try JSONDecoder().decode([FlowImage].self,from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard images.indices.contains(first),images.indices.contains(second) else { throw failure("Frame unavailable") }
        let w = 128,h = 96
        var seed: UInt64 = 719,rgb = [Float]()
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let value = Float((seed >> 32)%1000)/10000+0.08
            rgb += [value,value*0.8,value*0.6]
        }
        var translated = rgb
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            translated[(y*w+x)*3+c] = rgb[(max(0,y-1)*w+max(0,x-2))*3+c]*Float(pow(2,[0.4,-0.3,0.2][c]))
        } } }
        let start = Date()
        let toy = try flow(.init(width: w,height: h,rgb: rgb),.init(width: w,height: h,rgb: translated))
        let central = (10..<(h-10)).flatMap { y in (10..<(w-10)).map { toy[y*w+$0] } }
        let observed = [median(central.map { $0[0] }),median(central.map { $0[1] })]
        let syntheticPassed = abs(observed[0]-2)<0.25 && abs(observed[1]-1)<0.25
        let forward = try flow(images[first],images[second])
        let backward = try flow(images[second],images[first])
        let report: [String: Any] = ["source": args[1],"frames": [first,second],"width": images[first].width,"height": images[first].height,
            "syntheticExpected": [2,1],"syntheticObserved": observed,"syntheticDirectionAndColourCheckPassed": syntheticPassed,
            "normalisation": "Per-channel median-centred log light converted to BGRA8 for geometry only; raw RGB measurements are preserved.",
            "seconds": Date().timeIntervalSince(start),"forward": forward,"backward": backward,
            "requestRevision": VNGenerateOpticalFlowRequestRevision1,"accuracy": "high"]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: destination)
        print("FLOW DIRECTION CHECK",syntheticPassed,observed)
    }
}
