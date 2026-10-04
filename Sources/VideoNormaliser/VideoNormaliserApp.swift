import SwiftUI
import AVKit

@main
struct VideoNormaliserApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…", action: model.chooseVideo).keyboardShortcut("o").disabled(model.busy)
                Button("Export Corrected Video…", action: model.export).keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.busy || model.result == nil)
            }
        }
    }
}

private let accent = Color(red: 0.70, green: 0.87, blue: 0.46)
private let muted = Color.white.opacity(0.45)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("PREVIEW", systemImage: "play.rectangle")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(muted)
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
                        Text(model.previewMode == .field ? "Field: red brightens · blue darkens · green is zero. Includes global exposure." : model.previewMode == .motion ? "Motion / occlusion: white is unreliable correspondence; black is consistent." : "Confidence: white is reliable background evidence; black is excluded or unsupported.")
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
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 282)
            }
            Divider()
            footer
        }
        .background(Color(red: 0.075, green: 0.085, blue: 0.09))
        .tint(accent)
        .alert("Video Normaliser", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.system(size: 27)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Video Normaliser").font(.system(size: 17, weight: .semibold))
                Text("A steadier light. Frame by frame.").font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            if let url = model.url {
                Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260)
            }
            Button(action: model.chooseVideo) { Label("Open video", systemImage: "folder") }.disabled(model.busy)
            Button(action: model.export) { Label("Export…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.result == nil || model.busy)
        }.padding(.horizontal, 28).padding(.vertical, 20)
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
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.selectedScene.map { "Scene \($0.number) settings" } ?? "Make light consistent").font(.system(size: 18, weight: .medium))
                    Text(model.result == nil ? "Analyse once, then edit scenes on the timeline." : "These settings apply only to the selected scene.")
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                }
                Button(action: model.analyse) {
                    Label(model.result == nil ? "Detect scenes & analyse" : "Analyse again", systemImage: "waveform.path")
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.info == nil || model.busy)
                sceneControls
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("02", "Reference area")
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
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("03", "Selected scene correction")
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
                        Text(field.fallback ?? String(format: "Local adjustment up to %.2f EV", field.peak))
                            .font(.system(size: 11)).foregroundStyle(field.fallback == nil ? muted : .orange)
                    }
                    Text("Total correction is limited to ±2 EV; local correction to ±0.6 EV. Unreliable areas fall back towards global correction.")
                        .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
                }.disabled(model.busy)
                if let result = model.result {
                    Button("Save diagnostics…", action: model.exportDiagnostics)
                        .font(.system(size: 11)).disabled(model.busy)
                    Text("Diagnostics log gains, alignment and confidence, plus predicted linear brightness. Check encoded output separately.")
                        .font(.system(size: 10)).foregroundStyle(muted)
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
                if model.info?.isHDR == true {
                    Label("HDR source detected. HDR colour fidelity has not been validated; check colour and highlights in the result.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineSpacing(3)
                }
                Spacer(minLength: 0)
                Text("Everything happens on your Mac.\nYour source video stays untouched.")
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(4)
            }.padding(24)
        }.background(.white.opacity(0.018))
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("01", "Selected scene")
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
                }.font(.system(size: 10))
                Text("Drag orange handles to adjust cuts. Splitting copies settings; merging keeps the earlier scene’s settings.")
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
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
            } else if let exported = model.exportedURL {
                Text("Exported \(exported.lastPathComponent)").font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }.controlSize(.small)
            } else {
                Text(model.result != nil ? "Ready to preview and export" : model.info != nil ? "Ready to analyse" : "Ready when you are")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Text("LOCAL PROCESSING").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
            }
        }.padding(.horizontal, 28).frame(height: 45)
    }

    private func sectionLabel(_ number: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
            Text(label).font(.system(size: 12, weight: .semibold))
        }
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
