import Foundation

/// Experimental source-only lighting component for ONE scene. Frame indices are
/// local to `times`. No images, corrected pixels, clean targets or manual EV enter
/// estimation. Calibration is a separate operation on automatic rendered gains.
enum CommonIlluminationComponent {
    static func pulseErrorWithinBudget(proposed: Double,current: Double,initial: Double,allowance: Double) -> Bool {
        guard proposed.isFinite,current.isFinite,initial.isFinite,allowance.isFinite,allowance >= 0 else { return false }
        return abs(proposed) <= abs(current)+allowance && abs(proposed) <= abs(initial)+allowance
    }
    /// Largest common step that keeps every accumulated increment inside its
    /// original correction budget. Scaling the whole proposal preserves its
    /// spatial shape rather than clipping individual channels or patches.
    static func boundedRefinementScale(current: [Double], proposed: [Double], limit: Double) -> Double? {
        guard current.count == proposed.count, limit.isFinite, limit >= 0 else { return nil }
        var scale = 1.0
        for (old,new) in zip(current,proposed) {
            guard old.isFinite,new.isFinite,abs(old) <= limit+1e-7 else { return nil }
            let delta = new-old
            if delta > 0 { scale = min(scale,max(0,(limit-old)/delta)) }
            if delta < 0 { scale = min(scale,max(0,(-limit-old)/delta)) }
        }
        return scale
    }
    struct Observation: Sendable {
        let frame: Int
        let x: Int
        let y: Int
        let level: Double
    }

    struct Track: Sendable {
        let observations: [Observation]
    }

    struct Configuration: Sendable {
        var radius: Double
        var mode: NormalisationMode
        var minimumDonors = 12
        var quietFloor = 0.005
        var excitation = 0.03
        var agreement = 0.015
        var requireIndependentEvents = true
        /// Experimental: fit only within a wholly supported contiguous run.
        var allowSupportedRuns = false
    }

    enum State: Sendable, Equatable {
        case quiet, supported, absent, unknown
    }

    struct SourceEstimate: Sendable {
        let state: State
        let coefficient: Double?
        let frames: [Int]
        let times: [Double]
        /// H(phi)-phi, aligned with this track's observations.
        let q: [Double]
        let independentlyValidated: Bool
        // Source-defined folds are frozen before automatic gain is observed.
        let temporalFolds: [[Int]]
        let eventFolds: [[Int]]
    }

    struct GainCalibration: Sendable {
        let delta: [Double]
        let renderedCoefficient: Double
        let globalCoefficient: Double
        let independentlyValidated: Bool
    }

    /// Additional automatic gain curvature, after measuring the gain already
    /// rendered on this source patch. Inputs exclude manual EV. A source pulse
    /// must have independent geometry and donor validation before calling this.
    /// Missing measurements remain unknown; excessive requests are rejected.
    static func pulseAdditionalCurvature(sourceExcursion: Double?,
                                         automaticGain: Double?, globalGain: Double?,
                                         strength: Double, spatial: Double) -> Double? {
        guard strength.isFinite, spatial.isFinite,
              (0...1).contains(strength), (0...1).contains(spatial) else { return nil }
        // Disabled controls must be exact bypasses, even with absent evidence.
        guard strength > 0, spatial > 0 else { return 0 }
        guard let sourceExcursion, let automaticGain, let globalGain,
              sourceExcursion.isFinite, automaticGain.isFinite, globalGain.isFinite else { return nil }
        // Global gain already includes Strength. Scale only the desired local
        // source response, never the previously applied global gain again.
        let desired = (1-spatial)*globalGain-spatial*strength*sourceExcursion
        let additional = desired-automaticGain
        guard additional.isFinite, abs(additional) <= 0.25*strength*spatial else { return nil }
        return additional
    }

    struct Response: Sendable {
        let coefficient: Double
        /// Linear drift in EV/second, independently fitted using actual time.
        let drift: Double
        let heldErrorRMS: Double
        let absent: Bool
    }

    enum EdgeRejection: String, Sendable, Equatable {
        case insufficientQuorum
        case opposingSigns
        case weakSpatialHalf
    }

    struct EdgeDiagnostic: Sendable {
        let frame: Int
        /// Qualified candidate pairs before disjoint-footprint selection.
        let candidateCount: Int
        let independentCount: Int
        let left: Double?
        let right: Double?
        let median: Double?
        let rejection: EdgeRejection?
    }

    struct PulsePixelEvidence: Sendable {
        let channelExcursion: [Double]
        let heldError: Double
        let rejection: String?
    }

    /// Source-only, three-frame log-RGB excursion on a transported odd-sized patch.
    /// Spatial folds test uniform photometric response; they are NOT independent
    /// material donors. Geometry and external donor quorum are separate gates.
    static func pulsePixels(before: [Double], middle: [Double], after: [Double],
                            alpha: Double, tolerance: Double = 0.02, side: Int = 5) -> PulsePixelEvidence {
        func rejected(_ reason: String) -> PulsePixelEvidence {
            .init(channelExcursion: [], heldError: 0, rejection: reason)
        }
        guard (5...13).contains(side), side%2 == 1,
              before.count == side*side*3, middle.count == side*side*3, after.count == side*side*3,
              alpha.isFinite, alpha > 0, alpha < 1, tolerance.isFinite, tolerance > 0 else {
            return rejected("invalidShapeOrTime")
        }
        // A clipped or near-black channel cannot certify logarithmic exposure.
        guard [before,middle,after].allSatisfy({ $0.allSatisfy { $0.isFinite && $0 > 0.005 && $0 < 0.95 } }) else {
            return rejected("clippingOrDarkChannel")
        }
        let residuals = (0..<side*side*3).map { log2(middle[$0])-(1-alpha)*log2(before[$0])-alpha*log2(after[$0]) }
        // Leave the centre row/column out of reciprocal contiguous-block tests.
        // This avoids interleaving adjacent samples as purported held evidence.
        let pixels = (0..<side*side).filter { $0%side != side/2 && $0/side != side/2 }
        let folds = [pixels.filter { $0/side < side/2 }, pixels.filter { $0/side > side/2 },
                     pixels.filter { $0%side < side/2 }, pixels.filter { $0%side > side/2 }]
        let coefficients = (0..<3).map { channel in ExposureMath.median(pixels.map { residuals[$0*3+channel] }) }
        var heldError = 0.0
        for (index,training) in folds.enumerated() {
            let held = folds[index ^ 1]
            for channel in 0..<3 {
                let coefficient = ExposureMath.median(training.map { residuals[$0*3+channel] })
                let error = sqrt(held.reduce(0.0) { $0+pow(residuals[$1*3+channel]-coefficient,2) }/Double(held.count))
                heldError = max(heldError,error)
                let heldCoefficient = ExposureMath.median(held.map { residuals[$0*3+channel] })
                guard error <= tolerance, abs(heldCoefficient-coefficient) <= tolerance else {
                    return .init(channelExcursion: coefficients, heldError: heldError,rejection: "nonuniformHeldResponse")
                }
            }
        }
        for channel in 0..<3 {
            let fullError = sqrt((0..<side*side).reduce(0.0) { $0+pow(residuals[$1*3+channel]-coefficients[channel],2) }/Double(side*side))
            heldError = max(heldError,fullError)
            if fullError > tolerance {
                return .init(channelExcursion: coefficients,heldError: heldError,rejection: "nonuniformInteriorResponse")
            }
        }
        return .init(channelExcursion: coefficients,heldError: heldError,rejection: nil)
    }

    /// Measure a two-frame RGB response on an already corresponding footprint.
    /// The repeated reference makes the residual log(after / before), sharing
    /// the reciprocal spatial holdout checks of pulsePixels. This is evidence
    /// of a uniform response, not proof of lighting or a correction target.
    static func stepPixels(before: [Double], after: [Double],
                           tolerance: Double = 0.04, side: Int = 5) -> PulsePixelEvidence {
        pulsePixels(before: before, middle: after, after: before,
                    alpha: 0.5, tolerance: tolerance, side: side)
    }

    struct ObservablePulseEvidence: Sendable {
        let channelExcursion: [Double?]
        let minimumMeasuredLuminanceCoverage: Double
        let representativeExcursion: Double?
        let heldError: Double
        let rejection: String?
    }

