import Foundation
import CoreGraphics

struct SpatialThumbnail: Sendable, Codable {
    let width: Int
    let height: Int
    let rgb: [Float] // Same row order as the CI bitmap; display coordinates.
    var light: [Double] {
        stride(from: 0, to: rgb.count, by: 3).map { 0.2126 * Double(rgb[$0]) + 0.7152 * Double(rgb[$0 + 1]) + 0.0722 * Double(rgb[$0 + 2]) }
    }
}

struct SpatialAlignment: Sendable, Codable {
    let reference: Int
    let dx: Int
    let dy: Int
    let error: Double
    let accepted: Bool
}

struct SpatialField: Sendable, Codable {
    var columns = 9
    var rows = 6
    var stops = [Double](repeating: 0, count: 54)
    var offsets = [Double](repeating: 0, count: 54)
    var exposureStops = [Double](repeating: 0, count: 54)
    var sampleColumns = 24
    var sampleRows = 14
    var confidence = [Double](repeating: 0, count: 336)
    var motion = [Double](repeating: 1, count: 336)
    var requested = [Double](repeating: 0, count: 336)
    var applied = [Double](repeating: 0, count: 336)
    var before = [Double](repeating: 0, count: 336)
    var reference = [Double](repeating: 0, count: 336)
    var alignments: [SpatialAlignment] = []
    var fallback: String? = "Spatial correction disabled"
    var peak: Double { stops.map(abs).max() ?? 0 }

    func value(x: Double, y: Double) -> Double {
        Self.basis(x: x, y: y, columns: columns, rows: rows).reduce(0) { $0 + stops[$1.0] * $1.1 }
    }
    func offset(x: Double, y: Double) -> Double {
        Self.basis(x: x, y: y, columns: columns, rows: rows).reduce(0) { $0 + offsets[$1.0] * $1.1 }
    }
    static func basis(x: Double, y: Double, columns: Int, rows: Int) -> [(Int, Double)] {
        let px = max(0, min(Double(columns - 1), x * Double(columns - 1)))
        let py = max(0, min(Double(rows - 1), y * Double(rows - 1)))
        let ix = min(columns - 2, Int(px)), iy = min(rows - 2, Int(py))
        let fx = px - Double(ix), fy = py - Double(iy)
        return [(iy * columns + ix, (1-fx)*(1-fy)), (iy * columns + ix+1, fx*(1-fy)),
                ((iy+1) * columns + ix, (1-fx)*fy), ((iy+1) * columns + ix+1, fx*fy)]
    }
}

