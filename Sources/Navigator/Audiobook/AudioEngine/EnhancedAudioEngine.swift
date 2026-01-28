//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Accelerate
import AudioToolbox
import AVFoundation
import Foundation
import ReadiumShared
import Synchronization

// MARK: - Silence Skip Configuration

/// Configuration for automatic silence skipping in audiobook playback.
///
/// This type is defined locally in swift-toolkit to avoid coupling with the app's Domain layer.
/// The app should map between its Domain.SilenceSkipConfiguration and this type.
public struct SilenceSkipConfiguration: Sendable, Equatable, Codable, Hashable {
    /// Whether silence skipping is enabled.
    public var enabled: Bool

    /// Detection sensitivity level.
    public var sensitivity: Sensitivity

    public init(
        enabled: Bool = false,
        sensitivity: Sensitivity = .balanced
    ) {
        self.enabled = enabled
        self.sensitivity = sensitivity
    }

    /// Sensitivity presets for silence detection.
    public enum Sensitivity: String, Sendable, Codable, CaseIterable, Hashable {
        /// Conservative: only skips dead silence (-40 dB threshold).
        case gentle

        /// Default: balanced detection (-45 dB threshold).
        case balanced

        /// Aggressive: skips quieter gaps (-50 dB threshold).
        case aggressive

        /// The dB threshold below which audio is considered silence.
        public var thresholdDb: Float {
            switch self {
            case .gentle: -40
            case .balanced: -45
            case .aggressive: -50
            }
        }
    }
}

/// Audio playback engine with DSP capabilities for voice enhancement and normalization.
///
/// Uses `AVAudioEngine` to provide real-time audio processing including:
/// - Voice enhancement (compression + gain for quiet narrators)
/// - Volume normalization (reduces volume swings)
/// - Volume boost (up to 200%)
/// - Playback rate/speed control
/// - EQ presets (6 presets optimized for audiobook listening)
///
/// The audio chain is:
/// ```
/// AVAudioPlayerNode → TimePitch → DynamicsProcessor → EQ → Mixer → MainMixerNode → Output
/// ```
@MainActor
public final class EnhancedAudioEngine: EnhancedAudioPlaybackEngine, Loggable {
    public weak var delegate: AudioPlaybackEngineDelegate?

    public var enhancementConfiguration: AudioEnhancementConfiguration {
        didSet {
            applyEnhancementSettings()
        }
    }

    public var supportsEnhancement: Bool { true }

    /// Interval between playback time updates sent to the delegate.
    public let timeUpdateInterval: TimeInterval

    public init(
        timeUpdateInterval: TimeInterval = 0.5,
        initialConfiguration: AudioEnhancementConfiguration = .default
    ) {
        self.timeUpdateInterval = timeUpdateInterval
        self.enhancementConfiguration = initialConfiguration
        setupAudioEngine()
    }

    // Note: No deinit - cleanup is handled by stop() which must be called before
    // the engine is deallocated. AudioNavigator.deinit ensures this by calling
    // engine.stop() via DispatchQueue.main.async. This pattern is necessary because
    // deinit runs in a nonisolated context and cannot access @MainActor properties.

    // MARK: - AudioPlaybackEngine

    public var state: AudioEnginePlaybackState {
        if currentAudioFile == nil {
            return .stopped
        }
        return isPlaying ? .playing : .paused
    }

