//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation

/// Playback state of the audio engine.
public enum AudioEnginePlaybackState: Hashable, Sendable {
    case stopped
    case loading
    case playing
    case paused
}

/// Audio level data for visualization.
///
/// Designed to support both simple single-level metering and
/// multi-band FFT frequency analysis.
public struct AudioLevelData: Equatable, Sendable {
    /// Audio levels for visualization.
    /// - Single-level mode: Array with one element (overall RMS level)
    /// - FFT mode: Array with multiple elements (frequency band levels)
    /// Values are normalized 0.0 to 1.0.
    public let levels: [Float]

    /// Number of frequency bands represented.
    public var bandCount: Int { levels.count }

    /// Overall audio level (average of all bands).
    public var overallLevel: Float {
        guard !levels.isEmpty else { return 0 }
        return levels.reduce(0, +) / Float(levels.count)
    }

    /// Creates audio level data with the given levels.
    public init(levels: [Float]) {
        self.levels = levels.map { min(max($0, 0), 1) }
    }

    /// Creates single-level audio data (for simple RMS metering).
    public init(level: Float) {
        self.levels = [min(max(level, 0), 1)]
    }

    /// Silent audio level data.
    public static let silent = AudioLevelData(levels: [0, 0, 0, 0, 0])

    /// Default band count for FFT mode (can be expanded later).
    public static let defaultBandCount = 5
}

/// Delegate protocol for receiving audio engine events.
@MainActor
public protocol AudioPlaybackEngineDelegate: AnyObject {
    /// Called periodically during playback with the current time.
    func engine(_ engine: any AudioPlaybackEngine, didUpdateTime time: Double)

    /// Called when the playback state changes.
    func engine(_ engine: any AudioPlaybackEngine, didChangeState state: AudioEnginePlaybackState)

    /// Called when the current item finishes playing.
    func engineDidFinishPlaying(_ engine: any AudioPlaybackEngine)

    /// Called when loaded time ranges change (for buffering UI).
    func engine(_ engine: any AudioPlaybackEngine, didUpdateLoadedTimeRanges ranges: [Range<Double>])

    /// Called periodically with audio level data for visualization.
    /// - Parameters:
    ///   - engine: The audio engine.
    ///   - levels: Audio level data containing normalized levels (0.0 to 1.0).
    func engine(_ engine: any AudioPlaybackEngine, didUpdateAudioLevels levels: AudioLevelData)

    /// Called when silence skip state changes (started/stopped skipping).
    func engine(_ engine: any AudioPlaybackEngine, silenceSkipStateChanged isSkipping: Bool)

    /// Called after a silence gap was hard-skipped.
    /// Note: Duration is approximate - measured from detection start to seek trigger.
    func engine(_ engine: any AudioPlaybackEngine, didSkipSilence duration: TimeInterval)

    /// Called with time saved delta during speed-up (per buffer).
    /// TCA feature accumulates these deltas.
    func engine(_ engine: any AudioPlaybackEngine, didAccumulateTimeSaved delta: TimeInterval)
}

/// Default implementations for optional delegate methods.
public extension AudioPlaybackEngineDelegate {
    func engine(_ engine: any AudioPlaybackEngine, didUpdateLoadedTimeRanges ranges: [Range<Double>]) {}
    func engine(_ engine: any AudioPlaybackEngine, didUpdateAudioLevels levels: AudioLevelData) {}
    func engine(_ engine: any AudioPlaybackEngine, silenceSkipStateChanged isSkipping: Bool) {}
    func engine(_ engine: any AudioPlaybackEngine, didSkipSilence duration: TimeInterval) {}
    func engine(_ engine: any AudioPlaybackEngine, didAccumulateTimeSaved delta: TimeInterval) {}
}

/// Protocol abstracting audio playback functionality.
///
/// This abstraction allows swapping between different audio engine implementations
/// (e.g., AVPlayer-based vs AVAudioEngine-based) without changing the navigator logic.
@MainActor
public protocol AudioPlaybackEngine: AnyObject {
    /// Delegate for receiving playback events.
    var delegate: AudioPlaybackEngineDelegate? { get set }

