import Foundation

struct ExposureSample: Sendable {
    let time: Double
    let level: Double
    let segment: Int
    let cells: [Double]
    let thumbnail: SpatialThumbnail?
    init(time: Double, level: Double, segment: Int, cells: [Double] = [], thumbnail: SpatialThumbnail? = nil) {
        self.time = time; self.level = level; self.segment = segment; self.cells = cells; self.thumbnail = thumbnail
    }
}

struct ExposureCurve: Sendable {
    let times: [Double]
    let stops: [Double]
    let spatial: [SpatialField]
    init(times: [Double], stops: [Double], spatial: [SpatialField] = []) {
        self.times = times; self.stops = stops; self.spatial = spatial
    }
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
        guard !times.isEmpty else { return 0 }
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] <= time + 0.000001 { low = middle + 1 } else { high = middle }
        }
        // Corrections belong to individual source frames. Interpolation would
        // mix exposure corrections across a cut or a held stop-motion frame.
        return stops[max(0, min(stops.count - 1, low - 1))]
    }

    var peak: Double { stops.map(abs).max() ?? 0 }
}

enum ExposureMath {
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
        let radius = max(0.05, radius)
        var corrections = [Double](repeating: 0, count: samples.count)
        var left = 0
        var right = 0
        // A trimmed time-window mean retains slow trends while keeping a
        // single bad frame from pulling neighbouring targets towards itself.
        for index in samples.indices {
            let sample = samples[index]
            while right < samples.count && samples[right].segment <= sample.segment && samples[right].time <= sample.time + radius + 0.000001 {
                right += 1
            }
            while left < right && (samples[left].segment < sample.segment || samples[left].time < sample.time - radius - 0.000001) {
                left += 1
            }
            let window = samples[left..<right].map(\.level).sorted()
            let trim = window.count / 5
            let middle = window[trim..<(window.count - trim)]
            let target = middle.isEmpty ? sample.level : middle.reduce(0, +) / Double(middle.count)
            corrections[index] = max(-2, min(2, target - sample.level)) * strength
        }
        return ExposureCurve(times: samples.map(\.time), stops: corrections)
    }
}
