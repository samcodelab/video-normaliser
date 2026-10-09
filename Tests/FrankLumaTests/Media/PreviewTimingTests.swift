import XCTest
import AVFoundation
import CoreImage
@testable import FrankLuma

final class PreviewTimingTests: XCTestCase {
    func testFlashFrameRequestIsInsideItsSampleAtTwelveFPS() {
        let start = 13.0/12, end = 14.0/12
        let request = PreviewTiming.interiorTime(start: start, end: end)
        XCTAssertGreaterThan(request, start)
        XCTAssertLessThan(request, end)
        let curve = ExposureCurve(times: [12.0/12,start,end], stops: [-0.05,0.38,-0.04])
        XCTAssertEqual(curve.value(at: request),0.38)
        // An unexpectedly earlier decoded sample must receive its own gain.
        XCTAssertEqual(curve.value(at: 12.0/12),-0.05)
    }
    func testVariableSampleDurationsAndFinalSample() {
        for (start,end) in [(0.0,0.04),(0.04,0.21),(7.083333333,7.166666667)] {
            let request=PreviewTiming.interiorTime(start:start,end:end)
            XCTAssertGreaterThan(request,start)
            XCTAssertLessThan(request,end)
        }
        XCTAssertEqual(PreviewTiming.interiorTime(start:2,end:nil),2)
    }

    @MainActor
    func testSceneLoopUsesVariableFrameCutAndFinalSceneEndAndScrubbingCancelsPlayback() async {
        let model = AppModel()
        model.info = VideoInfo(duration: 0.5, width: 640, height: 360, fps: 12, hasAudio: false, isHDR: false)
        model.result = AnalysisResult(samples: [0.0, 0.04, 0.125, 0.3].map {
            ExposureSample(time: $0, level: 0, segment: 0)
        }, uncertainFrames: 0, cuts: 1)
        model.sceneBoundaries = [2]
        let item = AVPlayerItem(asset: AVMutableComposition())
        model.player.replaceCurrentItem(with: item)
        model.loopSelectedScene = true
        model.togglePlayback()
        XCTAssertEqual(item.forwardPlaybackEndTime.seconds, 0.125, accuracy: 0.000001)
        model.seekFrame(2)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(item.forwardPlaybackEndTime.isValid)
        model.togglePlayback()
        XCTAssertEqual(item.forwardPlaybackEndTime.seconds, 0.5, accuracy: 0.000001)
        model.loopSelectedScene = false
        XCTAssertFalse(item.forwardPlaybackEndTime.isValid)
        model.togglePlayback() // Pause after changing the option during playback.
        await Task.yield()
        XCTAssertFalse(model.isPlaying)
        model.closeSession()
    }

    func testCorrectedStillIsRenderedBeforePreviewDownsampling() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FrankLuma Demo.mov")
        var field = SpatialField()
        field.surface = .init(width: 4,height: 3,
            channelEV: (0..<12).flatMap { p -> [Float] in p%4 < 2 ? [0.8,0.4,0.2] : [-0.4,0.2,0.5] },
            guide: (0..<12).flatMap { p -> [Float] in p%4 < 2 ? [0.1,0.15,0.2] : [0.4,0.3,0.2] })
        let curve = ExposureCurve(times: [0],stops: [0.2],spatial: [field])
        let full = try await VideoEngine.preview(url: source,time: 0,curve: curve,maximumSize: CGSize(width: 10000,height: 10000))
        let small = try await VideoEngine.preview(url: source,time: 0,curve: curve,maximumSize: CGSize(width: 160,height: 100))
        let scale = min(160/Double(full.width),100/Double(full.height))
        let expected = CIImage(cgImage: full).applyingFilter("CILanczosScaleTransform",parameters: [kCIInputScaleKey: scale,kCIInputAspectRatioKey: 1])
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
        let bounds = CGRect(x: 0,y: 0,width: small.width,height: small.height)
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0,count: small.width*small.height*4)
            bytes.withUnsafeMutableBytes { context.render(image,toBitmap: $0.baseAddress!,rowBytes: small.width*4,bounds: bounds,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
            return bytes
        }
        let actual = pixels(CIImage(cgImage: small)), reference = pixels(expected)
        let meanError = zip(actual,reference).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1)) }/Double(actual.count)
        XCTAssertLessThan(meanError,1.0) // One encoded display level, including CGImage quantisation.
    }

    @MainActor
    func testNativePlaybackRepeatsSceneAndPauseStopsRewinds() async throws {
        let repositoryDemo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FrankLuma Demo.mov")
        let source = Bundle.main.url(forResource: "FrankLuma Demo", withExtension: "mov") ?? repositoryDemo
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Native playback requires the bundled or repository demo movie")
        }
        let model = AppModel()
        model.info = try await VideoEngine.info(for: AVURLAsset(url: source))
        model.result = AnalysisResult(samples: [0.0, 0.1, 0.2, 0.3].map {
            ExposureSample(time: $0, level: 0, segment: 0)
        }, uncertainFrames: 0, cuts: 1)
        model.sceneBoundaries = [3]
        let item = AVPlayerItem(url: source)
        model.player.replaceCurrentItem(with: item)
        let ended = expectation(description: "Scene repeats twice")
        ended.expectedFulfillmentCount = 2
        ended.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in ended.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer); model.closeSession() }
        model.loopSelectedScene = true
        model.togglePlayback()
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(model.selectedSceneStart, 0)
        XCTAssertLessThan(model.playhead, 0.3)
        model.togglePlayback()
        let paused = model.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.player.currentTime().seconds, paused, accuracy: 0.001)
    }
}
