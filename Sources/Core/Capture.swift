import Foundation
import CoreAudio
import AudioToolbox
import os

public struct CapturedBlock: Sendable {
    public let frames: Int
    public let channels: Int
    public let samples: [Float]
    public let hostTime: UInt64
    public let sampleTime: Double
    public let timestampFlags: UInt32
    public let sequence: UInt64
    public let droppedBefore: UInt64
}

/// Common read interface for device taps and process taps.
public protocol BlockAudioSource: AnyObject {
    func readBlock(into buffer: inout [Float]) throws -> CapturedBlock?
}

public struct TapDescriptor: Codable, Sendable {
    public let deviceUID: String
    public let tapUID: String
    public let aggregateUID: String
    public let clockDeviceUID: String
    public let sampleRate: Double
    public let channels: UInt32
    public let bytesPerFrame: UInt32
    public let formatFlags: UInt32
}

public enum CaptureError: Error, CustomStringConvertible {
    case alreadyRunning
    case notRunning
    case noOutputDevice
    case unsupportedFormat(String)
    case noIndependentClock
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case ringAllocationFailed
    case ringFault(UInt32)
    case blockLayout

    public var description: String {
        switch self {
        case .alreadyRunning: return "capture is already running"
        case .notRunning: return "capture is not running"
        case .noOutputDevice: return "no usable output device for the capture clock"
        case let .unsupportedFormat(detail):
            return "unsupported capture format: \(detail)"
        case .noIndependentClock:
            return "no independent clock device (the tapped device cannot clock itself)"
        case let .tapCreationFailed(status):
            return "AudioHardwareCreateProcessTap failed: \(status) (\(CoreAudioError.fourCC(status)))"
        case let .aggregateCreationFailed(status):
            return "AudioHardwareCreateAggregateDevice failed: \(status) (\(CoreAudioError.fourCC(status)))"
        case let .ioProcFailed(status):
            return "AudioDeviceCreateIOProcID failed: \(status) (\(CoreAudioError.fourCC(status)))"
        case let .startFailed(status):
            return "AudioDeviceStart failed: \(status) (\(CoreAudioError.fourCC(status)))"
        case .ringAllocationFailed: return "capture ring allocation failed"
        case let .ringFault(code): return "capture ring fault \(code)"
        case .blockLayout: return "captured block has an unexpected layout"
        }
    }
}

private final class TapContext {
    let ring: OpaquePointer
    let channels: UInt32
    var fault: UInt32 = 0

    init(ring: OpaquePointer, channels: UInt32) {
        self.ring = ring
        self.channels = channels
    }
}

