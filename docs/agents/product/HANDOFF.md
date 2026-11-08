# FaceTime Recorder 交接文档（HANDOFF）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.2 |
| 日期 | 2026-11-07 |
| 作者 | 产品 Agent |
| 交接对象 | UI Agent、Dev Agent、QA Agent |
| 输入基线 | `docs/agents/product/PRD.md`、`docs/agents/product/TECH_PLAN.md`、`docs/audit/G0_AUDIT.md` |
| 状态 | 待总调度确认后开工；未确认的决策不得由下游自行改变 |

> **全局红线**
>
> 1. 不修改旧 HomePod Flow 仓库、驱动或 `FlowVirtualAudio.c`。
> 2. 不安装/依赖额外虚拟麦克风；不依赖 HomePod/AirPlay。
> 3. 监听不得回放麦克风；录制与监听解耦。
> 4. FaceTime 真人通话音频未验证前，UI/文档/发布说明只能写“待验证”。
> 5. 任何“通过”必须有命令、时间、退出码、日志/报告路径、必要的人工听感记录。
> 6. 正常交付双产物：`FaceTime.mp4`（H.264 + 双方 Mix，默认播放/分享）和 `FaceTime.mkv`（H.264 + Mix/Remote/Mic）。
> 7. 录制阶段不混音，保留 `remote.wav` + `microphone.wav`；混音只在停止后的 FFmpeg 导出阶段发生。
> 8. 监听默认开启，永远解析到物理输出（MacBook 扬声器/耳机）；即使系统默认输出被接管到虚拟声卡，监听仍从物理设备出声。

---

## 1. 给 UI Agent

### 1.1 目标与边界

V1 是**极简产品形态**，不是临时 demo。UI Agent 的第一优先级是让主界面只保留“两个开关 + 一个按钮 + 状态/结果/同意提示”，其余全部进 `高级` 折叠区。

**唯一写入范围**：

```text
docs/agents/ui/**
Sources/App/UI/**
```

**交付物**：

- `docs/agents/ui/UI_SPEC.md`
- `docs/agents/ui/mockups/**`（至少：空闲、准备中、录制中、生成中、完成、失败、高级展开）
- `Sources/App/UI/MinimalRecorderView.swift`
- `Sources/App/UI/AdvancedSettingsView.swift`
- “状态 → 主界面一行”对照表

### 1.2 V1 主界面（唯一允许的元素）

```text
┌──────────────────────────────────────────┐
│              FaceTime 录音               │
│                                          │
│   [ 录制对方声音            开 ]          │
│     会自动切换系统声音并在停止后恢复。     │
│                                          │
│   [ 录制我的麦克风          开 ]          │
│                                          │
│              [ 开始录制 ]                 │
│                                          │
│   状态：空闲                              │
│                                          │
│   请确保通话对方同意录音。                 │
│   远端音频：待真人通话验证                 │
│                                          │
│   高级 ▸                                  │
└──────────────────────────────────────────┘
```

主界面只允许：

1. 标题：`FaceTime 录音`。
2. 两个大开关：
   - `录制对方声音`（默认开）；
   - `录制我的麦克风`（默认开）。
3. 一个主按钮：`开始录制` / `停止并保存`。
4. 一行状态：`空闲` / `准备中` / `录制中 00:12` / `正在生成视频` / `完成` / `失败：<原因>`。
5. 完成后一行结果：`已保存 FaceTime.mp4（双方声音）` + `在 Finder 中显示`。
6. 常驻小字：`请确保通话对方同意录音。`
7. 远端开关下一行说明：`会自动切换系统声音并在停止后恢复。`
8. 底部固定小字：`远端音频：待真人通话验证`。
9. `高级` 折叠入口。

主界面不显示：设备名、窗口/显示器选择、监听开关、音量滑杆、权限卡片、诊断、日志、FFmpeg/8ch 徽章、MKV 路径。

### 1.3 状态 → 主界面

| 状态 | 状态行 | 主按钮 | 开关 | 结果行 |
|---|---|---|---|---|
| `idle` | `空闲` | `开始录制`（两项都关时禁用） | 可切换 | 无/上次结果可保留 |
| `preparing` | `准备中` | 禁用 | 锁定 | 无 |
| `recording` | `录制中 MM:SS` | `停止并保存` | 锁定 | 无 |
| `stopping` | `准备中` 或 `正在生成视频` | 禁用 | 锁定 | 无 |
| `muxing` | `正在生成视频` | 禁用 | 锁定 | 无 |
| `finished` | `完成` | `开始录制` | 可切换 | `已保存 ...` + Finder |
| `failed` | `失败：<中文原因>` | `开始录制` | 可切换 | 可保留上次结果 |

### 1.4 开关组合

| 录制对方 | 录制麦克风 | 主界面行为 |
|---|---|---|
| 开 | 开 | 自动接管 + 自动监听；结果“双方声音” |
| 开 | 关 | 自动接管 + 自动监听；结果“仅对方声音” |
| 关 | 开 | 不接管、不监听；结果“仅麦克风” |
| 关 | 关 | 主按钮禁用；状态“请至少开启一项” |

录制中两个开关锁定；必须停止后重新开始才能改变组合。

### 1.5 自动行为（UI 不提供选择）

- 远端设备：自动 `HomePod Flow Audio`。
- 麦克风：自动系统默认输入。
- 监听：`录制对方声音` 开启时自动开启；固定使用接管前的那台物理默认输出；UI 无设备选择/音量滑杆，音量由 macOS 控制；麦克风永不进入监听。
- 系统输出接管：**只在点“开始录制”时**自动接管；App 启动/空闲时不切；关闭“录制对方声音”时不接管；停止/退出/崩溃恢复自动还原；不弹确认框。
- 画面：自动查找 `appName=FaceTime` 窗口；找到录窗口，找不到回退主显示器并在状态行说明；不选窗口/显示器。
- AEC：默认关闭；高级区可开 Apple VPIO；不得写“已消除回声”。
- 结果：主界面只展示 MP4（或仅音频时 M4A）；MKV 归档在高级区。

### 1.6 高级折叠区（默认收起）

展开后允许显示，但不得影响主流程：

1. 设备：虚拟声卡状态、麦克风设备、监听输出（只读，固定接管前物理默认）。
2. 音频：AEC 开关、单声道兼容（P1）、8ch 诊断（P1）；不提供监听音量。
3. 权限：麦克风/系统音频/屏幕状态、打开系统设置、重新自检、重新启动。
4. 诊断：`diagnostics.json` 路径、扫描/复制、日志、FFmpeg 版本/路径、8ch 徽章。
5. 视频源状态（只读）：FaceTime 窗口 / 主显示器回退；不提供选择器。
6. 产物：MKV 多轨归档路径、源轨 WAV、`mix.wav`（失败时）、导出重试。
7. 输出恢复：立即恢复、打开声音设置、上次会话恢复。

