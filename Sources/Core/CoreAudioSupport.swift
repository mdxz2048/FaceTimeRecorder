import Foundation
import CoreAudio
import AudioToolbox

public enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(operation: String, status: OSStatus)
    case missingProperty(object: AudioObjectID, selector: String)
    case badFormat(String)
    case deviceNotFound(String)

    public var description: String {
        switch self {
        case let .osStatus(operation, status):
            return "\(operation) failed with OSStatus \(status) (\(Self.fourCC(status)))"
        case let .missingProperty(object, selector):
            return "property \(selector) missing on object \(object)"
        case let .badFormat(message):
            return "bad audio format: \(message)"
        case let .deviceNotFound(uid):
            return "audio device not found for UID \(uid)"
        }
    }

    static func fourCC(_ value: OSStatus) -> String {
        let v = UInt32(bitPattern: value)
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "?"
        }
        return String(format: "0x%08X", v)
    }
}

public enum CA {
    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func get<T>(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                              as type: T.Type) -> T? {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size) else {
            return nil
        }
        return pointer.pointee
    }

    public static func string(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    public static func ids(_ object: AudioObjectID,
                           _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    public static func asbd(_ object: AudioObjectID,
                            _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioStreamBasicDescription? {
        var addr = address(selector, scope: scope)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &format) == noErr,
              size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            return nil
        }
        return format
    }

    public static func set<T>(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                              value: T) -> OSStatus {
        var addr = address(selector, scope: scope, element: element)
        var copy = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                          UInt32(MemoryLayout<T>.size), &copy)
    }

    public static func has(_ object: AudioObjectID,
                           _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                           element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(object, &addr)
    }

    public static func systemObject() -> AudioObjectID {
        AudioObjectID(kAudioObjectSystemObject)
    }
}

public enum AudioDeviceCatalog {
    public static func allDevices() -> [AudioDeviceInfo] {
        let ids = CA.ids(CA.systemObject(), kAudioHardwarePropertyDevices)
        return ids.compactMap(deviceInfo)
    }

    public static func defaultOutputDeviceID() -> AudioObjectID? {
        CA.get(CA.systemObject(), kAudioHardwarePropertyDefaultOutputDevice,
               as: AudioObjectID.self)
    }

    public static func defaultInputDeviceID() -> AudioObjectID? {
        CA.get(CA.systemObject(), kAudioHardwarePropertyDefaultInputDevice,
               as: AudioObjectID.self)
    }

