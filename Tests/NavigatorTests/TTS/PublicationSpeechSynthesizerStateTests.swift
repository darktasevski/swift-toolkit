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
/// while `play()` could be writing it.
@MainActor
final class PublicationSpeechSynthesizerStateTests: XCTestCase {
    func testTheDelegateHearsEachStateBeforeTheChangeReturns() async throws {
        let engine = HeldTTSEngine()
        let synthesizer = try XCTUnwrap(PublicationSpeechSynthesizer(
            publication: Self.publication(),
            audioSession: SilentAudioSessionManager(),
            engineFactory: { engine }
        ))
        let delegate = RecordingSynthesizerDelegate()
        synthesizer.delegate = delegate

        synthesizer.start()
        try await waitUntil("the first utterance is being spoken") { engine.started == 1 }
        let utterance = try XCTUnwrap(engine.utterances.first)
        guard case let .playing(playing, range: nil) = synthesizer.state else {
            return XCTFail("the synthesizer is not playing its first utterance: \(synthesizer.state)")
        }
        XCTAssertEqual(playing.text, utterance)

        synthesizer.pause()

        XCTAssertEqual(delegate.states, [.playing(playing, range: nil), .paused(playing)])
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), description)
    }

    private static func publication() -> Publication {
        Publication(
            manifest: Manifest(
                metadata: Metadata(conformsTo: [.epub], title: "Synthesizer state", languages: ["en"]),
                readingOrder: [Link(href: "chapter.xhtml", mediaType: .xhtml)]
            ),
            container: SingleResourceContainer(
                resource: DataResource(string: """
                <html><body><p>The first sentence is read aloud. The second follows it.</p></body></html>
                """),
                at: AnyURL(string: "chapter.xhtml")!
            ),
            servicesBuilder: PublicationServicesBuilder(content: DefaultContentService.makeFactory(
                resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
            ))
        )
    }
}

/// Speaks nothing: each utterance lasts until the synthesizer cancels it.
@MainActor
private final class HeldTTSEngine: TTSEngine {
    private(set) var started = 0
    private(set) var utterances: [String] = []

    var availableVoices: [TTSVoice] {
        []
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange _: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        started += 1
        utterances.append(utterance.text)
        let (held, _) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in held {}
        } onCancel: {}
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
