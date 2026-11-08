import Foundation
import CoreAudio
import AudioToolbox
import os

public enum ProcessTapError: Error, CustomStringConvertible {
    case processNotFound(String)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case unsupportedFormat(String)
    case ringAllocationFailed
    case noClockDevice

    public var description: String {
        switch self {
        case let .processNotFound(name): return "process \(name) is not running"
        case let .tapCreationFailed(code): return "AudioHardwareCreateProcessTap failed: \(code) (\(CoreAudioError.fourCC(code)))"
        case let .aggregateCreationFailed(code): return "AudioHardwareCreateAggregateDevice failed: \(code) (\(CoreAudioError.fourCC(code)))"
        case let .ioProcFailed(code): return "AudioDeviceCreateIOProcID failed: \(code)"
        case let .startFailed(code): return "AudioDeviceStart failed: \(code)"
        case let .unsupportedFormat(detail): return "unsupported process tap format: \(detail)"
        case .ringAllocationFailed: return "process tap ring allocation failed"
        case .noClockDevice: return "no physical clock device for the process tap"
        }
    }
}

private final class ProcessTapContext {
    let ring: OpaquePointer
    let channels: UInt32
    var fault: UInt32 = 0
    init(ring: OpaquePointer, channels: UInt32) {
        self.ring = ring
        self.channels = channels
    }
}

private let processTapIOProc: AudioDeviceIOProc = { _, _, input, inputTime, output, _, raw in
    guard let raw else { return noErr }
    let context = Unmanaged<ProcessTapContext>.fromOpaque(raw).takeUnretainedValue()
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
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}

/// Taps a specific process's audio via Core Audio process taps. FaceTime call
/// audio is rendered by `/usr/libexec/avconferenced`, not by the FaceTime UI
/// process, so this is the path that captures the remote party independently
/// of the output device.
public final class ProcessTapCapture: BlockAudioSource, @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "process-tap")
    private let lock = NSLock()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    private var context: ProcessTapContext?
    private var running = false
    public private(set) var descriptor: TapDescriptor?

    public init() {}

    public static func findProcess(named name: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// CATapDescription takes Core Audio process objects, not Unix PIDs.
    public static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &value,
            &size,
            &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    public func start(processID: pid_t) throws -> TapDescriptor {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return descriptor! }

        guard let processObject = Self.processObject(forPID: processID) else {
            throw ProcessTapError.processNotFound("pid \(processID)")
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "FaceTime Recorder call audio"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        if createdTap != kAudioObjectUnknown { tap = createdTap }
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            cleanupLocked()
            throw ProcessTapError.tapCreationFailed(tapStatus)
        }
        guard let tapUID = CA.string(tap, kAudioTapPropertyUID),
              let tapFormat = CA.asbd(tap, kAudioTapPropertyFormat) else {
            cleanupLocked()
            throw ProcessTapError.unsupportedFormat("tap UID/format unavailable")
        }
        guard tapFormat.isFloat32Packed, tapFormat.mChannelsPerFrame >= 1,
              tapFormat.mChannelsPerFrame <= 8 else {
            cleanupLocked()
            throw ProcessTapError.unsupportedFormat(tapFormat.descriptionLine)
        }
        let channels = tapFormat.mChannelsPerFrame
        guard let createdRing = fr_block_ring_create(64, 16_384, channels) else {
            cleanupLocked()
            throw ProcessTapError.ringAllocationFailed
        }
        ring = createdRing
        let ctx = ProcessTapContext(ring: createdRing, channels: channels)
        context = ctx

        guard let clockUID = resolveClockUID() else {
            cleanupLocked()
            throw ProcessTapError.noClockDevice
        }
        let aggregateUID = "com.mdxz.facetime.recorder.process.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FaceTime Recorder call capture",
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
            throw ProcessTapError.aggregateCreationFailed(aggregateStatus)
        }

        var createdIO: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregate, processTapIOProc,
            Unmanaged.passUnretained(ctx).toOpaque(), &createdIO)
        if let createdIO { ioProc = createdIO }
        guard ioStatus == noErr, let createdIO else {
            cleanupLocked()
            throw ProcessTapError.ioProcFailed(ioStatus)
        }
        let startStatus = AudioDeviceStart(aggregate, createdIO)
        guard startStatus == noErr else {
            cleanupLocked()
            throw ProcessTapError.startFailed(startStatus)
        }
        running = true
        let result = TapDescriptor(deviceUID: "process:\(processID)",
                                   tapUID: tapUID,
                                   aggregateUID: aggregateUID,
                                   clockDeviceUID: clockUID,
                                   sampleRate: tapFormat.mSampleRate,
                                   channels: channels,
                                   bytesPerFrame: tapFormat.mBytesPerFrame,
                                   formatFlags: tapFormat.mFormatFlags)
        descriptor = result
        log.info("process tap started pid=\(processID) ch=\(channels)")
        return result
    }

    public func readBlock(into buffer: inout [Float]) throws -> CapturedBlock? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let ring, let context else { return nil }
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

    public var droppedBlocks: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return ring.map { fr_block_ring_dropped($0) } ?? 0
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
    }

    deinit { stop() }

    private func resolveClockUID() -> String? {
        if let id = AudioDeviceCatalog.defaultOutputDeviceID(),
           let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
           uid != "com.homepodflow.virtual-audio.surround71.v1" {
            return uid
        }
        return AudioDeviceCatalog.allDevices().first(where: {
            $0.uid == "BuiltInSpeakerDevice"
        })?.uid
    }

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
}