    public var currentTime: Double {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return lastKnownTime
        }
        let time = Double(playerTime.sampleTime) / playerTime.sampleRate + seekOffset
        return max(0, time)
    }

    public var duration: Double? {
        guard let audioFile = currentAudioFile else { return nil }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    public var volume: Float {
        get { baseVolume }
        set {
            baseVolume = newValue
            applyVolume()
        }
    }

    public var rate: Float {
        get { currentRate }
        set {
            currentRate = newValue
            timePitchNode.rate = newValue
            // Update user rate for silence skip (so we restore to correct speed after skip)
            silenceState.withLock { $0.userRate = newValue }
        }
    }

    /// Configuration for automatic silence skipping.
    public var silenceSkipConfiguration: SilenceSkipConfiguration {
        get { silenceState.withLock { $0.config } }
        set {
            // Capture values atomically before spawning Task
            let enabled = newValue.enabled
            let resetState = !enabled

            silenceState.withLock { state in
                state.config = newValue
                if resetState {
                    state.detectionState = .speech
                }
            }

            // Rate reset must happen on main actor
            if resetState {
                Task { @MainActor in
                    let userRate = self.silenceState.withLock { $0.userRate }
                    if self.timePitchNode.rate != userRate {
                        self.scheduleRateRamp(to: userRate)
                    }
                }
            }
        }
    }

    /// Updates the user's chosen playback rate (preserved during silence skip).
    public func setUserRate(_ rate: Float) {
        silenceState.withLock { $0.userRate = rate }
    }

    public func load(_ asset: AVURLAsset, originalFileURL: URL?) async throws {
        // Soft stop - don't destroy FFT setup since we're reusing the engine
        playerNode.stop()
        stopLevelMetering()
        audioEngine.stop()
        isPlaying = false
        currentAudioFile = nil
        currentFileURL = nil
        seekOffset = 0
        lastKnownTime = 0
        stopTimeUpdates()

        // Ensure FFT is set up (may have been destroyed by stop())
        if fftSetup == nil {
            setupFFT()
        }

        // For AVAudioEngine, we need a file URL, not an asset.
        // AVURLAsset may have a custom scheme for Readium resources.
        // Prefer the originalFileURL if provided, otherwise try to extract from the asset.
        let url: URL
        if let originalFileURL, originalFileURL.isFileURL {
            url = originalFileURL
        } else if let extractedURL = extractFileURL(from: asset) {
            url = extractedURL
        } else {
            log(.error, "Failed to get file URL from asset: \(asset.url)")
            throw EnhancedAudioEngineError.unsupportedAsset
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            currentAudioFile = audioFile
            currentFileURL = url
            seekOffset = 0
            lastKnownTime = 0

            // Connect nodes for this file's format
            try connectNodes(for: audioFile)

            delegate?.engine(self, didChangeState: .paused)
        } catch {
            log(.error, "Failed to load audio file: \(error)")
            throw EnhancedAudioEngineError.audioFileLoadFailed(error)
        }
    }

    public func play() {
        guard let audioFile = currentAudioFile else { return }

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }

            // Capture current position before scheduling (uses lastKnownTime when paused)
            let startTime = currentTime

            // Update seekOffset so currentTime computes correctly after play.
            // When the player node starts, playerTime.sampleTime will be 0, so without
            // updating seekOffset, currentTime would return the stale offset instead
            // of the actual resume position.
            seekOffset = startTime
            lastKnownTime = startTime

            scheduleFile(audioFile, from: startTime)
            playerNode.play()
            isPlaying = true
            startTimeUpdates()
            startLevelMetering()
            delegate?.engine(self, didChangeState: .playing)
        } catch {
            log(.error, "Failed to start playback: \(error)")
            delegate?.engine(self, didChangeState: .paused)
        }
    }

    public func pause() {
        guard isPlaying else { return }

        // Save current time before pausing
        lastKnownTime = currentTime
        playerNode.pause()
        isPlaying = false
        stopTimeUpdates()
        stopLevelMetering()
        delegate?.engine(self, didChangeState: .paused)
    }

    @discardableResult
    public func seek(to time: Double) async -> Bool {
        guard let audioFile = currentAudioFile else { return false }

        let wasPlaying = isPlaying
        if wasPlaying {
            playerNode.stop()
            isPlaying = false
        }

        // Reset silence detection state on seek to prevent being stuck in sped-up state
        let userRate = silenceState.withLock { state in
            state.detectionState = .speech
            return state.userRate
        }
        // Restore user's rate if we were in a speed-up state
        if timePitchNode.rate != userRate {
            timePitchNode.rate = userRate
        }

        // Update seek offset
        seekOffset = time
        lastKnownTime = time

        if wasPlaying {
            scheduleFile(audioFile, from: time)
            playerNode.play()
            isPlaying = true
            delegate?.engine(self, didChangeState: .playing)
        }

        return true
    }

    public func stop() {
        playerNode.stop()
        stopLevelMetering()
        audioEngine.stop()
        isPlaying = false
        currentAudioFile = nil
        currentFileURL = nil
        seekOffset = 0
        lastKnownTime = 0
        stopTimeUpdates()

        // Cancel any in-progress rate ramp
        cancelRateRamp()

        // Reset silence skip state
        silenceState.withLock { state in
            state.detectionState = .speech
        }

        // Clean up FFT resources
        if let fftSetup = fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
            self.fftSetup = nil
        }

        delegate?.engine(self, didChangeState: .stopped)
    }

    // MARK: - Private Properties

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private var dynamicsProcessor: AVAudioUnitEffect?
    private let eqNode = AVAudioUnitEQ(numberOfBands: 10)
    private let mixerNode = AVAudioMixerNode()

    private var currentAudioFile: AVAudioFile?
    private var currentFileURL: URL?
    private var isPlaying = false
    /// Generation counter to ignore stale completion handlers from previous segments.
    /// Incremented each time we schedule a new segment.
    private var scheduleGeneration: Int = 0
    private var seekOffset: Double = 0
    private var lastKnownTime: Double = 0
    private var baseVolume: Float = 1.0
    private var currentRate: Float = 1.0

    private var timeUpdateTimer: Timer?

    /// Whether audio level metering is currently active.
    private var isLevelMeteringActive = false

    /// Buffer size for audio tap (smaller = more responsive, larger = smoother).
    private let levelMeteringBufferSize: AVAudioFrameCount = 1024

    /// Smoothing factor for level transitions (0 = no smoothing, 1 = max smoothing).
    private let levelSmoothingFactor: Float = 0.3

    /// Last computed audio levels for smoothing.
    private var lastAudioLevels: [Float] = Array(repeating: 0, count: AudioLevelData.defaultBandCount)

    /// Dedicated queue for FFT processing (off audio render thread).
    ///
    /// Note: `DispatchQueue` is required here rather than `async/await` because:
    /// 1. The audio tap callback runs synchronously on the audio render thread
    /// 2. `await` cannot be used in this callback context
    /// 3. FFT processing must be moved off the audio thread to prevent dropouts
    private let fftQueue = DispatchQueue(label: "com.readium.audio.fft", qos: .userInteractive)

    /// Thread-safe state for FFT processing coordination.
    /// Uses Mutex for consistency with silence skip state (Swift 6 pattern).
    private struct FFTProcessingState: Sendable {
        var isProcessing = false
        var lastUpdateTime: CFAbsoluteTime = 0
    }

    private let fftProcessingState = Mutex(FFTProcessingState())

    /// Minimum interval between audio level updates (throttling to ~25Hz).
    private let levelUpdateMinInterval: TimeInterval = 0.04

    // MARK: - FFT Properties

    /// FFT size (must be power of 2). Larger = more frequency resolution, slower response.
    private let fftSize = 1024

    /// Log2 of FFT size for vDSP.
    private var fftLog2Size: vDSP_Length { vDSP_Length(log2(Float(fftSize))) }

    /// vDSP FFT setup (reusable across calls).
    private var fftSetup: FFTSetup?

    /// Window function buffer (Hanning window).
    private var windowBuffer: [Float] = []

    /// Real part of split complex for FFT.
    private var realBuffer: [Float] = []

    /// Imaginary part of split complex for FFT.
    private var imagBuffer: [Float] = []

    /// Magnitude buffer for FFT output.
    private var magnitudeBuffer: [Float] = []

    /// Frequency band boundaries for 5-band visualization.
    /// Maps frequency ranges to visualization bands.
    private struct FrequencyBands {
        /// Band boundaries in Hz: [bass, low-mid, mid, high-mid, treble]
        /// Band 0: 20-150 Hz (bass - kick drums, bass notes)
        /// Band 1: 150-400 Hz (low-mid - male vocals, warmth)
        /// Band 2: 400-2000 Hz (mid - vocals, instruments)
        /// Band 3: 2000-6000 Hz (high-mid - presence, clarity)
        /// Band 4: 6000-20000 Hz (treble - air, brilliance)
        static let boundaries: [Float] = [20, 150, 400, 2000, 6000, 20000]
        static let count = 5
    }

    // MARK: - Silence Skip State (Thread-Safe)

    /// Thread-safe container for silence detection state.
    /// Accessed from audio processing queue and main actor.
    private struct SilenceSkipState: Sendable {
        var config = SilenceSkipConfiguration()
        var detectionState = DetectionState.speech
        var userRate: Float = 1.0

        enum DetectionState: Equatable, Sendable {
            case speech
            case maybeSilent(since: TimeInterval) // CACurrentMediaTime
            case speedingUp(since: TimeInterval) // CACurrentMediaTime
            case seeking
        }
    }

    private let silenceState = Mutex(SilenceSkipState())

    // Silence skip thresholds (immutable, no synchronization needed)
    private let minimumSilenceDuration: TimeInterval = 0.4
    private let longSilenceThreshold: TimeInterval = 2.0
    private let silencePlaybackRate: Float = 2.5
    private let rateRampDuration: TimeInterval = 0.1

    /// Task for current rate ramp animation (for cancellation).
    private var rampTask: Task<Void, Never>?

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        // Create dynamics processor using Audio Unit
        let componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        dynamicsProcessor = AVAudioUnitEffect(audioComponentDescription: componentDescription)

        // Configure time pitch node (no pitch shift, just rate)
        timePitchNode.pitch = 0 // No pitch change
        timePitchNode.rate = currentRate

        // Attach nodes to the engine
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchNode)
        if let dynamicsProcessor {
            audioEngine.attach(dynamicsProcessor)
        }
        audioEngine.attach(eqNode)
        audioEngine.attach(mixerNode)

        // Configure EQ bands with standard frequencies
        configureEQBands()

        // Initialize FFT for audio visualization
        setupFFT()

        // Initial enhancement settings
        applyEnhancementSettings()
    }

    /// Initializes FFT buffers and setup for frequency analysis.
    private func setupFFT() {
        // Create FFT setup (reusable)
        fftSetup = vDSP_create_fftsetup(fftLog2Size, FFTRadix(kFFTRadix2))

        // Pre-allocate buffers
        windowBuffer = [Float](repeating: 0, count: fftSize)
        realBuffer = [Float](repeating: 0, count: fftSize / 2)
        imagBuffer = [Float](repeating: 0, count: fftSize / 2)
        magnitudeBuffer = [Float](repeating: 0, count: fftSize / 2)

        // Create Hanning window
        vDSP_hann_window(&windowBuffer, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    /// Configures the 10-band EQ with standard frequencies for audiobook optimization.
    private func configureEQBands() {
        // Standard 10-band frequencies (Hz): 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
        let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let bands = eqNode.bands

        for (index, frequency) in frequencies.enumerated() {
            guard index < bands.count else { break }
            let band = bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0 // Octave bandwidth
            band.gain = 0 // Flat by default
            band.bypass = false
        }
    }

    private func connectNodes(for audioFile: AVAudioFile) throws {
        let format = audioFile.processingFormat

        // Disconnect existing connections
        audioEngine.disconnectNodeInput(timePitchNode)
        if let dynamicsProcessor {
            audioEngine.disconnectNodeInput(dynamicsProcessor)
        }
        audioEngine.disconnectNodeInput(eqNode)
        audioEngine.disconnectNodeInput(mixerNode)
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)

        // Connect: PlayerNode → TimePitch → DynamicsProcessor → EQ → Mixer → MainMixer → Output
        audioEngine.connect(playerNode, to: timePitchNode, format: format)

        if let dynamicsProcessor {
            audioEngine.connect(timePitchNode, to: dynamicsProcessor, format: format)
            audioEngine.connect(dynamicsProcessor, to: eqNode, format: format)
        } else {
            // Fallback: bypass dynamics processor
            audioEngine.connect(timePitchNode, to: eqNode, format: format)
        }
        audioEngine.connect(eqNode, to: mixerNode, format: format)
        audioEngine.connect(mixerNode, to: audioEngine.mainMixerNode, format: format)

        // Prepare the engine
        audioEngine.prepare()
    }

    private func scheduleFile(_ audioFile: AVAudioFile, from time: Double) {
        // Increment generation to invalidate any pending completion handlers
        scheduleGeneration += 1
        let currentGeneration = scheduleGeneration

        playerNode.stop()

        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = audioFile.length

        guard startFrame < totalFrames else {
            // At or past end of file
            delegate?.engineDidFinishPlaying(self)
            return
        }

        let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

        // Seek to the start position
        audioFile.framePosition = startFrame

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: framesToPlay,
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackCompletion(generation: currentGeneration)
            }
        }
    }

    private func handlePlaybackCompletion(generation: Int) {
        // Ignore stale completion handlers from previous segments
        guard generation == scheduleGeneration else { return }
        guard isPlaying else { return }

        isPlaying = false
        stopTimeUpdates()
        stopLevelMetering()
        delegate?.engineDidFinishPlaying(self)
    }

    // MARK: - Enhancement Settings

    private func applyEnhancementSettings() {
        applyVoiceEnhancement()
        applyEQ()
        applyVolume()
    }

    private func applyVoiceEnhancement() {
        guard let dynamicsProcessor else { return }

        let audioUnit = dynamicsProcessor.audioUnit

        if enhancementConfiguration.enhanceVoiceEnabled {
            // Voice enhancement settings (compression + gain)
            // These settings are tuned for audiobook narration:
            // - Threshold: -20dB (start compressing when signal exceeds this)
            // - Head Room: 3dB (controls compression ratio)
            // - Attack: 10ms (fast enough to catch transients)
            // - Release: 100ms (smooth release)
            // - Makeup gain: +3dB (compensate for compression)
            setDynamicsParameter(audioUnit, .threshold, value: -20)
            setDynamicsParameter(audioUnit, .headRoom, value: 3)
            setDynamicsParameter(audioUnit, .attackTime, value: 0.010)
            setDynamicsParameter(audioUnit, .releaseTime, value: 0.100)
            setDynamicsParameter(audioUnit, .masterGain, value: 3)
        } else {
            // Bypass - neutral settings
            setDynamicsParameter(audioUnit, .threshold, value: 0)
            setDynamicsParameter(audioUnit, .headRoom, value: 40)
            setDynamicsParameter(audioUnit, .attackTime, value: 0.001)
            setDynamicsParameter(audioUnit, .releaseTime, value: 0.050)
            setDynamicsParameter(audioUnit, .masterGain, value: 0)
        }
    }

    /// Sets a parameter on the dynamics processor audio unit.
    private func setDynamicsParameter(
        _ audioUnit: AudioUnit,
        _ parameter: DynamicsProcessorParameter,
        value: Float
    ) {
        let status = AudioUnitSetParameter(
            audioUnit,
            parameter.rawValue,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
        #if DEBUG
        if status != noErr {
            assertionFailure("Failed to set dynamics parameter \(parameter): OSStatus \(status)")
        }
        #endif
    }

    private func applyVolume() {
        // Apply both base volume and volume boost
        let effectiveVolume = baseVolume * enhancementConfiguration.volumeBoost
        mixerNode.outputVolume = min(effectiveVolume, 2.0)
    }

    /// Applies the current EQ preset or custom band settings.
    private func applyEQ() {
        let bands = eqNode.bands

        // If custom bands are provided, use those
        if let customBands = enhancementConfiguration.customEQBands {
            for (index, gain) in customBands.enumerated() {
                guard index < bands.count else { break }
                bands[index].gain = gain
            }
            return
        }

        // Otherwise apply preset
        let gains = eqGains(for: enhancementConfiguration.eqPreset)
        for (index, gain) in gains.enumerated() {
            guard index < bands.count else { break }
            bands[index].gain = gain
        }
    }

    /// Returns the 10-band EQ gains (in dB) for a given preset.
    /// Bands: 32Hz, 64Hz, 125Hz, 250Hz, 500Hz, 1kHz, 2kHz, 4kHz, 8kHz, 16kHz
    private func eqGains(for preset: AudioEQPreset?) -> [Float] {
        guard let preset else {
            // No preset = flat response
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }

        switch preset {
        case .natural:
            // Flat frequency response
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

        case .voiceClarity:
            // Boost speech frequencies (1-4kHz), slight cut on bass
            // Speech clarity is most affected by 2-4kHz range
            return [-2, -1, 0, 0, 1, 2, 3, 3, 1, 0]

        case .bassReduction:
            // Reduce low frequencies to minimize rumble and boominess
            return [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0]

        case .trebleBoost:
            // Boost high frequencies for added detail and airiness
            return [0, 0, 0, 0, 0, 0, 1, 2, 3, 3]

        case .outdoor:
            // Compensate for outdoor noise - boost mids and highs
            // Cut sub-bass (wind noise), boost presence
            return [-4, -2, 0, 1, 2, 3, 4, 3, 2, 1]

        case .headphones:
            // Optimized for headphone listening
            // Slight bass reduction (proximity effect), enhanced stereo presence
            return [-1, 0, 0, 0, 0, 1, 1, 2, 1, 0]
        }
    }

    // MARK: - Silence Skip Rate Ramping

    /// Smoothly ramps playback rate to prevent audio artifacts.
    /// Must be called from MainActor since it accesses timePitchNode.rate.
    @MainActor
    private func scheduleRateRamp(to targetRate: Float) {
        rampTask?.cancel()
        rampTask = Task { [weak self] in
            guard let self else { return }
            let startRate = timePitchNode.rate
            let steps = 10
            let stepDuration = rateRampDuration / Double(steps)

            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Float(i) / Float(steps)
                let newRate = startRate + (targetRate - startRate) * progress
                self.timePitchNode.rate = newRate
                try? await Task.sleep(for: .seconds(stepDuration))
            }
        }
    }

    /// Cancels any in-progress rate ramp. Called from stop().
    @MainActor
    private func cancelRateRamp() {
        rampTask?.cancel()
        rampTask = nil
    }

    // MARK: - Time Updates

    private func startTimeUpdates() {
        stopTimeUpdates()
        timeUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: timeUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPlaying else { return }
                self.delegate?.engine(self, didUpdateTime: self.currentTime)
            }
        }
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
    }

    // MARK: - Audio Level Metering

    /// Starts audio level metering by installing a tap on the mixer node.
    private func startLevelMetering() {
        guard !isLevelMeteringActive else { return }

        let format = mixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        mixerNode.installTap(onBus: 0, bufferSize: levelMeteringBufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Silence detection runs on every buffer (lightweight RMS calculation)
            self.detectAndHandleSilence(buffer)

            // Drop frames if FFT processing can't keep up (prevents audio thread blocking)
            let shouldProcess = self.fftProcessingState.withLock { state in
                guard !state.isProcessing else { return false }
                state.isProcessing = true
                return true
            }

            guard shouldProcess else { return }

            // Process FFT on dedicated queue (off audio render thread)
            self.fftQueue.async { [weak self] in
                self?.processAudioBuffer(buffer)
            }
        }

        isLevelMeteringActive = true
    }

    /// Stops audio level metering by removing the tap.
    private func stopLevelMetering() {
        guard isLevelMeteringActive else { return }

        mixerNode.removeTap(onBus: 0)
        isLevelMeteringActive = false

        // Wait for any pending FFT work to complete before resetting state.
        // This prevents in-flight async work from accessing deallocated resources.
        fftQueue.sync {}

        // Reset processing flag
        fftProcessingState.withLock { $0.isProcessing = false }

        // Send silent levels when stopping
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastAudioLevels = Array(repeating: 0, count: AudioLevelData.defaultBandCount)
            self.delegate?.engine(self, didUpdateAudioLevels: .silent)
        }
    }

    /// Processes an audio buffer to extract frequency band levels using FFT.
    /// Called on the dedicated FFT queue (off audio render thread).
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        defer {
            // Clear processing flag to allow next frame
            fftProcessingState.withLock { $0.isProcessing = false }
        }

        guard let channelData = buffer.floatChannelData,
              let fftSetup = fftSetup else { return }

        let frameLength = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)

        guard frameLength >= fftSize else { return }

        // Use first channel (mono mix) for analysis
        let samples = channelData[0]

        // Copy samples and apply window function
        // Bounds check: use min to prevent buffer overrun if frameLength < fftSize
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        let sampleCount = min(fftSize, frameLength)
        for i in 0..<sampleCount {
            windowedSamples[i] = samples[i] * windowBuffer[i]
        }
        // Remaining samples (if any) are already zero-initialized

        // Prepare split complex for FFT
        var splitComplex = DSPSplitComplex(realp: &realBuffer, imagp: &imagBuffer)

        // Convert real samples to split complex format
        windowedSamples.withUnsafeBufferPointer { samplesPtr in
            guard let baseAddress = samplesPtr.baseAddress else { return }
            baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Perform FFT
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2Size, FFTDirection(FFT_FORWARD))

        // Calculate magnitudes
        vDSP_zvmags(&splitComplex, 1, &magnitudeBuffer, 1, vDSP_Length(fftSize / 2))

        // Convert to decibels and normalize
        // Scale by FFT size for proper magnitude
        var scaleFactor = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudeBuffer, 1, &scaleFactor, &magnitudeBuffer, 1, vDSP_Length(fftSize / 2))

        // Bin frequencies into bands
        let bandLevels = binFrequenciesToBands(magnitudeBuffer, sampleRate: sampleRate)

        // Throttle updates to reduce MainActor hops (thread-safe access)
        let now = CFAbsoluteTimeGetCurrent()
        let shouldUpdate = fftProcessingState.withLock { state in
            guard now - state.lastUpdateTime >= levelUpdateMinInterval else { return false }
            state.lastUpdateTime = now
            return true
        }
        guard shouldUpdate else { return }

        // Apply smoothing on main thread
        Task { @MainActor [weak self, bandLevels] in
            guard let self, self.isPlaying else { return }

            // Smooth the levels for less jittery animation
            for i in 0..<self.lastAudioLevels.count {
                let newValue = i < bandLevels.count ? bandLevels[i] : 0
                self.lastAudioLevels[i] = self.lastAudioLevels[i] * self.levelSmoothingFactor +
                    newValue * (1 - self.levelSmoothingFactor)
            }

            let levelData = AudioLevelData(levels: self.lastAudioLevels)
            self.delegate?.engine(self, didUpdateAudioLevels: levelData)
        }
    }

    /// Bins FFT magnitude data into frequency bands for visualization.
    ///
    /// - Parameters:
    ///   - magnitudes: FFT magnitude buffer (fftSize/2 values)
    ///   - sampleRate: Audio sample rate in Hz
    /// - Returns: Array of normalized levels (0.0-1.0) for each frequency band
    private func binFrequenciesToBands(_ magnitudes: [Float], sampleRate: Float) -> [Float] {
        let binCount = magnitudes.count
        let binWidth = sampleRate / Float(fftSize) // Hz per FFT bin

        var bandLevels = [Float](repeating: 0, count: FrequencyBands.count)

        // For each frequency band, sum magnitudes of bins that fall within it
        for bandIndex in 0..<FrequencyBands.count {
            let lowFreq = FrequencyBands.boundaries[bandIndex]
            let highFreq = FrequencyBands.boundaries[bandIndex + 1]

            // Convert frequency range to bin indices
            let lowBin = max(1, Int(lowFreq / binWidth)) // Skip DC component (bin 0)
            let highBin = min(binCount - 1, Int(highFreq / binWidth))

            guard lowBin <= highBin else { continue }

            // Sum magnitudes in this frequency range
            var sum: Float = 0
            var count: Float = 0

            for bin in lowBin...highBin {
                sum += magnitudes[bin]
                count += 1
            }

            // Average magnitude for this band
            let avgMagnitude = count > 0 ? sum / count : 0

            // Convert to perceptually linear scale using logarithmic mapping
            // Magnitudes are typically very small, so we need significant scaling
            let dbValue = 20 * log10(max(avgMagnitude, 1e-10))
            // Map dB range to 0-1 (assuming -60dB to 0dB useful range)
            let normalizedLevel = max(0, min(1, (dbValue + 60) / 60))

            // Apply some additional scaling per band for visual balance
            // Lower frequencies tend to be louder, so we boost higher bands slightly
            let bandBoost: Float = 1.0 + Float(bandIndex) * 0.1
            bandLevels[bandIndex] = min(1.0, normalizedLevel * bandBoost * 1.5)
        }

        return bandLevels
    }

    // MARK: - Silence Skip Detection

    /// Called from audio tap callback (audio processing queue).
    /// Reports events to delegate; does NOT accumulate state.
    private func detectAndHandleSilence(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData,
              buffer.format.sampleRate > 0 else { return }

        // Read config atomically
        let config = silenceState.withLock { $0.config }
        guard config.enabled else { return }

        let frameLength = vDSP_Length(buffer.frameLength)
        var rms: Float = 0

        // Calculate RMS (root mean square)
        vDSP_rmsqv(channelData[0], 1, &rms, frameLength)

        // Convert to dB
        let db = 20 * log10(max(rms, 1e-10))
        let isSilent = db < config.sensitivity.thresholdDb

        // Use monotonic time (not wall clock) to avoid NTP sync jumps
        let now = CACurrentMediaTime()
        let bufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate

        // Capture currentTime before acquiring lock to avoid accessing @MainActor state inside lock.
        // This is safe because currentTime is a computed property reading from audio engine state.
        let capturedCurrentTime = currentTime

        // State machine with atomic access
        silenceState.withLock { state in
            switch (state.detectionState, isSilent) {
            case (.speech, true):
                // Speech → potential silence
                state.detectionState = .maybeSilent(since: now)

            case (.maybeSilent(let since), true):
                let silenceDuration = now - since

                if silenceDuration >= longSilenceThreshold {
                    // Long silence: hard seek
                    state.detectionState = .seeking
                    let skipTo = capturedCurrentTime + silenceDuration
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.seek(to: skipTo)
                        self.silenceState.withLock { $0.detectionState = .speech }
                        // Report skip event with duration - TCA accumulates
                        self.delegate?.engine(self, didSkipSilence: silenceDuration)
                    }
                } else if silenceDuration >= minimumSilenceDuration {
                    // Short silence: speed up
                    state.detectionState = .speedingUp(since: now)
                    let userRate = state.userRate
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scheduleRateRamp(to: self.silencePlaybackRate * userRate)
                        self.delegate?.engine(self, silenceSkipStateChanged: true)
                    }
                }

            case (.maybeSilent, false):
                // False alarm - back to speech
                state.detectionState = .speech

            case (.speedingUp, true):
                // Still in short silence - calculate time saved this buffer
                // Report to delegate; TCA accumulates
                let effectiveRate = silencePlaybackRate
                let savedThisBuffer = bufferDuration * Double(effectiveRate - 1) / Double(effectiveRate)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.engine(self, didAccumulateTimeSaved: savedThisBuffer)
                }

            case (.speedingUp, false):
                // Silence ended - return to normal
                state.detectionState = .speech
                let userRate = state.userRate
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.scheduleRateRamp(to: userRate)
                    self.delegate?.engine(self, silenceSkipStateChanged: false)
                }

            case (.speech, false), (.seeking, _):
                // Normal speech or seeking - no action
                break
            }
        }
    }

    // MARK: - URL Extraction

    /// Extracts a file URL from an AVURLAsset.
    ///
    /// Readium uses custom URL schemes (readiumfile://, readiumhttp://) for its assets.
    /// For local files, we need to convert back to a file:// URL.
    private func extractFileURL(from asset: AVURLAsset) -> URL? {
        let assetURL = asset.url

        // Check if it's already a file URL
        if assetURL.isFileURL {
            return assetURL
        }

        // Handle Readium's custom scheme (readiumfile://...)
        let urlString = assetURL.absoluteString
        if urlString.hasPrefix("readiumfile://") {
            // Convert readiumfile:// back to file://
            let fileURLString = urlString.replacingOccurrences(of: "readiumfile://", with: "file://")
            return URL(string: fileURLString)
        }

        // For other schemes (http, readiumhttp), we'd need to stream or download.
        return nil
    }
}

