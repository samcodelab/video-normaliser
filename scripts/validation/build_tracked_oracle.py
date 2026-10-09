"""Instrument a frozen Swift source copy for benchmark-only material diagnostics.

The resulting source references BenchmarkAudit's known mask decoder and dimensions;
it cannot be compiled into the app. No production source is modified. Masks only
classify tracked measurement footprints; the reset is a causal ablation, not a
production segmentation method. Centre-sampled labels underestimate mixed boundaries.
"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
text = args.source.read_text()
anchor = '        completed += active.filter { $0.observations.count >= 5 }'
assert text.count(anchor) == 1
injection = r'''
        var materialReport = [[String: Any]]()
        var maskFrames: [[Bool]]?
        if let path = ProcessInfo.processInfo.environment["FRANKLUMA_ORACLE_MASK"] {
            maskFrames = try! BenchmarkAudit.masks(from: URL(fileURLWithPath: path))
            func stamp(_ observation: Observation) -> [Bool] {
                let frame = Int((samples[observation.frame].time*Double(BenchmarkAudit.fps)).rounded())
                precondition(maskFrames!.indices.contains(frame), "Oracle time not in benchmark mask")
                return (-2...2).flatMap { dy in (-2...2).map { dx in
                    let x = min(BenchmarkAudit.width-1,Int((Double(observation.x+dx)+0.5)*Double(BenchmarkAudit.width)/Double(w)))
                    let y = min(BenchmarkAudit.height-1,Int((Double(observation.y+dy)+0.5)*Double(BenchmarkAudit.height)/Double(h)))
                    return maskFrames![frame][y*BenchmarkAudit.width+x]
                } }
            }
            var split = [Track]()
            for track in completed {
                var chunk = [Observation](), previousStamp: [Bool]?
                let patterns = track.observations.map(stamp)
                let changes = zip(patterns,patterns.dropFirst()).filter { $0 != $1 }.count
                materialReport.append(["firstFrame": track.observations[0].frame,
                    "frames": track.observations.map(\.frame),"x": track.observations.map(\.x),
                    "y": track.observations.map(\.y),"sourceLevels": track.observations.map(\.level),
                    "occupancyChanges": changes,"initialForegroundPixels": patterns[0].filter { $0 }.count])
                for (observation,pattern) in zip(track.observations,patterns) {
                    if let old = previousStamp, old != pattern {
                        if chunk.count >= 5 { split.append(.init(identity: track.identity,observations: chunk)) }
                        chunk = []
                    }
                    chunk.append(observation); previousStamp = pattern
                }
                if chunk.count >= 5 { split.append(.init(identity: track.identity,observations: chunk)) }
            }
            print("MATERIAL_ORACLE rawTracks=\(completed.count) crossing=\(materialReport.filter { ($0[\"occupancyChanges\"] as! Int) > 0 }.count) stableSegments=\(split.count)")
            if ProcessInfo.processInfo.environment["FRANKLUMA_ORACLE_RESET"] == "1" { completed = split }
        }
        var residualReport = [[String: Any]]()
'''
# String interpolation requires unescaped dictionary quotes inside the expression.
injection = injection.replace(r'$0[\"occupancyChanges\"]', '$0["occupancyChanges"]')
text = text.replace(anchor, anchor + injection)
anchor = '''            for (j,observation) in track.observations.enumerated() {
                measurements[observation.frame].append(.init(x: observation.x,y: observation.y,target: outputLevels[j]+rapid[j]))
            }'''
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + r'''
            if maskFrames != nil {
                residualReport.append(["firstFrame": track.observations[0].frame,
                    "firstX": track.observations[0].x,"firstY": track.observations[0].y,
                    "frames": track.observations.map(\.frame),"required": required,"rapid": rapid])
            }
''')
anchor = '        var result = fields\n        for i in images.indices {'
assert text.count(anchor) == 1
text = text.replace(anchor, r'''
        if let path = ProcessInfo.processInfo.environment["FRANKLUMA_ORACLE_REPORT"] {
            precondition(!FileManager.default.fileExists(atPath: path), "Oracle report is immutable")
            let report: [String: Any] = ["tracks": materialReport,"residuals": residualReport,
                "reset": ProcessInfo.processInfo.environment["FRANKLUMA_ORACLE_RESET"] == "1",
                "maskSampling": "Nearest full-resolution ground-truth labels at the 25 thumbnail measurement centres; mixed/antialiased boundaries can be missed",
                "fittingTrackCount": completed.count,"sourceTrackCount": materialReport.count]
            try! JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: URL(fileURLWithPath: path),options: .atomic)
        }
''' + anchor)
assert not args.output.exists(), 'Use a new immutable instrumentation path'
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(text)
