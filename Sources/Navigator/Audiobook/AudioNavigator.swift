//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared

/// Status of a played media resource.
public enum MediaPlaybackState: Hashable, Sendable {
    case paused
    case loading
    case playing
}

/// Holds metadata about a played media resource.
public struct MediaPlaybackInfo: Equatable, Sendable {
    /// Index of the current resource in the `readingOrder`.
    public let resourceIndex: Int

    /// Indicates whether the resource is currently playing or not.
    public let state: MediaPlaybackState

    /// Current playback position in the resource, in seconds.
    public let time: Double

    /// Duration in seconds of the resource, if known.
    public let duration: Double?

    /// Progress in the resource, from 0 to 1.
    public var progress: Double {
        guard let duration = duration else {
            return 0
        }
        return time / duration
    }

    public init(
        resourceIndex: Int = 0,
        state: MediaPlaybackState = .loading,
        time: Double = 0,
        duration: Double? = nil
    ) {
        self.resourceIndex = resourceIndex
        self.state = state
        self.time = time
        self.duration = duration
    }
}

@MainActor public protocol AudioNavigatorDelegate: NavigatorDelegate {
    /// Called when the playback updates.
    func navigator(_ navigator: AudioNavigator, playbackDidChange info: MediaPlaybackInfo)

    /// Called when the navigator finished playing the current resource.
    /// Returns whether the next resource should be played. Default is true.
    func navigator(_ navigator: AudioNavigator, shouldPlayNextResource info: MediaPlaybackInfo) -> Bool

    /// Called when the ranges of buffered media data change.
    /// Warning: They may be discontinuous.
    func navigator(_ navigator: AudioNavigator, loadedTimeRangesDidChange ranges: [Range<Double>])

    /// Called periodically with audio level data for visualization.
    /// - Parameters:
    ///   - navigator: The audio navigator.
    ///   - levels: Audio level data containing normalized levels (0.0 to 1.0).
    func navigator(_ navigator: AudioNavigator, didUpdateAudioLevels levels: AudioLevelData)
}

public extension AudioNavigatorDelegate {
    func navigator(_ navigator: AudioNavigator, playbackDidChange info: MediaPlaybackInfo) {}

    func navigator(_ navigator: AudioNavigator, shouldPlayNextResource info: MediaPlaybackInfo) -> Bool { true }

    func navigator(_ navigator: AudioNavigator, loadedTimeRangesDidChange ranges: [Range<Double>]) {}

    func navigator(_ navigator: AudioNavigator, didUpdateAudioLevels levels: AudioLevelData) {}
}

/// Navigator for audio-based publications such as:
///
/// * Readium Audiobook
/// * ZAB (Zipped Audio Book)
@MainActor
public final class AudioNavigator: Navigator, Configurable, AudioSessionUser, Loggable {
    public weak var delegate: AudioNavigatorDelegate?

    /// Factory for creating audio playback engines.
    public typealias EngineFactory = @MainActor () -> any AudioPlaybackEngine

    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: AudioPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: AudioDefaults

        /// Interval between two updates of the playback state.
        public var playbackRefreshInterval: TimeInterval

        /// Custom configuration for the audio session.
        public var audioSession: AudioSession.Configuration

        /// Factory to create the audio playback engine.
        /// Defaults to `AVPlayerEngine` for backwards compatibility.
        public var engineFactory: EngineFactory?

        /// The source file URL for the publication.
        /// Required for `EnhancedAudioEngine` which needs direct file access.
        /// For standalone audio files (MP3, etc.), this should be the file URL.
        /// For packaged audiobooks (LCP, etc.), this should be the container URL.
        public var sourceURL: URL?