    public static func defaultOutputUID() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return CA.string(id, kAudioDevicePropertyDeviceUID)
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(CA.systemObject(), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0,
                                       &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    public static func deviceInfo(id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CA.string(id, kAudioObjectPropertyName) ?? uid
        let model = CA.string(id, kAudioDevicePropertyModelUID)
        let transport: UInt32 = CA.get(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0
        let rate: Float64 = CA.get(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        let buffer: UInt32? = CA.get(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)
        let latency: UInt32? = CA.get(id, kAudioDevicePropertyLatency,
                                      scope: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        let safety: UInt32? = CA.get(id, kAudioDevicePropertySafetyOffset,
                                     scope: kAudioObjectPropertyScopeOutput, as: UInt32.self)

        let inStreams = streams(device: id, direction: .input)
        let outStreams = streams(device: id, direction: .output)
        let inChannels = inStreams.reduce(0) { $0 + Int($1.virtualFormat.mChannelsPerFrame) }
        let outChannels = outStreams.reduce(0) { $0 + Int($1.virtualFormat.mChannelsPerFrame) }

        return AudioDeviceInfo(id: id, uid: uid, name: name, modelUID: model,
                               transport: transport, transportName: transportName(transport),
                               nominalSampleRate: rate, bufferFrameSize: buffer,
                               deviceLatencyFrames: latency, safetyOffsetFrames: safety,
                               inputChannels: inChannels, outputChannels: outChannels,
                               inputStreams: inStreams, outputStreams: outStreams,
                               preferredOutputChannelLabels: channelLabels(device: id,
                                                                           channels: outChannels))
    }

    public static func streams(device: AudioObjectID, direction: AudioDirection) -> [AudioStreamInfo] {
        let scope = direction == .input ? kAudioObjectPropertyScopeInput
                                        : kAudioObjectPropertyScopeOutput
        let ids = CA.ids(device, kAudioDevicePropertyStreams, scope: scope)
        return ids.compactMap { stream in
            guard let virtual = CA.asbd(stream, kAudioStreamPropertyVirtualFormat) else {
                return nil
            }
            let physical = CA.asbd(stream, kAudioStreamPropertyPhysicalFormat)
            return AudioStreamInfo(id: stream, direction: direction,
                                   virtualFormat: virtual, physicalFormat: physical)
        }
    }

    public static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity Capture (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity Capture (wireless)"
        default: return "0x\(String(type, radix: 16))"
        }
    }

    /// Reads the preferred output channel layout and maps Core Audio labels to
    /// short names (FL, FR, FC, ...). Falls back to the canonical 7.1 order.
    public static func channelLabels(device: AudioObjectID, channels: Int) -> [String] {
        guard channels > 0 else { return [] }
        var addr = CA.address(kAudioDevicePropertyPreferredChannelLayout,
                              scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 12 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr {
                let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
                let tag = layout.pointee.mChannelLayoutTag
                if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
                    let count = Int(layout.pointee.mNumberChannelDescriptions)
                    let base = raw
                        .advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                        .assumingMemoryBound(to: AudioChannelDescription.self)
                    var result: [String] = []
                    for index in 0..<count {
                        result.append(labelName(base[index].mChannelLabel))
                    }
                    if result.count >= channels,
                       result.prefix(channels).contains(where: { $0 != "?" }) {
                        return Array(result.prefix(channels))
                    }
                }
            }
        }
        let canonical = ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"]
        if channels <= canonical.count { return Array(canonical.prefix(channels)) }
        return (0..<channels).map { $0 < canonical.count ? canonical[$0] : "CH\($0)" }
    }

    public static func labelName(_ label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: return "FL"
        case kAudioChannelLabel_Right: return "FR"
        case kAudioChannelLabel_Center: return "FC"
        case kAudioChannelLabel_LFEScreen: return "LFE"
        case kAudioChannelLabel_LeftSurround: return "SL"
        case kAudioChannelLabel_RightSurround: return "SR"
        case kAudioChannelLabel_LeftSurroundDirect: return "BL"
        case kAudioChannelLabel_RightSurroundDirect: return "BR"
        case kAudioChannelLabel_LeftCenter: return "FLC"
        case kAudioChannelLabel_RightCenter: return "FRC"
        case kAudioChannelLabel_CenterSurround: return "CS"
        case kAudioChannelLabel_Mono: return "M"
        case kAudioChannelLabel_Unknown: return "?"
        default: return "L\(label)"
        }
    }

    public static func setDefaultOutput(uid: String) throws {
        guard let device = deviceID(forUID: uid) else {
            throw CoreAudioError.deviceNotFound(uid)
        }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        let status = AudioObjectSetPropertyData(CA.systemObject(), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else {
            throw CoreAudioError.osStatus(operation: "set default output", status: status)
        }
    }
}

public extension AudioStreamBasicDescription {
    var isFloat32Packed: Bool {
        mFormatID == kAudioFormatLinearPCM &&
        (mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
        (mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
        mBitsPerChannel == 32 &&
        mBytesPerFrame == 4 * mChannelsPerFrame &&
        mFramesPerPacket == 1
    }

    var descriptionLine: String {
        let kind = isFloat32Packed ? "Float32" : "fmt=\(mFormatID)"
        return "\(Int(mSampleRate)) Hz, \(mChannelsPerFrame) ch, \(kind), \(mBytesPerFrame) B/frame"
    }

    static func float32(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                          kAudioFormatFlagsNativeEndian |
                          kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}
