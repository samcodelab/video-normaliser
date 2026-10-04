import Foundation
import CoreGraphics

/// Whole-frame appearance, independent of the region used to measure exposure.
struct FrameAppearance {
    let luminance: [Double]
    let chromaticity: [Double]

    init(pixels: [UInt8], width: Int, height: Int) {
        var light: [Double] = []
        var histogram = [Double](repeating: 0, count: 64)
        var count = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 { for dx in 0..<2 {
                    let i = ((y + dy) * width + x + dx) * 4
                    r += Double(pixels[i]) / 1020
                    g += Double(pixels[i + 1]) / 1020
                    b += Double(pixels[i + 2]) / 1020
                } }
                light.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                let total = r + g + b
                if total > 0.045, max(r, g, b) < 0.95 {
                    // Soft histogram bins avoid spurious cuts when compression
                    // noise moves a colour just across a bin boundary.
                    let red = r / total * 7, green = g / total * 7
                    let rx = Int(red), gy = Int(green)
                    let rf = red - Double(rx), gf = green - Double(gy)
                    for (dx, wx) in [(0, 1 - rf), (1, rf)] {
                        for (dy, wy) in [(0, 1 - gf), (1, gf)] {
                            histogram[min(7, gy + dy) * 8 + min(7, rx + dx)] += wx * wy
                        }
                    }
                    count += 1
                }
            }
        }
        luminance = light
        chromaticity = count > 0 ? histogram.map { $0 / count } : []
    }

    init(luminance: [Double], chromaticity: [Double]) {
        self.luminance = luminance
        self.chromaticity = chromaticity
    }
}

enum PreviewTiming {
    static func interiorTime(start: Double, end: Double?) -> Double {
        guard let end, end.isFinite, end > start else { return start }
        return start + (end - start) / 2
    }
}

enum SceneDetection {
    /// A changing foreground can rearrange most of the image over successive
    /// stop-motion frames. During that motion, require a change in the colour
    /// population as well as structure before declaring another automatic cut.
    static func isCut(preceding: FrameAppearance?, previous: FrameAppearance, current: FrameAppearance, following: [FrameAppearance] = []) -> Bool {
        guard isCut(previous: previous, current: current) else { return false }
        guard let preceding else { return true }
        let changes = zip(preceding.luminance, previous.luminance).filter {
            $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
        }.map { log2($1 / $0) }
        let exposure = ExposureMath.median(changes)
        let ongoingMotion = ExposureMath.median(changes.map { abs($0 - exposure) }) > 0.28
        guard ongoingMotion else { return true }
        let colourChange = zip(previous.chromaticity, current.chromaticity).map { abs($0 - $1) }.reduce(0, +) / 2
        guard colourChange <= 0.45, following.count == 2 else { return true }
        // Preserve a new shot that settles after its first moving frame.
        // Suppress only candidates surrounded by sustained structural motion.
        var previousFrame = current
        for next in following {
            let changes = zip(previousFrame.luminance, next.luminance).filter {
                $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
            }.map { log2($1 / $0) }
            let exposure = ExposureMath.median(changes)
            if ExposureMath.median(changes.map { abs($0 - exposure) }) <= 0.28 { return true }
            previousFrame = next
        }
        return false
    }

    static func isCut(previous: FrameAppearance, current: FrameAppearance) -> Bool {
        let pairs = zip(previous.luminance, current.luminance).filter {
            $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
        }
        let changes = pairs.map { log2($1 / $0) }
        let exposure = ExposureMath.median(changes)
        // Remove the global exposure step before comparing image structure:
        // a uniform flash should be corrected, not mistaken for a new scene.
        let structuralChange = ExposureMath.median(changes.map { abs($0 - exposure) })
        let colourChange: Double
        if !previous.chromaticity.isEmpty, !current.chromaticity.isEmpty {
            colourChange = zip(previous.chromaticity, current.chromaticity).map { abs($0 - $1) }.reduce(0, +) / 2
        } else { colourChange = 0 }
        return (pairs.count >= 12 && structuralChange > 0.65)
            || (pairs.count >= 12 && structuralChange > 0.28 && colourChange > 0.45)
            || colourChange > 0.8
    }
}

