import Foundation
import CoreAudio
import CoreGraphics
import Darwin
import os

public struct LiveSnapshot: Sendable {
    public var state: RecorderState = .idle
    public var elapsed: TimeInterval = 0
    public var remoteRMS: Float = 0
    public var remotePeak: Float = 0
    public var micRMS: Float = 0
    public var micPeak: Float = 0
    public var channelRMS: [Float] = []
    public var monitorFillFrames: Int = 0
    public var monitorOverflows: UInt64 = 0
    public var monitorUnderruns: UInt64 = 0
    public var remoteCallbacks: UInt64 = 0
    public var warnings: [String] = []
    public var lastError: String?
}

public struct SessionFiles: Sendable {
    public let directory: URL
    public let video: URL
    public let remoteWAV: URL
    public let micWAV: URL
    public let mkv: URL
    public let mp4: URL
    public let diagnostics: URL
}

public enum RecorderEngineError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case selfTestFailed(SelfTestResult)
    case alreadyRecording
    case notRecording
    case noRemoteBlocks

    public var description: String {
        switch self {
        case let .invalidConfiguration(message): return message
        case let .selfTestFailed(result):
            return "采集自检失败（\(result.code.rawValue)）：\(result.detail)"
        case .alreadyRecording: return "已经在录制中"
        case .notRecording: return "当前没有录制会话"
        case .noRemoteBlocks: return "未收到远端音频数据块"
        }
    }
}

