import Foundation
import CoreAudio

/// Direction of a Core Audio stream/device as observed through the HAL.
public enum AudioDirection: String, Codable, Sendable {
    case input
    case output
}

public struct AudioStreamInfo: Sendable, Identifiable {
    public let id: AudioObjectID
    public let direction: AudioDirection
    public let virtualFormat: AudioStreamBasicDescription
    public let physicalFormat: AudioStreamBasicDescription?

    public init(id: AudioObjectID,
                direction: AudioDirection,
                virtualFormat: AudioStreamBasicDescription,
                physicalFormat: AudioStreamBasicDescription?) {
        self.id = id
        self.direction = direction
        self.virtualFormat = virtualFormat
        self.physicalFormat = physicalFormat
    }
}

public struct ASBDInfo: Codable, Sendable {
    public let sampleRate: Double
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let bytesPerFrame: UInt32
    public let channelsPerFrame: UInt32
    public let bitsPerChannel: UInt32
    public let isFloat32Packed: Bool
    public let description: String

    public init(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate
        formatID = asbd.mFormatID
        formatFlags = asbd.mFormatFlags
        bytesPerPacket = asbd.mBytesPerPacket
        framesPerPacket = asbd.mFramesPerPacket
        bytesPerFrame = asbd.mBytesPerFrame
        channelsPerFrame = asbd.mChannelsPerFrame
        bitsPerChannel = asbd.mBitsPerChannel
        isFloat32Packed = asbd.isFloat32Packed
        description = asbd.descriptionLine
    }
}

public struct StreamSnapshot: Codable, Sendable {
    public let id: AudioObjectID
    public let direction: String
    public let virtualFormat: ASBDInfo
    public let physicalFormat: ASBDInfo?

    public init(_ stream: AudioStreamInfo) {
        id = stream.id
        direction = stream.direction.rawValue
        virtualFormat = ASBDInfo(stream.virtualFormat)
        physicalFormat = stream.physicalFormat.map(ASBDInfo.init)
    }
}

public struct DeviceSnapshot: Codable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let modelUID: String?
    public let transport: UInt32
    public let transportName: String
    public let nominalSampleRate: Double
    public let bufferFrameSize: UInt32?
    public let deviceLatencyFrames: UInt32?
    public let safetyOffsetFrames: UInt32?
    public let inputChannels: Int
    public let outputChannels: Int
    public let inputStreams: [StreamSnapshot]
    public let outputStreams: [StreamSnapshot]
    public let preferredOutputChannelLabels: [String]
    public let isVirtual: Bool
    public let isHomePodFlowDevice: Bool

    public init(_ device: AudioDeviceInfo) {
        id = device.id
        uid = device.uid
        name = device.name
        modelUID = device.modelUID
        transport = device.transport
        transportName = device.transportName
        nominalSampleRate = device.nominalSampleRate
        bufferFrameSize = device.bufferFrameSize
        deviceLatencyFrames = device.deviceLatencyFrames
        safetyOffsetFrames = device.safetyOffsetFrames
        inputChannels = device.inputChannels
        outputChannels = device.outputChannels
        inputStreams = device.inputStreams.map(StreamSnapshot.init)
        outputStreams = device.outputStreams.map(StreamSnapshot.init)
        preferredOutputChannelLabels = device.preferredOutputChannelLabels
        isVirtual = device.isVirtual
        isHomePodFlowDevice = device.isHomePodFlowDevice
    }
}

public struct AudioDeviceInfo: Sendable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let modelUID: String?
    public let transport: UInt32
    public let transportName: String
    public let nominalSampleRate: Double
    public let bufferFrameSize: UInt32?
    public let deviceLatencyFrames: UInt32?
    public let safetyOffsetFrames: UInt32?
    public let inputChannels: Int
    public let outputChannels: Int
    public let inputStreams: [AudioStreamInfo]
    public let outputStreams: [AudioStreamInfo]
    public let preferredOutputChannelLabels: [String]

    public var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }
    public var isInputCapable: Bool { inputChannels > 0 }
    public var isOutputCapable: Bool { outputChannels > 0 }
    public var isHomePodFlowDevice: Bool {
        uid.hasPrefix("com.homepodflow.virtual-audio") ||
        name.localizedCaseInsensitiveContains("HomePod Flow")
    }

    public var summary: String {
        var parts: [String] = []
        if outputChannels > 0 {
            parts.append("out \(outputChannels)ch@\(Int(nominalSampleRate))")
        }
        if inputChannels > 0 {
            parts.append("in \(inputChannels)ch@\(Int(nominalSampleRate))")
        }
        if parts.isEmpty { parts.append("no streams") }
        return parts.joined(separator: " / ")
    }

    public init(id: AudioObjectID,
                uid: String,
                name: String,
                modelUID: String?,
                transport: UInt32,
                transportName: String,
                nominalSampleRate: Double,
                bufferFrameSize: UInt32?,
                deviceLatencyFrames: UInt32?,
                safetyOffsetFrames: UInt32?,
                inputChannels: Int,
                outputChannels: Int,
                inputStreams: [AudioStreamInfo],
                outputStreams: [AudioStreamInfo],
                preferredOutputChannelLabels: [String]) {
        self.id = id
        self.uid = uid
        self.name = name
        self.modelUID = modelUID
        self.transport = transport
        self.transportName = transportName
        self.nominalSampleRate = nominalSampleRate
        self.bufferFrameSize = bufferFrameSize
        self.deviceLatencyFrames = deviceLatencyFrames
        self.safetyOffsetFrames = safetyOffsetFrames
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.inputStreams = inputStreams
        self.outputStreams = outputStreams
        self.preferredOutputChannelLabels = preferredOutputChannelLabels
    }
}

