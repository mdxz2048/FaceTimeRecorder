import Foundation
import AVFoundation

/// Microphone recording from a direct HAL input capture, independent of the
/// monitor output. This avoids AVAudioEngine's voice-processing graph, which
/// cannot start while FaceTime is using it.
public final class MicCaptureRecorder: @unchecked Sendable {
    private let input: DirectInputCapture
    private let nativeFormat: AudioStreamBasicDescription
    private let wavURL: URL
    private let queue = DispatchQueue(label: "com.mdxz.facetime.recorder.mic")
    private let lock = NSLock()
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var sourceIsInterleaved = true
    private var downmixToMono = false
    private let outputFormat: AVAudioFormat
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var scratch: [Float] = []
    private var running = false
    private var paused = false
    private var stats = MicRecorderStats()
    private var sumSquares: Double = 0

    public init(input: DirectInputCapture,
                wavURL: URL,
                format: AudioStreamBasicDescription) throws {
        self.input = input
        self.nativeFormat = format
        self.wavURL = wavURL
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000, channels: 2,
                                          interleaved: true)!
        self.writer = try WAVWriter(url: wavURL, sampleRate: 48_000, channels: 2)
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        // MacBook mic arrays report 3+ channels. AVAudioFormat's interleaved
        // 3-channel layout is not supported, so downmix to channel 0.
        downmixToMono = nativeFormat.mChannelsPerFrame > 2
        let targetChannels: UInt32 = downmixToMono ? 1 : nativeFormat.mChannelsPerFrame
        let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: nativeFormat.mSampleRate,
                                      channels: targetChannels,
                                      interleaved: true)
            ?? AVAudioFormat(standardFormatWithSampleRate: nativeFormat.mSampleRate,
                             channels: targetChannels)
        guard let canonical else {
            stats.conversionError = "microphone format unavailable: sr=\(nativeFormat.mSampleRate) ch=\(nativeFormat.mChannelsPerFrame) flags=\(nativeFormat.mFormatFlags)"
            lock.unlock()
            return
        }
        sourceFormat = canonical
        sourceIsInterleaved = canonical.isInterleaved
        if canonical.sampleRate != outputFormat.sampleRate ||
            canonical.channelCount != outputFormat.channelCount {
            converter = AVAudioConverter(from: canonical, to: outputFormat)
            if converter == nil {
                stats.conversionError = "AVAudioConverter could not be created"
            }
        }
        inputBuffer = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: 8_192)
        outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384)
        scratch = [Float](repeating: 0, count: 16_384 * Int(canonical.channelCount))
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    public func stop() -> MicRecorderStats {
        lock.lock(); running = false; lock.unlock()
        queue.sync { self.drain() }
        try? writer?.close()
        lock.lock()
        var result = stats
        result.wavFrames = writer?.framesWritten ?? 0
        if result.frames > 0 {
            result.rms = Float(sqrt(sumSquares / Double(result.frames)))
        }
        lock.unlock()
        return result
    }

    public var snapshot: MicRecorderStats {
        lock.lock(); defer { lock.unlock() }
        var result = stats
        if result.frames > 0 { result.rms = Float(sqrt(sumSquares / Double(result.frames))) }
        return result
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Drops mic blocks while paused so the WAV timeline matches the video.
    public func setPaused(_ flag: Bool) {
        lock.lock(); paused = flag; lock.unlock()
    }

    private func loop() {
        while isRunning {
            if !drainOnce() { usleep(2_000) }
        }
    }

    private func drain() {
        while drainOnce() {}
    }

    @discardableResult
    private func drainOnce() -> Bool {
        guard let source = sourceFormat, let inputBuffer, let outputBuffer else { return false }
        var block: CapturedBlock?
        do {
            block = try input.readBlock(into: &scratch)
        } catch {
            lock.lock(); stats.conversionError = "\(error)"; lock.unlock()
            return false
        }
        guard let block, block.frames > 0 else { return false }
        let channels = Int(source.channelCount)
        let inputChannels = block.channels

        if let converter {
            inputBuffer.frameLength = AVAudioFrameCount(block.frames)
            if let destination = inputBuffer.floatChannelData {
                block.samples.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    if downmixToMono {
                        for frame in 0..<block.frames {
                            destination[0][frame] = base[frame * inputChannels]
                        }
                    } else if sourceIsInterleaved || channels == 1 {
                        destination[0].update(from: base, count: block.frames * channels)
                    } else {
                        for channel in 0..<channels {
                            for frame in 0..<block.frames {
                                destination[channel][frame] = base[frame * inputChannels + channel]
                            }
                        }
                    }
                }
            }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                lock.lock()
                stats.conversionError = error?.localizedDescription ?? "conversion failed"
                lock.unlock()
                return true
            }
            let frames = Int(outputBuffer.frameLength)
            if frames > 0, let samples = outputBuffer.floatChannelData?[0] {
                commit(samples: samples, frames: frames)
            }
        } else {
            block.samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                commit(samples: base, frames: block.frames)
            }
        }
        return true
    }

    private func commit(samples: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        let isPaused = paused
        lock.unlock()
        guard !isPaused else { return }
        var peak: Float = 0
        for frame in 0..<frames {
            for channel in 0..<2 {
                let value = samples[frame * 2 + channel]
                sumSquares += Double(value * value)
                peak = max(peak, abs(value))
            }
        }
        lock.lock()
        stats.frames += UInt64(frames)
        stats.peak = max(stats.peak, peak)
        stats.aecEnabled = false
        try? writer?.write(samples, frames: frames)
        lock.unlock()
    }
}
