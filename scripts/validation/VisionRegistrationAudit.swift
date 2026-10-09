// Diagnostic only: validate native homography direction and illumination tolerance.
import Foundation
import Vision
import CoreVideo
import simd
struct FlowImage: Decodable { let width: Int;let height: Int;let rgb: [Float] }
@main struct VisionRegistrationAudit {
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
    static func failure(_ message: String) -> NSError { NSError(domain: "RegistrationAudit",code: 1,userInfo: [NSLocalizedDescriptionKey: message]) }
    static func registration(_ a: FlowImage,_ b: FlowImage) throws -> [[Double]] {
        try autoreleasepool {
            let source = try buffer(a),target = try buffer(b)
            let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: source,options: [:])
            request.revision = VNHomographicImageRegistrationRequestRevision1
            try VNImageRequestHandler(cvPixelBuffer: target,options: [:]).perform([request])
            guard let matrix = request.results?.first?.warpTransform else { throw failure("No homography") }
            return (0..<3).map { row in (0..<3).map { column in Double(matrix[column][row]) } }
        }
    }
    static func point(_ m: [[Double]],_ x: Double,_ y: Double) -> [Double] {
        let d = m[2][0]*x+m[2][1]*y+m[2][2]
        return [(m[0][0]*x+m[0][1]*y+m[0][2])/d,(m[1][0]*x+m[1][1]*y+m[1][2])/d]
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5,let first = Int(args[2]),let second = Int(args[3]) else { throw failure("Usage: thumbnails.json first second report.json") }
        let destination = URL(fileURLWithPath: args[4]);guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Report exists") }
        let images = try JSONDecoder().decode([FlowImage].self,from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let w = 192,h = 112
        var seed: UInt64 = 812,rgb = [Float]()
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let level = Float((seed >> 32)%1000)/10000+0.08
            rgb += [level,level*0.8,level*0.6]
        }
        var targets = [[String: Any]]()
        let start = Date()
        for scale in [1.0,1.04] {
            var transformed = rgb
            for y in 0..<h { for x in 0..<w {
                let xx = (Double(x)-Double(w)/2-2)/scale+Double(w)/2
                let yy = (Double(y)-Double(h)/2-1)/scale+Double(h)/2
                let sx = max(0,min(Double(w-2),xx)),sy = max(0,min(Double(h-2),yy))
                let ix = Int(sx),iy = Int(sy),fx = Float(sx-Double(ix)),fy = Float(sy-Double(iy))
                for c in 0..<3 {
                    let p = (iy*w+ix)*3+c
                    let top = rgb[p]*(1-fx)+rgb[p+3]*fx,bottom = rgb[p+w*3]*(1-fx)+rgb[p+w*3+3]*fx
                    transformed[(y*w+x)*3+c] = (top*(1-fy)+bottom*fy)*Float(pow(2,[0.4,-0.3,0.2][c]))
                }
            } }
            let m = try registration(.init(width: w,height: h,rgb: rgb),.init(width: w,height: h,rgb: transformed))
            var direct = [Double](),flipped = [Double]()
            for y in stride(from: 24,to: h-24,by: 16) { for x in stride(from: 24,to: w-24,by: 16) {
                let expected = [scale*(Double(x)-Double(w)/2)+Double(w)/2+2,scale*(Double(y)-Double(h)/2)+Double(h)/2+1]
                let a = point(m,Double(x),Double(y)),b = point(m,Double(x),Double(h-1-y))
                direct.append(hypot(a[0]-expected[0],a[1]-expected[1]))
                flipped.append(hypot(b[0]-expected[0],Double(h-1)-b[1]-expected[1]))
            } }
            targets.append(["scale": scale,"translation": [2,1],"matrix": m,"directMedianErrorPixels": median(direct),"flippedMedianErrorPixels": median(flipped)])
        }
        let forward = try registration(images[first],images[second]),backward = try registration(images[second],images[first])
        let report: [String: Any] = ["source": args[1],"frames": [first,second],"width": images[first].width,"height": images[first].height,"synthetic": targets,"forward": forward,"backward": backward,"seconds": Date().timeIntervalSince(start),"normalisation": "Per-channel median-centred log-light BGRA8 for geometry only."]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: destination)
        print("REGISTRATION",targets)
    }
}
