import Foundation

@main struct PersistentSolverAudit {
    struct Result: Encodable {
        let coefficients: [Double]
        let rms: Double
        let samples: Int
    }
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw VideoError.message("Usage: problem.json result.json") }
        let output = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw VideoError.message("Refusing to overwrite evidence") }
        let problem = try JSONDecoder().decode(PersistentLightingSolver.Problem.self,from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        guard let coefficients = PersistentLightingSolver.fit(problem) else { throw VideoError.message("Solver rejected problem") }
        let errors = try problem.samples.map { sample -> Double in
            guard let row = PersistentLightingSolver.response(sample,coefficients: coefficients) else { throw VideoError.message("Invalid response") }
            return row.error
        }
        let result = Result(coefficients: coefficients,rms: sqrt(errors.reduce(0) { $0+$1*$1 }/Double(errors.count)),samples: errors.count)
        try JSONEncoder().encode(result).write(to: output)
        print("Solved \(problem.count) coefficients across \(errors.count) patch transitions")
    }
}
