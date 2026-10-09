import Foundation

/// Controlled target-contamination diagnostic; does not process image pixels.
@main struct LightingConfidenceAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected report path") }
        let times = (0..<13).map { Double($0)/12 }
        func history(_ corrupt: Bool) -> [SurfaceTracking.Observation] {
            times.indices.map { i in
                let level = corrupt && (4...8).contains(i) ? -1.0 : -3.0
                return .init(frame: i,x: 12,y: 12,channelLevels: [level,level,level],
                    confidence: (4...8).contains(i) ? 0 : 1)
            }
        }
        var results: [[String: Any]] = []
        for mode in [NormalisationMode.smooth,.steady] {
            let clean = SurfaceTracking.lighting(history(false),times: times,radius: 0.5,mode: mode,strength: 1)
            let contaminated = SurfaceTracking.lighting(history(true),times: times,radius: 0.5,mode: mode,strength: 1)
            let reliable = times.indices.filter { !(4...8).contains($0) }
            let changes = reliable.map { contaminated[$0].channelEV[0]-clean[$0].channelEV[0] }
            results.append(["mode": mode == .smooth ? "smooth" : "steady",
                "reliableFrames": reliable,"targetChangeAtReliableFramesEV": changes,
                "maximumAbsoluteChangeEV": changes.map(abs).max() ?? 0])
        }
        let report: [String: Any] = ["purpose": "Whether zero-confidence samples contaminate otherwise reliable targets",
            "cases": results,"limitations": "Controlled trace; does not establish prevalence or perceptual video quality."]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