        public init(
            preferences: AudioPreferences = AudioPreferences(),
            defaults: AudioDefaults = AudioDefaults(),
            playbackRefreshInterval: TimeInterval = 0.5,
            audioSession: AudioSession.Configuration = .init(
                category: .playback,
                mode: .spokenAudio,
                routeSharingPolicy: .longFormAudio
            ),
            engineFactory: EngineFactory? = nil,
            sourceURL: URL? = nil
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.playbackRefreshInterval = playbackRefreshInterval
            self.audioSession = audioSession
            self.engineFactory = engineFactory
            self.sourceURL = sourceURL
        }
    }

    public nonisolated let publication: Publication
    private let initialLocation: Locator?
    private let config: Configuration

    public var audioConfiguration: AudioSession.Configuration { config.audioSession }

    /// The audio playback engine used by this navigator.
    public let engine: any AudioPlaybackEngine

    public init(
        publication: Publication,
        initialLocation: Locator? = nil,
        config: Configuration = Configuration()
    ) {
        self.publication = publication
        self.initialLocation = initialLocation
        self.config = config

        let durations = publication.readingOrder.map { $0.duration ?? 0 }
        let totalDuration = durations.reduce(0, +)

        self.durations = durations
        self.totalDuration = (totalDuration > 0) ? totalDuration : nil

        settings = AudioSettings(
            preferences: config.preferences,
            defaults: config.defaults
        )

        // Create the audio engine using the factory or default to AVPlayerEngine
        if let factory = config.engineFactory {
            engine = factory()
        } else {
            engine = AVPlayerEngine(timeUpdateInterval: config.playbackRefreshInterval)
        }

        // Set initial engine settings
        engine.volume = Float(settings.volume)
        engine.rate = Float(settings.speed)

        // Set up engine delegate
        engine.delegate = self
    }

    deinit {
        playTask?.cancel()

        // AudioSession.end(for:) is nonisolated and only captures ObjectIdentifier,
        // so it's safe to call from deinit
        AudioSession.shared.end(for: self)

        // Engine cleanup must run on main thread. We capture the engine reference
        // and dispatch async. The engine will clean up its observers.
        // Note: Prefer calling close() explicitly before releasing the navigator
        // to ensure cleanup completes synchronously.
        let engine = self.engine
        DispatchQueue.main.async {
            engine.stop()
        }
    }

    /// Explicitly closes the navigator and releases all resources.
    ///
    /// Call this method before releasing the navigator to ensure proper cleanup.
    /// While deinit will also clean up resources, calling close() explicitly
    /// guarantees synchronous cleanup and is recommended for deterministic behavior.
    public func close() {
        playTask?.cancel()
        playTask = nil
        AudioSession.shared.end(for: self)
        engine.stop()
    }

    /// Returns whether the resource is currently playing or not.
    public var state: MediaPlaybackState {
        MediaPlaybackState(engine.state)
    }

    /// Current playback info.
    public var playbackInfo: MediaPlaybackInfo {
        MediaPlaybackInfo(
            resourceIndex: resourceIndex,
            state: state,
            time: currentTime,
            duration: resourceDuration
        )
    }

    /// Index of the current resource in the reading order.
    private var resourceIndex: Int = 0

    /// Starting time of the current resource, in the reading order.
    private var resourceStartingTime: Double? {
        durations[..<resourceIndex].reduce(0, +)
    }

    /// Duration in seconds in the current resource.
    private var resourceDuration: Double? {
        if let duration = engine.duration {
            return duration
        } else {
            return publication.readingOrder[resourceIndex].duration
        }
    }

    /// Total duration in the publication.
    public private(set) var totalDuration: Double?

    /// Durations indexed by reading order position.
    private let durations: [Double]

    public var currentTime: Double {
        engine.currentTime
    }

    /// Whether an asset is currently loaded in the engine.
    private var hasLoadedAsset: Bool = false

    private var playTask: Task<Void, Never>? {
        willSet {
            playTask?.cancel()
        }
    }

    /// Preloads the first resource to make duration available without starting playback.
    ///
    /// Call this after initialization to show duration in the UI before the user presses play.
    public func preload() async {
        guard !hasLoadedAsset else { return }

        if let location = initialLocation {
            await go(to: location, options: NavigatorGoOptions(animated: false))
        } else if let link = publication.readingOrder.first {
            await go(to: link, options: NavigatorGoOptions(animated: false))
        }
    }

    /// Resumes or start the playback.
    public func play() {
        playTask = Task { @MainActor in
            AudioSession.shared.start(with: self, isPlaying: false)

            if !hasLoadedAsset {
                if let location = initialLocation {
                    await go(to: location)
                } else if let link = publication.readingOrder.first {
                    await go(to: link)
                }
            }
            // Apply speed before starting playback (not applied when paused)
            engine.rate = Float(settings.speed)
            engine.play()
        }
    }

    /// Pauses the playback.
    public func pause() {
        engine.pause()
    }

    /// Toggles the playback.
    public func playPause() {
        switch state {
        case .loading, .playing:
            pause()
        case .paused:
            play()
        }
    }

    /// Seeks to the given time in the current resource.
    public func seek(to time: Double) async {
        let wasPlaying = (state == .playing)
        pause()

        await engine.seek(to: time)

        if wasPlaying {
            play()
        }
    }

    /// Seeks relatively from the current time in the current resource.
    public func seek(by delta: Double) async {
        await seek(to: currentTime + delta)
    }

    private lazy var mediaLoader = PublicationMediaLoader(publication: publication)

    private func playbackDidChange(_ time: Double? = nil) {
        if let time = time {
            let locator = makeLocator(forTime: time)
            currentLocation = locator
            Task { @MainActor in
                delegate?.navigator(self, locationDidChange: locator)
            }
        }

        makePlaybackInfo(forTime: time) { info in
            self.delegate?.navigator(self, playbackDidChange: info)
        }
    }

    /// A deadlock can occur when loading HTTP assets and creating the playback info from the main thread.
    /// To fix this, this is an asynchronous operation.
    private func makePlaybackInfo(forTime time: Double? = nil, completion: @escaping @MainActor (MediaPlaybackInfo) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let info = MediaPlaybackInfo(
                resourceIndex: self.resourceIndex,
                state: self.state,
                time: time ?? self.currentTime,
                duration: self.resourceDuration
            )

            DispatchQueue.main.async {
                completion(info)
            }
        }
    }

    private func makeLocator(forTime time: Double) -> Locator {
        let link = publication.readingOrder[resourceIndex]

        var progression: Double?
        if let duration = resourceDuration, duration > 0 {
            progression = resourceDuration.map { time / max($0, 1) }
        }

        var totalProgression: Double? = nil
        if let totalDuration = totalDuration, totalDuration > 0, let startingTime = resourceStartingTime {
            totalProgression = (startingTime + time) / totalDuration
        }

        return Locator(
            href: link.url(),
            mediaType: link.mediaType ?? MediaType("audio/*")!,
            title: link.title,
            locations: Locator.Locations(
                fragments: ["t=\(time)"],
                progression: progression,
                totalProgression: totalProgression
            )
        )
    }

    // MARK: - Navigator

    public private(set) var currentLocation: Locator?

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        let wasPlaying = (state == .playing)
        pause()

        guard let newResourceIndex = publication.readingOrder.firstIndexWithHREF(locator.href) else {
            return false
        }
        let link = publication.readingOrder[newResourceIndex]

        do {
            currentLocation = locator
            // Loads resource
            if !hasLoadedAsset || resourceIndex != newResourceIndex {
                log(.info, "Starts playing \(link.href)")
                let asset = try mediaLoader.makeAsset(for: link)
                // For engines that need direct file access (like EnhancedAudioEngine),
                // use the sourceURL from configuration. This is necessary because
                // Readium's virtual URL scheme doesn't work with AVAudioFile.
                try await engine.load(asset, originalFileURL: config.sourceURL)
                hasLoadedAsset = true
                resourceIndex = newResourceIndex
                await delegate?.navigator(self, loadedTimeRangesDidChange: [])
            }

            // Seeks to time
            let time = locator.locations.time?.begin ?? ((resourceDuration ?? 0) * (locator.locations.progression ?? 0))

            let finished = await engine.seek(to: time)
            if finished {
                await delegate?.navigator(self, didJumpTo: locator)
            }

            if wasPlaying {
                play()
            }

            return true

        } catch {
            log(.error, error)
            return false
        }
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
    }

    /// Indicates whether the navigator can go to the next content portion
    /// (e.g. page or audiobook resource).
    public var canGoForward: Bool {
        publication.readingOrder.indices.contains(resourceIndex + 1)
    }

    /// Indicates whether the navigator can go to the next content portion
    /// (e.g. page or audiobook resource).
    public var canGoBackward: Bool {
        publication.readingOrder.indices.contains(resourceIndex - 1)
    }

    public func goForward(options: NavigatorGoOptions) async -> Bool {
        await goToResourceIndex(resourceIndex + 1, options: options)
    }

    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        await goToResourceIndex(resourceIndex - 1, options: options)
    }

    @discardableResult
    private func goToResourceIndex(_ index: Int, options: NavigatorGoOptions) async -> Bool {
        guard publication.readingOrder.indices ~= index else {
            return false
        }
        return await go(to: publication.readingOrder[index], options: options)
    }

    // MARK: - Configurable

    public private(set) var settings: AudioSettings

    public func submitPreferences(_ preferences: AudioPreferences) {
        settings = AudioSettings(
            preferences: preferences,
            defaults: config.defaults
        )

        engine.volume = Float(settings.volume)

        // We don't directly change engine rate when paused, as it would start playback.
        // The rate is applied when play() is called.
        if state != .paused {
            engine.rate = Float(settings.speed)
        }

        // Apply enhancement settings if engine supports them
        if let enhancedEngine = engine as? EnhancedAudioPlaybackEngine {
            enhancedEngine.enhancementConfiguration = settings.enhancement
        }
    }

    public func editor(of preferences: AudioPreferences) -> AudioPreferencesEditor {
        AudioPreferencesEditor(
            initialPreferences: preferences,
            defaults: config.defaults
        )
    }
}

