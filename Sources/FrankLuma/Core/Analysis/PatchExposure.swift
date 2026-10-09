import Foundation

struct PatchCorrectionDiagnostic: Codable {
    let estimatedErrorEV: Double
    let confidence: Double
    let requestedEV: Double
    let appliedEV: Double
    let validationLimitEV: Double
    let rejectionReason: String?
}

/// Measures against shot-local baselines without accumulating frame errors.
struct PatchExposure {
    let values: [[Double]]
    let levels: [Double]
    private let validationValues: [[Double]]
    private let detailWeight: Double
    private var brightnessPatches: [[Int]] = []
    private var brightnessBaselines: [Double] = []
    var reliable: Bool { (values.first?.count ?? 0) >= 12 }

    init(cells: [[Double]], thumbnails: [SpatialThumbnail?] = []) {
        guard let count = cells.first?.count, count >= 12, cells.allSatisfy({ $0.count == count }) else {
            values = []; levels = []; validationValues = []; detailWeight = 0; return
        }
        // A short shot cannot establish a dominant background colour reliably.
        let tracked = cells.count >= 12 && count == 336 && thumbnails.count == cells.count && thumbnails.allSatisfy { $0 != nil }
        let compatible = tracked ? Self.backgroundSupport(thumbnails: thumbnails.map { $0! }) : []
        let usable = cells.indices.map { i in (0..<count).map { j in
            cells[i][j].isFinite && cells[i][j] > 0.025 && cells[i][j] < 0.8 && (!tracked || compatible[i][j])
        } }
        let valid = (0..<count).filter { j in
            let support = usable.filter { $0[j] }.count
            return tracked ? support >= min(cells.count, max(3, Int(ceil(Double(cells.count) * 0.65)))) : support == cells.count
        }
        guard valid.count >= 12 else {
            values = []; levels = Array(repeating: 0, count: cells.count); validationValues = []; detailWeight = 0; return
        }
        let logs = cells.map { row in row.map { log2(max(0.000001, $0)) } }
        let baseline = (0..<count).map { j in ExposureMath.median(logs.indices.filter { usable[$0][j] }.map { logs[$0][j] }) }
        let common = logs.indices.map { i in ExposureMath.median(valid.filter { usable[i][$0] }.map { logs[i][$0] - baseline[$0] }) }
        let scores = valid.map { j -> (Int, Double) in
            let residual = logs.indices.filter { usable[$0][j] }.map { i in pow(logs[i][j] - baseline[j] - common[i], 2) }
            return (j, sqrt(residual.reduce(0, +) / Double(max(1, residual.count))))
        }.sorted { $0.1 < $1.1 }
        let eligible = scores.filter { $0.1 < 0.12 }.map(\.0)
        let chosen = Array(eligible.prefix(max(12, valid.count / 3)))
        // Sparse tracks must not switch correction on and off as subjects pass.
        // Keep the established whole-shot measurement when tracking cannot
        // supply an independently supported estimate for every source frame.
        if tracked && (chosen.count < 12 || usable.contains(where: { row in chosen.filter { row[$0] }.count < 12 })) {
            self = PatchExposure(cells: cells)
            return
        }
        // Small scene-wide changes are comparable to patch measurement noise.
        // A conservative quantile then acts as a deadband. Use all consistent
        // patches and their median in quiet shots; blend to conservative flash
        // correction as the scene's measured exposure range increases.
        let span = (common.max() ?? 0) - (common.min() ?? 0)
        detailWeight = max(0, min(1, (0.25 - span) / 0.10))
        validationValues = logs.indices.map { i in eligible.map { usable[i][$0] ? logs[i][$0] : .nan } }
        values = logs.indices.map { i in chosen.map { usable[i][$0] ? logs[i][$0] : .nan } }
        let levelPatches = detailWeight > 0.5 ? eligible : chosen
        let supportedPatches = logs.indices.map { i in levelPatches.filter { usable[i][$0] } }
        brightnessPatches = supportedPatches
        brightnessBaselines = baseline
        levels = logs.indices.map { i in ExposureMath.median(supportedPatches[i].map { logs[i][$0] - baseline[$0] }) }
    }

    // Reuse source-selected patches: re-selecting from output can hide overshoot.
    func brightnessLevel(cells: [Double], frame: Int) -> Double? {
        guard brightnessPatches.indices.contains(frame) else { return nil }
        let patches = brightnessPatches[frame].filter { cells.indices.contains($0) && cells[$0].isFinite && cells[$0] > 0.001 }
        guard patches.count >= 12 else { return nil }
        return ExposureMath.median(patches.map { log2(cells[$0]) - brightnessBaselines[$0] })
    }

