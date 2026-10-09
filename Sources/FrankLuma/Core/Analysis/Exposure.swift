import Foundation

struct ExposureSample: Sendable {
    let time: Double
    let level: Double
    let segment: Int
    let cells: [Double]
    let thumbnail: SpatialThumbnail?
    /// Opt-in finer source evidence; never changes the baseline thumbnail.
    let detailThumbnail: SpatialThumbnail?
    /// Experimental metering raster; original detail still drives geometry.
    let meterThumbnail: SpatialThumbnail?
    init(time: Double, level: Double, segment: Int, cells: [Double] = [], thumbnail: SpatialThumbnail? = nil, detailThumbnail: SpatialThumbnail? = nil, meterThumbnail: SpatialThumbnail? = nil) {
        self.time = time; self.level = level; self.segment = segment; self.cells = cells; self.thumbnail = thumbnail
        self.detailThumbnail = detailThumbnail; self.meterThumbnail = meterThumbnail
    }
}

struct ExposureCurve: Sendable {
    let times: [Double]
    let stops: [Double]
    let spatial: [SpatialField]
    let manualStops: [Double]
    init(times: [Double], stops: [Double], spatial: [SpatialField] = [], manualStops: [Double] = []) {
        self.times = times; self.stops = stops; self.spatial = spatial; self.manualStops = manualStops
    }

    /// Manual exposure belongs to a source frame, independently of scene edits
    /// and automatic estimation. Replacing this layer never compounds a trim.
    func addingManualAdjustments(_ adjustments: [Int: Double]) -> ExposureCurve {
        var manual = [Double](repeating: 0, count: times.count)
        for (frame, value) in adjustments where manual.indices.contains(frame) && value.isFinite {
            manual[frame] = max(-2, min(2, value))
        }
        return ExposureCurve(times: times, stops: stops, spatial: spatial, manualStops: manual)
    }

    var combinedStops: [Double] {
        stops.enumerated().map { index, value in value + (index < spatial.count ? spatial[index].brightnessEV ?? 0 : 0) + (index < manualStops.count ? manualStops[index] : 0) }
    }

    func manualValue(at time: Double) -> Double { lookup(manualStops, at: time) }
    func field(at time: Double) -> SpatialField? {
        guard !spatial.isEmpty, !times.isEmpty else { return nil }
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= time + 0.000001 { low = middle + 1 } else { high = middle }
        }
        return spatial[min(spatial.count - 1, max(0, low - 1))]
    }

    static let empty = ExposureCurve(times: [], stops: [])

    func value(at time: Double) -> Double {
        lookup(stops, at: time)
    }

    private func lookup(_ values: [Double], at time: Double) -> Double {
        guard !times.isEmpty, !values.isEmpty else { return 0 }
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= time + 0.000001 { low = middle + 1 } else { high = middle }
        }
        // Corrections belong to individual source frames. Interpolation would
        // mix exposure corrections across a cut or a held stop-motion frame.
        return values[max(0, min(values.count - 1, low - 1))]
    }

    var peak: Double { stops.enumerated().map { abs($0.element + ($0.offset < spatial.count ? spatial[$0.offset].brightnessEV ?? 0 : 0)) }.max() ?? 0 }
}

enum ExposureMath {
    static func weightedMedian(_ values: [Double],weights: [Double]) -> Double {
        guard values.count == weights.count,!values.isEmpty else { return median(values) }
        let pairs = zip(values,weights).filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        guard !pairs.isEmpty else { return 0 }
        if pairs.allSatisfy({ $0.1 == pairs[0].1 }) { return median(pairs.map { $0.0 }) }
        let total = pairs.reduce(0) { $0+$1.1 }
        var accumulated = 0.0
        for (i,pair) in pairs.enumerated() {
            accumulated += pair.1
            if accumulated == total/2,i+1 < pairs.count { return (pair.0+pairs[i+1].0)/2 }
            if accumulated >= total/2 { return pair.0 }
        }
        return pairs.last!.0
    }
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Estimate exposure in stops using corresponding image cells. The median
    /// rejects moving objects as long as they occupy less than half the reference.
    static func transition(previous: [Double], current: [Double]) -> (delta: Double, cut: Bool, reliable: Bool) {
        let pairs = zip(previous, current).filter { $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92 }
        guard pairs.count >= 12 else { return (0, false, false) }
        let differences = pairs.map { log2($1 / $0) }
        let delta = median(differences)
        let residual = median(differences.map { abs($0 - delta) })
        return (delta, residual > 0.65, residual < 0.35)
    }

    static func curve(samples: [ExposureSample], radius: Double, strength: Double, mode: NormalisationMode = .smooth) -> ExposureCurve {
        guard !samples.isEmpty else { return .empty }
        if mode == .steady {
            let groups = Dictionary(grouping: samples, by: \.segment)
            let targets = groups.mapValues { median($0.map(\.level)) }
            return ExposureCurve(times: samples.map(\.time), stops: samples.map {
                max(-2, min(2, (targets[$0.segment] ?? $0.level) - $0.level)) * strength
            })
        }
        var corrections = [Double](repeating: 0, count: samples.count)
        var start = 0
        while start < samples.count {
            if Task.isCancelled { break }
            var end = start + 1
            while end < samples.count, samples[end].segment == samples[start].segment { end += 1 }
            let shot = Array(samples[start..<end])
            let targets = smoothTargets(times: shot.map(\.time), levels: shot.map(\.level), radius: radius)
            for index in shot.indices {
                corrections[start + index] = max(-2, min(2, targets[index] - shot[index].level)) * strength
            }
            start = end
        }
        return ExposureCurve(times: samples.map(\.time), stops: corrections)
    }

