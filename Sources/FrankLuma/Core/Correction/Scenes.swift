import Foundation
import CoreGraphics

/// Whole-frame appearance, independent of the region used to measure exposure.
struct FrameAppearance {
    let luminance: [Double]
    let chromaticity: [Double]
    let rgb: [Double]
    let columns: Int

    init(pixels: [UInt8], width: Int, height: Int) {
        var light: [Double] = []
        var colours: [Double] = []
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
                colours += [r, g, b]
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
        rgb = colours
        columns = width / 2
    }

    init(luminance: [Double], chromaticity: [Double]) {
        self.luminance = luminance
        self.chromaticity = chromaticity
        rgb = []; columns = 0
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
        if isPersistentStructuralCut(preceding: preceding, previous: previous, current: current, following: following) { return true }
        if isForegroundCut(preceding: preceding, previous: previous, current: current, following: following) { return true }
        guard isCut(previous: previous, current: current) else { return false }
        guard let preceding else { return true }
        let changes = zip(preceding.luminance, previous.luminance).filter {
            $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
        }.map { log2($1 / $0) }
        let exposure = ExposureMath.median(changes)
        let ongoingMotion = ExposureMath.median(changes.map { abs($0 - exposure) }) > 0.28
        guard ongoingMotion else { return true }
        let colourChange = zip(previous.chromaticity, current.chromaticity).map { abs($0 - $1) }.reduce(0, +) / 2
        guard colourChange <= 0.45, following.count >= 2 else { return true }
        // Preserve a new shot that settles after its first moving frame.
        // Suppress only candidates surrounded by sustained structural motion.
        var previousFrame = current
        for next in following.prefix(2) {
            let changes = zip(previousFrame.luminance, next.luminance).filter {
                $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
            }.map { log2($1 / $0) }
            let exposure = ExposureMath.median(changes)
            if ExposureMath.median(changes.map { abs($0 - exposure) }) <= 0.28 { return true }
            previousFrame = next
        }
        return false
    }

    /// Same-palette camera cuts need not replace the colour population.
    /// Require a settled shot on each side and a persistent exposure-normalised
    /// structural change, so lighting flashes and continuing motion stay in-shot.
    private static func isPersistentStructuralCut(preceding: FrameAppearance?, previous: FrameAppearance,
                                                 current: FrameAppearance, following: [FrameAppearance]) -> Bool {
        guard let preceding, following.count >= 3 else { return false }
        func distance(_ a: FrameAppearance, _ b: FrameAppearance) -> Double {
            let changes = zip(a.luminance, b.luminance).filter {
                $0 > 0.015 && $1 > 0.015 && $0 < 0.92 && $1 < 0.92
            }.map { log2($1 / $0) }
            guard changes.count >= 12 else { return 0 }
            let exposure = ExposureMath.median(changes)
            return ExposureMath.median(changes.map { abs($0 - exposure) })
        }
        let jump = distance(previous, current)
        guard jump > 0.35, distance(preceding, previous) < 0.12 else { return false }
        return following.prefix(3).allSatisfy {
            distance(current, $0) < 0.12 && distance(previous, $0) > 0.35
        }
    }