struct VideoScene: Identifiable {
    var id: Int { startFrame }
    let number: Int
    let startFrame: Int
    let frameCount: Int
    let start: Double
    let end: Double
}

enum SceneMath {
    static func boundaries(in samples: [ExposureSample]) -> Set<Int> {
        Set(samples.indices.dropFirst().filter { samples[$0].segment != samples[$0 - 1].segment })
    }

    static func assign(_ samples: [ExposureSample], boundaries: Set<Int>) -> [ExposureSample] {
        var scene = 0
        return samples.enumerated().map { index, sample in
            if index > 0, boundaries.contains(index) { scene += 1 }
            return ExposureSample(time: sample.time, level: sample.level, segment: scene, cells: sample.cells, thumbnail: sample.thumbnail)
        }
    }

    static func scenes(samples: [ExposureSample], boundaries: Set<Int>, duration: Double) -> [VideoScene] {
        guard !samples.isEmpty else { return [] }
        let starts = [0] + boundaries.filter { $0 > 0 && $0 < samples.count }.sorted()
        return starts.enumerated().map { number, start in
            let next = number + 1 < starts.count ? starts[number + 1] : samples.count
            return VideoScene(number: number + 1, startFrame: start, frameCount: next - start,
                              start: samples[start].time, end: next < samples.count ? samples[next].time : duration)
        }
    }
}

enum NormalisationMode: String, CaseIterable, Sendable, Codable {
    case smooth = "Smooth flicker"
    case steady = "Steady scene"
}

struct ReferenceRegion: Hashable, Sendable, Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct SceneSettings: Equatable, Sendable, Codable {
    var strength = 1.0
    var radius = 0.5
    var mode: NormalisationMode = .smooth
    var reference: ReferenceRegion?
    var spatialStrength = 1.0
}

enum TimelineMath {
    static func frame(at time: Double, samples: [ExposureSample]) -> Int {
        guard !samples.isEmpty else { return 0 }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time <= time + 0.000001 { low = mid + 1 } else { high = mid }
        }
        return max(0, min(samples.count - 1, low - 1))
    }

    static func nearestFrame(at time: Double, samples: [ExposureSample]) -> Int {
        let left = frame(at: time, samples: samples)
        guard left + 1 < samples.count else { return left }
        return abs(samples[left].time - time) <= abs(samples[left + 1].time - time) ? left : left + 1
    }

    static func clampedBoundary(_ proposed: Int, moving old: Int, boundaries: Set<Int>, frameCount: Int) -> Int {
        let previous = boundaries.filter { $0 < old }.max() ?? 0
        let next = boundaries.filter { $0 > old }.min() ?? frameCount
        return min(next - 1, max(previous + 1, proposed))
    }
}

enum SceneCorrection {
    struct CachedScene: Sendable {
        let settings: SceneSettings
        let frameCount: Int
        let curve: ExposureCurve
        let original: [Double]
        let stablePatches: Int
    }

    struct Calculation: Sendable {
        let curve: ExposureCurve
        let original: [Double]
        let stablePatches: [Int: Int]
        let cache: [Int: CachedScene]
    }

