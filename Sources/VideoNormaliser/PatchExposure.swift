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
    var reliable: Bool { (values.first?.count ?? 0) >= 12 }

    init(cells: [[Double]]) {
        guard let count = cells.first?.count, count >= 12, cells.allSatisfy({ $0.count == count }) else {
            values = []; levels = []; validationValues = []; detailWeight = 0; return
        }
        let valid = (0..<count).filter { j in cells.allSatisfy { $0[j] > 0.025 && $0[j] < 0.8 } }
        guard valid.count >= 12 else {
            values = []; levels = Array(repeating: 0, count: cells.count); validationValues = []; detailWeight = 0; return
        }
        let logs = cells.map { row in row.map { log2(max(0.000001, $0)) } }
        let baseline = (0..<count).map { j in ExposureMath.median(logs.map { $0[j] }) }
        let common = logs.map { row in ExposureMath.median(valid.map { row[$0] - baseline[$0] }) }
        let scores = valid.map { j -> (Int, Double) in
            let residual = logs.indices.map { i in pow(logs[i][j] - baseline[j] - common[i], 2) }
            return (j, sqrt(residual.reduce(0, +) / Double(logs.count)))
        }.sorted { $0.1 < $1.1 }
        let eligible = scores.filter { $0.1 < 0.12 }.map(\.0)
        let chosen = Array(eligible.prefix(max(12, valid.count / 3)))
        // Small scene-wide changes are comparable to patch measurement noise.
        // A conservative quantile then acts as a deadband. Use all consistent
        // patches and their median in quiet shots; blend to conservative flash
        // correction as the scene's measured exposure range increases.
        let span = (common.max() ?? 0) - (common.min() ?? 0)
        detailWeight = max(0, min(1, (0.25 - span) / 0.10))
        validationValues = logs.map { row in eligible.map { row[$0] } }
        values = logs.map { row in chosen.map { row[$0] } }
        let levelPatches = detailWeight > 0.5 ? eligible : chosen
        levels = logs.map { row in ExposureMath.median(levelPatches.map { row[$0] - baseline[$0] }) }
    }

    func diagnostics(times: [Double], radius: Double, strength: Double, mode: NormalisationMode) -> [PatchCorrectionDiagnostic] {
        guard reliable, values.count == times.count else {
            return times.map { _ in PatchCorrectionDiagnostic(estimatedErrorEV: 0, confidence: 0, requestedEV: 0,
                appliedEV: 0, validationLimitEV: 0, rejectionReason: "Fewer than 12 stable patches") }
        }
        func candidates(_ frames: [[Double]]) -> [[Double]] {
            var result = [[Double]](repeating: [], count: times.count)
            for patch in 0..<frames[0].count {
                let samples = times.indices.map { ExposureSample(time: times[$0], level: frames[$0][patch], segment: 0) }
                let curve = ExposureMath.curve(samples: samples, radius: radius, strength: 1, mode: mode)
                for i in times.indices { result[i].append(curve.stops[i]) }
            }
            return result
        }
        let primary = candidates(values), validation = candidates(validationValues)
        return times.indices.map { i in
            let changes = primary[i], checks = validation[i]
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

    private static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position), upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
