//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import UIKit

/// An user of the `AudioSession`, for example a media player object.
public protocol AudioSessionUser: AnyObject {
    /// Audio session configuration to use for this user.
    var audioConfiguration: AudioSession.Configuration { get }

    /// Called when an audio interruption (e.g. phone call) finishes, to resume audio playback or
    /// recording.
    func play()
}

public extension AudioSessionUser {
    var audioConfiguration: AudioSession.Configuration {
        .init()
    }
}

/// Manages the app's audio session for Readium audio consumers.
public protocol AudioSessionManaging {
    /// Starts an audio session with the given `user`, active by the time it returns.
    @MainActor func start(with user: AudioSessionUser, isPlaying: Bool)

    /// Ends the current audio session.
    func end(for user: AudioSessionUser)

    /// Indicates whether the `user` is playing.
    func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool)
}

/// Manages an activated `AVAudioSession`.
@MainActor
public final class AudioSession: AudioSessionManaging, Loggable {
    public struct Configuration: Equatable {
        public let category: AVAudioSession.Category
        public let mode: AVAudioSession.Mode
        public let routeSharingPolicy: AVAudioSession.RouteSharingPolicy
        public let options: AVAudioSession.CategoryOptions

        public init(
            category: AVAudioSession.Category = .playback,
            mode: AVAudioSession.Mode = .default,
            routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .default,
            options: AVAudioSession.CategoryOptions = []
        ) {
            self.category = category
            self.mode = mode
            self.routeSharingPolicy = routeSharingPolicy
            self.options = options
        }
    }

    /// Shared `AudioSession` for this app.
    public nonisolated static let shared = AudioSession()

    /// Internal so a test can own an instance; the app uses `shared`.
    nonisolated init() {
        Task {
            await observeAppStateChanges()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    fileprivate struct User {
        let id: ObjectIdentifier
        private(set) weak var user: AudioSessionUser?

        init(_ user: AudioSessionUser) {
            id = ObjectIdentifier(user)
            self.user = user
        }
    }

    /// Current user of the `AudioSession`.
    private var user: User?

    /// Starts an audio session with the given `user`, active by the time it returns, so an engine the
    /// caller starts next plays in it. The current user gets its session back if it ended while the
    /// user stayed, as on going to the background while paused.
    public func start(with user: AudioSessionUser, isPlaying: Bool) {
        let id = ObjectIdentifier(user)
        if self.user?.id != id {
            if let oldUser = self.user {
                end(forUserID: oldUser.id)
            }
            self.user = User(user)
            self.isPlaying = false
            observeInterruptions()
        }

        startSession(with: user.audioConfiguration)
    }

    /// Ends the current audio session.
    public nonisolated func end(for user: AudioSessionUser) {
        let id = ObjectIdentifier(user)
        Task {
            await end(forUserID: id)
        }
    }

    private func end(forUserID id: ObjectIdentifier) {
        guard user?.id == id else {
            return
        }

        user = nil
        isPlaying = false

        endSession()
    }

    /// Indicates whether the `user` is playing.
    private var isPlaying: Bool = false

    public nonisolated func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool) {
        Task {
            await self.user(user, didChangePlaying: isPlaying)
        }
    }

    private func user(_ user: AudioSessionUser, didChangePlaying isPlaying: Bool) async {
        let id = ObjectIdentifier(user)
        guard self.user?.id == id, self.isPlaying != isPlaying else {
            return
        }

        self.isPlaying = isPlaying

        if isPlaying {
            startSession(with: user.audioConfiguration)
        } else if UIApplication.shared.applicationState != .active {
            endSession()
        }
    }

    // MARK: App background state

    private func observeAppStateChanges() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc func appDidEnterBackground() {
        if !isPlaying {
            endSession()
        }
    }

    // MARK: Session management

    /// Whether the session is active: set by an activation that succeeded, cleared when the session
    /// ends or an interruption begins.
    private(set) var isSessionStarted = false

    /// Activations that succeeded; internal, for tests.
    private(set) var activations = 0

    private func startSession(with config: Configuration) {
        guard !isSessionStarted else {
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(config.category, mode: config.mode, policy: config.routeSharingPolicy, options: config.options)
            try audioSession.setActive(true)
            isSessionStarted = true
            activations += 1
            log(.info, "Started audio session with category: \(config.category), mode: \(config.mode), policy: \(config.routeSharingPolicy), options: \(config.options)")
        } catch {
            // Left inactive, so the next start tries again.
            log(.error, "Failed to start the audio session: \(error)")
        }
    }

    private func endSession() {
        guard isSessionStarted else {
            return
        }

        do {
            AVAudioSession.sharedInstance()
            try AVAudioSession.sharedInstance().setActive(false)
            log(.info, "Ended audio session")
        } catch {
            log(.error, "Failed to end the audio session: \(error)")
        }

        isSessionStarted = false
    }

    /// Whether the audio session is currently interrupted, e.g. by a phone call.
    public private(set) var isInterrupted: Bool = false

    /// The observer of audio session interruption notifications.
    private var interruptionObserver: Any?

    /// Watches for interruptions from the first start on, active or not: a session ended in the
    /// background, after the engine paused for a call, must still hear the call end. The handler acts
    /// only for a current user, so the observer is never removed.
    private func observeInterruptions() {
        guard interruptionObserver == nil else {
            return
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioSessionInterruption(notification: notification)
        }
    }

    private nonisolated func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawInterruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawInterruptionType)
        else {
            return
        }

        let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
            .map(AVAudioSession.InterruptionOptions.init(rawValue:))
            ?? []

        Task {
            await handleAudioSessionInterruption(type: interruptionType, options: options)
        }
    }

    private func handleAudioSessionInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            isInterrupted = true
            // The system has deactivated the session, so the next start activates it again.
            isSessionStarted = false

        case .ended:
            isInterrupted = false

            // The session turns on again through the user's own start, once it admits the resume,
            // so a refused resume interrupts no other app's audio.
            if options.contains(.shouldResume), let user = user?.user {
                user.play()
            }

        @unknown default:
            break
        }
    }
}
