//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

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
}

private final class SessionUser: AudioSessionUser {
    func play() {}
}