高级区默认折叠；主界面不因高级区展开而改变状态或尺寸突变。

### 1.7 输出接管说明

主界面只在远端开关下显示一行：

> `会自动切换系统声音并在停止后恢复。`

接管发生在点“开始录制”时，不在 App 启动时。不显示确认弹窗、不显示“接管”按钮、不显示原设备名。原设备名、系统提示音风险、恢复失败处理放在高级区。

### 1.8 完成结果

| 场景 | 主界面结果行 |
|---|---|
| 双方都录 | `已保存 FaceTime.mp4（双方声音）` + `在 Finder 中显示` |
| 仅对方 | `已保存 FaceTime.mp4（仅对方声音）` + `在 Finder 中显示` |
| 仅麦克风 | `已保存 FaceTime.mp4（仅麦克风）` + `在 Finder 中显示` |
| 仅音频 | `已保存 FaceTime.m4a（双方声音）` + `在 Finder 中显示` |
| 降级 | 仍显示主产物；缺失的 MP4/MKV 在高级区标黄 |

MKV 多轨归档、两条路径、时长、大小、警告、诊断入口只在高级区。

### 1.9 失败与权限（极简）

- 主界面不显示权限卡片；失败时状态行给一句中文原因，例如：
  - `失败：远端音频权限未开启`
  - `失败：无法切换系统声音`
  - `失败：没有可用的扬声器/耳机`
  - `失败：磁盘空间不足`
- 详细权限、错误码、打开设置、重新自检、重启 App 全部在高级区。
- 麦克风拒绝不阻塞录制：状态行/结果行降级为“仅对方声音”。
- 屏幕拒绝自动仅音频：状态行提示“无屏幕权限，仅录音频”；不新增按钮。
- 固定监听设备不可用时状态行“失败：没有可用的扬声器/耳机”；不自动换设备。
- 不把“有文件”显示为成功；MP4/MKV 单产物缺失必须在高级区标黄。

### 1.10 可访问性

- 两个开关有 VoiceOver label 和状态描述。
- 主按钮有 `⌘R` 快捷键；录制中为停止。
- 状态行变化用 VoiceOver announcement，但不要每秒播报计时。
- 不用颜色作为唯一状态；配文字。
- 最小窗口 520×420；高级展开可滚动。
- 录制红点不闪烁或提供静态替代。

### 1.11 UI 禁止事项

1. 不在主界面或高级区增加监听设备选择、监听音量滑杆、窗口/显示器选择器；主界面不增加设备选择、监听开关、权限卡片、诊断、日志、FFmpeg/8ch。
2. 不显示“FaceTime 音频已支持/已验证”；底部只能是 `远端音频：待真人通话验证`。
3. 不把 MKV 说成默认播放文件；默认播放是 MP4（仅音频 M4A）。
4. 不隐藏 MP4/MKV 单产物缺失；高级区必须标黄。
5. 不在录制中允许切换开关。
6. 不自动修改系统输出却不给一行说明；说明必须常驻。
7. 不允许把虚拟设备选为监听输出。
8. 不在 UI 层直接调用 Core Audio/ScreenCaptureKit 采集 API。

---
## 2. 给 Dev Agent

### 2.1 边界与写入范围

**唯一写入范围**（按 CHARTER）：

```text
Sources/App/**（UI 目录除外）
Sources/Core/** 新增文件
Scripts/**
```

**只读、不得擅自修改**：

```text
Sources/CRing/**
Sources/Core/Capture.swift
Sources/Core/CoreAudioSupport.swift
Sources/Core/Models.swift
Sources/Core/TonePlayer.swift
Sources/Core/WAVWriter.swift
Sources/Core/DriftResampler.swift
Sources/Probe/**
Resources/**
project.yml
docs/**
Tests/**
```

如果确实需要修改上述只读文件，先在 `docs/agents/STATUS.md` 登记，由总调度裁决/合并。不要直接改驱动/旧仓库。

### 2.2 现有代码复用

| 现有 | 用法 |
|---|---|
| `DeviceTapCapture` | 远端 tap；`start(deviceUID:preferredClockUID:)`；`readBlock(into:)` |
| `CapturedBlock` | 包含 frames/channels/samples/hostTime/sampleTime/timestampFlags/sequence/droppedBefore |
| `TapDescriptor` | tapUID/aggregateUID/clockDeviceUID/sampleRate/channels/bytesPerFrame/formatFlags |
| `AudioDeviceCatalog` | 设备枚举、UID 查找、默认输出、channel labels、setDefaultOutput |
| `RecorderConfiguration` | 配置结构；已有 `takeOverSystemOutput`、`monitorEnabled`、`monitorVolume`、`echoCancellation`、`remoteChannelMode` |
| `RecorderState` | 已有 `idle/preparing/recording/stopping/muxing/finished/failed`，直接用 |
| `RecorderPaths` | 输出目录、lease URL |
| `OutputLease` | 现有字段；如需 `sessionID`，新增 `OutputLeaseRecord`，不要改旧结构 |
| `DriftResampler` | 监听路径；stereo |
| `TonePlayer` | 自检 1 kHz；测试用 440 Hz |
| `WAVWriter` | `remote.wav`/`microphone.wav`/自检 8ch |
| `FRBlockRing`/`FRSampleRing` | 所有音频 ring |

### 2.3 建议新增文件

```text
Sources/App/
  FaceTimeRecorderApp.swift
  SessionViewModel.swift
  AppDelegate.swift              # 退出/恢复/单实例

Sources/Core/Session/
  SessionCoordinator.swift
  SessionTypes.swift             # StartRequest/SessionSnapshot/SessionWarning
  SessionManifest.swift
  Diagnostics.swift
  RecoveryService.swift
  SingleInstanceGuard.swift

Sources/Core/Permissions/
  PermissionService.swift

Sources/Core/Route/
  OutputRouteManager.swift
  OutputLeaseStore.swift
  DefaultOutputObserver.swift

Sources/Core/Audio/
  SelfTestRunner.swift
  ChannelMap.swift
  RemoteDistributor.swift
  MicrophoneCapture.swift
  AppleVoiceProcessingCapture.swift
  PassthroughCapture.swift
  MicWorker.swift
  MonitorEngine.swift
  MonitorOutputUnit.swift
  MonitorRouteResolver.swift
  AudioLevels.swift

Sources/Core/Record/
  SourceTrackWriter.swift
  AudioTimeline.swift
  TimelineResampler.swift

Sources/Core/Video/
  VideoRecorder.swift
  VideoFrameQueue.swift
  VideoSourceProvider.swift

Sources/Core/Export/
  MixExporter.swift
  MediaValidator.swift
  ToneAnalyzer.swift
```

