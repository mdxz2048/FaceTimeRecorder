import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Darwin
import Foundation

// MARK: - UI state

enum RecorderUIState: String {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case muxing
    case finished
    case failed

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .preparing: return "准备中…"
        case .recording: return "录制中"
        case .paused: return "已暂停"
        case .stopping: return "正在收尾…"
        case .muxing: return "封装中…"
        case .finished: return "已完成"
        case .failed: return "失败"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .paused, .stopping, .muxing:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }
}

enum CaptureSourceMode: String, Codable, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: return "整个显示器"
        case .window: return "单个窗口"
        }
    }
}

enum SystemSettingsDestination: String, Sendable {
    case microphone
    case screenCapture
    case audioCapture
    case sound
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var remoteDeviceUID: String = ""
    var microphoneUID: String?
    var monitorOutputUID: String?
    var captureMode: CaptureSourceMode = .display
    var captureDisplayID: UInt32?
    var captureWindowID: UInt32?
    var recordVideo: Bool = true
    var recordMicrophone: Bool = true
    var monitorEnabled: Bool = true
    var monitorVolume: Double = 0.9
    // V1 default: raw mic. Apple VPIO is available in Advanced, but on this
    // machine it can starve the device-tap aggregate; do not enable by default
    // until the real-device AEC/tap coexistence test passes.
    var echoCancellation: EchoCancellationMode = .off
    var takeOverSystemOutput: Bool = false
}

// MARK: - Failures

enum FailureAction: String, Identifiable, Sendable {
    case openMicrophoneSettings
    case openScreenSettings
    case openAudioCaptureSettings
    case openSoundSettings
    case retry
    case showInFinder
    case copyLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openMicrophoneSettings: return "打开麦克风设置"
        case .openScreenSettings: return "打开屏幕录制设置"
        case .openAudioCaptureSettings: return "打开系统音频录制设置"
        case .openSoundSettings: return "打开声音设置"
        case .retry: return "重试"
        case .showInFinder: return "在 Finder 中显示"
        case .copyLog: return "复制日志"
        }
    }
}

struct AppFailure: Identifiable, Sendable {
    let id = UUID()
    let code: String
    let title: String
    let detail: String
    let actions: [FailureAction]
    let diagnosticURL: URL?
    let sessionDirectory: URL?
}

private enum StartOutcome: Sendable {
    case success(SessionFiles)
    case failure(AppFailure)
}

struct SelfTestOutcome: Sendable {
    let passed: Bool
    let title: String
    let detail: String
    let code: String
    let result: SelfTestResult?
}

// MARK: - Self-test evaluation

struct SelfTestEvaluation: Sendable {
    let passed: Bool
    let title: String
    let detail: String
    let code: String
}

enum SelfTestEvaluator {
    /// The Core self-test is deliberately loose (non-zero FL/FR). The app
    /// applies the more explicit product thresholds before it allows a session
    /// to start.
    static let minimumFrames: UInt64 = 24_000
    static let minimumRMS: Float = 0.005

    static func evaluate(_ result: SelfTestResult) -> SelfTestEvaluation {
        let counts = "callbacks=\(result.callbacks), frames=\(result.frames)"
        let channelText = result.channelRMS.enumerated().prefix(8).map {
            String(format: "ch%d=%.4f", $0.offset, Double($0.element))
        }
        .joined(separator: ", ")
        let allCounts = channelText.isEmpty ? counts : "\(counts), \(channelText)"

        switch result.code {
        case .passed:
            let front = Array(result.channelRMS.prefix(2))
            let maxFront = front.max() ?? 0
            if result.frames < minimumFrames {
                return SelfTestEvaluation(
                    passed: false,
                    title: "自检帧数不足",
                    detail: "1 秒内只收到 \(result.frames) 帧（期望 ≥ \(minimumFrames)）。设备可能被占用或时钟不稳定。\(allCounts)",
                    code: "self_test_frame_starved")
            }
            if maxFront < minimumRMS {
                return SelfTestEvaluation(
                    passed: false,
                    title: "自检音过弱",
                    detail: String(format: "FL/FR 最大 RMS %.5f 低于阈值 %.3f。请检查系统音频录制权限、路由和设备状态。%@",
                                   maxFront, minimumRMS, allCounts),
                    code: "self_test_silent")
            }
            return SelfTestEvaluation(
                passed: true,
                title: "自检通过",
                detail: String(format: "FL/FR 收到 1 秒 1 kHz 低电平测试音（max RMS %.4f）。这只证明远端采集链路可读；FaceTime 音频仍需真人通话验证。%@",
                               maxFront, allCounts),
                code: "self_test_passed")
        case .noCallbacks:
            return SelfTestEvaluation(
                passed: false,
                title: "自检未收到回调",
                detail: "1 秒内 tap 没有收到任何音频回调。请检查聚合设备/时钟设备是否可用，然后重试。\(allCounts)",
                code: "self_test_no_callbacks")
        case .allZero:
            return SelfTestEvaluation(
                passed: false,
                title: "自检读到全零 PCM",
                detail: "回调与帧数正常，但所有样本为零。通常是系统音频录制权限未授予，或没有任何声音路由到 HomePod Flow。\(allCounts)",
                code: "permission_audio_capture_denied_or_silent")
        case .partialChannels:
            return SelfTestEvaluation(
                passed: false,
                title: "自检信号不在 FL/FR",
                detail: "\(result.detail) \(allCounts)",
                code: "channel_map_mismatch")
        case .tapError:
            return SelfTestEvaluation(
                passed: false,
                title: "无法创建音频采集",
                detail: "\(result.detail) \(allCounts)",
                code: "tap_create_failed")
        }
    }
}

// MARK: - Error mapping