    static func calculateAsync(base: [ExposureSample], boundaries: Set<Int>, settings: [Int: SceneSettings],
                               references: [ReferenceRegion: [ExposureSample]], cache: [Int: CachedScene]) async -> Calculation {
        var updated: [Int: CachedScene] = [:]
        var stops: [Double] = [], spatial: [SpatialField] = [], original: [Double] = []
        var counts: [Int: Int] = [:]
        for scene in SceneMath.scenes(samples: base, boundaries: boundaries, duration: base.last?.time ?? 0) {
            if Task.isCancelled { break }
            let options = settings[scene.startFrame] ?? SceneSettings()
            let entry: CachedScene
            if let previous = cache[scene.startFrame], previous.settings == options, previous.frameCount == scene.frameCount {
                entry = previous
            } else {
                let range = scene.startFrame..<(scene.startFrame + scene.frameCount)
                let frames = range.map { index in
                    let sample = base[index]
                    return ExposureSample(time: sample.time, level: sample.level, segment: 0, cells: sample.cells, thumbnail: sample.thumbnail)
                }
                let reference = options.reference.flatMap { references[$0] }.flatMap { $0.count == base.count ? Array($0[range]) : nil }
                let localReferences = options.reference.flatMap { region in reference.map { [region: $0] } } ?? [:]
                var globalOptions = options; globalOptions.spatialStrength = 0
                let global = calculate(base: frames, boundaries: [], settings: [0: globalOptions], references: localReferences, cache: [:])
                if Task.isCancelled { break }
                let previous = cache[scene.startFrame].flatMap { $0.frameCount == scene.frameCount ? $0.curve.spatial : nil } ?? []
                let fields = await SpatialLighting.estimateAsync(samples: frames, global: global.curve.stops.map { options.strength > 0 ? $0/options.strength : 0 }, radius: options.radius,
                    strength: options.spatialStrength * options.strength, region: options.reference?.rect, previous: previous, mode: options.mode)
                entry = CachedScene(settings: options, frameCount: scene.frameCount,
                    curve: ExposureCurve(times: global.curve.times, stops: global.curve.stops, spatial: fields),
                    original: global.original, stablePatches: global.stablePatches[0] ?? 0)
            }
            updated[scene.startFrame] = entry
            stops += entry.curve.stops; spatial += entry.curve.spatial; original += entry.original
            counts[scene.startFrame] = entry.stablePatches
        }
        return Calculation(curve: ExposureCurve(times: base.map(\.time), stops: stops, spatial: spatial),
                           original: original, stablePatches: counts, cache: updated)
    }

    /// Reuse unchanged shots when an inspector edit affects only one scene.
    /// The caller invalidates this cache whenever analysis/reference data changes.
    static func calculate(base: [ExposureSample], boundaries: Set<Int>, settings: [Int: SceneSettings],
                          references: [ReferenceRegion: [ExposureSample]], cache: [Int: CachedScene]) -> Calculation {
        var updated: [Int: CachedScene] = [:]
        var stops: [Double] = [], spatial: [SpatialField] = [], original: [Double] = []
        var counts: [Int: Int] = [:]
        for scene in SceneMath.scenes(samples: base, boundaries: boundaries, duration: base.last?.time ?? 0) {
            if Task.isCancelled { break }
            let options = settings[scene.startFrame] ?? SceneSettings()
            let entry: CachedScene
            if let previous = cache[scene.startFrame], previous.settings == options, previous.frameCount == scene.frameCount {
                entry = previous
            } else {
                let range = scene.startFrame..<(scene.startFrame + scene.frameCount)
                let reference = options.reference.flatMap { references[$0] } ?? base
                let source = reference.count == base.count ? reference : base
                let patches = PatchExposure(cells: range.map { source[$0].cells })
                let times = range.map { base[$0].time }
                let global: ExposureCurve
                if !source[scene.startFrame].cells.isEmpty {
                    global = patches.curve(times: times, radius: options.radius, strength: options.strength, mode: options.mode)
                } else {
                    global = ExposureMath.curve(samples: range.map {
                        ExposureSample(time: base[$0].time, level: source[$0].level, segment: 0)
                    }, radius: options.radius, strength: options.strength, mode: options.mode)
                }
                let frames = range.map { index in
                    let sample = base[index]
                    return ExposureSample(time: sample.time, level: sample.level, segment: 0,
                                          cells: sample.cells, thumbnail: sample.thumbnail)
                }
                if Task.isCancelled { break }
                let previous = cache[scene.startFrame].flatMap {
                    $0.frameCount == scene.frameCount ? $0.curve.spatial : nil
                } ?? []
                let fields = SpatialLighting.estimate(samples: frames, global: global.stops.map { options.strength > 0 ? $0/options.strength : 0 }, radius: options.radius,
                    strength: options.spatialStrength * options.strength, region: options.reference?.rect, previous: previous, mode: options.mode)
                let levels = patches.levels.count == range.count ? patches.levels : range.map { source[$0].level }
                let baseline = ExposureMath.median(levels)
                entry = CachedScene(settings: options, frameCount: scene.frameCount,
                    curve: ExposureCurve(times: times, stops: global.stops, spatial: fields),
                    original: levels.map { $0 - baseline }, stablePatches: patches.values.first?.count ?? 0)
            }
            updated[scene.startFrame] = entry
            stops += entry.curve.stops; spatial += entry.curve.spatial; original += entry.original
            counts[scene.startFrame] = entry.stablePatches
        }
        return Calculation(curve: ExposureCurve(times: base.map(\.time), stops: stops, spatial: spatial),
                           original: original, stablePatches: counts, cache: updated)
    }

