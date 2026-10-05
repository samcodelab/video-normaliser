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
            CommandGroup(replacing: .appInfo) {
                Button("About FrankLuma", action: showFrankLumaAbout)
            }
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
                    .disabled(model.busy || model.correctionPending || model.result == nil)
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
        }.defaultSize(width: 900, height: 680)
    }
}

private let accent = Color(red: 0.70, green: 0.87, blue: 0.46)
private let muted = Color.secondary
private let frankLumaPrivacyPolicyURL = URL(string: "https://broadframestudio.com/frankluma/privacy/index.html")!

@MainActor
private func showFrankLumaAbout() {
    let credits = NSMutableAttributedString(string: "Broad Frame Studio\nbroadframestudio.com", attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.labelColor
    ])
    let website = (credits.string as NSString).range(of: "broadframestudio.com")
    credits.addAttribute(.link, value: URL(string: "https://broadframestudio.com")!, range: website)
    NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
}

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
                    .help("Export corrected video (⇧⌘E)").disabled(model.result == nil || model.busy || model.correctionPending)
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
                    if !model.correctionPending, let count = model.stablePatchCounts[model.selectedSceneStart], count < 12 {
                        Text("Too little stable background for global correction. Select a static reference area, or review this scene’s cuts.")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
                            Button("Save diagnostics…", action: model.exportDiagnostics).disabled(model.busy || model.correctionPending)
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
            } else if model.correctionPending {
                ProgressView().controlSize(.small)
                Text("Updating correction…").font(.system(size: 11))
                Spacer()
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
    @State private var selection: HandbookTopic? = .gettingStarted
    @State private var search = ""
    private var topics: [HandbookTopic] {
        HandbookTopic.allCases.filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(topics) { topic in
                    Label(topic.rawValue, systemImage: topic.symbol).tag(topic)
                }
            }
            .navigationTitle("Handbook")
            .searchable(text: $search, prompt: "Search help")
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 270)
            .overlay {
                if topics.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            let topic = selection ?? .gettingStarted
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FRANKLUMA HANDBOOK").font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(topic.rawValue).font(.largeTitle.weight(.semibold))
                        Text(topic.introduction).font(.title3).foregroundStyle(.secondary)
                    }
                    if topic == .gettingStarted {
                        Button("Open Demo Video", action: openDemo).controlSize(.large)
                        Text("The included silent demo is original geometric animation with deliberately uneven exposure.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(topic.sections.indices, id: \.self) { index in
                        let section = topic.sections[index]
                        VStack(alignment: .leading, spacing: 9) {
                            Text(section.title).font(.headline)
                            Text(section.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    HStack {
                        Link("Online handbook", destination: URL(string: "https://broadframestudio.com/frankluma/help/")!)
                        Spacer()
                        Link("Privacy policy", destination: frankLumaPrivacyPolicyURL)
                    }.font(.callout)
                    Text("This handbook is included in the app and works offline. Online links open in your browser.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .frame(maxWidth: 650, alignment: .leading)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(topic)
            .navigationTitle(topic.rawValue)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: search) { _, _ in
            if let first = topics.first, !topics.contains(selection ?? .gettingStarted) { selection = first }
        }
    }
}

private struct HandbookSection {
    let title: String
    let body: String
    init(_ title: String, _ body: String) { self.title = title; self.body = body }
}

private enum HandbookTopic: String, CaseIterable, Identifiable {
    case gettingStarted = "Getting started"
    case scenes = "Scene boundaries"
    case correction = "Correction & references"
    case preview = "Timeline & preview"
    case export = "Exporting video"
    case projects = "Projects & recovery"
    case media = "Supported media"
    case troubleshooting = "Troubleshooting"
    case support = "Privacy & support"
    var id: Self { self }
    var searchText: String { rawValue + " " + introduction + " " + sections.map { $0.title + " " + $0.body }.joined(separator: " ") }
    var symbol: String {
        switch self {
        case .gettingStarted: return "play.rectangle"
        case .scenes: return "scissors"
        case .correction: return "slider.horizontal.3"
        case .preview: return "film"
        case .export: return "square.and.arrow.up"
        case .projects: return "folder"
        case .media: return "video"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .support: return "questionmark.circle"
        }
    }
    var introduction: String {
        switch self {
        case .gettingStarted: return "Your first stop-motion correction, from source clip to finished movie."
        case .scenes: return "Keep different shots separate so correction stays within each scene."
        case .correction: return "Reduce exposure flicker while protecting movement and intentional lighting changes."
        case .preview: return "Compare the same frames and review correction over time."
        case .export: return "Choose a sharing copy or an editing format, then check the encoded result."
        case .projects: return "Keep editable settings, reconnect your source, and recover unsaved work."
        case .media: return "What you can open and export on your Mac."
        case .troubleshooting: return "Practical checks for correction, access, playback and export problems."
        case .support: return "Processing stays on your Mac. You choose what to share with support."
        }
    }
    var sections: [HandbookSection] {
        switch self {
        case .gettingStarted: return [
            .init("1. Open and analyse", "Choose Open Video… (⌘O), drop a video into the window, or try the included demo. Choose Detect scenes & analyse and wait for analysis to complete. Use SDR video with no side larger than 4096 pixels; see Supported media if your clip is rejected."),
            .init("2. Review the scene cuts", "Select each scene and step around its beginning and end with the arrow keys. Different camera shots should be separate scenes, even when they share a background. Automatic detection can miss cuts or mistake a flash for a cut. Split or merge scenes before tuning correction."),
            .init("3. Compare and adjust", "Choose Side by side in the Preview menu: Original is on the left and Corrected on the right. Start with Smooth flicker and a 0.5 s radius. Adjust strength for the selected scene, then play it. Enable Loop scene to review that scene repeatedly. Use a stable background reference when moving subjects dominate the measurement."),
            .init("4. Save your work and export", "Save Project (⌘S) keeps editable settings; retain the original video. Export… (⇧⌘E) writes a separate corrected movie. Open that result in a player or editor and check the difficult frames, cuts, duration and audio. Exporting does not save your project.")
        ]
        case .scenes: return [
            .init("Inspect before correcting", "Click a scene band or frame on the timeline. Use ← and → to inspect adjacent source frames. A group shot changing to a close-up needs its own boundary even if exposure and background remain similar. The correction window must not combine different shots."),
            .init("Add or move a cut", "Select the first frame of the new shot and choose Split at playhead. Drag an orange cut handle to move an existing boundary; it snaps to frames. The inspector’s start/end frame steppers provide an exact keyboard-accessible alternative. Boundaries cannot cross or create empty scenes."),
            .init("Merge an unnecessary cut", "Select the scene after the unwanted cut and choose Merge previous. Review the merged scene’s correction afterwards. This is useful when a lighting flash was mistaken for a camera cut."),
            .init("Analyse again and reset cuts", "Analyse again refreshes automatic cuts if you have not manually edited them. Manually reviewed boundaries are preserved. Reset cuts explicitly restores the detected boundaries and removes your manual changes. Save a separate project version before resetting cuts you may want to keep.")
        ]
        case .correction: return [
            .init("Smooth flicker or Steady scene?", "Smooth flicker reduces rapid exposure variation while retaining gradual lighting changes. The smoothing radius controls the surrounding time used to estimate a target: a larger radius can remove longer variations but can also soften intentional changes. Steady scene uses one exposure target across the scene and can reduce intentional fades. Use it for a shot whose lighting should stay constant."),
            .init("Strength and spatial correction", "Strength controls the overall correction; zero leaves the scene uncorrected. Spatial correction addresses supported local exposure and tone changes. Set it to zero for global correction only. Start with the defaults and judge the picture in playback, including shadows, fine texture and highlights."),
            .init("Choose a reference area", "Expand Reference area and choose Select reference area. Drag over a static background patch in the preview; in Side by side, draw on the original image on the left. Choose a reasonably sized area that stays visible and avoids moving objects, changing shadows, clipped highlights or very dark regions. Compare it across the entire scene."),
            .init("Use whole frame or copy settings", "Use whole frame removes a custom reference. A reference belongs to the selected scene and does not alter scene detection. Apply these settings to all scenes copies both correction settings and the reference rectangle. Review each shot first: the same rectangle may contain a moving subject after a camera cut."),
            .init("Understand the limits", "Strong motion and too little stable background can limit correction. Fewer than 12 usable stable patches produces zero correction with a notice. Clipped highlight detail cannot be restored. Exposure correction does not replace white-balance correction or colour grading. A smoother graph alone does not establish a better picture.")
        ]
        case .preview: return [
            .init("Scrub, step and zoom", "Click or drag on the timeline to scrub. ← and → step one source frame; Space plays or pauses. First/last buttons go to the clip’s edges. Pinch or Command-scroll zooms around the pointer; ordinary scroll pans. Fit shows the whole clip."),
            .init("Loop the selected scene", "Select a scene, enable Loop scene beside the transport buttons, and press Play. Playback repeats from that scene’s first frame when it reaches the boundary, including the final scene of the clip. Pause, scrubbing, scene selection or editing cuts stops playback. Press Play again to review the newly selected scene. Disable Loop scene for normal playback across the clip."),
            .init("Preview modes", "Original and Corrected show one picture. Side by side shows the same source frame on both sides. These modes affect preview only: export always writes one corrected picture at the source dimensions. Confidence mask, Motion mask and Correction field help inspect measurement support, movement and the effective correction."),
            .init("Read the exposure graph", "The cyan original and green corrected-global curves use the same per-scene baseline. Local exposure and tone adjustments are not represented by that global line. The correction field and actual picture can reveal changes the line does not show."),
            .init("Save diagnostics", "Expand Diagnostics and choose Save diagnostics… to write frame measurements and correction data locally. These are technical review aids, not an encoded-output quality score. Mean estimates exclude pixel-level protection. Review a diagnostic file before choosing to send it to anyone.")
        ]
        case .export: return [
            .init("Review before exporting", "Play the clip and inspect scene cuts, flashes, shadows and highlights. Finish correction changes and wait for processing to complete. Choose Export… (⇧⌘E), name the file and select a writable destination in the Save panel."),
            .init("Choose a format", "MP4 — H.264 is a broadly compatible sharing choice. HEVC can produce smaller files, but check the receiving player or editor. H.264 and HEVC also support QuickTime. QuickTime — ProRes 422 is intended for further editing and needs more storage. Export re-encodes the video; none of these choices makes a lossless copy of the source."),
            .init("Quality and audio", "Standard and High quality are available for H.264/HEVC; High produces larger files. ProRes uses a higher-precision processing path. QuickTime preserves compatible original audio. MP4 preserves AAC and converts other audio to AAC; multichannel audio becomes stereo. Choose QuickTime when keeping compatible original tracks matters. The included demo is silent."),
            .init("Finish and check the movie", "Keep the source drive connected and allow space for processing. Cancellation or failure leaves an existing destination intact. The source stays untouched. Use Show in Finder and open the result in a player or editor. Check dimensions/orientation, duration, the last frame, audio and difficult scenes. Save Project separately if you want to resume editing.")
        ]
        case .projects: return [
            .init("Save editable settings", "Save Project (⌘S) creates a small .frankluma file containing cuts, references, correction settings, export options, current frame and preview mode. It links the original video and does not embed it or cached analysis. Back up both the project and its exact source video. Project files can reveal source paths and editing settings."),
            .init("Save another version", "Save Project As… (⇧⌘S) creates a separately named editing version and makes it the active save destination. Later Save Project updates that copy. A movie export and an editable project are separate outputs."),
            .init("Reopen or relink", "Use Open Project… (⇧⌘O), Finder or drag-and-drop. FrankLuma checks the source and repeats analysis before restoring edits. Keep the source drive connected. If a source has moved, macOS bookmarks may find it; otherwise locate it when prompted or choose File → Relink Source Video…. Relinking requires the original or a byte-identical copy. A re-encoded or modified movie needs a new session."),
            .init("Recover unsaved changes", "Unsaved edits are checkpointed locally after a brief delay. On launch, choose Recover, Keep for Later or Discard for an offered checkpoint. File → Recover Unsaved Session opens the newest checkpoint; other checkpoints remain available afterwards. Recovery requires the original source and repeats analysis. Save Project to retain a recovered session."),
            .init("Before closing", "Opening another file, closing or quitting with unsaved edits offers Save, Discard or Cancel. Cancel keeps editing. A successful save or deliberate discard/closure removes that session’s recovery checkpoint. If a recovery warning appears, save the project manually. During processing, wait or cancel the operation before closing.")
        ]
        case .media: return [
            .init("Requirements", "FrankLuma requires macOS 14 or later. Input must be unprotected SDR video readable by macOS, no larger than 4096 pixels on either side. Codec availability depends on your Mac and macOS. H.264/HEVC in MP4 or MOV and SDR ProRes in MOV are common choices."),
            .init("HDR and protected media", "HDR, including HLG and PQ, and protected videos are not supported. Convert to an unprotected SDR Rec. 709 copy in a video editor before opening it. Simply changing the file extension does not convert colour or codec. Keep the original footage."),
            .init("Source timing and orientation", "Analysis uses actual decoded frame timestamps, including variable frame timing. Export preserves the source picture dimensions/orientation and frame timing. Side by side is a preview layout and does not create a split-screen movie."),
            .init("Long clips", "Decoding and exporting longer or higher-resolution clips takes more time. Keep the source available and wait for the activity to finish before exporting. Review several difficult scenes and check the full output rather than assuming one corrected frame represents the whole film.")
        ]
        case .troubleshooting: return [
            .init("Flicker remains", "Inspect the actual frames in a loop. Confirm the scene contains one shot, strength is above zero, and the stable-patch notice is not reporting too little support. Try a suitable static reference and compare Smooth flicker with Steady scene. Increase radius cautiously for longer variations. Strong movement, local shadows, colour shifts and clipped highlights may limit results."),
            .init("A cut is missing or a flash becomes a scene", "Step to the first frame of the new shot and use Split at playhead. Merge previous removes a false cut. Automatic detection is an aid; review boundaries before correction. Analyse again preserves manually edited cuts; Reset cuts replaces them with detected cuts."),
            .init("Opening or relinking fails", "Confirm the file is accessible, the source drive is connected, and the video is unprotected SDR within the size limit. Select the file again through the Open panel. Projects require the exact source content; a visually similar re-encode does not match. Open a modified video as a new session."),
            .init("Playback or processing seems stalled", "Check the activity and error message. Keep external drives connected. Let analysis/correction finish before exporting. If cancellation is available, let it complete before retrying. Try the included demo to distinguish a source-specific problem. Record the operation and exact error when contacting support."),
            .init("Export fails or the shared movie is old", "Check free storage, source availability and destination write access. Choose another writable local destination in the Save panel. Try QuickTime if audio conversion is failing. After changing correction, export a new movie: saving the project does not update an earlier export. Open the actual exported file and check audio and the final frame."),
            .init("Recovery or saving reports an error", "Save the project manually to a writable location. Keep both the project and source. A recovery checkpoint is a safeguard, not a substitute for a saved project or backup. Include the exact save/recovery error in your support request.")
        ]
        case .support: return [
            .init("Local processing", "FrankLuma does not upload footage and has no accounts, advertising, tracking or third-party analytics. It reads files you select through macOS and saves projects, exports and diagnostics where you choose. Recovery checkpoints stay in the app’s local storage. Source videos are not modified."),
            .init("Contact support", "Email support@broadframestudio.com. Include your app/macOS versions, the step that failed, exact error, source dimensions/codec/container, scene/frame and selected export format. Try the included demo if possible and mention whether the issue occurs there too."),
            .init("Share only what you choose", "Private videos, projects and diagnostics are shared only if you send them. Review attachments first; projects can contain source filenames/paths and editing settings. A small non-private example and clear reproduction steps are often enough. The online privacy policy explains storage and voluntary support emails.")
        ]
    }
}
}
