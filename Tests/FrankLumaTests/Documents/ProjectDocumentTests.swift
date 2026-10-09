import XCTest
import AVFoundation
import CoreImage
@testable import FrankLuma

final class ProjectDocumentTests: XCTestCase {
    func testColourStrengthDefaultsForOlderSettingsAndRoundTrips() throws {
        let older = try JSONDecoder().decode(SceneSettings.self,from: Data("{}".utf8))
        XCTAssertEqual(older.colourStrength,1)
        let settings = SceneSettings(colourStrength: 0.35)
        XCTAssertEqual(try JSONDecoder().decode(SceneSettings.self,from: JSONEncoder().encode(settings)).colourStrength,0.35)
    }

    @MainActor
    private func waitForProjectAnalysis(_ model: AppModel,file: StaticString = #filePath,line: UInt = #line) async throws {
        // Native analysis is offline work. Wait for its actual completion before
        // asserting document/preview state; unoptimised builds can take longer
        // than the former five-second preview setup allowance.
        let clock = ContinuousClock(),deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while model.busy || model.correctionPending {
            guard clock.now < deadline else {
                XCTFail("Project analysis timed out at \(model.progress): \(model.activity ?? "idle"), error \(model.error ?? "none")",file: file,line: line)
                throw NSError(domain: "ProjectAnalysisTimeout",code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func document(source: URL) throws -> ProjectDocument {
        let reference = ReferenceRegion(CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5))
        var first = SceneSettings()
        first.strength = 0.25; first.radius = 1.2; first.mode = .steady
        first.reference = reference; first.spatialStrength = 0.4
        var second = SceneSettings()
        second.strength = 0.8; second.spatialStrength = 0
        return ProjectDocument(source: ProjectSource(url: source, fingerprint: try SourceFingerprint.read(source)),
            frameCount: 12, boundaries: [6],
            scenes: [SavedScene(startFrame: 0, settings: first), SavedScene(startFrame: 6, settings: second)],
            defaults: SceneSettings(), exportOptions: .init(format: .proResMOV, quality: .standard),
            playhead: 8.0 / 24, previewMode: .sideBySide)
    }

    func testSceneBrightnessSettingDefaultsForOlderProjectsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SceneSettings.self, from: Data("{\"strength\":1,\"radius\":0.5,\"spatialStrength\":1}".utf8))
        XCTAssertTrue(legacy.preserveBrightness)
        let settings = SceneSettings(preserveBrightness: false)
        XCTAssertEqual(try JSONDecoder().decode(SceneSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testProjectRoundTripPreservesEditsAndKeepsVideoSeparate() throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        let sourceBytes = Data(repeating: 37, count: 1024 * 1024)
        try sourceBytes.write(to: source)
        var original = try document(source: source)
        original.frameExposureAdjustments = [.init(frame: 2, stops: -0.4), .init(frame: 9, stops: 0.7)]
        let file = folder.appendingPathComponent("edit.frankluma")
        try ProjectStore.write(original, to: file)
        let reopened = try ProjectStore.read(file)
        XCTAssertEqual(reopened.boundaries, original.boundaries)
        XCTAssertEqual(reopened.scenes, original.scenes)
        XCTAssertEqual(reopened.frameExposureAdjustments, original.frameExposureAdjustments)
        XCTAssertEqual(reopened.defaults, original.defaults)
        XCTAssertEqual(reopened.exportOptions, original.exportOptions)
        XCTAssertEqual(reopened.previewMode, .sideBySide)
        XCTAssertEqual(reopened.playhead, original.playhead)
        XCTAssertEqual(reopened.source.fingerprint, original.source.fingerprint)
        XCTAssertLessThan(try Data(contentsOf: file).count, 20000)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

    func testInvalidAndFutureProjectsCannotReplaceExistingProject() throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let original = try document(source: source)
        let file = folder.appendingPathComponent("edit.frankluma")
        try ProjectStore.write(original, to: file)
        let bytes = try Data(contentsOf: file)
        var invalid = original
        invalid.boundaries = [6, 6]
        XCTAssertThrowsError(try ProjectStore.write(invalid, to: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        invalid = original; invalid.scenes[0].settings.strength = 3
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.scenes[0].settings.reference = ReferenceRegion(CGRect(x: 0.9, y: 0, width: 0.5, height: 1))
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.scenes.reverse()
        XCTAssertThrowsError(try invalid.validate())
        invalid = original; invalid.version = ProjectDocument.currentVersion + 1
        let future = folder.appendingPathComponent("future.frankluma")
        try JSONEncoder().encode(invalid).write(to: future)
        XCTAssertThrowsError(try ProjectStore.read(future)) { error in
            XCTAssertEqual(error.localizedDescription, ProjectError.unsupportedVersion.localizedDescription)
        }
        let corrupt = folder.appendingPathComponent("corrupt.frankluma")
        try Data("not a project".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ProjectStore.read(corrupt))
    }

    func testLegacyProjectWithoutManualEditsLoadsAndInvalidFrameEditsAreRejected() throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let original = try document(source: source)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["version"] = 1
        json.removeValue(forKey: "frameExposureAdjustments")
        let legacy = try JSONDecoder().decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNoThrow(try legacy.validate())
        XCTAssertEqual(legacy.frameExposureAdjustments, [])
        for edits: [SavedFrameExposure] in [[.init(frame: -1, stops: 0.1)], [.init(frame: 12, stops: 0.1)],
            [.init(frame: 1, stops: 2.01)], [.init(frame: 1, stops: .nan)],
            [.init(frame: 1, stops: 0.2), .init(frame: 1, stops: 0.3)],
            [.init(frame: 2, stops: 0.2), .init(frame: 1, stops: 0.3)]] {
            var invalid = original; invalid.frameExposureAdjustments = edits
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testSourceIdentityAcceptsMovedCopyAndRejectsSameSizeDifferentVideo() throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        try Data("original video".utf8).write(to: source)
        let expected = try SourceFingerprint.read(source)
        let copy = folder.appendingPathComponent("renamed.mov")
        try FileManager.default.copyItem(at: source, to: copy)
        XCTAssertEqual(try SourceFingerprint.read(copy), expected)
        try Data("modified video".utf8).write(to: copy)
        let changed = try SourceFingerprint.read(copy)
        XCTAssertEqual(changed.byteCount, expected.byteCount)
        XCTAssertNotEqual(changed, expected)
    }

    func testRecoverySessionsStaySeparateAndDiscardRemovesOnlyChosenSession() throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        try Data("source video".utf8).write(to: source)
        let original = try document(source: source)
        let store = ProjectRecoveryStore(directory: folder.appendingPathComponent("recovery"))
        let oldID = UUID(), currentID = UUID()
        try store.write(original, id: oldID)
        var changed = original; changed.scenes[0].settings.strength = 0.75
        try store.write(changed, id: currentID)
        XCTAssertEqual(store.candidates(excluding: currentID).map { $0.resolvingSymlinksInPath() }, [store.url(for: oldID).resolvingSymlinksInPath()])
        XCTAssertEqual(try ProjectStore.read(store.url(for: currentID)).scenes[0].settings.strength, 0.75)
        XCTAssertEqual(try ProjectStore.read(store.url(for: oldID)).scenes, original.scenes)
        try store.remove(id: currentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: oldID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: currentID).path))
    }

    @MainActor
    func testReopenRebuildsReferencesRestoresSettingsAndAutosavesEdits() async throws {
        let folder = try directory(), source = folder.appendingPathComponent("source.mov")
        try await makeVideo(source)
        var saved = try document(source: source)
        saved.frameExposureAdjustments = [.init(frame: 8, stops: -0.25)]
        let file = folder.appendingPathComponent("edit.frankluma")
        try ProjectStore.write(saved, to: file)
        let recovery = ProjectRecoveryStore(directory: folder.appendingPathComponent("recovery"))
        let model = AppModel(recoveryStore: recovery)
        model.openProject(file)
        try await waitForProjectAnalysis(model)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.url?.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
        XCTAssertEqual(model.projectURL, file)
        XCTAssertEqual(model.result?.samples.count, 12)
        XCTAssertEqual(model.sceneBoundaries, [6])
        XCTAssertEqual(model.sceneSettings[0], saved.scenes[0].settings)
        XCTAssertEqual(model.sceneSettings[6], saved.scenes[1].settings)
        XCTAssertEqual(model.exportOptions, saved.exportOptions)
        XCTAssertEqual(model.previewMode, .sideBySide)
        XCTAssertEqual(model.currentFrame, 8)
        XCTAssertEqual(model.manualExposure, -0.25)
        XCTAssertEqual(model.curve.manualValue(at: model.playhead), -0.25)
        XCTAssertFalse(model.projectHasChanges)
        guard !model.projectHasChanges else { return } // Never enter a modal confirmation on regression.
        XCTAssertEqual(model.curve.stops.count, 12)
        let base = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        let reference = try XCTUnwrap(saved.scenes[0].settings.reference)
        let measured = try await VideoEngine.analyse(url: source, region: reference.rect, progress: { _ in })
        let expected = SceneCorrection.curve(base: base.samples, boundaries: [6], settings: model.sceneSettings,
                                              references: [reference: measured.samples])
        XCTAssertEqual(model.curve.stops, expected.stops)
        // A malformed open preserves the current clean session without a modal prompt.
        let bad = folder.appendingPathComponent("bad.frankluma")
        try Data("corrupt".utf8).write(to: bad)
        model.openProject(bad)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.projectURL, file)
        XCTAssertEqual(model.sceneSettings[0], saved.scenes[0].settings)
        model.error = nil
        model.strength = 0.55
        XCTAssertTrue(model.projectHasChanges)
        // Exercise the real debounce rather than invoking the write directly.
        try await Task.sleep(for: .milliseconds(900))
        let checkpoints = recovery.candidates(excluding: UUID())
        XCTAssertEqual(checkpoints.count, 1)
        let checkpoint = try ProjectStore.read(try XCTUnwrap(checkpoints.first))
        XCTAssertEqual(checkpoint.scenes[1].settings.strength, 0.55)
        XCTAssertEqual(checkpoint.frameExposureAdjustments, saved.frameExposureAdjustments)
        XCTAssertEqual(try ProjectStore.read(file).scenes, saved.scenes, "Autosave must not overwrite the saved project")
        XCTAssertTrue(model.saveProject())
        XCTAssertFalse(model.projectHasChanges)
        XCTAssertTrue(recovery.candidates(excluding: UUID()).isEmpty)
        XCTAssertEqual(try ProjectStore.read(file).scenes[1].settings.strength, 0.55)
        let recoveryID = UUID()
        try recovery.write(checkpoint, id: recoveryID)
        let restored = AppModel(recoveryStore: recovery)
        XCTAssertTrue(restored.recoveryAvailable)
        restored.restoreRecovery(recovery.url(for: recoveryID))
        try await waitForProjectAnalysis(restored)
        XCTAssertNil(restored.error)
        XCTAssertNil(restored.projectURL, "Recovered work must be saved explicitly")
        XCTAssertTrue(restored.projectHasChanges)
        XCTAssertFalse(restored.recoveryAvailable, "The active session must not offer its own checkpoint")
        XCTAssertEqual(restored.sceneSettings[6]?.strength, 0.55)
        XCTAssertEqual(restored.sceneSettings[0]?.reference, reference)
        XCTAssertEqual(restored.exportOptions, saved.exportOptions)
        XCTAssertEqual(restored.frameExposureAdjustments, [8: -0.25])
        restored.closeSession()
        XCTAssertNil(restored.result)
        XCTAssertFalse(restored.projectHasChanges)
        XCTAssertTrue(recovery.candidates(excluding: UUID()).isEmpty)
        model.closeSession()
    }

    @MainActor
    func testNearbyPreviewRefreshesEditedFrameAndReusesNeighbours() async throws {
        let folder = try directory(), source = folder.appendingPathComponent("nearby.mov")
        try await makeVideo(source)
        let file = folder.appendingPathComponent("nearby.frankluma")
        try ProjectStore.write(document(source: source), to: file)
        let model = AppModel(recoveryStore: ProjectRecoveryStore(directory: folder.appendingPathComponent("recovery")))
        defer { model.closeSession() }
        model.openProject(file)
        try await waitForProjectAnalysis(model)
        XCTAssertNil(model.error)
        model.showNearbyFrames = true
        func waitForFrames(_ frames: Set<Int>) async throws {
            for _ in 0..<500 {
                if Set(model.nearbyFrameImages.keys) == frames { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Nearby previews did not finish: \(model.nearbyFrameError ?? "no error")")
        }
        try await waitForFrames([6,7,8,9,10])
        let before = try XCTUnwrap(model.nearbyFrameImages[8])
        let neighbour = try XCTUnwrap(model.nearbyFrameImages[9])
        func light(_ frame: CGImage) -> Float {
            let cs = CGColorSpace(name: CGColorSpace.linearSRGB)!
            let context = CIContext(options: [.workingColorSpace: cs])
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: frame), toBitmap: $0.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: frame.width/2, y: frame.height/2, width: 1, height: 1), format: .RGBAf, colorSpace: cs)
            }
            return pixel[0]
        }
        model.manualExposure = -1
        try await waitForFrames([6,7,8,9,10])
        let after = try XCTUnwrap(model.nearbyFrameImages[8])
        XCTAssertEqual(light(after), light(before) * 0.5, accuracy: 0.005)
        XCTAssertTrue(neighbour === model.nearbyFrameImages[9], "Unchanged neighbour should retain its cached image")
        model.seekFrame(9)
        try await waitForFrames([7,8,9,10,11])
        XCTAssertTrue(after === model.nearbyFrameImages[8])
        model.nearbyFramesCorrected = false
        try await waitForFrames([7,8,9,10,11])
        XCTAssertGreaterThan(light(try XCTUnwrap(model.nearbyFrameImages[8])), light(after))
        model.showNearbyFrames = false
        XCTAssertTrue(model.nearbyFrameImages.isEmpty)
    }

    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 192, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 192, kCVPixelBufferHeightKey as String: 128])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProjectError.invalidSource }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 192, 128, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<128 { for x in 0..<192 {
                let i = y * stride + x * 4
                let value = UInt8((frame.isMultiple(of: 2) ? 90 : 125) + x / 24)
                data[i] = value; data[i + 1] = value; data[i + 2] = value; data[i + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