    /// Current playback state.
    var state: AudioEnginePlaybackState { get }

    /// Current playback time in seconds.
    var currentTime: Double { get }

    /// Duration of the current item in seconds, if known.
    var duration: Double? { get }

    /// Playback volume (0.0 to 1.0).
    var volume: Float { get set }

    /// Playback rate/speed (1.0 = normal).
    var rate: Float { get set }

    /// Loads an audio asset for playback.
    ///
    /// - Parameters:
    ///   - asset: The AVURLAsset to load. May use Readium's custom URL scheme.
    ///   - originalFileURL: The original file URL before Readium scheme transformation.
    ///     Some engines (like `EnhancedAudioEngine`) require direct file access and
    ///     cannot use Readium's `AVAssetResourceLoaderDelegate` mechanism.
    func load(_ asset: AVURLAsset, originalFileURL: URL?) async throws

    /// Starts or resumes playback.
    func play()

    /// Pauses playback.
    func pause()

    /// Seeks to the specified time.
    /// - Parameter time: Target time in seconds.
    /// - Returns: Whether the seek completed successfully.
    @discardableResult
    func seek(to time: Double) async -> Bool

    /// Cleans up resources when the engine is no longer needed.
    func stop()
}

/// Audio enhancement settings for DSP processing.
///
/// These settings control voice enhancement, normalization, and equalization.
/// Not all engines support all features - check capabilities before use.
public struct AudioEnhancementConfiguration: Codable, Equatable, Hashable, Sendable {
    /// Whether voice enhancement (compression + gain) is enabled.
    /// Improves clarity for quiet narrators.
    public var enhanceVoiceEnabled: Bool

    /// Whether volume normalization is enabled.
    /// Reduces volume swings between chapters/sections.
    public var normalizationEnabled: Bool

    /// Volume boost multiplier (1.0 to 2.0).
    /// Values above 1.0 amplify the audio beyond normal levels.
    public var volumeBoost: Float

    /// Selected EQ preset, if any.
    public var eqPreset: AudioEQPreset?

    /// Custom EQ band gains, if using custom EQ.
    /// Array of gain values in dB for each frequency band.
    public var customEQBands: [Float]?

    public init(
        enhanceVoiceEnabled: Bool = true,
        normalizationEnabled: Bool = false,
        volumeBoost: Float = 1.0,
        eqPreset: AudioEQPreset? = nil,
        customEQBands: [Float]? = nil
    ) {
        self.enhanceVoiceEnabled = enhanceVoiceEnabled
        self.normalizationEnabled = normalizationEnabled
        self.volumeBoost = min(max(volumeBoost, 1.0), 2.0)
        self.eqPreset = eqPreset
        self.customEQBands = customEQBands
    }

    /// Default configuration with Enhance Voice enabled.
    public static let `default` = AudioEnhancementConfiguration()
}

/// Predefined EQ presets for common listening scenarios.
public enum AudioEQPreset: String, Codable, Hashable, Sendable, CaseIterable {
    /// Flat frequency response (no EQ).
    case natural

    /// Enhanced speech clarity (+3dB in 1-4kHz range).
    case voiceClarity

    /// Reduced low frequencies (-6dB below 200Hz).
    case bassReduction

    /// Boosted high frequencies (+3dB above 4kHz).
    case trebleBoost

    /// Optimized for outdoor/noisy environments.
    case outdoor

    /// Optimized for headphone listening.
    case headphones
}

/// Protocol for engines that support audio enhancement/DSP.
@MainActor
public protocol EnhancedAudioPlaybackEngine: AudioPlaybackEngine {
    /// Current enhancement configuration.
    var enhancementConfiguration: AudioEnhancementConfiguration { get set }

    /// Whether this engine supports audio enhancement features.
    var supportsEnhancement: Bool { get }
}
