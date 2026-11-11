//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
@testable import ReadiumNavigator
import ReadiumShared
import Testing

/// Every start the navigator makes meets its delegate's answer at the moment it would play, and a
/// pause wins over a start still pending: a play whose first resource is loading, the restart after
/// a seek, or the advance to the next resource.
@MainActor
struct AudioNavigatorStartTests {
    @MainActor
    struct Pause {
        @Test func cancelsAPendingPlay() async {
            let fixture = StartFixture()

            fixture.navigator.play()
            fixture.navigator.pause()
            await settle()

            #expect(fixture.engine.playCount == 0)
            #expect(fixture.audioSession.startCount == 0)
        }

        @Test func cancelsAPlayWhoseFirstResourceIsLoading() async throws {
            let fixture = StartFixture()
            fixture.engine.holdsLoads = true

            fixture.navigator.play()
            try await waitUntil { fixture.engine.loadCount == 1 }
            fixture.navigator.pause()
            fixture.engine.releaseLoad()
            try await Task.sleep(nanoseconds: boundedWait)

            #expect(fixture.engine.playCount == 0)
        }

        @Test func cancelsASeekRestart() async throws {
            let fixture = try await StartFixture.playing()

            await fixture.navigator.seek(to: 10)
            fixture.navigator.pause()
            await settle()

            #expect(fixture.engine.playCount == 1)
        }

        @Test func cancelsAPendingAdvance() async throws {
            let fixture = try await StartFixture.advancing()

            fixture.navigator.pause()
            fixture.engine.releaseLoad()
            try await Task.sleep(nanoseconds: boundedWait)

            #expect(fixture.engine.playCount == 1)
        }
    }

    @MainActor
    struct Restart {
        @Test func seekWhilePlayingPlaysAgain() async throws {
            let fixture = try await StartFixture.playing()

            await fixture.navigator.seek(to: 10)

            try await waitUntil { fixture.engine.playCount == 2 }
        }

        @Test func advancePlaysTheNextResource() async throws {
            let fixture = try await StartFixture.advancing()

            fixture.engine.releaseLoad()
            try await Task.sleep(nanoseconds: boundedWait)

            #expect(fixture.engine.playCount == 2)
        }
    }

    @MainActor
    struct Gate {
        @Test func refusedStartLeavesTheEnginePaused() async {
            let fixture = StartFixture()
            fixture.delegate.answers = [false]

            fixture.navigator.play()
            await settle()

            #expect(fixture.engine.playCount == 0)
            #expect(fixture.audioSession.startCount == 0)
        }

        @Test func isAskedAgainOnceTheFirstResourceLoads() async throws {
            let fixture = StartFixture()
            fixture.delegate.answers = [true, false]

            fixture.navigator.play()
            try await waitUntil { fixture.delegate.askCount == 2 }
            await settle()

            #expect(fixture.engine.loadCount == 1)
            #expect(fixture.engine.playCount == 0)
        }

        /// A start refused once the first resource has loaded leaves the audio session off, so other
        /// apps' audio is never interrupted for a start that does not play.
        @Test func refusalAfterTheFirstLoadStartsNoAudioSession() async throws {
            let fixture = StartFixture()
            fixture.delegate.answers = [true, false]

            fixture.navigator.play()
            try await waitUntil { fixture.delegate.askCount == 2 }
            await settle()

            #expect(fixture.audioSession.startCount == 0)
        }

        @Test func refusesASeekRestart() async throws {
            let fixture = try await StartFixture.playing()
            fixture.delegate.answers = [false]

            await fixture.navigator.seek(to: 10)
            await settle()

            #expect(fixture.engine.playCount == 1)
        }

        /// `Restart.advancePlaysTheNextResource` is the positive control: the same release, admitted,
        /// plays within the bound.
        @Test func refusesAnAdvance() async throws {
            let fixture = try await StartFixture.advancing()
            fixture.delegate.answers = [false]

            fixture.engine.releaseLoad()
            try await Task.sleep(nanoseconds: boundedWait)

            #expect(fixture.engine.loadCount == 2)
            #expect(fixture.engine.playCount == 1)
        }
    }

