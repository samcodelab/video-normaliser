import SwiftUI
import AppKit

private let timelineAccent = Color(red: 0.70, green: 0.87, blue: 0.46)

struct TimelineEditor: View {
    @ObservedObject var model: AppModel
    @State private var draggingBoundary: Int?
    @State private var draftTime: Double?
    @State private var viewport = TimelineViewport()
    private let plotHeight = 98.0
    private var duration: Double { max(0.001, model.info?.duration ?? 1) }

    private var visibleDuration: Double { duration / viewport.zoom }
    private func x(_ time: Double, width: Double) -> Double { (time - viewport.start) / visibleDuration * width }
    private func zoom(_ factor: Double, anchor: Double) {
        let frames = Double(model.result?.samples.count ?? Int(duration * (model.info?.fps ?? 24)))
        viewport.scale(by: factor, anchor: anchor, duration: duration, maximum: max(1, frames / 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transport
            HStack {
                Text("GLOBAL EXPOSURE / SCENES")
                Spacer()
                if model.result != nil {
                    Text("Scene \(model.selectedScene?.number ?? 1) · Frame \(model.currentFrame + 1)/\(model.result?.samples.count ?? 0)")
                }
                Text(String(format: "  %.2f s", model.playhead)).monospacedDigit()
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                legend("Original", colour: .cyan, dashed: true)
                legend("Global model + manual", colour: timelineAccent, dashed: false)
                Label("Manual adjustment", systemImage: "diamond.fill")
                    .font(.system(size: 10)).foregroundStyle(.purple)
                Spacer()
                Text("Global estimate · local gains shown in preview diagnostics")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    plot(width: geometry.size.width)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard !model.busy else { return }
                            let time = viewport.start + value.location.x / geometry.size.width * visibleDuration
                            if let samples = model.result?.samples {
                                model.seekFrame(TimelineMath.frame(at: time, samples: samples))
                            } else { model.seek(toTime: time) }
                        })
                    ForEach(model.scenes) { scene in
                        let x = max(0, x(scene.start, width: geometry.size.width))
                        let width = max(0, min(geometry.size.width, self.x(scene.end, width: geometry.size.width)) - x)
                        Button { model.seek(to: scene) } label: {
                            Text(width > 55 ? "Scene \(scene.number)" : "\(scene.number)")
                                .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .frame(width: max(0, width - 2), height: 23)
                                .background(scene.startFrame == model.selectedSceneStart ? timelineAccent.opacity(0.3) : .white.opacity(0.06))
                                .foregroundStyle(scene.startFrame == model.selectedSceneStart ? timelineAccent : .secondary)
                        }.buttonStyle(.plain).offset(x: x, y: 0).opacity(width > 0 ? 1 : 0).allowsHitTesting(width > 0)
                            .help("Select scene \(scene.number)")
                    }
                    ForEach(model.frameExposureAdjustments.keys.sorted(), id: \.self) { frame in
                        if let samples = model.result?.samples, samples.indices.contains(frame) {
                            let markerX = x(samples[frame].time, width: geometry.size.width)
                            if markerX >= 0, markerX <= geometry.size.width {
                                Button { model.seekFrame(frame) } label: {
                                    Image(systemName: "diamond.fill")
                                        .font(.system(size: 9)).foregroundStyle(.purple)
                                        .frame(width: 14, height: 16)
                                }.buttonStyle(.plain).position(x: markerX, y: 43)
                                    .disabled(model.busy)
                                    .help(String(format: "Frame %d: manual exposure %+.2f EV", frame + 1, model.frameExposureAdjustments[frame] ?? 0))
                                    .accessibilityLabel("Adjusted frame \(frame + 1)")
                            }
                        }
                    }
                    ForEach(model.scenes.dropFirst()) { scene in
                        boundaryHandle(scene: scene, width: geometry.size.width)
                    }
                    let playheadX = x(model.playhead, width: geometry.size.width)
                    Path { path in
                        path.move(to: CGPoint(x: playheadX, y: 25))
                        path.addLine(to: CGPoint(x: playheadX, y: plotHeight + 25))
                    }.stroke(.white, lineWidth: 1.5).allowsHitTesting(false)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11))
                        .foregroundStyle(.white).position(x: playheadX, y: 29).allowsHitTesting(false)
                }
                .background(TimelineNavigation(enabled: model.info != nil && !model.busy && draggingBoundary == nil,
                    zoom: { factor, fraction in zoom(factor, anchor: fraction) },
                    pan: { fraction in viewport.pan(by: fraction * visibleDuration, duration: duration) }))
            }.frame(height: plotHeight + 25).clipped()
            if viewport.zoom > 1 {
                HStack(spacing: 10) {
                    Text(String(format: "%.2f s", viewport.start)).monospacedDigit()
                    Slider(value: Binding(get: { viewport.start }, set: { viewport.start = $0 }),
                           in: 0...max(0.000001, duration - visibleDuration))
                        .accessibilityLabel("Timeline visible range")
                        .help("Pan through the zoomed timeline")
                    Text(String(format: "%.2f s", viewport.start + visibleDuration)).monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary).disabled(model.busy || draggingBoundary != nil)
            }
            HStack {
                Text("Scrub · Drag orange cuts · ⌘ scroll / pinch to zoom · Scroll to pan")
                Spacer()
                if model.result != nil {
                    Text(String(format: "Global %+.2f · Manual %+.2f EV", model.automaticExposure, model.manualExposure))
                        .monospacedDigit().foregroundStyle(timelineAccent)
                        .help("Automatic global exposure, including the scene brightness safeguard, and the extra manual exposure for this source frame. Local correction is shown in the preview.")
                }
                Text(String(format: "Peak automatic %.2f EV", model.curve.peak)).foregroundStyle(timelineAccent)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.onChange(of: model.url) { _, _ in viewport = TimelineViewport() }
            .padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legend(_ title: String, colour: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in path.move(to: CGPoint(x: 0, y: 4)); path.addLine(to: CGPoint(x: 22, y: 4)) }
                .stroke(colour, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 22, height: 8)
            Text(title).font(.system(size: 10)).foregroundStyle(colour)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { model.seekFrame(0) } label: { Image(systemName: "backward.end.fill") }
                .help("First frame")
            Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
                .keyboardShortcut(.leftArrow, modifiers: []).help("Previous frame (←)")
                .accessibilityLabel("Previous frame")
            Button(action: model.togglePlayback) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                .keyboardShortcut(.space, modifiers: []).help("Play / pause (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame") }
                .keyboardShortcut(.rightArrow, modifiers: []).help("Next frame (→)")
                .accessibilityLabel("Next frame")
            Button { model.seekFrame((model.result?.samples.count ?? 1) - 1) } label: { Image(systemName: "forward.end.fill") }
                .help("Last frame")
            Toggle(isOn: $model.loopSelectedScene) {
                Label("Loop scene", systemImage: "repeat")
            }.toggleStyle(.button).disabled(model.selectedScene == nil)
                .help("Repeat playback within the selected scene")
                .accessibilityLabel("Loop selected scene")
            Spacer()
            Button { zoom(1 / 1.5, anchor: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").accessibilityLabel("Zoom timeline out").disabled(viewport.zoom <= 1)
            Text(String(format: "%.1f×", viewport.zoom)).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary)
            Button { zoom(1.5, anchor: min(1, max(0, (model.playhead - viewport.start) / visibleDuration))) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in around playhead").accessibilityLabel("Zoom timeline in")
            Button("Fit") { viewport = TimelineViewport() }.help("Show the whole video")
            Button("Split at playhead", action: model.splitAtPlayhead).disabled(model.result == nil || model.currentFrame == 0)
                .help("The current frame becomes the first frame of a new scene")
        }.controlSize(.small).disabled(model.info == nil || model.busy)
    }

    private func boundaryHandle(scene: VideoScene, width: Double) -> some View {
        let time = draggingBoundary == scene.startFrame ? (draftTime ?? scene.start) : scene.start
        return ZStack {
            Rectangle().fill(.orange.opacity(0.8)).frame(width: 2)
            RoundedRectangle(cornerRadius: 3).fill(.orange).frame(width: 10, height: 18)
                .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 6)).foregroundStyle(.black))
        }.frame(width: 18, height: plotHeight + 25)
            .contentShape(Rectangle())
            .offset(x: x(time, width: width) - 9)
            .highPriorityGesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !model.busy, let result = model.result else { return }
                    draggingBoundary = scene.startFrame
                    let requested = scene.start + value.translation.width / width * visibleDuration
                    let proposed = TimelineMath.nearestFrame(at: requested, samples: result.samples)
                    let index = TimelineMath.clampedBoundary(proposed, moving: scene.startFrame,
                                                            boundaries: model.sceneBoundaries, frameCount: result.samples.count)
                    draftTime = result.samples[index].time
                    model.seekFrame(index)
                }
                .onEnded { _ in
                    if let time = draftTime { model.moveBoundary(from: scene.startFrame, to: time) }
                    draggingBoundary = nil; draftTime = nil
                })
            .accessibilityLabel("Boundary before scene \(scene.number)")
            .accessibilityValue(String(format: "%.3f seconds", time))
            .accessibilityAdjustableAction { direction in
                if direction == .increment { model.moveBoundary(from: scene.startFrame, toFrame: scene.startFrame + 1) }
                if direction == .decrement { model.moveBoundary(from: scene.startFrame, toFrame: scene.startFrame - 1) }
            }
            .help("Drag to move the start of scene \(scene.number). Snaps to frames.")
    }

    private func plot(width: Double) -> some View {
        Canvas { context, size in
            let top = 25.0, middle = top + plotHeight / 2
            if let scene = model.selectedScene {
                let rect = CGRect(x: x(scene.start, width: width), y: top,
                                  width: (scene.end - scene.start) / visibleDuration * width, height: plotHeight)
                context.fill(Path(rect), with: .color(timelineAccent.opacity(0.04)))
            }
            if let samples = model.result?.samples, !samples.isEmpty,
               width / visibleDuration * duration / Double(samples.count) >= 12 {
                let first = TimelineMath.frame(at: viewport.start, samples: samples)
                let last = TimelineMath.frame(at: viewport.start + visibleDuration, samples: samples)
                for index in first...last {
                    let left = x(samples[index].time, width: width)
                    let right = x(index + 1 < samples.count ? samples[index + 1].time : duration, width: width)
                    let rect = CGRect(x: left, y: top, width: max(0, right - left), height: plotHeight)
                    context.fill(Path(rect), with: .color(index == model.currentFrame ? timelineAccent.opacity(0.14) : .white.opacity(index.isMultiple(of: 2) ? 0.035 : 0)))
                    var line = Path()
                    line.move(to: CGPoint(x: left, y: top)); line.addLine(to: CGPoint(x: left, y: top + plotHeight))
                    context.stroke(line, with: .color(.white.opacity(0.13)), lineWidth: 1)
                    if right - left >= 28 {
                        context.draw(Text("\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                                     at: CGPoint(x: (left + right) / 2, y: top + plotHeight - 9))
                    }
                }
            }
            for y in [top, middle, top + plotHeight] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
                context.stroke(line, with: .color(.white.opacity(y == middle ? 0.15 : 0.05)), lineWidth: 1)
            }
            let exposure = model.exposureComparison
            guard exposure.times.count > 1 else { return }
            let range = exposure.range
            context.draw(Text(String(format: "+%.2f EV", range)).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: width - 3, y: top + 8), anchor: .trailing)
            context.draw(Text(String(format: "−%.2f EV", range)).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: width - 3, y: top + plotHeight - 25), anchor: .trailing)
            for (values, colour, dashed) in [(exposure.original, Color.cyan, true), (exposure.corrected, timelineAccent, false)] {
                var path = Path()
                for scene in model.scenes {
                    let end = scene.startFrame + scene.frameCount
                    guard scene.end >= viewport.start, scene.start <= viewport.start + visibleDuration else { continue }
                    let visibleStart = max(scene.startFrame, TimelineMath.frame(at: viewport.start, samples: model.result?.samples ?? []))
                    let visibleEnd = min(end, TimelineMath.frame(at: viewport.start + visibleDuration, samples: model.result?.samples ?? []) + 2)
                    let strideSize = max(1, scene.frameCount / max(1, Int((scene.end - scene.start) / visibleDuration * width)))
                    var first = true
                    for index in stride(from: visibleStart, to: visibleEnd, by: strideSize) {
                        let upper = min(index + strideSize, end)
                        let value = values[index..<upper].max(by: { abs($0) < abs($1) }) ?? 0
                        let point = CGPoint(x: x(exposure.times[index], width: width), y: middle - value / range * plotHeight / 2)
                        if first { path.move(to: point); first = false } else { path.addLine(to: point) }
                        if strideSize == 1 {
                            let nextTime = index + 1 < end ? exposure.times[index + 1] : scene.end
                            path.addLine(to: CGPoint(x: x(nextTime, width: width), y: point.y))
                        }
                    }
                    // Extend the final held frame to the scene's end, without
                    // connecting exposure baselines across a scene cut.
                    if visibleEnd == end {
                        path.addLine(to: CGPoint(x: x(scene.end, width: width), y: middle - values[end - 1] / range * plotHeight / 2))
                    }
                }
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: dashed ? [4, 3] : []))
            }
        }
    }
}


