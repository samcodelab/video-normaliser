// Counterfactual attribution of a retained correction field, without refitting.
// Measurements are fixed image cells, not tracked surfaces or clean-light truth.
import Foundation

@main struct CorrectionAttributionAudit {
    struct Cell: Codable {
        var sourceEV: Double
        var globalGainEV: Double
        var localContributionEV: Double
        var anchorContributionEV: Double
        var totalGainEV: Double
        var outputEV: Double
        var estimatorConfidence: Double
    }
    struct Frame: Codable { var frame: Int; var cells: [Cell] }
    struct Report: Codable {
        var diagnostics: String
        var limitation: String
        var frames: [Frame]
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw VideoError.message("Usage: diagnostics-folder output.json") }
        let folder = URL(fileURLWithPath: args[1]), decoder = JSONDecoder()
        func read<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
            try decoder.decode(type, from: Data(contentsOf: folder.appendingPathComponent(name)))
        }
        let images = try read("thumbnails.json", [SpatialThumbnail].self)
        let fields = try read("spatial-fields.json", [SpatialField].self)
        let stops = try read("global-stops.json", [Double].self)
        guard images.count == fields.count, images.count == stops.count, !images.isEmpty else {
            throw VideoError.message("Diagnostics must retain every source frame in order")
        }
        var frames: [Frame] = []
        for i in images.indices {
            let source = SpatialRenderer.predictedCells(images[i], global: 0, field: SpatialField())
            let global = SpatialRenderer.predictedCells(images[i], global: stops[i], field: SpatialField())
            var local = fields[i]; local.brightnessEV = nil; local.validationStops = nil
            let spatial = SpatialRenderer.predictedCells(images[i], global: stops[i], field: local)
            let full = SpatialRenderer.predictedCells(images[i], global: stops[i], field: fields[i])
            guard [source,global,spatial,full].allSatisfy({ $0.count == 336 && $0.allSatisfy({ $0.isFinite && $0 >= 0 }) }), fields[i].confidence.count == 336 else {
                throw VideoError.message("Invalid cell diagnostics at frame \(i)")
            }
            let cells = source.indices.map { p -> Cell in
                let s = log2(max(1e-9,source[p])), g = log2(max(1e-9,global[p]))
                let l = log2(max(1e-9,spatial[p])), f = log2(max(1e-9,full[p]))
                return Cell(sourceEV:s,globalGainEV:g-s,localContributionEV:l-g,
                            anchorContributionEV:f-l,totalGainEV:f-s,outputEV:f,
                            estimatorConfidence:fields[i].confidence[p])
            }
            frames.append(Frame(frame:i,cells:cells))
        }
        let report = Report(diagnostics:folder.path,
            limitation:"Thumbnail renderer prediction; no codec or native-resolution proof. Ordered counterfactual decomposition (source → global → local → anchor/validation), not independently refitted stages. Contributions telescope per cell; medians do not. Fixed cells include motion, reflectance and lighting. Confidence is estimator support, not physical truth or a probability. Removing brightnessEV also removes conditional tone limiting in the affine path.",frames:frames)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to:URL(fileURLWithPath:args[2]),options:.withoutOverwriting)
        print("Attributed",frames.count,"frames to",args[2])
    }
}
