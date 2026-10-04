import SwiftUI
import AVKit

@main
struct FrankLumaApp: App {
    @NSApplicationDelegateAdaptor(FrankLumaLifecycle.self) private var lifecycle
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("FrankLuma", id: "editor") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
                .onOpenURL { model.open($0) }
                .onAppear {
                    lifecycle.model = model
                    DispatchQueue.main.async { model.checkRecoveryOnLaunch() }
                }
                .background(SessionWindowGuard(model: model))
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .help) {
                Button("FrankLuma Help") { openWindow(id: "help") }
                Button("Open Demo Video", action: model.openDemo).disabled(model.busy)
                Divider()
                Link("Privacy Policy", destination: frankLumaPrivacyPolicyURL)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Video…", action: model.chooseVideo).keyboardShortcut("o").disabled(model.busy)
                Button("Open Project…", action: model.chooseProject).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
                Button("Export Corrected Video…", action: model.export).keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.busy || model.result == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }.keyboardShortcut("s")
                    .disabled(model.busy || model.result == nil)
                Button("Save Project As…") { model.saveProject(asCopy: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.busy || model.result == nil)
                Divider()
                Button("Relink Source Video…", action: model.relinkSource)
                    .disabled(model.busy || model.result == nil)
                Button("Recover Unsaved Session…", action: model.recoverSession)
                    .disabled(model.busy || !model.recoveryAvailable)
            }
        }
        Window("FrankLuma Help", id: "help") {
            FrankLumaHelp(openDemo: { model.openDemo(); openWindow(id: "editor") })
        }.defaultSize(width: 520, height: 520)
    }
}

