import Foundation

@main
struct PulseClockReconstructionAudit {
    struct Input: Decodable { let times: [Double]; let excursions: [Double?]; let weights: [Double] }
    struct Output: Encodable { let signal: [Double?]; let maximumResidual: Double }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain:"PulseAudit",code:1) }
        let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let input = try JSONDecoder().decode(Input.self,from:data)
        guard let result = PulseReconstruction.solve(times:input.times,excursions:input.excursions,weights:input.weights) else {
            throw NSError(domain:"PulseAudit",code:2)
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print(String(decoding:try encoder.encode(Output(signal:result.signal,maximumResidual:result.maximumResidual)),as:UTF8.self))
    }
}
