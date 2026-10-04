import Foundation

/// Retain for the whole lifetime of the player or asynchronous operation using
/// this URL. A false return is normal for URLs already covered by the sandbox
/// (including some Open/Save panel URLs); file operations report real failures.
final class SecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

/// Stage on the destination's volume using the system-provided replacement
/// directory. Selecting a filename doesn't grant access to arbitrary siblings.
final class ExportStaging {
    let directory: URL
    let file: URL

    init(destination: URL) throws {
        directory = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: destination, create: true)
        file = directory.appendingPathComponent("FrankLuma-\(UUID().uuidString).mov")
    }

    func commit(to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