/// Orchestrates one recording session. All public mutation happens on the
/// caller's thread; audio callbacks only touch SPSC rings.
public final class RecorderEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "com.mdxz.facetime.recorder", category: "session")
    private let lock = NSLock()
    private let router = SystemOutputRouter()

    private var configuration: RecorderConfiguration?
    private var files: SessionFiles?
    private var tap: DeviceTapCapture?
    private var keepAlive: SilentKeepAlive?
    private var systemAudio: SystemAudioRecorder?
    private var processTap: ProcessTapCapture?
    private var monitor: AUHALMonitor?
    private var micInput: DirectInputCapture?
    private var remote: RemoteAudioRecorder?
    private var mic: MicCaptureRecorder?
    private var screen: ScreenRecorder?
    private var events: [SessionEvent] = []
    private var stateValue: RecorderState = .idle
    private var lastErrorValue: String?
    private var startedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBeganAt: Date?
    private var videoStartHostTime: UInt64 = 0
    private var micStartHostTime: UInt64 = 0
    private var remoteFirstHostTime: UInt64 = 0
    private var didTakeOverOutput = false
    private var remoteDeviceInfo: AudioDeviceInfo?
    private var tapDescriptorValue: TapDescriptor?
    private var remoteTapWatcher: DispatchSourceTimer?
    private let remoteTapQueue = DispatchQueue(label: "com.mdxz.facetime.recorder.tap-watch")
    private var audioWatchdog: DispatchSourceTimer?
    private let audioWatchQueue = DispatchQueue(label: "com.mdxz.facetime.recorder.audio-watch")
    private var remoteStallTicks = 0
    private var micStallTicks = 0
    private var lastRemoteFrames: UInt64 = 0
    private var lastMicFrames: UInt64 = 0
    private var lastRemoteAdvance = Date()
    private var lastMicAdvance = Date()
    private var audioRebuilds = 0

    public init() {}

    public var state: RecorderState {
        lock.lock(); defer { lock.unlock() }
        return stateValue
    }

    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastErrorValue
    }

    public var sessionDirectory: URL? {
        lock.lock(); defer { lock.unlock() }
        return files?.directory
    }

    public func recoverStaleOutputLease() {
        router.recoverStaleLease()
    }

    public func start(configuration: RecorderConfiguration,
                      performSelfTest: Bool = true) throws -> SessionFiles {
        lock.lock()
        guard stateValue == .idle || stateValue == .finished || stateValue == .failed else {
            lock.unlock()
            throw RecorderEngineError.alreadyRecording
        }
        stateValue = .preparing
        lastErrorValue = nil
        events = []
        lock.unlock()

        do {
            try validate(configuration)
            let directory = try makeWorkingDirectory(base: configuration.outputDirectory)
            let finalVideo = Self.uniqueVideoURL(in: configuration.outputDirectory)
            let sessionFiles = SessionFiles(
                directory: directory,
                video: directory.appendingPathComponent("screen.mov"),
                remoteWAV: directory.appendingPathComponent("remote.wav"),
                micWAV: directory.appendingPathComponent("microphone.wav"),
                mkv: directory.appendingPathComponent("FaceTime.mkv"),
                mp4: finalVideo,
                diagnostics: directory.appendingPathComponent("diagnostics.json"))
            lock.lock(); files = sessionFiles; self.configuration = configuration; lock.unlock()
            addEvent("working directory: \(directory.path)")
            addEvent("output file: \(finalVideo.path)")
            progress("session directory created")

            // Remote audio always comes from the avconferenced process tap.
            // ScreenCaptureKit system audio deliberately excludes call audio
            // (`excludedCallingClientAudio`), so it can only ever record the
            // ringback tone, never the person on the other end.
            let avConferencePID = configuration.recordRemote
                ? ProcessTapCapture.findProcess(named: "avconferenced") : nil

            var micInput: DirectInputCapture?
            var micFormatValue: AudioStreamBasicDescription?
            if configuration.recordMicrophone, let microphoneUID = configuration.microphoneUID {
                let input = DirectInputCapture()
                micFormatValue = try input.start(deviceUID: microphoneUID)
                self.micInput = input
                micInput = input
                micStartHostTime = mach_absolute_time()
                addEvent("麦克风输入：\(microphoneUID)")
            }
            progress("microphone step done")

            if configuration.recordRemote {
                if let avConferencePID {
                    try attachRemoteTap(processID: avConferencePID,
                                        sessionFiles: sessionFiles)
                } else {
                    // FaceTime has not started yet (no call placed). Wait for
                    // avconferenced and attach the tap the moment it appears;
                    // recording a source that can never contain call audio is
                    // worse than starting the remote track a little late.
                    remoteFirstHostTime = mach_absolute_time()
                    addEvent("FaceTime 未运行：等待通话建立后自动接入对方声音", level: "warning")
                    startRemoteTapWatcher(sessionFiles: sessionFiles)
                }
            } else {
                remoteFirstHostTime = mach_absolute_time()
            }

            // Start video only after the audio path is ready, so the exported
            // file does not begin with several seconds of silent video while
            // the tap aggregate is still starting.
            if configuration.recordVideo {
                let recorder = ScreenRecorder()
                // V1 records FaceTime itself, not the whole desktop. Prefer an
                // explicit window, then auto-detect the FaceTime window; fall
                // back to the chosen/main display only if FaceTime is closed.
                let autoWindowID = configuration.captureWindowID
                    ?? ScreenRecorder.faceTimeWindowID().map { UInt32($0) }
                let windowID: CGWindowID? = autoWindowID.map { UInt32($0) }
                let displayID: CGDirectDisplayID? = windowID == nil
                    ? (configuration.captureDisplayID ?? CGMainDisplayID())
                    : nil
                try recorder.start(displayID: displayID,
                                   windowID: windowID,
                                   outputURL: sessionFiles.video)
                screen = recorder
                videoStartHostTime = mach_absolute_time()
                addEvent(windowID == nil
                         ? "未找到 FaceTime 窗口，已录制主显示器 \(recorder.width)x\(recorder.height)"
                         : "正在录制 FaceTime 窗口 \(recorder.width)x\(recorder.height)")
            } else {
                videoStartHostTime = mach_absolute_time()
            }
            progress("video step done")

            if configuration.recordMicrophone, let micInput, let micFormatValue {
                let mic = try MicCaptureRecorder(input: micInput,
                                                 wavURL: sessionFiles.micWAV,
                                                 format: micFormatValue)
                self.mic = mic
                mic.start()
            }

            lock.lock()
            startedAt = Date()
            pausedAccumulated = 0
            pauseBeganAt = nil
            stateValue = .recording
            lock.unlock()
            startAudioWatchdog(sessionFiles: sessionFiles)
            addEvent("录制开始")
            return sessionFiles
        } catch {
            addEvent("启动失败：\(error)", level: "error")
            writeFailureLog(error)
            teardown(failed: true)
            throw error
        }
    }

    /// Creates the process tap for FaceTime's call audio and starts writing the
    /// remote track. Also used for late attachment when the call starts after
    /// the recording did.
    private func attachRemoteTap(processID: pid_t, sessionFiles: SessionFiles,
                                 append: Bool = false,
                                 padSeconds: Double = 0) throws {
        let tap = ProcessTapCapture()
        let descriptor = try tap.start(processID: processID)
        let remote = try RemoteAudioRecorder(source: tap,
                                             descriptor: descriptor,
                                             labels: ["FL", "FR"],
                                             mode: .stereoDownmix,
                                             wavURL: sessionFiles.remoteWAV,
                                             monitorRing: nil,
                                             append: append)
        if padSeconds > 0 { remote.padSilence(seconds: padSeconds) }
        lock.lock()
        let allowed = stateValue == .preparing || stateValue == .recording || stateValue == .paused
        guard allowed else {
            lock.unlock()
            tap.stop()
            return
        }
        self.processTap = tap
        self.tapDescriptorValue = descriptor
        self.remote = remote
        let wasPaused = stateValue == .paused
        lock.unlock()
        if wasPaused { remote.setPaused(true) }
        remote.start()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if remote.snapshot.frames > 0 { break }
            usleep(20_000)
        }
        let first = remote.snapshot.firstHostTime
        lock.lock()
        remoteFirstHostTime = first > 0 ? first : mach_absolute_time()
        lock.unlock()
        addEvent("远端音频：avconferenced 进程 tap (pid \(processID))")
    }

    /// Polls for avconferenced so a recording started before the call still
    /// gets the other party once FaceTime comes up.
    private func startRemoteTapWatcher(sessionFiles: SessionFiles) {
        stopRemoteTapWatcher()
        let timer = DispatchSource.makeTimerSource(queue: remoteTapQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.stateValue == .recording || self.stateValue == .paused
            let alreadyAttached = self.remote != nil
            self.lock.unlock()
            guard active, !alreadyAttached else {
                timer.cancel()
                return
            }
            guard let pid = ProcessTapCapture.findProcess(named: "avconferenced") else { return }
            do {
                try self.attachRemoteTap(processID: pid, sessionFiles: sessionFiles)
                timer.cancel()
            } catch {
                // FaceTime may still be starting up; retry on the next tick.
            }
        }
        lock.lock(); remoteTapWatcher = timer; lock.unlock()
        timer.resume()
    }

    private func stopRemoteTapWatcher() {
        lock.lock()
        let timer = remoteTapWatcher
        remoteTapWatcher = nil
        lock.unlock()
        timer?.cancel()
    }

    // MARK: - Capture watchdog

    /// FaceTime activates its voice-processing graph the moment a call
    /// connects. That tears down the shared devices, so both the process tap
    /// and the HAL microphone stop delivering. Watch delivery and rebuild the
    /// affected capture, appending to the same WAV so the track stays one file
    /// and keeps its timeline.
    private func startAudioWatchdog(sessionFiles: SessionFiles) {
        stopAudioWatchdog()
        remoteStallTicks = 0
        micStallTicks = 0
        lastRemoteFrames = 0
        lastMicFrames = 0
        lastRemoteAdvance = Date()
        lastMicAdvance = Date()
        audioRebuilds = 0
        let timer = DispatchSource.makeTimerSource(queue: audioWatchQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let state = self.stateValue
            let remoteRec = self.remote
            let micRec = self.mic
            self.lock.unlock()
            guard state == .recording else {
                if state == .paused {
                    self.remoteStallTicks = 0
                    self.micStallTicks = 0
                }
                return
            }
            if let remoteRec {
                let frames = remoteRec.snapshot.frames
                if frames > self.lastRemoteFrames {
                    self.lastRemoteFrames = frames
                    self.lastRemoteAdvance = Date()
                    self.remoteStallTicks = 0
                } else {
                    self.remoteStallTicks += 1
                    if self.remoteStallTicks >= 5 {
                        self.rebuildRemoteGraph(sessionFiles: sessionFiles)
                    }
                }
            }
            if let micRec {
                let frames = micRec.snapshot.frames
                if frames > self.lastMicFrames {
                    self.lastMicFrames = frames
                    self.lastMicAdvance = Date()
                    self.micStallTicks = 0
                } else {
                    self.micStallTicks += 1
                    if self.micStallTicks >= 5 {
                        self.rebuildMicrophoneGraph(sessionFiles: sessionFiles)
                    }
                }
            }
        }
        lock.lock(); audioWatchdog = timer; lock.unlock()
        timer.resume()
    }

    private func stopAudioWatchdog() {
        lock.lock()
        let timer = audioWatchdog
        audioWatchdog = nil
        lock.unlock()
        timer?.cancel()
    }

    private func rebuildRemoteGraph(sessionFiles: SessionFiles) {
        remoteStallTicks = 0
        audioRebuilds += 1
        guard audioRebuilds <= 30 else { return }
        let pad = Date().timeIntervalSince(lastRemoteAdvance)
        lock.lock()
        let oldRecorder = remote
        let oldTap = processTap
        remote = nil
        processTap = nil
        lock.unlock()
        _ = oldRecorder?.stop()
        oldTap?.stop()
        lastRemoteFrames = 0
        lastRemoteAdvance = Date()
        guard let pid = ProcessTapCapture.findProcess(named: "avconferenced") else { return }
        do {
            try attachRemoteTap(processID: pid,
                                sessionFiles: sessionFiles,
                                append: true,
                                padSeconds: pad)
            addEvent("对方声音：检测到中断，已重建采集并继续", level: "warning")
        } catch {
            addEvent("对方声音重建失败：\(error)", level: "error")
        }
    }

    private func rebuildMicrophoneGraph(sessionFiles: SessionFiles) {
        micStallTicks = 0
        audioRebuilds += 1
        guard audioRebuilds <= 30 else { return }
        let pad = Date().timeIntervalSince(lastMicAdvance)
        lock.lock()
        let configuration = self.configuration
        let oldRecorder = mic
        let oldInput = micInput
        mic = nil
        micInput = nil
        lock.unlock()
        _ = oldRecorder?.stop()
        oldInput?.stop()
        lastMicFrames = 0
        lastMicAdvance = Date()
        guard let uid = configuration?.microphoneUID else { return }
        do {
            let input = DirectInputCapture()
            let format = try input.start(deviceUID: uid)
            let recorder = try MicCaptureRecorder(input: input,
                                                  wavURL: sessionFiles.micWAV,
                                                  format: format,
                                                  append: true)
            if pad > 0 { recorder.padSilence(seconds: pad) }
            lock.lock(); micInput = input; mic = recorder; lock.unlock()
            recorder.start()
            addEvent("麦克风：检测到中断，已重启采集并继续", level: "warning")
        } catch {
            addEvent("麦克风重启失败：\(error)", level: "error")
        }
    }

    /// Freezes every track (video frames, remote WAV, mic WAV) without tearing
    /// down capture. Monitoring and the process tap keep running so the call
    /// stays audible while paused.
    public func pause() {
        lock.lock()
        guard stateValue == .recording else { lock.unlock(); return }
        stateValue = .paused
        pauseBeganAt = Date()
        lock.unlock()
        screen?.setPaused(true)
        remote?.setPaused(true)
        mic?.setPaused(true)
        addEvent("录制已暂停")
    }

    public func resume() {
        lock.lock()
        guard stateValue == .paused else { lock.unlock(); return }
        if let began = pauseBeganAt {
            pausedAccumulated += Date().timeIntervalSince(began)
        }
        pauseBeganAt = nil
        stateValue = .recording
        lock.unlock()
        screen?.setPaused(false)
        remote?.setPaused(false)
        mic?.setPaused(false)
        addEvent("继续录制")
    }

    public func stop() -> RecordingResult? {
        lock.lock()
        guard stateValue == .recording || stateValue == .paused else {
            lock.unlock()
            return nil
        }
        if stateValue == .paused {
            // Freeze the paused interval so duration math stays correct.
            if let began = pauseBeganAt {
                pausedAccumulated += Date().timeIntervalSince(began)
            }
            pauseBeganAt = nil
        }
        stateValue = .stopping
        let started = startedAt ?? Date()
        let sessionFiles = files
        lock.unlock()
        addEvent("正在停止")

        stopRemoteTapWatcher()
        stopAudioWatchdog()
        screen?.setPaused(false)
        remote?.setPaused(false)
        mic?.setPaused(false)
        screen?.stop()
        let micStats = mic?.stop()
        let remoteStats: RemoteRecorderStats?
        if let systemAudio {
            remoteStats = systemAudio.stop()
            self.systemAudio = nil
        } else {
            remoteStats = remote?.stop()
        }
        monitor?.stop()
        micInput?.stop()
        tap?.stop()
        processTap?.stop()
        processTap = nil
        keepAlive?.stop()
        keepAlive = nil
        if didTakeOverOutput {
            do { try router.restoreIfNeeded() }
            catch { addEvent("恢复默认输出失败：\(error)", level: "error") }
        }

        guard let sessionFiles, let configuration else {
            lock.lock(); stateValue = .failed; lock.unlock()
            return nil
        }

        let remoteOffset = hostDeltaSeconds(from: videoStartHostTime, to: remoteFirstHostTime)
        let micOffset = hostDeltaSeconds(from: videoStartHostTime, to: micStartHostTime)
        lock.lock(); stateValue = .muxing; lock.unlock()
        addEvent("封装中（remote offset \(String(format: "%.3f", remoteOffset)) s）")

        var mp4Result: MuxResult?
        let remoteExists = FileManager.default.fileExists(atPath: sessionFiles.remoteWAV.path)
        let micExists = configuration.recordMicrophone &&
            FileManager.default.fileExists(atPath: sessionFiles.micWAV.path)
        if remoteExists || micExists {
            let videoAttributes = try? FileManager.default.attributesOfItem(
                atPath: sessionFiles.video.path)
            let videoBytes = (videoAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let videoURL = configuration.recordVideo && videoBytes > 1_024
                ? sessionFiles.video : nil
            let remoteURL = remoteExists ? sessionFiles.remoteWAV : nil
            let micURL = micExists ? sessionFiles.micWAV : nil
            do {
                // One MP4, three audio tracks: mix (default) + Remote + Mic.
                mp4Result = try MediaMuxer.mux(video: videoURL,
                                               remoteWAV: remoteURL,
                                               micWAV: micURL,
                                               output: sessionFiles.mp4,
                                               container: .mp4,
                                               remoteOffset: remoteOffset,
                                               micOffset: micOffset)
                if mp4Result?.success == false, videoURL != nil {
                    // A broken video must not cost the user the audio. Retry
                    // as an audio-only file and report the degradation.
                    addEvent("视频轨不可用，改为导出纯音频文件", level: "warning")
                    mp4Result = try MediaMuxer.mux(video: nil,
                                                   remoteWAV: remoteURL,
                                                   micWAV: micURL,
                                                   output: sessionFiles.mp4,
                                                   container: .mp4,
                                                   remoteOffset: remoteOffset,
                                                   micOffset: micOffset)
                }
                if let mp4Result {
                    addEvent(mp4Result.success ? "视频导出完成（混音 / 对方 / 麦克风）"
                                               : "视频导出失败：\(mp4Result.stderrTail)",
                             level: mp4Result.success ? "info" : "error")
                }
                if mp4Result?.success != true {
                    // Never leave a half-written MP4 in the output folder.
                    try? FileManager.default.removeItem(at: sessionFiles.mp4)
                }
            } catch {
                addEvent("视频导出异常：\(error)", level: "error")
            }
        }

        lock.lock()
        let pausedTotal = pausedAccumulated
        lock.unlock()
        let duration = max(0, Date().timeIntervalSince(started) - pausedTotal)
        let diagnostics = buildDiagnostics(files: sessionFiles,
                                           configuration: configuration,
                                           started: started,
                                           remoteStats: remoteStats,
                                           micStats: micStats,
                                           muxResult: nil,
                                           mp4Result: mp4Result)
        try? DiagnosticsWriter.write(diagnostics, to: sessionFiles.diagnostics)

        // One file per session: once the MP4 is good, the raw screen.mov and
        // WAVs are no longer needed. On failure they stay for recovery.
        if mp4Result?.success == true {
            do {
                try FileManager.default.removeItem(at: sessionFiles.directory)
                addEvent("已清理临时素材，仅保留 \(sessionFiles.mp4.lastPathComponent)")
            } catch {
                addEvent("清理临时素材失败：\(error)", level: "warning")
            }
        }

        // Reset session objects but keep last result paths for the UI.
        tap = nil; processTap = nil; keepAlive = nil; monitor = nil; remote = nil; mic = nil; screen = nil
        self.configuration = nil
        didTakeOverOutput = false
        lock.lock()
        stateValue = .finished
        lock.unlock()
        addEvent("录制结束，时长 \(String(format: "%.1f", duration)) s")

        return RecordingResult(sessionDirectory: sessionFiles.directory,
                               mkvURL: nil,
                               mp4URL: mp4Result?.outputURL,
                               videoURL: configuration.recordVideo ? sessionFiles.video : nil,
                               remoteWAVURL: sessionFiles.remoteWAV,
                               micWAVURL: configuration.recordMicrophone ? sessionFiles.micWAV : nil,
                               diagnosticsURL: sessionFiles.diagnostics,
                               durationSeconds: duration)
    }

    public func snapshot() -> LiveSnapshot {
        lock.lock()
        var snapshot = LiveSnapshot()
        snapshot.state = stateValue
        snapshot.lastError = lastErrorValue
        if let startedAt {
            var elapsed = Date().timeIntervalSince(startedAt) - pausedAccumulated
            if let pauseBeganAt {
                elapsed -= Date().timeIntervalSince(pauseBeganAt)
            }
            snapshot.elapsed = max(0, elapsed)
        } else {
            snapshot.elapsed = 0
        }
        let remote = self.remote
        let systemAudio = self.systemAudio
        let monitor = self.monitor
        let mic = self.mic
        lock.unlock()
        if let systemAudio {
            let stats = systemAudio.snapshot
            snapshot.remoteCallbacks = 0
            snapshot.channelRMS = stats.channelRMS
            if let first = stats.channelRMS.first {
                snapshot.remoteRMS = first
            }
            snapshot.remotePeak = stats.channelPeak.max() ?? 0
        } else if let remote {
            let stats = remote.snapshot
            snapshot.remoteCallbacks = stats.callbacks
            snapshot.channelRMS = stats.channelRMS
            if let first = stats.channelRMS.first {
                snapshot.remoteRMS = stats.channelRMS.count > 1
                    ? max(first, stats.channelRMS[1]) : first
            }
            snapshot.remotePeak = stats.channelPeak.max() ?? 0
        }
        if let mic {
            let stats = mic.snapshot
            snapshot.micRMS = stats.rms
            snapshot.micPeak = stats.peak
        }
        if let monitor {
            snapshot.monitorFillFrames = monitor.fillFrames
            snapshot.monitorOverflows = monitor.overflows
            snapshot.monitorUnderruns = monitor.underrunFrames
            snapshot.warnings = monitor.status.warnings
        }
        return snapshot
    }

    /// Plays an inaudible (sink) tone into the virtual device and verifies the
    /// tap returns non-zero FL/FR. This is the only honest way to distinguish
    /// "permission denied" from "FaceTime is quiet".
    public func runSelfTest(deviceUID: String, seconds: Double) -> SelfTestResult {
        let testTap = DeviceTapCapture()
        let player = TonePlayer()
        var buffer = [Float](repeating: 0, count: 16_384 * 8)
        var rms = [Float](repeating: 0, count: 8)
        var peak = [Float](repeating: 0, count: 8)
        var sums = [Double](repeating: 0, count: 8)
        var frames: UInt64 = 0
        var callbacks: UInt64 = 0
        do {
            let descriptor = try testTap.start(deviceUID: deviceUID)
            try player.start(deviceUID: deviceUID, frequency: 1_000,
                             amplitude: 0.06, duration: seconds + 0.3,
                             sampleRate: descriptor.sampleRate)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let block = try testTap.readBlock(into: &buffer), block.frames > 0 {
                    callbacks += 1
                    frames += UInt64(block.frames)
                    for frame in 0..<block.frames {
                        for channel in 0..<min(block.channels, 8) {
                            let value = block.samples[frame * block.channels + channel]
                            sums[channel] += Double(value * value)
                            peak[channel] = max(peak[channel], abs(value))
                        }
                    }
                } else {
                    usleep(5_000)
                }
            }
            player.stop()
            testTap.stop()
        } catch {
            player.stop()
            testTap.stop()
            return SelfTestResult(code: .tapError, detail: "\(error)",
                                  channelRMS: [], channelPeak: [],
                                  callbacks: callbacks, frames: frames,
                                  toneChannelIndices: [])
        }
        if frames > 0 {
            rms = sums.map { Float(sqrt($0 / Double(frames))) }
        }
        let channels = min(rms.count, 8)
        let loud = (0..<channels).filter { peak[$0] > 0.0005 }
        if callbacks == 0 {
            return SelfTestResult(code: .noCallbacks, detail: "tap 未收到任何回调",
                                  channelRMS: rms, channelPeak: peak,
                                  callbacks: callbacks, frames: frames,
                                  toneChannelIndices: loud)
        }
        if loud.isEmpty {
            return SelfTestResult(code: .allZero,
                                  detail: "回调与帧数正常但 PCM 全为零。最可能是音频录制权限未授予，或虚拟设备当前没有任何输出。",
                                  channelRMS: rms, channelPeak: peak,
                                  callbacks: callbacks, frames: frames,
                                  toneChannelIndices: [])
        }
        if !loud.contains(0) || !loud.contains(1) {
            return SelfTestResult(code: .partialChannels,
                                  detail: "非零信号出现在通道 \(loud)，而不是预期的 FL/FR(0,1)。请检查设备布局。",
                                  channelRMS: rms, channelPeak: peak,
                                  callbacks: callbacks, frames: frames,
                                  toneChannelIndices: loud)
        }
        return SelfTestResult(code: .passed,
                              detail: "FL/FR 收到自检音，RMS \(String(format: "%.4f", rms[0]))。",
                              channelRMS: rms, channelPeak: peak,
                              callbacks: callbacks, frames: frames,
                              toneChannelIndices: loud)
    }

    private func validate(_ configuration: RecorderConfiguration) throws {
        guard configuration.recordRemote || configuration.recordMicrophone else {
            throw RecorderEngineError.invalidConfiguration("至少选择一种声音来源：对方声音或麦克风。")
        }
        guard configuration.recordRemote else {
            remoteDeviceInfo = nil
            if configuration.recordMicrophone, configuration.microphoneUID == nil {
                throw RecorderEngineError.invalidConfiguration("已启用麦克风轨但未选择麦克风")
            }
            return
        }
        guard let device = AudioDeviceCatalog.allDevices().first(where: {
            $0.uid == configuration.remoteDeviceUID
        }) else {
            throw RecorderEngineError.invalidConfiguration("找不到远端虚拟设备 \(configuration.remoteDeviceUID)")
        }
        guard device.outputChannels > 0 else {
            throw RecorderEngineError.invalidConfiguration("所选设备没有输出通道")
        }
        if configuration.recordMicrophone, configuration.microphoneUID == nil {
            throw RecorderEngineError.invalidConfiguration("已启用麦克风轨但未选择麦克风")
        }
        if configuration.recordVideo, configuration.captureDisplayID == nil,
           configuration.captureWindowID == nil {
            throw RecorderEngineError.invalidConfiguration("已启用视频但未选择显示器或窗口")
        }
        remoteDeviceInfo = device
    }

    /// Monitoring must always land on a physical output. When the system
    /// default has been switched to the virtual sink, falling back to "default"
    /// would silence the call.
    private func resolveMonitorUID(_ requested: String?, remoteUID: String) -> String? {
        func acceptable(_ uid: String) -> Bool {
            guard uid != remoteUID,
                  let info = AudioDeviceCatalog.allDevices().first(where: { $0.uid == uid }) else {
                return false
            }
            return info.outputChannels > 0 && !info.isVirtual
        }
        if let requested, acceptable(requested) { return requested }
        if let current = AudioDeviceCatalog.defaultOutputUID(), acceptable(current) {
            return current
        }
        return AudioDeviceCatalog.allDevices().first {
            acceptable($0.uid) && $0.uid == "BuiltInSpeakerDevice"
        }?.uid ?? AudioDeviceCatalog.allDevices().first {
            acceptable($0.uid)
        }?.uid
    }

    /// Scratch space for the raw tracks. Hidden and removed once the single
    /// deliverable has been exported successfully.
    private func makeWorkingDirectory(base: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = base.appendingPathComponent(".recording-\(formatter.string(from: Date()))",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The one file a session leaves behind: `2026-11-09-FaceTime-1.mp4`.
    /// The number keeps counting up within the same day.
    static func uniqueVideoURL(in base: URL, date: Date = Date()) -> URL {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stem = "\(formatter.string(from: date))-FaceTime"
        let prefix = stem + "-"
        var highest = 0
        if let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".mp4") {
                let number = name.dropFirst(prefix.count).dropLast(4)
                if let value = Int(number) {
                    highest = max(highest, value)
                }
            }
        }
        return base.appendingPathComponent("\(stem)-\(highest + 1).mp4")
    }

    private func addEvent(_ message: String, level: String = "info") {
        lock.lock()
        events.append(SessionEvent(level: level, message: message))
        if level == "error" { lastErrorValue = message }
        lock.unlock()
        log.info("\(message, privacy: .public)")
    }

    private func progress(_ message: String) {
        lock.lock()
        let directory = files?.directory
        lock.unlock()
        guard let directory else { return }
        let url = directory.appendingPathComponent("session-progress.log")
        let line = "[\(Date())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func teardown(failed: Bool) {
        stopRemoteTapWatcher()
        stopAudioWatchdog()
        screen?.stop()
        _ = mic?.stop()
        _ = remote?.stop()
        _ = systemAudio?.stop()
        systemAudio = nil
        monitor?.stop()
        micInput?.stop()
        tap?.stop()
        processTap?.stop()
        processTap = nil
        if didTakeOverOutput {
            try? router.restoreIfNeeded()
            didTakeOverOutput = false
        }
        screen = nil; mic = nil; remote = nil; monitor = nil; tap = nil; processTap = nil
        lock.lock()
        stateValue = failed ? .failed : .idle
        lock.unlock()
    }

    private func writeFailureLog(_ error: Error) {
        lock.lock()
        let directory = files?.directory
        let lines = events.map { "[\($0.level)] \($0.message)" }
        lock.unlock()
        guard let directory else { return }
        let text = (lines + ["", "ERROR: \(error)"]).joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent("session-error.log"),
                        atomically: true, encoding: .utf8)
    }

    private func buildDiagnostics(files: SessionFiles,
                                  configuration: RecorderConfiguration,
                                  started: Date,
                                  remoteStats: RemoteRecorderStats?,
                                  micStats: MicRecorderStats?,
                                  muxResult: MuxResult?,
                                  mp4Result: MuxResult?) -> SessionDiagnostics {
        lock.lock()
        let snapshot = remoteDeviceInfo.map(DeviceSnapshot.init)
        let tapDescriptor = tapDescriptorValue
        let monitorStatus = monitor?.status
        let monitorOverflows = monitor?.overflows ?? 0
        let monitorUnderruns = monitor?.underrunFrames ?? 0
        let screenFrames = screen?.frameCount ?? 0
        let screenError = screen?.lastError
        let screenWidth = screen?.width ?? 0
        let screenHeight = screen?.height ?? 0
        let eventCopy = events
        let errorCopy = lastErrorValue
        lock.unlock()

        var verdicts: [String] = []
        if let remoteStats {
            if remoteStats.frames == 0 { verdicts.append("远端音轨没有帧") }
            else if remoteStats.silentFrames == remoteStats.frames {
                verdicts.append("远端音轨全为零；检查 TCC 与路由")
            } else {
                verdicts.append("远端音轨含非零 PCM")
            }
        }
        if let micStats, micStats.frames == 0 { verdicts.append("麦克风音轨没有帧") }
        if let screenError { verdicts.append("视频错误：\(screenError)") }
        if let errorCopy { verdicts.append("会话错误：\(errorCopy)") }

        let attributes = try? FileManager.default.attributesOfItem(atPath: files.video.path)
        let videoBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return SessionDiagnostics(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            startedAt: started,
            finishedAt: Date(),
            host: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                   "arch": currentArchitecture()],
            remoteDevice: snapshot ?? DeviceSnapshot(AudioDeviceInfo(
                id: 0, uid: configuration.remoteDeviceUID, name: "unknown",
                modelUID: nil, transport: 0, transportName: "unknown",
                nominalSampleRate: 0, bufferFrameSize: nil,
                deviceLatencyFrames: nil, safetyOffsetFrames: nil,
                inputChannels: 0, outputChannels: 0, inputStreams: [],
                outputStreams: [], preferredOutputChannelLabels: [])),
            tap: tapDescriptor,
            monitor: monitorStatus.map { MonitorDiagnostics($0,
                                                            overflows: monitorOverflows,
                                                            underruns: monitorUnderruns) },
            remote: remoteStats.map(RemoteDiagnostics.init),
            microphone: micStats.map(MicDiagnostics.init),
            video: VideoDiagnostics(enabled: configuration.recordVideo,
                                    width: screenWidth, height: screenHeight,
                                    frames: screenFrames, lastError: screenError,
                                    fileBytes: videoBytes),
            mux: muxResult.map { MuxDiagnostics(success: $0.success,
                                                exitCode: $0.exitCode,
                                                command: $0.command,
                                                stderrTail: $0.stderrTail,
                                                durationSeconds: $0.durationSeconds) },
            mp4Mux: mp4Result.map { MuxDiagnostics(success: $0.success,
                                                   exitCode: $0.exitCode,
                                                   command: $0.command,
                                                   stderrTail: $0.stderrTail,
                                                   durationSeconds: $0.durationSeconds) },
            outputTakeOver: didTakeOverOutput,
            events: eventCopy,
            verdicts: verdicts)
    }

    private func hostDeltaSeconds(from start: UInt64, to end: UInt64) -> Double {
        guard start > 0, end > start else { return 0 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(end - start) * Double(info.numer) / Double(info.denom) / 1e9
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