    @MainActor
    struct Toggle {
        @Test func pausesAPendingStart() async {
            let fixture = StartFixture()

            fixture.navigator.play()
            fixture.navigator.playPause()
            await settle()

            #expect(fixture.engine.playCount == 0)
            #expect(fixture.audioSession.startCount == 0)
        }

        @Test func startsAgainAfterAStartRanToItsEnd() async throws {
            let fixture = try await StartFixture.playing()
            fixture.engine.stopOnItsOwn()

            fixture.navigator.playPause()

            try await waitUntil { fixture.engine.playCount == 2 }
        }

        /// The advance off the last resource ends without a play, so it must not stay the pending
        /// start the toggle would cancel.
        @Test func startsAgainAfterTheLastResourceEnds() async throws {
            let fixture = try await StartFixture.playing()

            fixture.engine.finish()
            try await waitUntil { fixture.delegate.nextResourceAskCount == 1 }
            await settle()
            fixture.navigator.playPause()

            try await waitUntil { fixture.engine.playCount == 2 }
        }

        @Test func startsAgainAfterTheNextResourceFailsToLoad() async throws {
            let fixture = try await StartFixture.playing(resources: 2)
            fixture.engine.failsLoads = true

            fixture.engine.finish()
            try await waitUntil { fixture.engine.loadCount == 2 }
            await settle()
            fixture.navigator.playPause()

            try await waitUntil { fixture.engine.playCount == 2 }
        }
    }

    @MainActor
    struct PendingPlay {
        /// Also the positive control for `cancelsAPlayWhoseFirstResourceIsLoading`: the same held load,
        /// released with no pause, plays within the bound.
        @Test func firstPlayStartsAfterItsOwnOpeningJump() async throws {
            let fixture = StartFixture()
            fixture.engine.holdsLoads = true

            fixture.navigator.play()
            try await waitUntil { fixture.engine.loadCount == 1 }
            fixture.engine.releaseLoad()
            try await Task.sleep(nanoseconds: boundedWait)

            #expect(fixture.engine.playCount == 1)
        }

        /// The session comes on only once the last gate check admits the start, and before the engine
        /// plays.
        @Test func startsTheSessionAfterTheLoadAndBeforeTheEngine() async throws {
            let fixture = StartFixture()

            fixture.navigator.play()
            try await waitUntil { fixture.engine.playCount == 1 }

            #expect(fixture.events.all == ["load", "session", "play"])
        }

        @Test func survivesASeek() async throws {
            let fixture = StartFixture()

            fixture.navigator.play()
            await fixture.navigator.seek(to: 10)

            try await waitUntil { fixture.engine.playCount == 1 }
        }
    }
}

// MARK: - Helpers

/// Long enough for a released load to end in a play. Each test that waits it out to see nothing
/// has a positive control that waits it out to see the play.
private let boundedWait: UInt64 = 300_000_000

@MainActor
private func settle() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    var polls = 0
    while !condition(), polls < 200 {
        try await Task.sleep(nanoseconds: 10_000_000)
        polls += 1
    }
    #expect(condition())
}

@MainActor
private final class StartFixture {
    let events = StartEvents()
    let engine: StartRecordingEngine
    let audioSession: StartRecordingAudioSession
    let delegate = StartDelegate()
    let navigator: AudioNavigator