enum SpatialLighting {
    private struct Frame {
        let thumb: SpatialThumbnail
        let luminance: [Double]
        let log: [Double]
        let red: [Double]
        let green: [Double]
        let gradientX: [Double]
        let gradientY: [Double]
        let features: [Int]
        init(_ t: SpatialThumbnail) {
            thumb = t; luminance = t.light
            log = luminance.map { log2(max(0.001, $0)) }
            red = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
            green = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i+1]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
            var gx = [Double](repeating: 0, count: luminance.count), gy = gx
            for y in 1..<(t.height-1) { for x in 1..<(t.width-1) {
                let p = y*t.width+x
                gx[p] = log[p+1]-log[p-1]; gy[p] = log[p+t.width]-log[p-t.width]
            } }
            gradientX = gx; gradientY = gy
            var positions: [Int] = []
            for y in stride(from: 4, to: t.height-4, by: 3) { for x in stride(from: 4, to: t.width-4, by: 3) {
                let p = y*t.width+x
                if luminance[p] > 0.02, abs(gx[p])+abs(gy[p]) > 0.03 { positions.append(p) }
            } }
            features = positions
        }
    }

    private static let sampleBasis = (0..<336).map { p in
        SpatialField.basis(x: (Double(p % 24)+0.5)/24, y: (Double(p / 24)+0.5)/14, columns: 9, rows: 6)
    }
    private static let supportWeights = (0..<54).map { node in
        (0..<336).map { p in
            let dx = (Double(p % 24)+0.5)/24-Double(node % 9)/8
            let dy = (Double(p / 24)+0.5)/14-Double(node / 9)/5
            return exp(-0.5*(pow(dx/0.12,2)+pow(dy/0.16,2)))
        }
    }

    /// Independent patch targets from original light, never from neighbours
    /// that have already received the scene-wide exposure adjustment.
    private static func temporalTargets(samples: [ExposureSample], radius: Double, mode: NormalisationMode) -> [[Double]] {
        guard let thumbnail = samples.first?.thumbnail, thumbnail.width >= 24, thumbnail.height >= 20,
              samples.allSatisfy({ $0.thumbnail?.width == thumbnail.width && $0.thumbnail?.height == thumbnail.height }) else { return [] }
        let w = thumbnail.width, h = thumbnail.height
        var means: [[Double]] = [], reds: [[Double]] = [], greens: [[Double]] = []
        means.reserveCapacity(samples.count); reds.reserveCapacity(samples.count); greens.reserveCapacity(samples.count)
        for sample in samples {
            if Task.isCancelled { return [] }
            let rgb = sample.thumbnail!.rgb
            var patches: [Double] = [], red: [Double] = [], green: [Double] = []
            patches.reserveCapacity(336)
            for row in 0..<14 { for col in 0..<24 {
                let x = min(w-3, max(2, Int((Double(col)+0.5)/24*Double(w))))
                let y = min(h-3, max(2, Int((Double(row)+0.5)/14*Double(h))))
                var r = 0.0, g = 0.0, b = 0.0
                for dy in -2...2 { for dx in -2...2 {
                    let p = ((y+dy)*w+x+dx)*3
                    r += Double(rgb[p]); g += Double(rgb[p+1]); b += Double(rgb[p+2])
                } }
                patches.append((0.2126*r+0.7152*g+0.0722*b)/25)
                red.append(r/max(0.001,r+g+b)); green.append(g/max(0.001,r+g+b))
            } }
            means.append(patches); reds.append(red); greens.append(green)
        }
        var targets = means
        for patch in 0..<336 {
            if Task.isCancelled { return [] }
            let red = ExposureMath.median(reds.map { $0[patch] })
            let green = ExposureMath.median(greens.map { $0[patch] })
            let anchor = samples.indices.min {
                abs(reds[$0][patch]-red)+abs(greens[$0][patch]-green) < abs(reds[$1][patch]-red)+abs(greens[$1][patch]-green)
            }!
            let x = min(w-3, max(2, Int((Double(patch % 24)+0.5)/24*Double(w))))
            let y = min(h-3, max(2, Int((Double(patch / 24)+0.5)/14*Double(h))))
            let valid = samples.indices.filter { i in
                let colour = abs(reds[i][patch]-red)+abs(greens[i][patch]-green)
                guard means[i][patch] > 0.015 else { return false }
                if colour < 0.04 { return true }
                // Additive illumination changes chromaticity even when the
                // physical surface is unchanged. Require matching texture.
                return colour < 0.12 && textureCorrelation(samples[i].thumbnail!, samples[anchor].thumbnail!, x: x, y: y) > 0.97
            }
            for i in samples.indices { targets[i][patch] = .nan }
            guard valid.count >= 3 else { continue }
            let series = valid.map { ExposureSample(time: samples[$0].time,
                level: log2(max(0.001, means[$0][patch])), segment: samples[$0].segment) }
            let correction = ExposureMath.curve(samples: series, radius: radius, strength: 1, mode: mode)
            for (index, i) in valid.enumerated() { targets[i][patch] = means[i][patch]*pow(2,correction.stops[index]) }
        }
        return targets
    }

    /// Work on independent ranges with a six-frame halo. This reproduces the
    /// serial neighbour selection while using multiple cores on long shots.
    static func estimateAsync(samples: [ExposureSample], global: [Double], radius: Double, strength: Double,
                              region: CGRect? = nil, previous: [SpatialField] = [], chunkSize: Int = 120, mode: NormalisationMode = .smooth) async -> [SpatialField] {
        let chunkSize = max(1, chunkSize)
        guard samples.count > chunkSize, samples.count == global.count, strength > 0 else {
            return estimate(samples: samples, global: global, radius: radius, strength: strength, region: region, previous: previous, mode: mode)
        }
        let targets = temporalTargets(samples: samples, radius: radius, mode: mode)
        if Task.isCancelled { return [] }
        let workers = min(6, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        return await withTaskGroup(of: (Int, [SpatialField]).self) { group in
            var output = [SpatialField](repeating: SpatialField(), count: samples.count)
            var next = 0
            func enqueue(_ start: Int) {
                let end = min(samples.count, start + chunkSize)
                let lower = max(0, start - 6), upper = min(samples.count, end + 6)
                group.addTask {
                    if Task.isCancelled { return (start, []) }
                    let old = previous.count == samples.count ? previous[lower..<upper].map { field -> SpatialField in
                        var field = field
                        field.alignments = field.alignments.map {
                            SpatialAlignment(reference: $0.reference-lower, dx: $0.dx, dy: $0.dy, error: $0.error, accepted: $0.accepted)
                        }
                        return field
                    } : []
                    let fields = estimate(samples: Array(samples[lower..<upper]), global: Array(global[lower..<upper]),
                                          radius: radius, strength: strength, region: region, previous: old, mode: mode, targets: targets.isEmpty ? [] : Array(targets[lower..<upper]))
                    guard fields.count == upper-lower else { return (start, []) }
                    return (start, fields[(start-lower)..<(end-lower)].map { field -> SpatialField in
                        var field = field
                        field.alignments = field.alignments.map {
                            SpatialAlignment(reference: $0.reference+lower, dx: $0.dx, dy: $0.dy, error: $0.error, accepted: $0.accepted)
                        }
                        return field
                    })
                }
            }
            for _ in 0..<workers where next < samples.count { enqueue(next); next += chunkSize }
            for await (start, fields) in group {
                if Task.isCancelled { group.cancelAll(); continue }
                for (offset, field) in fields.enumerated() { output[start+offset] = field }
                if next < samples.count { enqueue(next); next += chunkSize }
            }
            return Task.isCancelled ? [] : output
        }
    }

    static func estimate(samples: [ExposureSample], global: [Double], radius: Double, strength: Double,
                         region: CGRect? = nil, previous: [SpatialField] = [], mode: NormalisationMode = .smooth, targets: [[Double]] = []) -> [SpatialField] {
        if Task.isCancelled { return [] }
        guard !samples.isEmpty, samples.count == global.count, samples.allSatisfy({ $0.thumbnail != nil }), strength > 0 else {
            let disabled = SpatialField()
            return samples.map { _ in disabled }
        }
        let w = samples[0].thumbnail!.width, h = samples[0].thumbnail!.height
        guard w >= 24, h >= 20, samples.allSatisfy({ $0.thumbnail!.width == w && $0.thumbnail!.height == h }) else {
            let disabled = SpatialField()
            return samples.map { _ in disabled }
        }
        let targets = targets.count == samples.count ? targets : temporalTargets(samples: samples, radius: radius, mode: mode)
        guard targets.count == samples.count, !Task.isCancelled else { return [] }
        // Only the current frame and its six local references need derived
        // luminance/gradient arrays. Keep that working set bounded on long shots.
        var frames: [Int: Frame] = [:]
        func prepare(_ index: Int) {
            if frames[index] == nil { frames[index] = Frame(samples[index].thumbnail!) }
        }
        var result: [SpatialField] = []
        result.reserveCapacity(samples.count)
        for i in samples.indices {
            if Task.isCancelled { return [] }
            var field = SpatialField()
            let neighbours = neighbourIndices(samples: samples, index: i, radius: radius)
            let needed = Set(neighbours + [i])
            frames = frames.filter { needed.contains($0.key) }
            for index in needed { prepare(index) }
            for j in neighbours {
                if previous.count == samples.count,
                   let alignment = previous[i].alignments.first(where: { $0.reference == j }) {
                    field.alignments.append(alignment)
                    continue
                }
                let shift = register(frames[i]!, frames[j]!)
                field.alignments.append(SpatialAlignment(reference: j, dx: shift.dx, dy: shift.dy, error: shift.error, accepted: shift.accepted))
            }
            let accepted = field.alignments.filter(\.accepted)
            guard accepted.count >= 2 else {
                field.fallback = "Too few aligned neighbouring frames"
                result.append(field); continue
            }
            var offsetTargets = [Double](repeating: 0, count: field.confidence.count)
            var spreads = offsetTargets
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                let index = row * field.sampleColumns + col
                let nx = (Double(col) + 0.5) / Double(field.sampleColumns)
                let ny = (Double(row) + 0.5) / Double(field.sampleRows)
                if let region, !region.contains(CGPoint(x: nx, y: ny)) { continue }
                let x = min(w-3, max(2, Int(nx * Double(w))))
                let y = min(h-3, max(2, Int(ny * Double(h))))
                var gains: [Double] = [], matchedMeans: [Double] = [], alignedMeans: [Double] = [], weights: [Double] = []
                let patch = (-2...2).flatMap { dy in (-2...2).map { dx in frames[i]!.luminance[(y+dy)*w+x+dx] } }
                let current = patch.reduce(0,+)/Double(patch.count)
                spreads[index] = sqrt(patch.map { pow($0-current,2) }.reduce(0,+)/Double(patch.count))
                field.before[index] = current
                for alignment in accepted {
                    let j = alignment.reference
                    let match = compare(frames[i]!, frames[j]!, x: x, y: y, dx: alignment.dx, dy: alignment.dy)
                    if match.confidence > 0 {
                        gains.append(match.delta)
                        let mean = current*pow(2,match.delta)+match.offset
                        matchedMeans.append(mean)
                        alignedMeans.append(mean*pow(2,global[j]))
                        weights.append(match.confidence)
                    }
                }
                let fraction = Double(gains.count) / Double(accepted.count)
                field.motion[index] = 1 - fraction
                guard gains.count >= 2, fraction >= 0.5 else { continue }
                // Texture matches establish motion/contrast support. Brightness
                // is anchored independently, so a globally overcorrected floor
                // in a neighbouring flash cannot become this frame's target.
                // Fixed-coordinate baselines are unsuitable for camera moves.
                // Registered raw patch means retain their physical correspondence.
                let translated = accepted.contains { $0.dx != 0 || $0.dy != 0 }
                let desired = translated ? ExposureMath.median(alignedMeans) : targets[i][index]
                guard desired.isFinite else { field.motion[index] = 1; continue }
                // Gain and offset describe the same reference, so normalise
                // its contrast to the independent target before combining fits.
                // Raw gain medians alone would follow alternating bright/dark
                // neighbours even when their mean target is already stable.
                let contrast = zip(gains, matchedMeans).map {
                    $0 + log2(max(0.001, desired)/max(0.001, $1))
                }
                let residual = ExposureMath.median(contrast) - global[i]
                let confidence = ExposureMath.median(weights) * fraction
                guard confidence > 0.25, current > 0.015 else { continue }
                field.confidence[index] = confidence
                field.requested[index] = max(-0.75, min(0.75, residual))
                offsetTargets[index] = desired - current * pow(2, global[i] + field.requested[index])
                field.reference[index] = desired

            } }
            // Erode uncertain boundary patches beside motion/occlusion. A patch
            // with consistent correspondence must keep its own lighting target;
            // a moving neighbour does not invalidate that physical surface.
            let motion = field.motion
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                let index = row * field.sampleColumns + col
                if motion[index] > 0.5 { field.confidence[index] = 0; continue }
                var movingNeighbours = 0
                for yy in max(0,row-1)...min(field.sampleRows-1,row+1) {
                    for xx in max(0,col-1)...min(field.sampleColumns-1,col+1) {
                        if motion[yy*field.sampleColumns+xx] > 0.65 { movingNeighbours += 1 }
                    }
                }
                if movingNeighbours > 0, motion[index] > 0.25 { field.confidence[index] *= 0.4 }
            } }
            guard field.confidence.filter({ $0 > 0.25 }).count >= 18 else {
                field.fallback = "Insufficient unoccluded background support"
                result.append(field); continue
            }
            var exposureField = field
            exposureField.requested = field.requested.indices.map { p in
                log2(max(0.25, pow(2,field.requested[p]) + offsetTargets[p] / max(0.02,field.before[p]*pow(2,global[i]))))
            }
            field.exposureStops = fit(field: exposureField).map { max(-0.9,min(0.9,$0))*strength }
            let fitted = fitTone(field: field, offsets: offsetTargets, spreads: spreads, global: global[i])
            field.stops = fitted.gains.map { log2(max(0.25, $0)) * strength }
            field.offsets = fitted.offsets.map { $0 * strength }
            // Fade unsupported portions smoothly towards global correction.
            // Do not extrapolate a large gain into an occluded/clipped corner.
            for y in 0..<field.rows { for x in 0..<field.columns {
                var support=0.0, total=0.0
                for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
                    let weight = supportWeights[y*field.columns+x][r*field.sampleColumns+c]
                    // Confidence already weights the fit. Fade by coverage of
                    // reliable anchors, rather than weakening their gain again
                    // when neighbouring foreground patches have been excluded.
                    if field.confidence[r*field.sampleColumns+c] > 0.25 { support += weight }
                    total += weight
                } }
                let supportWeight = min(1, support/max(0.00001,total)/0.35)
                field.stops[y*field.columns+x] *= supportWeight
                field.offsets[y*field.columns+x] *= supportWeight
                field.exposureStops[y*field.columns+x] *= supportWeight
            } }
            // Bound gradients to avoid abrupt local contrast changes.
            for _ in 0..<4 {
                for y in 0..<field.rows { for x in 0..<field.columns {
                    let p = y*field.columns+x
                    for q in [x+1 < field.columns ? p+1 : p, y+1 < field.rows ? p+field.columns : p] where q != p {
                        let difference = field.stops[p] - field.stops[q]
                        if abs(difference) > 0.18 {
                            let adjustment = (abs(difference)-0.18)/2 * (difference > 0 ? 1.0 : -1.0)
                            field.stops[p] -= adjustment; field.stops[q] += adjustment
                        }
                    }
                } }
            }
            field.fallback = nil
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                field.applied[row*field.sampleColumns+col] = field.value(x: (Double(col)+0.5)/Double(field.sampleColumns), y: (Double(row)+0.5)/Double(field.sampleRows))
            } }
            result.append(field)
        }
        return result
    }

    static func neighbourIndices(samples: [ExposureSample], index: Int, radius: Double) -> [Int] {
        let window = max(0.25, radius)+0.000001
        var neighbours: [Int] = []
        var distance = 1
        var leftOpen = true, rightOpen = true
        while neighbours.count < 6, leftOpen || rightOpen {
            let left = index-distance, right = index+distance
            if leftOpen {
                leftOpen = left >= 0 && samples[left].segment == samples[index].segment && samples[index].time-samples[left].time <= window
                if leftOpen { neighbours.append(left) }
            }
            if rightOpen, neighbours.count < 6 {
                rightOpen = right < samples.count && samples[right].segment == samples[index].segment && samples[right].time-samples[index].time <= window
                if rightOpen { neighbours.append(right) }
            }
            distance += 1
        }
        return neighbours
    }

    /// Bounded translation registration on log-luminance gradients. Large
    /// motion, parallax or rotation that fails this test falls back safely.
    private static func register(_ a: Frame, _ b: Frame) -> (dx: Int, dy: Int, error: Double, accepted: Bool) {
        let w = a.thumb.width, h = a.thumb.height
        func cost(_ dx: Int, _ dy: Int) -> Double {
            var sum = 0.0, count = 0
            for p in a.features {
                let y = p/w, x = p % w
                let xx=x+dx, yy=y+dy
                guard xx>1, xx<w-2, yy>1, yy<h-2 else { continue }
                let q=yy*w+xx
                guard b.luminance[q]>0.02 else { continue }
                let residual=abs(a.gradientX[p]-b.gradientX[q])+abs(a.gradientY[p]-b.gradientY[q])
                sum += min(0.3,residual); count += 1
            }
            return count >= 12 ? sum/Double(count) : 0.3
        }
        var best=(dx:0,dy:0,error:cost(0,0))
        for dy in stride(from: -8, through: 8, by: 1) { for dx in stride(from: -12, through: 12, by: 1) {
            let value=cost(dx,dy) + 0.0001*Double(abs(dx)+abs(dy))
            if value < best.error { best=(dx,dy,value) }
        } }
        // Flat synthetic/background images have no registration features. Only
        // accept zero translation when chromaticity and local structure agree.
        if best.error >= 0.29 {
            let centre=compare(a,b,x:w/2,y:h/2,dx:0,dy:0)
            if centre.confidence>0.8 { return (0,0,0,true) }
        }
        return (best.dx,best.dy,best.error,best.error < (best.dx == 0 && best.dy == 0 ? 0.20 : 0.12) && abs(best.dx)<12 && abs(best.dy)<8)
    }

    /// Exposure/offset invariant patch structure. Flat patches cannot prove
    /// correspondence; colour checks continue to protect those regions.
    private static func textureCorrelation(_ a: SpatialThumbnail, _ b: SpatialThumbnail, x: Int, y: Int) -> Double {
        let w = a.width
        var aa: [Double] = [], bb: [Double] = []
        for yy in -2...2 { for xx in -2...2 {
            let p = ((y+yy)*w+x+xx)*3
            aa.append(0.2126*Double(a.rgb[p])+0.7152*Double(a.rgb[p+1])+0.0722*Double(a.rgb[p+2]))
            bb.append(0.2126*Double(b.rgb[p])+0.7152*Double(b.rgb[p+1])+0.0722*Double(b.rgb[p+2]))
        } }
        let ma = aa.reduce(0,+)/25, mb = bb.reduce(0,+)/25
        var va = 0.0, vb = 0.0, covariance = 0.0
        for i in aa.indices {
            let da = aa[i]-ma, db = bb[i]-mb
            va += da*da; vb += db*db; covariance += da*db
        }
        guard va/25 > 0.00002, vb/25 > 0.00002 else { return 0 }
        return covariance/sqrt(va*vb)
    }

    private static func compare(_ a: Frame, _ b: Frame, x: Int, y: Int, dx: Int, dy: Int) -> (delta: Double, offset: Double, confidence: Double) {
        let w=a.thumb.width,h=a.thumb.height
        guard x+dx>=2, x+dx<w-2, y+dy>=2, y+dy<h-2 else { return (0,0,0) }
        var ratios:[Double]=[], colours:[Double]=[], pairs:[(Double, Double)]=[]
        for yy in -2...2 { for xx in -2...2 {
            let p=(y+yy)*w+x+xx, q=(y+yy+dy)*w+x+xx+dx
            let ap=p*3,bp=q*3
            guard a.luminance[p]>0.015,b.luminance[q]>0.015,
                  max(a.thumb.rgb[ap],a.thumb.rgb[ap+1],a.thumb.rgb[ap+2])<0.97,
                  max(b.thumb.rgb[bp],b.thumb.rgb[bp+1],b.thumb.rgb[bp+2])<0.97 else { continue }
            ratios.append(b.log[q]-a.log[p])
            pairs.append((a.luminance[p], b.luminance[q]))
            colours.append(abs(a.red[p]-b.red[q])+abs(a.green[p]-b.green[q]))
        } }
        guard ratios.count>=12 else { return (0,0,0) }
        let delta=ExposureMath.median(ratios)
        let residual=ExposureMath.median(ratios.map { abs($0-delta) })
        let colour=ExposureMath.median(colours)
        let meanA = pairs.map { $0.0 }.reduce(0,+)/Double(pairs.count)
        let meanB = pairs.map { $0.1 }.reduce(0,+)/Double(pairs.count)
        let varianceA = pairs.map { pow($0.0-meanA,2) }.reduce(0,+)
        let varianceB = pairs.map { pow($0.1-meanB,2) }.reduce(0,+)
        let covarianceAB = pairs.map { ($0.0-meanA)*($0.1-meanB) }.reduce(0,+)
        let correlation = varianceA > 0.0005 && varianceB > 0.0005 ? covarianceAB/sqrt(varianceA*varianceB) : 0
        let sameTexture = correlation > 0.97 && colour < 0.12
        guard ratios.count >= 18 || sameTexture else { return (delta,0,0) }
        guard colour < 0.055 || sameTexture else { return (delta,0,0) }
        // Estimate the gain from matched linear-light energy, rather than
        // the median pixel ratio. The latter overweights dark crevices on
        // textured surfaces and can turn a dark floor frame into a bright one.
        // Downweight inconsistent pixel pairs before summing to retain robustness
        // against small occlusions and misregistration.
        var source = 0.0, target = 0.0, support = 0.0
        for (index, pair) in pairs.enumerated() {
            let weight = min(1, max(0.08, 3*residual) / max(0.000001, abs(ratios[index]-delta)))
            source += weight * pair.0; target += weight * pair.1; support += weight
        }
        guard support >= (sameTexture ? 12 : 18), source > 0 else { return (delta, 0, 0) }
        let scalar = target/source
        var gain = scalar, offset = 0.0
        // A diffuse-light change can affect bright studs and dark recesses
        // differently. Only introduce an offset when matched texture supports
        // a materially better affine fit than an exposure-only fit.
        let meanX = pairs.map { $0.0 }.reduce(0,+)/Double(pairs.count)
        let meanY = pairs.map { $0.1 }.reduce(0,+)/Double(pairs.count)
        let variance = pairs.map { pow($0.0-meanX,2) }.reduce(0,+)
        if variance/Double(pairs.count) > (sameTexture ? 0.00002 : 0.0004) {
            let covariance = pairs.map { ($0.0-meanX)*($0.1-meanY) }.reduce(0,+)
            let slope = covariance/variance
            let intercept = meanY-slope*meanX
            let scalarError = pairs.map { pow($0.1-scalar*$0.0,2) }.reduce(0,+)
            let affineError = pairs.map { pow($0.1-slope*$0.0-intercept,2) }.reduce(0,+)
            if slope > (sameTexture ? 0.25 : 0.5), slope < (sameTexture ? 4 : 2), abs(intercept) < 0.25,
               affineError < scalarError * 0.4 {
                gain = slope; offset = intercept
            }
        }
        let fitResidual = ExposureMath.median(pairs.map { abs($0.1 - (gain*$0.0+offset)) / max(0.02,$0.1) })
        guard fitResidual < 0.07 || (sameTexture && fitResidual < 0.15) else { return (delta,0,0) }
        let ordinary = max(0,1-fitResidual/0.09)*max(0,1-colour/0.065)
        let structural = sameTexture ? 0.8*max(0,1-fitResidual/0.2) : 0
        return (log2(gain),offset,max(ordinary,structural))
    }

    /// Fit gain and offset together: every background patch constrains its
    /// corrected mean, and textured patches additionally constrain contrast.
    /// Separate fits can satisfy neither after spatial interpolation.
    private static func fitTone(field: SpatialField, offsets: [Double], spreads: [Double], global: Double) -> (gains: [Double], offsets: [Double]) {
        let nodes = field.columns * field.rows, n = nodes * 2
        let globalGain = pow(2, global)
        var matrix = [Double](repeating: 0, count: n*n), rhs = [Double](repeating: 0, count: n)
        func add(_ terms: [(Int,Double)], _ weight: Double, _ target: Double) {
            for (a,wa) in terms {
                rhs[a] += weight*wa*target
                for (b,wb) in terms { matrix[a*n+b] += weight*wa*wb }
            }
        }
        for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
            let p=r*field.sampleColumns+c
            guard field.confidence[p] > 0 else { continue }
            let basis = sampleBasis[p]
            let light=field.before[p]*globalGain
            let gain=pow(2,field.requested[p])-1
            let meanTerms=basis.map { ($0.0,$0.1*light*4) } + basis.map { ($0.0+nodes,$0.1) }
            add(meanTerms,field.confidence[p],(gain*light+offsets[p])*4)
            let spread=spreads[p]*globalGain*4
            add(basis.map { ($0.0,$0.1*spread) },field.confidence[p],gain*spread)
        } }
        for channel in 0..<2 { for y in 0..<field.rows { for x in 0..<field.columns {
            let p=channel*nodes+y*field.columns+x
            add([(p,1)],0.002,0)
            if x>0 && x<field.columns-1 { add([(p-1,1),(p,-2),(p+1,1)],0.10,0) }
            if y>0 && y<field.rows-1 { add([(p-field.columns,1),(p,-2),(p+field.columns,1)],0.10,0) }
        } } }
        var lower=[Double](repeating:0,count:n*n)
        for i in 0..<n { for j in 0...i {
            var value=matrix[i*n+j]
            for k in 0..<j { value -= lower[i*n+k]*lower[j*n+k] }
            lower[i*n+j] = i==j ? sqrt(max(0.000001,value)) : value/lower[j*n+j]
        } }
        var temp=[Double](repeating:0,count:n), solution=temp
        for i in 0..<n { var value=rhs[i];for j in 0..<i { value -= lower[i*n+j]*temp[j] };temp[i]=value/lower[i*n+i] }
        for i in stride(from:n-1,through:0,by:-1) { var value=temp[i];if i+1<n { for j in (i+1)..<n { value -= lower[j*n+i]*solution[j] } };solution[i]=value/lower[i*n+i] }
        return (Array(solution.prefix(nodes)).map { max(0.6,min(1.6,1+$0)) }, Array(solution.suffix(nodes)).map { max(-0.25,min(0.25,$0/4)) })
    }

    /// Robust weighted least squares with a bending penalty and a weak zero
    /// prior. Preserve supported regional flashes instead of treating their
    /// concentrated residuals as outliers. Unsupported cells relax towards
    /// global correction.
    private static func fit(field: SpatialField) -> [Double] {
        let n=field.columns*field.rows
        var solution=[Double](repeating:0,count:n)
        for iteration in 0..<3 {
            var matrix=[Double](repeating:0,count:n*n), rhs=[Double](repeating:0,count:n)
            func add(_ terms:[(Int,Double)], _ weight:Double, _ target:Double) {
                for (a,wa) in terms {
                    rhs[a] += weight*wa*target
                    for (b,wb) in terms { matrix[a*n+b] += weight*wa*wb }
                }
            }
            for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
                let p=r*field.sampleColumns+c
                guard field.confidence[p]>0 else { continue }
                let basis = sampleBasis[p]
                let prediction=basis.reduce(0) { $0+solution[$1.0]*$1.1 }
                let error=abs(prediction-field.requested[p])
                let robust=iteration==0 ? 1 : min(1,0.20/max(0.0001,error))
                add(basis,field.confidence[p]*robust,field.requested[p])
            } }
            for y in 0..<field.rows { for x in 0..<field.columns {
                let p=y*field.columns+x
                add([(p,1)],0.002,0)
                if x>0 && x<field.columns-1 { add([(p-1,1),(p,-2),(p+1,1)],0.08,0) }
                if y>0 && y<field.rows-1 { add([(p-field.columns,1),(p,-2),(p+field.columns,1)],0.08,0) }
            } }
            // Cholesky solve; positive priors make the system definite.
            var lower=[Double](repeating:0,count:n*n)
            for i in 0..<n { for j in 0...i {
                var value=matrix[i*n+j]
                for k in 0..<j { value -= lower[i*n+k]*lower[j*n+k] }
                lower[i*n+j] = i==j ? sqrt(max(0.000001,value)) : value/lower[j*n+j]
            } }
            var temp=[Double](repeating:0,count:n)
            for i in 0..<n { var value=rhs[i];for j in 0..<i { value -= lower[i*n+j]*temp[j] };temp[i]=value/lower[i*n+i] }
            for i in stride(from:n-1,through:0,by:-1) { var value=temp[i];if i+1<n { for j in (i+1)..<n { value -= lower[j*n+i]*solution[j] } };solution[i]=value/lower[i*n+i] }
        }
        return solution
    }
}
