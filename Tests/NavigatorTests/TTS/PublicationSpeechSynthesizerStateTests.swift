//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// The synthesizer's state has one owner, the main actor, and its delegate hears each state as it
/// is set. A notification deferred to a task read `state` when that task ran, on another thread,
/// while `play()` could be writing it. A playback task that a later command superseded changes
/// nothing, and the next one starts only once it has returned.
@MainActor
final class PublicationSpeechSynthesizerStateTests: XCTestCase {
    func testTheDelegateHearsEachStateBeforeTheChangeReturns() async throws {
        let engine = HeldTTSEngine()
        let (synthesizer, delegate) = try makeSynthesizer(engine)

        synthesizer.start()
        try await waitUntil("the first utterance is being spoken") { engine.started >= 1 }
        let utterance = try XCTUnwrap(engine.utterances.first)
        guard case let .playing(playing, range: nil) = synthesizer.state else {
            return XCTFail("the synthesizer is not playing its first utterance: \(synthesizer.state)")
        }
        XCTAssertEqual(playing.text, utterance)

        synthesizer.pause()

        XCTAssertEqual(delegate.states, [.playing(playing, range: nil), .paused(playing)])
    }

    /// A word boundary the engine reported before the pause reached it refines nothing: the
    /// synthesizer stays paused.
    func testAWordRangeReportedAfterAPauseLeavesItPaused() async throws {
        let engine = HeldTTSEngine()
        let (synthesizer, delegate) = try makeSynthesizer(engine)
        synthesizer.start()
        try await waitUntil("the first utterance is being spoken") { engine.started >= 1 }
        let first = try XCTUnwrap(engine.utterances.first)
        let reportRange = try XCTUnwrap(engine.reportRange)
        guard case let .playing(playing, range: nil) = synthesizer.state else {
            return XCTFail("the synthesizer is not playing its first utterance: \(synthesizer.state)")
        }

        synthesizer.pause()
        reportRange(first.startIndex ..< first.index(after: first.startIndex))

        XCTAssertEqual(synthesizer.state, .paused(playing))
        XCTAssertEqual(delegate.states, [.playing(playing, range: nil), .paused(playing)])
    }

    /// Two skips in a row move two utterances on, and the one the second skip superseded never
    /// reaches the engine.
    func testASupersededSkipNeverReachesTheEngine() async throws {
        let engine = HeldTTSEngine()
        let (synthesizer, _) = try makeSynthesizer(engine)
        synthesizer.start()
        try await waitUntil("the first utterance is being spoken") { engine.started >= 1 }

        synthesizer.next()
        synthesizer.next()
        try await waitUntil("the third utterance is being spoken") { engine.started >= 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(engine.utterances, [Self.sentences[0], Self.sentences[2]])
    }

    /// Two skips across a paragraph end load the next paragraph once: the skip the second one
    /// superseded never advances the content iterator, so the next paragraph is spoken.
    func testTwoSkipsAtAParagraphEndSpeakTheNextParagraph() async throws {
        let engine = HeldTTSEngine()
        let (synthesizer, _) = try makeSynthesizer(engine, html: "<p>\(Self.sentences[0])</p><p>\(Self.sentences[1]) \(Self.sentences[2])</p>")
        synthesizer.start()
        try await waitUntil("the first paragraph is being spoken") { engine.started >= 1 }

        synthesizer.next()
        synthesizer.next()
        try await waitUntil("the second paragraph is being spoken") { engine.started >= 2 }

        XCTAssertEqual(engine.utterances, [Self.sentences[0], Self.sentences[1]])
    }

    /// A new command's utterance starts only once the engine has returned the one it interrupts,
    /// so two playback tasks never run at once.
    func testANewUtteranceWaitsForTheInterruptedOneToReturn() async throws {
        let engine = StubbornTTSEngine()
        let (synthesizer, _) = try makeSynthesizer(engine)
        synthesizer.start()
        try await waitUntil("the first utterance is being spoken") { engine.started >= 1 }

        synthesizer.next()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.started, 1, "the next utterance started before the interrupted one returned")

        engine.release()
        try await waitUntil("the next utterance is being spoken") { engine.started >= 2 }
        XCTAssertEqual(engine.utterances, [Self.sentences[0], Self.sentences[1]])
        engine.release()
    }

    private func makeSynthesizer(
        _ engine: TTSEngine,
        html: String = "<p>\(PublicationSpeechSynthesizerStateTests.sentences.joined(separator: " "))</p>"
    ) throws -> (PublicationSpeechSynthesizer, RecordingSynthesizerDelegate) {
        let synthesizer = try XCTUnwrap(PublicationSpeechSynthesizer(
            publication: Self.publication(html: html),
            audioSession: SilentAudioSessionManager(),
            engineFactory: { engine }
        ))
        let delegate = RecordingSynthesizerDelegate()
        synthesizer.delegate = delegate
        return (synthesizer, delegate)
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        var polls = 0
        while !condition(), polls < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertTrue(condition(), description)
    }

    private static let sentences = [
        "The first sentence is read aloud.",
        "The second follows it.",
        "The third ends the paragraph.",
    ]

    private static func publication(html: String) -> Publication {
        Publication(
            manifest: Manifest(
                metadata: Metadata(conformsTo: [.epub], title: "Synthesizer state", languages: ["en"]),
                readingOrder: [Link(href: "chapter.xhtml", mediaType: .xhtml)]
            ),
            container: SingleResourceContainer(
                resource: DataResource(string: "<html><body>\(html)</body></html>"),
                at: AnyURL(string: "chapter.xhtml")!
            ),
            servicesBuilder: PublicationServicesBuilder(content: DefaultContentService.makeFactory(
                resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
            ))
        )
    }
}

/// Speaks nothing: each utterance lasts until the synthesizer cancels it. It keeps the last
/// utterance's word-range callback, so a test can report a word boundary late.
@MainActor
private final class HeldTTSEngine: TTSEngine {
    private(set) var started = 0
    private(set) var utterances: [String] = []
    private(set) var reportRange: ((Range<String.Index>) -> Void)?

    var availableVoices: [TTSVoice] {
        []
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        started += 1
        utterances.append(utterance.text)
        reportRange = onSpeakRange
        let (held, _) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in held {}
        } onCancel: {}
        return .success(())
    }
}

/// Speaks nothing, and returns an utterance only when the test releases it, cancelled or not: an
/// engine whose stop takes time.
@MainActor
private final class StubbornTTSEngine: TTSEngine {
    private(set) var started = 0
    private(set) var utterances: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var availableVoices: [TTSVoice] {
        []
    }

    func release() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange _: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        started += 1
        utterances.append(utterance.text)
        await withCheckedContinuation { waiting.append($0) }
        return .success(())
    }
}

@MainActor
private final class RecordingSynthesizerDelegate: PublicationSpeechSynthesizerDelegate {
    private(set) var states: [PublicationSpeechSynthesizer.State] = []

    func publicationSpeechSynthesizer(
        _: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        states.append(state)
    }

    func publicationSpeechSynthesizer(
        _: PublicationSpeechSynthesizer,
        utterance _: PublicationSpeechSynthesizer.Utterance,
        didFailWithError _: PublicationSpeechSynthesizer.Error
    ) {}
}

private final class SilentAudioSessionManager: AudioSessionManaging {
    func start(with _: AudioSessionUser, isPlaying _: Bool) {}
    func end(for _: AudioSessionUser) {}
    func user(_: AudioSessionUser, didChangePlaying _: Bool) {}
}
