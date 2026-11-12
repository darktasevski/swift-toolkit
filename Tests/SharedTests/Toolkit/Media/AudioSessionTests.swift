//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
@testable import ReadiumShared
import Testing

/// `start(with:isPlaying:)` has activated the session by the time it returns, so a caller that
/// starts its engine next plays in an active session.
@MainActor
@Suite(.serialized)
struct AudioSessionTests {
    @Test func startActivatesTheSessionBeforeReturning() {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }

        session.start(with: user, isPlaying: false)

        #expect(session.isSessionStarted)
    }

    /// Going to the background while paused ends the session but keeps its user, so the user's next
    /// start must activate it again.
    @Test func startActivatesAgainASessionEndedForItsUser() throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.appDidEnterBackground()
        try #require(!session.isSessionStarted)

        session.start(with: user, isPlaying: false)

        #expect(session.isSessionStarted)
    }

    /// A start for a user whose session is active neither activates it again nor watches for
    /// interruptions a second time, so an interruption ending resumes that user once.
    @Test func repeatStartsResumeTheUserOnceAfterAnInterruption() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)

        postInterruptionEndedShouldResume()

        try await waitForTheResumes(of: user)
        #expect(user.plays == 1)
    }

    /// Ending a session stops its watch for interruptions, so a session activated again after going
    /// to the background resumes its user once.
    @Test func aSessionActivatedAgainResumesTheUserOnceAfterAnInterruption() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.appDidEnterBackground()
        try #require(!session.isSessionStarted)
        session.start(with: user, isPlaying: false)

        postInterruptionEndedShouldResume()

        try await waitForTheResumes(of: user)
        #expect(user.plays == 1)
    }

    /// A start for another user ends the current user's session and starts the new user's in its
    /// configuration, so an interruption ending then resumes only the new user.
    @Test func startForAnotherUserHandsTheSessionOver() async throws {
        let session = AudioSession()
        let first = SessionUser(audioConfiguration: .init(category: .playback))
        let second = SessionUser(audioConfiguration: .init(category: .ambient))
        defer { session.end(for: second) }
        session.start(with: first, isPlaying: false)

        session.start(with: second, isPlaying: false)

        #expect(AVAudioSession.sharedInstance().category == .ambient)
        postInterruptionEndedShouldResume()
        try await waitForTheResumes(of: second)
        #expect(second.plays == 1)
        #expect(first.plays == 0)
    }
}

// MARK: - Helpers

/// Each interruption handler resumes on a later main-actor turn, so after the first resume the wait
/// stays a while longer for any duplicate.
@MainActor
private func waitForTheResumes(of user: SessionUser) async throws {
    for _ in 0 ..< 200 where user.plays == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(user.plays > 0, "the interruption never resumed the user")
    try await Task.sleep(nanoseconds: 300_000_000)
}

private func postInterruptionEndedShouldResume() {
    NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]
    )
}

private final class SessionUser: AudioSessionUser {
    let audioConfiguration: AudioSession.Configuration
    private(set) var plays = 0

    init(audioConfiguration: AudioSession.Configuration = .init()) {
        self.audioConfiguration = audioConfiguration
    }

    func play() {
        plays += 1
    }
}
