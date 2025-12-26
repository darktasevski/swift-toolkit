//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation

/// Audio playback engine implementation using AVPlayer.
///
/// This is the default engine that provides standard audio playback without
/// advanced DSP features. It's extracted from the original AudioNavigator
/// implementation for backwards compatibility.
@MainActor
public final class AVPlayerEngine: AudioPlaybackEngine {
    public weak var delegate: AudioPlaybackEngineDelegate?

    /// Interval between playback time updates sent to the delegate.
    public let timeUpdateInterval: TimeInterval

    public init(timeUpdateInterval: TimeInterval = 0.5) {
        self.timeUpdateInterval = timeUpdateInterval
    }

    // Note: No deinit - cleanup is handled by stop() which must be called before
    // the engine is deallocated. AudioNavigator.deinit ensures this by calling
    // engine.stop() via DispatchQueue.main.async. This pattern is necessary because
    // deinit runs in a nonisolated context and cannot access @MainActor properties.

    // MARK: - AudioPlaybackEngine

    public var state: AudioEnginePlaybackState {
        guard player.currentItem != nil else {
            return .stopped
        }
        switch player.timeControlStatus {
        case .paused:
            return .paused
        case .waitingToPlayAtSpecifiedRate:
            return .loading
        case .playing:
            return .playing
        @unknown default:
            return .loading
        }
    }

    public var currentTime: Double {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    public var duration: Double? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else {
            return nil
        }
        return duration.seconds
    }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var rate: Float {
        get { currentRate }
        set {
            currentRate = newValue
            if state == .playing {
                player.rate = newValue
            }
        }
    }

    public func load(_ asset: AVURLAsset, originalFileURL: URL?) async throws {
        // AVPlayer works with Readium's custom URL scheme via AVAssetResourceLoaderDelegate,
        // so we don't need the originalFileURL.
        let previousState = state
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // Notify delegate of state change
        if previousState != state {
            delegate?.engine(self, didChangeState: state)
        }

        // Reset loaded time ranges
        lastLoadedTimeRanges = []
        delegate?.engine(self, didUpdateLoadedTimeRanges: [])
    }

    public func play() {
        player.playImmediately(atRate: currentRate)
    }

    public func pause() {
        player.pause()
    }

    @discardableResult
    public func seek(to time: Double) async -> Bool {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        return await player.seek(to: cmTime)
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        cleanupObservers()
    }

    // MARK: - Private

    /// The stored playback rate (used when resuming playback).
    private var currentRate: Float = 1.0

    /// Tracks loaded time ranges to detect changes.
    private var lastLoadedTimeRanges: [Range<Double>] = []

    /// KVO observers.
    private var rateObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?

    /// Periodic time observer token.
    private var timeObserver: Any?

    /// Timer for loaded time ranges updates.
    private var loadedTimeRangesTimer: Timer?

    /// End of playback notification observer.
    private var endOfPlaybackObserver: NSObjectProtocol?

    private lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false

        setupObservers(for: player)

        return player
    }()

    private func setupObservers(for player: AVPlayer) {
        // Periodic time observer
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: timeUpdateInterval, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.isNumeric ? time.seconds : 0
            self.delegate?.engine(self, didUpdateTime: seconds)
        }

        // Rate observer (for play/pause detection)
        // Note: KVO callbacks run on arbitrary threads. We move the weak self check
        // inside the Task to avoid accessing @MainActor-isolated self from a non-isolated context.
        rateObserver = player.observe(\.rate, options: [.new, .old]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didChangeState: self.state)
            }
        }

        // Time control status observer
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .old]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didChangeState: self.state)
            }
        }

        // Current item observer
        currentItemObserver = player.observe(\.currentItem, options: [.new, .old]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didChangeState: self.state)
            }
        }

        // End of playback notification
        // Note: Using .main queue ensures the closure runs on main thread,
        // but we still wrap in Task for proper actor isolation.
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self, weak player] notification in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    let player,
                    let currentItem = player.currentItem,
                    currentItem == (notification.object as? AVPlayerItem)
                else {
                    return
                }
                self.delegate?.engineDidFinishPlaying(self)
            }
        }

        // Loaded time ranges timer
        // Use .common run loop mode so the timer fires even during scrolling/tracking
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }

                let ranges: [Range<Double>] = (self.player.currentItem?.loadedTimeRanges ?? [])
                    .map { value in
                        let range = value.timeRangeValue
                        let start = range.start.isNumeric ? range.start.seconds : 0
                        let duration = range.duration.isNumeric ? range.duration.seconds : 0
                        return start ..< (start + duration)
                    }

                guard ranges != self.lastLoadedTimeRanges else {
                    return
                }

                self.lastLoadedTimeRanges = ranges
                self.delegate?.engine(self, didUpdateLoadedTimeRanges: ranges)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadedTimeRangesTimer = timer
    }

    private func cleanupObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        rateObserver?.invalidate()
        rateObserver = nil

        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil

        currentItemObserver?.invalidate()
        currentItemObserver = nil

        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }

        loadedTimeRangesTimer?.invalidate()
        loadedTimeRangesTimer = nil
    }
}
