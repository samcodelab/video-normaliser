import Foundation

/// Reconstructs a source lighting signal from corroborated three-frame
/// excursions. A reconstructed source signal alone is not permission to correct
/// an image. By default unobservable constant/linear components are removed.
/// Validated correction increments may instead preserve their run endpoints.
enum PulseReconstruction {
    struct Constraint {
        let before: Int
        let middle: Int
        let after: Int
        let excursion: Double
        let weight: Double
    }

    /// Joint correction increments for independently certified temporal rows.
    /// Only certified middle frames are variables. Other frames keep their
    /// existing gain; nil does not assert that their source lighting is quiet.
    static func solveCorrections(times: [Double], constraints: [Constraint],
                                 regularization: Double = 0.001, variableFrames: Set<Int>? = nil) -> Result? {
        guard times.count >= 3,times.allSatisfy(\.isFinite),
              zip(times,times.dropFirst()).allSatisfy({ $0 < $1 }),
              regularization.isFinite,regularization >= 0,
              constraints.allSatisfy({ $0.before >= 0 && $0.before < $0.middle && $0.middle < $0.after &&
                  $0.after < times.count && $0.excursion.isFinite && $0.weight.isFinite && $0.weight > 0 }) else { return nil }
        guard !constraints.isEmpty else { return Result(signal:Array(repeating:nil,count:times.count),maximumResidual:0) }
        let supported = Set(constraints.map(\.middle))
        guard variableFrames == nil || variableFrames!.isSubset(of:supported) else { return nil }
        let frames = Array(variableFrames ?? supported).sorted()
        guard !frames.isEmpty else { return Result(signal:Array(repeating:nil,count:times.count),maximumResidual:constraints.map { abs($0.excursion) }.max() ?? 0) }
        let columns = Dictionary(uniqueKeysWithValues:frames.enumerated().map { ($0.element,$0.offset) })
        let maximumWeight = constraints.map(\.weight).max()!
        let rows = constraints.map { row -> ([(Int,Double)],Double,Double) in
            let alpha = (times[row.middle]-times[row.before])/(times[row.after]-times[row.before])
            let terms = [(row.before,-(1-alpha)),(row.middle,1.0),(row.after,-alpha)]
            return (terms.compactMap { frame,value in columns[frame].map { ($0,value) } },row.excursion,row.weight/maximumWeight)
        }
        func forward(_ v: [Double],_ terms: [(Int,Double)]) -> Double {
            terms.reduce(0) { $0+v[$1.0]*$1.1 }
        }
        func product(_ v: [Double]) -> [Double] {
            var result = v.map { regularization*$0 }
            for (terms,_,weight) in rows {
                let value = weight*forward(v,terms)
                for (column,coefficient) in terms { result[column] += coefficient*value }
            }
            return result
        }
        func dot(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        var rhs = [Double](repeating:0,count:frames.count)
        for (terms,target,weight) in rows {
            for (column,coefficient) in terms { rhs[column] += coefficient*weight*target }
        }
        var x = [Double](repeating:0,count:frames.count),residual = rhs,direction = rhs
        var energy = dot(residual,residual)
        let threshold = max(1e-24,energy*1e-20)
        for _ in 0..<min(4096,max(32,frames.count*4)) {
            if energy <= threshold { break }
            let applied = product(direction),denominator = dot(direction,applied)
            guard denominator.isFinite,denominator > 0 else { return nil }
            let step = energy/denominator
            x = zip(x,direction).map { $0.0+step*$0.1 }
            residual = zip(residual,applied).map { $0.0-step*$0.1 }
            let next = dot(residual,residual),beta = next/energy
            direction = zip(residual,direction).map { $0.0+beta*$0.1 }
            energy = next
        }
        guard energy <= max(threshold,dot(rhs,rhs)*1e-12),x.allSatisfy(\.isFinite) else { return nil }
        var signal = [Double?](repeating:nil,count:times.count)
        for (column,frame) in frames.enumerated() { signal[frame] = x[column] }
        let residuals = rows.map { forward(x,$0.0)-$0.1 }
        return Result(signal:signal,maximumResidual:residuals.map(abs).max() ?? 0,rowResiduals:residuals)
    }
    struct Result {
        let signal: [Double?]
        let maximumResidual: Double
        let rowResiduals: [Double]
        init(signal: [Double?], maximumResidual: Double, rowResiduals: [Double] = []) {
            self.signal = signal; self.maximumResidual = maximumResidual; self.rowResiduals = rowResiduals
        }
    }

    /// Measured held-patch error bounds the precision of a temporal target.
    /// This is a deterministic consistency check, not a probability estimate.
    static func residualsConsistent(_ residuals: [Double], errors: [Double], scale: Double) -> Bool {
        guard residuals.count == errors.count,scale.isFinite,scale > 0,
              errors.allSatisfy({ $0.isFinite && $0 >= 0 }),residuals.allSatisfy(\.isFinite) else { return false }
        return zip(residuals,errors).allSatisfy { abs($0.0) <= scale*max(0.01,2*$0.1) }
    }

    static func solve(times: [Double], excursions: [Double?], weights: [Double],
                      regularization: Double = 0.001, anchorEndpoints: Bool = false) -> Result? {
        let n = times.count
        guard n >= 3, excursions.count == n, weights.count == n,
              times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
              weights.allSatisfy({ $0.isFinite && $0 >= 0 }),
              excursions.compactMap({ $0 }).allSatisfy(\.isFinite),
              regularization.isFinite, regularization >= 0 else { return nil }
        var signal = [Double?](repeating: nil, count: n), maximumResidual = 0.0
        var first = 1
        while first < n-1 {
            guard excursions[first] != nil, weights[first] > 0 else { first += 1; continue }
            var last = first
            while last+1 < n-1, excursions[last+1] != nil, weights[last+1] > 0 { last += 1 }
            // Runs share at most boundary frames. Keep independent estimates
            // separate rather than silently connecting across an unknown row.
            let start = first-1, end = last+1, count = end-start+1
            let t = Array(times[start...end])
            let center = t.reduce(0,+)/Double(count)
            let span = t.last!-t.first!
            let axis = t.map { ($0-center)/span }
            let axisEnergy = axis.reduce(0) { $0+$1*$1 }
            func project(_ v: [Double]) -> [Double] {
                if anchorEndpoints {
                    // Correction increments have a different gauge from a
                    // source lighting estimate. Anchor them to the unchanged
                    // gain at unsupported run boundaries. This does not assert
                    // that source illumination at those boundaries is quiet.
                    var out = v
                    out[0] = 0; out[count-1] = 0
                    return out
                }
                let mean = v.reduce(0,+)/Double(count)
                let slope = zip(v,axis).reduce(0) { $0+$1.0*$1.1 }/axisEnergy
                return zip(v,axis).map { $0.0-mean-slope*$0.1 }
            }
            let alpha = (1..<count-1).map { (t[$0]-t[$0-1])/(t[$0+1]-t[$0-1]) }
            let scale = weights[first...last].max()!
            let w = weights[first...last].map { $0/scale }
            let r = excursions[first...last].map { $0! }
            func transpose(_ rows: [Double]) -> [Double] {
                var out = [Double](repeating: 0,count: count)
                for j in rows.indices {
                    out[j] -= (1-alpha[j])*rows[j]
                    out[j+1] += rows[j]
                    out[j+2] -= alpha[j]*rows[j]
                }
                return out
            }
            func forward(_ v: [Double]) -> [Double] {
                alpha.indices.map { v[$0+1]-(1-alpha[$0])*v[$0]-alpha[$0]*v[$0+2] }
            }
            func product(_ v: [Double]) -> [Double] {
                let rows = zip(forward(v),w).map(*)
                let normal = transpose(rows)
                return project(zip(normal,v).map { $0.0+regularization*$0.1 })
            }
            func dot(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
            let rhs = project(transpose(zip(r,w).map(*)))
            var x = [Double](repeating: 0,count: count), residual = rhs, direction = rhs
            var energy = dot(residual,residual)
            let threshold = max(1e-24,energy*1e-20)
            for _ in 0..<min(4096, max(32, count*4)) {
                if energy <= threshold { break }
                let applied = product(direction), denominator = dot(direction,applied)
                guard denominator.isFinite, denominator > 0 else { return nil }
                let step = energy/denominator
                x = zip(x,direction).map { $0.0+step*$0.1 }
                residual = zip(residual,applied).map { $0.0-step*$0.1 }
                let nextEnergy = dot(residual,residual), beta = nextEnergy/energy
                direction = zip(residual,direction).map { $0.0+beta*$0.1 }
                energy = nextEnergy
            }
            guard energy <= max(threshold, dot(rhs,rhs)*1e-12) else { return nil }
            x = project(x)
            guard x.allSatisfy(\.isFinite) else { return nil }
            for (j,value) in x.enumerated() {
                // A frame bordering two independent runs has no single
                // established level. Leave it unknown rather than average.
                if signal[start+j] != nil { signal[start+j] = nil }
                else { signal[start+j] = value }
            }
            maximumResidual = max(maximumResidual, zip(forward(x),r).map { abs($0.0-$0.1) }.max() ?? 0)
            first = last+1
        }
        return Result(signal: signal, maximumResidual: maximumResidual)
    }
}

extension PulseReconstruction {
    struct FieldRow {
        let terms: [(Int,Double)]
        let error: Double
        let budget: Double
        let weight: Double
        let adjacent: Bool
        var objectiveTolerance: Double = 0
    }
    struct FieldStep {
        let increments: [Double]
        let maximumViolation: Double
        let iterations: Int
        let feasibilityScale: Double
        let primalResidual: Double
        let dualResidual: Double
        let iterateChange: Double
    }

    /// Convex linearized field step. Residual boxes, the existing adjacent
    /// residual-energy ball and source increment boxes are joint constraints.
    /// The caller must remeasure the nonlinear renderer before accepting it.
    static func solveBoundedField(rows: [FieldRow],bounds: [(Double,Double)],
        regularization: Double = 0.001,maximumIterations: Int = 400,restoreFeasibility: Bool = false,convergenceTolerance: Double = 1e-7,boxPenalty: Double = 1) -> FieldStep? {
        let n = bounds.count,m = rows.count
        guard n > 0,m > 0,maximumIterations > 0,regularization.isFinite,regularization > 0,convergenceTolerance.isFinite,convergenceTolerance > 0,boxPenalty.isFinite,boxPenalty > 0,
              bounds.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.0 <= 0 && $0.1 >= 0 }),
              rows.allSatisfy({ row in row.error.isFinite && row.budget.isFinite && row.budget >= abs(row.error) && row.weight.isFinite && row.weight >= 0 && row.objectiveTolerance.isFinite && row.objectiveTolerance >= 0 && !row.terms.isEmpty && row.terms.allSatisfy { (0..<n).contains($0.0) && $0.1.isFinite } }) else { return nil }
        let intervalObjective = rows.contains { $0.objectiveTolerance > 0 }
        let adjacent = rows.indices.filter { rows[$0].adjacent }
        let energyLimit = adjacent.reduce(0.0) { $0+rows[$1].error*rows[$1].error }
        func forward(_ x: [Double]) -> [Double] { rows.map { row in row.terms.reduce(0.0) { $0+x[$1.0]*$1.1 } } }
        func transpose(_ y: [Double]) -> [Double] {
            var out = Array(repeating:0.0,count:n)
            for i in rows.indices { for (column,value) in rows[i].terms { out[column] += value*y[i] } }
            return out
        }
        func dot(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).reduce(0.0) { $0+$1.0*$1.1 } }
        func project(_ values: [Double],objective: Bool = false) -> [Double] {
            func boundedValue(_ i: Int,_ lambda: Double) -> Double {
                let row = rows[i],denominator = 1+lambda
                let weight = objective ? row.weight : 0
                var value = values[i]/denominator
                if weight > 0,abs(values[i]) > denominator*row.objectiveTolerance {
                    let sign = values[i] < 0 ? -1.0 : 1.0
                    value = (values[i]+sign*weight*row.objectiveTolerance)/(denominator+weight)
                }
                return max(-row.budget,min(row.budget,value))
            }
            var out = rows.indices.map { boundedValue($0,0) }
            if adjacent.reduce(0.0,{ $0+out[$1]*out[$1] }) > energyLimit {
                if energyLimit == 0 { for i in adjacent { out[i] = 0 } }
                else {
                    var low = 0.0,high = 1.0
                    func energy(_ lambda: Double) -> Double { adjacent.reduce(0.0) { sum,i in
                        let value = boundedValue(i,lambda)
                        return sum+value*value
                    } }
                    while energy(high) > energyLimit && high < 1e16 { high *= 2 }
                    for _ in 0..<60 { let middle = (low+high)/2;if energy(middle) > energyLimit { low = middle } else { high = middle } }
                    for i in adjacent { out[i] = boundedValue(i,high) }
                }
            }
            return out
        }
        // Unit residual penalty; the independent box penalty only changes
        // numerical conditioning, not the objective or feasible set.
        let diagonalBase = boxPenalty+regularization
        var diagonal = Array(repeating:diagonalBase,count:n)
        for row in rows { for (i,value) in row.terms { diagonal[i] += (1+(intervalObjective ? 0 : row.weight))*value*value } }
        func product(_ x: [Double]) -> [Double] {
            let y = forward(x).enumerated().map { (1+(intervalObjective ? 0 : rows[$0.offset].weight))*$0.element }
            let a = transpose(y)
            return x.indices.map { a[$0]+diagonalBase*x[$0] }
        }
        var x = Array(repeating:0.0,count:n),v = x,dualBox = x
        var z = rows.map(\.error),dualRows = Array(repeating:0.0,count:m)
        let objective = transpose(rows.map { intervalObjective ? 0 : -$0.weight*$0.error })
        for iteration in 1...maximumIterations {
            if Task.isCancelled { return nil }
            let rhsRows = rows.indices.map { z[$0]-dualRows[$0]-rows[$0].error }
            let rhs = transpose(rhsRows).enumerated().map { objective[$0.offset]+$0.element+boxPenalty*(v[$0.offset]-dualBox[$0.offset]) }
            let applied = product(x)
            var residual = x.indices.map { rhs[$0]-applied[$0] }
            var preconditioned = x.indices.map { residual[$0]/diagonal[$0] },direction = preconditioned
            var rz = dot(residual,preconditioned)
            // The inner solve must be more accurate than the requested outer
            // convergence. Retain the inherited threshold at default precision.
            let threshold = convergenceTolerance < 1e-7
                ? max(1e-28,dot(rhs,rhs)*convergenceTolerance*convergenceTolerance*0.01)
                : max(1e-22,dot(rhs,rhs)*1e-14)
            for _ in 0..<min(128,max(16,n*2)) {
                if dot(residual,residual) <= threshold { break }
                let a = product(direction),denominator = dot(direction,a)
                guard denominator.isFinite,denominator > 0 else { return nil }
                let step = rz/denominator
                for i in x.indices { x[i] += step*direction[i];residual[i] -= step*a[i] }
                preconditioned = x.indices.map { residual[$0]/diagonal[$0] }
                let next = dot(residual,preconditioned),beta = next/rz
                direction = x.indices.map { preconditioned[$0]+beta*direction[$0] };rz = next
            }
            guard x.allSatisfy(\.isFinite) else { return nil }
            let values = forward(x).enumerated().map { rows[$0.offset].error+$0.element }
            let previousZ = z,previousV = v
            z = project(values.indices.map { values[$0]+dualRows[$0] },objective:intervalObjective)
            v = x.indices.map { max(bounds[$0].0,min(bounds[$0].1,x[$0]+dualBox[$0])) }
            var primal = 0.0,iterateChange = 0.0
            for i in z.indices { dualRows[i] += values[i]-z[i];primal = max(primal,abs(values[i]-z[i]));iterateChange = max(iterateChange,abs(z[i]-previousZ[i])) }
            for i in v.indices { dualBox[i] += x[i]-v[i];primal = max(primal,abs(x[i]-v[i]));iterateChange = max(iterateChange,abs(v[i]-previousV[i])) }
            let residualChange = transpose(z.indices.map { z[$0]-previousZ[$0] })
            let dual = v.indices.map { abs(residualChange[$0]+boxPenalty*(v[$0]-previousV[$0])) }.max() ?? 0
            if max(primal,dual) <= convergenceTolerance || iteration == maximumIterations {
                var scale = 1.0
                if restoreFeasibility {
                    // Zero is feasible. Intersect the ray from zero to the
                    // box-clamped iterate with every residual box and the
                    // adjacent-energy ball; do not enlarge either constraint.
                    let direction = forward(v)
                    for i in rows.indices {
                        let change = direction[i]
                        if change > 0 { scale = min(scale,(rows[i].budget-rows[i].error)/change) }
                        else if change < 0 { scale = min(scale,(-rows[i].budget-rows[i].error)/change) }
                    }
                    let linear = adjacent.reduce(0.0) { $0+rows[$1].error*direction[$1] }
                    let quadratic = adjacent.reduce(0.0) { $0+direction[$1]*direction[$1] }
                    if quadratic > 0 { scale = min(scale,max(0,-2*linear/quadratic)) }
                    guard scale.isFinite else { return nil }
                    scale = max(0,min(1,scale))
                    if scale < 1 { scale *= 1-1e-9 }
                }
                let increments = v.map { $0*scale }
                let final = forward(increments).enumerated().map { rows[$0.offset].error+$0.element }
                let projected = project(final)
                let violation = zip(final,projected).map { abs($0-$1) }.max() ?? 0
                return .init(increments:increments,maximumViolation:violation,iterations:iteration,feasibilityScale:scale,primalResidual:primal,dualResidual:dual,iterateChange:iterateChange)
            }
        }
        return nil
    }
}
