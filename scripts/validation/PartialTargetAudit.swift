import Foundation

/// Full-resolution independent clean/source target for a user's partial amount.
/// Uses decoded benchmark media and masks, not fitted analysis trajectories.
@main struct PartialTargetAudit {
    struct Result: Encodable {
        let strength: Double
        let frameCount: Int
        let before: [String: RegionScore]
        let after: [String: RegionScore]
        let targetDefinition: String
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let strength = Double(args[4]), (0...1).contains(strength) else {
            throw VideoError.message("Usage: case-folder baseline.mp4 candidate.mp4 strength result.json")
        }
        let output = URL(fileURLWithPath: args[5])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw VideoError.message("Refusing to overwrite evidence") }
        let folder = URL(fileURLWithPath: args[1])
        let source = try await BenchmarkAudit.decode(folder.appendingPathComponent("input.mov"))
        let clean = try await BenchmarkAudit.decode(folder.appendingPathComponent("target.mov"))
        let before = try await BenchmarkAudit.decode(URL(fileURLWithPath: args[2]))
        let after = try await BenchmarkAudit.decode(URL(fileURLWithPath: args[3]))
        guard [clean.count,before.count,after.count].allSatisfy({ $0 == source.count }) else { throw VideoError.message("Frame count mismatch") }
        // Both the 72-frame motion suite and 300-frame adversarial suite use
        // independent masks. Validate against decoded media, not the generator's
        // default frame count.
        BenchmarkAudit.frameCount = source.count
        let masks = try BenchmarkAudit.masks(from: folder.appendingPathComponent("foreground-rle.json"))
        let target = source.indices.map { frame -> BenchmarkAudit.DecodedFrame in
            var rgb = source[frame].rgb
            for pixel in stride(from: 0,to: rgb.count,by: 3) {
                func light(_ values: [Float]) -> Double {
                    0.2126*Double(values[pixel])+0.7152*Double(values[pixel+1])+0.0722*Double(values[pixel+2])
                }
                let gain = pow(max(0.000001,light(clean[frame].rgb))/max(0.000001,light(source[frame].rgb)),strength)
                for c in 0..<3 { rgb[pixel+c] = Float(Double(rgb[pixel+c])*gain) }
            }
            return .init(time: source[frame].time,duration: source[frame].duration,rgb: rgb)
        }
        let item = BenchmarkCase(id: folder.lastPathComponent,category: "Independent partial exposure target",expectedCuts: [],recommendedMode: "smooth")
        let result = Result(strength: strength,frameCount: source.count,
            before: BenchmarkAudit.score(before,target: target,item: item,masks: masks),
            after: BenchmarkAudit.score(after,target: target,item: item,masks: masks),
            targetDefinition: "Per-pixel target Y = source Y^(1-Strength) × independently decoded clean Y^Strength; source chromaticity retained")
        try JSONEncoder().encode(result).write(to: output)
        print("Scored \(source.count) full-resolution frames against independent partial target")
    }
}