    /// A new subject or camera angle can occupy less than half the frame,
    /// leaving the background (and the median structure score) unchanged.
    /// Require a strong regional palette replacement, a settled prior shot,
    /// and three following frames of the new palette. Translation preserves the palette;
    /// a brief flash returns to the old palette instead of confirming a cut.
    private static func isForegroundCut(preceding: FrameAppearance?, previous: FrameAppearance,
                                        current: FrameAppearance, following: [FrameAppearance]) -> Bool {
        guard previous.columns >= 6, current.columns == previous.columns,
              previous.rgb.count == previous.luminance.count * 3,
              current.rgb.count == previous.rgb.count, following.count >= 3,
              following.allSatisfy({ $0.columns == previous.columns && $0.rgb.count == previous.rgb.count }),
              colourDistance(previous.chromaticity, current.chromaticity) > 0.15 else { return false }
        let columns = previous.columns, rows = previous.luminance.count / columns
        guard rows >= 6 else { return false }
        for y in 0..<3 { for x in 0..<3 {
            let indices = (y * rows / 3..<(y + 1) * rows / 3).flatMap { row in
                (x * columns / 3..<(x + 1) * columns / 3).map { row * columns + $0 }
            }
            let before = regionalColour(previous, indices: indices)
            let after = regionalColour(current, indices: indices)
            guard colourDistance(before, after) > 0.65 else { continue }
            if let preceding {
                guard preceding.rgb.count == previous.rgb.count,
                      colourDistance(regionalColour(preceding, indices: indices), before) < 0.08 else { continue }
            }
            if following.prefix(3).allSatisfy({ colourDistance(regionalColour($0, indices: indices), after) < 0.20 }) {
                return true
            }
        } }
        return false
    }

    private static func colourDistance(_ first: [Double], _ second: [Double]) -> Double {
        guard !first.isEmpty, first.count == second.count else { return 0 }
        return zip(first, second).map { abs($0 - $1) }.reduce(0, +) / 2
    }