### 2.4 接口草案

#### SessionCoordinator

```swift
@MainActor
public final class SessionCoordinator: ObservableObject {
    @Published public private(set) var state: RecorderState
    @Published public private(set) var snapshot: SessionSnapshot

    public func start(_ request: StartRequest) async
    public func cancelPreparation() async
    public func stop() async
    public func retry() async
    public func reset() async

    public func setMonitorEnabled(_ enabled: Bool) async
    public func setMonitorVolume(_ volume: Float) async
    public func refreshPreflight() async
    public func recoverLastSession() async
}
```

要求：

- 所有状态变化在主线程发布；实时线程不碰 `@Published`。
- `start` 内部串行执行，重复调用返回 `already_running`。
- `stop` 幂等；重复调用不崩溃。
- `reset` 只在 `finished/failed` 可用。
- 所有 await 的外部操作有超时（prepare 20s 不含用户授权；stop 5s；单个导出 300s，总计 600s）。

#### SessionTypes

```swift
public struct StartRequest: Sendable {
    public var recordRemote: Bool       // 主界面开关 1
    public var recordMicrophone: Bool   // 主界面开关 2
    public var advanced: AdvancedOverrides?   // 默认 nil；高级区才填
}

public struct AdvancedOverrides: Sendable {
    public var microphoneUID: String?
    public var echoCancellation: EchoCancellationMode?
    public var outputDirectory: URL?
}

public enum VideoSourceChoice: Sendable, Equatable {
    case faceTimeWindow(UInt32)
    case mainDisplayFallback
    case audioOnly
}

public struct SessionSnapshot: Sendable {
    public var state: RecorderState
    public var recordRemote: Bool
    public var recordMicrophone: Bool
    public var deliveryStatus: DeliveryStatus   // complete / degraded / failed
    public var elapsedSeconds: Double
    public var remoteLevel: LevelSnapshot
    public var microphoneLevel: LevelSnapshot
    public var diskFreeBytes: Int64
    public var warnings: [SessionWarning]
    public var error: SessionError?
    public var result: RecordingArtifacts?
}

public enum DeliveryStatus: String, Codable, Sendable {
    case complete     // MP4 + MKV（或 M4A + MKA）都有效
    case degraded     // 至少一个可播放产物有效，但另一个缺失
    case failed       // 没有可播放产物
}

public struct RecordingArtifacts: Sendable {
    public var sessionDirectory: URL
    public var mp4URL: URL?          // 默认播放/分享
    public var mkvURL: URL?          // 多轨归档
    public var m4aURL: URL?          // 仅音频默认播放
    public var mkaURL: URL?          // 仅音频多轨归档
    public var remoteWAVURL: URL?
    public var microphoneWAVURL: URL?
    public var takeMovieURL: URL?
    public var diagnosticsURL: URL
    public var deliveryStatus: DeliveryStatus
}

public struct SessionWarning: Codable, Sendable {
    public var code: String
    public var message: String
    public var severity: Severity   // info/warning/critical
}
```

#### PermissionService

```swift
public enum PermissionStatus: String, Codable, Sendable {
    case notDetermined, granted, denied, restricted, unknown
}

public enum SettingsPane: Sendable {
    case microphone, screenAndSystemAudio, sound
}

public protocol PermissionProviding: AnyObject {
    func microphoneStatus() -> PermissionStatus
    func requestMicrophone() async -> PermissionStatus
    func screenStatus() -> PermissionStatus
    func requestScreen() -> Bool
    func openSettings(_ pane: SettingsPane)
}
```

注意：系统音频没有可靠 preflight；不要伪造 `systemAudioStatus`。只暴露 `inferredBySelfTest`。

#### OutputRouteManager

```swift
public struct OutputLeaseRecord: Codable, Sendable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var virtualDeviceUID: String
    public var originalDefaultOutputUID: String?
    public var didChangeDefaultOutput: Bool
    public var processIdentifier: Int32
    public var sessionID: String
}

public enum RouteError: Error, CustomStringConvertible {
    case deviceMissing(String)
    case takeoverFailed(OSStatus)
    case restoreFailed(OSStatus)
    case originalDeviceMissing(String)
    case leaseConflict
}

public protocol OutputRouting: AnyObject {
    func currentDefaultOutputUID() -> String?
    func isVirtualDefault() -> Bool
    func takeover(virtualUID: String, sessionID: String) throws -> OutputLeaseRecord
    func restore(_ lease: OutputLeaseRecord) -> RestoreResult
    func observeDefaultOutputChanges(_ handler: @escaping (String?) -> Void)
}
```

要求：

- `recordRemote=true` 时由 `SessionCoordinator` 自动调用 `takeover`，不等待 UI 确认；`recordRemote=false` 不调用。
- lease 原子写；`fsync`；失败回滚。
- 恢复只在当前默认 == 虚拟设备时执行。
- 用户中途改走时只清 lease，不改系统。
- 应用退出/崩溃恢复入口在 `AppDelegate`，不在 UI；崩溃后下次启动自动恢复，不弹确认框。

#### RemoteDistributor

```swift
public final class RemoteDistributor {
    public init(capture: DeviceTapCapture,
                channelMap: ChannelMap,
                recordRing: OpaquePointer,
                monitorRing: OpaquePointer?)
    public func start()
    public func stop()
    public var stats: RemoteStats { get }   // rms[8], dropped, overflows
}
```

要求：

- 单消费者线程；从 `capture.readBlock` 取块。
- 逐帧映射 FL/FR；不平均。
- `recordRing` 必写；`monitorRing` 可空（监听关闭时丢弃）。
- 统计 8ch RMS/peak；每秒一次，不在实时线程。
- ring 满时递增 dropped，不阻塞。

#### MicrophoneCapture

```swift
public protocol MicrophoneCapturing: AnyObject {
    var status: AECStatus { get }
    var inputFormat: AVAudioFormat { get }
    func start(deviceUID: String?,
               monitorOutputUID: String,
               monitorReference: MonitorReference?) throws
    func stop()
    func setMonitorEnabled(_ enabled: Bool)
}
```

实现：