/// A bounded time viewport shared by drawing, scrubbing and cut dragging.
struct TimelineViewport {
    var start = 0.0
    var zoom = 1.0

    mutating func scale(by factor: Double, anchor: Double, duration: Double, maximum: Double) {
        guard factor.isFinite, factor > 0, duration.isFinite, duration > 0 else { return }
        let fraction = min(1, max(0, anchor))
        let time = start + fraction * duration / zoom
        zoom = min(max(1, maximum), max(1, zoom * factor))
        start = min(max(0, duration - duration / zoom), max(0, time - fraction * duration / zoom))
    }

    mutating func pan(by seconds: Double, duration: Double) {
        guard seconds.isFinite else { return }
        start = min(max(0, duration - duration / zoom), max(0, start + seconds))
    }
}

/// Match TonePebble's pointer-anchored Command-wheel and native pinch behaviour.
/// The probe never takes clicks away from scene buttons, cut handles or scrubbing.
private struct TimelineNavigation: NSViewRepresentable {
    let enabled: Bool
    let zoom: (Double, Double) -> Void
    let pan: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        context.coordinator.view = view
        context.coordinator.owner = self
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let owner = coordinator.owner, owner.enabled,
                  let view = coordinator.view, let window = view.window,
                  event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  view.bounds.width > 0 else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }
            if event.type == .magnify {
                guard event.magnification.isFinite else { return event }
                owner.zoom(max(0.1, 1 + Double(event.magnification)), point.x / view.bounds.width)
            } else if event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 {
                let delta = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.12)
                owner.zoom(exp(max(-0.5, min(0.5, delta))), point.x / view.bounds.width)
            } else {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                guard delta != 0 else { return event }
                owner.pan(-Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 20) / view.bounds.width)
            }
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.owner = self }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var owner: TimelineNavigation?
        var monitor: Any?
    }
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