private let tapIOProc: AudioDeviceIOProc = { _, _, input, inputTime, output, _, raw in
    guard let raw else { return noErr }
    let context = Unmanaged<TapContext>.fromOpaque(raw).takeUnretainedValue()
    if input.pointee.mNumberBuffers != 1 {
        context.fault = 1
    } else {
        let buffer = input.pointee.mBuffers
        if let data = buffer.mData, buffer.mNumberChannels == context.channels {
            let frames = buffer.mDataByteSize / (4 * context.channels)
            _ = fr_block_ring_push(context.ring,
                                   data.assumingMemoryBound(to: Float.self),
                                   frames, context.channels,
                                   inputTime.pointee.mFlags.rawValue,
                                   inputTime.pointee.mHostTime,
                                   inputTime.pointee.mSampleTime)
        } else {
            context.fault = 2
        }
    }
    for index in 0..<Int(output.pointee.mNumberBuffers) {
        let buffer = output.pointee.mBuffers
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
    return noErr
}

/// Captures the mix that a *device* is rendering, using a private Core Audio
/// process tap bound to that device (CATapDescription(andDeviceUID:)).
///
/// Audio capture authorization is enforced by TCC. When a process is not
/// authorized the HAL still starts and delivers callbacks, but every sample is
/// zero. That is why callers must run a non-silence self-test and report the
/// result instead of treating a successful start as proof of capture.
public final class DeviceTapCapture: BlockAudioSource, @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "tap")
    private let lock = NSLock()
    private var ring: OpaquePointer?
    private var context: TapContext?
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private(set) public var descriptor: TapDescriptor?

    public init() {}

    public func start(deviceUID: String,
                      preferredClockUID: String? = nil) throws -> TapDescriptor {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw CaptureError.alreadyRunning }

        guard let device = AudioDeviceCatalog.deviceID(forUID: deviceUID) else {
            throw CoreAudioError.deviceNotFound(deviceUID)
        }
        let streams = AudioDeviceCatalog.streams(device: device, direction: .output)
        guard let stream = streams.first,
              let format = CA.asbd(stream.id, kAudioStreamPropertyVirtualFormat) else {
            throw CaptureError.unsupportedFormat("device has no output stream")
        }
        guard format.isFloat32Packed, format.mChannelsPerFrame >= 1,
              format.mChannelsPerFrame <= 8 else {
            throw CaptureError.unsupportedFormat(format.descriptionLine)
        }

        let channels = format.mChannelsPerFrame
        let clockUID = try resolveClockUID(excluding: deviceUID,
                                           preferred: preferredClockUID)

        let description = CATapDescription(__excludingProcesses: [],
                                           andDeviceUID: deviceUID,
                                           withStream: 0)
        description.name = "FaceTime Recorder device tap"
        description.isPrivate = true
        description.isMixdown = false
        description.isMono = false
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        if createdTap != kAudioObjectUnknown { tap = createdTap }
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            cleanupLocked()
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        guard let tapUID = CA.string(tap, kAudioTapPropertyUID) else {
            cleanupLocked()
            throw CaptureError.unsupportedFormat("tap UID unavailable")
        }
        if let tapFormat = CA.asbd(tap, kAudioTapPropertyFormat),
           tapFormat.mChannelsPerFrame != channels ||
           tapFormat.mSampleRate != format.mSampleRate {
            cleanupLocked()
            throw CaptureError.unsupportedFormat(
                "tap format \(tapFormat.descriptionLine) differs from device \(format.descriptionLine)")
        }

        guard let createdRing = fr_block_ring_create(64, 16_384, channels) else {
            cleanupLocked()
            throw CaptureError.ringAllocationFailed
        }
        ring = createdRing
        let ctx = TapContext(ring: createdRing, channels: channels)
        context = ctx

        let aggregateUID = "com.mdxz.facetime.recorder.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FaceTime Recorder capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &createdAggregate)
        if createdAggregate != kAudioObjectUnknown { aggregate = createdAggregate }
        guard aggregateStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            cleanupLocked()
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }

        var createdIO: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregate, tapIOProc,
            Unmanaged.passUnretained(ctx).toOpaque(), &createdIO)
        if let createdIO { ioProc = createdIO }
        guard ioStatus == noErr, createdIO != nil else {
            cleanupLocked()
            throw CaptureError.ioProcFailed(ioStatus)
        }
        let startStatus = AudioDeviceStart(aggregate, createdIO!)
        guard startStatus == noErr else {
            cleanupLocked()
            throw CaptureError.startFailed(startStatus)
        }
        running = true

        let result = TapDescriptor(deviceUID: deviceUID,
                                   tapUID: tapUID,
                                   aggregateUID: aggregateUID,
                                   clockDeviceUID: clockUID,
                                   sampleRate: format.mSampleRate,
                                   channels: channels,
                                   bytesPerFrame: format.mBytesPerFrame,
                                   formatFlags: format.mFormatFlags)
        descriptor = result
        log.info("tap started device=\(deviceUID, privacy: .public) ch=\(channels) clock=\(clockUID, privacy: .public)")
        return result
    }

    public func readBlock(into buffer: inout [Float]) throws -> CapturedBlock? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let ring, let context else { throw CaptureError.notRunning }
        if context.fault != 0 { throw CaptureError.ringFault(context.fault) }
        let maxFrames = Int(fr_block_ring_max_frames(ring))
        let channels = Int(fr_block_ring_channels(ring))
        let needed = maxFrames * channels
        if buffer.count < needed {
            buffer = [Float](repeating: 0, count: needed)
        }
        var meta = FRBlockMeta()
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            fr_block_ring_pop(ring, pointer.baseAddress, UInt32(maxFrames), &meta)
        }
        guard status != -1 else { throw CaptureError.blockLayout }
        guard status == 1 else { return nil }
        let count = Int(meta.frames) * Int(meta.channels)
        return CapturedBlock(frames: Int(meta.frames),
                             channels: Int(meta.channels),
                             samples: Array(buffer[0..<count]),
                             hostTime: meta.host_time,
                             sampleTime: meta.sample_time,
                             timestampFlags: meta.timestamp_flags,
                             sequence: meta.sequence,
                             droppedBefore: meta.dropped_before)
    }

    public var droppedBlocks: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return ring.map { fr_block_ring_dropped($0) } ?? 0
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    deinit { stop() }

    private func cleanupLocked() {
        if running, aggregate != kAudioObjectUnknown, let ioProc {
            _ = AudioDeviceStop(aggregate, ioProc)
        }
        running = false
        if aggregate != kAudioObjectUnknown, let ioProc {
            _ = AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
        if let ring {
            fr_block_ring_destroy(ring)
            self.ring = nil
        }
        context = nil
        descriptor = nil
    }

    private func resolveClockUID(excluding targetUID: String,
                                 preferred: String?) throws -> String {
        // Preferred: the tapped device itself. A private aggregate containing
        // it keeps the sink's IO running (so the tap always delivers blocks)
        // and avoids fighting AVAudioEngine/VPIO for the physical monitor
        // device's clock. Empirically verified on macOS 26.5: 302 callbacks in
        // 3 s with the virtual sink as the aggregate's main subdevice.
        if preferred == targetUID { return targetUID }
        if let target = AudioDeviceCatalog.deviceID(forUID: targetUID),
           AudioDeviceCatalog.streams(device: target, direction: .output).isEmpty == false {
            return targetUID
        }
        if let preferred, preferred != targetUID,
           let device = AudioDeviceCatalog.deviceID(forUID: preferred),
           AudioDeviceCatalog.streams(device: device, direction: .output).isEmpty == false {
            return preferred
        }
        if let id = AudioDeviceCatalog.defaultOutputDeviceID(),
           let uid = CA.string(id, kAudioDevicePropertyDeviceUID), uid != targetUID,
           AudioDeviceCatalog.streams(device: id, direction: .output).isEmpty == false {
            return uid
        }
        let candidates = AudioDeviceCatalog.allDevices().filter {
            $0.uid != targetUID && $0.outputChannels > 0
        }
        if let builtIn = candidates.first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            return builtIn.uid
        }
        guard let first = candidates.first else { throw CaptureError.noIndependentClock }
        return first.uid
    }
}