// MARK: - AudioPlaybackEngineDelegate

extension AudioNavigator: AudioPlaybackEngineDelegate {
    public func engine(_ engine: any AudioPlaybackEngine, didUpdateTime time: Double) {
        playbackDidChange(time)
    }

    public func engine(_ engine: any AudioPlaybackEngine, didChangeState engineState: AudioEnginePlaybackState) {
        let session = AudioSession.shared
        switch engineState {
        case .stopped, .paused:
            session.user(self, didChangePlaying: false)
        case .loading, .playing:
            session.user(self, didChangePlaying: true)
        }
        playbackDidChange()
    }

    public func engineDidFinishPlaying(_ engine: any AudioPlaybackEngine) {
        shouldPlayNextResource { [weak self] playNext in
            guard let self else { return }
            Task {
                if playNext, await self.goForward() {
                    self.play()
                }
            }
        }
    }

    public func engine(_ engine: any AudioPlaybackEngine, didUpdateLoadedTimeRanges ranges: [Range<Double>]) {
        Task { @MainActor in
            delegate?.navigator(self, loadedTimeRangesDidChange: ranges)
        }
    }

    public func engine(_ engine: any AudioPlaybackEngine, didUpdateAudioLevels levels: AudioLevelData) {
        Task { @MainActor in
            delegate?.navigator(self, didUpdateAudioLevels: levels)
        }
    }

    private func shouldPlayNextResource(completion: @escaping (Bool) -> Void) {
        guard let delegate = delegate else {
            completion(true)
            return
        }

        makePlaybackInfo { info in
            completion(delegate.navigator(self, shouldPlayNextResource: info))
        }
    }
}

// MARK: - Private Extensions

private extension MediaPlaybackState {
    init(_ engineState: AudioEnginePlaybackState) {
        switch engineState {
        case .stopped, .paused:
            self = .paused
        case .loading:
            self = .loading
        case .playing:
            self = .playing
        }
    }
}