private let accent = Color(red: 0.70, green: 0.87, blue: 0.46)
private let muted = Color.secondary
private let frankLumaPrivacyPolicyURL = URL(string: "https://broadframestudio.com/frankluma/privacy/index.html")!

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTarget = false
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Preview", systemImage: "play.rectangle")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                        Spacer()
                        if model.result != nil {
                            Picker("Preview", selection: $model.previewMode) {
                                ForEach(PreviewMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                            }.pickerStyle(.menu).frame(width: 240)
                                .onChange(of: model.previewMode) { _, _ in model.updatePreviewLayout() }
                                .disabled(model.busy)
                        }
                    }
                    preview
                    if model.previewMode.isDiagnostic {
                        Text(model.previewMode == .field ? "Field: red brightens · blue darkens · green is zero. Shows the applied exposure and tone correction." : model.previewMode == .motion ? "Motion / occlusion: white is unreliable correspondence; black is consistent." : "Confidence: white is reliable background evidence; black is excluded or unsupported.")
                            .font(.system(size: 10)).foregroundStyle(muted)
                    }
                    if let info = model.info {
                        HStack(spacing: 16) {
                            Text("\(info.width) × \(info.height)")
                            Text(String(format: "%.2f fps", info.fps))
                            Text(duration(info.duration))
                            Spacer()
                            Label(info.hasAudio ? "Audio included" : "No audio", systemImage: info.hasAudio ? "waveform" : "speaker.slash")
                        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                    }
                    graph
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(red: 0.075, green: 0.085, blue: 0.09))
        .tint(accent)
        .navigationTitle(model.projectTitle)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: model.chooseVideo) { Label("Open Video…", systemImage: "folder") }
                    .help("Open a video (⌘O)").disabled(model.busy)
                Button { model.saveProject() } label: { Label("Save Project", systemImage: "square.and.arrow.down") }
                    .help("Save editable settings (⌘S)").disabled(model.result == nil || model.busy)
                Button(action: model.export) { Label("Export…", systemImage: "square.and.arrow.up") }
                    .help("Export corrected video (⇧⌘E)").disabled(model.result == nil || model.busy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide inspector" : "Show inspector")
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 270, ideal: 290, max: 360)
        }
        .alert("FrankLuma", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard !model.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(accent, lineWidth: 3).padding(5).allowsHitTesting(false) } }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let info = model.info {
                    PlayerSurface(player: model.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !model.isPlaying, let image = model.stillImage {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if let message = model.previewError {
                        VStack { Spacer(); Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).padding(10).background(.black.opacity(0.8)) }
                    }
                    let paired = model.previewMode == .sideBySide
                    let displayWidth = Double(info.width) * (paired ? 2 : 1)
                    let scale = min(geometry.size.width / displayWidth, geometry.size.height / Double(info.height))
                    let size = CGSize(width: Double(info.width) * scale, height: Double(info.height) * scale)
                    RegionOverlay(region: model.region, selecting: model.selectingRegion, commit: model.setRegion)
                        .frame(width: size.width, height: size.height)
                        .offset(x: paired ? -size.width / 2 : 0)
                        .allowsHitTesting(model.selectingRegion)
                    if paired {
                        RegionOverlay(region: model.region, selecting: false, commit: { _ in })
                            .frame(width: size.width, height: size.height).offset(x: size.width / 2)
                            .allowsHitTesting(false)
                        Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: size.height).allowsHitTesting(false)
                        VStack {
                            HStack {
                                Text("ORIGINAL").foregroundStyle(.cyan).frame(maxWidth: .infinity)
                                Text("CORRECTED").foregroundStyle(accent).frame(maxWidth: .infinity)
                            }.font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.vertical, 10)
                            Spacer()
                        }.allowsHitTesting(false)
                    }
                    if model.selectingRegion {
                        VStack {
                            Text(model.previewMode == .sideBySide ? "Select a reference on the original (left) image" : "Drag over a static background area")
                                .font(.system(size: 12, weight: .medium)).padding(10).background(.black.opacity(0.8), in: Capsule())
                            Spacer()
                        }.padding(18).allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "film.stack").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(accent)
                        VStack(spacing: 8) {
                            Text("Let your animation shine").font(.system(size: 23, weight: .medium))
                            Text("Reduce exposure flicker in your stop-motion footage.")
                                .font(.system(size: 13)).foregroundStyle(muted)
                        }
                        Button("Choose a video…", action: model.chooseVideo).controlSize(.large)
                        Button("Try the included demo", action: model.openDemo).buttonStyle(.link)
                        Text("or drop a video anywhere in this window")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        }.frame(minHeight: 200)
    }

    private var graph: some View {
        TimelineEditor(model: model)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.selectedScene.map { "Scene \($0.number)" } ?? "Scene Inspector").font(.system(size: 15, weight: .semibold))
                    Text(model.result == nil ? "Analyse once, then edit scenes on the timeline." : "Settings for the selected scene")
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                }
                Button(action: model.analyse) {
                    Label(model.result == nil ? "Detect scenes & analyse" : "Analyse again", systemImage: "waveform.path")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.info == nil || model.busy)
                sceneControls
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Correction")
                    Picker("Normalisation", selection: $model.mode) {
                        ForEach(NormalisationMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.labelsHidden().pickerStyle(.segmented)

                    Text(model.mode == .smooth ? "Reduce rapid flicker while retaining gradual lighting changes. Choose Steady scene for a constant exposure target." : "Match frames to one median exposure target within this scene. Intentional fades will also be reduced.")
                        .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
                    HStack {
                        Text("Strength")
                        Spacer()
                        Text("\(Int(model.strength * 100))%").foregroundStyle(accent).monospacedDigit()
                    }.font(.system(size: 12))
                    Slider(value: $model.strength, in: 0...1, step: 0.05) { Text("Correction strength") }
                        .labelsHidden()

                    if model.mode == .smooth {
                      HStack {
                        Text("Smoothing radius")
                        Spacer()
                        Text(String(format: "%.1f s", model.radius)).foregroundStyle(accent).monospacedDigit()
                    }.font(.system(size: 12))
                    Slider(value: $model.radius, in: 0.1...3, step: 0.1) { Text("Smoothing radius") }
                        .labelsHidden()

                    }
                    HStack {
                        Text("Spatial correction")
                        Spacer()
                        Text("\(Int(model.spatialStrength * 100))%").foregroundStyle(accent).monospacedDigit()
                    }.font(.system(size: 12))
                    Slider(value: $model.spatialStrength, in: 0...1, step: 0.05) { Text("Spatial correction strength") }.labelsHidden()
                    Text("Smooth local exposure changes from aligned background patches. Set to 0% for global correction only.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    if let field = model.curve.field(at: model.playhead) {
                        Text(field.fallback ?? (field.offsets.contains { abs($0) > 0.003 } ? "Local exposure and tone correction" : String(format: "Local adjustment up to %.2f EV", field.peak)))
                            .font(.system(size: 11)).foregroundStyle(field.fallback == nil ? muted : .orange)
                    }
                    Image(systemName: "info.circle")
                        .foregroundStyle(muted)
                        .help("Tone correction matches background brightness and contrast, with protection for deep shadows and highlights. Unsupported areas fall back towards global exposure.")
                        .accessibilityLabel("About tone correction")
                }.disabled(model.busy)
                Divider()
                DisclosureGroup("Reference area") {
                    VStack(alignment: .leading, spacing: 10) {
                    Text(model.region == nil ? "Using the whole frame" : "Using your selected area")
                        .font(.system(size: 12, weight: .medium))
                    Text("For moving subjects, select a background area whose lighting should stay consistent.")
                        .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
                    Button {
                        model.beginRegionSelection()
                    } label: {
                        Label(model.selectingRegion ? "Cancel selection" : "Select reference area", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }.disabled(model.result == nil || model.busy)
                    if model.region != nil {
                        Button("Use whole frame") { model.setRegion(nil) }.buttonStyle(.link).font(.system(size: 11)).disabled(model.busy)
                    }
                    }.padding(.top, 8)
                }.font(.system(size: 12, weight: .medium))
                Divider()
                if let result = model.result {
                    DisclosureGroup("Diagnostics") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Save diagnostics…", action: model.exportDiagnostics).disabled(model.busy)
                            Text("Gain/offset fields and confidence. Mean estimates exclude pixel-level protection; check encoded output separately.")
                                .foregroundStyle(muted)
                        }.font(.system(size: 11)).padding(.top, 8)
                    }.font(.system(size: 12))
                    Button("Apply these settings to all scenes", action: model.applySettingsToAllScenes)
                        .font(.system(size: 11)).disabled(model.busy)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Analysis complete", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                        Text("\(model.scenes.count) scenes · \(result.cuts) automatic cuts")
                        if let count = model.stablePatchCounts[model.selectedSceneStart] {
                            Text("\(count) stable patches in this scene")
                            if count < 12 {
                                Text("Too little stable content to correct this scene. Select a static reference area or adjust the scene boundaries.")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }.font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
                Text("Everything happens on your Mac.\nYour source video stays untouched.")
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(4)
            }.padding(18)
        }.background(.bar)
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Scene boundaries")
            if let scene = model.selectedScene {
                Picker("Scene", selection: Binding(get: { model.selectedSceneStart }, set: { start in
                    if let scene = model.scenes.first(where: { $0.startFrame == start }) { model.seek(to: scene) }
                })) {
                    ForEach(model.scenes) { scene in
                        Text("Scene \(scene.number) · \(timecode(scene.start)) – \(timecode(scene.end))").tag(scene.startFrame)
                    }
                }.labelsHidden()
                Text("Frames \(scene.startFrame + 1)–\(scene.startFrame + scene.frameCount) · \(scene.frameCount) frames")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                if scene.startFrame > 0 {
                    Stepper("Start frame: \(scene.startFrame + 1)", onIncrement: {
                        model.moveBoundary(from: scene.startFrame, toFrame: scene.startFrame + 1)
                    }, onDecrement: {
                        model.moveBoundary(from: scene.startFrame, toFrame: scene.startFrame - 1)
                    }).font(.system(size: 11))
                }
                let next = scene.startFrame + scene.frameCount
                if next < (model.result?.samples.count ?? 0) {
                    Stepper("End frame: \(next)", onIncrement: {
                        model.moveBoundary(from: next, toFrame: next + 1)
                        if let current = model.scenes.first(where: { $0.startFrame == scene.startFrame }) { model.seek(to: current) }
                    }, onDecrement: {
                        model.moveBoundary(from: next, toFrame: next - 1)
                        if let current = model.scenes.first(where: { $0.startFrame == scene.startFrame }) { model.seek(to: current) }
                    }).font(.system(size: 11))
                }
                HStack {
                    if scene.startFrame > 0 {
                        Button("Merge previous") { model.removeBoundary(at: scene.startFrame) }
                            .help("Keep the previous scene's settings")
                    }
                    Spacer()
                    Button("Reset cuts", action: model.resetBoundaries)
                }.font(.system(size: 11)).tint(.secondary)
                Text("Drag orange handles to adjust cuts.")
                    .font(.system(size: 11)).foregroundStyle(muted)
                    .help("Splitting copies settings; merging keeps the earlier scene’s settings.")
            } else {
                Text("Automatic scene detection uses the whole frame. Each scene can have its own correction and reference area.")
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
            }
        }.disabled(model.busy)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle().fill(model.busy ? .orange : accent).frame(width: 6, height: 6)
            if let activity = model.activity {
                Text(activity).font(.system(size: 11))
                ProgressView(value: model.progress).frame(width: 160)
                Text("\(Int(model.progress * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                Spacer()
                Button("Cancel", action: model.cancel).controlSize(.small)
            } else if let warning = model.recoveryWarning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).help(warning)
                Spacer()
                Button("Save Project") { model.saveProject() }.controlSize(.small)
            } else if let exported = model.exportedURL {
                Text("Exported \(exported.lastPathComponent)").font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }.controlSize(.small)
            } else {
                Text(model.result != nil ? "Ready to preview and export" : model.info != nil ? "Ready to analyse" : "Ready when you are")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Label("On-device processing", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(muted)
            }
        }.padding(.horizontal, 20).frame(height: 32)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 12, weight: .semibold))
    }

    private func duration(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func timecode(_ seconds: Double) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct RegionOverlay: View {
    let region: CGRect?
    let selecting: Bool
    let commit: (CGRect?) -> Void
    @State private var draft: CGRect?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let rect = draft ?? region {
                    Rectangle().fill(accent.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                        .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                        .offset(x: rect.minX * geometry.size.width, y: rect.minY * geometry.size.height)
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard selecting else { return }
                        let x1 = max(0, min(1, value.startLocation.x / geometry.size.width))
                        let y1 = max(0, min(1, value.startLocation.y / geometry.size.height))
                        let x2 = max(0, min(1, value.location.x / geometry.size.width))
                        let y2 = max(0, min(1, value.location.y / geometry.size.height))
                        draft = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
                    }
                    .onEnded { _ in
                        if let draft, draft.width >= 0.03, draft.height >= 0.03 { commit(draft) }
                        draft = nil
                    })
        }
    }
}