enum ErrorMapper {
    static func map(_ error: Error, sessionDirectory: URL?) -> AppFailure {
        if let error = error as? RecorderEngineError {
            return mapEngine(error, sessionDirectory: sessionDirectory)
        }
        if let error = error as? CaptureError {
            return mapCapture(error, sessionDirectory: sessionDirectory)
        }
        if let error = error as? MonitorError {
            return mapMonitor(error, sessionDirectory: sessionDirectory)
        }
        if let error = error as? ScreenRecorderError {
            return mapScreen(error, sessionDirectory: sessionDirectory)
        }
        if let error = error as? CoreAudioError {
            return mapCoreAudio(error, sessionDirectory: sessionDirectory)
        }
        if let error = error as? TonePlayerError {
            return make(code: "self_test_tone_failed",
                        title: "自检测试音播放失败",
                        detail: "\(error)。请确认虚拟设备可用、没有被其他进程独占，然后重试。",
                        actions: [.openAudioCaptureSettings, .retry],
                        sessionDirectory: sessionDirectory)
        }
        if let error = error as? MediaMuxerError {
            return make(code: "mux_tool_missing",
                        title: "封装工具不可用",
                        detail: "\(error)",
                        actions: [.retry],
                        sessionDirectory: sessionDirectory)
        }
        if let error = error as? OutputRouterError {
            return make(code: "output_router_failed",
                        title: "系统输出接管/恢复失败",
                        detail: "\(error)。请检查当前系统输出，必要时手动选择物理输出设备。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        }
        return make(code: "unknown",
                    title: "操作失败",
                    detail: "\(error)\n请重试；若持续失败，请查看诊断文件。",
                    actions: [.retry],
                    sessionDirectory: sessionDirectory)
    }

    static func selfTestFailure(_ evaluation: SelfTestEvaluation,
                                result: SelfTestResult?,
                                sessionDirectory: URL?) -> AppFailure {
        var actions: [FailureAction] = [.retry]
        if let code = result?.code {
            switch code {
            case .allZero, .tapError, .partialChannels:
                actions.insert(.openAudioCaptureSettings, at: 0)
            case .noCallbacks:
                actions.insert(.openSoundSettings, at: 0)
                actions.insert(.openAudioCaptureSettings, at: 0)
            case .passed:
                actions.insert(.openAudioCaptureSettings, at: 0)
            }
        }
        return make(code: evaluation.code,
                    title: evaluation.title,
                    detail: evaluation.detail,
                    actions: actions,
                    sessionDirectory: sessionDirectory)
    }

    static func genericFailure(code: String,
                               title: String,
                               detail: String,
                               sessionDirectory: URL?) -> AppFailure {
        make(code: code, title: title, detail: detail,
             actions: [.retry], sessionDirectory: sessionDirectory)
    }

    // MARK: Specific mappings

    private static func mapEngine(_ error: RecorderEngineError,
                                  sessionDirectory: URL?) -> AppFailure {
        switch error {
        case .invalidConfiguration(let message):
            return make(code: "invalid_configuration",
                        title: "配置不完整",
                        detail: "\(message)\n请检查远端设备、麦克风和画面源选择后重试。",
                        actions: [.retry],
                        sessionDirectory: sessionDirectory)
        case .selfTestFailed(let result):
            return selfTestFailure(SelfTestEvaluator.evaluate(result),
                                   result: result,
                                   sessionDirectory: sessionDirectory)
        case .alreadyRecording:
            return make(code: "already_recording",
                        title: "已经在录制中",
                        detail: "当前 App 已有一个录制会话。请先停止并保存，再开始新的录制。",
                        actions: [],
                        sessionDirectory: sessionDirectory)
        case .notRecording:
            return make(code: "not_recording",
                        title: "当前没有录制会话",
                        detail: "停止请求没有找到处于录制状态的会话。请查看日志并重试。",
                        actions: [.retry],
                        sessionDirectory: sessionDirectory)
        case .noRemoteBlocks:
            return make(code: "no_remote_blocks",
                        title: "远端音频没有数据块",
                        detail: "tap 已启动，但启动阶段没有收到音频块。请确认 FaceTime 有声音、系统输出已指向 HomePod Flow，并检查系统音频录制权限。",
                        actions: [.openAudioCaptureSettings, .openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        }
    }

    private static func mapCapture(_ error: CaptureError,
                                   sessionDirectory: URL?) -> AppFailure {
        switch error {
        case .alreadyRunning:
            return make(code: "capture_already_running",
                        title: "采集已在运行",
                        detail: "上一个采集实例尚未释放。请停止录制或重启 App 后重试。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .notRunning:
            return make(code: "capture_not_running",
                        title: "采集没有运行",
                        detail: "读取音频时采集实例已停止。请重新开始录制。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .noOutputDevice:
            return make(code: "device_missing",
                        title: "没有可用的输出设备",
                        detail: "找不到能作为采集时钟的输出设备。请确认扬声器/耳机可用后重试。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .unsupportedFormat(let detail):
            return make(code: "format_unsupported",
                        title: "设备音频格式不受支持",
                        detail: "\(detail)\nHomePod Flow 应为 8ch / 48 kHz / Float32 packed。请检查设备与驱动。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .noIndependentClock:
            return make(code: "aggregate_clock_missing",
                        title: "找不到独立时钟设备",
                        detail: "tap 的聚合设备不能使用虚拟设备自身作为时钟。请选择一个可用的物理输出设备后重试。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .tapCreationFailed(let status):
            return make(code: "tap_create_failed",
                        title: "无法创建系统音频采集",
                        detail: "AudioHardwareCreateProcessTap 失败：\(status)（\(CoreAudioError.fourCC(status))）。通常是系统音频录制权限未授予，或 tap 被系统拒绝。",
                        actions: [.openAudioCaptureSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .aggregateCreationFailed(let status):
            return make(code: "aggregate_create_failed",
                        title: "无法创建采集聚合设备",
                        detail: "AudioHardwareCreateAggregateDevice 失败：\(status)（\(CoreAudioError.fourCC(status))）。请检查时钟设备/监听输出是否可用。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .ioProcFailed(let status):
            return make(code: "io_proc_failed",
                        title: "无法启动采集回调",
                        detail: "AudioDeviceCreateIOProcID 失败：\(status)（\(CoreAudioError.fourCC(status))）。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .startFailed(let status):
            return make(code: "capture_start_failed",
                        title: "采集启动失败",
                        detail: "AudioDeviceStart 失败：\(status)（\(CoreAudioError.fourCC(status))）。设备可能被占用或时钟不可用。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .ringAllocationFailed:
            return make(code: "ring_allocation_failed",
                        title: "采集缓冲分配失败",
                        detail: "内存不足或格式异常。请关闭占用内存的应用后重试。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .ringFault(let code):
            return make(code: "ring_fault",
                        title: "采集缓冲布局异常",
                        detail: "采集回调收到的音频块布局不符合预期（fault \(code)）。请重试并提交诊断文件。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .blockLayout:
            return make(code: "block_layout",
                        title: "音频块布局异常",
                        detail: "采集队列返回了无法识别的音频块布局。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        }
    }

    private static func mapMonitor(_ error: MonitorError,
                                   sessionDirectory: URL?) -> AppFailure {
        switch error {
        case .noMicrophone:
            return make(code: "mic_unavailable",
                        title: "麦克风不可用",
                        detail: "没有可用的麦克风输入节点。请选择其他麦克风、检查系统权限，或关闭麦克风轨后重试。",
                        actions: [.openMicrophoneSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .engineStartFailed(let message):
            return make(code: "monitor_start_failed",
                        title: "监听/麦克风引擎启动失败",
                        detail: "\(message)\n请检查实际监听设备是否被占用、采样率是否可用，或关闭监听后重试。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .ringAllocationFailed:
            return make(code: "monitor_ring_allocation_failed",
                        title: "监听缓冲分配失败",
                        detail: "无法分配监听/麦克风 ring。请重启 App 或关闭其他音频应用。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        }
    }

    private static func mapScreen(_ error: ScreenRecorderError,
                                  sessionDirectory: URL?) -> AppFailure {
        switch error {
        case .permissionDenied:
            return make(code: "permission_screen_denied",
                        title: "屏幕录制权限未授予",
                        detail: "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 FaceTime Recorder；也可以关闭“录制画面”只录声音。",
                        actions: [.openScreenSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .noSuchDisplay:
            return make(code: "video_source_missing",
                        title: "找不到所选显示器",
                        detail: "显示器可能已断开。请刷新画面源后重新选择。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .noSuchWindow:
            return make(code: "video_source_missing",
                        title: "找不到所选窗口",
                        detail: "窗口可能已关闭。请刷新窗口列表后重新选择 FaceTime 窗口。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .writerSetup(let message):
            return make(code: "video_writer_setup_failed",
                        title: "视频写入器初始化失败",
                        detail: "\(message)\n请检查磁盘空间与影片目录权限。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .streamStart(let message):
            return make(code: "screen_stream_failed",
                        title: "ScreenCaptureKit 启动失败",
                        detail: "\(message)\n请确认屏幕录制权限、窗口仍存在，并重试。",
                        actions: [.openScreenSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .appendFailed(let message):
            return make(code: "video_append_failed",
                        title: "视频帧写入失败",
                        detail: "\(message)\n请检查磁盘空间；音频轨可能仍已保存。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        }
    }

    private static func mapCoreAudio(_ error: CoreAudioError,
                                     sessionDirectory: URL?) -> AppFailure {
        switch error {
        case .deviceNotFound(let uid):
            return make(code: "device_missing",
                        title: "找不到音频设备",
                        detail: "设备 UID \(uid) 不存在或已断开。请刷新设备后重新选择。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .osStatus(let operation, let status):
            return make(code: "core_audio_error",
                        title: "Core Audio 操作失败",
                        detail: "\(operation) 返回 OSStatus \(status)（\(CoreAudioError.fourCC(status))）。",
                        actions: [.openSoundSettings, .retry],
                        sessionDirectory: sessionDirectory)
        case .missingProperty(let object, let selector):
            return make(code: "core_audio_property_missing",
                        title: "音频设备属性缺失",
                        detail: "对象 \(object) 缺少属性 \(selector)。设备驱动可能不兼容。",
                        actions: [.retry], sessionDirectory: sessionDirectory)
        case .badFormat(let message):
            return make(code: "core_audio_bad_format",
                        title: "音频格式异常",
                        detail: message,
                        actions: [.retry], sessionDirectory: sessionDirectory)
        }
    }

    // MARK: Helpers

    private static func make(code: String,
                             title: String,
                             detail: String,
                             actions: [FailureAction],
                             sessionDirectory: URL?) -> AppFailure {
        var finalActions = actions
        if !finalActions.contains(.copyLog) { finalActions.append(.copyLog) }
        if !finalActions.contains(.showInFinder) { finalActions.append(.showInFinder) }
        return AppFailure(code: code,
                          title: title,
                          detail: detail,
                          actions: finalActions,
                          diagnosticURL: diagnosticURL(for: sessionDirectory),
                          sessionDirectory: sessionDirectory)
    }

    private static func diagnosticURL(for sessionDirectory: URL?) -> URL? {
        let manager = FileManager.default
        if let directory = sessionDirectory {
            let diagnostics = directory.appendingPathComponent("diagnostics.json")
            if manager.fileExists(atPath: diagnostics.path) { return diagnostics }
            let coreLog = directory.appendingPathComponent("session-error.log")
            if manager.fileExists(atPath: coreLog.path) { return coreLog }
            return directory.appendingPathComponent("app-events.log")
        }
        return RecorderPaths.supportDirectory.appendingPathComponent("last-failure.log")
    }
}

// MARK: - View model

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var settings: AppSettings = AppSettings() {
        didSet {
            guard didLoadSettings, !suppressPersistence else { return }
            persistSettings()
        }
    }
    @Published var remoteAudioEnabled = true {
        didSet {
            guard oldValue != remoteAudioEnabled else { return }
            settings.monitorEnabled = remoteAudioEnabled
            settings.takeOverSystemOutput = remoteAudioEnabled
            if remoteAudioEnabled {
                if let home = homePodDevice {
                    settings.remoteDeviceUID = home.uid
                }
                ensurePhysicalMonitorSelection()
            } else {
                activeMonitorName = nil
            }
        }
    }
    @Published var lastFailure: AppFailure?
    @Published var startBlockAlert: String?

    @Published private(set) var allDevices: [AudioDeviceInfo] = []
    @Published private(set) var displayOptions: [DisplayOption] = []
    @Published private(set) var windowOptions: [WindowOption] = []
    @Published private(set) var isLoadingWindows = false
    @Published private(set) var windowListNote: String?
    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var uiState: RecorderUIState = .idle
    @Published private(set) var lastResult: RecordingResult?
    @Published private(set) var currentDefaultOutputUID: String?
    @Published private(set) var currentDefaultOutputName: String = "未知"
    @Published private(set) var activeMonitorName: String?
    @Published private(set) var microphoneAuthorization: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var screenCaptureGranted: Bool = CGPreflightScreenCaptureAccess()
    @Published private(set) var isSelfTesting = false
    @Published private(set) var lastSelfTest: SelfTestOutcome?
    @Published private(set) var isPreparing = false
    @Published private(set) var isStopping = false
    @Published private(set) var frozenElapsed: TimeInterval?
    @Published private(set) var ffmpegAvailable: Bool = MediaMuxer.locateFFmpeg() != nil

    let engine = RecorderEngine()
    let log = AppLog()

    private let settingsKey = "FaceTimeRecorder.AppSettings.v1"
    private var didLoadSettings = false
    private var suppressPersistence = false
    private var refreshTimer: Timer?
    private var lastLoggedState: RecorderState = .idle
    private var loggedWarnings: Set<String> = []
    private var loggedErrors: Set<String> = []
    private var remoteSilentSince: Date?
    private var didLogRemoteSilence = false
    private var routeCheckCounter = 0
    private var terminationCompletion: (() -> Void)?

    init() {
        loadSettings()
        engine.recoverStaleOutputLease()
        refreshDisplays()
        refreshDevices(logChange: false)
        refreshPermissions()
        refreshRouting()
        refreshEnvironment()
        didLoadSettings = true
        enforceMinimalDefaults()
        log.add("App 启动。远端音频仍需真人通话验证，不把自检通过当作 FaceTime 已验证。", level: .info)
    }

    // MARK: Derived device lists

    var remoteDeviceOptions: [AudioDeviceInfo] {
        allDevices.filter { $0.outputChannels > 0 }
    }

    var microphoneOptions: [AudioDeviceInfo] {
        allDevices.filter { $0.inputChannels > 0 }
    }

    /// Monitoring must never target a virtual device, including HomePod Flow.
    var monitorOutputOptions: [AudioDeviceInfo] {
        allDevices.filter {
            $0.outputChannels > 0 &&
            !$0.isVirtual &&
            $0.uid != settings.remoteDeviceUID
        }
    }

    var homePodDevice: AudioDeviceInfo? {
        allDevices.first { $0.isHomePodFlowDevice && $0.outputChannels > 0 }
    }

    var selectedRemoteDevice: AudioDeviceInfo? {
        allDevices.first { $0.uid == settings.remoteDeviceUID }
    }

    /// Read-only display value. Core resolves the real monitor output itself
    /// from the physical default that existed before output takeover.
    var resolvedMonitorDevice: AudioDeviceInfo? {
        let options = monitorOutputOptions
        if let uid = currentDefaultOutputUID,
           let device = options.first(where: { $0.uid == uid }) {
            return device
        }
        if let builtIn = options.first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            return builtIn
        }
        return options.first
    }

    var resolvedMonitorUID: String? { resolvedMonitorDevice?.uid }
    var actualMonitorName: String {
        activeMonitorName ?? resolvedMonitorDevice?.name ?? "无可用物理输出"
    }

    var isSystemOutputRoutedToRemote: Bool {
        guard !settings.remoteDeviceUID.isEmpty else { return false }
        return currentDefaultOutputUID == settings.remoteDeviceUID
    }

    /// The coordinator's `--autotest` hook is the only mode allowed to override
    /// the minimal UI's fixed video/monitor/takeover defaults.
    var isAutotestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--autotest")
    }

    var effectiveRecordVideo: Bool {
        isAutotestMode ? settings.recordVideo : true
    }

    var effectiveMonitorEnabled: Bool {
        isAutotestMode ? settings.monitorEnabled : remoteAudioEnabled
    }

    var effectiveTakeover: Bool {
        isAutotestMode ? settings.takeOverSystemOutput : remoteAudioEnabled
    }

    // MARK: Lifecycle

    func onAppear() {
        refreshPermissions()
        refreshRouting()
        refreshEnvironment()
        refreshDisplays()
        refreshDevices(logChange: false)
        if !screenCaptureGranted {
            // Registers the app in Screen Recording and shows the system prompt.
            _ = ScreenRecorder.requestPermission()
            refreshPermissions()
        }
    }

    func refreshPermissions() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    func refreshEnvironment() {
        ffmpegAvailable = MediaMuxer.locateFFmpeg() != nil
    }

    func refreshRouting() {
        let uid = AudioDeviceCatalog.defaultOutputUID()
        currentDefaultOutputUID = uid
        if let uid = uid, let known = allDevices.first(where: { $0.uid == uid }) {
            currentDefaultOutputName = known.name
        } else if let uid = uid {
            currentDefaultOutputName = uid
        } else {
            currentDefaultOutputName = "无默认输出"
        }
    }

    // MARK: Devices and sources

    func refreshDevices(logChange: Bool = true) {
        allDevices = sortedDevices(AudioDeviceCatalog.allDevices())
        applyDeviceDefaultsIfNeeded()
        refreshRouting()
        if logChange {
            let home = homePodDevice?.name ?? "未找到 HomePod Flow"
            log.add("刷新音频设备：\(allDevices.count) 个；\(home)。", level: .info)
        }
    }

    func refreshDisplays() {
        let displays = ScreenRecorder.listDisplays()
        displayOptions = displays
        settings.captureDisplayID = displays.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? displays.first?.id
    }

    func refreshWindows() {
        guard !isLoadingWindows else { return }
        guard screenCaptureGranted else {
            windowOptions = []
            windowListNote = "需要屏幕录制权限才能列出窗口。"
            log.add("未授权屏幕录制，无法列出窗口。", level: .warning)
            return
        }
        isLoadingWindows = true
        windowListNote = nil
        log.add("正在刷新窗口列表…", level: .info)
        Task.detached(priority: .userInitiated) {
            let windows = ScreenRecorder.listWindows()
            await MainActor.run { [weak self] in
                self?.applyWindows(windows)
            }
        }
    }

    private func applyWindows(_ windows: [WindowOption]) {
        isLoadingWindows = false
        windowOptions = windows
        guard !windows.isEmpty else {
            windowListNote = "没有可录制的窗口；可能是权限未授予或窗口已关闭。"
            log.add("窗口列表为空。", level: .warning)
            return
        }
        let faceTime = windows.first { $0.appName.localizedCaseInsensitiveContains("FaceTime") }
        if let faceTime = faceTime {
            windowListNote = "检测到 FaceTime 窗口：\(faceTime.title)"
        } else {
            windowListNote = "未检测到 FaceTime 窗口（共 \(windows.count) 个窗口）。"
        }
        if let current = settings.captureWindowID,
           windows.contains(where: { $0.id == current }) {
            log.add("窗口列表已刷新：\(windows.count) 个。", level: .info)
            return
        }
        if let faceTime = faceTime {
            settings.captureWindowID = faceTime.id
        } else if settings.captureWindowID == nil {
            settings.captureWindowID = windows.first?.id
        }
        log.add("窗口列表已刷新：\(windows.count) 个。", level: .info)
    }

    private func sortedDevices(_ devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        devices.sorted { lhs, rhs in
            if lhs.isHomePodFlowDevice != rhs.isHomePodFlowDevice {
                return lhs.isHomePodFlowDevice
            }
            if lhs.outputChannels != rhs.outputChannels {
                return lhs.outputChannels > rhs.outputChannels
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func applyDeviceDefaultsIfNeeded() {
        suppressPersistence = true
        defer { suppressPersistence = false }

        let remotes = remoteDeviceOptions
        if !remotes.contains(where: { $0.uid == settings.remoteDeviceUID }) {
            settings.remoteDeviceUID = (homePodDevice ?? remotes.first)?.uid ?? ""
        }

        let microphones = microphoneOptions
        if let uid = settings.microphoneUID,
           microphones.contains(where: { $0.uid == uid }) {
            // Keep the user's choice.
        } else {
            let defaultUID = AudioDeviceCatalog.defaultInputDeviceID()
                .flatMap { AudioDeviceCatalog.deviceInfo(id: $0)?.uid }
            settings.microphoneUID = defaultUID.flatMap { uid in
                microphones.contains(where: { $0.uid == uid }) ? uid : nil
            } ?? microphones.first?.uid
        }

        let outputs = monitorOutputOptions
        if let uid = settings.monitorOutputUID,
           outputs.contains(where: { $0.uid == uid }) {
            // Keep the user's choice.
        } else {
            let defaultUID = AudioDeviceCatalog.defaultOutputUID()
            settings.monitorOutputUID = outputs.first(where: { $0.uid == defaultUID })?.uid
                ?? outputs.first(where: { $0.uid == "BuiltInSpeakerDevice" })?.uid
                ?? outputs.first?.uid
        }

        if !isAutotestMode {
            settings.recordVideo = true
            // V1: VPIO can starve the device tap on this machine. Keep raw mic
            // unless the user explicitly experiments in Advanced.
            settings.echoCancellation = .off
        }
        settings.captureMode = .display
        settings.captureDisplayID = displayOptions.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? displayOptions.first?.id
        settings.monitorVolume = 1.0
        if !isAutotestMode {
            settings.monitorEnabled = remoteAudioEnabled
            settings.takeOverSystemOutput = remoteAudioEnabled
        }
        ensurePhysicalMonitorSelection()
    }

    private func enforceMinimalDefaults() {
        suppressPersistence = true
        remoteAudioEnabled = true
        if let home = homePodDevice {
            settings.remoteDeviceUID = home.uid
        }
        if !isAutotestMode {
            settings.recordVideo = true
        }
        settings.captureMode = .display
        settings.captureDisplayID = displayOptions.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? displayOptions.first?.id
        if !isAutotestMode {
            settings.monitorEnabled = true
            settings.takeOverSystemOutput = true
        }
        ensurePhysicalMonitorSelection()
        suppressPersistence = false
        persistSettings()
    }

    private func ensurePhysicalMonitorSelection() {
        let outputs = monitorOutputOptions
        guard !outputs.isEmpty else {
            settings.monitorOutputUID = nil
            return
        }
        if let uid = settings.monitorOutputUID,
           outputs.contains(where: { $0.uid == uid }) {
            return
        }
        let defaultUID = AudioDeviceCatalog.defaultOutputUID()
        settings.monitorOutputUID = outputs.first(where: { $0.uid == defaultUID })?.uid
            ?? outputs.first(where: { $0.uid == "BuiltInSpeakerDevice" })?.uid
            ?? outputs.first?.uid
    }

    // MARK: Permission requests

    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            log.add("请求麦克风权限…", level: .info)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    self.log.add(granted
                                 ? "麦克风权限已授予。"
                                 : "麦克风权限被拒绝；本次仍可录制，但不会有麦克风音轨。",
                                 level: granted ? .success : .warning)
                }
            }
        } else if status == .denied || status == .restricted {
            openSystemSettings(.microphone)
        } else {
            log.add("麦克风权限已授权。", level: .info)
        }
    }

    func requestScreenPermission() {
        if CGPreflightScreenCaptureAccess() {
            screenCaptureGranted = true
            log.add("屏幕录制权限已授予。", level: .success)
            return
        }
        log.add("请求屏幕录制权限…", level: .info)
        let granted = CGRequestScreenCaptureAccess()
        screenCaptureGranted = granted || CGPreflightScreenCaptureAccess()
        if screenCaptureGranted {
            log.add("屏幕录制权限已授予。若仍无法开始，请重启 App。", level: .success)
        } else {
            log.add("屏幕录制权限未授予；请在系统设置中允许 FaceTime Recorder。", level: .warning)
            openSystemSettings(.screenCapture)
        }
    }

    func openSystemSettings(_ destination: SystemSettingsDestination) {
        let urlString: String
        switch destination {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenCapture, .audioCapture:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .sound:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        }
        guard let url = URL(string: urlString) else { return }
        if !NSWorkspace.shared.open(url) {
            log.add("无法自动打开系统设置，请手动打开系统设置（\(destination.rawValue)）。",
                    level: .warning)
        }
    }

    // MARK: Start / stop

    var startBlockReason: String? {
        if isSelfTesting { return "正在执行自检，请稍候。" }
        if !remoteAudioEnabled && !settings.recordMicrophone {
            return "请至少开启一个声音来源。"
        }
        if remoteAudioEnabled {
            if settings.remoteDeviceUID.isEmpty {
                return "未找到 HomePod Flow 设备。"
            }
            guard let remote = selectedRemoteDevice else {
                return "远端设备不可用，请在高级中选择。"
            }
            if remote.outputChannels == 0 { return "远端设备没有输出通道。" }
            if effectiveMonitorEnabled && resolvedMonitorDevice == nil {
                return "没有可用的物理监听输出。"
            }
        }
        if settings.recordMicrophone && settings.microphoneUID == nil {
            return "未找到麦克风。"
        }
        if !remoteAudioEnabled && settings.recordMicrophone &&
            microphoneAuthorization != .authorized &&
            microphoneAuthorization != .notDetermined {
            return "麦克风权限未授予。"
        }
        if effectiveRecordVideo {
            if !screenCaptureGranted {
                return "屏幕录制权限未授予。"
            }
            if displayOptions.isEmpty { return "未找到主显示器。" }
        }
        if !ffmpegAvailable {
            return "缺少视频生成工具。"
        }
        return nil
    }

    var primaryButtonTitle: String {
        switch uiState {
        case .idle: return "录制"
        case .preparing: return "准备中…"
        case .recording: return "暂停"
        case .paused: return "继续"
        case .stopping, .muxing: return "正在生成视频…"
        case .finished: return "录制"
        case .failed: return "重试"
        }
    }

    var primaryButtonEnabled: Bool {
        switch uiState {
        case .idle, .finished, .failed:
            // Always clickable: clicking explains the blocker and opens the
            // matching privacy pane instead of leaving a dead button.
            return true
        case .recording, .paused:
            return true
        case .preparing, .stopping, .muxing:
            return false
        }
    }

    var primaryButtonShowsProgress: Bool {
        uiState == .preparing || uiState == .stopping || uiState == .muxing
    }

    var compactStatusText: String {
        switch uiState {
        case .idle: return "空闲"
        case .preparing: return "准备中…"
        case .recording: return "录制中 \(compactElapsedText)"
        case .paused: return "已暂停 \(compactElapsedText)"
        case .stopping, .muxing: return "正在生成视频…"
        case .finished: return "完成"
        case .failed: return "失败：\(lastFailure?.title ?? "未知错误")"
        }
    }

    var compactElapsedText: String {
        let total = max(0, Int(displayElapsed.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var primaryFileURL: URL? {
        lastResult?.mp4URL ?? lastResult?.mkvURL
    }

    var savedSummary: String? {
        guard uiState == .finished, let result = lastResult else { return nil }
        let hasRemote = result.remoteWAVURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let hasMic = result.micWAVURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        if result.mp4URL != nil {
            if hasRemote && hasMic { return "已保存（三条音轨）" }
            if hasRemote { return "已保存（仅对方声音）" }
            if hasMic { return "已保存（仅麦克风）" }
            return "已保存"
        }
        if result.mkvURL != nil { return "已保存（多轨归档）" }
        return nil
    }

    var diagnosticPathText: String {
        if let result = lastResult { return result.diagnosticsURL.path }
        if let failure = lastFailure, let url = failure.diagnosticURL { return url.path }
        return "暂无"
    }

    func revealPrimaryFile() {
        if let url = primaryFileURL {
            revealInFinder(url)
        } else if let directory = lastResult?.sessionDirectory {
            revealInFinder(directory)
        }
    }

    /// Opens the exported video straight in the default player.
    func openPrimaryFile() {
        guard let url = primaryFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            revealPrimaryFile()
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealDiagnostic() {
        if let result = lastResult {
            revealInFinder(result.diagnosticsURL)
        } else if let url = lastFailure?.diagnosticURL {
            revealInFinder(url)
        } else {
            log.add("暂无诊断文件。", level: .info)
        }
    }

    func primaryAction() {
        switch uiState {
        case .recording:
            pauseRecording()
        case .paused:
            resumeRecording()
        case .preparing, .stopping, .muxing:
            break
        case .idle, .finished, .failed:
            if let reason = startBlockReason {
                startBlockAlert = reason
                log.add("无法开始：\(reason)", level: .warning)
                if reason.contains("屏幕") {
                    openSystemSettings(.screenCapture)
                } else if reason.contains("麦克风") {
                    openSystemSettings(.microphone)
                }
                return
            }
            startRecording()
        }
    }

    func pauseRecording() {
        guard uiState == .recording, !isStopping else { return }
        engine.pause()
        uiState = .paused
        log.add("录制已暂停", level: .info)
    }

    func resumeRecording() {
        guard uiState == .paused else { return }
        engine.resume()
        uiState = .recording
        log.add("继续录制", level: .info)
    }

    func openSettingsForStartBlock() {
        let reason = startBlockAlert ?? ""
        if reason.contains("屏幕") {
            openSystemSettings(.screenCapture)
        } else if reason.contains("麦克风") {
            openSystemSettings(.microphone)
        }
        startBlockAlert = nil
    }

    func startRecording() {
        guard !uiState.isBusy, !isSelfTesting else { return }
        refreshRouting()
        refreshPermissions()
        refreshEnvironment()
        if let reason = startBlockReason {
            log.add("无法开始：\(reason)", level: .warning)
            return
        }
        if settings.recordMicrophone && microphoneAuthorization == .notDetermined &&
            !ProcessInfo.processInfo.arguments.contains("--autotest") {
            log.add("开始前请求麦克风权限…", level: .info)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.refreshPermissions()
                    self.beginStart()
                }
            }
            return
        }
        beginStart()
    }

    private func beginStart() {
        guard !uiState.isBusy else { return }
        refreshRouting()
        refreshEnvironment()
        if let reason = startBlockReason {
            log.add("无法开始：\(reason)", level: .warning)
            return
        }

        let config = makeConfiguration()
        activeMonitorName = resolvedMonitorDevice?.name ?? "系统默认输出"
        lastFailure = nil
        lastResult = nil
        lastSelfTest = nil
        uiState = .preparing
        isPreparing = true
        frozenElapsed = nil
        remoteSilentSince = nil
        didLogRemoteSilence = false
        routeCheckCounter = 0
        loggedWarnings.removeAll()
        loggedErrors.removeAll()
        lastLoggedState = .idle

        let monitorDescription = effectiveMonitorEnabled ? actualMonitorName : "监听已关闭"
        let remoteDescription = config.recordRemote
            ? (selectedRemoteDevice?.name ?? config.remoteDeviceUID)
            : "已关闭"
        log.add("准备开始：远端 \(remoteDescription)，监听 \(monitorDescription)。",
                level: .info)
        if effectiveTakeover {
            log.add("将在开始录制时接管系统默认输出；停止录制时恢复。", level: .warning)
        } else if !config.recordRemote {
            log.add("对方声音已关闭：不创建远端 tap，也不接管系统输出。", level: .warning)
        } else {
            log.add("本次不接管系统输出；远端轨可能为空。", level: .warning)
            if isSystemOutputRoutedToRemote {
                log.add("系统输出仍指向远端设备；Core 的远端 tap 可能仍会录入对方声音。", level: .warning)
            }
        }
        if settings.recordMicrophone && microphoneAuthorization != .authorized {
            log.add(remoteAudioEnabled
                    ? "麦克风未授权：本次仅录制对方声音与画面。"
                    : "麦克风未授权且对方声音已关闭：本次可能没有可用音轨。",
                    level: .warning)
        }

        let engine = self.engine
        let skipSelfTest = self.isAutotestMode
        Task.detached(priority: .userInitiated) {
            // Run the honest 1-second non-silence test with stricter app-side
            // thresholds, then start Core without a second tone. Skipped when
            // the user records only the microphone.
            if config.recordRemote && !skipSelfTest {
                let selfTest = engine.runSelfTest(deviceUID: config.remoteDeviceUID, seconds: 1.0)
                let evaluation = SelfTestEvaluator.evaluate(selfTest)
                guard evaluation.passed else {
                    let failure = ErrorMapper.selfTestFailure(evaluation,
                                                              result: selfTest,
                                                              sessionDirectory: nil)
                    await MainActor.run { [weak self] in
                        self?.handleStartOutcome(.failure(failure))
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    self?.lastSelfTest = SelfTestOutcome(passed: true,
                                                         title: evaluation.title,
                                                         detail: evaluation.detail,
                                                         code: evaluation.code,
                                                         result: selfTest)
                    self?.log.add("\(evaluation.title)：\(evaluation.detail)", level: .success)
                }
            }
            do {
                let files = try engine.start(configuration: config, performSelfTest: false)
                await MainActor.run { [weak self] in
                    self?.handleStartOutcome(.success(files))
                }
            } catch {
                let failure = ErrorMapper.map(error, sessionDirectory: engine.sessionDirectory)
                await MainActor.run { [weak self] in
                    self?.handleStartOutcome(.failure(failure))
                }
            }
        }
    }

    private func makeConfiguration() -> RecorderConfiguration {
        let microphoneEnabled = settings.recordMicrophone &&
            microphoneAuthorization == .authorized &&
            settings.microphoneUID != nil
        let mainDisplayID = displayOptions.first(where: { $0.id == CGMainDisplayID() })?.id
            ?? displayOptions.first?.id
        // Core prefers ScreenRecorder.faceTimeWindowID() and falls back to the
        // main display. Its current validate() still rejects both capture IDs
        // being nil when recordRemote is on, so pass the main display as the
        // fallback instead of a user-selectable source.
        let fallbackDisplayID = (effectiveRecordVideo && remoteAudioEnabled)
            ? mainDisplayID
            : nil
        return RecorderConfiguration(
            remoteDeviceUID: settings.remoteDeviceUID,
            recordRemote: remoteAudioEnabled,
            microphoneUID: microphoneEnabled ? settings.microphoneUID : nil,
            monitorOutputUID: nil,
            captureDisplayID: fallbackDisplayID,
            captureWindowID: settings.captureWindowID,
            recordVideo: effectiveRecordVideo,
            recordMicrophone: microphoneEnabled,
            monitorEnabled: effectiveMonitorEnabled,
            monitorVolume: Float(max(0, min(1, settings.monitorVolume))),
            echoCancellation: settings.echoCancellation,
            remoteChannelMode: .stereoDownmix,
            takeOverSystemOutput: effectiveTakeover,
            outputDirectory: RecorderPaths.defaultOutputDirectory)
    }

    private func handleStartOutcome(_ outcome: StartOutcome) {
        isPreparing = false
        switch outcome {
        case .success(let files):
            lastFailure = nil
            uiState = .recording
            snapshot = engine.snapshot()
            log.add("录制开始：\(files.directory.path)", level: .success)
            startRefreshTimer()
            refreshRouting()
        case .failure(let failure):
            uiState = .failed
            lastFailure = failure
            activeMonitorName = nil
            snapshot = engine.snapshot()
            log.add("\(failure.title)：\(failure.detail)", level: .error)
            persistFailureLog(failure)
            stopRefreshTimer()
            refreshRouting()
        }
    }

    func stopRecording() {
        guard uiState == .recording || uiState == .paused ||
              snapshot.state == .recording || snapshot.state == .paused else { return }
        guard !isStopping else { return }
        isStopping = true
        frozenElapsed = snapshot.elapsed
        uiState = .stopping
        log.add("正在保存视频（混音 / 对方 / 麦克风 三条音轨）…", level: .info)
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            let result = engine.stop()
            await MainActor.run { [weak self] in
                self?.handleStopResult(result)
            }
        }
    }

    private func handleStopResult(_ result: RecordingResult?) {
        defer { notifyTerminationReady() }
        isStopping = false
        stopRefreshTimer()
        refreshRouting()

        guard let result = result else {
            uiState = .failed
            let detail = engine.lastError ?? "停止时没有处于录制状态，或媒体收尾失败。"
            let failure = ErrorMapper.genericFailure(code: "stop_failed",
                                                     title: "停止/封装失败",
                                                     detail: detail,
                                                     sessionDirectory: engine.sessionDirectory)
            lastFailure = failure
            log.add("停止失败：\(detail)", level: .error)
            persistFailureLog(failure)
            return
        }

        lastResult = result
        let hasPlayableFile = result.mp4URL != nil || result.mkvURL != nil
        if hasPlayableFile {
            uiState = .finished
        } else {
            uiState = .failed
            let failure = ErrorMapper.genericFailure(
                code: "mux_failed",
                title: "没有生成可播放主文件",
                detail: "视频文件没有生成。WAV/MOV 素材已保留在会话目录中；请查看诊断文件并重试封装。",
                sessionDirectory: result.sessionDirectory)
            lastFailure = failure
            persistFailureLog(failure)
        }
        log.add("录制结束，时长 \(Self.formatDuration(result.durationSeconds))。",
                level: hasPlayableFile ? .success : .warning)
        if let mp4 = result.mp4URL {
            log.add("视频文件（三条音轨）：\(mp4.path)", level: .info)
        } else {
            log.add("视频未生成；请查看诊断与 WAV/MOV 素材。", level: .warning)
        }
        if FileManager.default.fileExists(atPath: result.diagnosticsURL.path) {
            log.add("诊断：\(result.diagnosticsURL.path)", level: .info)
        }
    }

    // MARK: Self-test

    func runSelfTest() {
        guard !isSelfTesting, !uiState.isBusy else { return }
        guard remoteAudioEnabled else {
            lastSelfTest = nil
            log.add("未开启“录制对方声音”，无需远端自检。", level: .info)
            return
        }
        guard !settings.remoteDeviceUID.isEmpty else {
            lastSelfTest = SelfTestOutcome(passed: false,
                                           title: "无法自检",
                                           detail: "未选择远端设备。",
                                           code: "device_missing",
                                           result: nil)
            return
        }
        refreshRouting()
        refreshEnvironment()
        isSelfTesting = true
        lastSelfTest = nil
        log.add("开始 1 秒 1 kHz 低电平非静音自检（不录音）。", level: .info)
        let engine = self.engine
        let uid = settings.remoteDeviceUID
        Task.detached(priority: .userInitiated) {
            let result = engine.runSelfTest(deviceUID: uid, seconds: 1.0)
            let evaluation = SelfTestEvaluator.evaluate(result)
            await MainActor.run { [weak self] in
                self?.handleSelfTest(result: result, evaluation: evaluation)
            }
        }
    }

    private func handleSelfTest(result: SelfTestResult, evaluation: SelfTestEvaluation) {
        isSelfTesting = false
        lastSelfTest = SelfTestOutcome(passed: evaluation.passed,
                                       title: evaluation.title,
                                       detail: evaluation.detail,
                                       code: evaluation.code,
                                       result: result)
        log.add("\(evaluation.title)：\(evaluation.detail)",
                level: evaluation.passed ? .success : .error)
    }

    // MARK: Snapshot refresh

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        tick()
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func tick() {
        let newSnapshot = engine.snapshot()
        snapshot = newSnapshot

        if newSnapshot.state != lastLoggedState {
            lastLoggedState = newSnapshot.state
            if newSnapshot.state == .muxing {
                log.add("Core 正在生成视频…", level: .info)
            } else if newSnapshot.state == .stopping {
                log.add("Core 正在停止采集并关闭文件…", level: .info)
            }
        }

        for warning in newSnapshot.warnings where !loggedWarnings.contains(warning) {
            loggedWarnings.insert(warning)
            log.add("监听警告：\(warning)", level: .warning)
        }
        if let error = newSnapshot.lastError, !loggedErrors.contains(error) {
            loggedErrors.insert(error)
            log.add("Core 错误：\(error)", level: .error)
        }

        if isPreparing {
            if newSnapshot.state == .recording {
                isPreparing = false
                uiState = .recording
            }
        }

        if isStopping {
            switch newSnapshot.state {
            case .muxing:
                uiState = .muxing
            case .finished:
                uiState = .finished
            case .failed:
                uiState = .failed
            default:
                uiState = .stopping
            }
        } else if !isPreparing && newSnapshot.state == .recording {
            uiState = .recording
        }

        if uiState == .recording {
            if newSnapshot.remoteRMS < 0.0005 {
                if remoteSilentSince == nil {
                    remoteSilentSince = Date()
                } else if !didLogRemoteSilence,
                          let since = remoteSilentSince,
                          Date().timeIntervalSince(since) >= 10 {
                    didLogRemoteSilence = true
                    log.add("远端已连续约 10 秒没有电平。请确认 FaceTime 正在使用 HomePod Flow 输出且对方有声音；录制仍在继续。",
                            level: .warning)
                }
            } else {
                remoteSilentSince = nil
                didLogRemoteSilence = false
            }
        }

        routeCheckCounter += 1
        if routeCheckCounter >= 4 {
            routeCheckCounter = 0
            let previousUID = currentDefaultOutputUID
            refreshRouting()
            if previousUID != currentDefaultOutputUID, uiState == .recording {
                if isSystemOutputRoutedToRemote {
                    log.add("系统输出已切回远端设备：\(currentDefaultOutputName)。", level: .info)
                } else {
                    log.add("系统输出已从远端设备切走（当前：\(currentDefaultOutputName)）；FaceTime 远端可能静音。App 不会自动改回。",
                            level: .warning)
                }
            }
        }
    }

    // MARK: Result helpers

    var displayElapsed: TimeInterval {
        switch uiState {
        case .recording, .paused:
            return snapshot.elapsed
        case .stopping, .muxing:
            return frozenElapsed ?? snapshot.elapsed
        case .finished:
            return lastResult?.durationSeconds ?? frozenElapsed ?? 0
        case .idle, .preparing:
            return 0
        case .failed:
            return lastResult?.durationSeconds ?? frozenElapsed ?? 0
        }
    }

    var formattedElapsed: String {
        Self.formatDuration(displayElapsed)
    }

    var statusDetail: String {
        switch uiState {
        case .idle:
            return "配置设备后点击开始。开始前会执行 1 秒非静音自检。"
        case .preparing:
            return "正在执行 1 秒自检、创建采集并启动监听…"
        case .recording:
            let monitorDescription = effectiveMonitorEnabled ? actualMonitorName : "已关闭"
            return "远端回调 \(snapshot.remoteCallbacks) 次；监听缓冲 \(snapshot.monitorFillFrames) 帧；监听 \(monitorDescription)。"
        case .paused:
            return "已暂停：画面与两条音轨都暂停写入，继续后接着录。"
        case .stopping:
            return "正在停止采集并关闭文件…"
        case .muxing:
            return "正在生成视频（混音 / 对方 / 麦克风 三条音轨）…"
        case .finished:
            return "已保存。默认播放混音；需要时可用 ffmpeg 单独取出对方或麦克风音轨。"
        case .failed:
            return lastFailure?.title ?? "操作失败。"
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    func revealInFinder(_ url: URL) {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if manager.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
        } else {
            log.add("路径不存在：\(url.path)", level: .warning)
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log.add("已复制到剪贴板。", level: .info)
    }

    // MARK: Failure actions

    func perform(_ action: FailureAction) {
        switch action {
        case .openMicrophoneSettings:
            openSystemSettings(.microphone)
        case .openScreenSettings:
            openSystemSettings(.screenCapture)
        case .openAudioCaptureSettings:
            openSystemSettings(.audioCapture)
        case .openSoundSettings:
            openSystemSettings(.sound)
        case .retry:
            startRecording()
        case .showInFinder:
            if let url = lastFailure?.diagnosticURL ?? lastFailure?.sessionDirectory {
                revealInFinder(url)
            }
        case .copyLog:
            copyToPasteboard(log.exportText())
        }
    }

    private func persistFailureLog(_ failure: AppFailure) {
        let target: URL
        if let directory = failure.sessionDirectory {
            target = directory.appendingPathComponent("app-events.log")
        } else {
            target = RecorderPaths.supportDirectory.appendingPathComponent("last-failure.log")
        }
        let header = """
        FaceTime Recorder failure
        code=\(failure.code)
        title=\(failure.title)
        detail=\(failure.detail)
        diagnostic=\(failure.diagnosticURL?.path ?? "-")

        """
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try (header + log.exportText() + "\n").write(to: target,
                                                         atomically: true,
                                                         encoding: .utf8)
            log.add("应用日志：\(target.path)", level: .info)
        } catch {
            log.add("写入应用日志失败：\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Termination

    /// Called from `applicationShouldTerminate`.
    ///
    /// Returns `true` when the termination must wait for the current recording
    /// stop/mux to finish (the completion is called from `handleStopResult`).
    /// Returns `false` when output has already been restored and the app can
    /// terminate immediately.
    func prepareForTermination(_ completion: @escaping () -> Void) -> Bool {
        switch uiState {
        case .recording, .paused, .stopping, .muxing:
            terminationCompletion = completion
            if uiState == .recording || uiState == .paused {
                stopRecording()
            }
            return true
        case .preparing:
            // Core start is synchronous inside a detached task and cannot be
            // cancelled safely here. Restore the output and let process exit
            // clean up the partial session.
            restoreDefaultOutput(force: true, onlyLease: true)
            return false
        case .idle, .finished, .failed:
            restoreDefaultOutput(force: true, onlyLease: true)
            return false
        }
    }

    private func notifyTerminationReady() {
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
    }

    // MARK: System output restoration

    /// Explicit menu action. Never called automatically.
    func restoreDefaultOutput(force: Bool = false, onlyLease: Bool = false) {
        guard force || !uiState.isBusy else {
            log.add("录制/准备/封装中，不能恢复默认输出；请先停止并保存。", level: .warning)
            return
        }
        refreshRouting()

        if FileManager.default.fileExists(atPath: RecorderPaths.leaseURL.path),
           let lease = loadLease() {
            if lease.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               kill(lease.processIdentifier, 0) == 0 {
                log.add("检测到另一个进程仍持有输出租约（pid \(lease.processIdentifier)），不会覆盖它的系统输出。",
                        level: .warning)
                return
            }
            if let original = lease.originalDefaultOutputUID,
               AudioDeviceCatalog.deviceID(forUID: original) != nil {
                do {
                    try AudioDeviceCatalog.setDefaultOutput(uid: original)
                    try? FileManager.default.removeItem(at: RecorderPaths.leaseURL)
                    refreshRouting()
                    log.add("已恢复系统默认输出：\(currentDefaultOutputName)", level: .success)
                    return
                } catch {
                    let failure = ErrorMapper.map(error, sessionDirectory: nil)
                    lastFailure = failure
                    log.add("恢复默认输出失败：\(failure.detail)", level: .error)
                    persistFailureLog(failure)
                    return
                }
            }
            try? FileManager.default.removeItem(at: RecorderPaths.leaseURL)
            log.add("输出租约没有可恢复的原设备；已清理租约。", level: .warning)
        }

        if onlyLease { return }

        guard let currentUID = currentDefaultOutputUID,
              let current = allDevices.first(where: { $0.uid == currentUID }),
              current.isVirtual || current.isHomePodFlowDevice else {
            log.add("当前系统默认输出不是 HomePod Flow，无需恢复。", level: .info)
            return
        }

        let candidates = allDevices.filter { $0.outputChannels > 0 && !$0.isVirtual }
        let target = candidates.first(where: { $0.uid == "BuiltInSpeakerDevice" })
            ?? candidates.first
        guard let target = target else {
            log.add("找不到可恢复的物理输出设备，请在系统设置中手动选择。", level: .warning)
            openSystemSettings(.sound)
            return
        }
        do {
            try AudioDeviceCatalog.setDefaultOutput(uid: target.uid)
            refreshRouting()
            log.add("已恢复系统默认输出：\(target.name)", level: .success)
        } catch {
            let failure = ErrorMapper.map(error, sessionDirectory: nil)
            lastFailure = failure
            log.add("恢复默认输出失败：\(failure.detail)", level: .error)
            persistFailureLog(failure)
        }
    }

    private func loadLease() -> OutputLease? {
        guard let data = try? Data(contentsOf: RecorderPaths.leaseURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OutputLease.self, from: data)
    }

    // MARK: Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return
        }
        settings = decoded
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }
}
