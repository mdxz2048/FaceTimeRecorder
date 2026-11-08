import Foundation

public struct SessionEvent: Codable, Sendable {
    public let at: Date
    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.at = Date()
        self.level = level
        self.message = message
    }
}

public struct MonitorDiagnostics: Codable, Sendable {
    public var outputDeviceUID: String?
    public var outputDeviceName: String?
    public var outputSampleRate: Double
    public var microphoneDeviceUID: String?
    public var microphoneFormat: String?
    public var aecEnabled: Bool
    public var aecError: String?
    public var engineRunning: Bool
    public var warnings: [String]
    public var monitorRingOverflows: UInt64
    public var monitorUnderrunFrames: UInt64

    public init(_ status: MonitorStatus, overflows: UInt64, underruns: UInt64) {
        outputDeviceUID = status.outputDeviceUID
        outputDeviceName = status.outputDeviceName
        outputSampleRate = status.outputSampleRate
        microphoneDeviceUID = status.microphoneDeviceUID
        microphoneFormat = status.microphoneFormat
        aecEnabled = status.aecEnabled
        aecError = status.aecError
        engineRunning = status.engineRunning
        warnings = status.warnings
        monitorRingOverflows = overflows
        monitorUnderrunFrames = underruns
    }
}

public struct RemoteDiagnostics: Codable, Sendable {
    public var callbacks: UInt64
    public var frames: UInt64
    public var droppedBlocks: UInt64
    public var silentFrames: UInt64
    public var channelRMS: [Float]
    public var channelPeak: [Float]
    public var monitorPushDroppedFrames: UInt64
    public var wavFrames: UInt64
    public var captureFormat: String

    public init(_ stats: RemoteRecorderStats) {
        callbacks = stats.callbacks
        frames = stats.frames
        droppedBlocks = stats.droppedBlocks
        silentFrames = stats.silentFrames
        channelRMS = stats.channelRMS
        channelPeak = stats.channelPeak
        monitorPushDroppedFrames = stats.monitorPushDroppedFrames
        wavFrames = stats.wavFrames
        captureFormat = stats.captureFormat
    }
}

public struct MicDiagnostics: Codable, Sendable {
    public var frames: UInt64
    public var rms: Float
    public var peak: Float
    public var wavFrames: UInt64
    public var conversionError: String?
    public var aecEnabled: Bool

    public init(_ stats: MicRecorderStats) {
        frames = stats.frames
        rms = stats.rms
        peak = stats.peak
        wavFrames = stats.wavFrames
        conversionError = stats.conversionError
        aecEnabled = stats.aecEnabled
    }
}

public struct VideoDiagnostics: Codable, Sendable {
    public var enabled: Bool
    public var width: Int
    public var height: Int
    public var frames: UInt64
    public var lastError: String?
    public var fileBytes: UInt64
}

public struct MuxDiagnostics: Codable, Sendable {
    public var success: Bool
    public var exitCode: Int32
    public var command: [String]
    public var stderrTail: String
    public var durationSeconds: Double?
}

public struct SessionDiagnostics: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var appVersion: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var host: [String: String]
    public var remoteDevice: DeviceSnapshot
    public var tap: TapDescriptor?
    public var monitor: MonitorDiagnostics?
    public var remote: RemoteDiagnostics?
    public var microphone: MicDiagnostics?
    public var video: VideoDiagnostics?
    public var mux: MuxDiagnostics?
    public var mp4Mux: MuxDiagnostics?
    public var outputTakeOver: Bool
    public var events: [SessionEvent]
    public var verdicts: [String]
}

public enum DiagnosticsWriter {
    public static func write(_ diagnostics: SessionDiagnostics, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(diagnostics)
        try data.write(to: url, options: .atomic)
    }
}

public struct SelfTestResult: Sendable {
    public enum Code: String, Sendable {
        case passed
        case noCallbacks
        case allZero
        case partialChannels
        case tapError
    }
    public let code: Code
    public let detail: String
    public let channelRMS: [Float]
    public let channelPeak: [Float]
    public let callbacks: UInt64
    public let frames: UInt64
    public let toneChannelIndices: [Int]

    public var passed: Bool { code == .passed }
}