- `AppleVoiceProcessingCapture`：默认；`AVAudioEngine` + `setVoiceProcessingEnabled(true)`；输出只渲染远端。
- `PassthroughCapture`：AEC 关闭；普通输入。
- `WebRTCAEC3Capture`：不实现，不创建假文件。

#### MonitorEngine

```swift
public final class MonitorEngine {
    public func start(outputUID: String, ring: OpaquePointer) throws
    public func setEnabled(_ enabled: Bool)
    public func stop()
    public var stats: MonitorStats { get }
}
```

要求：

- 输出设备不能是虚拟设备。
- `recordRemote=false` 时不启动监听。
- `outputUID` 必须是接管前物理默认输出；必须显式设置输出 AudioUnit 的当前设备；不得依赖系统默认输出。
- 输出只读 `monitorRing`；不得读取 mic ring。
- `DriftResampler` 参数：target 7200、min 2880、max 14400、ratio ±1%。
- unity gain；不提供软件音量，音量由 macOS 控制。
- 欠载/溢出计数。
- 设备丢失不自动换设备；关闭监听，录制继续。

#### SourceTrackWriter

```swift
public final class SourceTrackWriter {
    public func start(remoteRing: OpaquePointer,
                      micRing: OpaquePointer?,
                      t0HostTime: UInt64,
                      remoteURL: URL,
                      microphoneURL: URL?,
                      sampleRate: Double) throws
    public func stop()
    public var stats: SourceTrackStats { get }
}
```

要求：

- 写 `remote.wav`（2ch/48k/Float32）与 `microphone.wav`（1ch/48k/Float32）。
- 以 `t0` 为起点：晚到写前导静音，早到丢弃；两轨从 0 开始。
- 录制阶段不创建 Mix、不编码 AAC、不调用 FFmpeg。
- `WAVWriter` 只在 worker 调用；失败记录 `audio_writer_failed`。
- 漂移超过 100 ms 时启用 `TimelineResampler`，写 `drift_correction=true`。

#### VideoRecorder

```swift
public final class VideoRecorder {
    public func start(writer: AVAssetWriter, source: VideoSourceChoice, t0HostTime: UInt64) async throws
    public func stop() async
    public var stats: VideoStats { get }
}
```

要求：

- ScreenCaptureKit；默认 `CGMainDisplayID()` 主显示器；高级区才可覆盖窗口/整屏。
- 1920 最长边、30fps、H.264、8 Mbps 目标。
- `movieFragmentInterval = 1s`。
- `take.mov` 只含视频轨；不写音频。
- 帧队列 8 帧；满则丢最旧并计数。
- 窗口断开写 `video_source_lost`，不崩溃。

#### MixExporter

```swift
public struct ExportResult: Sendable {
    public var mp4URL: URL?
    public var mkvURL: URL?
    public var m4aURL: URL?
    public var mkaURL: URL?
    public var deliveryStatus: DeliveryStatus
    public var ffprobeOK: Bool
    public var toneValidationOK: Bool?
}

public final class MixExporter {
    public func export(video: URL?,
                       remoteWAV: URL?,
                       microphoneWAV: URL?,
                       outputDirectory: URL,
                       sessionName: String) async throws -> ExportResult
    public func validate(_ url: URL) async throws -> MediaInfo
}
```

要求：

- FFmpeg 路径 `/opt/homebrew/bin/ffmpeg`；先检查存在。
- 先生成一次临时 `mix.wav`：`remote` stereo + `mic` mono→stereo，`amix normalize=0`，`alimiter=limit=0.95:level=false`；成功后删除，失败保留。
- `remoteWAV=nil` 时 Mix 只含麦克风；`microphoneWAV=nil` 时 Mix 只含远端；两者都 nil 不应调用。
- MP4：1 视频 + 1 条 Mix AAC；默认音轨必须是 Mix。
- MKV：1 视频 + 3 条音轨，顺序 Mix/Remote/Mic，标题固定。
- 仅音频：M4A + MKA。
- `ffprobe` 校验轨道/顺序/时长；失败不得报成功。
- 单产物超时 300s，总计 600s；超时终止进程并保留素材。
- 跑 440/880 双音校验（测试模式/验收），结果写 `toneValidationOK`。

### 2.5 状态机事件

```swift
public enum SessionEvent: Sendable {
    case startRequested(StartRequest)
    case cancelPreparation
    case prepareSucceeded
    case prepareFailed(SessionError)
    case stopRequested
    case fatalError(SessionError)
    case stopCompleted
    case stopTimeout
    case muxSucceeded(MuxResult)
    case muxFailed(SessionError)
    case muxTimeout
    case reset
    case retry
}
```

要求：

- 非法事件忽略/记录，不崩溃。
- 状态只在主线程迁移；实时线程只写 ring/原子计数。
- `preparing` 超时 20s；`stopping` 5s；`muxing` 300s。
- `stop` 幂等；`start` 在非 `idle/finished/failed` 时拒绝。

### 2.6 实时规则

1. 实时回调不分配、不加锁、不做文件 IO、不网络、不日志、不 Objective-C。
2. 只允许：
   - `fr_block_ring_push`
   - `fr_sample_ring_write/peek/advance`
   - 原子计数递增
   - 固定大小 memcpy
3. 不在实时回调调用 `Array.append`、`Data`、`String`、`os_log`、`NSLock`、`FileHandle`。
4. 所有转换/编码/写盘在 worker。
5. 用 Instruments/Time Profiler 检查回调；不得出现 malloc/lock 热点。

### 2.7 构建与自测命令

```sh
cd /Users/lvzhipeng/Developer/FaceTimeRecorder
export PATH=/opt/homebrew/bin:$PATH
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme CoreTests \
  -derivedDataPath build CODE_SIGN_IDENTITY=- test
```

自测：

```sh
build/Build/Products/Debug/AudioProbe list --json
build/Build/Products/Debug/AudioProbe tap \
  --uid com.homepodflow.virtual-audio.surround71.v1 \
  --seconds 5 --tone --wav /tmp/fr-probe.wav --report /tmp/fr-probe.json --all-channels
```

### 2.8 完成定义（Dev）