    private static func regionalColour(_ frame: FrameAppearance, indices: [Int]) -> [Double] {
        var histogram = [Double](repeating: 0, count: 64)
        var count = 0
        for index in indices {
            let r = frame.rgb[index * 3], g = frame.rgb[index * 3 + 1], b = frame.rgb[index * 3 + 2]
            let total = r + g + b
            guard total > 0.045, max(r, g, b) < 0.95 else { continue }
            let red = r / total * 7, green = g / total * 7
            let rx = Int(red), gy = Int(green)
            for (dx, wx) in [(0, 1 - red + Double(rx)), (1, red - Double(rx))] {
                for (dy, wy) in [(0, 1 - green + Double(gy)), (1, green - Double(gy))] {
                    histogram[min(7, gy + dy) * 8 + min(7, rx + dx)] += wx * wy
                }
            }
            count += 1
        }
        return count >= 12 ? histogram.map { $0 / Double(count) } : []
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
    /// Refresh automatic cuts on reanalysis, preserving explicitly reviewed
    /// boundaries and inheriting each new shot's existing editing settings.
    static func refreshedCuts(previous: [ExposureSample], current: [ExposureSample], boundaries: Set<Int>,
                              settings: [Int: SceneSettings], defaults: SceneSettings)
        -> (boundaries: Set<Int>, settings: [Int: SceneSettings], sameFrames: Bool) {
        let sameFrames = previous.map(\.time) == current.map(\.time)
        if sameFrames, boundaries != self.boundaries(in: previous) { return (boundaries, settings, true) }
        let detected = self.boundaries(in: current)
        let oldStarts = [0] + boundaries.sorted()
        let updated = Dictionary(uniqueKeysWithValues: ([0] + detected.sorted()).map { start in
            let oldStart = oldStarts.last { $0 <= start } ?? 0
            return (start, sameFrames ? settings[oldStart] ?? defaults : defaults)
        })
        return (detected, updated, sameFrames)
    }

    static func boundaries(in samples: [ExposureSample]) -> Set<Int> {
        Set(samples.indices.dropFirst().filter { samples[$0].segment != samples[$0 - 1].segment })
    }

    static func assign(_ samples: [ExposureSample], boundaries: Set<Int>) -> [ExposureSample] {
        var scene = 0
        return samples.enumerated().map { index, sample in
            if index > 0, boundaries.contains(index) { scene += 1 }
            return ExposureSample(time: sample.time, level: sample.level, segment: scene, cells: sample.cells, thumbnail: sample.thumbnail, detailThumbnail: sample.detailThumbnail, meterThumbnail: sample.meterThumbnail)
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
    var colourStrength = 1.0
    var preserveBrightness = true

    private enum CodingKeys: String, CodingKey { case strength, radius, mode, reference, spatialStrength, colourStrength, preserveBrightness }
    init(strength: Double = 1, radius: Double = 0.5, mode: NormalisationMode = .smooth,
         reference: ReferenceRegion? = nil, spatialStrength: Double = 1, colourStrength: Double = 1, preserveBrightness: Bool = true) {
        self.strength = strength; self.radius = radius; self.mode = mode; self.reference = reference
        self.spatialStrength = spatialStrength; self.colourStrength = colourStrength; self.preserveBrightness = preserveBrightness
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.5
        mode = try c.decodeIfPresent(NormalisationMode.self, forKey: .mode) ?? .smooth
        reference = try c.decodeIfPresent(ReferenceRegion.self, forKey: .reference)
        spatialStrength = try c.decodeIfPresent(Double.self, forKey: .spatialStrength) ?? 1
        colourStrength = try c.decodeIfPresent(Double.self, forKey: .colourStrength) ?? 1
        preserveBrightness = try c.decodeIfPresent(Bool.self, forKey: .preserveBrightness) ?? true
    }
}

enum TimelineMath {
    /// Keep the selected frame centred even at the source's first/last frame.
    static func nearbyFrames(current: Int, radius: Int, frameCount: Int) -> [Int?] {
        let radius = min(2, max(1, radius))
        return (-radius...radius).map { offset in
            let frame = current + offset
            return frame >= 0 && frame < frameCount ? frame : nil
        }
    }

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
                    return ExposureSample(time: sample.time, level: sample.level, segment: 0, cells: sample.cells, thumbnail: sample.thumbnail, detailThumbnail: sample.detailThumbnail, meterThumbnail: sample.meterThumbnail)
                }
                let reference = options.reference.flatMap { references[$0] }.flatMap { $0.count == base.count ? Array($0[range]) : nil }
                let localReferences = options.reference.flatMap { region in reference.map { [region: $0] } } ?? [:]
                var globalOptions = options; globalOptions.spatialStrength = 0; globalOptions.preserveBrightness = false
                let global = calculate(base: frames, boundaries: [], settings: [0: globalOptions], references: localReferences, cache: [:],meterOnly: true)
                if Task.isCancelled { break }
                let previous = cache[scene.startFrame].flatMap { $0.frameCount == scene.frameCount ? $0.curve.spatial : nil } ?? []
                let fields = SurfaceLighting.enabled && options.strength > 0 ? SurfaceLighting.estimate(samples: frames, global: global.curve.stops, radius: options.radius, strength: options.strength, spatialStrength: options.spatialStrength, colourStrength: options.colourStrength, mode: options.mode) : await SpatialLighting.estimateAsync(samples: frames, global: global.curve.stops.map { options.strength > 0 ? $0/options.strength : 0 }, radius: options.radius,
                    strength: options.spatialStrength * options.strength, region: options.reference?.rect, previous: previous, mode: options.mode)
                let separated = SurfaceLighting.separatedCurve(times: global.curve.times,global: global.curve.stops,fields: fields,spatialStrength: options.spatialStrength)
                let anchored = SceneBrightness.anchor(samples: frames, curve: separated, options: options,
                    measurement: reference ?? frames)
                entry = CachedScene(settings: options, frameCount: scene.frameCount,
                    curve: anchored,
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
                          references: [ReferenceRegion: [ExposureSample]], cache: [Int: CachedScene],meterOnly: Bool = false) -> Calculation {
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
                let patches = PatchExposure(cells: range.map { source[$0].cells }, thumbnails: options.reference == nil ? range.map { source[$0].thumbnail } : [])
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
                                          cells: sample.cells, thumbnail: sample.thumbnail, detailThumbnail: sample.detailThumbnail, meterThumbnail: sample.meterThumbnail)
                }
                if Task.isCancelled { break }
                let previous = cache[scene.startFrame].flatMap {
                    $0.frameCount == scene.frameCount ? $0.curve.spatial : nil
                } ?? []
                let fields = SurfaceLighting.enabled && options.strength > 0 && !meterOnly ? SurfaceLighting.estimate(samples: frames, global: global.stops, radius: options.radius, strength: options.strength, spatialStrength: options.spatialStrength, colourStrength: options.colourStrength, mode: options.mode) : SpatialLighting.estimate(samples: frames, global: global.stops.map { options.strength > 0 ? $0/options.strength : 0 }, radius: options.radius,
                    strength: options.spatialStrength * options.strength, region: options.reference?.rect, previous: previous, mode: options.mode)
                let levels = patches.levels.count == range.count ? patches.levels : range.map { source[$0].level }
                let baseline = ExposureMath.median(levels)
                let separated = SurfaceLighting.separatedCurve(times: times,global: global.stops,fields: fields,spatialStrength: options.spatialStrength)
                entry = CachedScene(settings: options, frameCount: scene.frameCount,
                    curve: SceneBrightness.anchor(samples: frames, curve: separated, options: options, measurement: Array(source[range])),
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
        let combined = curve.combinedStops
        for scene in scenes {
            let reference = settings[scene.startFrame]?.reference
            let candidate = reference.flatMap { references[$0] } ?? base
            let source = candidate.count == base.count ? candidate : base
            let range = scene.startFrame..<(scene.startFrame + scene.frameCount)
            let patches = PatchExposure(cells: range.map { source[$0].cells }, thumbnails: reference == nil ? range.map { source[$0].thumbnail } : [])
            let levels = patches.levels.count == range.count ? patches.levels : range.map { source[$0].level }
            let baseline = ExposureMath.median(levels)
            for index in range {
                let value = levels[index - scene.startFrame] - baseline
                original.append(value)
                corrected.append(value + (index < combined.count ? combined[index] : 0))
            }
        }
        return ExposureComparison(times: base.map(\.time), original: original, corrected: corrected)
    }

    static func curve(base: [ExposureSample], boundaries: Set<Int>, settings: [Int: SceneSettings],
                      references: [ReferenceRegion: [ExposureSample]]) -> ExposureCurve {
        calculate(base: base, boundaries: boundaries, settings: settings, references: references, cache: [:]).curve
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

/// Anchor each shot independently and validate the assembled pixel correction.
/// Manual adjustments are added later and are deliberately excluded here.
enum SceneBrightness {
    static func anchor(samples: [ExposureSample], curve: ExposureCurve, options: SceneSettings,
                       measurement: [ExposureSample]) -> ExposureCurve {
        guard options.preserveBrightness, options.strength > 0,
              samples.count == curve.stops.count, measurement.count == samples.count, !samples.isEmpty else { return curve }
        let commonLighting = ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_ILLUMINATION"] == "1"
            && options.reference == nil && options.spatialStrength > 0
        let trackedResidual = ProcessInfo.processInfo.environment["FRANKLUMA_TRACKED_SURFACE_RESIDUAL"] == "1"
            && options.reference == nil && options.spatialStrength > 0 && !commonLighting
        let patches = PatchExposure(cells: measurement.map(\.cells),
            thumbnails: options.reference == nil ? samples.map(\.thumbnail) : [])
        let levels = patches.reliable ? patches.levels : measurement.map(\.level)
        guard levels.count == samples.count, levels.allSatisfy(\.isFinite) else { return curve }
        // Anchor the gradual trend, rather than requiring every frame to have
        // identical brightness. Steady scene still uses a constant median.
        let targetCurve = ExposureMath.curve(samples: zip(samples,levels).map {
            ExposureSample(time: $0.0.time, level: $0.1, segment: 0)
        }, radius: options.radius, strength: 1, mode: options.mode)
        let trend = zip(levels,targetCurve.stops).map(+)
        let anchor = ExposureMath.median(levels)-ExposureMath.median(trend)
        let targets = levels.indices.map { levels[$0]+(trend[$0]+anchor-levels[$0])*options.strength }
        var fields = curve.spatial.count == samples.count ? curve.spatial : Array(repeating: SpatialField(), count: samples.count)
        if fields.allSatisfy({ $0.surface != nil }), patches.reliable {
            // Partial spatial correction intentionally retains local variation.
            // Do not undo the user's choice with a scene-wide residual gain.
            let surfaceTargets = levels.indices.map { i in
                let globalTarget = levels[i]+curve.stops[i]
                return globalTarget+(targets[i]-globalTarget)*options.spatialStrength
            }
            // Surface histories already remove temporal lighting changes. A
            // shot-wide offset preserves the original robust brightness anchor.
            // A bounded residual check then removes errors visible in the
            // rendered stable surfaces, rather than trusting an estimated EV.
            let rendered = samples.indices.compactMap { i -> Double? in
                guard let thumbnail = samples[i].thumbnail else { return nil }
                return patches.brightnessLevel(cells: SpatialRenderer.predictedCells(thumbnail,
                    global: curve.stops[i],field: fields[i],region: options.reference?.rect),frame: i)
            }
            if rendered.count == samples.count {
                let shift = max(-2,min(2,ExposureMath.median(levels)-ExposureMath.median(rendered)))
                for i in fields.indices { fields[i].brightnessEV = shift }
                // Fixed-position source anchors are valid for stationary shots,
                // not for camera pans that reveal different materials. Steady
                // mode requests a constant local target as well as a scene median.
                let movingCamera = fields.contains { $0.cameraMotion == true || $0.alignments.contains { $0.accepted && ($0.dx != 0 || $0.dy != 0) } }
                let smoothValidation = options.mode == .smooth && ProcessInfo.processInfo.environment["FRANKLUMA_SMOOTH_PATCH_VALIDATION"] != "0"
                    && patches.hasStationaryBackground(thumbnails: samples.map(\.thumbnail))
                let patchTargets = smoothValidation ? patches.smoothBrightnessTargets(cells: samples.map(\.cells),times: samples.map(\.time),
                    radius: options.radius,strength: options.strength,global: curve.stops,spatialStrength: options.spatialStrength) : []
                if options.mode == .steady || smoothValidation, options.reference == nil, !movingCamera, options.spatialStrength > 0 {
                    for i in fields.indices {
                        guard let thumbnail = samples[i].thumbnail, let surface = fields[i].surface, surface.rowModel != true else { continue }
                        let cells = SpatialRenderer.predictedCells(thumbnail,global: curve.stops[i],field: fields[i])
                        let residuals: [(Int,Double)]
                        if smoothValidation {
                            residuals = patchTargets.indices.contains(i) ? patchTargets[i].compactMap { patch,target in
                                guard cells.indices.contains(patch),cells[patch].isFinite,cells[patch] > 0.001 else { return nil }
                                return (patch,target-log2(cells[patch]))
                            } : []
                        } else {
                            residuals = patches.brightnessResiduals(cells: cells,source: samples[i].cells,frame: i,
                                target: surfaceTargets[i],strength: options.strength)
                        }
                        let validated = SurfaceLighting.validatedGains(surface,residuals: residuals,amount: options.spatialStrength)
                        fields[i].surface = validated
                        for p in fields[i].applied.indices {
                            let x = min(validated.width-1,Int((Double(p%24)+0.5)/24*Double(validated.width)))
                            let y = min(validated.height-1,Int((Double(p/24)+0.5)/14*Double(validated.height)))
                            let k = (y*validated.width+x)*3
                            fields[i].applied[p] = 0.2126*Double(validated.channelEV[k])+0.7152*Double(validated.channelEV[k+1])+0.0722*Double(validated.channelEV[k+2])
                            fields[i].requested[p] = fields[i].applied[p]
                        }
                    }
                }
                // Diagnostic ablation: retain the constant shot shift while
                // separating spatial fitting from extrapolated global residuals.
                if ProcessInfo.processInfo.environment["FRANKLUMA_CONSTANT_SURFACE_ANCHOR"] != "1",
                   (!trackedResidual || ProcessInfo.processInfo.environment["FRANKLUMA_TRACKED_RESIDUAL_KEEP_GLOBAL"] == "1") {
                    for i in fields.indices {
                        guard let thumbnail = samples[i].thumbnail else { continue }
                        let cells = SpatialRenderer.predictedCells(thumbnail,global: curve.stops[i],field: fields[i],region: options.reference?.rect)
                        guard let measured = patches.brightnessLevel(cells: cells,frame: i) else { continue }
                        fields[i].brightnessEV = shift+max(-0.25,min(0.25,surfaceTargets[i]-measured))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["FRANKLUMA_CONSTANT_SURFACE_ANCHOR"] != "1",
               (!trackedResidual || ProcessInfo.processInfo.environment["FRANKLUMA_TRACKED_RESIDUAL_KEEP_GLOBAL"] == "1"),
               ProcessInfo.processInfo.environment["FRANKLUMA_REGISTERED_ANCHOR"] != "0",
               options.reference == nil,options.spatialStrength > 0,samples.allSatisfy({ $0.thumbnail != nil }),
               fields.contains(where: { $0.cameraMotion == true }) {
                let rendered = samples.indices.map { i -> SpatialThumbnail in
                    let image = samples[i].thumbnail!,map = fields[i].surface!
                    var rgb = [Float]();rgb.reserveCapacity(image.rgb.count)
                    for y in 0..<image.height { for x in 0..<image.width {
                        let p = (y*image.width+x)*3
                        let pixel = (0..<3).map { Double(image.rgb[p+$0]) }
                        rgb += SpatialRenderer.surfaceRGB(pixel,x: (Double(x)+0.5)/Double(image.width),y: (Double(y)+0.5)/Double(image.height),
                            map: map,global: curve.stops[i]+(fields[i].brightnessEV ?? 0)).map(Float.init)
                    } }
                    return SpatialThumbnail(width: image.width,height: image.height,rgb: rgb)
                }
                var diagonal = Array(repeating: 1.0,count: samples.count),lower = Array(repeating: 0.0,count: samples.count),rhs = lower
                var substantial = false
                for i in 1..<samples.count {
                    guard fields[i].surface?.rowModel != true,fields[i-1].surface?.rowModel != true,
                          let residual = SurfaceLighting.cameraValidationResidual(samples[i-1].thumbnail!,samples[i].thumbnail!,renderedA: rendered[i-1],renderedB: rendered[i]) else { continue }
                    substantial = substantial || abs(residual) > 0.06*options.strength*options.spatialStrength
                    let weight = 4.0
                    diagonal[i-1] += weight;diagonal[i] += weight;lower[i] = -weight
                    rhs[i-1] += weight*residual;rhs[i] -= weight*residual
                }
                if substantial {
                    for i in 1..<samples.count {
                        let factor = lower[i]/diagonal[i-1]
                        diagonal[i] -= factor*lower[i];rhs[i] -= factor*rhs[i-1]
                    }
                    var adjustment = rhs
                    for i in stride(from: samples.count-1,through: 0,by: -1) {
                        adjustment[i] = (rhs[i]-(i+1 < samples.count ? lower[i+1]*adjustment[i+1] : 0))/diagonal[i]
                    }
                    let centre = ExposureMath.median(adjustment),limit = 0.25*options.strength*options.spatialStrength
                    for i in fields.indices { fields[i].brightnessEV = (fields[i].brightnessEV ?? 0)+max(-limit,min(limit,adjustment[i]-centre)) }
                }
            }
            if commonLighting || trackedResidual {
                fields = TrackedSurfaceResidual.apply(samples: samples,stops: curve.stops,fields: fields,options: options,
                    sourceComponent: commonLighting)
            } else if ProcessInfo.processInfo.environment["FRANKLUMA_PERSISTENT_LOCAL_FLASH"] == "1",
               options.reference == nil, options.spatialStrength > 0 {
                fields = PersistentLocalFlash.apply(samples: samples,stops: curve.stops,fields: fields,options: options)
            } else if ProcessInfo.processInfo.environment["FRANKLUMA_SHARED_FLASH_ANCHOR"] == "1",
               options.reference == nil, options.spatialStrength > 0 {
                fields = SharedFlashAnchor.apply(samples: samples, stops: curve.stops, fields: fields, options: options)
            }
            if ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_COMPOSITION"] == "1" {
                fields = TrackedSurfaceResidual.applyPulseComposition(samples:samples,stops:curve.stops,fields:fields,options:options)
            }
            if ProcessInfo.processInfo.environment["FRANKLUMA_QUIET_COLOUR_CONTINUITY"] == "1" {
                fields = QuietColourContinuity.apply(samples:samples,stops:curve.stops,fields:fields,options:options)
            }
            return ExposureCurve(times: curve.times,stops: curve.stops,spatial: fields)
        }
        if patches.reliable, samples.allSatisfy({ $0.thumbnail != nil }) {
            for i in samples.indices {
                if Task.isCancelled { return curve }
                fields[i].brightnessEV = 0
                // Validate local fits against held, unoccluded background
                // references. Correct their smooth residual, never image texture.
                if options.spatialStrength > 0, options.reference == nil {
                    for _ in 0..<2 {
                        let output = SpatialRenderer.predictedCells(samples[i].thumbnail!, global: curve.stops[i], field: fields[i])
                        var residual = SpatialField()
                        for (p, error) in patches.brightnessResiduals(cells: output, source: samples[i].cells, frame: i,
                            target: targets[i], strength: options.strength) {
                            residual.confidence[p] = 1
                            residual.requested[p] = error
                        }
                        guard residual.confidence.filter({ $0 > 0 }).count >= 18 else { break }
                        // A shared exposure error belongs to the global anchor.
                        // Fitting it only over selected patches would brighten
                        // or darken unsupported parts of an otherwise uniform shot.
                        let commonError = ExposureMath.median(residual.requested.indices.filter { residual.confidence[$0] > 0 }.map { residual.requested[$0] })
                        residual.requested = residual.requested.map { max(-0.5,min(0.5,$0-commonError)) }
                        var adjustment = SpatialLighting.fit(field: residual)
                        for node in adjustment.indices {
                            let x = Double(node % 9)/8, y = Double(node / 9)/5
                            let nearby = (0..<336).filter { p in
                                residual.confidence[p] > 0 && pow((Double(p % 24)+0.5)/24-x,2) + pow((Double(p / 24)+0.5)/14-y,2) < 0.025
                            }.map { residual.requested[$0] }
                            // No extrapolation into a foreground or unsupported
                            // corner, and no fitted gain outside local evidence.
                            adjustment[node] = nearby.count >= 3 ? max(min(0,nearby.min()!),min(max(0,nearby.max()!),adjustment[node])) : 0
                        }
                        let previous = fields[i].validationStops ?? Array(repeating: 0, count: 54)
                        fields[i].validationStops = zip(previous,adjustment).map { max(-0.5,min(0.5,$0+$1)) }
                    }
                }
                for _ in 0..<3 {
                    let cells = SpatialRenderer.predictedCells(samples[i].thumbnail!, global: curve.stops[i], field: fields[i], region: options.reference?.rect)
                    guard let measured = patches.brightnessLevel(cells: cells, frame: i) else { break }
                    let delta = targets[i]-measured
                    fields[i].brightnessEV = max(-2,min(2,(fields[i].brightnessEV ?? 0)+delta))
                    if abs(delta) < 0.001 { break }
                }
            }
            return ExposureCurve(times: curve.times, stops: curve.stops, spatial: fields)
        }
        // Global-only/legacy measurements have no images to validate. Retain
        // their conservative correction while removing shot-wide exposure drift.
        let corrected = zip(levels,curve.stops).map(+)
        let shift = (ExposureMath.median(levels)-ExposureMath.median(corrected))
        guard abs(shift) > 0.00000001 else { return curve }
        return ExposureCurve(times: curve.times, stops: curve.stops.map { max(-2,min(2,$0+shift)) }, spatial: curve.spatial)
    }
}
