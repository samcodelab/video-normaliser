import XCTest
import AVFoundation
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

    @MainActor
    func testNativePlaybackRepeatsSceneAndPauseStopsRewinds() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "FrankLuma Demo", withExtension: "mov"))
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
