// Decode a movie with the production analysis sampler; do not render correction.
import Foundation

@main struct ThumbnailDump {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw VideoError.message("Usage: movie output-thumbnails.json")
        }
        let output = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw VideoError.message("Refusing to overwrite thumbnail evidence")
        }
        let analysis = try await VideoEngine.analyse(
            url: URL(fileURLWithPath: args[1]), region: nil, progress: { _ in })
        let images = try analysis.samples.map { sample in
            guard let image = sample.thumbnail else {
                throw VideoError.message("Missing decoded thumbnail")
            }
            return image
        }
        try JSONEncoder().encode(images).write(to: output)
        print("Decoded \(images.count) thumbnails")
    }
}