    /// Keep the source-selected support but inspect twelve independent regions.
    /// A scene median can hide an isolated local flash. Unsupported regions
    /// remain nil rather than presenting an invented quality measurement.
    func brightnessRegionLevels(cells: [Double], frame: Int) -> [Double?] {
        guard cells.count == 336,brightnessBaselines.count == 336,
              brightnessPatches.indices.contains(frame) else { return Array(repeating: nil,count: 12) }
        var regions = [[Double]](repeating: [],count: 12)
        for p in brightnessPatches[frame] where cells[p].isFinite && cells[p] > 0.001 {
            let region = min(2,(p/24)*3/14)*4+min(3,(p%24)*4/24)
            regions[region].append(log2(cells[p])-brightnessBaselines[p])
        }
        return regions.map { $0.count >= 3 ? ExposureMath.median($0) : nil }
    }

    func brightnessResiduals(cells: [Double], source: [Double], frame: Int, target: Double,
                             strength: Double) -> [(Int, Double)] {
        guard brightnessPatches.indices.contains(frame) else { return [] }
        return brightnessPatches[frame].compactMap { p in
            guard cells.indices.contains(p), source.indices.contains(p), cells[p].isFinite, cells[p] > 0.001 else { return nil }
            let expected = (1-strength)*log2(max(0.001,source[p])) + strength*brightnessBaselines[p] + target-(1-strength)*levels[frame]
            return (p,expected-log2(cells[p]))
        }
    }

    /// Source-selected, stationary background patches each retain their own
    /// gradual lighting trend. Missing/occluded observations never fit a target.
    func smoothBrightnessTargets(cells: [[Double]], times: [Double], radius: Double,
                                 strength: Double, global: [Double], spatialStrength: Double) -> [[Int: Double]] {
        guard cells.count == times.count,cells.count == brightnessPatches.count,global.count == times.count else { return [] }
        var targets = [[Int: Double]](repeating: [:],count: times.count)
        let selected = Set(brightnessPatches.flatMap { $0 })
        for patch in selected {
            let frames = times.indices.filter { brightnessPatches[$0].contains(patch) && cells[$0].indices.contains(patch) && cells[$0][patch].isFinite && cells[$0][patch] > 0.025 && cells[$0][patch] < 0.8 }
            guard frames.count >= 8 else { continue }
            let samples = frames.map { ExposureSample(time: times[$0],level: log2(cells[$0][patch]),segment: 0) }
            let curve = ExposureMath.curve(samples: samples,radius: radius,strength: strength,mode: .smooth)
            for (index,frame) in frames.enumerated() {
                targets[frame][patch] = samples[index].level+global[frame]+(curve.stops[index]-global[frame])*max(0,min(1,spatialStrength))
            }
        }
        return targets
    }

    /// Translation detection alone cannot establish fixed camera geometry:
    /// zooms and rotations also move texture through fixed patch coordinates.
    /// Require source-selected background structure to remain identifiable
    /// after removing per-channel exposure and planar lighting gradients.
    func hasStationaryBackground(thumbnails: [SpatialThumbnail?]) -> Bool {
        guard thumbnails.count == brightnessPatches.count,!thumbnails.isEmpty,
              thumbnails.allSatisfy({ $0 != nil }) else { return false }
        let referenceIndex = thumbnails.count/2,reference = thumbnails[referenceIndex]!
        let anchors = brightnessPatches[referenceIndex].filter { patch in
            let x = Int((Double(patch%24)+0.5)/24*Double(reference.width))
            let y = Int((Double(patch/24)+0.5)/14*Double(reference.height))
            return SurfaceTracking.stationaryShapeConfidence(reference,reference,x: x,y: y) > 0.5
        }
        guard anchors.count >= 12 else { return false }
        var stableFrames = 0
        for i in thumbnails.indices {
            let frame = thumbnails[i]!
            guard frame.width == reference.width,frame.height == reference.height else { return false }
            let selected = Set(brightnessPatches[i])
            let visible = anchors.filter { selected.contains($0) }
            guard visible.count >= 12 else { continue }
            let stable = visible.filter { patch in
                let x = Int((Double(patch%24)+0.5)/24*Double(reference.width))
                let y = Int((Double(patch/24)+0.5)/14*Double(reference.height))
                return SurfaceTracking.stationaryShapeConfidence(frame,reference,x: x,y: y) > 0.5
            }.count
            if Double(stable)/Double(visible.count) >= 0.8 { stableFrames += 1 }
        }
        return Double(stableFrames)/Double(thumbnails.count) >= 0.9
    }