- [ ] App 可在 Apple Silicon 构建并启动。
- [ ] 主界面只显示标题、两个开关、主按钮、状态行、结果行、同意提示、未验证提示、高级折叠入口。
- [ ] 两个开关默认开；都关时主按钮禁用；录制中开关锁定。
- [ ] `录制对方声音` 开启时自动接管系统输出、自动监听、自动主显示器录制；无确认弹窗。
- [ ] 设备 UID/8ch/48k/Float32 校验。
- [ ] 路由校验先于自检；路由不对阻止开始。
- [ ] 自检 1 秒非静音；失败有 8ch WAV/JSON。
- [ ] 录制/监听解耦；麦克风不进监听。
- [ ] 录制阶段写 `remote.wav` + `microphone.wav` + 视频-only `take.mov`；不混音。
- [ ] 监听默认开启且显式走物理输出；接管系统输出后仍物理出声。
- [ ] 停止后导出 `FaceTime.mp4`（1 视频 + 1 Mix）和 `FaceTime.mkv`（1 视频 + Mix/Remote/Mic）。
- [ ] 440/880 双音测试：MP4 默认音轨同时可测；MKV 三音轨顺序正确。
- [ ] 单产物失败可降级；两产物都失败才 `failed`；WAV 保留。
- [ ] lease 接管/恢复/崩溃恢复。
- [ ] 错误码/诊断 JSON 完整。
- [ ] 无实时回调分配/锁/IO/日志。
- [ ] 不修改旧仓库/驱动。

---
## 3. 给 QA Agent

### 3.1 边界与交付物

**唯一写入范围**：

```text
Tests/**
tests/**
docs/agents/qa/**
```

**交付物**：

- `docs/agents/qa/TEST_PLAN.md`
- `Tests/CoreTests/**` 离线单测
- `tests/**` 真机脚本、测试注入、证据模板
- 缺陷单（可复现步骤、日志、影响范围）
- 不修改产品代码/测试断言；发现缺陷只提交可复现报告

### 3.2 测试层级

| 层级 | 内容 | 执行者 | 是否需要真机 |
|---|---|---|---|
| Unit | ring、通道映射、漂移、状态机、lease、命名、错误码、WAV | QA/Dev | 否 |
| Integration | App 准备/自检/录制/监听/混音导出/恢复 | QA | 是 |
| Hardware | 设备枚举、tap、麦克风、ScreenCaptureKit、默认输出 | QA/总调度 | 是 |
| Human | FaceTime 真人通话、听感、回声、音画同步 | 总调度 + 用户 | 是 |

### 3.3 单元测试矩阵

| ID | 对象 | 前置 | 步骤 | 期望 | 证据 |
|---|---|---|---|---|---|
| UT-01 | `FRBlockRing` | 创建 4 slots × 128 frames | 写入/读出 1..3 块；写满；读空 | 数据完整；满时返回 0；dropped 增加；无崩溃 | `xctest` 日志 |
| UT-02 | `FRSampleRing` | 2ch 1024 frames | write/read/peek/advance | peek 不前进；advance 正确；边界不越界 | `xctest` |
| UT-03 | `ChannelMap` | labels `FL FR FC LFE BL BR SL SR` | 解析 | flIndex=0, frIndex=1, method=.labels | `xctest` |
| UT-04 | `ChannelMap` | labels 缺失/`?` | 解析 | 回退 0/1；warning `channel_map_assumed` | `xctest` |
| UT-05 | `ChannelMap` | 1ch | 解析 | method=.mono；L/R 相同 | `xctest` |
| UT-06 | `DriftResampler` | 输入 150ms 填充 | 连续 process | 欠载/溢出计数；ratio 限幅 ±1%；输出无 NaN | `xctest` |
| UT-07 | 状态机 | idle | 发送非法事件 | 不崩溃；状态不变；记录 ignored | `xctest` |
| UT-08 | 状态机 | recording | stop 两次 | 第二次幂等；不重复导出 | `xctest` |
| UT-09 | 状态机 | preparing | 超时 | 进入 failed；错误码 `prepare_timeout` | `xctest` |
| UT-10 | `OutputLeaseStore` | 临时目录 | 写/读/删除/损坏 JSON | 原子；损坏时安全失败；不误改输出 | `xctest` |
| UT-11 | 文件名 | 同秒两次 | 生成目录/文件 | 追加 `-2`；不覆盖 | `xctest` |
| UT-12 | 错误映射 | 每个错误码 | 映射中文文案 | 无空文案；动作存在 | `xctest` |
| UT-13 | `WAVWriter` | 1ch/8ch | 写 1s；close；读头 | sampleRate/channels/dataBytes 正确 | `xctest` |
| UT-14 | `TimelineResampler` | 48k→48.1k 模拟 | 处理 | 输出帧数接近 host 时间；无爆音（离线检查） | `xctest` |
| UT-15 | `SourceTrackWriter` | t0 晚于首块 100ms | 写 1s | WAV 前导静音 100ms；时长正确；无混音文件 | `xctest`、WAV 头 |
| UT-16 | `MixExporter` | 合成 remote440 + mic880 | 导出 | MP4 1 音频；MKV 3 音频；顺序 Mix/Remote/Mic；两个频率存在 | `ffprobe`、`tone-analysis.json` |

### 3.4 集成/真机矩阵