    static func exposure(base: [ExposureSample], boundaries: Set<Int>, settings: [Int: SceneSettings],
                         references: [ReferenceRegion: [ExposureSample]], curve: ExposureCurve) -> ExposureComparison {
        let scenes = SceneMath.scenes(samples: base, boundaries: boundaries, duration: base.last?.time ?? 0)
        var original: [Double] = [], corrected: [Double] = []
        for scene in scenes {
            let reference = settings[scene.startFrame]?.reference
            let candidate = reference.flatMap { references[$0] } ?? base
            let source = candidate.count == base.count ? candidate : base
            let range = scene.startFrame..<(scene.startFrame + scene.frameCount)
            let patches = PatchExposure(cells: range.map { source[$0].cells })
            let levels = patches.levels.count == range.count ? patches.levels : range.map { source[$0].level }
            let baseline = ExposureMath.median(levels)
            for index in range {
                let value = levels[index - scene.startFrame] - baseline
                original.append(value)
                corrected.append(value + (index < curve.stops.count ? curve.stops[index] : 0))
            }
        }
        return ExposureComparison(times: base.map(\.time), original: original, corrected: corrected)
    }

    static func curve(base: [ExposureSample], boundaries: Set<Int>, settings: [Int: SceneSettings],
                      references: [ReferenceRegion: [ExposureSample]]) -> ExposureCurve {
        let scenes = SceneMath.scenes(samples: base, boundaries: boundaries, duration: base.last?.time ?? 0)
        var stops: [Double] = []
        var spatial: [SpatialField] = []
        for scene in scenes {
            let options = settings[scene.startFrame] ?? SceneSettings()
            let referenceSamples = options.reference.flatMap { references[$0] } ?? base
            let source = referenceSamples.count == base.count ? referenceSamples : base
            let range = scene.startFrame..<(scene.startFrame + scene.frameCount)
            // Explicit slices guarantee that no correction can sample another
            // scene, even when its radius exceeds the scene's entire duration.
            let samples = range.map { ExposureSample(time: base[$0].time, level: source[$0].level, segment: 0) }
            let patches = PatchExposure(cells: range.map { source[$0].cells })
            if !source[scene.startFrame].cells.isEmpty {
                stops += patches.curve(times: samples.map(\.time), radius: options.radius, strength: options.strength, mode: options.mode).stops
            } else {
                stops += ExposureMath.curve(samples: samples, radius: options.radius, strength: options.strength, mode: options.mode).stops
            }
            // The reviewed boundaries are authoritative, including manual
            // merges of false automatic cuts caused by camera movement.
            let sceneFrames = range.map { index in
                let sample = base[index]
                return ExposureSample(time: sample.time, level: sample.level, segment: 0,
                                      cells: sample.cells, thumbnail: sample.thumbnail)
            }
            let sceneGlobal = Array(stops.suffix(scene.frameCount))
            spatial += SpatialLighting.estimate(samples: sceneFrames, global: sceneGlobal.map { options.strength > 0 ? $0/options.strength : 0 }, radius: options.radius,
                                                 strength: options.spatialStrength * options.strength, region: options.reference?.rect, mode: options.mode)
        }
        return ExposureCurve(times: base.map(\.time), stops: stops, spatial: spatial)
    }
}

struct ExposureComparison {
    let times: [Double]
    let original: [Double]
    let corrected: [Double]
    static let empty = ExposureComparison(times: [], original: [], corrected: [])
    var range: Double { max(0.25, max(original.map(abs).max() ?? 0, corrected.map(abs).max() ?? 0) * 1.15) }
}

enum PreviewMode: String, CaseIterable, Codable, Sendable {
    case original = "Original"
    case corrected = "Corrected"
    case sideBySide = "Side by side"
    case confidence = "Confidence mask"
    case motion = "Motion mask"
    case field = "Correction field"
    var isDiagnostic: Bool { self == .confidence || self == .motion || self == .field }
}