    func diagnostics(times: [Double], radius: Double, strength: Double, mode: NormalisationMode) -> [PatchCorrectionDiagnostic] {
        guard reliable, values.count == times.count else {
            return times.map { _ in PatchCorrectionDiagnostic(estimatedErrorEV: 0, confidence: 0, requestedEV: 0,
                appliedEV: 0, validationLimitEV: 0, rejectionReason: "Fewer than 12 stable patches") }
        }
        func candidates(_ frames: [[Double]]) -> [[Double]] {
            var result = [[Double]](repeating: [], count: times.count)
            for patch in 0..<frames[0].count {
                if Task.isCancelled { break }
                let supported = times.indices.filter { frames[$0][patch].isFinite }
                guard !supported.isEmpty else { continue }
                let samples = supported.map { ExposureSample(time: times[$0], level: frames[$0][patch], segment: 0) }
                let curve = ExposureMath.curve(samples: samples, radius: radius, strength: 1, mode: mode)
                for (index, i) in supported.enumerated() { result[i].append(curve.stops[index]) }
            }
            return result
        }
        let primary = candidates(values), validation = candidates(validationValues)
        if Task.isCancelled { return [] }
        return times.indices.map { i in
            let changes = primary[i], checks = validation[i]
            guard changes.count >= 12, checks.count >= 12 else {
                return PatchCorrectionDiagnostic(estimatedErrorEV: 0, confidence: 0, requestedEV: 0,
                    appliedEV: 0, validationLimitEV: 0, rejectionReason: "Fewer than 12 supported background tracks in this frame")
            }
            let median = ExposureMath.median(changes), detail = ExposureMath.median(checks)
            let safe = median > 0 ? max(0, Self.quantile(changes, 0.2)) : min(0, Self.quantile(changes, 0.8))
            let requested = detailWeight * detail + (1 - detailWeight) * safe
            // Validate the proposed gain against the broader consistent patch
            // pool, including patches held out by the top-third selection.
            // Allow 0.015 EV for measurement/encoding noise. Large disagreements
            // reduce gain; small-change shots retain the robust median estimate.
            let limit = requested > 0 ? max(0, Self.quantile(checks, 0.2) + 0.015)
                                      : min(0, Self.quantile(checks, 0.8) - 0.015)
            let bounded = requested > 0 ? min(requested, limit) : max(requested, limit)
            let validated = detailWeight * requested + (1 - detailWeight) * bounded
            let applied = max(-2, min(2, validated)) * strength
            let support = Double(checks.filter { abs($0 - detail) < 0.05 }.count) / Double(checks.count)
            let reason: String?
            if strength == 0 { reason = "Strength is zero" }
            else if abs(validated - requested) > 0.000001 { reason = "Broader patch check reduced overshoot" }
            else if abs(requested) < 0.000001 && abs(median) > 0.000001 { reason = "Patches disagree on correction direction" }
            else { reason = nil }
            return PatchCorrectionDiagnostic(estimatedErrorEV: -detail, confidence: support, requestedEV: requested,
                                             appliedEV: applied, validationLimitEV: limit, rejectionReason: reason)
        }
    }

    func curve(times: [Double], radius: Double, strength: Double, mode: NormalisationMode) -> ExposureCurve {
        ExposureCurve(times: times, stops: diagnostics(times: times, radius: radius, strength: strength, mode: mode).map(\.appliedEV))
    }

    /// Follow the dominant background colour at each measured position across
    /// the shot. An occlusion invalidates that observation, not the whole track.
    /// This is fixed-position tracking; camera movement still needs registration.
    private static func backgroundSupport(thumbnails: [SpatialThumbnail]) -> [[Bool]] {
        guard let first = thumbnails.first, first.width >= 24, first.height >= 14,
              thumbnails.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.rgb.count == first.width * first.height * 3 }) else {
            return thumbnails.map { _ in Array(repeating: true, count: 336) }
        }
        let colours = thumbnails.map { frame in (0..<336).map { patch -> (Double, Double) in
            let column = patch % 24, row = patch / 24
            var red = 0.0, green = 0.0, blue = 0.0
            for y in row * frame.height / 14..<(row + 1) * frame.height / 14 {
                for x in column * frame.width / 24..<(column + 1) * frame.width / 24 {
                    let p = (y * frame.width + x) * 3
                    red += Double(frame.rgb[p]); green += Double(frame.rgb[p + 1]); blue += Double(frame.rgb[p + 2])
                }
            }
            let total = max(0.001, red + green + blue)
            return (red / total, green / total)
        } }
        let centres = (0..<336).map { patch in
            (ExposureMath.median(colours.map { $0[patch].0 }), ExposureMath.median(colours.map { $0[patch].1 }))
        }
        return colours.map { row in row.indices.map { patch in
            abs(row[patch].0 - centres[patch].0) + abs(row[patch].1 - centres[patch].1) < 0.065
        } }
    }

    private static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position), upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