| ID | 对应 AC | 前置 | 步骤 | 期望 | 证据 |
|---|---|---|---|---|---|
| IT-01 | AC-02 | 驱动安装；GUI | `AudioProbe list --json` | UID/0in/8out/48k/labels 正确 | `list.json` |
| IT-02 | AC-03 | 系统音频授权；默认输出虚拟 | `AudioProbe tap ... --tone --all-channels` | `pcm_detected`；FL/FR RMS≥0.005；退出 0 | `report.json`、WAV |
| IT-03 | AC-04 | ssh 无 TCC | 同 IT-02 | `all_zero_pcm`；退出 10 | `report.json` |
| IT-04 | AC-05 | 虚拟设备缺失/模拟自动接管失败 | App 开始 | `device_missing`/`output_takeover_failed`；无媒体文件 | 截图、诊断 |
| IT-05 | AC-06 | 系统音频拒绝 | App 开始 | 自检失败；不生成主文件；8ch WAV | 截图、WAV、诊断 |
| IT-06 | AC-07 | 麦克风拒绝 | 录 30s | MP4 1v+1a（Mix=远端）；MKV 1v+2a（Mix/Remote）；无麦克风 WAV | `ffprobe`、截图 |
| IT-07 | AC-08 | 屏幕拒绝 | 仅声音 30s | M4A 1 音频（Mix）；MKA 3 音频（Mix/Remote/Mic）；无视频 | `ffprobe`、截图 |
| IT-08 | AC-09 | 全部授权 | 录 60s | MP4 1v+1a（Mix）；MKV 1v+3a（Mix/Remote/Mic）；WAV 存在；默认播放 MP4 能听双方；时长差≤0.5s | `ffprobe`、听感、WAV |
| IT-09 | AC-10 | 录制中 | 高级区调整监听音量 3 次 | 录制不断；无 >100ms 缺口 | 诊断、听感 |
| IT-10 | AC-11 | 耳机；远端静音 | 麦克风说话 20s | 耳机无自己声音；mic 轨有信号 | 听感、诊断 |
| IT-11 | AC-12 | 录制对方开 | 录 20s 停止 | 自动接管/自动恢复；lease 删除 | before/after、lease |
| IT-12 | AC-13 | 接管录制中 | `kill -9`；重启 | stale lease 自动恢复原输出，不弹确认框 | 截图、lease |
| IT-13 | AC-14 | 接管录制中 | 手动改默认输出；停止 | 警告；不覆盖；lease 清理 | 截图、诊断 |
| IT-14 | AC-15 | 录制中 | 磁盘降到 <500MB | 自动停止；保留素材 | 诊断、文件 |
| IT-15 | AC-16 | FFmpeg 缺失 | 录 20s 停止 | `mux_tool_missing`；不报 MP4/MKV 成功；WAV/`take.mov` 保留 | 截图、`ffprobe` |
| IT-16 | AC-17 | 录制中 | 设备消失 | 安全停止；`device_lost`；不崩溃 | 诊断 |
| IT-17 | AC-18 | 正常 | 15min 合成测试 | 无 ring 溢出；漂移≤100ms；可播放 | 诊断、`ffprobe` |
| IT-18 | AC-19 | 真人 FaceTime | 5min 双方说话 | 默认双击 MP4 能同时听到双方；MKV 三音轨独立；同步 | `human-note.md`、`ffprobe` |
| IT-19 | AC-20 | 真人 FaceTime | 15min | 端到端；MP4 默认播放双方；MKV 三音轨；无未解释丢帧；≤100ms | `human-note.md`、诊断 |
| IT-20 | AC-21 | 屏幕权限 | 保持默认录主显示器 | 视频来自主显示器；无需选窗口 | 抽帧、截图 |
| IT-21 | AC-22 | 正常 | 同秒两次录制 | 不覆盖；`-2` | 目录列表 |
| IT-22 | AC-23 | 导出中 | kill FFmpeg/App | 可从 `take.mov` + WAV 恢复；不丢素材 | 截图、`ffprobe` |
| IT-23 | AC-24 | 已录制 | 开第二实例 | 激活已有；不并发 | 截图、进程 |
| IT-24 | AC-25 | 首次 | 查看主界面并开始 | 常驻“请确保通话对方同意录音。”；不弹额外确认框；点击开始即确认 | 截图 |
| IT-25 | AC-26 | 录制中 | 退出→停止并保存 | 正常收尾；输出恢复 | 截图、`ffprobe` |
| IT-26 | AC-27 | 录制中 | 睡眠 30s | 阻止或安全收尾；无损坏主文件 | 诊断、截图 |
| IT-27 | AC-28 | 旧仓库 | `git status --short` | 无本项目修改 | `git-status.txt` |
| IT-28 | AC-29 | 正常 | 检查源轨 WAV | `remote.wav` 2ch、`microphone.wav` 1ch；可读；时长差≤0.5s | `wav-info.json` |
| IT-29 | AC-30 | P1 | 8ch 诊断 | 8ch WAV 正确 | `wav-info.json` |
| IT-30 | AC-31 | 合成 remote440 + mic880 + 视频 | 用同一导出器生成 MP4/MKV；分析 MP4 默认音轨 | MP4 1 音频；440/880 均 ≥-30 dBFS；MKV 3 音频顺序正确 | `tone-analysis.json`、`ffprobe` |
| IT-31 | AC-32 | 虚拟设备 440；物理扬声器 880 靠近麦克风 | 录 15s；默认播放 MP4 | MP4 同时可听/测 440+880；Remote 轨主峰 440；Mic 轨主峰 880 | `tone-analysis.json`、`human-note.md` |
| IT-32 | AC-33 | 接管系统输出到虚拟；物理监听可用 | 录 20s；播放系统音乐；对麦克风说话 | 监听从物理设备出声；`monitorOutputUID != virtualUID`；耳机无自己声音 | 诊断、听感、截图 |
| IT-33 | AC-34 | 正常 20s 素材 | 分别注入 MP4/MKV 导出失败 | 单产物失败时 `finished` 降级并标缺失；两产物失败 `failed`；WAV 保留 | 截图、`manifest.json`、诊断 |
| IT-34 | AC-35 | 首次启动 | 打开主界面 | 只有标题/两个开关/主按钮/状态行/同意提示/未验证提示/高级入口；无设备/窗口/音量/权限卡/FFmpeg/8ch | 截图、可访问性树 |
| IT-35 | AC-36 | 主界面 | 展开/收起高级 | 高级默认收起；展开有设备/音量/权限/诊断/日志/FFmpeg/8ch；收起不影响主流程 | 截图 |
| IT-36 | AC-37 | 默认输出内置；两项开关默认开 | 开始 20s 停止 | 无确认弹窗；自动切虚拟、自动监听、自动恢复；结果“双方声音” | 录屏、lease、诊断、`ffprobe` |
| IT-37 | AC-38 | 主界面 | 四种开关组合 | 开/开双方；开/关仅对方；关/开不接管仅麦克风；关/关禁用；录制中锁定 | 截图、`ffprobe` |
| IT-38 | AC-39 | 录制完成 | 查看结果行 | “已保存 FaceTime.mp4（双方声音）”+Finder；MKV 只在高级 | 截图、Finder |
| IT-39 | AC-40 | 录制中 | 点击两个开关 | 不可切换；需停止后重开 | 截图 |

### 3.5 权限拒绝矩阵

按 PRD 6.1 执行，至少覆盖：

1. 麦克风拒绝 + 系统音频/屏幕通过 → MP4（Mix=远端）+ MKV（Mix/Remote）。
2. 系统音频拒绝 + 其他通过 → 阻止，无主文件。
3. 屏幕拒绝 + 其他通过 → M4A（Mix）+ MKA（Mix/Remote/Mic）。
4. 屏幕+麦克风拒绝 → M4A（远端）+ MKA（Mix/Remote）。
5. 系统音频+屏幕拒绝 → 阻止。
6. 监听输出不可用 → 开始前阻止或运行中回退内置扬声器；仍失败则关闭监听、录制继续。

每条证据包含：系统设置截图、App 状态截图、`diagnostics.json`、`ffprobe`（如有文件）。

### 3.6 故障注入