    /// Partial spectral evidence only. Unresolved channels stay nil; coverage
    /// describes measured radiance, not an assumed bound on hidden illumination.
    static func pulseObservableRGB(before: [Double],middle: [Double],after: [Double],
                                    alpha: Double,tolerance: Double = 0.04) -> ObservablePulseEvidence {
        func rejected(_ reason: String) -> ObservablePulseEvidence {
            .init(channelExcursion:[nil,nil,nil],minimumMeasuredLuminanceCoverage:0,representativeExcursion:nil,heldError:0,rejection:reason)
        }
        guard alpha.isFinite,alpha > 0,alpha < 1,tolerance.isFinite,tolerance > 0,
              [before,middle,after].allSatisfy({ $0.count == 75 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else {
            return rejected("invalidObservableRGB")
        }
        let pixels = (0..<25).filter { $0%5 != 2 && $0/5 != 2 }
        let folds = [pixels.filter { $0/5 < 2 },pixels.filter { $0/5 > 2 },pixels.filter { $0%5 < 2 },pixels.filter { $0%5 > 2 }]
        var gains = [Double?](repeating:nil,count:3),heldError = 0.0
        for channel in 0..<3 {
            let valid = Set((0..<25).filter { p in [before,middle,after].allSatisfy { $0[p*3+channel] > 0.005 } })
            let supported = folds.map { $0.filter { valid.contains($0) } }
            guard supported.allSatisfy({ $0.count >= 4 }) else { continue }
            func excursion(_ p: Int) -> Double {
                let i=p*3+channel
                return log2(middle[i])-(1-alpha)*log2(before[i])-alpha*log2(after[i])
            }
            for i in supported.indices {
                let coefficient = ExposureMath.median(supported[i].map(excursion)),held = supported[i ^ 1]
                let error = sqrt(held.reduce(0) { $0+pow(excursion($1)-coefficient,2) }/Double(held.count))
                heldError = max(heldError,error)
                guard error <= tolerance,abs(ExposureMath.median(held.map(excursion))-coefficient) <= tolerance else {
                    return rejected("nonuniformObservableChannel")
                }
            }
            gains[channel] = ExposureMath.median(pixels.filter { valid.contains($0) }.map(excursion))
        }
        guard gains.contains(where:{ $0 != nil }) else { return rejected("noObservableChannel") }
        let weights = [0.2126,0.7152,0.0722]
        var coverage = 1.0,referenceTotal = 0.0,middleTotal = 0.0,errors = [Double]()
        for pixel in 0..<25 {
            for rgb in [before,middle,after] {
                let total = (0..<3).reduce(0) { $0+weights[$1]*rgb[pixel*3+$1] }
                let known = (0..<3).filter { gains[$0] != nil }.reduce(0) { $0+weights[$1]*rgb[pixel*3+$1] }
                guard total > 0.005 else { return rejected("darkObservableLuminance") }
                coverage = min(coverage,known/total)
            }
            var reference = 0.0,observed = 0.0,predicted = 0.0
            for channel in 0..<3 {
                guard let gain = gains[channel] else { continue }
                let i=pixel*3+channel,value = pow(before[i],1-alpha)*pow(after[i],alpha)*weights[channel]
                reference += value;predicted += value*pow(2,gain);observed += middle[i]*weights[channel]
            }
            guard reference > 0,predicted > 0,observed > 0 else { return rejected("unobservableInterior") }
            errors.append(abs(log2(observed/predicted)))
            referenceTotal += reference;middleTotal += observed
        }
        guard coverage >= 0.98 else { return rejected("insufficientMeasuredLuminanceCoverage") }
        let fullError = sqrt(errors.reduce(0) { $0+$1*$1 }/25)
        heldError = max(heldError,fullError)
        guard fullError <= tolerance,errors.max()! <= 2*tolerance else { return rejected("nonuniformObservableInterior") }
        return .init(channelExcursion:gains,minimumMeasuredLuminanceCoverage:coverage,
                     representativeExcursion:log2(middleTotal/referenceTotal),heldError:heldError,rejection:nil)
    }

    /// Exposure-only counterpart. Dark individual colour channels do not make
    /// a well-exposed luminance measurement unobservable. This certifies only a
    /// neutral EV excursion, never channel-specific colour correction.
    static func pulseLuminancePixels(before: [Double], middle: [Double], after: [Double],
                                     alpha: Double, tolerance: Double = 0.02, side: Int = 5) -> PulsePixelEvidence {
        guard (5...13).contains(side),side%2 == 1,
              [before,middle,after].allSatisfy({ $0.count == side*side*3 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else {
            return .init(channelExcursion: [],heldError: 0,rejection: "invalidOrClippedRGB")
        }
        func luminanceRGB(_ rgb: [Double]) -> [Double] {
            (0..<side*side).flatMap { pixel in
                let y = 0.2126*rgb[pixel*3]+0.7152*rgb[pixel*3+1]+0.0722*rgb[pixel*3+2]
                return [y,y,y]
            }
        }
        return pulsePixels(before: luminanceRGB(before),middle: luminanceRGB(middle),
            after: luminanceRGB(after),alpha: alpha,tolerance: tolerance,side: side)
    }

    /// A deterministic significance floor, not a confidence probability.
    /// Preserve the current automatic gain when a proposed additional gain is
    /// smaller than the source held-pixel error and measurement floor.
    static func significantPulseDelta(_ delta: Double,heldError: Double,strength: Double,spatial: Double,
                                      minimumEV: Double = 0.003) -> Double? {
        guard delta.isFinite,heldError.isFinite,heldError >= 0,strength.isFinite,spatial.isFinite,
              (0...1).contains(strength),(0...1).contains(spatial),minimumEV.isFinite,minimumEV >= 0 else { return nil }
        let amount = strength*spatial
        guard amount > 0 else { return 0 }
        return abs(delta) <= max(minimumEV,2*heldError)*amount ? 0 : delta
    }

    struct MaskedPulseEvidence: Sendable {
        let excursion: Double?
        let validPixels: [Int]
        let heldError: Double
        let rejection: String?
    }

    /// Source-selected unclipped pixels only. This describes the observed subset,
    /// never the hidden response of excluded pixels or an authorized correction.
    static func pulseMaskedLuminancePixels(before: [Double], middle: [Double], after: [Double],
                                            alpha: Double, tolerance: Double = 0.02, side: Int = 5) -> MaskedPulseEvidence {
        func rejected(_ reason: String, pixels: [Int] = [], error: Double = 0) -> MaskedPulseEvidence {
            .init(excursion:nil,validPixels:pixels,heldError:error,rejection:reason)
        }
        guard (3...13).contains(side),side%2 == 1,alpha.isFinite,alpha > 0,alpha < 1,
              tolerance.isFinite,tolerance > 0,
              [before,middle,after].allSatisfy({ $0.count == side*side*3 && $0.allSatisfy { $0.isFinite } }) else {
            return rejected("invalidMaskedShapeTimeOrRGB")
        }
        func light(_ rgb: [Double], _ pixel: Int) -> Double {
            0.2126*rgb[pixel*3]+0.7152*rgb[pixel*3+1]+0.0722*rgb[pixel*3+2]
        }
        let pixels = (0..<side*side).filter { pixel in
            [before,middle,after].allSatisfy { rgb in
                (0..<3).allSatisfy({ rgb[pixel*3+$0] >= 0 && rgb[pixel*3+$0] < 0.95 }) && light(rgb,pixel) > 0.005
            }
        }
        guard pixels.count >= (side == 3 ? 9 : Int(ceil(0.8*Double(side*side)))) else { return rejected("insufficientMaskedCoverage",pixels:pixels) }
        let valid = Set(pixels),half = side/2
        let eligible = (0..<side*side).filter { $0%side != half && $0/side != half }
        let fullFolds = [eligible.filter { $0/side < half },eligible.filter { $0/side > half },
                         eligible.filter { $0%side < half },eligible.filter { $0%side > half }]
        let folds = fullFolds.map { $0.filter { valid.contains($0) } }
        guard zip(folds,fullFolds).allSatisfy({ $0.count >= max(side == 3 ? 2 : 3,Int(ceil(0.6*Double($1.count)))) }) else {
            return rejected("insufficientMaskedHeldCoverage",pixels:pixels)
        }
        let tolerance = side == 3 ? min(tolerance,0.02) : tolerance
        let residual = Dictionary(uniqueKeysWithValues:pixels.map { pixel in
            (pixel,log2(light(middle,pixel))-(1-alpha)*log2(light(before,pixel))-alpha*log2(light(after,pixel)))
        })
        let coefficient = ExposureMath.median(eligible.filter { valid.contains($0) }.map { residual[$0]! })
        var heldError = 0.0
        for (i,training) in folds.enumerated() {
            let fit = ExposureMath.median(training.map { residual[$0]! }),held = folds[i ^ 1]
            let error = sqrt(held.reduce(0.0) { $0+pow(residual[$1]!-fit,2) }/Double(held.count))
            heldError = max(heldError,error)
            guard error <= tolerance,abs(ExposureMath.median(held.map { residual[$0]! })-fit) <= tolerance else {
                return rejected("nonuniformMaskedHeldResponse",pixels:pixels,error:heldError)
            }
        }
        let errors = pixels.map { abs(residual[$0]!-coefficient) }
        // Full valid interior includes the center omitted from training folds.
        let fullError = sqrt(errors.reduce(0) { $0+$1*$1 }/Double(errors.count))
        heldError = max(heldError,fullError)
        guard fullError <= tolerance,errors.max()! <= 2*tolerance else {
            return rejected("nonuniformMaskedInteriorResponse",pixels:pixels,error:heldError)
        }
        return .init(excursion:coefficient,validPixels:pixels,heldError:heldError,rejection:nil)
    }

    struct KernelPulseEvidence: Sendable {
        let excursion: Double?
        let heldError: Double
        let rejection: String?
        /// Index into each transported 11×11 raster, retaining repeated taps.
        let tapIndices: [Int]
        let tapWeights: [Double]
        /// Indices into flattened taps, restricted to observable features.
        let validTapIndices: [Int]
    }

    /// Finite positive kernel on a transported 11×11 raster. All kernel taps
    /// retain their actual source coordinates. Held folds must have disjoint
    /// original integer-pixel support in every frame, including bilinear taps.
    /// No clipped/negative source tap can be made observable by averaging.
    static func pulseKernelLuminancePixels(before: [Double],middle: [Double],after: [Double],
        footprints: [[(x:Double,y:Double)]],width: Int,height: Int,
        alpha: Double,tolerance: Double = 0.04) -> KernelPulseEvidence {
        func reject(_ reason: String,_ error: Double = 0) -> KernelPulseEvidence {
            .init(excursion:nil,heldError:error,rejection:reason,tapIndices:[],tapWeights:[],validTapIndices:[])
        }
        let images = [before,middle,after]
        guard width >= 2,height >= 2,footprints.count == 3,
              footprints.allSatisfy({ $0.count == 121 }),
              images.allSatisfy({ $0.count == 363 && $0.allSatisfy(\.isFinite) }) else { return reject("invalidKernelShapeOrRGB") }
        var features = [[Int]](),indices = [Int](),weights = [Double]()
        let kernel = [1.0,2.0,1.0]
        for y in stride(from:1,through:9,by:2) { for x in stride(from:1,through:9,by:2) {
            var feature = [Int]()
            for dy in -1...1 { for dx in -1...1 {
                let tap = (y+dy)*11+x+dx
                feature.append(tap);indices.append(tap)
                weights.append(kernel[dy+1]*kernel[dx+1]/16)
            } }
            features.append(feature)
        } }
        var support = Array(repeating:Array(repeating:Set<Int>(),count:25),count:3)
        for frame in 0..<3 { for feature in 0..<25 { for tap in features[feature] {
            let p = footprints[frame][tap]
            guard p.x.isFinite,p.y.isFinite,p.x >= 0,p.y >= 0,
                  p.x < Double(width-1),p.y < Double(height-1) else { return reject("kernelOutsideImage") }
            let x = Int(floor(p.x)),y = Int(floor(p.y)),fx = p.x-Double(x),fy = p.y-Double(y)
            for (dx,dy,w) in [(0,0,(1-fx)*(1-fy)),(1,0,fx*(1-fy)),(0,1,(1-fx)*fy),(1,1,fx*fy)] where w > 0 {
                support[frame][feature].insert((y+dy)*width+x+dx)
            }
        } } }
        var filtered = Array(repeating:[Double](),count:3)
        for feature in 0..<25 {
            let observable = images.allSatisfy { rgb in features[feature].allSatisfy { tap in
                (0..<3).allSatisfy { rgb[tap*3+$0] >= 0 && rgb[tap*3+$0] < 0.95 }
            } }
            for frame in 0..<3 {
                for c in 0..<3 {
                    filtered[frame].append(observable ? features[feature].enumerated().reduce(0.0) {
                        $0+images[frame][$1.element*3+c]*weights[feature*9+$1.offset]
                    } : -1)
                }
            }
        }
        let evidence = pulseMaskedLuminancePixels(before:filtered[0],middle:filtered[1],after:filtered[2],alpha:alpha,tolerance:tolerance)
        guard let median = evidence.excursion else { return reject(evidence.rejection ?? "unknownKernelRejection",evidence.heldError) }
        let valid = Set(evidence.validPixels)
        let eligible = (0..<25).filter { $0%5 != 2 && $0/5 != 2 && valid.contains($0) }
        let folds = [eligible.filter { $0/5 < 2 },eligible.filter { $0/5 > 2 },
                     eligible.filter { $0%5 < 2 },eligible.filter { $0%5 > 2 }]
        for frame in 0..<3 { for pair in [0,2] {
            let a = folds[pair].reduce(into:Set<Int>()) { $0.formUnion(support[frame][$1]) }
            let b = folds[pair+1].reduce(into:Set<Int>()) { $0.formUnion(support[frame][$1]) }
            guard a.isDisjoint(with:b) else { return reject("overlappingKernelHeldSupport",evidence.heldError) }
        } }
        let light = filtered.map { rgb in evidence.validPixels.reduce(0.0) { total,p in
            total+0.2126*rgb[p*3]+0.7152*rgb[p*3+1]+0.0722*rgb[p*3+2]
        } }
        let excursion = log2(light[1])-(1-alpha)*log2(light[0])-alpha*log2(light[2])
        guard excursion.isFinite,abs(excursion-median) <= tolerance else { return reject("inconsistentKernelAggregate",evidence.heldError) }
        return .init(excursion:excursion,heldError:max(evidence.heldError,abs(excursion-median)),rejection:nil,
            tapIndices:indices,tapWeights:weights,validTapIndices:evidence.validPixels.flatMap { feature in Array(feature*9..<feature*9+9) })
    }

    /// Smooth regions have no local correspondence evidence. A caller must
    /// independently establish a stationary camera and an external donor clock.
    /// This only qualifies source photometry; it never establishes that clock.
    static func pulseLowTextureLuminancePixels(before: [Double],middle: [Double],after: [Double],
        alpha: Double,tolerance: Double = 0.04,stationaryCameraSupported: Bool,allowColourChange: Bool = false) -> MaskedPulseEvidence {
        func reject(_ reason: String) -> MaskedPulseEvidence { .init(excursion:nil,validPixels:[],heldError:0,rejection:reason) }
        guard stationaryCameraSupported else { return reject("unsupportedStationaryCamera") }
        guard alpha.isFinite,alpha > 0,alpha < 1,tolerance.isFinite,tolerance > 0 else { return reject("invalidLowTextureTimeOrTolerance") }
        let images = [before,middle,after]
        guard images.allSatisfy({ $0.count == 507 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else { return reject("invalidLowTextureSupport") }
        var means = [[Double]]()
        for rgb in images {
            let mean = (0..<3).map { c in stride(from:c,to:rgb.count,by:3).reduce(0.0) { $0+rgb[$1] }/169 }
            means.append(mean)
            for c in 0..<3 where mean[c] > 0.005 {
                let values = stride(from:c,to:rgb.count,by:3).map { log2(max(0.003,rgb[$0])) }
                let average = values.reduce(0,+)/169
                let energy = sqrt(values.reduce(0.0) { $0+pow($1-average,2) }/169)
                guard energy <= 0.03 else { return reject("texturedOrOccludedRegion") }
            }
        }
        let light = means.map { $0[0]*0.2126+$0[1]*0.7152+$0[2]*0.0722 }
        guard light.allSatisfy({ $0 > 0.005 }) else { return reject("darkLowTextureRegion") }
        for c in 0..<3 where means.allSatisfy({ $0[c] > 0.005 }) {
            let chroma = (0..<3).map { log2(means[$0][c]/light[$0]) }
            guard allowColourChange || chroma.max()!-chroma.min()! <= tolerance else { return reject("changedLowTextureMaterialOrColour") }
        }
        var patches: [[Double]] = []
        for rgb in images {
            var patch: [Double] = []
            for dy in -2...2 { for dx in -2...2 {
                let p = ((6+dy)*13+6+dx)*3
                for c in 0..<3 { patch.append(rgb[p+c]) }
            } }
            patches.append(patch)
        }
        let evidence = pulseMaskedLuminancePixels(before:patches[0],middle:patches[1],after:patches[2],alpha:alpha,tolerance:tolerance)
        guard let median = evidence.excursion else { return evidence }
        var totals: [Double] = []
        for rgb in patches {
            var total = 0.0
            for pixel in evidence.validPixels {
                let p = pixel*3
                total += rgb[p]*0.2126+rgb[p+1]*0.7152+rgb[p+2]*0.0722
            }
            totals.append(total)
        }
        let excursion = log2(totals[1])-(1-alpha)*log2(totals[0])-alpha*log2(totals[2])
        guard excursion.isFinite,abs(excursion-median) <= tolerance else { return reject("inconsistentLowTextureAggregate") }
        return .init(excursion:excursion,validPixels:evidence.validPixels,heldError:max(evidence.heldError,abs(excursion-median)),rejection:nil)
    }

    /// Independent tracked donors must support every measured query channel.
    /// Missing/dark channels are never supplied by another channel or a prior.
    static func pulseColourCorroborates(query: ObservablePulseEvidence,donors: [ObservablePulseEvidence],
        minimumDonors: Int = 4,tolerance: Double = 0.04) -> Bool {
        guard query.rejection == nil,query.channelExcursion.count == 3,
              query.minimumMeasuredLuminanceCoverage >= 0.98,query.heldError.isFinite,query.heldError >= 0,minimumDonors >= 4,
              tolerance.isFinite,tolerance > 0 else { return false }
        var measured = 0
        for channel in 0..<3 {
            guard let value = query.channelExcursion[channel],value.isFinite else { continue }
            measured += 1
            let supported = donors.filter { $0.rejection == nil && $0.minimumMeasuredLuminanceCoverage >= 0.98 && $0.channelExcursion.count == 3 && $0.channelExcursion[channel] != nil }
            guard supported.count >= minimumDonors else { return false }
            let clock = pulseClock(excursions:supported.map { $0.channelExcursion[channel]! },errors:supported.map(\.heldError),minimumDonors:minimumDonors)
            guard let event = clock.excursion else { return false }
            if clock.state == .quiet {
                guard abs(value)+2*query.heldError <= 0.01 else { return false }
            } else {
                guard clock.state == .event,abs(value-event) <= tolerance else { return false }
            }
        }
        return measured > 0
    }

    struct SpectralPulseEvidence: Sendable {
        let gains: [Double]?
        let pixelExcursion: [Double]
        let representativeExcursion: Double?
        let heldError: Double
        let rejection: String?
        var identifiableRank: Int? = nil
        var maximumPredictionUncertaintyEV: Double = 0
    }

    private struct SupportedSpectralModel {
        let coefficients: [Double]
        let nullDirections: [[Double]]
        let rank: Int
    }

    /// A neutral anchor selects one coefficient vector; only predictions whose
    /// uncertainty is bounded over the supported gain box may be used. The
    /// anchor is not evidence for unobservable channel gains.
    private static func supportedSpectralModel(x: [[Double]],y: [Double],pixels: [Int]) -> SupportedSpectralModel? {
        var matrix = Array(repeating:Array(repeating:0.0,count:3),count:3)
        var rhs = Array(repeating:0.0,count:3)
        for p in pixels {
            let residual = y[p]-x[p].reduce(0,+)
            for c in 0..<3 {
                rhs[c] += x[p][c]*residual
                for d in 0..<3 { matrix[c][d] += x[p][c]*x[p][d] }
            }
        }
        var vectors = [[1.0,0,0],[0,1.0,0],[0,0,1.0]]
        let scale = (0..<3).map { matrix[$0][$0] }.max() ?? 0
        guard scale.isFinite,scale > 1e-10 else { return nil }
        for _ in 0..<32 {
            let pair = [(0,1),(0,2),(1,2)].max { abs(matrix[$0.0][$0.1]) < abs(matrix[$1.0][$1.1]) }!
            let p = pair.0,q = pair.1,off = matrix[p][q]
            if abs(off) <= scale*1e-12 { break }
            let tau = (matrix[q][q]-matrix[p][p])/(2*off)
            let t = (tau >= 0 ? 1.0 : -1.0)/(abs(tau)+sqrt(1+tau*tau))
            let c = 1/sqrt(1+t*t),sn = t*c
            matrix[p][p] -= t*off;matrix[q][q] += t*off
            matrix[p][q] = 0;matrix[q][p] = 0
            for k in 0..<3 where k != p && k != q {
                let a = matrix[k][p],b = matrix[k][q]
                matrix[k][p] = c*a-sn*b;matrix[p][k] = matrix[k][p]
                matrix[k][q] = sn*a+c*b;matrix[q][k] = matrix[k][q]
            }
            for k in 0..<3 {
                let a = vectors[k][p],b = vectors[k][q]
                vectors[k][p] = c*a-sn*b;vectors[k][q] = sn*a+c*b
            }
        }
        let largest = (0..<3).map { matrix[$0][$0] }.max()!
        var coefficients = [1.0,1,1],nullDirections = [[Double]](),rank = 0
        for axis in 0..<3 {
            let direction = (0..<3).map { vectors[$0][axis] },value = matrix[axis][axis]
            if value <= largest*1e-6 { nullDirections.append(direction);continue }
            rank += 1
            let delta = zip(direction,rhs).reduce(0.0) { $0+$1.0*$1.1 }/value
            for c in 0..<3 { coefficients[c] += direction[c]*delta }
        }
        guard rank > 0,coefficients.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }) else { return nil }
        return .init(coefficients:coefficients,nullDirections:nullDirections,rank:rank)
    }

    /// Diagnostic only: source RGB basis predicts luminance on independent
    /// contiguous regions. This model does not establish lighting identity.
    static func pulseSpectralLuminancePixels(before: [Double],middle: [Double],after: [Double],
        alpha: Double,tolerance: Double = 0.04,side: Int = 5,rankAware: Bool = false) -> SpectralPulseEvidence {
        func reject(_ reason: String,_ error: Double = 0) -> SpectralPulseEvidence {
            .init(gains:nil,pixelExcursion:[],representativeExcursion:nil,heldError:error,rejection:reason)
        }
        guard (5...13).contains(side),side%2 == 1,alpha.isFinite,alpha > 0,alpha < 1,
              tolerance.isFinite,tolerance > 0,[before,middle,after].allSatisfy({ $0.count == side*side*3 && $0.allSatisfy { $0.isFinite && (rankAware ? $0 >= 0 : $0 > 0) && $0 < 0.95 } }) else { return reject("invalidSpectralShapeTimeOrRGB") }
        let weights = [0.2126,0.7152,0.0722]
        let x = (0..<side*side).map { p in (0..<3).map { c in weights[c]*pow(before[p*3+c],1-alpha)*pow(after[p*3+c],alpha) } }
        let y = (0..<side*side).map { p in (0..<3).reduce(0.0) { $0+weights[$1]*middle[p*3+$1] } }
        guard x.allSatisfy({ $0.reduce(0,+) > 0.005 }),y.allSatisfy({ $0 > 0.005 }) else { return reject("darkSpectralLuminance") }
        let half = side/2,eligible = (0..<side*side).filter { $0%side != half && $0/side != half }
        let folds = [eligible.filter { $0/side < half },eligible.filter { $0/side > half },eligible.filter { $0%side < half },eligible.filter { $0%side > half }]
        func fit(_ pixels: [Int]) -> SupportedSpectralModel? {
            if rankAware { return supportedSpectralModel(x:x,y:y,pixels:pixels) }
            var matrix = (0..<3).map { c in (0..<3).map { d in pixels.reduce(0.0) { $0+x[$1][c]*x[$1][d] } }+[pixels.reduce(0.0) { $0+x[$1][c]*y[$1] }] }
            let scale = (0..<3).map { matrix[$0][$0] }.max() ?? 0
            guard scale > 1e-10 else { return nil }
            for c in 0..<3 {
                let pivot = (c..<3).max { abs(matrix[$0][c]) < abs(matrix[$1][c]) }!
                matrix.swapAt(c,pivot)
                guard abs(matrix[c][c]) > scale*1e-6 else { return nil }
                let divisor = matrix[c][c]
                for d in c..<4 { matrix[c][d] /= divisor }
                for row in 0..<3 where row != c {
                    let factor = matrix[row][c]
                    for d in c..<4 { matrix[row][d] -= factor*matrix[c][d] }
                }
            }
            let gains = matrix.map { $0[3] }
            return gains.allSatisfy({ $0.isFinite && (0.25...4).contains($0) }) ? .init(coefficients:gains,nullDirections:[],rank:3) : nil
        }
        func prediction(_ model: SupportedSpectralModel) -> [Double] { x.map { zip($0,model.coefficients).reduce(0.0) { $0+$1.0*$1.1 } } }
        func uncertainty(_ model: SupportedSpectralModel,_ predicted: [Double]) -> Double {
            // Any two vectors in the declared [0.25,4]^3 gain box are at
            // most sqrt(3)*3.75 apart. Bound their unobserved predictions.
            x.indices.map { p in
                let projection = sqrt(model.nullDirections.reduce(0.0) { total,v in
                    let dot = zip(x[p],v).reduce(0.0) { $0+$1.0*$1.1 };return total+dot*dot
                })
                let radius = sqrt(3.0)*3.75*projection
                guard predicted[p] > radius else { return Double.infinity }
                return log2((predicted[p]+radius)/(predicted[p]-radius))
            }.max() ?? .infinity
        }
        var predictions = [[Double]](),heldError = 0.0,maximumUncertainty = 0.0
        for (i,training) in folds.enumerated() {
            guard let gains = fit(training) else { return reject("unidentifiableSpectralBasis") }
            let held = folds[i ^ 1],predicted = prediction(gains)
            let uncertaintyEV = uncertainty(gains,predicted)
            maximumUncertainty = max(maximumUncertainty,uncertaintyEV)
            guard uncertaintyEV <= tolerance else { return reject("unsupportedSpectralPrediction",uncertaintyEV.isFinite ? uncertaintyEV : 0) }
            let error = sqrt(held.reduce(0.0) { $0+pow(log2(y[$1]/predicted[$1]),2) }/Double(held.count))
            heldError = max(heldError,error)
            guard error <= tolerance else { return reject("nonuniformHeldSpectralResponse",heldError) }
            predictions.append(predicted)
        }
        let disagreement = x.indices.map { p in
            let values = predictions.map { log2($0[p]) };return values.max()!-values.min()!
        }.max()!
        guard disagreement <= tolerance else { return reject("inconsistentSpectralPredictions",heldError) }
        guard let gains = fit(eligible) else { return reject("unidentifiableSpectralBasis") }
        let predicted = prediction(gains)
        maximumUncertainty = max(maximumUncertainty,uncertainty(gains,predicted))
        guard maximumUncertainty <= tolerance else { return reject("unsupportedSpectralPrediction",maximumUncertainty.isFinite ? maximumUncertainty : 0) }
        let errors = y.indices.map { abs(log2(y[$0]/predicted[$0])) }
        let fullError = sqrt(errors.reduce(0) { $0+$1*$1 }/Double(errors.count));heldError = max(heldError,fullError)
        guard fullError <= tolerance,errors.max()! <= 2*tolerance else { return reject("nonuniformInteriorSpectralResponse",heldError) }
        let excursion = x.indices.map { log2(predicted[$0]/x[$0].reduce(0,+)) }
        return .init(gains:gains.rank == 3 ? gains.coefficients : nil,pixelExcursion:excursion,representativeExcursion:log2(predicted.reduce(0,+)/x.flatMap { $0 }.reduce(0,+)),heldError:heldError,rejection:nil,identifiableRank:gains.rank,maximumPredictionUncertaintyEV:maximumUncertainty)
    }

    struct PulseToneEvidence: Sendable {
        let slope: Double?
        let intercept: Double?
        let pixelExcursion: [Double]
        let representativeExcursion: Double?
        let heldError: Double
        let predictionDisagreement: Double
        let rejection: String?
    }

    /// Diagnostic affine log-luminance response. A fitted contrast change must
    /// not be treated as a spatially uniform EV or an authorized correction.
    static func pulseToneLuminancePixels(before: [Double], middle: [Double], after: [Double],
                                         alpha: Double, tolerance: Double = 0.04, side: Int = 5,
                                         overlapOnly: Bool = false) -> PulseToneEvidence {
        func rejected(_ reason: String, error: Double = 0, disagreement: Double = 0) -> PulseToneEvidence {
            .init(slope: nil,intercept: nil,pixelExcursion: [],representativeExcursion: nil,
                  heldError: error,predictionDisagreement: disagreement,rejection: reason)
        }
        guard (5...13).contains(side), side%2 == 1,
              alpha.isFinite, alpha > 0, alpha < 1, tolerance.isFinite, tolerance > 0,
              [before,middle,after].allSatisfy({ $0.count == side*side*3 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else {
            return rejected("invalidShapeTimeOrRGB")
        }
        func luminance(_ rgb: [Double]) -> [Double] {
            (0..<side*side).map { 0.2126*rgb[$0*3]+0.7152*rgb[$0*3+1]+0.0722*rgb[$0*3+2] }
        }
        let a = luminance(before), b = luminance(middle), c = luminance(after)
        guard [a,b,c].allSatisfy({ $0.allSatisfy { $0 > 0.005 } }) else { return rejected("darkLuminance") }
        let x = (0..<side*side).map { (1-alpha)*log2(a[$0])+alpha*log2(c[$0]) }
        let y = b.map(log2)
        let half = side/2
        let pixels = (0..<side*side).filter { $0%side != half && $0/side != half }
        let folds = [pixels.filter { $0/side < half },pixels.filter { $0/side > half },
                     pixels.filter { $0%side < half },pixels.filter { $0%side > half }]
        var predictions = [[Double]](), heldError = 0.0, validated = Set<Int>()
        for (index,training) in folds.enumerated() {
            let proposedHeld = folds[index ^ 1], tx = training.map { x[$0] }
            guard tx.max()!-tx.min()! >= 0.2 else { return rejected("insufficientToneRange") }
            // A held test outside the training range would test extrapolation,
            // not independently establish a response curve.
            let supported = proposedHeld.filter { x[$0] >= tx.min()!-0.03 && x[$0] <= tx.max()!+0.03 }
            guard overlapOnly || supported.count == proposedHeld.count else {
                return rejected("toneExtrapolation")
            }
            let held = overlapOnly ? supported : proposedHeld
            guard held.count >= max(4,(proposedHeld.count+1)/2),
                  held.map({ x[$0] }).max()!-held.map({ x[$0] }).min()! >= 0.15 else {
                return rejected("insufficientHeldToneSupport")
            }
            validated.formUnion(held)
            guard let model = fit(x: tx,y: training.map { y[$0] },intervals: Array(repeating: 1,count: training.count)),
                  (0.5...2).contains(model.coefficient) else { return rejected("invalidToneSlope") }
            let prediction = x.map { model.drift+model.coefficient*$0 }
            predictions.append(prediction)
            let error = sqrt(held.reduce(0) { $0+pow(y[$1]-prediction[$1],2) }/Double(held.count))
            heldError = max(heldError,error)
            guard error <= tolerance else { return rejected("nonuniformHeldTone",error: heldError) }
        }
        guard validated.count*4 >= pixels.count*3 else { return rejected("insufficientToneCoverage") }
        let disagreement = (0..<side*side).map { pixel in
            predictions.map { $0[pixel] }.max()!-predictions.map { $0[pixel] }.min()!
        }.max()!
        guard disagreement <= tolerance else { return rejected("inconsistentTonePredictions",error: heldError,disagreement: disagreement) }
        guard let model = fit(x: pixels.map { x[$0] },y: pixels.map { y[$0] },intervals: Array(repeating:1,count:pixels.count)),
              (0.5...2).contains(model.coefficient) else { return rejected("invalidToneSlope") }
        let predicted = x.map { model.drift+model.coefficient*$0 }
        let fullError = sqrt(zip(y,predicted).reduce(0) { $0+pow($1.0-$1.1,2) }/Double(side*side))
        heldError = max(heldError,fullError)
        guard fullError <= tolerance else { return rejected("nonuniformInteriorTone",error: heldError,disagreement: disagreement) }
        let excursion = zip(predicted,x).map { $0.0-$0.1 }
        let representative = log2(predicted.reduce(0) { $0+pow(2,$1) }/x.reduce(0) { $0+pow(2,$1) })
        return .init(slope: model.coefficient,intercept: model.drift,pixelExcursion: excursion,
                     representativeExcursion: representative,heldError: heldError,
                     predictionDisagreement: disagreement,rejection:nil)
    }

    struct PulseLinearEvidence: Sendable {
        let gain: Double?
        let offset: Double? // linear luminance, not EV
        let pixelExcursion: [Double]
        let representativeExcursion: Double?
        let heldError: Double
        let rejection: String?
    }

    enum LinearReference: Sendable { case geometricExposure, arithmeticRadiance }

    /// Tests a positive affine response in linear luminance. Independent
    /// geometry and event evidence are still required; no correction is implied.
    static func pulseLinearLuminancePixels(before: [Double],middle: [Double],after: [Double],
                                           alpha: Double,tolerance: Double = 0.04,reference: LinearReference = .geometricExposure) -> PulseLinearEvidence {
        func rejected(_ reason: String,error: Double = 0) -> PulseLinearEvidence {
            .init(gain:nil,offset:nil,pixelExcursion:[],representativeExcursion:nil,heldError:error,rejection:reason)
        }
        guard alpha.isFinite,alpha > 0,alpha < 1,tolerance.isFinite,tolerance > 0,
              [before,middle,after].allSatisfy({ $0.count == 75 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else {
            return rejected("invalidLinearShapeTimeOrRGB")
        }
        func luminance(_ rgb: [Double]) -> [Double] {
            (0..<25).map { 0.2126*rgb[$0*3]+0.7152*rgb[$0*3+1]+0.0722*rgb[$0*3+2] }
        }
        let a=luminance(before),b=luminance(middle),c=luminance(after)
        guard [a,b,c].allSatisfy({ $0.allSatisfy { $0 > 0.005 } }) else { return rejected("darkLinearLuminance") }
        // Additive radiance and multiplicative exposure have different temporal
        // references. Keep the established exposure model as the default.
        let x=a.indices.map { reference == .arithmeticRadiance
            ? (1-alpha)*a[$0]+alpha*c[$0] : pow(a[$0],1-alpha)*pow(c[$0],alpha) }
        let pixels=(0..<25).filter { $0%5 != 2 && $0/5 != 2 }
        let folds=[pixels.filter { $0/5 < 2 },pixels.filter { $0/5 > 2 },pixels.filter { $0%5 < 2 },pixels.filter { $0%5 > 2 }]
        func model(_ indices: [Int]) -> (coefficient:Double,drift:Double)? {
            let values=indices.map { x[$0] }
            guard values.max()!-values.min()! >= 0.01,
                  let result=fit(x:values,y:indices.map { b[$0] },intervals:Array(repeating:1,count:indices.count)),
                  (0.5...2).contains(result.coefficient),abs(result.drift) <= 0.05 else { return nil }
            return result
        }
        var predictions=[[Double]](),heldError=0.0
        for (i,training) in folds.enumerated() {
            guard let m=model(training) else { return rejected("unidentifiableOrUnboundedLinearResponse") }
            let prediction=x.map { m.coefficient*$0+m.drift }
            guard prediction.allSatisfy({ $0 > 0.005 && $0 < 0.95 }) else { return rejected("invalidLinearPrediction") }
            let held=folds[i ^ 1]
            let error=sqrt(held.reduce(0) { $0+pow(log2(b[$1]/prediction[$1]),2) }/Double(held.count))
            heldError=max(heldError,error)
            guard error <= tolerance else { return rejected("nonuniformHeldLinearResponse",error:heldError) }
            predictions.append(prediction)
        }
        let disagreement=x.indices.map { i in log2(predictions.map { $0[i] }.max()!/predictions.map { $0[i] }.min()!) }.max()!
        guard disagreement <= tolerance else { return rejected("inconsistentLinearPredictions",error:heldError) }
        guard let m=model(pixels) else { return rejected("unidentifiableOrUnboundedLinearResponse") }
        let prediction=x.map { m.coefficient*$0+m.drift }
        guard prediction.allSatisfy({ $0 > 0.005 && $0 < 0.95 }) else { return rejected("invalidLinearPrediction") }
        let errors=zip(b,prediction).map { abs(log2($0.0/$0.1)) }
        let fullError=sqrt(errors.reduce(0) { $0+$1*$1 }/25)
        heldError=max(heldError,fullError)
        guard fullError <= tolerance,errors.max()! <= 2*tolerance else { return rejected("nonuniformInteriorLinearResponse",error:heldError) }
        return .init(gain:m.coefficient,offset:m.drift,pixelExcursion:zip(prediction,x).map { log2($0.0/$0.1) },
                     representativeExcursion:log2(prediction.reduce(0,+)/x.reduce(0,+)),heldError:heldError,rejection:nil)
    }

    struct PulsePlaneEvidence: Sendable {
        let coefficients: [Double] // constant, normalized horizontal/vertical gradients
        let pixelExcursion: [Double]
        let heldError: Double
        let predictionDisagreement: Double
        let rejection: String?
    }

    /// A source-only smooth illumination gradient, independent of scene motion
    /// proof and external donor support. Never authorizes an image warp.
    static func pulsePlaneLuminancePixels(before: [Double],middle: [Double],after: [Double],
                                          alpha: Double,tolerance: Double = 0.04,side: Int = 5) -> PulsePlaneEvidence {
        func rejected(_ reason: String,error: Double = 0,disagreement: Double = 0) -> PulsePlaneEvidence {
            .init(coefficients:[],pixelExcursion:[],heldError:error,predictionDisagreement:disagreement,rejection:reason)
        }
        guard (5...13).contains(side),side%2 == 1,alpha.isFinite,alpha > 0,alpha < 1,
              tolerance.isFinite,tolerance > 0,
              [before,middle,after].allSatisfy({ $0.count == side*side*3 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.95 } }) else {
            return rejected("invalidPlaneShapeTimeOrRGB")
        }
        func levels(_ rgb: [Double]) -> [Double]? {
            let y = (0..<side*side).map { 0.2126*rgb[$0*3]+0.7152*rgb[$0*3+1]+0.0722*rgb[$0*3+2] }
            return y.allSatisfy({ $0 > 0.005 }) ? y.map(log2) : nil
        }
        guard let a = levels(before),let b = levels(middle),let c = levels(after) else { return rejected("darkPlaneLuminance") }
        let residual = a.indices.map { b[$0]-(1-alpha)*a[$0]-alpha*c[$0] },half = side/2
        let basis = a.indices.map { [1.0,Double($0%side-half)/Double(half),Double($0/side-half)/Double(half)] }
        func fitPlane(_ indices: [Int]) -> [Double]? {
            var weights = Array(repeating:1.0,count:indices.count),model = [Double]()
            for _ in 0..<5 {
                var matrix = Array(repeating:Array(repeating:0.0,count:4),count:3)
                for (j,i) in indices.enumerated() {
                    for row in 0..<3 {
                        for col in 0..<3 { matrix[row][col] += weights[j]*basis[i][row]*basis[i][col] }
                        matrix[row][3] += weights[j]*basis[i][row]*residual[i]
                    }
                }
                for col in 0..<3 {
                    let pivot = (col..<3).max { abs(matrix[$0][col]) < abs(matrix[$1][col]) }!
                    guard abs(matrix[pivot][col]) > 1e-10 else { return nil }
                    matrix.swapAt(col,pivot)
                    let divisor = matrix[col][col]
                    for j in col..<4 { matrix[col][j] /= divisor }
                    for row in 0..<3 where row != col {
                        let factor = matrix[row][col]
                        for j in col..<4 { matrix[row][j] -= factor*matrix[col][j] }
                    }
                }
                model = matrix.map { $0[3] }
                guard model.allSatisfy(\.isFinite) else { return nil }
                let errors = indices.map { i in residual[i]-zip(model,basis[i]).reduce(0) { $0+$1.0*$1.1 } }
                let center = ExposureMath.median(errors)
                let scale = max(0.001,1.4826*ExposureMath.median(errors.map { abs($0-center) }))
                weights = errors.map { min(1,3*scale/max(1e-12,abs($0))) }
            }
            return model
        }
        func predict(_ model: [Double]) -> [Double] { basis.map { row in zip(model,row).reduce(0) { $0+$1.0*$1.1 } } }
        func bounded(_ model: [Double]) -> Bool { abs(model[1]) <= 0.35 && abs(model[2]) <= 0.35 && abs(model[1])+abs(model[2]) <= 0.5 }
        let pixels = a.indices.filter { $0%side != half && $0/side != half }
        let folds = [pixels.filter { $0/side < half },pixels.filter { $0/side > half },pixels.filter { $0%side < half },pixels.filter { $0%side > half }]
        var predictions = [[Double]](),heldError = 0.0
        for (i,training) in folds.enumerated() {
            guard let model = fitPlane(training),bounded(model) else { return rejected("invalidPlaneGradient") }
            let prediction = predict(model),held = folds[i ^ 1]
            let error = sqrt(held.reduce(0) { $0+pow(residual[$1]-prediction[$1],2) }/Double(held.count))
            heldError = max(heldError,error)
            guard error <= tolerance else { return rejected("nonuniformHeldPlane",error:heldError) }
            predictions.append(prediction)
        }
        let disagreement = a.indices.map { i in predictions.map { $0[i] }.max()!-predictions.map { $0[i] }.min()! }.max()!
        guard disagreement <= tolerance else { return rejected("inconsistentPlanePredictions",error:heldError,disagreement:disagreement) }
        guard let model = fitPlane(pixels),bounded(model) else { return rejected("invalidPlaneGradient") }
        let prediction = predict(model),errors = zip(residual,prediction).map { abs($0.0-$0.1) }
        let fullError = sqrt(errors.reduce(0) { $0+$1*$1 }/Double(errors.count))
        heldError = max(heldError,fullError)
        guard fullError <= tolerance,errors.max()! <= 2*tolerance else {
            return rejected("nonuniformInteriorPlane",error:heldError,disagreement:disagreement)
        }
        return .init(coefficients:model,pixelExcursion:prediction,heldError:heldError,predictionDisagreement:disagreement,rejection:nil)
    }

    struct PulseClockEvidence: Sendable {
        enum State: String, Sendable { case quiet, event, unknown }
        let state: State
        let excursion: Double?
        let uncertainty: Double
    }

    /// Donors must already be source-selected, independent, leave-query-out
    /// and spatially ordered. This routine never creates donor independence.
    static func pulseClock(excursions: [Double], errors: [Double], minimumDonors: Int = 4) -> PulseClockEvidence {
        let unknown = PulseClockEvidence(state:.unknown,excursion:nil,uncertainty:0)
        guard minimumDonors >= 4, excursions.count >= minimumDonors, errors.count == excursions.count,
              excursions.allSatisfy(\.isFinite), errors.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return unknown }
        let uncertainty = ExposureMath.median(errors), event = ExposureMath.median(excursions)
        // Quiet is positive evidence: every independent donor must bound its
        // source excursion and held prediction error. Failure is not zero.
        if zip(excursions,errors).allSatisfy({ abs($0.0)+2*$0.1 <= 0.01 }) {
            return .init(state:.quiet,excursion:event,uncertainty:uncertainty)
        }
        let half = excursions.count/2
        let left = ExposureMath.median(Array(excursions[..<half]))
        let right = ExposureMath.median(Array(excursions[half...]))
        guard left*right > 0,min(abs(left),abs(right)) > max(0.03,2*uncertainty),abs(event) > 0.03 else {
            return .init(state:.unknown,excursion:nil,uncertainty:uncertainty)
        }
        return .init(state:.event,excursion:event,uncertainty:uncertainty)
    }

    private struct Edge {
        let track: Int
        let before: Observation
        let after: Observation
        var change: Double { after.level - before.level }
    }

    private static func independent(_ a: Edge, _ b: Edge) -> Bool {
        max(abs(a.before.x-b.before.x), abs(a.before.y-b.before.y)) >= 5 &&
        max(abs(a.after.x-b.after.x), abs(a.after.y-b.after.y)) >= 5
    }

    private static func edgeEvidence(frame: Int, edges: [Edge], excluding query: Int?, configuration: Configuration) -> EdgeDiagnostic {
        let own = edges.first { $0.track == query }
        var chosen: [Edge] = []
        var candidateCount = 0
        for edge in edges {
            if edge.track == query { continue }
            if let own, !independent(edge, own) { continue }
            candidateCount += 1
            if chosen.allSatisfy({ independent(edge, $0) }) { chosen.append(edge) }
        }
        let half = chosen.count / 2
        let left = half > 0 ? ExposureMath.median(chosen[..<half].map(\.change)) : nil
        let right = chosen.isEmpty ? nil : ExposureMath.median(chosen[half...].map(\.change))
        let value = chosen.isEmpty ? nil : ExposureMath.median(chosen.map(\.change))
        func result(_ rejection: EdgeRejection?) -> EdgeDiagnostic {
            EdgeDiagnostic(frame: frame, candidateCount: candidateCount, independentCount: chosen.count,
                left: left, right: right, median: value, rejection: rejection)
        }
        guard chosen.count >= max(4, configuration.minimumDonors), let left, let right, let value else {
            return result(.insufficientQuorum)
        }
        let quiet = max(abs(left), max(abs(right), abs(value))) <= configuration.quietFloor
        // Different materials may have different coupling amplitudes. Spatial
        // halves certify direction; temporal response validates each amplitude.
        guard quiet || (left*right > 0 && min(abs(left), abs(right)) > configuration.quietFloor) else {
            return result(left*right < 0 ? .opposingSigns : .weakSpatialHalf)
        }
        return result(nil)
    }

    private static func increment(_ edges: [Edge], excluding query: Int?, configuration: Configuration) -> Double? {
        let evidence = edgeEvidence(frame: edges.first?.after.frame ?? 0, edges: edges, excluding: query, configuration: configuration)
        // Retain small supported increments to avoid turning drift into steps.
        return evidence.rejection == nil ? evidence.median : nil
    }

    private static func valid(_ track: Track, frameCount: Int, minimumObservations: Int = 3) -> Bool {
        guard track.observations.count >= minimumObservations else { return false }
        for (index, observation) in track.observations.enumerated() {
            guard observation.frame >= 0, observation.frame < frameCount,
                  observation.level.isFinite else { return false }
            if index > 0, observation.frame != track.observations[index-1].frame+1 { return false }
        }
        return true
    }

    private static func makeEdges(frameCount: Int, tracks: [Track], additionalDonors: [Track] = []) -> [[Edge]] {
        guard frameCount > 0 else { return [] }
        var edges = Array(repeating: [Edge](), count: frameCount)
        let all = tracks + additionalDonors
        for (identifier, track) in all.enumerated()
        where valid(track, frameCount: frameCount, minimumObservations: identifier < tracks.count ? 3 : 2) {
            for index in 1..<track.observations.count {
                let before = track.observations[index-1], after = track.observations[index]
                edges[after.frame].append(Edge(track: identifier, before: before, after: after))
            }
        }
        for frame in edges.indices {
            edges[frame].sort {
                if $0.after.x != $1.after.x { return $0.after.x < $1.after.x }
                if $0.after.y != $1.after.y { return $0.after.y < $1.after.y }
                return $0.track < $1.track
            }
        }
        return edges
    }

    /// Read-only evidence for EVERY edge, including those after the first failure.
    /// Additional already-qualified source pairs are hypothetical donors only;
    /// neither this method nor those donors change estimate() or its quorum.
    static func edgeDiagnostics(frameCount: Int, tracks: [Track], additionalDonors: [Track] = [],
                                configuration: Configuration) -> [EdgeDiagnostic] {
        guard frameCount >= 2 else { return [] }
        let edges = makeEdges(frameCount: frameCount, tracks: tracks, additionalDonors: additionalDonors)
        return (1..<frameCount).map {
            edgeEvidence(frame: $0, edges: edges[$0], excluding: nil, configuration: configuration)
        }
    }

    private static func unknown(_ track: Track, times: [Double], state: State = .unknown) -> SourceEstimate {
        SourceEstimate(state: state, coefficient: state == .quiet ? 0 : nil,
            frames: track.observations.map(\.frame),
            times: track.observations.map { times.indices.contains($0.frame) ? times[$0.frame] : 0 },
            q: Array(repeating: 0, count: track.observations.count), independentlyValidated: false,
            temporalFolds: [], eventFolds: [])
    }

    /// Returns track-aligned estimates. By default an unsupported edge invalidates
    /// the scene waveform. The opt-in run mode accepts only whole queries inside
    /// supported runs; neither missing observations nor scene cuts are bridged.
    /// Same-event estimates remain visible, but strict calibration rejects them.
    static func estimate(times: [Double], tracks: [Track], configuration: Configuration) -> [SourceEstimate] {
        guard times.count >= 3, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
              configuration.radius.isFinite, configuration.radius >= 0,
              configuration.quietFloor > 0, configuration.excitation > configuration.quietFloor,
              configuration.agreement > 0 else { return tracks.map { unknown($0, times: times) } }
        let edges = makeEdges(frameCount: times.count, tracks: tracks)
        let base: [Double?] = [0.0] + (1..<times.count).map {
            increment(edges[$0], excluding: nil, configuration: configuration)
        }
        if !configuration.allowSupportedRuns && base.contains(where: { $0 == nil }) {
            return tracks.map { unknown($0, times: times) }
        }
        return tracks.enumerated().map { identifier, track in
            guard valid(track, frameCount: times.count),
                  let first = track.observations.first?.frame,
                  let last = track.observations.last?.frame else { return unknown(track, times: times) }
            // A query crossing an unknown transition is never calibrated. Runs
            // have their own origin and smoothing window, so no missing edge is
            // filled with zero or carries an offset from another run.
            guard ((first+1)...last).allSatisfy({ base[$0] != nil }) else {
                return unknown(track, times: times)
            }
            var start = first, end = last
            while start > 0 && base[start] != nil { start -= 1 }
            while end+1 < times.count && base[end+1] != nil { end += 1 }
            var increments = [0.0] + ((start+1)...end).map { base[$0]! }
            for observation in track.observations.dropFirst() {
                guard let value = increment(edges[observation.frame], excluding: identifier, configuration: configuration) else {
                    return unknown(track, times: times)
                }
                increments[observation.frame-start] = value
            }
            if increments.allSatisfy({ abs($0) <= configuration.quietFloor }) {
                return unknown(track, times: times, state: .quiet)
            }
            let frames = track.observations.map(\.frame)
            let localTimes = frames.map { times[$0] }
            let dt = differences(localTimes)
            let x = frames.dropFirst().map { increments[$0-start] }
            let y = differences(track.observations.map(\.level))
            let active = x.indices.filter { abs(x[$0]) >= configuration.excitation }
            guard active.count >= 2 else { return unknown(track, times: times) }
            let folds = temporalFolds(active: active, count: x.count)
            let episodes = eventFolds(active: active)
            guard let response = validate(x: x, y: y, intervals: dt, folds: folds, configuration: configuration) else {
                return unknown(track, times: times)
            }
            let independent = episodes.count >= 2 && validate(x: x, y: y, intervals: dt, folds: episodes, configuration: configuration) != nil
            var phi = [0.0]
            for value in increments.dropFirst() { phi.append(phi.last! + value) }
            let target = configuration.mode == .steady
                ? Array(repeating: ExposureMath.median(phi), count: phi.count)
                : ExposureMath.smoothTargets(times: Array(times[start...end]), levels: phi, radius: configuration.radius, preserveShortRamps: true)
            let q = frames.map { target[$0-start] - phi[$0-start] }
            return SourceEstimate(state: response.absent ? .absent : .supported,
                coefficient: response.absent ? 0 : response.coefficient, frames: frames, times: localTimes,
                q: q, independentlyValidated: independent, temporalFolds: folds, eventFolds: episodes)
        }
    }

    /// Automatic gains must be measured as log luminance(after)/luminance(source)
    /// on the same source footprint; never mean RGB EV or manual-adjusted output.
    /// Partial Spatial retains the corresponding global correction component.
    static func calibrate(estimate: SourceEstimate, renderedGain: [Double], globalGain: [Double],
                          strength: Double, spatial: Double, configuration: Configuration) -> GainCalibration? {
        guard strength.isFinite, spatial.isFinite, strength > 0, strength <= 1, spatial > 0, spatial <= 1,
              estimate.state == .supported || estimate.state == .absent,
              let sourceCoefficient = estimate.coefficient,
              renderedGain.count == estimate.q.count, globalGain.count == estimate.q.count,
              renderedGain.allSatisfy(\.isFinite), globalGain.allSatisfy(\.isFinite),
              !configuration.requireIndependentEvents || estimate.independentlyValidated else { return nil }
        let x = differences(estimate.q), dt = differences(estimate.times)
        guard let rendered = validate(x: x, y: differences(renderedGain), intervals: dt,
                                      folds: estimate.temporalFolds, configuration: configuration) else { return nil }
        let renderedIndependent = estimate.eventFolds.count >= 2 && validate(x: x, y: differences(renderedGain), intervals: dt,
            folds: estimate.eventFolds, configuration: configuration) != nil
        var globalCoefficient = 0.0, globalIndependent = true
        if spatial < 1 {
            guard let global = validate(x: x, y: differences(globalGain), intervals: dt,
                                        folds: estimate.temporalFolds, configuration: configuration) else { return nil }
            globalCoefficient = global.absent ? 0 : global.coefficient
            globalIndependent = estimate.eventFolds.count >= 2 && validate(x: x, y: differences(globalGain), intervals: dt,
                folds: estimate.eventFolds, configuration: configuration) != nil
        }
        let independent = estimate.independentlyValidated && renderedIndependent && globalIndependent
        guard !configuration.requireIndependentEvents || independent else { return nil }
        let renderedCoefficient = rendered.absent ? 0 : rendered.coefficient
        let coefficient = (1-spatial)*globalCoefficient + spatial*strength*sourceCoefficient - renderedCoefficient
        // Avoid manufacturing a gain from round-off in an already correct fit.
        let delta = abs(coefficient) < 1e-10 ? Array(repeating: 0.0, count: estimate.q.count) : estimate.q.map { coefficient*$0 }
        return GainCalibration(delta: delta, renderedCoefficient: renderedCoefficient,
                               globalCoefficient: globalCoefficient, independentlyValidated: independent)
    }

    /// Optional gain-only fallback AFTER source geometry is frozen. The source
    /// must demonstrate absent coupling to a sufficiently excited automatic gain
    /// waveform. A quiet/unknown predictor is not proof of source absence.
    ///
    /// `automaticGlobal` is the scene-wide nominal automatic stops+brightness EV;
    /// the other arrays are aligned to `frames`, and contain no manual adjustment.
    /// `globalGain` is actual global-only rendered log-luminance gain on these
    /// same footprints, not the nominal predictor. Strength is already present
    /// in these inputs, so it is a bypass guard, not another multiplier.
    ///
    /// This removes only rapid gain: H is a curvature trend in BOTH modes. Slow
    /// calibration and sustained overbright sections are outside this fallback.
    static func calibrateAbsence(times: [Double], frames: [Int], sourceLevels: [Double],
                                 renderedGain: [Double], globalGain: [Double], automaticGlobal: [Double],
                                 strength: Double, spatial: Double, configuration: Configuration) -> GainCalibration? {
        guard strength.isFinite, spatial.isFinite, strength > 0, strength <= 1, spatial > 0, spatial <= 1,
              times.count >= 3, automaticGlobal.count == times.count,
              times.allSatisfy(\.isFinite), automaticGlobal.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
              frames.count >= 3, frames.allSatisfy({ times.indices.contains($0) }),
              zip(frames, frames.dropFirst()).allSatisfy({ $1 == $0+1 }),
              sourceLevels.count == frames.count, renderedGain.count == frames.count, globalGain.count == frames.count,
              sourceLevels.allSatisfy(\.isFinite), renderedGain.allSatisfy(\.isFinite), globalGain.allSatisfy(\.isFinite),
              configuration.radius.isFinite, configuration.radius >= 0,
              configuration.quietFloor > 0, configuration.excitation > configuration.quietFloor,
              configuration.agreement > 0 else { return nil }
        let trend = ExposureMath.smoothTargets(times: times, levels: automaticGlobal,
            radius: configuration.radius, preserveShortRamps: true)
        let psi = frames.map { automaticGlobal[$0]-trend[$0] }
        let x = differences(psi), dt = differences(frames.map { times[$0] })
        let active = x.indices.filter { abs(x[$0]) >= configuration.excitation }
        guard active.count >= 2 else { return nil }
        let folds = temporalFolds(active: active, count: x.count)
        let episodes = eventFolds(active: active)
        guard let source = validate(x: x, y: differences(sourceLevels), intervals: dt,
                                    folds: folds, configuration: configuration), source.absent else { return nil }
        let sourceEvent = episodes.count >= 2 ? validate(x: x, y: differences(sourceLevels), intervals: dt,
            folds: episodes, configuration: configuration) : nil
        let sourceIndependent = sourceEvent?.absent == true
        guard !configuration.requireIndependentEvents || sourceIndependent,
              let rendered = validate(x: x, y: differences(renderedGain), intervals: dt,
                                      folds: folds, configuration: configuration) else { return nil }
        let renderedIndependent = episodes.count >= 2 && validate(x: x, y: differences(renderedGain), intervals: dt,
            folds: episodes, configuration: configuration) != nil
        var globalCoefficient = 0.0, globalIndependent = true
        if spatial < 1 {
            guard let global = validate(x: x, y: differences(globalGain), intervals: dt,
                                        folds: folds, configuration: configuration) else { return nil }
            globalCoefficient = global.absent ? 0 : global.coefficient
            globalIndependent = episodes.count >= 2 && validate(x: x, y: differences(globalGain), intervals: dt,
                folds: episodes, configuration: configuration) != nil
        }
        let independent = sourceIndependent && renderedIndependent && globalIndependent
        guard !configuration.requireIndependentEvents || independent else { return nil }
        let renderedCoefficient = rendered.absent ? 0 : rendered.coefficient
        let coefficient = (1-spatial)*globalCoefficient-renderedCoefficient
        let delta = abs(coefficient) < 1e-10 ? Array(repeating: 0.0, count: psi.count) : psi.map { coefficient*$0 }
        return GainCalibration(delta: delta, renderedCoefficient: renderedCoefficient,
                               globalCoefficient: globalCoefficient, independentlyValidated: independent)
    }

    private static func differences(_ values: [Double]) -> [Double] {
        zip(values.dropFirst(), values).map { $0 - $1 }
    }

    private static func temporalFolds(active: [Int], count: Int) -> [[Int]] {
        let split = (active[(active.count-1)/2] + active[active.count/2])/2 + 1
        return [Array(0..<split), Array(split..<count)]
    }

    private static func eventFolds(active: [Int]) -> [[Int]] {
        var episodes: [[Int]] = []
        for index in active {
            if episodes.isEmpty || index > episodes[episodes.count-1].last!+1 { episodes.append([]) }
            episodes[episodes.count-1].append(index)
        }
        return episodes
    }

    /// Robust fit Δlevel = coefficient*Δcomponent + drift*Δtime. The drift
    /// regressor preserves constant calibration and physical linear VFR trends.
    static func fit(x: [Double], y: [Double], intervals: [Double]) -> (coefficient: Double, drift: Double)? {
        guard x.count >= 2, x.count == y.count, x.count == intervals.count,
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite),
              intervals.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var weights = Array(repeating: 1.0, count: x.count)
        var coefficient = 0.0, drift = 0.0
        for _ in 0..<5 {
            var xx = 0.0, tt = 0.0, xt = 0.0, xy = 0.0, ty = 0.0
            for i in x.indices {
                xx += weights[i]*x[i]*x[i]
                tt += weights[i]*intervals[i]*intervals[i]
                xt += weights[i]*x[i]*intervals[i]
                xy += weights[i]*x[i]*y[i]
                ty += weights[i]*intervals[i]*y[i]
            }
            let denominator = xx-xt*xt/tt
            guard tt > 0, denominator > max(1e-12, xx*1e-10) else { return nil }
            coefficient = (xy-xt*ty/tt)/denominator
            drift = (ty-coefficient*xt)/tt
            guard coefficient.isFinite, drift.isFinite else { return nil }
            let residual = x.indices.map { y[$0]-coefficient*x[$0]-drift*intervals[$0] }
            let centre = ExposureMath.median(residual)
            let scale = max(0.001, 1.4826*ExposureMath.median(residual.map { abs($0-centre) }))
            weights = residual.map { min(1, 3*scale/max(1e-12, abs($0))) }
        }
        return (coefficient, drift)
    }

    static func validate(x: [Double], y: [Double], intervals: [Double], folds: [[Int]], configuration: Configuration) -> Response? {
        guard x.count == y.count, x.count == intervals.count, folds.count >= 2 else { return nil }
        var coefficients: [Double] = [], errors: [Double] = [], nullErrors: [Double] = []
        for held in folds {
            guard !held.isEmpty, Set(held).count == held.count, held.allSatisfy({ x.indices.contains($0) }) else { return nil }
            let heldSet = Set(held), train = x.indices.filter { !heldSet.contains($0) }
            guard train.contains(where: { abs(x[$0]) >= configuration.excitation }),
                  held.contains(where: { abs(x[$0]) >= configuration.excitation }),
                  let model = fit(x: train.map { x[$0] }, y: train.map { y[$0] }, intervals: train.map { intervals[$0] }) else { return nil }
            coefficients.append(model.coefficient)
            for i in held {
                errors.append(y[i]-model.coefficient*x[i]-model.drift*intervals[i])
                nullErrors.append(y[i]-model.drift*intervals[i])
            }
        }
        guard let model = fit(x: x, y: y, intervals: intervals) else { return nil }
        let error = sqrt(errors.reduce(0) { $0+$1*$1 }/Double(errors.count))
        let null = sqrt(nullErrors.reduce(0) { $0+$1*$1 }/Double(nullErrors.count))
        let absent = abs(model.coefficient) <= 0.03 && coefficients.allSatisfy { abs($0) <= 0.05 } && null <= 0.01
        let explained = error <= max(configuration.agreement, 0.06*null) && error <= 0.7*null
        guard abs(model.coefficient) <= 2.5,
              coefficients.max()! - coefficients.min()! <= max(0.06, 0.15*abs(model.coefficient)),
              absent || explained else { return nil }
        return Response(coefficient: model.coefficient, drift: model.drift, heldErrorRMS: error, absent: absent)
    }
}