public enum RemoteChannelMode: String, Codable, Sendable {
    /// Downmix FL/FR to a stereo recording and monitoring feed (default).
    case stereoDownmix = "stereo"
    /// Preserve every capture channel (for diagnostics / surround sources).
    case native = "native"
}

public enum EchoCancellationMode: String, Codable, Sendable {
    /// Apple voice-processing I/O (real, hardware-accelerated AEC).
    case appleVoiceProcessing = "apple_vpio"
    /// No echo cancellation. Only safe when monitoring is off or headphones are used.
    case off = "off"
}

public struct RecorderConfiguration: Codable, Sendable {
    public var remoteDeviceUID: String
    /// When false, no device tap is created and no remote track is written.
    public var recordRemote: Bool
    public var microphoneUID: String?
    public var monitorOutputUID: String?
    public var captureDisplayID: UInt32?
    public var captureWindowID: UInt32?
    public var recordVideo: Bool
    public var recordMicrophone: Bool
    public var monitorEnabled: Bool
    public var monitorVolume: Float
    public var echoCancellation: EchoCancellationMode
    public var remoteChannelMode: RemoteChannelMode
    public var takeOverSystemOutput: Bool
    public var outputDirectory: URL

    public init(remoteDeviceUID: String,
                recordRemote: Bool = true,
                microphoneUID: String? = nil,
                monitorOutputUID: String? = nil,
                captureDisplayID: UInt32? = nil,
                captureWindowID: UInt32? = nil,
                recordVideo: Bool = true,
                recordMicrophone: Bool = true,
                monitorEnabled: Bool = true,
                monitorVolume: Float = 0.9,
                echoCancellation: EchoCancellationMode = .appleVoiceProcessing,
                remoteChannelMode: RemoteChannelMode = .stereoDownmix,
                takeOverSystemOutput: Bool = false,
                outputDirectory: URL = RecorderPaths.defaultOutputDirectory) {
        self.remoteDeviceUID = remoteDeviceUID
        self.recordRemote = recordRemote
        self.microphoneUID = microphoneUID
        self.monitorOutputUID = monitorOutputUID
        self.captureDisplayID = captureDisplayID
        self.captureWindowID = captureWindowID
        self.recordVideo = recordVideo
        self.recordMicrophone = recordMicrophone
        self.monitorEnabled = monitorEnabled
        self.monitorVolume = monitorVolume
        self.echoCancellation = echoCancellation
        self.remoteChannelMode = remoteChannelMode
        self.takeOverSystemOutput = takeOverSystemOutput
        self.outputDirectory = outputDirectory
    }
}

public enum RecorderState: String, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case muxing
    case finished
    case failed
}

public struct LevelSnapshot: Sendable {
    public var remoteRMS: Float = 0
    public var remotePeak: Float = 0
    public var micRMS: Float = 0
    public var micPeak: Float = 0
    public var monitorFillFrames: Int = 0
    public var remoteChannelRMS: [Float] = []
}

public struct RecordingResult: Sendable {
    public let sessionDirectory: URL
    public let mkvURL: URL?
    public let mp4URL: URL?
    public let videoURL: URL?
    public let remoteWAVURL: URL?
    public let micWAVURL: URL?
    public let diagnosticsURL: URL
    public let durationSeconds: Double
}

public enum RecorderPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("FaceTime Recorder", isDirectory: true)
    }

    public static var defaultOutputDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory,
                                             in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("FaceTime Recorder", isDirectory: true)
    }

    public static var leaseURL: URL {
        supportDirectory.appendingPathComponent("output-lease.json")
    }
}

public struct OutputLease: Codable, Sendable {
    public let createdAt: Date
    public let virtualDeviceUID: String
    public let originalDefaultOutputUID: String?
    public let didChangeDefaultOutput: Bool
    public let processIdentifier: Int32
}
