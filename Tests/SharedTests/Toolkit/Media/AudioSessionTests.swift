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

    /// Repeat starts for the same user watch for interruptions once, so an interruption ending
    /// resumes that user once.
    @Test func repeatStartsResumeTheUserOnceAfterAnInterruption() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)

        postInterruption(.ended, options: .shouldResume)

        try await waitForTheResumes(of: user)
        #expect(user.plays == 1)
    }

    /// A session activated again after going to the background still watches for interruptions
    /// once, so it resumes its user once.
    @Test func aSessionActivatedAgainResumesTheUserOnceAfterAnInterruption() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.appDidEnterBackground()
        try #require(!session.isSessionStarted)
        session.start(with: user, isPlaying: false)

        postInterruption(.ended, options: .shouldResume)

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
        postInterruption(.ended, options: .shouldResume)
        try await waitForTheResumes(of: second)
        #expect(second.plays == 1)
        #expect(first.plays == 0)
    }

    /// A start for a user whose session is active does not activate it again.
    @Test func repeatStartsActivateTheSessionOnce() {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }

        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)
        session.start(with: user, isPlaying: false)

        #expect(session.activations == 1)
    }

    /// A failed activation leaves the session inactive, so the next start tries again.
    @Test func aFailedActivationIsTriedAgainOnTheNextStart() throws {
        let session = AudioSession()
        // Long-form audio cannot mix with others, so `setCategory` throws.
        let user = SessionUser(audioConfiguration: .init(
            category: .playback,
            routeSharingPolicy: .longFormAudio,
            options: [.mixWithOthers]
        ))
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        try #require(!session.isSessionStarted)
        try #require(session.activations == 0)

        user.audioConfiguration = .init()
        session.start(with: user, isPlaying: false)

        #expect(session.isSessionStarted)
        #expect(session.activations == 1)
    }

    /// The engine pausing for a call ends the session when the app is in the background, but the user
    /// stays, so the call ending still resumes it.
    @Test func aUserWhoseSessionEndedInTheBackgroundResumesAfterAnInterruption() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        session.appDidEnterBackground()
        try #require(!session.isSessionStarted)

        postInterruption(.ended, options: .shouldResume)

        try await waitForTheResumes(of: user)
        #expect(user.plays == 1)
    }

    /// The system deactivates the session when an interruption begins, so the next start activates
    /// it again.
    @Test func aStartAfterAnInterruptionBeganActivatesTheSessionAgain() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        postInterruption(.began)
        try await waitUntil { !session.isSessionStarted }

        session.start(with: user, isPlaying: false)

        #expect(session.isSessionStarted)
        #expect(session.activations == 2)
    }

    /// An interruption ending only asks the user to resume: the session turns on through the user's
    /// own start, so a user that refuses the resume, as a held book does, leaves it off.
    @Test func anInterruptionEndingActivatesNothingByItself() async throws {
        let session = AudioSession()
        let user = SessionUser()
        defer { session.end(for: user) }
        session.start(with: user, isPlaying: false)
        postInterruption(.began)
        try await waitUntil { !session.isSessionStarted }

        postInterruption(.ended, options: .shouldResume)

        try await waitForTheResumes(of: user)
        #expect(!session.isSessionStarted)
        #expect(session.activations == 1)
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

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 where !condition() {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(condition())
}

private func postInterruption(
    _ type: AVAudioSession.InterruptionType,
    options: AVAudioSession.InterruptionOptions = []
) {
    NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [
            AVAudioSessionInterruptionTypeKey: type.rawValue,
            AVAudioSessionInterruptionOptionKey: options.rawValue,
        ]
    )
}

private final class SessionUser: AudioSessionUser {
    var audioConfiguration: AudioSession.Configuration
    private(set) var plays = 0

    init(audioConfiguration: AudioSession.Configuration = .init()) {
        self.audioConfiguration = audioConfiguration
    }

    func play() {
        plays += 1
    }
}