private final class InputContext {
    let ring: OpaquePointer
    let channels: UInt32
    var fault: UInt32 = 0

    init(ring: OpaquePointer, channels: UInt32) {
        self.ring = ring
        self.channels = channels
    }
}

private let inputIOProc: AudioDeviceIOProc = { _, _, input, inputTime, _, _, raw in
    guard let raw else { return noErr }
    let context = Unmanaged<InputContext>.fromOpaque(raw).takeUnretainedValue()
    if input.pointee.mNumberBuffers != 1 {
        context.fault = 1
        return noErr
    }
    let buffer = input.pointee.mBuffers
    if let data = buffer.mData, buffer.mNumberChannels == context.channels {
        let frames = buffer.mDataByteSize / (4 * context.channels)
        _ = fr_block_ring_push(context.ring,
                               data.assumingMemoryBound(to: Float.self),
                               frames, context.channels,
                               inputTime.pointee.mFlags.rawValue,
                               inputTime.pointee.mHostTime,
                               inputTime.pointee.mSampleTime)
    } else {
        context.fault = 2
    }
    return noErr
}

/// Direct HAL input capture for physical microphones. Used by AudioProbe's
/// `input` mode and by recording tests; the app's microphone path uses
/// AVAudioEngine so it can enable Apple's voice-processing AEC.
public final class DirectInputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: OpaquePointer?
    private var context: InputContext?
    private var ioProc: AudioDeviceIOProcID?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var running = false
    public private(set) var format: AudioStreamBasicDescription?
    public private(set) var deviceUID: String = ""

    public init() {}

    public func start(deviceUID: String) throws -> AudioStreamBasicDescription {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw CaptureError.alreadyRunning }
        guard let id = AudioDeviceCatalog.deviceID(forUID: deviceUID) else {
            throw CoreAudioError.deviceNotFound(deviceUID)
        }
        let streams = AudioDeviceCatalog.streams(device: id, direction: .input)
        guard let stream = streams.first,
              let fmt = CA.asbd(stream.id, kAudioStreamPropertyVirtualFormat) else {
            throw CaptureError.unsupportedFormat("device has no input stream")
        }
        guard fmt.isFloat32Packed else {
            throw CaptureError.unsupportedFormat(fmt.descriptionLine)
        }
        guard let createdRing = fr_block_ring_create(64, 16_384, fmt.mChannelsPerFrame) else {
            throw CaptureError.ringAllocationFailed
        }
        ring = createdRing
        let ctx = InputContext(ring: createdRing, channels: fmt.mChannelsPerFrame)
        context = ctx

        var createdIO: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            id, inputIOProc, Unmanaged.passUnretained(ctx).toOpaque(), &createdIO)
        if let createdIO { ioProc = createdIO }
        guard status == noErr, let createdIO else {
            cleanupLocked()
            throw CaptureError.ioProcFailed(status)
        }
        let started = AudioDeviceStart(id, createdIO)
        guard started == noErr else {
            cleanupLocked()
            throw CaptureError.startFailed(started)
        }
        device = id
        running = true
        format = fmt
        self.deviceUID = deviceUID
        return fmt
    }

    public func readBlock(into buffer: inout [Float]) throws -> CapturedBlock? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let ring, let context else { throw CaptureError.notRunning }
        if context.fault != 0 { throw CaptureError.ringFault(context.fault) }
        let maxFrames = Int(fr_block_ring_max_frames(ring))
        let channels = Int(fr_block_ring_channels(ring))
        if buffer.count < maxFrames * channels {
            buffer = [Float](repeating: 0, count: maxFrames * channels)
        }
        var meta = FRBlockMeta()
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            fr_block_ring_pop(ring, pointer.baseAddress, UInt32(maxFrames), &meta)
        }
        guard status != -1 else { throw CaptureError.blockLayout }
        guard status == 1 else { return nil }
        let count = Int(meta.frames) * Int(meta.channels)
        return CapturedBlock(frames: Int(meta.frames),
                             channels: Int(meta.channels),
                             samples: Array(buffer[0..<count]),
                             hostTime: meta.host_time,
                             sampleTime: meta.sample_time,
                             timestampFlags: meta.timestamp_flags,
                             sequence: meta.sequence,
                             droppedBefore: meta.dropped_before)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    deinit { stop() }

    private func cleanupLocked() {
        if device != kAudioObjectUnknown, let ioProc {
            if running { _ = AudioDeviceStop(device, ioProc) }
            _ = AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        device = kAudioObjectUnknown
        running = false
        if let ring {
            fr_block_ring_destroy(ring)
            self.ring = nil
        }
        context = nil
    }
}
