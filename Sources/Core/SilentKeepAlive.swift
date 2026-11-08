import Foundation
import AudioToolbox
import CoreAudio

public enum SilentKeepAliveError: Error, CustomStringConvertible {
    case noComponent
    case status(String, OSStatus)
    case alreadyRunning

    public var description: String {
        switch self {
        case .noComponent: return "HAL output AudioUnit is unavailable"
        case let .status(operation, code):
            return "\(operation) failed: \(code) (\(CoreAudioError.fourCC(code)))"
        case .alreadyRunning: return "keep-alive already running"
        }
    }
}

private let silentRender: AURenderCallback = { _, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for index in 0..<buffers.count {
        if let data = buffers[index].mData {
            memset(data, 0, Int(buffers[index].mDataByteSize))
        }
    }
    _ = frames
    return noErr
}

/// Renders silence into the virtual sink so its IO stays running. Without a
/// client, the device tap can deliver zero callbacks; this makes capture
/// deterministic and lets us tell "FaceTime is not routed here" (all-zero PCM)
/// apart from "the device is idle" (no callbacks at all).
public final class SilentKeepAlive: @unchecked Sendable {
    private let lock = NSLock()
    private var unit: AudioComponentInstance?
    private var running = false

    public init() {}

    public func start(deviceUID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw SilentKeepAliveError.alreadyRunning }
        guard let device = AudioDeviceCatalog.deviceID(forUID: deviceUID) else {
            throw CoreAudioError.deviceNotFound(deviceUID)
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw SilentKeepAliveError.noComponent
        }
        var created: AudioComponentInstance?
        var code = AudioComponentInstanceNew(component, &created)
        guard code == noErr, let instance = created else {
            throw SilentKeepAliveError.status("AudioComponentInstanceNew", code)
        }
        unit = instance
        var enable: UInt32 = 1
        code = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output, 0, &enable, 4)
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("EnableIO", code) }
        var deviceID = device
        code = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &deviceID,
                                    UInt32(MemoryLayout<AudioObjectID>.size))
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("CurrentDevice", code) }
        var format = AudioStreamBasicDescription.float32(sampleRate: 48_000, channels: 2)
        code = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &format,
                                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("StreamFormat", code) }
        var callback = AURenderCallbackStruct(inputProc: silentRender, inputProcRefCon: nil)
        code = AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                    kAudioUnitScope_Input, 0, &callback,
                                    UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("SetRenderCallback", code) }
        code = AudioUnitInitialize(instance)
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("AudioUnitInitialize", code) }
        code = AudioOutputUnitStart(instance)
        guard code == noErr else { cleanupLocked(); throw SilentKeepAliveError.status("AudioOutputUnitStart", code) }
        running = true
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
    }
}
