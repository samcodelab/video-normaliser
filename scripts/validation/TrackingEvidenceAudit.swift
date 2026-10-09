// Run the actual tracker on saved analysis pixels; diagnostic instrumentation
// is injected into an isolated source copy, never the production implementation.
import Foundation

@main struct TrackingEvidenceAudit {
    static func main() throws {
        let args = CommandLine.arguments
        guard (args.count == 7 || (args.count == 9 && args[7] == "--source-cells")),let first = Int(args[3]),let end = Int(args[4]),
              let fps = Double(args[5]),fps > 0,first >= 0,end > first else {
            throw NSError(domain: "TrackingEvidence",code: 1,userInfo: [NSLocalizedDescriptionKey:
                "Usage: thumbnails.json global-stops.json first-frame end-exclusive fps report.json"])
        }
        let decoder = JSONDecoder()
        let images = try decoder.decode([SpatialThumbnail].self,from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let global = try decoder.decode([Double].self,from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard images.count == global.count,end <= images.count else {
            throw NSError(domain: "TrackingEvidence",code: 2)
        }
        let destination = URL(fileURLWithPath: args[6])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "TrackingEvidence",code: 3,userInfo: [NSLocalizedDescriptionKey: "Report already exists"])
        }
        setenv("FRANKLUMA_TRACKING_REPORT",destination.path,1)
        let samples = (first..<end).map { ExposureSample(time: Double($0)/fps,level: 0,segment: 0,thumbnail: images[$0]) }
        var sceneGlobal = Array(global[first..<end])
        if args.count == 9 {
            let cells = try decoder.decode([[Double]].self,from: Data(contentsOf: URL(fileURLWithPath: args[8])))
            guard cells.count == images.count else { throw NSError(domain: "TrackingEvidence",code: 5) }
            sceneGlobal = PatchExposure(cells: Array(cells[first..<end]),thumbnails: Array(images[first..<end]))
                .curve(times: samples.map(\.time),radius: 0.5,strength: 1,mode: .smooth).stops
        }
        let fields = SurfaceLighting.estimate(samples: samples,global: sceneGlobal,radius: 0.5,
            strength: 1,spatialStrength: 1,colourStrength: 1,mode: .smooth)
        guard fields.count == samples.count,FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "TrackingEvidence",code: 4,userInfo: [NSLocalizedDescriptionKey: "Incomplete tracking diagnostic"])
        }
        print("TRACKING EVIDENCE",first,end,"frames",fields.count)
    }
}
