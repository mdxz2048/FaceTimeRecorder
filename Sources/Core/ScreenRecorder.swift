import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import AppKit
import os

public struct DisplayOption: Identifiable, Sendable, Hashable {
    public let id: CGDirectDisplayID
    public let name: String
    public let width: Int
    public let height: Int
}

public struct WindowOption: Identifiable, Sendable, Hashable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let bundleID: String?
    public let width: Int
    public let height: Int
}

public enum ScreenRecorderError: Error, CustomStringConvertible {
    case permissionDenied
    case noSuchDisplay
    case noSuchWindow
    case writerSetup(String)
    case streamStart(String)
    case appendFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "屏幕录制权限未授予。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 FaceTime Recorder。"
        case .noSuchDisplay: return "找不到所选显示器"
        case .noSuchWindow: return "找不到所选窗口（可能已关闭）"
        case let .writerSetup(message): return "视频写入器初始化失败：\(message)"
        case let .streamStart(message): return "ScreenCaptureKit 启动失败：\(message)"
        case let .appendFailed(message): return "视频帧写入失败：\(message)"
        }
    }
}

public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "screen")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.mdxz.facetime.recorder.screen")
    private let audioQueue = DispatchQueue(label: "com.mdxz.facetime.recorder.sck-audio")
    private let lock = NSLock()
    private var running = false
    private var firstPresentationTime: CMTime?
    private var sessionStarted = false
    private var paused = false
    private var pausedAccumulated = CMTime.zero
    private var pauseBeganAt: CMTime?
    private var lastPresentationTime: CMTime?
    private(set) public var outputURL: URL?
    private(set) public var frameCount: UInt64 = 0
    private(set) public var lastError: String?
    private(set) public var width: Int = 0
    private(set) public var height: Int = 0
    /// Receives ScreenCaptureKit system-audio sample buffers.
    public var onAudioSample: ((CMSampleBuffer) -> Void)?

    public override init() { super.init() }

    /// Paused frames are dropped and the resumed timeline is pulled back by
    /// the paused interval, so the video and the WAV tracks stay aligned.
    public func setPaused(_ flag: Bool) {
        lock.lock()
        if flag {
            if !paused {
                paused = true
                pauseBeganAt = lastPresentationTime
            }
        } else if paused {
            paused = false
            if let began = pauseBeganAt, let last = lastPresentationTime {
                let delta = CMTimeSubtract(last, began)
                if delta.isValid, delta.seconds > 0 {
                    pausedAccumulated = CMTimeAdd(pausedAccumulated, delta)
                }
            }
            pauseBeganAt = nil
        }
        lock.unlock()
    }

    public static func preflightPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func listDisplays() -> [DisplayOption] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            DisplayOption(id: id,
                          name: id == CGMainDisplayID() ? "主显示器" : "显示器 \(id)",
                          width: CGDisplayPixelsWide(id),
                          height: CGDisplayPixelsHigh(id))
        }
    }

    /// Window list for the picker. Requires Screen Recording permission on
    /// macOS 15+, so callers should treat an empty list as "unknown", not
    /// "FaceTime is not open".
    public static func listWindows() -> [WindowOption] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [WindowOption] = []
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            if let content {
                result = content.windows.compactMap { window in
                    guard window.frame.width >= 160, window.frame.height >= 120 else { return nil }
                    let title = window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "窗口")
                    return WindowOption(id: window.windowID,
                                        title: title,
                                        appName: window.owningApplication?.applicationName ?? "?",
                                        bundleID: window.owningApplication?.bundleIdentifier,
                                        width: Int(window.frame.width),
                                        height: Int(window.frame.height))
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result.sorted { lhs, rhs in
            if lhs.appName == "FaceTime" && rhs.appName != "FaceTime" { return true }
            if rhs.appName == "FaceTime" && lhs.appName != "FaceTime" { return false }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    /// The only window V1 records. Returns nil when FaceTime is not running or
    /// screen-recording permission has not been granted yet.
    public static func faceTimeWindowID() -> CGWindowID? {
        listWindows().first(where: {
            // Never capture ourselves: our own process is also called
            // "FaceTime Recorder", which contains the substring "FaceTime".
            guard $0.bundleID != Bundle.main.bundleIdentifier else { return false }
            guard !$0.appName.localizedCaseInsensitiveContains("Recorder") else { return false }
            if $0.bundleID == "com.apple.FaceTime" { return true }
            // Localized owner names include "FaceTime通话".
            return $0.appName.localizedCaseInsensitiveContains("FaceTime")
        })?.id
    }

    public func start(displayID: CGDirectDisplayID?,
                      windowID: CGWindowID?,
                      outputURL: URL,
                      framesPerSecond: Int = 30,
                      bitRate: Int = 20_000_000) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenRecorderError.permissionDenied
        }

        let semaphore = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        var contentError: Error?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { value, error in
            content = value
            contentError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        guard let content else {
            throw ScreenRecorderError.streamStart(contentError?.localizedDescription ?? "no shareable content")
        }

        let filter: SCContentFilter
        if let windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecorderError.noSuchWindow
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let target = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
            guard let target else { throw ScreenRecorderError.noSuchDisplay }
            filter = SCContentFilter(display: target, excludingWindows: [])
            width = target.width
            height = target.height
        }
        if width == 0 || height == 0 {
            width = Int(filter.contentRect.width)
            height = Int(filter.contentRect.height)
        }
        // Window frames are in points. Capture at native Retina pixels so the
        // recording is not downscaled to half resolution.
        if windowID != nil {
            let windowFrame = content.windows.first(where: { $0.windowID == windowID })?.frame
            let scale = windowFrame.flatMap { frame in
                NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.backingScaleFactor
            } ?? NSScreen.main?.backingScaleFactor ?? 2
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }
        width = max(2, width - (width % 2))
        height = max(2, height - (height % 2))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        configuration.scalesToFit = false
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        } catch {
            throw ScreenRecorderError.streamStart(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerSetup(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw ScreenRecorderError.writerSetup("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecorderError.writerSetup(writer.error?.localizedDescription ?? "startWriting failed")
        }
        // Session starts on the first real frame; see stream(_:didOutputSampleBuffer:).

        self.writer = writer
        self.input = input
        self.stream = stream
        self.outputURL = outputURL
        self.firstPresentationTime = nil
        self.sessionStarted = false
        self.frameCount = 0
        self.lastError = nil

        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        stream.startCapture { error in
            startError = error
            startSemaphore.signal()
        }
        _ = startSemaphore.wait(timeout: .now() + 10)
        if let startError {
            input.markAsFinished()
            writer.cancelWriting()
            self.writer = nil
            self.input = nil
            self.stream = nil
            throw ScreenRecorderError.streamStart(startError.localizedDescription)
        }
        running = true
        log.info("screen capture started \(self.width)x\(self.height) url=\(outputURL.lastPathComponent, privacy: .public)")
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let stream = self.stream
        let input = self.input
        let writer = self.writer
        lock.unlock()

        if let stream {
            let semaphore = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 10)
        }
        input?.markAsFinished()
        if let writer, writer.status == .writing {
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 30)
        }
        lock.lock()
        self.stream = nil
        self.input = nil
        self.writer = nil
        lock.unlock()
    }

    deinit { stop() }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            onAudioSample?(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid else { return }
        // ScreenCaptureKit also emits idle/blank/minimized frames. Appending
        // those to AVAssetWriter can put it into a failed state.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                     createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let frameStatus = SCFrameStatus(rawValue: rawStatus),
           frameStatus != .complete {
            return
        }
        lock.lock()
        let input = self.input
        let writer = self.writer
        let running = self.running
        let paused = self.paused
        let offset = self.pausedAccumulated
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastPresentationTime = presentationTime
        if !sessionStarted {
            writer?.startSession(atSourceTime: presentationTime)
            sessionStarted = true
            firstPresentationTime = presentationTime
        }
        lock.unlock()
        guard running, !paused, let input, let writer, input.isReadyForMoreMediaData else { return }
        if writer.status != .writing {
            lastError = writer.error?.localizedDescription
            return
        }
        let buffer = Self.retimed(sampleBuffer, by: offset)
        guard let buffer else { return }
        if input.append(buffer) {
            lock.lock(); frameCount += 1; lock.unlock()
        } else if let error = writer.error {
            lastError = error.localizedDescription
            log.error("append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.seconds > 0 else { return sampleBuffer }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: CMTimeSubtract(pts, offset),
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error.localizedDescription
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
    }
}