    init(resources: Int = 1) {
        engine = StartRecordingEngine(events: events)
        audioSession = StartRecordingAudioSession(events: events)
        let readingOrder = (0 ..< resources).map {
            Link(href: "track\($0).mp3", mediaType: .mp3, duration: 60)
        }
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Test Audiobook"), readingOrder: readingOrder)
        )
        let engine = engine
        navigator = AudioNavigator(
            publication: publication,
            config: AudioNavigator.Configuration(engineFactory: { engine }),
            audioSession: audioSession
        )
        navigator.delegate = delegate
    }

    static func playing(resources: Int = 1) async throws -> StartFixture {
        let fixture = StartFixture(resources: resources)
        fixture.navigator.play()
        try await waitUntil { fixture.engine.playCount == 1 }
        await settle()
        return fixture
    }

    /// Playing the first of two resources, which has just finished: the advance to the second is
    /// pending, with its load held until `releaseLoad()`.
    static func advancing() async throws -> StartFixture {
        let fixture = try await playing(resources: 2)
        fixture.engine.holdsLoads = true
        fixture.engine.finish()
        try await waitUntil { fixture.engine.loadCount == 2 }
        return fixture
    }
}

@MainActor
private final class StartDelegate: AudioNavigatorDelegate {
    /// Answers in order; the last one repeats. Admits when empty.
    var answers: [Bool] = []
    private(set) var askCount = 0
    private(set) var nextResourceAskCount = 0

    func navigatorShouldStartPlayback(_: AudioNavigator) -> Bool {
        defer { askCount += 1 }
        guard !answers.isEmpty else { return true }
        return answers[min(askCount, answers.count - 1)]
    }

    func navigator(_: AudioNavigator, shouldPlayNextResource _: MediaPlaybackInfo) -> Bool {
        nextResourceAskCount += 1
        return true
    }

    func navigator(_: any Navigator, presentError _: NavigatorError) {}
}

/// The order in which the session and the engine are reached.
private final class StartEvents {
    private(set) var all: [String] = []

    func record(_ event: String) {
        all.append(event)
    }
}

private final class StartRecordingAudioSession: AudioSessionManaging {
    private let events: StartEvents
    private(set) var startCount = 0

    init(events: StartEvents) {
        self.events = events
    }

    func start(with _: AudioSessionUser, isPlaying _: Bool) {
        startCount += 1
        events.record("session")
    }

    func end(for _: AudioSessionUser) {}

    func user(_: AudioSessionUser, didChangePlaying _: Bool) {}
}

private enum StartRecordingEngineError: Error {
    case loadFailed
}

@MainActor
private final class StartRecordingEngine: AudioPlaybackEngine {
    weak var delegate: AudioPlaybackEngineDelegate?
    private let events: StartEvents

    init(events: StartEvents) {
        self.events = events
    }

    private(set) var state: AudioEnginePlaybackState = .stopped
    private(set) var currentTime: Double = 0
    let duration: Double? = 60
    var volume: Float = 1
    var rate: Float = 1
    private(set) var playCount = 0
    private(set) var loadCount = 0
    /// When set, each load waits for `releaseLoad()`.
    var holdsLoads = false
    /// When set, each load throws.
    var failsLoads = false
    private var heldLoad: CheckedContinuation<Void, Never>?

    func load(_: AVURLAsset, originalFileURL _: URL?) async throws {
        loadCount += 1
        events.record("load")
        if failsLoads {
            throw StartRecordingEngineError.loadFailed
        }
        if holdsLoads {
            await withCheckedContinuation { heldLoad = $0 }
        }
        state = .paused
    }

    func releaseLoad() {
        heldLoad?.resume()
        heldLoad = nil
    }

    func play() {
        playCount += 1
        events.record("play")
        send(.playing)
    }

    func pause() {
        guard state == .playing else { return }
        send(.paused)
    }

    func seek(to time: Double) async -> Bool {
        currentTime = time
        return true
    }

    func stop() {
        state = .stopped
    }

    /// Reaches the end of the resource, as the engine reports it.
    func finish() {
        send(.paused)
        delegate?.engineDidFinishPlaying(self)
    }

    /// Pauses without the navigator asking, short of the resource's end.
    func stopOnItsOwn() {
        send(.paused)
    }

    private func send(_ state: AudioEnginePlaybackState) {
        self.state = state
        delegate?.engine(self, didChangeState: state)
    }
}
