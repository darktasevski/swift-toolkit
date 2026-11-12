//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing

/// `start(from:)` starts the audio session before it returns, so the session is active by the time
/// the first utterance reaches the engine.
@MainActor
struct PublicationSpeechSynthesizerAudioSessionTests {
    @Test func startStartsTheAudioSessionBeforeReturning() throws {
        let audioSession = RecordingAudioSession()
        let synthesizer = try #require(PublicationSpeechSynthesizer(
            publication: makePublication(),
            audioSession: audioSession,
            engineFactory: { SilentTTSEngine() }
        ))
        defer { synthesizer.stop() }

        synthesizer.start()

        #expect(audioSession.starts == 1)
    }
}

// MARK: - Helpers

private func makePublication() -> Publication {
    Publication(
        manifest: Manifest(
            metadata: Metadata(conformsTo: [.epub], title: "Synthesizer session", languages: ["en"]),
            readingOrder: [Link(href: "chapter.xhtml", mediaType: .xhtml)]
        ),
        container: SingleResourceContainer(
            resource: DataResource(string: "<html><body><p>One sentence.</p></body></html>"),
            at: AnyURL(string: "chapter.xhtml")!
        ),
        servicesBuilder: PublicationServicesBuilder(content: DefaultContentService.makeFactory(
            resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
        ))
    )
}

private final class RecordingAudioSession: AudioSessionManaging {
    private(set) var starts = 0

    func start(with _: AudioSessionUser, isPlaying _: Bool) {
        starts += 1
    }

    func end(for _: AudioSessionUser) {}

    func user(_: AudioSessionUser, didChangePlaying _: Bool) {}
}

/// Speaks nothing; each utterance lasts until the synthesizer cancels it.
@MainActor
private final class SilentTTSEngine: TTSEngine {
    var availableVoices: [TTSVoice] {
        []
    }

    func voiceWithIdentifier(_: String) -> TTSVoice? {
        nil
    }

    func speak(
        _: TTSUtterance,
        onSpeakRange _: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        let (held, _) = AsyncStream<Never>.makeStream()
        for await _ in held {}
        return .success(())
    }
}