    /// Robust shot-wide trend: penalise curvature rather than averaging flashes
    /// into neighbouring targets. Linear lighting ramps have zero penalty.
    /// The banded solve uses actual timestamps, including variable frame rates.
    static func smoothTargets(times: [Double], levels: [Double], radius: Double,reliability: [Double] = [], preserveShortRamps: Bool = false) -> [Double] {
        let n = levels.count
        guard reliability.isEmpty || reliability.count == n else { return levels }
        let supplied = reliability.map { $0.isFinite ? max(0,min(1,$0)) : 0 }
        if !supplied.isEmpty && !supplied.contains(where: { $0 > 0 }) { return levels }
        // Uniform confidence must not change the radius's physical meaning.
        let average = supplied.isEmpty ? 1 : supplied.filter { $0 > 0 }.reduce(0,+)/Double(supplied.filter { $0 > 0 }.count)
        let uniform = supplied.isEmpty || supplied.allSatisfy { $0 == supplied.first! }
        let prior = uniform ? Array(repeating: 1.0,count: n) : supplied.map { $0/average }
        let weighted = prior.contains { $0 != 1 }
        func centre(_ values: [Double]) -> Double { weighted ? weightedMedian(values,weights: prior) : median(values) }
        if weighted,prior.filter({ $0 > 0 }).count < 2 { return Array(repeating: centre(levels),count: n) }
        guard n == times.count, n > 2 else { return Array(repeating: centre(levels), count: n) }
        let intervals = (1..<n).map { times[$0] - times[$0 - 1] }
        guard intervals.allSatisfy({ $0.isFinite && $0 > 0 }), levels.allSatisfy(\.isFinite) else { return levels }
        // A shot shorter than two smoothing spans cannot establish a gradual
        // trend reliably; retain the bounded trimmed target instead of fitting endpoint drift.
        if !preserveShortRamps, times[n - 1] - times[0] <= 4 * max(0.05, radius) {
            return times.indices.map { i in
                if weighted {
                    let indices = times.indices.filter { abs(times[$0]-times[i]) <= max(0.05,radius)+0.000001 && prior[$0] > 0 }.sorted { levels[$0] < levels[$1] }
                    let total = indices.reduce(0) { $0+prior[$1] }
                    guard total > 0 else { return centre(levels) }
                    var accumulated = 0.0,sum = 0.0,support = 0.0
                    for index in indices {
                        let kept = max(0,min(accumulated+prior[index],total*0.8)-max(accumulated,total*0.2))
                        sum += kept*levels[index];support += kept;accumulated += prior[index]
                    }
                    return sum/max(1e-12,support)
                }
                let window = times.indices.filter { abs(times[$0] - times[i]) <= max(0.05, radius) + 0.000001 }.map { levels[$0] }.sorted()
                let trim = window.count / 5
                let middle = window[trim..<(window.count - trim)]
                return middle.reduce(0, +) / Double(middle.count)
            }
        }
        let step = median(intervals)
        let lambda = min(1e9, pow(max(0.05, radius) / step, 4))
        var penalty = [Double](repeating: 0, count: n)
        var first = penalty, second = penalty
        for i in 1..<(n - 1) {
            let left = max(step * 0.05, intervals[i - 1]) / step
            let right = max(step * 0.05, intervals[i]) / step
            let span = (left + right) / 2
            let terms = [1 / left / span, -(1 / left + 1 / right) / span, 1 / right / span]
            let weight = lambda * span
            for j in 0..<3 { penalty[i - 1 + j] += weight * terms[j] * terms[j] }
            first[i] += weight * terms[0] * terms[1]
            first[i + 1] += weight * terms[1] * terms[2]
            second[i + 1] += weight * terms[0] * terms[2]
        }
        let durations = (0..<n).map { i in
            ((i > 0 ? intervals[i - 1] : intervals[0]) + (i + 1 < n ? intervals[i] : intervals[n - 2])) / (2 * step)
        }
        var weights = [Double](repeating: 1, count: n), targets = levels
        for _ in 0..<6 {
            if Task.isCancelled { return targets }
            var diagonal = penalty, lower = penalty.map { _ in 0.0 }, lower2 = lower, rhs = lower
            for i in 0..<n {
                let weight = durations[i] * prior[i] * max(0.000001, weights[i])
                diagonal[i] += weight
                rhs[i] = weight * levels[i]
                if i >= 2 { lower2[i] = second[i] / diagonal[i - 2] }
                if i >= 1 {
                    let overlap = i >= 2 ? lower2[i] * diagonal[i - 2] * lower[i - 1] : 0
                    lower[i] = (first[i] - overlap) / diagonal[i - 1]
                    diagonal[i] -= lower[i] * lower[i] * diagonal[i - 1]
                }
                if i >= 2 { diagonal[i] -= lower2[i] * lower2[i] * diagonal[i - 2] }
                diagonal[i] = max(1e-12, diagonal[i])
                if i >= 1 { rhs[i] -= lower[i] * rhs[i - 1] }
                if i >= 2 { rhs[i] -= lower2[i] * rhs[i - 2] }
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                targets[i] = rhs[i] / diagonal[i]
                if i + 1 < n { targets[i] -= lower[i + 1] * targets[i + 1] }
                if i + 2 < n { targets[i] -= lower2[i + 2] * targets[i + 2] }
            }
            let residuals = zip(levels, targets).map { $0 - $1 }
            let location = centre(residuals)
            let scale = max(0.025, 1.4826 * centre(residuals.map { abs($0 - location) }))
            weights = residuals.map {
                let distance = abs($0 - location) / (3 * scale)
                return distance < 1 ? pow(1 - distance * distance, 2) : 0
            }
        }
        return targets
    }
}