@MainActor
final class FrankLumaLifecycle: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.confirmLeavingSession() != false else { return .terminateCancel }
        model?.finishSession()
        return .terminateNow
    }
}

/// Preserve SwiftUI's window delegate while adding a close confirmation.
private struct SessionWindowGuard: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ nsView: Probe, context: Context) {}
    final class Probe: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let coordinator, window.delegate !== coordinator else { return }
            coordinator.original = window.delegate
            window.delegate = coordinator
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        weak var original: NSWindowDelegate?
        init(model: AppModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.confirmLeavingSession() else { return false }
            let close = original?.windowShouldClose?(sender) ?? true
            if close { model.closeSession() }
            return close
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}

private struct FrankLumaHelp: View {
    let openDemo: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("FrankLuma 1.0").font(.title2.bold())
                Text("Reduce exposure flicker in stop-motion video.")
                Text("Getting started").font(.headline)
                Text("1. Open an SDR video, then choose Detect scenes & analyse.\n2. Compare Original and Corrected, or use Side by side.\n3. Adjust scene cuts and correction strength. Use a static reference area if subjects move.\n4. Export to a new file and check the result.")
                Button("Open Demo Video", action: openDemo)
                Text("Supported media").font(.headline)
                Text("SDR videos readable by macOS, up to 4096 pixels on either side. Codec availability depends on macOS. HDR (including HLG and PQ) and protected videos are not supported. Convert them to an unprotected SDR Rec. 709 copy first.")
                Text("Export and editing sessions").font(.headline)
                Text("Output choices are H.264 or HEVC in MP4/QuickTime, and ProRes 422 in QuickTime. High quality produces larger H.264/HEVC files; ProRes uses higher precision for editing. QuickTime preserves compatible original audio. MP4 preserves AAC or converts other audio to AAC, downmixing multichannel audio to stereo. Video is re-encoded, not lossless. Source files stay untouched. Save Project (⌘S) preserves scene cuts, reference areas, correction settings and export options in a small .frankluma file. Keep the original video with it. Open Project rebuilds analysis and restores edits; use Relink Source Video for an identical copy that has moved. Unsaved edits are autosaved locally for crash recovery. Closing or opening another file offers Save, Discard or Cancel. Exporting a movie does not save your project.")
                Text("Timeline controls").font(.headline)
                Text("⌘ + mouse wheel or trackpad pinch zooms around the pointer. Scroll to pan; Fit shows the whole clip. Click a frame slice to select it. Arrow keys step frames; Space plays or pauses. Orange cut handles snap to frames. Inspector frame steppers provide a keyboard-accessible alternative.")
                Text("Support").font(.headline)
                Link("support@broadframestudio.com", destination: URL(string: "mailto:support@broadframestudio.com")!)
                Link("Privacy Policy", destination: frankLumaPrivacyPolicyURL)
                Text("When reporting an issue, include your macOS version, source format and the steps that failed. Videos and diagnostics are only shared if you choose to send them.")
                Text("Correction limits").font(.headline)
                Text("Strong motion, clipped highlights and too little stable background can limit correction. Smooth flicker preserves gradual lighting changes; Steady scene can also reduce intentional fades. This is exposure correction, not a general white-balance or colour-grading tool.")
            }.font(.body).textSelection(.enabled).padding(24)
        }.frame(minWidth: 440, minHeight: 420)
    }
}
