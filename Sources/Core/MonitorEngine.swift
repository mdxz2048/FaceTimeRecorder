import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

public struct MonitorStatus: Sendable {
    public var outputDeviceUID: String?
    public var outputDeviceName: String?
    public var outputSampleRate: Double = 0
    public var microphoneDeviceUID: String?
    public var microphoneFormat: String?
    public var aecEnabled: Bool = false
    public var aecError: String?
    public var engineRunning: Bool = false
    public var warnings: [String] = []
}

public enum MonitorError: Error, CustomStringConvertible {
    case noMicrophone
    case engineStartFailed(String)
    case ringAllocationFailed

    public var description: String {
        switch self {
        case .noMicrophone: return "no microphone input node"
        case let .engineStartFailed(message): return "audio engine failed to start: \(message)"
        case .ringAllocationFailed: return "monitor ring allocation failed"
        }
    }
}

/// Owns the AVAudioEngine used for:
///   * monitor playback (remote PCM -> selected physical output), and
///   * microphone capture (optionally with Apple voice-processing AEC).
///
/// The engine's source-node render callback is the only monitor consumer; the
/// input tap is the only microphone producer. Both feed preallocated SPSC
/// rings, never the filesystem.
public final class MonitorEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "monitor")
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sourceNode: AVAudioSourceNode?
    private var monitorRing: OpaquePointer?
    private var micRing: OpaquePointer?
    private var resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)
    private var micScratch = [Float](repeating: 0, count: 16_384)
    private var sourceScratch = [Float](repeating: 0, count: 16_384 * 2)
    private var running = false
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    public private(set) var status = MonitorStatus()
    public private(set) var micSourceFormat: AVAudioFormat?
    public private(set) var outputFormat: AVAudioFormat?
    public private(set) var monitorRingHandle: OpaquePointer?
    public private(set) var micRingHandle: OpaquePointer?

    // AVAudioEngine mixers accept non-interleaved float; the resampler still
    // produces interleaved samples and the render block deinterleaves them.
    public static let processingFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000, channels: 2)!

    public init() {}

    public func start(outputDeviceUID: String?,
                      microphoneDeviceUID: String?,
                      monitorEnabled: Bool,
                      monitorVolume: Float,
                      echoCancellation: EchoCancellationMode) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        status = MonitorStatus()
        status.outputDeviceUID = outputDeviceUID
        status.microphoneDeviceUID = microphoneDeviceUID

        let ringCapacity = 48_000 * 4
        guard let ring = fr_sample_ring_create(UInt32(ringCapacity), 2) else {
            throw MonitorError.engineStartFailed("monitor ring \(ringCapacity)x2 allocation failed")
        }
        monitorRing = ring
        monitorRingHandle = ring
        resampler.reset()

        let format = Self.processingFormat
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self, let ring = self.monitorRingHandle else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard frames > 0, buffers.count >= 2,
                  let leftRaw = buffers[0].mData,
                  let rightRaw = buffers[1].mData,
                  self.sourceScratch.count >= frames * 2 else { return noErr }
            self.sourceScratch.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                self.resampler.process(ring: ring, out: base, frames: frames)
                let left = leftRaw.assumingMemoryBound(to: Float.self)
                let right = rightRaw.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    left[frame] = base[frame * 2]
                    right[frame] = base[frame * 2 + 1]
                }
            }
            return noErr
        }
        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = monitorEnabled ? max(0, min(1, monitorVolume)) : 0

        if let outputDeviceUID {
            applyOutputDevice(uid: outputDeviceUID)
        }
        if let au = engine.outputNode.audioUnit {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output, 0, &asbd, &size) == noErr {
                status.outputSampleRate = asbd.mSampleRate
                outputFormat = AVAudioFormat(streamDescription: &asbd)
            }
        }

        if let microphoneDeviceUID {
            try configureMicrophone(uid: microphoneDeviceUID,
                                    echoCancellation: echoCancellation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            throw MonitorError.engineStartFailed(error.localizedDescription)
        }
        running = true
        status.engineRunning = true
        // Some engines follow the system default output on configuration
        // changes. Re-assert the physical monitor device and keep watching.
        reassertOutputDevice()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main) { [weak self] _ in
                self?.reassertOutputDevice()
            }
        log.info("monitor engine started output=\(outputDeviceUID ?? "default", privacy: .public) aec=\(self.status.aecEnabled)")
    }

    /// Re-binds the engine output to the physical device chosen before the
    /// default-output takeover. Safe to call while running.
    public func reassertOutputDevice() {
        lock.lock()
        let uid = status.outputDeviceUID
        lock.unlock()
        guard let uid else { return }
        applyOutputDevice(uid: uid)
    }

    /// Reads the output device actually bound to the engine's AUHAL unit.
    public func currentOutputDeviceUID() -> String? {
        lock.lock()
        let au = engine.outputNode.audioUnit
        lock.unlock()
        guard let au else { return nil }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, &size)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return CA.string(device, kAudioDevicePropertyDeviceUID)
    }

    public func setMonitorVolume(_ volume: Float, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        engine.mainMixerNode.outputVolume = enabled ? max(0, min(1, volume)) : 0
    }

    public func setMonitorEnabled(_ enabled: Bool, volume: Float) {
        setMonitorVolume(volume, enabled: enabled)
    }

    public var monitorRingFillFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return monitorRing.map { Int(fr_sample_ring_available($0)) } ?? 0
    }

    public var monitorOverflows: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return monitorRing.map { fr_sample_ring_overflow_count($0) } ?? 0
    }

    public var monitorUnderrunFrames: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return resampler.underrunFrames
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanup()
    }

    deinit { stop() }

    private func cleanup() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if running { engine.stop() }
        running = false
        status.engineRunning = false
        micRingHandle = nil
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        if let monitorRing {
            fr_sample_ring_destroy(monitorRing)
            self.monitorRing = nil
        }
        monitorRingHandle = nil
        if let micRing {
            fr_sample_ring_destroy(micRing)
            self.micRing = nil
        }
    }

    private func applyOutputDevice(uid: String) {
        guard let device = AudioDeviceCatalog.deviceID(forUID: uid),
              let au = engine.outputNode.audioUnit else {
            status.warnings.append("无法设置监听输出设备 \(uid)")
            return
        }
        var value = device
        let statusCode = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &value,
                                              UInt32(MemoryLayout<AudioObjectID>.size))
        if statusCode != noErr {
            status.warnings.append("监听输出设备设置失败：\(statusCode)")
        }
        status.outputDeviceName = AudioDeviceCatalog.deviceInfo(id: device)?.name
    }

    private func configureMicrophone(uid: String, echoCancellation: EchoCancellationMode) throws {
        let input = engine.inputNode
        guard let device = AudioDeviceCatalog.deviceID(forUID: uid) else {
            throw CoreAudioError.deviceNotFound(uid)
        }
        if let au = input.audioUnit {
            var value = device
            let code = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &value,
                                            UInt32(MemoryLayout<AudioObjectID>.size))
            if code != noErr {
                status.warnings.append("麦克风设备设置失败：\(code)")
            }
        }
        if echoCancellation == .appleVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                status.aecEnabled = true
                // Enabling VPIO can reset the engine's output device to the
                // (possibly virtual) system default. Re-apply the physical
                // monitor device afterwards.
                if let outputUID = status.outputDeviceUID {
                    applyOutputDevice(uid: outputUID)
                }
            } catch {
                status.aecEnabled = false
                status.aecError = error.localizedDescription
                status.warnings.append("Apple 回声消除不可用，已回退为无 AEC：\(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MonitorError.noMicrophone
        }
        // Voice-processing I/O can expose 9 channels (mic + internal
        // reference/processed channels). Channel 0 is the processed capture
        // signal we want; storing all nine would be wasteful.
        guard let ring = fr_sample_ring_create(48_000 * 10, 1) else {
            throw MonitorError.engineStartFailed("microphone ring 480000x\(format.channelCount) allocation failed")
        }
        micRing = ring
        micRingHandle = ring
        let captureFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                          channels: 1)
        micSourceFormat = captureFormat
        status.microphoneFormat = "\(Int(format.sampleRate)) Hz, source \(format.channelCount) ch → mono"
        micScratch = [Float](repeating: 0, count: 16_384)

        let sourceChannels = Int(format.channelCount)
        let interleaved = format.isInterleaved
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let ring = self.micRingHandle else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { return }
            if self.micScratch.count < frames { return }
            self.micScratch.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                if interleaved {
                    let stride = max(sourceChannels, 1)
                    let source = data[0]
                    for frame in 0..<frames { base[frame] = source[frame * stride] }
                } else {
                    base.update(from: data[0], count: frames)
                }
                _ = fr_sample_ring_write(ring, base, UInt32(frames))
            }
        }
        tapInstalled = true
    }
}
