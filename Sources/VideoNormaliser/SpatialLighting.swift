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
        init(_ t: SpatialThumbnail) {
            thumb = t; luminance = t.light
            log = luminance.map { log2(max(0.001, $0)) }
            red = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
            green = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i+1]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
        }
    }

    static func estimate(samples: [ExposureSample], global: [Double], radius: Double, strength: Double,
                         region: CGRect? = nil) -> [SpatialField] {
        guard samples.count == global.count, samples.allSatisfy({ $0.thumbnail != nil }), strength > 0 else {
            return samples.map { _ in SpatialField() }
        }
        let frames = samples.map { Frame($0.thumbnail!) }
        let w = frames[0].thumb.width, h = frames[0].thumb.height
        guard w >= 24, h >= 20, frames.allSatisfy({ $0.thumb.width == w && $0.thumb.height == h }) else {
            return samples.map { _ in SpatialField() }
        }
        var result: [SpatialField] = []
        for i in samples.indices {
            var field = SpatialField()
            let neighbours = samples.indices.filter { $0 != i && samples[$0].segment == samples[i].segment && abs(samples[$0].time - samples[i].time) <= max(0.25, radius) + 0.000001 }
                .sorted { abs($0-i) < abs($1-i) }.prefix(6)
            for j in neighbours {
                let shift = register(frames[i], frames[j])
                field.alignments.append(SpatialAlignment(reference: j, dx: shift.dx, dy: shift.dy, error: shift.error, accepted: shift.accepted))
            }
            let accepted = field.alignments.filter(\.accepted)
            guard accepted.count >= 2 else {
                field.fallback = "Too few aligned neighbouring frames"
                result.append(field); continue
            }
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                let index = row * field.sampleColumns + col
                let nx = (Double(col) + 0.5) / Double(field.sampleColumns)
                let ny = (Double(row) + 0.5) / Double(field.sampleRows)
                if let region, !region.contains(CGPoint(x: nx, y: ny)) { continue }
                let x = min(w-3, max(2, Int(nx * Double(w))))
                let y = min(h-3, max(2, Int(ny * Double(h))))
                var targets: [Double] = [], weights: [Double] = []
                let current = frames[i].luminance[y*w+x]
                field.before[index] = current
                for alignment in accepted {
                    let j = alignment.reference
                    let match = compare(frames[i], frames[j], x: x, y: y, dx: alignment.dx, dy: alignment.dy)
                    if match.confidence > 0 {
                        targets.append(match.delta + global[j] - global[i])
                        weights.append(match.confidence)
                    }
                }
                let fraction = Double(targets.count) / Double(accepted.count)
                field.motion[index] = 1 - fraction
                guard targets.count >= 2, fraction >= 0.5 else { continue }
                let residual = ExposureMath.median(targets)
                // References are robust in time; gains themselves are not time
                // smoothed. An isolated flash is corrected on its own frame.
                let dispersion = ExposureMath.median(targets.map { abs($0-residual) })
                let confidence = ExposureMath.median(weights) * fraction * max(0, 1-dispersion/0.18)
                guard confidence > 0.25 else { continue }
                field.confidence[index] = confidence
                field.requested[index] = max(-0.75, min(0.75, residual))
                field.reference[index] = current * pow(2, global[i] + residual)
            } }
            // Remove samples adjacent to strong motion/occlusion. Never create
            // a subject-shaped correction edge: the fitted field stays coarse.
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
                if movingNeighbours > 0 { field.confidence[index] *= 0.4 }
            } }
            guard field.confidence.filter({ $0 > 0.25 }).count >= 18 else {
                field.fallback = "Insufficient unoccluded background support"
                result.append(field); continue
            }
            field.stops = fit(field: field).map { max(-0.6, min(0.6, $0)) * strength }
            // Fade unsupported portions smoothly towards global correction.
            // Do not extrapolate a large gain into an occluded/clipped corner.
            for y in 0..<field.rows { for x in 0..<field.columns {
                let nx = Double(x)/Double(field.columns-1), ny = Double(y)/Double(field.rows-1)
                var support=0.0, total=0.0
                for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
                    let dx = (Double(c)+0.5)/Double(field.sampleColumns)-nx
                    let dy = (Double(r)+0.5)/Double(field.sampleRows)-ny
                    let weight=exp(-0.5*(pow(dx/0.12,2)+pow(dy/0.16,2)))
                    support += weight*field.confidence[r*field.sampleColumns+c]; total += weight
                } }
                field.stops[y*field.columns+x] *= min(1, support/max(0.00001,total)/0.20)
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

    /// Bounded translation registration on log-luminance gradients. Large
    /// motion, parallax or rotation that fails this test falls back safely.
    private static func register(_ a: Frame, _ b: Frame) -> (dx: Int, dy: Int, error: Double, accepted: Bool) {
        let w = a.thumb.width, h = a.thumb.height
        func cost(_ dx: Int, _ dy: Int) -> Double {
            var sum = 0.0, count = 0
            for y in stride(from: 4, to: h-4, by: 3) { for x in stride(from: 4, to: w-4, by: 3) {
                let xx=x+dx, yy=y+dy
                guard xx>1, xx<w-2, yy>1, yy<h-2 else { continue }
                let p=y*w+x, q=yy*w+xx
                guard a.luminance[p]>0.02, b.luminance[q]>0.02 else { continue }
                let gx=a.log[p+1]-a.log[p-1], gy=a.log[p+w]-a.log[p-w]
                guard abs(gx)+abs(gy)>0.03 else { continue }
                let residual=abs(gx-(b.log[q+1]-b.log[q-1]))+abs(gy-(b.log[q+w]-b.log[q-w]))
                sum += min(0.3,residual); count += 1
            } }
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

    private static func compare(_ a: Frame, _ b: Frame, x: Int, y: Int, dx: Int, dy: Int) -> (delta: Double, confidence: Double) {
        let w=a.thumb.width,h=a.thumb.height
        guard x+dx>=2, x+dx<w-2, y+dy>=2, y+dy<h-2 else { return (0,0) }
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
        guard ratios.count>=18 else { return (0,0) }
        let delta=ExposureMath.median(ratios)
        let residual=ExposureMath.median(ratios.map { abs($0-delta) })
        let colour=ExposureMath.median(colours)
        guard residual<0.10,colour<0.055 else { return (delta,0) }
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
        guard support >= 18, source > 0 else { return (delta, 0) }
        return (log2(target/source),max(0,1-residual/0.12)*max(0,1-colour/0.065))
    }

    /// Robust weighted least squares with a bending penalty and a weak zero
    /// prior. Unsupported cells relax towards global correction.
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
                let basis=SpatialField.basis(x:(Double(c)+0.5)/Double(field.sampleColumns),y:(Double(r)+0.5)/Double(field.sampleRows),columns:field.columns,rows:field.rows)
                let prediction=basis.reduce(0) { $0+solution[$1.0]*$1.1 }
                let error=abs(prediction-field.requested[p])
                let robust=iteration==0 ? 1 : min(1,0.08/max(0.0001,error))
                add(basis,field.confidence[p]*robust,field.requested[p])
            } }
            for y in 0..<field.rows { for x in 0..<field.columns {
                let p=y*field.columns+x
                add([(p,1)],0.015,0)
                if x>0 && x<field.columns-1 { add([(p-1,1),(p,-2),(p+1,1)],0.4,0) }
                if y>0 && y<field.rows-1 { add([(p-field.columns,1),(p,-2),(p+field.columns,1)],0.4,0) }
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
