import Foundation
import CryptoKit
import UniformTypeIdentifiers

extension UTType {
    static let frankLumaProject = UTType(exportedAs: "com.sam.frankluma.project", conformingTo: .data)
}

struct ProjectSourceStamp: Equatable, Sendable {
    let byteCount: Int
    let modified: Date?

    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw ProjectError.invalidSource
        }
        return Self(byteCount: size, modified: values.contentModificationDate)
    }
}

struct SourceFingerprint: Codable, Equatable, Sendable {
    let byteCount: Int
    let sha256: String

    static func read(_ url: URL) throws -> Self {
        let before = try ProjectSourceStamp.read(url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var count = 0
        while true {
            try Task.checkCancellation()
            let data = try file.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
            count += data.count
        }
        guard before == (try ProjectSourceStamp.read(url)), count == before.byteCount else {
            throw ProjectError.sourceChanged
        }
        return Self(byteCount: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

struct ProjectSource: Codable, Sendable {
    var path: String
    var bookmark: Data?
    var fingerprint: SourceFingerprint
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    init(url: URL, fingerprint: SourceFingerprint) {
        path = url.path
        // A missing bookmark is recoverable: the user can locate the source.
        bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        self.fingerprint = fingerprint
    }

    func resolve() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL {
                // Recreate the bookmark after loading, including stale bookmarks.
                return url
            }
        }
        return URL(fileURLWithPath: path)
    }
}

struct SavedScene: Codable, Equatable, Sendable {
    var startFrame: Int
    var settings: SceneSettings
}

struct SavedFrameExposure: Codable, Equatable, Sendable {
    var frame: Int
    var stops: Double
}

struct ProjectDocument: Codable, Sendable {
    static let currentVersion = 2
    var kind = "com.sam.frankluma.project"
    var version = currentVersion
    var source: ProjectSource
    var frameCount: Int
    var boundaries: [Int]
    var scenes: [SavedScene]
    var defaults: SceneSettings
    var exportOptions: VideoExportOptions
    var playhead: Double
    var previewMode: PreviewMode
    var frameExposureAdjustments: [SavedFrameExposure] = []

    enum CodingKeys: String, CodingKey {
        case kind, version, source, frameCount, boundaries, scenes, defaults, exportOptions, playhead, previewMode, frameExposureAdjustments
    }

    init(source: ProjectSource, frameCount: Int, boundaries: [Int], scenes: [SavedScene], defaults: SceneSettings,
         exportOptions: VideoExportOptions, playhead: Double, previewMode: PreviewMode,
         frameExposureAdjustments: [SavedFrameExposure] = []) {
        self.source = source; self.frameCount = frameCount; self.boundaries = boundaries; self.scenes = scenes
        self.defaults = defaults; self.exportOptions = exportOptions; self.playhead = playhead; self.previewMode = previewMode
        self.frameExposureAdjustments = frameExposureAdjustments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        version = try values.decode(Int.self, forKey: .version)
        source = try values.decode(ProjectSource.self, forKey: .source)
        frameCount = try values.decode(Int.self, forKey: .frameCount)
        boundaries = try values.decode([Int].self, forKey: .boundaries)
        scenes = try values.decode([SavedScene].self, forKey: .scenes)
        defaults = try values.decode(SceneSettings.self, forKey: .defaults)
        exportOptions = try values.decode(VideoExportOptions.self, forKey: .exportOptions)
        playhead = try values.decode(Double.self, forKey: .playhead)
        previewMode = try values.decode(PreviewMode.self, forKey: .previewMode)
        frameExposureAdjustments = try values.decodeIfPresent([SavedFrameExposure].self, forKey: .frameExposureAdjustments) ?? []
    }

    func validate() throws {
        guard kind == "com.sam.frankluma.project", (1...Self.currentVersion).contains(version) else {
            throw ProjectError.unsupportedVersion
        }
        let editedFrames = frameExposureAdjustments.map(\.frame)
        guard editedFrames == editedFrames.sorted(), Set(editedFrames).count == editedFrames.count,
              frameExposureAdjustments.allSatisfy({ $0.frame >= 0 && $0.frame < frameCount && $0.stops.isFinite && (-2...2).contains($0.stops) }),
              version >= 2 || frameExposureAdjustments.isEmpty else { throw ProjectError.invalidDocument }
        let starts = [0] + boundaries
        guard frameCount > 0, boundaries == boundaries.sorted(), Set(boundaries).count == boundaries.count,
              boundaries.allSatisfy({ $0 > 0 && $0 < frameCount }),
              scenes.map(\.startFrame) == starts,
              playhead.isFinite, playhead >= 0,
              source.path.hasPrefix("/"), !source.name.isEmpty,
              source.fingerprint.byteCount > 0, source.fingerprint.sha256.count == 64,
              source.fingerprint.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              (source.bookmark?.count ?? 0) <= 1024 * 1024 else {
            throw ProjectError.invalidDocument
        }
        for settings in [defaults] + scenes.map(\.settings) {
            guard settings.strength.isFinite, (0...1).contains(settings.strength),
                  settings.spatialStrength.isFinite, (0...1).contains(settings.spatialStrength),
                  settings.colourStrength.isFinite, (0...1).contains(settings.colourStrength),
                  settings.radius.isFinite, (0.1...3).contains(settings.radius) else {
                throw ProjectError.invalidDocument
            }
            if let region = settings.reference {
                guard [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite),
                      region.x >= 0, region.y >= 0, region.width >= 0.03, region.height >= 0.03,
                      region.x + region.width <= 1.000001, region.y + region.height <= 1.000001 else {
                    throw ProjectError.invalidDocument
                }
            }
        }
    }
}

enum ProjectError: LocalizedError {
    case invalidDocument, unsupportedVersion, invalidSource, sourceChanged, differentSource
    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "This project contains invalid editing settings. The current session has not been replaced."
        case .unsupportedVersion: return "This project uses an unsupported format. Try opening it with a newer version of FrankLuma."
        case .invalidSource: return "The source video is missing or unreadable. Locate the original video to reopen this project."
        case .sourceChanged: return "The source video changed during this session. Open it again before saving or applying edits."
        case .differentSource: return "This video does not match the project's original source. Locate the original video or an identical copy."
        }
    }
}

enum ProjectStore {
    static let maximumBytes = 8 * 1024 * 1024

    static func read(_ url: URL) throws -> ProjectDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw ProjectError.invalidDocument }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw ProjectError.invalidDocument }
        do {
            let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
            try document.validate()
            return document
        } catch let error as ProjectError { throw error }
        catch { throw ProjectError.invalidDocument }
    }

    static func write(_ document: ProjectDocument, to url: URL) throws {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw ProjectError.invalidDocument }
        // Stage on the destination volume, preserving an existing project on failure.
        let staging = try ExportStaging(destination: url)
        try data.write(to: staging.file, options: .atomic)
        try staging.commit(to: url)
    }
}

/// Each editing session has its own checkpoint. Starting another session cannot
/// overwrite an unresolved recovery from a previous launch.
struct ProjectRecoveryStore {
    let directory: URL
    static var standard: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: root.appendingPathComponent("FrankLuma/Recovery", isDirectory: true))
    }

    func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".frankluma") }

    func write(_ document: ProjectDocument, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectStore.write(document, to: url(for: id))
    }

    func remove(id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func candidates(excluding id: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                      includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "frankluma" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != id }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }
}