| 注入 | 方法 | 期望 |
|---|---|---|
| 无 TCC 全零 | ssh 启动 AudioProbe | `all_zero_pcm`，不是成功 |
| 自动接管失败 | 测试钩子让 `setDefaultOutput` 返回错误 | `output_takeover_failed`；恢复 lease；不开始 |
| 自检静音 | 撤销系统音频权限 | `permission_audio_capture_denied_or_silent` |
| ring 溢出 | 测试钩子暂停消费者/注入大块 | `ring_overflow` 计数；实时不阻塞 |
| 监听 underrun | 测试钩子延迟输出 | `monitor_underrun` 计数；录制继续 |
| 无物理监听输出 | 断开耳机/禁用内置扬声器 | 监听开启时 `monitor_output_missing`；关闭监听可继续 |
| 磁盘低 | 小容量卷/测试注入 | 自动停止 |
| FFmpeg 缺失 | 临时改名 | `mux_tool_missing`；WAV/`take.mov` 保留 |
| MP4 导出失败 | 注入无效输出/改权限 | `mp4_export_failed`；MKV 可用时降级 |
| MKV 导出失败 | 注入无效输出/改权限 | `mkv_export_failed`；MP4 可用时降级 |
| 混音失败 | 注入无效 filter/损坏 WAV | `mix_failed`；保留 WAV |
| 视频源断开 | 关闭 FaceTime 窗口 | `video_source_lost`；音频继续 |
| 设备消失 | 卸载/重载驱动（测试机） | `device_lost`；安全停止 |
| 崩溃 | `kill -9` 录制中/导出中 | 重启恢复；不覆盖 |
| 睡眠 | 合盖/`pmset sleepnow` | 阻止或安全收尾 |

### 3.7 真人 FaceTime 测试脚本（G1/G6）

**前置**：

- 两台设备（Mac + iPhone/iPad 或其他 Mac），双方同意录音。
- 被测 Mac 安装 App，HomePod Flow 驱动，系统音频/屏幕/麦克风已授权。
- 耳机或内置扬声器；记录设备型号、macOS 版本、App 构建号。
- 先按 IT-02 确认 tap 非零。

**步骤**：

1. 发起 FaceTime 视频通话，接通。
2. 启动 App，保持两个开关默认开启，点击“开始录制”；不选择窗口/显示器/设备。
3. 双方各说话 30 秒；中间静音 10 秒；再各说 30 秒。
4. 录制 5 分钟；期间关闭/开启监听一次；调整一次监听音量。
5. 停止并保存；等待 MP4 与 MKV 生成。
6. 先双击 MP4，用默认播放器直接听：应同时听到双方。
7. 再用支持多轨的播放器打开 MKV，分别独奏 Mix/远端/麦克风轨；检查：
   - 远端轨是否有对方声音；
   - 麦克风轨是否有本地声音；
   - 两条轨是否同步；
   - 是否有持续回声/金属声/断音；
   - 文件是否能被 `ffprobe` 读取。
8. 15 分钟版本重复一次，包含一次窗口移动/缩放、一次静音段。

**通过标准**：

- MP4 默认播放同时包含双方声音且可辨认；
- MKV 的 Mix/Remote/Mic 三音轨独立可播；
- 麦克风轨包含本地声音；
- 三音轨时间差 ≤100 ms；
- 无持续回声；
- 状态行无红色失败；
- 证据齐全。

**证据**：

```text
tests/evidence/2026-11-07/IT-18/
  human-note.md      # 日期、设备、系统、App 版本、通话时长、听感
  ffprobe-mp4.json
  ffprobe-mkv.json
  tone-analysis.json
  diagnostics.json
  recording.sha256
```

**状态**：在完成前，所有对外文案保持“远端音频：待真人通话验证”。

### 3.8 证据规范

- 目录：`tests/evidence/YYYY-MM-DD/<case-id>/`
- 必含：`command.txt`、`exit_code.txt`、`stdout.log`、`stderr.log`
- 音频：`report.json`、WAV、`ffprobe.json`
- 界面：PNG 截图
- 听感：`human-note.md`（谁、何时、设备、听感、结论）
- 大文件不入 Git；记录路径/哈希/大小。
- 失败证据同样归档；不得只保留成功。

### 3.9 缺陷单模板

```text
标题：[P0/P1] <现象>
环境：macOS/芯片/App 构建/设备
前置：
步骤：
期望：
实际：
复现率：
证据：日志/截图/诊断/文件
影响：数据丢失/静音/崩溃/体验
初步定位：权限/路由/格式/时钟/混音导出/UI
```

### 3.10 判定规则

1. P0 AC 全部有证据才算 G6 通过。
2. IT-18/IT-19 未通过，不得改“待验证”徽章。
3. 任何“部分成功”必须按降级记录；不得合并为成功。
4. 失败用例不得删除证据；修复后保留旧证据并新增复测证据。
5. 测试断言不得为了让代码通过而修改。

---
## 4. 需要总调度裁决的问题

> 下列问题未裁决前，下游不得自行改变产品范围/验收口径。产品建议仅供参考。

### 4.1 已登记决策

| ID | 问题 | 产品建议 | 影响 | 状态 |
|---|---|---|---|---|
| D-003 | 是否确认默认 Apple VPIO + 可替换 AEC 接口，不引入 AEC3？ | 确认。AEC3 当前不可构建；G5 前只写“可能降低回声” | 技术方案、UI、G5 | 待总调度确认 |
| D-004 | 默认输出接管策略？ | **已被极简模式覆盖**：`录制对方声音` 开启时自动接管，不弹确认框；关闭时不接管 | 交互、权限、恢复 | 已覆盖 |
| D-005 | 8ch 取声道是否按标签 FL/FR？ | 确认；标签不可用才回退 0/1，写 `channel_map_assumed` | 音频质量、诊断 | 待总调度确认 |
| D-006 | V1 是否采用极简主界面？ | **已确认**：两个开关 + 一个主按钮 + 状态/结果/同意提示；其余进高级 | UI/交互/验收 | 已确认 |

### 4.2 产品范围问题

