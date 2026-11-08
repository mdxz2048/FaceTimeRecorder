import Foundation
import AVFoundation
import os

public struct RemoteRecorderStats: Sendable {
    public var callbacks: UInt64 = 0
    public var frames: UInt64 = 0
    public var droppedBlocks: UInt64 = 0
    public var silentFrames: UInt64 = 0
    public var channelRMS: [Float] = []
    public var channelPeak: [Float] = []
    public var firstHostTime: UInt64 = 0
    public var lastHostTime: UInt64 = 0
    public var monitorPushDroppedFrames: UInt64 = 0
    public var wavURL: URL?
    public var wavFrames: UInt64 = 0
    public var captureFormat: String = ""
}

/// Consumes device-tap blocks on a normal-priority worker, downmixes FL/FR to
/// stereo, writes the remote track and feeds the monitor ring. No work happens
/// on the HAL thread beyond the SPSC push in DeviceTapCapture.
public final class RemoteAudioRecorder: @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "remote")
    private let source: BlockAudioSource
    private let queue = DispatchQueue(label: "com.mdxz.facetime.recorder.remote")
    private let lock = NSLock()
    private var writer: WAVWriter?
    private let sampleRate: Double
    private let captureChannels: Int
    private let labels: [String]
    private let mode: RemoteChannelMode
    private let stereoIndices: (Int, Int)
    private let monitorRing: OpaquePointer?
    private var running = false
    private var paused = false
    private var stats = RemoteRecorderStats()
    private var scratch = [Float]()
    private var scratchStereo = [Float](repeating: 0, count: 16_384 * 2)
    private var pendingRMS: [Double]
    private var pendingPeak: [Float]

    public init(source: BlockAudioSource,
                descriptor: TapDescriptor,
                labels: [String],
                mode: RemoteChannelMode,
                wavURL: URL?,
                monitorRing: OpaquePointer?) throws {
        self.source = source
        self.sampleRate = descriptor.sampleRate
        self.captureChannels = Int(descriptor.channels)
        self.labels = labels
        self.mode = mode
        self.monitorRing = monitorRing
        self.stereoIndices = Self.frontStereoIndices(labels: labels,
                                                     channels: Int(descriptor.channels))
        self.pendingRMS = [Double](repeating: 0, count: Int(descriptor.channels))
        self.pendingPeak = [Float](repeating: 0, count: Int(descriptor.channels))
        stats.captureFormat = "\(Int(descriptor.sampleRate)) Hz, \(descriptor.channels) ch, labels=\(labels.joined(separator: ","))"
        if let wavURL {
            let channels = mode == .native ? Int(descriptor.channels) : 2
            self.writer = try WAVWriter(url: wavURL, sampleRate: descriptor.sampleRate,
                                        channels: channels)
            stats.wavURL = wavURL
        }
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    public func stop() -> RemoteRecorderStats {
        lock.lock()
        running = false
        lock.unlock()
        queue.sync { self.drain() }
        try? writer?.close()
        lock.lock()
        var result = stats
        result.wavFrames = writer?.framesWritten ?? 0
        if result.frames > 0 {
            result.channelRMS = pendingRMS.map { Float(sqrt($0 / Double(result.frames))) }
            result.channelPeak = pendingPeak
        }
        lock.unlock()
        return result
    }

    public var snapshot: RemoteRecorderStats {
        lock.lock()
        defer { lock.unlock() }
        var result = stats
        if result.frames > 0 {
            result.channelRMS = pendingRMS.map { Float(sqrt($0 / Double(result.frames))) }
            result.channelPeak = pendingPeak
        }
        return result
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// While paused the WAV stops growing but monitoring keeps flowing, so the
    /// call stays audible and the resumed file joins up seamlessly.
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
        if scratch.count < 16_384 * captureChannels {
            scratch = [Float](repeating: 0, count: 16_384 * captureChannels)
        }
        let block: CapturedBlock?
        do {
            block = try source.readBlock(into: &scratch)
        } catch {
            log.error("remote read failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard let block, block.frames > 0 else { return false }

        lock.lock()
        stats.callbacks += 1
        stats.frames += UInt64(block.frames)
        stats.droppedBlocks = max(stats.droppedBlocks, block.droppedBefore)
        if stats.firstHostTime == 0 { stats.firstHostTime = block.hostTime }
        stats.lastHostTime = block.hostTime
        let captureChannels = block.channels
        var frameNonzero = false
        for frame in 0..<block.frames {
            for channel in 0..<min(captureChannels, pendingRMS.count) {
                let value = block.samples[frame * captureChannels + channel]
                if value != 0 { frameNonzero = true }
                pendingRMS[channel] += Double(value * value)
                pendingPeak[channel] = max(pendingPeak[channel], abs(value))
            }
            if !frameNonzero { stats.silentFrames += 1 }
        }
        if let writer, !paused {
            if mode == .native {
                try? writer.write(block.samples, frames: block.frames)
            }
        }
        lock.unlock()

        if mode == .stereoDownmix {
            downmix(block)
        }
        return true
    }

    private func downmix(_ block: CapturedBlock) {
        let channels = block.channels
        let (leftIndex, rightIndex) = stereoIndices
        let frames = block.frames
        if scratchStereo.count < frames * 2 {
            scratchStereo = [Float](repeating: 0, count: frames * 2)
        }
        scratchStereo.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for frame in 0..<frames {
                let left: Float
                let right: Float
                if channels == 1 {
                    left = block.samples[frame]
                    right = left
                } else {
                    left = leftIndex < channels ? block.samples[frame * channels + leftIndex] : 0
                    right = rightIndex < channels ? block.samples[frame * channels + rightIndex] : 0
                }
                base[frame * 2] = left
                base[frame * 2 + 1] = right
            }
            lock.lock()
            if !paused {
                try? writer?.write(base, frames: frames)
            }
            lock.unlock()
            if let monitorRing {
                let written = fr_sample_ring_write(monitorRing, base, UInt32(frames))
                if written < UInt32(frames) {
                    lock.lock()
                    stats.monitorPushDroppedFrames += UInt64(frames - Int(written))
                    lock.unlock()
                }
            }
        }
    }

    /// FL/FR are taken by label, never by assuming 7.1 ordering. The HomePod
    /// Flow device reports FL FR FC LFE BL BR SL SR, which differs from the
    /// common 7.1 label order.
    public static func frontStereoIndices(labels: [String], channels: Int) -> (Int, Int) {
        func find(_ names: [String]) -> Int? {
            for (index, label) in labels.enumerated() where names.contains(label.uppercased()) {
                return index
            }
            return nil
        }
        let left = find(["FL", "L", "LEFT"]) ?? 0
        let right = find(["FR", "R", "RIGHT"]) ?? (channels > 1 ? 1 : 0)
        if channels == 1 { return (0, 0) }
        return (min(left, channels - 1), min(right, channels - 1))
    }
}

public struct MicRecorderStats: Sendable {
    public var frames: UInt64 = 0
    public var rms: Float = 0
    public var peak: Float = 0
    public var wavFrames: UInt64 = 0
    public var conversionError: String?
    public var aecEnabled: Bool = false
}

/// Converts the microphone ring (whatever VPIO/device format) to 48 kHz stereo
/// float and writes the mic track. Conversion happens off the audio thread.
public final class MicTrackRecorder: @unchecked Sendable {
    private let engine: MonitorEngine
    private let wavURL: URL
    private let queue = DispatchQueue(label: "com.mdxz.facetime.recorder.mic")
    private let lock = NSLock()
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var running = false
    private var stats = MicRecorderStats()
    private var sumSquares: Double = 0
    private var scratch: [Float] = []
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    public init(engine: MonitorEngine, wavURL: URL) throws {
        self.engine = engine
        self.wavURL = wavURL
        self.writer = try WAVWriter(url: wavURL, sampleRate: 48_000, channels: 2)
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000, channels: 2,
                                          interleaved: true)
    }

    public func start() {
        lock.lock()
        guard !running, let source = engine.micSourceFormat, let output = outputFormat else {
            lock.unlock(); return
        }
        // The ring always stores interleaved Float32. Build a canonical
        // interleaved input format so AVAudioPCMBuffer's first channel pointer
        // is the whole interleaved block, regardless of what VPIO reported.
        let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: source.sampleRate,
                                      channels: source.channelCount,
                                      interleaved: true) ?? source
        sourceFormat = canonical
        if canonical.sampleRate != output.sampleRate || canonical.channelCount != output.channelCount {
            converter = AVAudioConverter(from: canonical, to: output)
            if converter == nil {
                stats.conversionError = "AVAudioConverter could not be created"
            }
        }
        inputBuffer = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: 8_192)
        outputBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384)
        scratch = [Float](repeating: 0, count: 8_192 * Int(canonical.channelCount))
        stats.aecEnabled = engine.status.aecEnabled
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
        guard let ring = engine.micRingHandle, let source = sourceFormat,
              let input = inputBuffer, let output = outputBuffer else { return false }
        let available = Int(fr_sample_ring_available(ring))
        guard available > 0 else { return false }
        let channels = Int(source.channelCount)
        let frames = min(available, 4_096)
        if scratch.count < frames * channels {
            scratch = [Float](repeating: 0, count: frames * channels)
        }
        var read = 0
        scratch.withUnsafeMutableBufferPointer { pointer in
            read = Int(fr_sample_ring_read(ring, pointer.baseAddress!, UInt32(frames)))
        }
        guard read > 0 else { return false }

        if let converter {
            input.frameLength = AVAudioFrameCount(read)
            if let destination = input.floatChannelData {
                // Interleaved canonical format: one contiguous block.
                destination[0].update(from: scratch, count: read * channels)
            }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                lock.lock()
                stats.conversionError = error?.localizedDescription ?? "conversion failed"
                lock.unlock()
                return true
            }
            let producedFrames = Int(output.frameLength)
            if producedFrames > 0, let samples = output.floatChannelData?[0] {
                commit(samples: samples, frames: producedFrames)
            }
        } else {
            // Same format: the ring block is already 48k stereo interleaved.
            scratch.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                commit(samples: base, frames: read)
            }
        }
        return true
    }

    private func commit(samples: UnsafePointer<Float>, frames: Int) {
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
        try? writer?.write(samples, frames: frames)
        lock.unlock()
    }
}