// MARK: - Dynamics Processor Parameters

/// Parameter IDs for the DynamicsProcessor audio unit.
private enum DynamicsProcessorParameter: AudioUnitParameterID {
    case threshold = 0 // kDynamicsProcessorParam_Threshold
    case headRoom = 1 // kDynamicsProcessorParam_HeadRoom
    case expansionRatio = 2 // kDynamicsProcessorParam_ExpansionRatio
    case expansionThreshold = 3 // kDynamicsProcessorParam_ExpansionThreshold
    case attackTime = 4 // kDynamicsProcessorParam_AttackTime
    case releaseTime = 5 // kDynamicsProcessorParam_ReleaseTime
    case masterGain = 6 // kDynamicsProcessorParam_MasterGain
    case compressionAmount = 1000 // kDynamicsProcessorParam_CompressionAmount (read-only)
    case inputAmplitude = 2000 // kDynamicsProcessorParam_InputAmplitude (read-only)
    case outputAmplitude = 3000 // kDynamicsProcessorParam_OutputAmplitude (read-only)
}

// MARK: - Errors

/// Errors specific to the enhanced audio engine.
public enum EnhancedAudioEngineError: Error, LocalizedError {
    case unsupportedAsset
    case audioFileLoadFailed(Error)
    case engineStartFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAsset:
            return "The audio asset format is not supported for enhanced playback."
        case .audioFileLoadFailed(let error):
            return "Failed to load audio file: \(error.localizedDescription)"
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedAsset:
            return "Try using the standard audio player instead."
        case .audioFileLoadFailed:
            return "Check that the file is a valid audio format."
        case .engineStartFailed:
            return "Try closing other audio apps and restarting playback."
        }
    }
}
