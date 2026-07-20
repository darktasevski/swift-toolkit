//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import AVFoundation
import ReadiumShared
import XCTest

@MainActor
final class AudioNavigatorAudioSessionTests: XCTestCase {
    func testPlayStartsInjectedAudioSession() async {
        let audioSession = RecordingAudioSessionManager()
        let (navigator, _) = makeNavigator(audioSession: audioSession)

        navigator.play()
        for _ in 0 ..< 10 where audioSession.startCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(audioSession.startCount, 1)
    }

    func testEngineStateChangesUseInjectedAudioSession() {
        let audioSession = RecordingAudioSessionManager()
        let (navigator, engine) = makeNavigator(audioSession: audioSession)

        engine.sendState(.playing)
        engine.sendState(.paused)

        XCTAssertEqual(audioSession.playingChanges, [true, false])
        _ = navigator
    }

    func testCloseEndsInjectedAudioSession() {
        let audioSession = RecordingAudioSessionManager()
        let (navigator, _) = makeNavigator(audioSession: audioSession)

        navigator.close()

        XCTAssertEqual(audioSession.endCount, 1)
    }

    func testCloseStopsPlaybackEngineSynchronously() {
        let audioSession = RecordingAudioSessionManager()
        let (navigator, engine) = makeNavigator(audioSession: audioSession)

        navigator.close()

        XCTAssertEqual(engine.stopCount, 1)
    }

    func testNavigatorIsReleasedAfterExplicitClose() {
        let audioSession = RecordingAudioSessionManager()
        weak var weakNavigator: AudioNavigator?

        autoreleasepool {
            var navigator: AudioNavigator? = makeNavigator(audioSession: audioSession).navigator
            weakNavigator = navigator
            navigator?.close()
            navigator = nil
        }

        XCTAssertNil(weakNavigator)
    }

    private func makeNavigator(
        audioSession: RecordingAudioSessionManager
    ) -> (navigator: AudioNavigator, engine: RecordingAudioPlaybackEngine) {
        let engine = RecordingAudioPlaybackEngine()
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test Audiobook"),
                readingOrder: [Link(href: "track.mp3", mediaType: .mp3, duration: 60)]
            )
        )
        let config = AudioNavigator.Configuration(engineFactory: { engine })
        let navigator = AudioNavigator(
            publication: publication,
            config: config,
            audioSession: audioSession
        )
        return (navigator, engine)
    }
}

private final class RecordingAudioSessionManager: AudioSessionManaging {
    private(set) var startCount = 0
    private(set) var endCount = 0
    private(set) var playingChanges: [Bool] = []

    func start(with user: AudioSessionUser, isPlaying: Bool) {
        startCount += 1
    }

    func end(for user: AudioSessionUser) {
        endCount += 1
    }

    func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool) {
        playingChanges.append(isPlaying)
    }
}

@MainActor
private final class RecordingAudioPlaybackEngine: AudioPlaybackEngine {
    weak var delegate: AudioPlaybackEngineDelegate?

    private(set) var state: AudioEnginePlaybackState = .stopped
    private(set) var currentTime: Double = 0
    private(set) var duration: Double? = 60
    var volume: Float = 1
    var rate: Float = 1
    private(set) var stopCount = 0

    func load(_ asset: AVURLAsset, originalFileURL: URL?) async throws {}

    func play() {
        sendState(.playing)
    }

    func pause() {
        sendState(.paused)
    }

    func seek(to time: Double) async -> Bool {
        currentTime = time
        return true
    }

    func stop() {
        stopCount += 1
        state = .stopped
    }

    func sendState(_ state: AudioEnginePlaybackState) {
        self.state = state
        delegate?.engine(self, didChangeState: state)
    }
}