| ID | 问题 | 产品建议 | 影响 | 需要谁 |
|---|---|---|---|---|
| Q-001 | “仅音频”降级是否纳入 P0？ | 纳入；屏幕权限拒绝很常见 | 状态机、导出、验收 | 总调度 |
| Q-002 | `remote.wav`/`microphone.wav` 是否默认保留？ | 确认默认保留；这是录制阶段不混音的源轨，也是恢复导出基础 | 存储、导出 | 总调度 |
| Q-003 | FFmpeg 缺失时是否允许只录中间文件？ | P0 阻止并提示安装；不提供普通用户“只录 WAV/take.mov”模式 | 安装门槛 | 总调度 |
| Q-004 | 8ch 原始 WAV 是否默认开启？ | 否；失败时保存 1 秒自检 8ch 即可 | 存储、诊断 | 总调度 |
| Q-005 | FL 有信号/FR 静音时是否默认复制双声道？ | 否；保留原样，P1 开关 | 听感、真实性 | 总调度 |
| Q-006 | 最低系统是否保持 macOS 15？ | 保持 15.0；只在 26.5.2 真机验收 | 兼容性 | 总调度 |
| Q-007 | 验证徽章移除标准？ | 5 分钟 + 15 分钟真人通话；MP4 默认播放双方；MKV 三音轨；同步；无持续回声；签字 | 发布文案 | 总调度 + 用户 |
| Q-008 | 是否允许“仅画面、无声音”模式？ | P2；P0 不做 | 范围 | 总调度 |
| Q-009 | 录制中睡眠是阻止还是允许后收尾？ | 阻止空闲睡眠；合盖睡眠唤醒后收尾并警告 | 稳定性 | 总调度 |
| Q-010 | 监听默认开启是否合适？ | `录制对方声音` 开启时自动开启；关闭时不监听；主界面不提供开关 | 体验 | 总调度 |
| Q-011 | Mix 默认增益/限幅？ | Remote=1.0、Mic=1.0、limiter=0.95；以 440/880 和真人听感为准 | 混音质量 | 总调度 |
| Q-012 | MP4 失败但 MKV 可用时状态？ | `finished` 降级并明确“MP4 缺失”，不丢弃可用素材 | 状态/UI | 总调度 |

### 4.3 技术实现问题

| ID | 问题 | 建议/验证方式 | 影响 |
|---|---|---|---|
| T-001 | VPIO 能否在默认输出=虚拟设备时，把 outputNode 路由到物理监听设备并同时采集麦克风？ | Phase 2 spike；失败走 aggregate 或标 `AEC unavailable` | G5、监听、AEC |
| T-002 | 视频-only `take.mov` + WAV 导出 MP4/MKV 在 macOS 26.5.2 是否稳定？ | Phase 4 验证；失败允许视频重编码 | G4 |
| T-003 | ScreenCaptureKit 捕获 FaceTime 窗口是否受限？ | AC-21；失败退回整屏 | 视频 |
| T-004 | FFmpeg `amix` + `alimiter` 的 MP4/MKV 轨道顺序与音画同步是否稳定？ | AC-09/31 `ffprobe` + tone probe；失败调 filter/重编码 | 混音/导出 |
| T-005 | `kAudioDevicePropertyPreferredChannelLayout` 不可用时如何回退？ | 0/1 + `channel_map_assumed`；自检 FL/FR | 音频 |
| T-006 | 蓝牙耳机延迟/AEC 参考如何处理？ | G5 记录；UI 提示；允许换输出 | 体验 |
| T-007 | 15/60 分钟 AVAssetWriter 文件碎片/大小？ | AC-18/AC-20；`movieFragmentInterval=1s` | 长录 |
| T-008 | MP4 单音频轨与 MKV 三音轨的默认播放器兼容性？ | AC-09/19/31 用系统播放器 + ffprobe | 交付 |

### 4.4 需要总调度签字的发布门禁

1. AC-19（5 分钟真人 FaceTime）通过。
2. AC-20（15 分钟真人 FaceTime）通过。
3. AC-13（崩溃恢复 lease）通过。
4. AC-16（FFmpeg 失败降级）通过。
5. AC-28（旧仓库/驱动未修改）通过。
6. AC-31（440/880 双音）与 AC-33（监听物理输出）通过。
7. AC-34（MP4/MKV 单产物失败降级）通过。
8. AC-35~AC-40（极简主界面、高级折叠、自动接管、开关组合、结果行、录制锁定）通过。
9. UI/Dev/QA 文档齐全，STATUS 更新。
10. 总调度书面同意移除“远端音频：待真人通话验证”提示。

---

## 5. 交接检查清单

### 5.1 产品 → UI

- [x] 用户画像/3 场景。
- [x] P0/P1/P2/Non-goals。
- [x] 状态机与界面状态矩阵。
- [x] 自动授权与拒绝降级（主界面不显示权限卡片）。
- [x] 输出接管/恢复交互。
- [x] 中文文案清单。
- [x] 主界面状态/结果行要求。
- [x] V1 极简主界面与高级折叠区。
- [x] “待验证”徽章规则。
- [ ] UI Agent 确认可实现的 SwiftUI 结构。

### 5.2 产品 → Dev

- [x] 模块图/数据流。
- [x] 线程/缓冲/SPSC 规则。
- [x] 8ch→stereo 策略。
- [x] 自检阈值/错误码。
- [x] AEC 接口与 AEC3 边界。
- [x] 文件布局/清理。
- [x] 分阶段命令。
- [x] 写入范围/只读文件。
- [ ] Dev Agent 确认接口草案无冲突。

### 5.3 产品 → QA

- [x] 验收标准 AC-01~AC-40。
- [x] 单元/集成/真机矩阵。
- [x] 权限拒绝矩阵。
- [x] 故障注入/崩溃/长录。
- [x] 真人 FaceTime 脚本。
- [x] 证据规范/缺陷模板。
- [ ] QA Agent 确认测试可执行、证据可归档。

### 5.4 全局

- [x] 不改旧仓库/驱动。
- [x] 复用已安装虚拟声卡。
- [x] 不依赖 HomePod/AirPlay。
- [x] 不需要额外虚拟麦克风。
- [x] 录制/监听解耦；监听不回放麦克风。
- [x] 录制阶段不混音；停止后导出 MP4（Mix）+ MKV（Mix/Remote/Mic）。
- [x] 监听默认开启且永远走物理输出。
- [x] 440/880 双音验收。
- [x] V1 极简主界面、自动接管、自动监听、主显示器录制。
- [x] 优先 Apple 官方 API；Apple Silicon 可构建。
- [x] FaceTime 未验证前只写“待验证”。
- [ ] 总调度确认 D-003/D-004/D-005 与 Q/T 问题。
- [ ] STATUS 更新为“产品交付完成，等待 UI/Dev/QA 开工”。

---

## 6. 变更记录

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| 1.0 | 2026-11-07 | 首版：UI/Dev/QA 交接、接口草案、测试矩阵、开放问题 | 产品 Agent |
| 1.1 | 2026-11-07 | 双产物 MP4/MKV、源轨 WAV、导出阶段混音、物理监听、440/880 测试 | 产品 Agent |
| 1.2 | 2026-11-07 | V1 极简主界面；高级折叠；自动接管/监听/主显示器；StartRequest 两开关 | 产品 Agent |
