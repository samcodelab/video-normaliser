import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var projectURL: URL?
    @Published private(set) var projectHasChanges = false
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var recoveryWarning: String?
    @Published var exportOptions = VideoExportOptions(format: .h264MP4) {
        didSet {
            if exportOptions != oldValue, !installingProject, result != nil { projectEdited() }
        }
    }
    private let recoveryStore: ProjectRecoveryStore
    private var recoveryID = UUID()
    private var checkpointTask: Task<Void, Never>?
    private var projectAccess: SecurityScopedAccess?
    private var projectSource: ProjectSource?
    private var sourceStamp: ProjectSourceStamp?
    private var installingProject = false
    private var checkedRecovery = false
    var projectTitle: String {
        let name = projectURL?.lastPathComponent ?? url?.lastPathComponent ?? "FrankLuma"
        return name + (projectHasChanges ? " — Edited" : "")
    }
    @Published var url: URL?
    @Published var info: VideoInfo?
    @Published var player = AVPlayer()
    @Published var result: AnalysisResult?
    @Published var curve = ExposureCurve.empty
    @Published var exposureComparison = ExposureComparison.empty
    @Published var sceneBoundaries: Set<Int> = []
    @Published var sceneSettings: [Int: SceneSettings] = [:]
    @Published var stablePatchCounts: [Int: Int] = [:]
    @Published var selectedSceneStart = 0
    @Published var defaults = SceneSettings()
    @Published var previewMode: PreviewMode = .corrected
    var corrected: Bool { previewMode != .original }
    var comparisonSize: CGSize? {
        guard previewMode == .sideBySide, let info else { return nil }
        return CGSize(width: info.width, height: info.height)
    }
    @Published var selectingRegion = false
    @Published var activity: String?
    @Published var progress = 0.0
    @Published var error: String?
    @Published var exportedURL: URL?
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var stillImage: CGImage?
    @Published var previewError: String?
    private var task: Task<Void, Never>?
    private var stillTask: Task<Void, Never>?
    private var asset: AVURLAsset?
    private var sourceAccess: SecurityScopedAccess?
    private var timeObserver: Any?
    private var playbackObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stillGeneration = 0
    private let previewCorrection = PreviewCorrection()
    private var referenceResults: [ReferenceRegion: [ExposureSample]] = [:]
    var busy: Bool { activity != nil }
    var scenes: [VideoScene] {
        SceneMath.scenes(samples: result?.samples ?? [], boundaries: sceneBoundaries, duration: info?.duration ?? 0)
    }
    var selectedScene: VideoScene? { scenes.first { $0.startFrame == selectedSceneStart } }
    var settings: SceneSettings { sceneSettings[selectedSceneStart] ?? defaults }
    var region: CGRect? { settings.reference?.rect }
    var currentFrame: Int { TimelineMath.frame(at: playhead, samples: result?.samples ?? []) }
    var strength: Double {
        get { settings.strength }
        set { changeSettings { $0.strength = newValue } }
    }
    var radius: Double {
        get { settings.radius }
        set { changeSettings { $0.radius = newValue } }
    }
    var spatialStrength: Double {
        get { settings.spatialStrength }
        set { changeSettings { $0.spatialStrength = newValue } }
    }
    var mode: NormalisationMode {
        get { settings.mode }
        set { changeSettings { $0.mode = newValue } }
    }

    init(recoveryStore: ProjectRecoveryStore = .standard) {
        self.recoveryStore = recoveryStore
        recoveryAvailable = !recoveryStore.candidates(excluding: recoveryID).isEmpty
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.setPlayhead(time.seconds)
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = playing
                if !playing && wasPlaying { self.setPlayhead(self.player.currentTime().seconds); self.refreshStill() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.seekFrame((self.result?.samples.count ?? 1) - 1)
            }
        }
    }

    private func changeSettings(_ edit: (inout SceneSettings) -> Void) {
        var options = settings
        edit(&options)
        if result == nil { defaults = options } else { sceneSettings[selectedSceneStart] = options }
        updateCurve()
    }

    func applySettingsToAllScenes() {
        let options = settings
        for scene in scenes { sceneSettings[scene.startFrame] = options }
        updateCurve()
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a stop-motion video to normalise."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ newURL: URL) {
        if newURL.pathExtension.lowercased() == "frankluma" { openProject(newURL); return }
        guard !busy else { return }
        guard newURL.isFileURL else {
            error = "Choose a video file on your Mac using Open video."
            return
        }
        guard confirmLeavingSession() else { return }
        let access = SecurityScopedAccess(newURL)
        activity = "Opening video"
        progress = 0
        player.pause()
        stillTask?.cancel()
        task = Task { [sourceAccess] in
            defer { withExtendedLifetime(sourceAccess) {} }
            do {
                let asset = AVURLAsset(url: newURL)
                let info = try await VideoEngine.info(for: asset)
                try MediaSupport.validate(info)
                try Task.checkCancellation()
                finishSession()
                projectURL = nil; projectAccess = nil; projectSource = nil; sourceStamp = nil
                recoveryID = UUID(); projectHasChanges = false
                result = nil; sceneBoundaries = []; sceneSettings = [:]; referenceResults = [:]; stablePatchCounts = [:]
                selectedSceneStart = 0; curve = .empty; exposureComparison = .empty; defaults.reference = nil
                installVideo(asset: asset, url: newURL, info: info, access: access)

            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            activity = nil
        }
    }

    func analyse() {
        guard let url, !busy else { return }
        player.pause(); selectingRegion = false
        activity = "Detecting scenes and analysing exposure"; progress = 0; exportedURL = nil
        task = Task { [sourceAccess] in
            defer { withExtendedLifetime(sourceAccess) {} }
            do {
                let worker = Task.detached(priority: .userInitiated) { [self] in
                    let stamp = try ProjectSourceStamp.read(url)
                    let analysis = try await VideoEngine.analyse(url: url, region: nil) { value in
                        Task { @MainActor in self.progress = value * 0.9 }
                    }
                    let fingerprint = try SourceFingerprint.read(url)
                    guard stamp == (try ProjectSourceStamp.read(url)) else { throw ProjectError.sourceChanged }
                    return (analysis, fingerprint, stamp)
                }
                let (analysis, fingerprint, stamp) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                projectSource = ProjectSource(url: url, fingerprint: fingerprint)
                sourceStamp = stamp
                let sameFrames = result?.samples.map(\.time) == analysis.samples.map(\.time)
                result = analysis
                if !sameFrames {
                    sceneBoundaries = SceneMath.boundaries(in: analysis.samples)
                    sceneSettings = Dictionary(uniqueKeysWithValues: scenes.map { ($0.startFrame, defaults) })
                    referenceResults = [:]
                }
                setPlayhead(playhead)
                updateCurve()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            activity = nil
        }
    }

    func beginRegionSelection() {
        player.pause()
        if previewMode.isDiagnostic { previewMode = .corrected; updatePreviewLayout() }
        selectingRegion.toggle()
        refreshStill()
    }

    func setRegion(_ newRegion: CGRect?) {
        selectingRegion = false
        guard let newRegion else { changeSettings { $0.reference = nil }; return }
        guard let url, result != nil, !busy else { return }
        let reference = ReferenceRegion(newRegion)
        if referenceResults[reference] != nil { changeSettings { $0.reference = reference }; return }
        let targetScene = selectedSceneStart
        activity = "Measuring reference for scene \(selectedScene?.number ?? 1)"; progress = 0
        task = Task { [sourceAccess] in
            defer { withExtendedLifetime(sourceAccess) {} }
            do {
                let worker = Task.detached(priority: .userInitiated) { [self] in
                    try await VideoEngine.analyse(url: url, region: newRegion) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }
                let analysis = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard analysis.samples.map(\.time) == result?.samples.map(\.time) else {
                    throw VideoError.message("The source video changed. Open it again before setting a reference.")
                }
                referenceResults[reference] = analysis.samples
                var options = sceneSettings[targetScene] ?? defaults
                options.reference = reference
                sceneSettings[targetScene] = options
                updateCurve()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            activity = nil
        }
    }

    func updateCurve(markEdited: Bool = true) {
        guard let result else { return }
        curve = SceneCorrection.curve(base: result.samples, boundaries: sceneBoundaries,
                                      settings: sceneSettings, references: referenceResults)
        exposureComparison = SceneCorrection.exposure(base: result.samples, boundaries: sceneBoundaries,
                                                      settings: sceneSettings, references: referenceResults, curve: curve)
        stablePatchCounts = Dictionary(uniqueKeysWithValues: scenes.map { scene in
            let reference = sceneSettings[scene.startFrame]?.reference
            let source = reference.flatMap { referenceResults[$0] } ?? result.samples
            let frames = source[scene.startFrame..<(scene.startFrame + scene.frameCount)]
            return (scene.startFrame, PatchExposure(cells: frames.map(\.cells)).values.first?.count ?? 0)
        })
        exportedURL = nil
        updatePreview()
        if markEdited { projectEdited() }
    }

    func splitAtPlayhead() {
        guard let result, !busy else { return }
        player.pause()
        let index = TimelineMath.frame(at: playhead, samples: result.samples)
        guard index > 0, !sceneBoundaries.contains(index) else { return }
        let inherited = settings
        sceneBoundaries.insert(index)
        sceneSettings[index] = inherited
        selectedSceneStart = index
        updateCurve()
    }

    func moveBoundary(from old: Int, to time: Double) {
        guard let result, sceneBoundaries.contains(old), !busy else { return }
        let frame = TimelineMath.nearestFrame(at: time, samples: result.samples)
        moveBoundary(from: old, toFrame: frame)
    }

    func moveBoundary(from old: Int, toFrame proposed: Int) {
        guard let result, sceneBoundaries.contains(old), !busy else { return }
        let new = TimelineMath.clampedBoundary(proposed, moving: old, boundaries: sceneBoundaries, frameCount: result.samples.count)
        guard new != old else { return }
        let options = sceneSettings.removeValue(forKey: old) ?? defaults
        sceneBoundaries.remove(old); sceneBoundaries.insert(new)
        sceneSettings[new] = options
        if selectedSceneStart == old { selectedSceneStart = new }
        updateCurve()
        seekFrame(new)
    }

    func removeBoundary(at index: Int) {
        guard !busy else { return }
        sceneBoundaries.remove(index)
        sceneSettings.removeValue(forKey: index)
        setPlayhead(playhead)
        updateCurve()
    }

    func resetBoundaries() {
        guard let result else { return }
        let oldScenes = scenes, oldSettings = sceneSettings
        sceneBoundaries = SceneMath.boundaries(in: result.samples)
        sceneSettings = Dictionary(uniqueKeysWithValues: scenes.map { scene in
            let old = oldScenes.last { $0.startFrame <= scene.startFrame }
            return (scene.startFrame, old.flatMap { oldSettings[$0.startFrame] } ?? defaults)
        })
        setPlayhead(playhead)
        updateCurve()
    }

    private func setPlayhead(_ time: Double) {
        guard time.isFinite else { return }
        playhead = max(0, min(info?.duration ?? 0, time))
        if let scene = scenes.last(where: { $0.start <= playhead + 0.000001 }) {
            selectedSceneStart = scene.startFrame
        }
    }

    func seek(to scene: VideoScene) { seekFrame(scene.startFrame) }

    func seek(toTime time: Double) {
        if let result { seekFrame(TimelineMath.nearestFrame(at: time, samples: result.samples)) }
        else { seekTime(max(0, min((info?.duration ?? 0) - 0.001, time))) }
    }

    func seekFrame(_ index: Int) {
        guard let result, !result.samples.isEmpty else { return }
        let index = min(result.samples.count - 1, max(0, index))
        seekTime(result.samples[index].time)
    }

    private func seekTime(_ time: Double) {
        player.pause(); isPlaying = false
        setPlayhead(time)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        refreshStill()
    }

    func stepFrame(_ count: Int) {
        if result != nil { seekFrame(currentFrame + count) }
        else { seek(toTime: playhead + Double(count) / max(1, info?.fps ?? 24)) }
    }

    func togglePlayback() {
        guard !busy, info != nil else { return }
        if isPlaying { player.pause(); isPlaying = false; setPlayhead(player.currentTime().seconds); refreshStill() }
        else {
            if let result, currentFrame >= result.samples.count - 1 { seekFrame(0) }
            selectingRegion = false
            stillTask?.cancel()
            player.play()
            isPlaying = true
        }
    }

    func updatePreview() {
        previewCorrection.set(corrected ? curve : .empty)
        refreshStill()
    }

    func updatePreviewLayout() {
        guard let asset else { return }
        player.pause(); isPlaying = false
        previewCorrection.set(corrected ? curve : .empty)
        player.currentItem?.videoComposition = VideoEngine.liveComposition(asset: asset, state: previewCorrection, comparisonSize: comparisonSize, diagnostic: previewMode)
        stillImage = nil
        seekTime(playhead)
    }

    private func refreshStill() {
        guard let url, !isPlaying else { return }
        stillTask?.cancel()
        stillGeneration += 1
        let generation = stillGeneration
        let time = result.map { $0.samples[TimelineMath.frame(at: playhead, samples: $0.samples)].time } ?? playhead
        let frameEnd = result.flatMap { result -> Double? in
            let index = TimelineMath.frame(at: playhead, samples: result.samples)
            return index + 1 < result.samples.count ? result.samples[index + 1].time : info?.duration
        }
        let snapshot = corrected ? curve : .empty
        let size = comparisonSize
        let diagnostic = previewMode
        stillTask = Task { [sourceAccess] in
            defer { withExtendedLifetime(sourceAccess) {} }
            do {
                try await Task.sleep(for: .milliseconds(35))
                let image = try await VideoEngine.preview(url: url, time: time, curve: snapshot, comparisonSize: size, diagnostic: diagnostic, frameEnd: frameEnd)
                try Task.checkCancellation()
                guard generation == stillGeneration else { return }
                stillImage = image; previewError = nil
            } catch is CancellationError { }
            catch {
                guard generation == stillGeneration else { return }
                previewError = error.localizedDescription
            }
        }
    }

    func exportDiagnostics() {
        guard let result, let url, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " — Diagnostics.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let access = SecurityScopedAccess(destination)
        defer { withExtendedLifetime(access) {} }
        do {
            struct FrameLog: Encodable {
                let frame: Int
                let time: Double
                let globalEV: Double
                let globalGain: Double
                let sceneStartFrame: Int
                let spatial: SpatialField?
                let unmaskedAffineMeanEstimate: [Double]
            }
            let frames = result.samples.enumerated().map { index, sample in
                let field = curve.field(at: sample.time)
                let global = curve.value(at: sample.time)
                let sceneStart = sceneBoundaries.filter { $0 <= index }.max() ?? 0
                let predicted: [Double] = field.map { f in f.before.indices.map { p -> Double in
                    let x = (Double(p % f.sampleColumns) + 0.5) / Double(f.sampleColumns)
                    let y = (Double(p / f.sampleColumns) + 0.5) / Double(f.sampleRows)
                    return f.before[p] * pow(2, global + f.applied[p]) + f.offset(x: x, y: y)
                } } ?? []
                return FrameLog(frame: index, time: sample.time, globalEV: global, globalGain: pow(2, global),
                                sceneStartFrame: sceneStart, spatial: field, unmaskedAffineMeanEstimate: predicted)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(frames).write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    func export() {
        guard let asset, let url, result != nil, !busy else { return }
        let panel = NSSavePanel()
        let selection = ExportSelection(options: exportOptions)
        let baseName = url.deletingPathExtension().lastPathComponent + " — Normalised"
        func updatePanel(_ format: ExportFormat) {
            panel.allowedContentTypes = [format.isMP4 ? .mpeg4Movie : .quickTimeMovie]
            let currentName = panel.nameFieldStringValue
            let stem = currentName.isEmpty ? baseName : (currentName as NSString).deletingPathExtension
            panel.nameFieldStringValue = stem + "." + format.fileExtension
        }
        panel.nameFieldStringValue = baseName + "." + selection.options.format.fileExtension
        updatePanel(selection.options.format)
        panel.message = "Export corrected SDR video. MP4 preserves AAC audio; other audio is converted to AAC (multichannel audio becomes stereo). QuickTime preserves original audio."
        let accessory = NSHostingView(rootView: ExportOptionsView(selection: selection, formatChanged: updatePanel))
        accessory.frame = NSRect(x: 0, y: 0, width: 430, height: 125)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else {
            error = "Choose a different filename so the source video is preserved."
            return
        }
        exportOptions = selection.options
        let options = selection.options
        player.pause()
        activity = "Exporting corrected video"
        progress = 0
        let exportCurve = curve
        let destinationAccess = SecurityScopedAccess(destination)
        task = Task { [sourceAccess] in
            defer { withExtendedLifetime((sourceAccess, destinationAccess)) {} }
            do {
                let staging = try ExportStaging(destination: destination)
                defer { withExtendedLifetime(staging) {} }
                try await VideoEngine.export(asset: asset, curve: exportCurve, destination: staging.file, options: options) { [self] value in
                    Task { @MainActor in self.progress = value }
                }
                try Task.checkCancellation()
                try staging.commit(to: destination)
                exportedURL = destination
            } catch is CancellationError { }
            catch { self.error = MediaSupport.exportFailure(error) }
            activity = nil
        }
    }

    func confirmLeavingSession() -> Bool {
        if busy {
            let alert = NSAlert()
            alert.messageText = "An operation is still running"
            alert.informativeText = "Wait for it to finish, or use Cancel before closing this session."
            alert.addButton(withTitle: "Keep Working")
            alert.runModal()
            return false
        }
        guard projectHasChanges else { return true }
        flushCheckpoint()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to this project?"
        alert.informativeText = "Save your scene cuts, reference areas and correction settings so you can resume later. Exporting a video does not save an editable project."
        alert.addButton(withTitle: "Save Project")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func openDemo() {
        guard let demo = Bundle.main.url(forResource: "FrankLuma Demo", withExtension: "mov") else {
            error = "The demo is unavailable in this build. Open the packaged FrankLuma app to use the included demo."
            return
        }
        open(demo)
    }

    func cancel() { task?.cancel() }
}


@MainActor
private final class ExportSelection: ObservableObject {
    @Published var options: VideoExportOptions
    init(options: VideoExportOptions) { self.options = options }
}

private struct ExportOptionsView: View {
    @ObservedObject var selection: ExportSelection
    let formatChanged: (ExportFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Format", selection: $selection.options.format) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .onChange(of: selection.options.format) { _, format in formatChanged(format) }
            Picker("Quality", selection: $selection.options.quality) {
                ForEach(ExportQuality.allCases, id: \.self) { quality in Text(quality.rawValue).tag(quality) }
            }
            .disabled(selection.options.format == .proResMOV)
            Text(selection.options.format == .proResMOV
                 ? "ProRes 422 uses higher precision and produces large files for editing."
                 : "High quality produces larger files. Video is re-encoded.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}


extension AppModel {
    private func installVideo(asset: AVURLAsset, url: URL, info: VideoInfo, access: SecurityScopedAccess) {
        self.asset = asset; self.url = url; self.info = info
        sourceAccess = access
        selectingRegion = false; exportedURL = nil; stillImage = nil; previewError = nil; playhead = 0
        previewCorrection.set(corrected ? curve : .empty)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = VideoEngine.liveComposition(asset: asset, state: previewCorrection,
                                                            comparisonSize: comparisonSize, diagnostic: previewMode)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let message = item.error?.localizedDescription ?? "The video preview could not be loaded."
                Task { @MainActor in self?.previewError = message }
            }
        }
        player.replaceCurrentItem(with: item)
        refreshStill()
    }

    func chooseProject() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.frankLumaProject]
        panel.allowsMultipleSelection = false
        panel.message = "Open a FrankLuma project to resume editing."
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    private func snapshot() throws -> ProjectDocument {
        guard let projectSource, let result, !result.samples.isEmpty else { throw ProjectError.invalidDocument }
        let starts = [0] + sceneBoundaries.sorted()
        return ProjectDocument(source: projectSource, frameCount: result.samples.count,
            boundaries: sceneBoundaries.sorted(),
            scenes: starts.map { SavedScene(startFrame: $0, settings: sceneSettings[$0] ?? defaults) },
            defaults: defaults, exportOptions: exportOptions, playhead: playhead, previewMode: previewMode)
    }

    @discardableResult
    func saveProject(asCopy: Bool = false) -> Bool {
        guard !busy, result != nil, let sourceURL = url else { return false }
        var destination = asCopy ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.frankLumaProject]
            panel.nameFieldStringValue = (projectURL ?? sourceURL).deletingPathExtension().lastPathComponent + ".frankluma"
            panel.message = "Save editable settings. Keep the original video; it is linked, not copied into the project."
            guard panel.runModal() == .OK, let selected = panel.url else { return false }
            destination = selected
        }
        guard let destination else { return false }
        let access = SecurityScopedAccess(destination)
        do {
            guard destination.resolvingSymlinksInPath().standardizedFileURL != sourceURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw VideoError.message("Choose a different filename so the source video is preserved.")
            }
            guard sourceStamp == (try ProjectSourceStamp.read(sourceURL)) else { throw ProjectError.sourceChanged }
            var document = try snapshot()
            document.source = ProjectSource(url: sourceURL, fingerprint: document.source.fingerprint)
            try ProjectStore.write(document, to: destination)
            projectSource = document.source; projectURL = destination; projectAccess = access
            projectHasChanges = false
            clearCheckpoint()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func openProject(_ file: URL) {
        guard !busy, file.isFileURL else { return }
        let access = SecurityScopedAccess(file)
        do {
            let document = try ProjectStore.read(file)
            guard confirmLeavingSession() else { return }
            loadProject(document, file: file, access: access)
        } catch { self.error = error.localizedDescription }
    }

    private func locateSource(_ source: ProjectSource) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.message = "Locate \(source.name) or an identical copy. Saved edits require the original video."
        panel.prompt = "Relink Video"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func relinkSource() {
        guard !busy, result != nil else { return }
        do {
            let document = try snapshot()
            guard let source = locateSource(document.source) else { return }
            loadProject(document, file: projectURL, access: projectAccess, sourceOverride: source)
        } catch { self.error = error.localizedDescription }
    }

    private func loadProject(_ document: ProjectDocument, file: URL?, access: SecurityScopedAccess?,
                             sourceOverride: URL? = nil, recovering id: UUID? = nil) {
        var candidate = sourceOverride ?? document.source.resolve()
        var sourceAccess = SecurityScopedAccess(candidate)
        if !FileManager.default.isReadableFile(atPath: candidate.path) {
            guard let located = locateSource(document.source) else { return }
            candidate = located
            sourceAccess = SecurityScopedAccess(candidate)
        }
        let sourceURL = candidate, sourceScope = sourceAccess
        let relinked = sourceURL.resolvingSymlinksInPath().standardizedFileURL != URL(fileURLWithPath: document.source.path).resolvingSymlinksInPath().standardizedFileURL || sourceOverride != nil
        activity = "Reopening project and checking source"; progress = 0
        player.pause(); stillTask?.cancel()
        task = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { [sourceScope] in
                    defer { withExtendedLifetime(sourceScope) {} }
                    let stamp = try ProjectSourceStamp.read(sourceURL)
                    let fingerprint = try SourceFingerprint.read(sourceURL)
                    guard fingerprint == document.source.fingerprint else { throw ProjectError.differentSource }
                    let asset = AVURLAsset(url: sourceURL)
                    let info = try await VideoEngine.info(for: asset)
                    try MediaSupport.validate(info)
                    let regions = Array(Set(document.scenes.compactMap { $0.settings.reference }))
                    let steps = Double(1 + regions.count)
                    let analysis = try await VideoEngine.analyse(url: sourceURL, region: nil) { value in
                        Task { @MainActor in self.progress = value / steps }
                    }
                    guard analysis.samples.count == document.frameCount else { throw ProjectError.differentSource }
                    var references: [ReferenceRegion: [ExposureSample]] = [:]
                    for (index, region) in regions.enumerated() {
                        try Task.checkCancellation()
                        let measured = try await VideoEngine.analyse(url: sourceURL, region: region.rect) { value in
                            Task { @MainActor in self.progress = (Double(index + 1) + value) / steps }
                        }
                        guard measured.samples.map(\.time) == analysis.samples.map(\.time) else { throw ProjectError.sourceChanged }
                        references[region] = measured.samples
                    }
                    guard stamp == (try ProjectSourceStamp.read(sourceURL)) else { throw ProjectError.sourceChanged }
                    return (info, analysis, references, stamp)
                }
                let (info, analysis, references, stamp) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                // Commit only after all source checks and reference measurements
                // succeed. Errors and cancellation retain the existing session.
                finishSession()
                installingProject = true
                projectURL = file; projectAccess = access
                recoveryID = id ?? UUID()
                projectSource = ProjectSource(url: sourceURL, fingerprint: document.source.fingerprint)
                sourceStamp = stamp
                defaults = document.defaults; exportOptions = document.exportOptions
                previewMode = document.previewMode
                result = analysis; sceneBoundaries = Set(document.boundaries)
                sceneSettings = Dictionary(uniqueKeysWithValues: document.scenes.map { ($0.startFrame, $0.settings) })
                referenceResults = references; selectedSceneStart = 0
                installVideo(asset: AVURLAsset(url: sourceURL), url: sourceURL, info: info, access: sourceScope)
                updateCurve(markEdited: false)
                seek(toTime: document.playhead)
                installingProject = false
                projectHasChanges = id != nil || relinked
                if projectHasChanges { flushCheckpoint() }
                refreshRecoveryAvailability()
            } catch is CancellationError { }
            catch ProjectError.differentSource {
                activity = nil
                let alert = NSAlert()
                alert.messageText = "The source video does not match"
                alert.informativeText = ProjectError.differentSource.localizedDescription
                alert.addButton(withTitle: "Locate Original Video")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn, let located = locateSource(document.source) {
                    loadProject(document, file: file, access: access, sourceOverride: located, recovering: id)
                    return
                }
            }
            catch { self.error = error.localizedDescription }
            activity = nil
        }
    }

    private func projectEdited() {
        guard !installingProject, result != nil else { return }
        projectHasChanges = true
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)); try Task.checkCancellation() }
            catch { return }
            self?.flushCheckpoint()
        }
    }

    func flushCheckpoint() {
        checkpointTask?.cancel(); checkpointTask = nil
        guard projectHasChanges else { return }
        do {
            try recoveryStore.write(snapshot(), id: recoveryID)
            recoveryWarning = nil
        } catch {
            recoveryWarning = "Autosave recovery is unavailable. Save your project: " + error.localizedDescription
        }
    }

    private func clearCheckpoint() {
        checkpointTask?.cancel(); checkpointTask = nil
        do { try recoveryStore.remove(id: recoveryID); recoveryWarning = nil }
        catch { recoveryWarning = "Could not remove an old recovery copy: " + error.localizedDescription }
        refreshRecoveryAvailability()
    }

    func finishSession() { clearCheckpoint() }

    func closeSession() {
        finishSession()
        player.pause(); stillTask?.cancel(); stillGeneration += 1
        player.replaceCurrentItem(with: nil); itemObservation = nil
        sourceAccess = nil; projectAccess = nil; projectSource = nil; sourceStamp = nil
        url = nil; info = nil; projectURL = nil; result = nil
        sceneBoundaries = []; sceneSettings = [:]; referenceResults = [:]; stablePatchCounts = [:]
        curve = .empty; exposureComparison = .empty; previewCorrection.set(.empty)
        stillImage = nil; previewError = nil; exportedURL = nil
        playhead = 0; selectedSceneStart = 0; selectingRegion = false; isPlaying = false
        projectHasChanges = false; recoveryID = UUID()
        refreshRecoveryAvailability()
    }

    func restoreRecovery(_ file: URL) {
        guard !busy, let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return }
        do {
            let document = try ProjectStore.read(file)
            loadProject(document, file: nil, access: nil, recovering: id)
        } catch { self.error = error.localizedDescription }
    }

    private func refreshRecoveryAvailability() {
        recoveryAvailable = !recoveryStore.candidates(excluding: recoveryID).isEmpty
    }

    func checkRecoveryOnLaunch() {
        guard !checkedRecovery else { return }
        checkedRecovery = true
        if url == nil, recoveryAvailable { recoverSession() }
    }

    func recoverSession() {
        guard !busy, let file = recoveryStore.candidates(excluding: recoveryID).first,
              let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return }
        let alert = NSAlert()
        alert.messageText = "Recover an unfinished editing session?"
        alert.informativeText = "FrankLuma found an autosaved session from a previous launch. Recover it to resume your edits, or keep it for later."
        alert.addButton(withTitle: "Recover Session")
        alert.addButton(withTitle: "Keep for Later")
        alert.addButton(withTitle: "Discard Recovery")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.completeRecoveryPrompt(response, file: file, id: id)
            }
        } else {
            completeRecoveryPrompt(alert.runModal(), file: file, id: id)
        }
    }

    private func completeRecoveryPrompt(_ response: NSApplication.ModalResponse, file: URL, id: UUID) {
        switch response {
        case .alertFirstButtonReturn:
            guard confirmLeavingSession() else { return }
            restoreRecovery(file)
        case .alertThirdButtonReturn:
            do { try recoveryStore.remove(id: id); refreshRecoveryAvailability() }
            catch { self.error = error.localizedDescription }
        default: break
        }
    }
}
