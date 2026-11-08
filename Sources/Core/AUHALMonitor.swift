import Foundation
import AudioToolbox
import CoreAudio
import os

public enum AUHALMonitorError: Error, CustomStringConvertible {
    case noComponent
    case status(String, OSStatus)
    case ringAllocationFailed
    case alreadyRunning

    public var description: String {
        switch self {
        case .noComponent: return "HAL output AudioUnit is unavailable"
        case let .status(operation, code):
            return "\(operation) failed: \(code) (\(CoreAudioError.fourCC(code)))"
        case .ringAllocationFailed: return "monitor ring allocation failed"
        case .alreadyRunning: return "monitor is already running"
        }
    }
}

private final class AUHALMonitorContext {
    let ring: OpaquePointer
    let resampler: DriftResampler
    var scratch: [Float]
    let gain: Float

    init(ring: OpaquePointer, resampler: DriftResampler, gain: Float) {
        self.ring = ring
        self.resampler = resampler
        self.scratch = [Float](repeating: 0, count: 16_384 * 2)
        self.gain = gain
    }
}

private let auhalRender: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let context = Unmanaged<AUHALMonitorContext>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard buffers.count > 0 else { return noErr }
    let first = buffers[0]
    let rawOptional: UnsafeMutableRawPointer? = first.mData
    guard let raw = rawOptional else { return noErr }
    let count = Int(frames)
    guard count > 0, context.scratch.count >= count * 2 else { return noErr }
    let out = raw.assumingMemoryBound(to: Float.self)
    context.scratch.withUnsafeMutableBufferPointer { pointer in
        guard let base = pointer.baseAddress else { return }
        context.resampler.process(ring: context.ring, out: base, frames: count)
        let channels = Int(first.mNumberChannels)
        if channels == 2 {
            for frame in 0..<count {
                out[frame * 2] = base[frame * 2] * context.gain
                out[frame * 2 + 1] = base[frame * 2 + 1] * context.gain
            }
        } else {
            // Mono fallback: average both channels.
            for frame in 0..<count {
                let value = (base[frame * 2] + base[frame * 2 + 1]) * 0.5 * context.gain
                for channel in 0..<channels { out[frame * channels + channel] = value }
            }
        }
    }
    return noErr
}

/// Monitor playback through a dedicated AUHAL output unit. Unlike
/// AVAudioEngine, this can start while FaceTime owns its voice-processing
/// graph, which is exactly the situation the recorder runs in.
public final class AUHALMonitor: @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "monitor")
    private let lock = NSLock()
    private var unit: AudioComponentInstance?
    private var ring: OpaquePointer?
    private var context: AUHALMonitorContext?
    private var running = false
    public private(set) var status = MonitorStatus()
    public private(set) var ringHandle: OpaquePointer?
    private var resampler = DriftResampler(maxFrames: 8_192, sampleRate: 48_000)

    public init() {}

    public func start(deviceUID: String, volume: Float) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw AUHALMonitorError.alreadyRunning }
        guard let device = AudioDeviceCatalog.deviceID(forUID: deviceUID) else {
            throw CoreAudioError.deviceNotFound(deviceUID)
        }
        guard let ring = fr_sample_ring_create(48_000 * 4, 2) else {
            throw AUHALMonitorError.ringAllocationFailed
        }
        self.ring = ring
        ringHandle = ring
        resampler.reset()
        let ctx = AUHALMonitorContext(ring: ring, resampler: resampler,
                                      gain: max(0, min(1, volume)))
        context = ctx

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            cleanupLocked()
            throw AUHALMonitorError.noComponent
        }
        var created: AudioComponentInstance?
        var code = AudioComponentInstanceNew(component, &created)
        guard code == noErr, let instance = created else {
            cleanupLocked()
            throw AUHALMonitorError.status("AudioComponentInstanceNew", code)
        }
        unit = instance
        var enable: UInt32 = 1
        code = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output, 0, &enable, 4)
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("EnableIO(output)", code)
        }
        var deviceID = device
        code = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &deviceID,
                                    UInt32(MemoryLayout<AudioObjectID>.size))
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("CurrentDevice", code)
        }
        var format = AudioStreamBasicDescription.float32(sampleRate: 48_000, channels: 2)
        code = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &format,
                                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("StreamFormat", code)
        }
        var callback = AURenderCallbackStruct(
            inputProc: auhalRender,
            inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque())
        code = AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                    kAudioUnitScope_Input, 0, &callback,
                                    UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("SetRenderCallback", code)
        }
        code = AudioUnitInitialize(instance)
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("AudioUnitInitialize", code)
        }
        code = AudioOutputUnitStart(instance)
        guard code == noErr else {
            cleanupLocked()
            throw AUHALMonitorError.status("AudioOutputUnitStart", code)
        }
        running = true
        status.outputDeviceUID = deviceUID
        status.outputDeviceName = AudioDeviceCatalog.deviceInfo(id: device)?.name
        status.outputSampleRate = 48_000
        status.engineRunning = true
        status.microphoneDeviceUID = nil
        status.aecEnabled = false
        log.info("AUHAL monitor started device=\(deviceUID, privacy: .public)")
    }

    public var fillFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.map { Int(fr_sample_ring_available($0)) } ?? 0
    }

    public var overflows: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return ring.map { fr_sample_ring_overflow_count($0) } ?? 0
    }

    public var underrunFrames: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return resampler.underrunFrames
    }

    public var currentOutputDeviceUID: String? {
        lock.lock()
        let instance = unit
        lock.unlock()
        guard let instance else { return nil }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, &size) == noErr else {
            return nil
        }
        return CA.string(device, kAudioDevicePropertyDeviceUID)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    deinit { stop() }

    private func cleanupLocked() {
        if let unit {
            if running { _ = AudioOutputUnitStop(unit) }
            _ = AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        running = false
        status.engineRunning = false
        ringHandle = nil
        if let ring {
            fr_sample_ring_destroy(ring)
            self.ring = nil
        }
        context = nil
    }
}
