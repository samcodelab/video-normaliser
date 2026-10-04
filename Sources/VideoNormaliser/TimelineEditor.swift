import SwiftUI

private let timelineAccent = Color(red: 0.70, green: 0.87, blue: 0.46)

struct TimelineEditor: View {
    @ObservedObject var model: AppModel
    @State private var draggingBoundary: Int?
    @State private var draftTime: Double?
    private let plotHeight = 98.0
    private var duration: Double { max(0.001, model.info?.duration ?? 1) }

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
                legend("After global correction", colour: timelineAccent, dashed: false)
                Spacer()
                Text("Global estimate · local field shown in preview diagnostics")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    plot(width: geometry.size.width)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard !model.busy else { return }
                            model.seek(toTime: max(0, min(duration, value.location.x / geometry.size.width * duration)))
                        })
                    ForEach(model.scenes) { scene in
                        let x = scene.start / duration * geometry.size.width
                        let width = (scene.end - scene.start) / duration * geometry.size.width
                        Button { model.seek(to: scene) } label: {
                            Text(width > 55 ? "Scene \(scene.number)" : "\(scene.number)")
                                .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .frame(width: max(0, width - 2), height: 23)
                                .background(scene.startFrame == model.selectedSceneStart ? timelineAccent.opacity(0.3) : .white.opacity(0.06))
                                .foregroundStyle(scene.startFrame == model.selectedSceneStart ? timelineAccent : .secondary)
                        }.buttonStyle(.plain).offset(x: x, y: 0)
                            .help("Select scene \(scene.number)")
                    }
                    ForEach(model.scenes.dropFirst()) { scene in
                        boundaryHandle(scene: scene, width: geometry.size.width)
                    }
                    let playheadX = min(geometry.size.width, max(0, model.playhead / duration * geometry.size.width))
                    Path { path in
                        path.move(to: CGPoint(x: playheadX, y: 25))
                        path.addLine(to: CGPoint(x: playheadX, y: plotHeight + 25))
                    }.stroke(.white, lineWidth: 1.5).allowsHitTesting(false)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11))
                        .foregroundStyle(.white).position(x: playheadX, y: 29).allowsHitTesting(false)
                }
            }.frame(height: plotHeight + 25).clipped()
            HStack {
                Text("Click or drag to scrub · Orange handles move cuts")
                Spacer()
                if model.result != nil {
                    Text(String(format: "This frame %+.2f EV", model.curve.value(at: model.playhead)))
                        .monospacedDigit().foregroundStyle(timelineAccent)
                        .help("Exposure adjustment for this frame in the corrected preview and export. Positive brightens; negative darkens.")
                }
                Text(String(format: "Peak correction %.2f EV", model.curve.peak)).foregroundStyle(timelineAccent)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
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
            Spacer()
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
            .offset(x: time / duration * width - 9)
            .highPriorityGesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !model.busy, let result = model.result else { return }
                    draggingBoundary = scene.startFrame
                    let requested = scene.start + value.translation.width / width * duration
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
                let rect = CGRect(x: scene.start / duration * width, y: top,
                                  width: (scene.end - scene.start) / duration * width, height: plotHeight)
                context.fill(Path(rect), with: .color(timelineAccent.opacity(0.04)))
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
                         at: CGPoint(x: width - 3, y: top + plotHeight - 8), anchor: .trailing)
            for (values, colour, dashed) in [(exposure.original, Color.cyan, true), (exposure.corrected, timelineAccent, false)] {
                var path = Path()
                for scene in model.scenes {
                    let end = scene.startFrame + scene.frameCount
                    let strideSize = max(1, scene.frameCount / max(1, Int((scene.end - scene.start) / duration * width)))
                    var first = true
                    for index in stride(from: scene.startFrame, to: end, by: strideSize) {
                        let upper = min(index + strideSize, end)
                        let value = values[index..<upper].max(by: { abs($0) < abs($1) }) ?? 0
                        let point = CGPoint(x: exposure.times[index] / duration * width, y: middle - value / range * plotHeight / 2)
                        if first { path.move(to: point); first = false } else { path.addLine(to: point) }
                    }
                    // Extend the final held frame to the scene's end, without
                    // connecting exposure baselines across a scene cut.
                    path.addLine(to: CGPoint(x: scene.end / duration * width, y: middle - values[end - 1] / range * plotHeight / 2))
                }
                context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: dashed ? [4, 3] : []))
            }
        }
    }
}
