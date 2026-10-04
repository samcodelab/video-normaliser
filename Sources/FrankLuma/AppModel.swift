import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
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

    init() {
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
                self.asset = asset; self.url = newURL; self.info = info
                result = nil; sceneBoundaries = []; sceneSettings = [:]; referenceResults = [:]; stablePatchCounts = [:]
                selectedSceneStart = 0; curve = .empty; exposureComparison = .empty; defaults.reference = nil
                selectingRegion = false; exportedURL = nil; stillImage = nil; previewError = nil; playhead = 0
                previewCorrection.set(.empty)
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = VideoEngine.liveComposition(asset: asset, state: previewCorrection, comparisonSize: comparisonSize, diagnostic: previewMode)
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed {
                        let message = item.error?.localizedDescription ?? "The video preview could not be loaded."
                        Task { @MainActor in self?.previewError = message }
                    }
                }
                player.replaceCurrentItem(with: item)
                self.sourceAccess = access
                refreshStill()
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
                    try await VideoEngine.analyse(url: url, region: nil) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }
                let analysis = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
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

    func updateCurve() {
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
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " — Normalised.mov"
        panel.message = "Export an SDR QuickTime (.mov) video encoded as H.264, with original audio. Video is re-encoded; this is not a lossless export."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else {
            error = "Choose a different filename so the source video is preserved."
            return
        }
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
                try await VideoEngine.export(asset: asset, curve: exportCurve, destination: staging.file) { [self] value in
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

    /// A video export does not save editable scene settings, so every analysed
    /// session needs protection until project saving is available.
    func confirmLeavingSession() -> Bool {
        if busy {
            let alert = NSAlert()
            alert.messageText = "An operation is still running"
            alert.informativeText = "Wait for it to finish, or use Cancel before closing this session."
            alert.addButton(withTitle: "Keep Working")
            alert.runModal()
            return false
        }
        guard result != nil else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this editing session?"
        alert.informativeText = "Scene cuts, reference areas and correction settings are not saved as a project. Exported videos are safe, but you cannot reopen these settings after discarding them."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Session")
        return alert.runModal() == .alertSecondButtonReturn
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
