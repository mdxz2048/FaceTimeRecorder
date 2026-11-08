# FaceTime Recorder 技术方案（TECH_PLAN）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.2 |
| 日期 | 2026-11-07 |
| 作者 | 产品 Agent |
| 状态 | 待总调度确认；与 `PRD.md` 配套，冲突时以 PRD 的产品规则为准 |
| Mac 构建路径 | `/Users/lvzhipeng/Developer/FaceTimeRecorder` |
| 目标平台 | macOS 15.0+，Apple Silicon（arm64）优先；G0 真机为 macOS 26.5.2 (25F84) |
| 工具链 | Xcode 26.6 (17F113)，Swift 6 工具链，xcodegen 2.45.4，ffmpeg 9.0.2 |
| 关键事实来源 | `docs/audit/G0_AUDIT.md`、`docs/agents/CHARTER.md`、`docs/agents/product/PRD.md` |

> **不可逾越的事实**
>
> 1. `HomePod Flow Audio`（UID `com.homepodflow.virtual-audio.surround71.v1`）只有输出：8ch、48 kHz、Float32 packed interleaved，0 个输入 stream、0 个输入通道。
> 2. 驱动 `WriteMix` 是纯 sink，不保留 PCM，不提供 Loopback 输入，不提供共享缓冲/客户端时间戳。
> 3. 远端只能通过 device tap 采集；无 TCC 时回调正常但所有样本为 0。
> 4. FaceTime 使用系统默认输出；默认输出不是虚拟设备时，远端不会进入 tap。
> 5. 不改驱动、不改旧仓库、不安装额外虚拟麦克风、不依赖 HomePod/AirPlay。
> 6. WebRTC AEC3 在本机没有可构建依赖；不得假装已实现。

---

## 1. 设计目标与约束

### 1.1 目标

1. 在 Apple Silicon Mac 上构建独立 SwiftUI App，录制：
   - 远端：从虚拟设备 tap 读取，按 FL/FR 降混为立体声；
   - 本地：麦克风单声道；
   - 视频：ScreenCaptureKit 捕获 FaceTime 窗口或整个屏幕；
   - 监听：把远端送到**物理输出**，麦克风不进入监听；
   - 源轨：录制阶段写 `remote.wav`（立体声）与 `microphone.wav`（单声道），不混音；
   - 交付：停止后导出 `FaceTime.mp4`（H.264 + 双方混音 AAC）和 `FaceTime.mkv`（H.264 + Mix/Remote/Mic 三音轨）。
2. 录制与监听解耦：macOS 系统音量/高级 AEC 开关变化不影响源轨写入。
3. 所有实时回调满足：不分配、不加锁、不做文件 I/O、不做网络、不写日志。
4. 任何“成功”有 `ffprobe`/WAV/JSON/日志证据；不伪造。
5. 失败可解释：权限、路由、格式、设备忙、时钟不连续、磁盘、混音、导出。

### 1.2 硬约束

| 约束 | 技术含义 |
|---|---|
| 复用已安装虚拟声卡 | 只读设备属性；创建私有 tap/aggregate；不写驱动 |
| 不改驱动 | 不新增输入 stream、不做 Loopback、不改 `FlowVirtualAudio.c` |
| 不依赖 HomePod/AirPlay | 采集路径只依赖 Core Audio 设备与 tap |
| 不需要额外虚拟麦克风 | 麦克风直接用物理输入设备 |
| 录制与监听解耦 | 远端 fan-out 到 record ring 与 monitor ring；监听不参与源轨写入 |
| 监听不回放麦克风 | monitor 总线只接收远端；mic 总线没有到 output 的边 |
| 监听永远走物理输出 | 监听设备解析排除虚拟声卡；接管系统输出后仍显式绑定物理设备 |
| 录制阶段不混音 | 只写 `remote.wav`/`microphone.wav`；Mix 只在停止后的 FFmpeg 导出阶段生成 |
| 优先 Apple 官方 API | Core Audio HAL、ScreenCaptureKit、AVFoundation、AVAudioEngine/VPIO、FFmpeg 仅做混音/导出 |
| Apple Silicon 必须能构建 | arm64 原生；不使用仅 x86 的第三方二进制 |
| 不夸大 | FaceTime 真人通话未验证前，UI/文档只写“待验证” |

### 1.3 V1 极简主界面与自动决策（不是临时 demo）

V1 主界面只保留：

1. 标题 `FaceTime 录音`。
2. 两个大开关：`录制对方声音`（默认开）、`录制我的麦克风`（默认开）。
3. 一个主按钮：`开始录制` / `停止并保存`。
4. 一行状态：`空闲` / `准备中` / `录制中 MM:SS` / `正在生成视频` / `完成` / `失败：<原因>`。
5. 完成后一行：`已保存 FaceTime.mp4（双方声音）` + `在 Finder 中显示`。
6. 常驻同意提示：`请确保通话对方同意录音。`
7. 远端开关下一行说明：`会自动切换系统声音并在停止后恢复。`
8. 底部固定：`远端音频：待真人通话验证`。
9. `高级` 折叠入口。

以下内容全部收进默认折叠的 `高级`：设备状态、麦克风选择、监听状态（只读）、权限详情、诊断、日志、FFmpeg/8ch 徽章、视频源状态（只读）。监听设备/音量、窗口/显示器选择器不进 UI。

自动决策：

| 输入 | 自动行为 |
|---|---|
| `recordRemote=true` | 自动选 `HomePod Flow Audio`；**点开始时**自动接管系统默认输出；自动开启监听并固定到接管前物理默认输出；执行 tap 自检；导出 Mix/Remote |
| `recordRemote=false` | 不接管、不监听、不创建 tap；不执行远端自检 |
| `recordMicrophone=true` | 自动选系统默认输入；AEC 默认关闭，高级可开 Apple VPIO；写 `microphone.wav` |
| `recordMicrophone=false` | 不创建麦克风链路；Mix 只含远端（若远端开） |
| 两者都 false | 主按钮禁用，状态“请至少开启一项” |
| 视频 | 自动查找 `appName=FaceTime` 窗口；找不到回退 `CGMainDisplayID()` 主显示器并在状态行说明；无选择器 |

`StartRequest` 在 V1 只要求两个布尔值；高级覆盖项使用单独的 `AdvancedOverrides`，默认 nil。后续章节中出现的窗口选择、显示器选择、监听开关、音量滑杆、权限卡片，都是高级区/内部规范或只读状态，不是主界面。

---

## 2. 模块图

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         FaceTimeRecorder App                        │
│  MinimalRecorderView / AdvancedSettingsView                          │
│  ── SessionViewModel ── SessionCoordinator (@MainActor)             │
│  PermissionService   OutputRouteManager   MonitorRouteResolver       │
│  RecoveryService                                                   │
└───────────────┬─────────────────────────────────────────────────────┘
                │ 命令 / 状态 / 诊断事件
┌───────────────▼─────────────────────────────────────────────────────┐
│                              Core                                   │
│                                                                     │
│  DeviceTapCapture ──► FRBlockRing(8ch) ──► RemoteDistributor        │
│       (HAL IOProc)                          │       │               │
│                                             │       └──► MonitorRing│
│                                             ▼               │       │
│                                      RemoteRecordRing       │       │
│                                                             ▼       │
│  MicrophoneCapture ──► FRBlockRing(mic) ──► MicWorker ──► DriftResampler
│       (VPIO/AVAudioEngine)                    │              │       │
│                                               ▼              ▼       │
│                                        MicRecordRing    MonitorOutput │
│                                               │          (物理设备)   │
│                                               ▼                      │
│                                      SourceTrackWriter              │
│                                      ├─ remote.wav                   │
│                                      └─ microphone.wav               │
│                                                                     │
│  ScreenCaptureKit ──► VideoFrameQueue ──► take.mov (video-only)      │
│                                                                     │
│  take.mov + remote.wav + microphone.wav                             │
│        └──► Exporter(FFmpeg) ──► FaceTime.mp4 (Mix)                 │
│                              └─► FaceTime.mkv (Mix/Remote/Mic)      │
│                              └─► Validator(ffprobe + tone probe)    │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.1 模块职责

| 模块 | 职责 | 不负责 |
|---|---|---|
| `App/UI` | 极简主界面（两开关/按钮/状态/结果）与高级折叠区 | 音频/视频实时处理 |
| `SessionCoordinator` | 状态机、生命周期、超时、恢复入口 | 直接操作 HAL |
| `PermissionService` | 麦克风/屏幕 preflight、打开设置、授权后刷新 | 系统音频“假 preflight” |
| `OutputRouteManager` | 默认输出读取/接管/恢复、lease | 音频采集、监听设备选择 |
| `MonitorRouteResolver` | 锁定接管前的物理默认输出；排除虚拟设备；不提供选择/回退 | 修改系统默认输出 |
| `DeviceTapCapture` | 复用现有 `Sources/Core/Capture.swift`；tap + aggregate + IOProc | 声道映射、文件写入 |
| `RemoteDistributor` | 8ch 校验、FL/FR 映射、RMS 统计、fan-out | 重采样、混音、编码 |
| `MicrophoneCapture` | VPIO/AVAudioEngine 采集、AEC 开关、mic ring | 监听 |
| `MonitorEngine` | 远端 ring → 固定物理输出；unity gain；underrun 统计 | 录制写文件、混音、软件音量 |
| `SourceTrackWriter` | `remote.wav`/`microphone.wav` 写入、前导静音、漂移校正 | 混音 |
| `VideoRecorder` | 自动 FaceTime 窗口、回退主显示器、帧队列、`take.mov` 视频轨 | 音频、窗口选择 UI |
| `MixExporter` | FFmpeg 混音、MP4/MKV/M4A/MKA 导出 | 采集 |
| `MediaValidator` | ffprobe 轨道/顺序/时长校验；双音频率校验 | 采集 |
| `ManifestWriter` | 原子写 `manifest.json` | UI |
| `DiagnosticsWriter` | 汇总 `diagnostics.json` | 实时日志 |
| `OutputLeaseStore` | `output-lease.json` 原子读写 | 修改系统输出 |
| `CRing` | 现有 C SPSC ring | Swift 对象生命周期 |

### 2.2 与现有代码的复用关系

| 现有文件 | 复用方式 | 注意 |
|---|---|---|
| `Sources/Core/Capture.swift` | 直接复用 `DeviceTapCapture`、`CapturedBlock`、`TapDescriptor` | 它已创建 64×16,384 的 `FRBlockRing`；tap 格式必须 8ch Float32 |
| `Sources/Core/CoreAudioSupport.swift` | 复用 `AudioDeviceCatalog`、`CA`、`setDefaultOutput`、`channelLabels` | 默认输出/设备属性只读；不要在实时回调调用 |
| `Sources/Core/Models.swift` | 复用 `RecorderConfiguration`、`RecorderState`、`RecordingResult`、`RecorderPaths`、`OutputLease` | 新增 `RecordingArtifacts`/`DeliveryStatus`，不要破坏旧字段；P0 填 `mp4URL`/`mkvURL`/WAV |
| `Sources/Core/DriftResampler.swift` | 监听路径直接复用 | 目前是 stereo；麦克风单声道需 `AVAudioConverter` 或扩展为单声道 |
| `Sources/Core/TonePlayer.swift` | 自检音、440 Hz 测试音 | 只向虚拟设备/物理设备播放；不参与录音 |
| `Sources/Core/WAVWriter.swift` | `remote.wav`/`microphone.wav`/自检 8ch | 只在 worker 写；不在实时回调 |
| `Sources/CRing/*` | 所有音频 ring | 保持 SPSC；不要多生产者/多消费者 |
| `Sources/Probe/main.swift` | G1/G3 证据工具 | 不改；App 不复用 CLI 主循环 |
| `Scripts/build.sh` / `package-probe.sh` | 构建/打包 | 保持路径与 scheme 名 |

---

## 3. 数据流

### 3.1 远端：device tap → 8ch → stereo → WAV/监听

```text
FaceTime
  │ 系统默认输出
  ▼
HomePod Flow Audio (8ch/48k/Float32, 仅输出)
  │ CATapDescription(andDeviceUID:)
  ▼
私有 aggregate（主时钟=独立物理输出）
  │ HAL IOProc（可变帧数，约 100 次/秒；buffer 15..4096 由 coreaudiod 管理）
  ▼
FRBlockRing<8ch>（64 slots × 16,384 frames）
  │ RemoteDistributor（单消费者线程）
  ├─ 校验 8ch / 标签 / FL/FR
  ├─ 逐帧映射：out[2i]=in[8i+FL], out[2i+1]=in[8i+FR]
  ├─ 每 1 秒统计 8ch RMS/peak（诊断）
  ├─ push → RemoteRecordRing<2ch>
  └─ push → MonitorRing<2ch>
        │
        ├─ SourceTrackWriter → remote.wav（48k stereo Float32）
        └─ MonitorRenderCallback → DriftResampler → 物理输出
```

关键点：

1. tap 的 IOProc 只做一件事：把 `AudioBufferList` 的 Float32 数据整块 push 到 `FRBlockRing`。不映射、不统计、不分配。
2. `DeviceTapCapture.readBlock` 返回 `CapturedBlock`，包含 `hostTime`、`sampleTime`、`timestampFlags`、`sequence`、`droppedBefore`。分发包必须保留这些元数据。
3. tap 帧数可变，不能假定 512；`FRBlockRing` 的 `max_frames=16384` 足够覆盖 15..4096 的单次回调。
4. tap 格式必须与设备输出格式一致：8ch、48 kHz、Float32 packed interleaved。若不一致，准备阶段报 `format_unsupported`，不要“猜”转换。
5. 远端录制与监听来自同一个 `RemoteDistributor` 输出，但写入不同 ring；监听关闭时只让 monitor 输出静音，不影响 `RemoteRecordRing` 和 `remote.wav`。
6. 录制阶段不生成 Mix；`remote.wav` 是远端源轨。
7. `recordRemote=false` 时整条远端链路不创建：不接管、不监听、不创建 tap/aggregate、不写 `remote.wav`。

### 3.2 麦克风：VPIO → 单声道 → WAV

```text
物理麦克风（内置 1ch/44.1k 或 48k；外接可变）
  │ Apple VoiceProcessingIO（AEC 开启时）
  ▼
AVAudioEngine input tap / VPIO input callback
  │ 只拷贝到 FRBlockRing<mic>，记录 hostTime
  ▼
MicWorker（非实时）
  ├─ 若硬件 44.1k：AVAudioConverter → 48k mono Float32
  ├─ 若硬件 48k：直通
  ├─ push → MicRecordRing<1ch>
  └─ 统计 RMS/peak/clipping
        │
        ▼
SourceTrackWriter → microphone.wav（48k mono Float32）
```

关键点：

1. `recordMicrophone=true` 时自动选系统默认输入；AEC 默认关闭（普通输入）；高级区可开 Apple VoiceProcessingIO。
2. 麦克风源轨永远单声道；不复制到监听。
3. 采样率转换在 worker 做，不在实时回调；`AVAudioConverter` 在准备阶段创建并预热。
4. 若 VPIO 无法同时满足“选定物理监听输出 + 选定麦克风输入”，Phase 2 做 spike；失败时 AEC 标 `unavailable`，UI 建议耳机，不得宣称已消除回声。
5. 麦克风权限被拒：不创建麦克风链路；`microphone.wav` 不存在；MP4 的 Mix 只含远端，MKV 只有 Mix/Remote 两条音轨。
6. `recordMicrophone=false` 时不创建麦克风链路、不选输入、不写 `microphone.wav`；Mix 只含远端。

### 3.3 监听：远端 → 物理输出（永远不经过虚拟设备）

```text
MonitorRing<2ch/48k>
  │ MonitorRenderCallback（实时）
  ▼
DriftResampler（目标 150 ms，最小 60 ms，最大 300 ms，ratio ±1%）
  ▼
物理输出 AudioUnit（显式绑定设备）
  │ 客户端格式 48k stereo Float32；设备侧由 AUHAL 转换
  ▼
MacBook 扬声器 / 耳机
```

规则：

1. `MonitorRouteResolver` 只锁定“接管前的那台物理默认输出”；不提供用户选择、不做别的设备回退；虚拟设备永远排除。
2. `recordRemote=true` 时自动监听；开始前若该固定物理输出不可用，阻止开始并报 `monitor_output_missing`。`recordRemote=false` 时不启动监听。
3. 监听输出 unity gain（1.0）；UI 不提供音量滑杆，音量由 macOS 系统音量控制；不影响源轨。
4. 监听关闭：输出静音（写零），但 `MonitorRing` 仍可接收或丢弃；源轨不受影响。
5. 麦克风没有任何到 `MonitorRenderCallback` 的路径；代码审查必须能证明。
6. **关键**：系统默认输出被接管到虚拟声卡后，监听引擎必须显式设置 `kAudioOutputUnitProperty_CurrentDevice`（或等价 API）到物理设备；不得使用 `AVAudioEngine.outputNode` 的默认跟随行为。
7. 监听设备消失：不自动换设备；关闭监听并显示红色警告，录制继续；诊断写 `monitor_device_lost`。

### 3.4 视频：FaceTime 窗口 → 视频-only take.mov

```text
FaceTime 窗口（appName=FaceTime；找不到回退主显示器）
  │ SCShareableContent → SCContentFilter
  ▼
SCStream（BGRA，30 fps，最大 1920×1080，queueDepth 5）
  │ SCStreamOutput（serial queue）
  ▼
VideoFrameQueue（有界 8 帧）
  │ VideoWorker
  ▼
AVAssetWriterInput(video, H.264)
  │
  ▼
take.mov（仅视频轨，无音频）
```

规则：

1. 点“开始录制”时用 `SCShareableContent` 查找 `appName=FaceTime` 的窗口；找到用 `SCContentFilter(desktopIndependentWindow:)` 捕获该窗口；找不到才用 `SCContentFilter(display: CGMainDisplayID(), excludingWindows: [])` 回退主显示器，并在状态行说明“未找到 FaceTime 窗口，已录制主显示器”。UI 不提供选择器。
2. 视频尺寸取 FaceTime 窗口尺寸（回退时取主显示器），限制最长边 1920，宽高取偶数；不足 1920 不放大。
3. 帧率 30 fps；`showsCursor=false`；不采集系统音频。
4. `SCStreamOutput` 回调只把 `CMSampleBuffer` 放入有界队列；不在回调里阻塞写盘。
5. 队列满时丢最旧帧并计数 `video_frames_dropped`；不阻塞 SCStream。
6. `movieFragmentInterval = 1s`，让崩溃后的 `take.mov` 更可能可恢复。
7. `take.mov` 只含视频；音频全部来自 `remote.wav`/`microphone.wav`，避免 AVAssetWriter 多音轨编码和混音耦合。
8. 记录 `videoSource=faceTimeWindow|mainDisplayFallback` 和窗口标题到诊断；不记录窗口截图之外的内容。
8. 窗口关闭/流停止：写入 `video_source_lost`，音频继续；停止后导出 M4A/MKA。

### 3.5 导出：WAV + 视频 → MP4（Mix）+ MKV（三音轨）

```text
take.mov (video-only) ─┐
remote.wav (stereo)  ──┼──► FFmpeg filter_complex ──► FaceTime.mp4 (video + Mix)
microphone.wav (mono)─┘                          └──► FaceTime.mkv (video + Mix/Remote/Mic)
```

Mix 规则：

1. 远端 `remote.wav` 保持立体声；麦克风 `microphone.wav` 上混为立体声。
2. 两路默认增益 1.0；`amix` 使用 `normalize=0`，避免两路被自动压低。
3. 使用 `alimiter=limit=0.95:level=false` 防止削波，同时关闭自动电平（否则会把安静的一方抬起来）；限幅可能带来极小延迟，导出后用 440/880 和 A/V 同步验收。
4. Mix 只生成一次，作为 MP4 的唯一音轨和 MKV 的第 1 条音轨。
5. 录制阶段绝不生成 Mix；`remote.wav`/`microphone.wav` 是源轨。

**第一步：只生成一次 Mix（导出中间文件 `mix.wav`）**

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -i remote.wav -i microphone.wav \
  -filter_complex "\
[0:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[remote];\
[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,volume=1.0[mic];\
[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95:level=false[mix]" \
  -map "[mix]" -c:a pcm_f32le mix.wav
```

**第二步：MP4（视频 + 1 条 Mix AAC）**

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -i take.mov -i mix.wav \
  -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart -shortest \
  FaceTime.mp4
```

> 音画对齐：manifest 记录 `videoStartHostTime`、`remoteStartHostTime`、`micStartHostTime`。正常情况下 WAV 已从 `t0` 前导静音，`-itsoffset 0`；若首帧/首样本仍有差异，按 host time 差值在对应 `-i` 前加 `-itsoffset <seconds>`（视频或音频），再用 `ffprobe` 验证 A/V 差 ≤100 ms。

**第三步：MKV（视频 + Mix/Remote/Mic 三音轨）**

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -i take.mov -i mix.wav -i remote.wav -i microphone.wav \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:a:0 \
  -c:v copy \
  -c:a:0 aac -b:a:0 192k -ac:a:0 2 \
  -c:a:1 aac -b:a:1 192k -ac:a:1 2 \
  -c:a:2 aac -b:a:2 128k -ac:a:2 1 \
  -metadata:s:a:0 title="Mix（双方）" -metadata:s:a:0 language=zho \
  -metadata:s:a:1 title="远端（FaceTime）" -metadata:s:a:1 language=zho \
  -metadata:s:a:2 title="麦克风" -metadata:s:a:2 language=zho \
  -shortest \
  FaceTime.mkv
```

无麦克风时：

- 第一步：`mix.wav` 直接使用 `remote.wav` 的立体声（或只做 aformat，不做 amix）。
- MP4：`-i take.mov -i mix.wav`，1 条音频。
- MKV：`-i take.mov -i mix.wav -i remote.wav`，两条音轨标题为 Mix、远端。

无远端（只录麦克风）时：

- 第一步：`mix.wav` 由 `microphone.wav` 上混为立体声，不做 amix。
- MP4：`-i take.mov -i mix.wav`，1 条音频。
- MKV：`-i take.mov -i mix.wav -i microphone.wav`，两条音轨标题为 Mix、麦克风。
- 不启动 tap、不接管系统输出、不监听。

仅音频：

- `FaceTime.m4a`：`-i mix.wav -map 0:a:0 -c:a aac -b:a 192k -ac 2`。
- `FaceTime.mka`：`-i mix.wav -i remote.wav -i microphone.wav` 的三音轨 map，但没有 `0:v`。

失败处理：

- MP4/MKV 尽量 `-c:v copy`；若容器/时间基不兼容，允许一次视频重编码（H.264）或音频重编码。
- 一个产物失败时保留另一个 + WAV；两个都失败时 `failed`。
- 不用 FFmpeg 做采集、实时监听、AEC 或录制阶段混音。

---
## 4. 线程与缓冲模型

### 4.1 线程/队列清单

| 线程/队列 | 类型 | 职责 | 实时规则 |
|---|---|---|---|
| Main | 主线程 | SwiftUI、状态机命令、权限 UI | 不做音频/视频处理 |
| HAL IOProc | Core Audio 实时 | tap 回调，push 8ch block | 不分配、不加锁、不 I/O、不日志 |
| VPIO/AVAudioEngine tap | 音频实时 | 麦克风回调，push mic block | 只拷贝；不分配、不加锁、不 I/O |
| MonitorRenderCallback | 音频实时 | 从 MonitorRing 取 2ch，重采样，写 output | 不分配；resampler 预分配 |
| RemoteDistributor | 串行后台 | 8ch→2ch、统计、fan-out | 非实时；不阻塞 IO |
| MicWorker | 串行后台 | 44.1→48、单声道、统计 | 非实时 |
| SourceTrackWriter | 串行后台 | 写 `remote.wav`/`microphone.wav`；前导静音；漂移校正 | 非实时；可阻塞写盘 |
| VideoWorker | 串行后台 | CMSampleBuffer、AVAssetWriter 视频 append | 非实时；可阻塞 |
| SCStreamOutput | SCK 串行队列 | 入有界帧队列 | 不阻塞写盘 |
| ExportWorker | 后台 | FFmpeg 混音/MP4/MKV 导出、ffprobe、双音分析 | 可阻塞 |
| DiagnosticsTimer | 后台/主线程定时 | 聚合统计、写 JSON | 不碰实时缓冲 |

### 4.2 SPSC ring 设计

现有 `Sources/CRing/FRAudioRing.h` 提供：

```c
FRSampleRing *fr_sample_ring_create(uint32_t capacity_frames, uint32_t channels);
uint32_t fr_sample_ring_write(...);
uint32_t fr_sample_ring_read(...);
uint32_t fr_sample_ring_peek(...);
void fr_sample_ring_advance(...);

FRBlockRing *fr_block_ring_create(uint32_t slots, uint32_t max_frames, uint32_t channels);
int fr_block_ring_push(..., FRBlockMeta *meta);
int fr_block_ring_pop(...);
uint64_t fr_block_ring_dropped(...);
```

使用矩阵：

| Ring | 生产者（唯一） | 消费者（唯一） | 容量 | 用途 |
|---|---|---|---|---|
| `tapBlockRing` | HAL IOProc | RemoteDistributor | 64 slots × 16,384 frames × 8ch | 原始 8ch 块 |
| `remoteRecordRing` | RemoteDistributor | SourceTrackWriter | 32 × 16,384 × 2ch | 远端 stereo 源轨 |
| `monitorRing` | RemoteDistributor | MonitorRenderCallback | 48,000 frames × 2ch | 监听；目标 7,200 帧 |
| `micCaptureRing` | AVAudioEngine tap | MicWorker | 64 × 16,384 × 1ch | 原始麦克风 |
| `micRecordRing` | MicWorker | SourceTrackWriter | 32 × 16,384 × 1ch | 48k 单声道源轨 |
| `raw8Ring`（P1） | RemoteDistributor | Raw8Writer | 16 × 16,384 × 8ch | 可选 8ch WAV |

内存估算：

- `tapBlockRing` ≈ 64 × 16,384 × 8 × 4 B ≈ 32 MiB。
- `remoteRecordRing` ≈ 4 MiB；`monitorRing` ≈ 384 KiB；`micCaptureRing` ≈ 4 MiB；`micRecordRing` ≈ 2 MiB。
- 总计约 43 MiB（不含视频队列）。可接受。

规则：

1. 每个 ring 严格单生产者/单消费者；不得从 UI 或诊断定时器直接读。
2. 生产者满时返回 0 或丢最旧；不得阻塞实时回调；`dropped` 计数必须递增。
3. 消费者不得在实时回调中分配；`MonitorRenderCallback` 的 scratch 在初始化时分配。
4. `FRBlockMeta` 保留 `host_time`、`sample_time`、`timestamp_flags`、`sequence`、`dropped_before`；WAV 起始位置/漂移校正以 `host_time` 为准。
5. 不在实时回调调用 `os_log`、`FileHandle`、`Data`、`Array` 扩容、`NSLock`、`malloc`。

### 4.3 格式转换

| 位置 | 输入 | 输出 | 方式 |
|---|---|---|---|
| tap | 8ch/48k/Float32 packed interleaved | 8ch 原样 | 直接 memcpy 到 block ring |
| RemoteDistributor | 8ch 48k | 2ch 48k | 按标签取 FL/FR；逐帧映射 |
| MicWorker | 1ch 44.1k 或 48k Float32 | 1ch 48k Float32 | `AVAudioConverter`，预分配输出 buffer |
| SourceTrackWriter remote | 2ch 48k | `remote.wav` Float32 | `WAVWriter`；t0 前导静音；漂移校正 |
| SourceTrackWriter mic | 1ch 48k | `microphone.wav` Float32 | 同上 |
| Monitor | 2ch 48k Float32 | 2ch 48k（设备侧可 44.1） | DriftResampler + AUHAL 客户端格式 |
| Export Mix | remote stereo + mic mono | 2ch 48k AAC | FFmpeg `amix` + `alimiter` |
| Export remote/mic | WAV | AAC | FFmpeg 编码 |
| Video | BGRA | H.264 1080p30 约 8 Mbps | AVAssetWriter |
| MP4 | video + Mix | H.264 + AAC | FFmpeg `-c:v copy` + AAC |
| MKV | video + Mix/Remote/Mic | H.264 + 3×AAC | FFmpeg |

注意：

1. tap 的 Float32 packed 格式已由 `ASBD.isFloat32Packed` 校验；不做整数/浮点转换。
2. 麦克风 44.1→48 用 `AVAudioConverter`，quality 用 medium；转换器在准备阶段创建并预热。
3. 不把 8ch 平均成 stereo；不把 LFE/环绕混入远端。
4. 录制阶段不编码 AAC；AAC 只在导出阶段生成。

---

## 5. 8ch → stereo 取声道策略

### 5.1 设备布局事实

G0 实测：

```text
UID        : com.homepodflow.virtual-audio.surround71.v1
name       : HomePod Flow Audio
transport  : Virtual
direction  : in=0ch / out=8ch
sampleRate : 48000 Hz
format     : Float32 packed interleaved, 32 B/frame
labels     : FL FR FC LFE BL BR SL SR
stream     : out stream 70
```

注意：标签顺序是 `FL FR FC LFE BL BR SL SR`，与常见 7.1 的 `FL FR FC LFE SL SR BL BR` 不同。**不能按常见 7.1 顺序假定后 4 通道。**

### 5.2 映射算法

准备阶段：

1. 读取设备输出 stream 的 virtual format，确认 8ch/48k/Float32。
2. 调用 `AudioDeviceCatalog.channelLabels(device: channels:)` 读取 `kAudioDevicePropertyPreferredChannelLayout`。
3. 构造：

```swift
struct ChannelMap {
    let sourceLabels: [String]      // 8 个标签
    let flIndex: Int                // 期望 0
    let frIndex: Int                // 期望 1
    let method: Method              // .labels / .fallbackFirstTwo / .mono
    let warnings: [String]
}
```

4. 查找 `FL`、`FR`：
   - 都找到：`method=.labels`；
   - 只找到 `FL`：`FR` 置静音，`method=.labels`，警告 `fr_missing`；
   - 都找不到但 channels>=2：回退索引 0/1，`method=.fallbackFirstTwo`，警告 `channel_map_assumed`；
   - channels==1：复制到 L/R，`method=.mono`。
5. 如果标签数小于通道数，或标签为 `?`，按回退处理并写诊断。

运行阶段（RemoteDistributor）：

```text
for frame in 0..<frames:
    out[2*frame + 0] = in[8*frame + flIndex]
    out[2*frame + 1] = (frIndex >= 0) ? in[8*frame + frIndex] : 0
```

不做：

- 不把 8 个通道求和/平均；
- 不把 FC 混入 L/R（会改变对白声像）；
- 不把 LFE 混入（低频污染）；
- 不把后环绕混入（空间感/相位问题）。

### 5.3 单声道/单侧信号

- FaceTime 可能把远端渲染到 FL，FR 为 0（历史证据 `rmsL=0.169940 rmsR=0.000000` 是可能形态之一）。
- 默认保留真实布局：FL 有信号、FR 静音。
- P1 提供“单声道复制到双声道”开关：把 `(FL+FR)/2` 或非静音声道复制到 L/R；默认关闭。
- 自检通过条件：`max(rmsFL, rmsFR) >= 0.005`，不要求两个都有信号。
- 诊断记录 `fl_rms`、`fr_rms`、`other_channels_rms`、`channel_map`。

### 5.4 8ch 诊断保留

1. 自检始终保存 1.2 秒 8ch WAV：`self-test-8ch.wav`，用于证明通道顺序和权限。
2. P1 可开启整段 8ch WAV：`raw-8ch.wav`，默认关闭；写入 `raw8Ring`，由 `Raw8Writer` 落盘。
3. 诊断 JSON 每秒记录 8ch RMS/peak；不默认保存整段 8ch。
4. 8ch WAV 只用于诊断，不参与最终 MP4/MKV。

---

## 6. 自检（非静音）设计

### 6.1 为什么必须自检

无 TCC 时：

```text
create tap status=0
create aggregate status=0
start status=0
RESULT callbacks=303 frames=155136 nonzero=0
```

回调正常、帧数正常、样本全零。仅凭 `AudioDeviceStart` 成功不能判断采集成功。

另一个更隐蔽的失败：默认输出不是虚拟设备时，自检音仍然可以被 `TonePlayer` 送到虚拟设备并通过 tap，但 FaceTime 的声音不会进入虚拟设备。因此**自检不能替代路由校验**。

### 6.2 自检流程

```text
preparing
  ├─ 1. 设备/格式校验
  ├─ 2. 默认输出校验（必须是虚拟设备，或接管成功）
  ├─ 3. 监听物理输出解析（不能是虚拟设备）
  ├─ 4. 创建 recording tap + aggregate（只创建一次）
  ├─ 5. 启动 tap，丢弃前 200 ms
  ├─ 6. TonePlayer 向虚拟设备播放 1 kHz / 0.08 / 1.2 s
  ├─ 7. tap 采集 1.2 s；分析后 1.0 s
  ├─ 8. 计算 callbacks/frames/RMS/peak/Goertzel(1 kHz)/每通道
  ├─ 9. 通过 → 保留 tap，进入 recording
  └─ 10. 失败 → 销毁 tap，恢复输出，写诊断，failed
```

### 6.3 参数与阈值

| 参数 | 值 | 理由 |
|---|---|---|
| `toneFrequencyHz` | 1000 | 避开低频/语音主能量，便于 Goertzel 检测 |
| `toneAmplitude` | 0.08 | 低电平，虚拟设备 sink 不可闻；RMS≈0.0566 |
| `toneDuration` | 1.2 s | 留出启动/淡入淡出 |
| `analysisSkip` | 0.2 s | 跳过启动瞬态 |
| `analysisWindow` | 1.0 s | 与产品“1 秒自检”一致 |
| `minCallbacks` | 10 | 1 秒内至少 10 次回调（正常约 90+） |
| `minFrames` | 24,000 | 1 秒 48k 的一半；容忍启动/调度 |
| `rmsThreshold` | 0.005 | -46 dBFS，远低于 0.0566 期望值 |
| `goertzelThreshold` | 0.01 | 1 kHz 分量幅度；避免宽带噪声误判 |
| `channelPass` | `max(rmsFL, rmsFR) >= rmsThreshold` 且至少一个 1 kHz 分量超阈值 | 允许 FL 单侧 |
| `channelMapFail` | 其它通道有明显能量但 FL/FR 无 | 通道映射错误 |

### 6.4 结果判定

| 条件 | 结果 | 错误码 |
|---|---|---|
| `callbacks == 0` | 失败 | `self_test_no_callbacks` |
| `frames < 24,000` | 失败 | `self_test_frame_starved` |
| 所有 8ch 样本严格为 0 | 失败 | `permission_audio_capture_denied_or_silent` |
| `max(rmsFL,rmsFR) < 0.005` 或 1 kHz 未检测到 | 失败 | `self_test_silent` |
| 只有非 FL/FR 通道有能量 | 失败 | `channel_map_mismatch` |
| TonePlayer 启动失败 | 失败 | `self_test_tone_failed` |
| tap 创建失败 | 失败 | `tap_create_failed` |
| aggregate 创建失败 | 失败 | `aggregate_create_failed` |
| 无独立时钟 | 失败 | `aggregate_clock_missing` |
| 格式不符 | 失败 | `format_unsupported` |
| 全部通过 | 成功 | — |

### 6.5 自检证据

1. `self-test-8ch.wav`：1.2 秒，8ch Float32，48 kHz；保存到会话目录或 App Support `diagnostics/`。
2. `self-test.json`：
   - `callbacks`, `frames`, `zeroFrames`
   - `rms[8]`, `peak[8]`, `nonzeroSamples[8]`
   - `flRms`, `frRms`, `goertzel1000Fl`, `goertzel1000Fr`
   - `channelMap`, `method`
   - `tone`: frequency/amplitude/duration/deviceUID
   - `verdict`: code/explanation
3. 自检失败时，诊断必须同时说明“权限可能未授权”和“路由可能没声音”，不能只给一个模糊错误。
4. 自检通过只证明“tap 能读到虚拟设备上的测试音”，不证明 FaceTime 通话音频；后者必须真人通话验证。

### 6.6 自检与录音 tap 复用

- 为避免二次 TCC 提示/二次 aggregate 创建，准备阶段只创建一次 tap，自检读取 1.2 秒后继续使用同一个 tap 进入录制。
- 自检期间产生的测试音样本不得进入最终录音：自检完成后清空 `tapBlockRing`、`remoteRecordRing`、`monitorRing`，并将 `t0` 设为录制开始后的第一帧视频（视频会话）或第一个有效音频块（纯音频）。
- 如果实现选择“自检独立 tap + 录制新 tap”，必须确保第一个 tap 完全销毁，且不会让用户看到两次授权弹窗；不推荐。

---

## 7. 时钟、漂移与自适应缓冲

### 7.1 时间基准

1. 统一使用 host time（`mach_absolute_time` / `CMClockGetHostTimeClock`）。
2. 会话 `t0`：
   - 视频会话：第一帧被接受的视频帧 host time；
   - 纯音频会话：第一个有效音频块 host time。
3. `remote.wav`/`microphone.wav` 从 `t0` 开始：
   - 首个音频块晚于 `t0`：写前导静音；
   - 首个音频块早于 `t0`：丢弃 `t0` 之前的样本。
4. 视频 PTS 从 0 开始（第一帧 = 0）；音频 WAV 也从 0 开始，保证导出时无需额外 offset。
5. 不使用“累计写入样本数 / 48000”作为唯一时间轴；样本数只用于诊断。

### 7.2 监听自适应缓冲

复用 `DriftResampler`：

| 参数 | 值 |
|---|---|
| `targetFillFrames` | 7,200（150 ms @48k） |
| `minimumFillFrames` | 2,880（60 ms） |
| `maximumFillFrames` | 14,400（300 ms） |
| `maximumRatioTrim` | ±1% |
| 误差增益 | 0.05 |
| ratio 平滑 | 0.02 |
| 欠载 | 输出 0，`underrunFrames +=` |
| 溢出 | 丢弃最旧到目标；`overflowCount +=` |

行为：

1. 每 10 ms 输出回调读 `available`，按目标填充调整 ratio。
2. 填充低于 min 持续 3 个回调：插入静音并计数；不要阻塞生产者。
3. 填充高于 max：丢弃最旧样本到 target；不要增长延迟。
4. `lastRatio`、`underrunFrames`、`overflowCount` 写入诊断。
5. 监听缓冲只影响监听，不影响源轨。

### 7.3 录制时钟漂移

1. `RecordingTimeline` 每秒计算：
   - `expectedFrames = elapsedHostSeconds * 48000`
   - `actualFrames = 已写入源轨样本数`
   - `driftMs = (actualFrames - expectedFrames) / 48`
   - `ppm = (actualFrames / expectedFrames - 1) * 1e6`
2. `|driftMs| <= 20`：正常。
3. `20 < |driftMs| <= 100`：写 `clock_drift_warning`；继续。
4. `|driftMs| > 100`：`SourceTrackWriter` 启用 `TimelineResampler` 把该轨拉回 48k host 时间轴；记录 `drift_correction=true`。
5. `|hostTime delta| > 2 s`：写 `clock_gap`；WAV 按 host time 继续写前导静音；视频 PTS 若出现缺口，保持 host time 映射并记录。
6. 长录 15 分钟门禁：MP4 音画差 ≤100 ms；MKV 三音轨同步；否则失败并保留诊断。

### 7.4 麦克风采样率转换

- 硬件 44.1 kHz：`AVAudioConverter` 输入 44.1k mono Float32，输出 48k mono Float32。
- 转换器在准备阶段创建；每次 `convert` 使用预分配 `AVAudioPCMBuffer`/`AudioBufferList`。
- 若转换失败：`mic_converter_failed`；麦克风源轨标记失败；视频+远端继续（P0 降级为无麦克风）。
- 时间戳仍用输入块 host time；不因转换改变 `t0`。

---
## 8. AEC 设计

### 8.1 现状

- 本机没有可构建的 WebRTC AEC3 依赖；不得引入无法构建的 Homebrew 包/预编译二进制。
- V1 默认关闭 AEC，使用普通输入；高级区可开 Apple VoiceProcessingIO（通过 `AVAudioEngine.setVoiceProcessingEnabled(true)` 或 AUHAL `kAudioUnitSubType_VoiceProcessingIO`）。
- Apple VPIO 包含回声消除、噪声抑制、AGC 等处理；与 WebRTC AEC3 不是同一实现，效果/音色不同。
- **当前只能写“Apple 语音处理（可能降低回声）”，不能写“已消除回声”。**

### 8.2 可替换接口

```swift
enum AECMode: String, Codable {
    case appleVoiceProcessing
    case off
}

enum AECStatus: String, Codable {
    case configuredAppleVPIO   // 已配置，效果待 G5 验证
    case bypassed               // 用户关闭
    case unavailable            // 设备/路由不支持
    case unknown
}

protocol EchoCancellingCapture: AnyObject {
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

| 实现 | 说明 | 状态 |
|---|---|---|
| `PassthroughCapture` | 默认；AEC 关闭；普通输入，独立监听输出 | P0 |
| `AppleVoiceProcessingCapture` | 高级可选；VPIO 输入 + 监听输出同一引擎，输出只渲染远端 | P0 |
| `WebRTCAEC3Capture` | 10 ms 帧、远端参考 ring、延迟估计 | **未实现** |

### 8.3 VPIO 参考信号与物理监听

目标架构：

```text
Remote MonitorRing ──► AVAudioSourceNode ──► VoiceProcessingIO output ──► 物理输出
                                                      │
                                                      ├─ AEC 参考（远端）
                                                      ▼
物理麦克风 ──► VoiceProcessingIO input ──► 处理后 mic ──► mic ring
```

规则：

1. VPIO 输出只渲染远端；麦克风绝不进入输出。
2. 监听关闭时输出静音；AEC 无参考，但也没有扬声器回声。
3. macOS 系统音量改变会改变 AEC 参考电平；VPIO 应处理；若不处理，G5 记录。
4. **系统默认输出可能是虚拟设备**：VPIO 的 outputNode 必须显式绑定到 `monitorOutputUID`（物理设备），不能用默认跟随；否则监听和 AEC 参考都会落到虚拟声卡。
5. 如果 VPIO 不能同时使用“选定麦克风 + 选定物理输出”，Phase 2 先做 spike：
   - 方案 A：同一 VPIO 引擎，显式设置 outputNode 当前设备为物理输出；
   - 方案 B：创建私有 aggregate（麦克风输入 + 物理输出）作为 VPIO 设备；
   - 方案 C：退回普通输入 + 独立监听，AEC 标 `unavailable`，UI 建议耳机。
6. 不得为了 AEC 把监听输出接到虚拟设备；那会让用户听不到。

### 8.4 未来接 AEC3 的边界

如果未来要接 WebRTC AEC3：

1. 需要可构建的 arm64 静态库/源码；当前没有。
2. 需要 48 kHz、10 ms（480 样本）帧；当前 tap 块是可变帧数，需要 `FrameAssembler`。
3. 需要 far-end reference ring（监听输出前）和 near-end mic ring；需要延迟估计/双讲检测。
4. 需要新增 `WebRTCAEC3Capture` 实现 `EchoCancellingCapture`，不改变 Session/Recorder 接口。
5. 需要重新跑 G5：扬声器外放、双方说话、无持续回声；不能沿用 VPIO 的结论。
6. 在上述完成前，文档/UI 不得出现“AEC3 已集成/已启用”。

---

## 9. 权限与 TCC 处理

### 9.1 权限检测

| 权限 | API | 说明 |
|---|---|---|
| 麦克风 | `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess` | 可靠 preflight |
| 屏幕录制 | `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` | 授权后可能需重启 App |
| 系统音频 | 无可靠公开 preflight | 创建 tap + 自检；全零即权限/路由问题 |

### 9.2 启动时序

1. App 启动/空闲时**不切换系统默认输出**；只在用户点 `开始录制` 后进入准备阶段才切。否则用户空闲时整台 Mac 会没声音。
2. 主界面不显示权限卡片；首次 `开始录制` 时由 macOS 自动弹麦克风/屏幕/系统音频授权。
3. 读取 `AVCaptureDevice` 麦克风状态；拒绝则降级为无麦克风，不阻塞远端。
4. 读取屏幕 preflight；拒绝则自动仅音频，不新增按钮。
5. `recordRemote=true` 时：记录接管前物理默认输出 → 创建 tap → 自动接管系统输出 → 锁定监听到该物理输出 → 执行自检。
6. 固定监听输出不可用则 `monitor_output_missing`；不自动换设备。
7. 停止/退出/崩溃恢复时自动还原系统输出。
8. 授权后从系统设置返回：刷新状态；若仍失败，高级区提示重启 App。
9. 不在每次开始录制时重复弹系统授权框；用 `openSettings` 深链，主界面只显示失败原因。

### 9.3 TCC 全零处理

- `DeviceTapCapture.start` 成功但自检全零：不要重试无限次；一次失败即报错，保存 8ch WAV。
- 若 `CGPreflightScreenCaptureAccess` 为 false 且自检全零：优先提示屏幕/系统音频权限。
- 若屏幕已授权但自检全零：提示“系统音频录制权限或路由”。
- 错误文案必须包含“权限可能未授权”和“默认输出可能不是虚拟设备”两种可能。

---

## 10. 失败分类与诊断字段

### 10.1 错误码（与 PRD 一致）

| 错误码 | 阶段 | 含义 | 用户动作 |
|---|---|---|---|
| `device_missing` | prepare | 找不到虚拟设备 | 检查驱动 |
| `device_no_output` | prepare | 设备无输出通道 | 检查设备 |
| `format_unsupported` | prepare | 不是 8ch/48k/Float32 | 诊断 |
| `route_not_default` | prepare | 默认输出不是虚拟设备 | 接管/声音设置 |
| `output_takeover_failed` | prepare | 切换默认输出失败 | 声音设置 |
| `aggregate_clock_missing` | prepare | 无独立时钟设备 | 连接物理输出 |
| `monitor_output_missing` | prepare | 无物理监听输出 | 连接耳机/扬声器 |
| `permission_audio_capture_denied_or_silent` | self-test | 全零，权限/路由 | 打开设置 |
| `self_test_no_callbacks` | self-test | 无回调 | 重试/诊断 |
| `self_test_frame_starved` | self-test | 帧数不足 | 重试/诊断 |
| `self_test_silent` | self-test | 低于阈值/无 1kHz | 检查权限/路由 |
| `self_test_tone_failed` | self-test | 测试音播放失败 | 重试 |
| `channel_map_mismatch` | self-test | FL/FR 无能量，其它通道有 | 诊断 |
| `tap_create_failed` | prepare | `AudioHardwareCreateProcessTap` 失败 | 诊断 |
| `aggregate_create_failed` | prepare | aggregate 创建失败 | 诊断 |
| `mic_unavailable` | prepare | 麦克风权限/设备不可用 | 可继续 |
| `mic_converter_failed` | prepare/record | 44.1→48 失败 | 关闭麦克风重试 |
| `video_unavailable` | prepare | 屏幕权限/源不可用 | 仅音频 |
| `video_source_lost` | record | 视频源断开 | 继续/停止 |
| `video_writer_failed` | record | 视频写入失败 | 仅音频 |
| `audio_writer_failed` | record | WAV 写入失败 | 诊断 |
| `ring_overflow` | record | ring 满 | 诊断 |
| `monitor_underrun` | record | 监听欠载 | 诊断 |
| `monitor_device_lost` | record | 监听设备消失 | 关闭监听；不换设备 |
| `route_changed_during_recording` | record | 默认输出被切走 | 切回 |
| `clock_gap` | record | 睡眠/时钟跳变 | 诊断 |
| `disk_low` | record | 磁盘 <500 MB | 自动停止 |
| `mux_tool_missing` | export | 找不到 FFmpeg | 安装/重试 |
| `mix_failed` | export | FFmpeg 混音失败 | 恢复导出 |
| `mp4_export_failed` | export | MP4 导出失败 | 用 MKV/恢复 |
| `mkv_export_failed` | export | MKV 导出失败 | 用 MP4/恢复 |
| `dual_output_incomplete` | export | 双产物未完整 | 查看警告 |
| `tone_validation_failed` | export | 440/880 双音未同时检出 | 诊断混音 |
| `mux_timeout` | export | 单产物 300s/总 600s 超时 | 诊断 |
| `output_restore_failed` | stop | 默认输出恢复失败 | 手动恢复 |
| `already_running` | prepare | 已有实例 | 激活已有 |
| `session_interrupted` | recovery | 异常退出 | 恢复 |

### 10.2 `diagnostics.json` 结构（关键段）

```json
{
  "schemaVersion": 2,
  "sessionID": "2026-11-07_14-30-05",
  "appVersion": "0.1.0",
  "recordingMode": {
    "recordRemote": true,
    "recordMicrophone": true
  },
  "host": {
    "os": "macOS 26.5.2 (25F84)",
    "arch": "arm64",
    "xcode": "26.6 (17F113)"
  },
  "permissions": {
    "microphone": "granted",
    "screen": "granted",
    "systemAudio": "inferred_by_self_test"
  },
  "devices": {
    "virtual": {
      "uid": "com.homepodflow.virtual-audio.surround71.v1",
      "name": "HomePod Flow Audio",
      "inputChannels": 0,
      "outputChannels": 8,
      "sampleRate": 48000,
      "labels": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"]
    },
    "defaultOutputBefore": "BuiltInSpeakerDevice",
    "defaultOutputDuringRecording": "com.homepodflow.virtual-audio.surround71.v1",
    "monitorOutput": "BuiltInSpeakerDevice",
    "monitorOutputIsVirtual": false
  },
  "route": {
    "takeoverRequested": true,
    "didChangeDefaultOutput": true,
    "restored": true,
    "restoreError": null
  },
  "tap": {
    "tapUID": "...",
    "aggregateUID": "...",
    "clockDeviceUID": "BuiltInSpeakerDevice",
    "sampleRate": 48000,
    "channels": 8,
    "bytesPerFrame": 32
  },
  "selfTest": {
    "callbacks": 93,
    "frames": 47616,
    "zeroFrames": 0,
    "rms": [0.056, 0.056, 0, 0, 0, 0, 0, 0],
    "peak": [0.08, 0.08, 0, 0, 0, 0, 0, 0],
    "goertzel1000Fl": 0.08,
    "goertzel1000Fr": 0.08,
    "verdict": "pass"
  },
  "channelMap": {
    "method": "labels",
    "flIndex": 0,
    "frIndex": 1,
    "warnings": []
  },
  "audio": {
    "remoteFrames": 0,
    "micFrames": 0,
    "remoteDropped": 0,
    "micDropped": 0,
    "ringOverflows": 0,
    "micConverter": "44.1k->48k",
    "remoteWav": "remote.wav",
    "microphoneWav": "microphone.wav"
  },
  "monitor": {
    "enabled": true,
    "routeLock": "originalPhysicalDefault",
    "outputUID": "BuiltInSpeakerDevice",
    "unityGain": true,
    "targetFillFrames": 7200,
    "underrunFrames": 0,
    "overflowCount": 0,
    "lastRatio": 1.0
  },
  "video": {
    "source": "faceTimeWindow",
    "fallbackReason": null,
    "frames": 0,
    "dropped": 0,
    "width": 1920,
    "height": 1080,
    "fps": 30,
    "takeMov": "take.mov"
  },
  "mix": {
    "remoteGain": 1.0,
    "micGain": 1.0,
    "limiter": 0.95,
    "durationMs": 0,
    "dualTone": {
      "remoteHz": 440,
      "micHz": 880,
      "remoteLevelDBFS": -12.0,
      "micLevelDBFS": -12.0,
      "verdict": "pass"
    }
  },
  "artifacts": {
    "mp4": {"path": "FaceTime.mp4", "valid": true, "videoTracks": 1, "audioTracks": 1, "audioCodec": "aac"},
    "mkv": {"path": "FaceTime.mkv", "valid": true, "videoTracks": 1, "audioTracks": 3, "trackOrder": ["mix", "remote", "mic"]},
    "m4a": null,
    "mka": null
  },
  "mux": {
    "tool": "/opt/homebrew/bin/ffmpeg",
    "version": "9.0.2",
    "mp4DurationMs": 0,
    "mkvDurationMs": 0,
    "reencodedVideo": false,
    "reencodedAudio": false
  },
  "warnings": [],
  "errorCode": null
}
```

### 10.3 日志

- 使用 `os.Logger`，subsystem `com.mdxz.facetime.recorder`。
- 不记录音频样本、不记录通话内容、不记录设备序列号。
- 日志级别：info 记录状态/设备 UID/产物；error 记录错误码/OSStatus；debug 记录帧数/ring 计数。
- 诊断文件只写本地 `~/Movies/FaceTime Recorder/.../diagnostics.json` 和 App Support。

---

## 11. 文件布局、命名与清理

### 11.1 会话目录

```text
~/Movies/FaceTime Recorder/
  2026-11-07/
    2026-11-07_14-30-05/
      FaceTime_2026-11-07_14-30-05.mp4   # 默认主文件：H.264 + Mix
      FaceTime_2026-11-07_14-30-05.mkv   # 多轨归档：Mix/Remote/Mic
      remote.wav                          # 录制源轨：远端立体声
      microphone.wav                      # 录制源轨：麦克风单声道
      mix.wav                             # 导出中间文件：双方混音；成功后删除，失败保留
      take.mov                            # 视频中间文件；成功后删除，失败保留
      self-test-8ch.wav                   # 自检证据
      manifest.json
      diagnostics.json
      .inprogress
      FAILED.txt            # 仅失败
```

- `take.mov`：视频-only AVAssetWriter 中间文件；成功导出后可删除；失败保留。
- `remote.wav`/`microphone.wav`：源轨，默认保留；用于重混/恢复导出。
- `mix.wav`：导出阶段生成的临时 Mix；成功后删除；失败保留用于诊断。
- `FaceTime.mp4`：默认播放/分享；`FaceTime.mkv`：归档。
- 仅音频：`FaceTime.m4a` + `FaceTime.mka`。
- 文档中的 `FaceTime.mp4`/`FaceTime.mkv` 指产物类型；实际文件名带 `yyyy-MM-dd_HH-mm-ss`，避免覆盖。

### 11.2 原子写入

1. `manifest.json`/`diagnostics.json`：写临时文件 `*.tmp`，`fsync`，`rename` 到目标。
2. lease：`output-lease.json.tmp` → `output-lease.json`。
3. 不在实时线程写任何文件。
4. 每次状态变化写 manifest；进程崩溃后 manifest 至少保留上一个状态。

### 11.3 清理规则

| 情况 | 行为 |
|---|---|
| prepare 失败且未创建媒体 | 删除空目录；诊断放 App Support |
| 录制失败但有媒体 | 保留目录/WAV/`take.mov`；写 `FAILED.txt`；不删除 |
| MP4 成功、MKV 失败 | `finished` 降级；保留 MP4/WAV；标“归档缺失” |
| MKV 成功、MP4 失败 | `finished` 降级；保留 MKV/WAV；标“MP4 缺失” |
| 两个都失败 | `failed`；保留 `take.mov`/WAV；提供恢复导出 |
| 成功 | 删除 `.inprogress`；删除 `take.mov`/`mix.wav`；保留 MP4/MKV/WAV/诊断 |
| 崩溃 | 下次扫描 `.inprogress`；用 `take.mov` + WAV 重新导出；不覆盖 |
| 磁盘低 | 自动停止；保留已录部分 |

---
## 12. 分阶段实施顺序与验证命令

> 所有命令在 Mac 上执行，工作目录：
> `/Users/lvzhipeng/Developer/FaceTimeRecorder`
> 先执行：
> ```sh
> export PATH=/opt/homebrew/bin:$PATH
> xcodegen generate
> ```

### Phase 0：基线构建与 G0/G1 复核

**目标**：确认工程可构建，AudioProbe 能枚举设备，GUI 授权下 tap 能读到非零 PCM。

**构建**：

```sh
cd /Users/lvzhipeng/Developer/FaceTimeRecorder
export PATH=/opt/homebrew/bin:$PATH
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme AudioProbe \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
```

**验证**：

```sh
build/Build/Products/Debug/AudioProbe list
build/Build/Products/Debug/AudioProbe tap \
  --uid com.homepodflow.virtual-audio.surround71.v1 \
  --seconds 5 --tone --wav /tmp/fr-probe.wav --report /tmp/fr-probe.json
```

**通过标准**：

- `list` 显示 `in=0ch / out=8ch`、48 kHz、标签 `FL FR FC LFE BL BR SL SR`。
- GUI 授权环境：`pcm_detected`，FL 或 FR RMS ≥0.005，退出码 0。
- SSH 无 TCC 环境：`all_zero_pcm`，退出码 10；这是负向证据，不是通过。

### Phase 1：路由校验 + 自检 + 状态机骨架

**目标**：App 能在 `preparing` 中完成设备/路由/权限/监听物理输出/自检；失败有稳定错误码；不生成假文件。

**新增文件建议**：

```text
Sources/Core/Session/SessionCoordinator.swift
Sources/Core/Session/SessionManifest.swift
Sources/Core/Session/Diagnostics.swift
Sources/Core/Audio/SelfTestRunner.swift
Sources/Core/Audio/ChannelMap.swift
Sources/Core/Route/OutputRouteManager.swift
Sources/Core/Route/OutputLeaseStore.swift
Sources/Core/Audio/MonitorRouteResolver.swift
Sources/App/SessionViewModel.swift
```

**构建**：

```sh
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
open "build/Build/Products/Debug/FaceTime Recorder.app"
```

**验证**：

1. 首次打开主界面：只有标题/两个开关/主按钮/状态行/同意提示/未验证提示；高级默认收起（AC-35/36）。
2. 两个开关都关：主按钮禁用，状态“请至少开启一项”（AC-38）。
3. 默认输出为 `BuiltInSpeakerDevice`、`录制对方声音` 开 → 开始 → 自动切到虚拟、自动监听、自检通过 → `recording`，无确认弹窗（AC-37）。
4. `录制对方声音` 关、麦克风开 → 不接管、不监听、不创建 tap；录 FaceTime 窗口（找不到回退主显示器）+麦克风。
5. 撤销系统音频权限 → 自检失败 → `permission_audio_capture_denied_or_silent` 或 `self_test_silent`。
6. 移除所有物理输出（测试环境）→ `monitor_output_missing`。
7. 检查 `self-test-8ch.wav` 与 `diagnostics.json`。

**通过标准**：状态机不跳态；失败不产生 `.mp4`/`.mkv`；输出恢复；诊断有 `recordingMode`、8ch RMS 与 `monitorOutputUID`。

### Phase 2：监听（物理输出）

**目标**：远端 tap → 固定物理输出；自动监听；系统音量不影响源轨；麦克风不进监听；接管后仍从原物理设备出声。

**新增文件建议**：

```text
Sources/Core/Audio/MonitorEngine.swift
Sources/Core/Audio/MonitorOutputUnit.swift
Sources/Core/Audio/MonitorRing.swift
```

**构建/运行**：

```sh
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
open "build/Build/Products/Debug/FaceTime Recorder.app"
```

**验证**：

1. `录制对方声音` 开 → 接管前物理默认输出（耳机/内置扬声器）能听到；虚拟设备不是监听输出；UI 无设备/音量选择。
2. `录制对方声音` 关 → 不接管、不监听；源轨只含麦克风。
3. 对着麦克风说话，耳机中听不到自己。
4. 调整 macOS 系统音量 3 次；录制源轨不受影响。
5. 连续 30 分钟，监听不累积延迟；`monitor.underrunFrames` 可解释。
6. `diagnostics.json` 有 `monitorOutputUID`、`routeLock=originalPhysicalDefault`、`lastRatio`、`underrun`、`overflow`，且 `monitorOutputIsVirtual=false`。

**通过标准**：G2 通过；AC-33 通过。

### Phase 3：双源轨 WAV 录制

**目标**：录制阶段写 `remote.wav` + `microphone.wav`，不混音；时间从 t0 对齐；掉帧可诊断。

**新增文件建议**：

```text
Sources/Core/Audio/RemoteDistributor.swift
Sources/Core/Audio/MicrophoneCapture.swift
Sources/Core/Audio/MicWorker.swift
Sources/Core/Record/SourceTrackWriter.swift
Sources/Core/Record/AudioTimeline.swift
Sources/Core/Record/TimelineResampler.swift
```

**构建**：

```sh
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
```

**验证**：

1. 录制 60 秒，双方说话；停止后 `remote.wav` 与 `microphone.wav` 存在。
2. `WAVReader.info`：remote 2ch/48k，microphone 1ch/48k；时长差 ≤0.5 秒。
3. 关闭监听再录一次，WAV 数量/时长不变。
4. 确认录制目录没有 Mix 文件、没有 MP4/MKV；符合“录制阶段不混音”。
5. 模拟 ring 溢出，诊断计数增加，录制不崩溃。

**通过标准**：G3 通过；WAV 可独立播放；两轨时间对齐；无实时混音。

### Phase 4：视频 + 双产物导出

**目标**：ScreenCaptureKit 自动 FaceTime 窗口（找不到回退主显示器）+ 双 WAV → MP4（Mix）+ MKV（Mix/Remote/Mic）；默认 MP4 能听双方。

**新增文件建议**：

```text
Sources/Core/Video/VideoRecorder.swift
Sources/Core/Video/VideoFrameQueue.swift
Sources/Core/Export/MixExporter.swift
Sources/Core/Export/MediaValidator.swift
Sources/Core/Export/ToneAnalyzer.swift
```

**构建/导出**：

```sh
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
# 录制 60 秒后，App 自动导出；检查目录
ls -lh "$HOME/Movies/FaceTime Recorder/<date>/<session>/"
```

**ffprobe 校验**：

```sh
/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_type,codec_name,channels,sample_rate:stream_tags=title \
  -show_entries format=duration,size -of json FaceTime.mp4
/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_type,codec_name,channels,sample_rate:stream_tags=title \
  -show_entries format=duration,size -of json FaceTime.mkv
```

**通过标准**：

- MP4：1 视频 + 1 音频（Mix）；默认播放能听到双方。
- MKV：1 视频 + 3 音频；轨道顺序 Mix/Remote/Mic；标题正确。
- 主界面只显示“已保存 FaceTime.mp4（双方声音）”+“在 Finder 中显示”；MKV 只在高级区。
- 有 FaceTime 窗口时视频来自该窗口；无窗口时回退主显示器且状态行说明；无窗口/显示器选择器。
- `remote.wav`/`microphone.wav` 保留。
- 音画差 ≤100 ms；MP4 默认音轨非静音。

### Phase 4.5：440/880 双音测试

**目标**：证明 MP4 默认音轨同时包含远端 440 Hz 与麦克风 880 Hz。

**生成测试素材**：

```sh
mkdir -p /tmp/fr-dual-tone
cd /tmp/fr-dual-tone

/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" \
  -af "volume=0.1,aformat=channel_layouts=stereo" -ac 2 -c:a pcm_f32le remote440.wav

/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=10" \
  -af "volume=0.1" -ac 1 -c:a pcm_f32le mic880.wav

/opt/homebrew/bin/ffmpeg -hide_banner -y \
  -f lavfi -i "testsrc=size=640x360:rate=30:duration=10" \
  -c:v libx264 -pix_fmt yuv420p take.mov
```

**用导出器生成 MP4/MKV**（与 App 相同的 filter）：

```sh
# 可直接复用 App 的 MixExporter 测试入口；或按 TECH_PLAN 3.5 的 ffmpeg 命令
# 输出：FaceTime.mp4 / FaceTime.mkv
```

**提取 MP4 默认音轨**：

```sh
/opt/homebrew/bin/ffmpeg -hide_banner -y -i FaceTime.mp4 \
  -map 0:a:0 -ac 2 -ar 48000 -c:a pcm_f32le /tmp/fr-dual-tone/mp4-mix.wav
```

**分析 440/880**：

```sh
python3 tests/tools/tone_probe.py /tmp/fr-dual-tone/mp4-mix.wav \
  --freq 440 --freq 880 --threshold-dbfs -30 \
  --json /tmp/fr-dual-tone/tone-analysis.json
```

**通过标准**：`tone-analysis.json` 中 440 与 880 都 `present=true` 且高于 -30 dBFS；MKV 三音轨顺序正确；Mix 轨同时含两个频率。

### Phase 5：AEC / 回声

**目标**：Apple VPIO 在真实扬声器/耳机下工作；监听物理输出；不把麦克风播回；G5 有听感证据。

**验证**：

1. 内置扬声器 + 内置麦克风，监听开启，双方说话 5 分钟。
2. 对方声音不应被麦克风大量录回；若仍有回声，记录 `aec_status` 与 `echo_observed`。
3. 耳机模式对比；AEC 关闭对比。
4. 不得用“AEC 已开启”代替“回声已消除”；只有 G5 通过才更新文案。

**通过标准**：G5 通过；否则 AEC 标 `unavailable`，UI 建议耳机，不宣称消除回声。

### Phase 6：G6 发布候选

**目标**：15 分钟真人通话、双产物、崩溃恢复、权限拒绝、文档齐全。

**验证**：

1. 15 分钟 FaceTime 真人通话；MP4 默认播放双方；MKV 三音轨；音画同步。
2. `kill -9` 录制中/导出中，重启恢复。
3. 权限拒绝矩阵全部走通。
4. 磁盘低、设备消失、睡眠唤醒。
5. `xcodebuild` 构建 + `CoreTests` 全绿。
6. 证据归档到 `tests/evidence/2026-11-07/`。

**通过标准**：G6 通过；PRD AC-01~AC-34（P0 项）都有证据；FaceTime 徽章按总调度签字更新。

---

## 13. 测试与证据命令

### 13.1 构建

```sh
cd /Users/lvzhipeng/Developer/FaceTimeRecorder
export PATH=/opt/homebrew/bin:$PATH
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
```

### 13.2 单元测试

```sh
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme CoreTests \
  -derivedDataPath build CODE_SIGN_IDENTITY=- test
```

覆盖：

- `FRBlockRing`/`FRSampleRing` SPSC 基本读写、满/空、peek/advance。
- `ChannelMap` 标签映射、回退、单声道。
- `DriftResampler` 目标填充、ratio 限幅、欠载计数。
- 状态机转换/非法事件/超时。
- `OutputLeaseStore` 原子写/恢复。
- `SourceTrackWriter` 前导静音/裁剪/时长。
- 文件名冲突/清理规则。
- 错误码映射。
- `WAVWriter` 头/duration。
- Mix filter 参数/轨道顺序（可用合成 WAV 离线测试）。

### 13.3 硬件/集成

```sh
# 设备枚举
build/Build/Products/Debug/AudioProbe list --json

# tap + 自检音（GUI 授权）
build/Build/Products/Debug/AudioProbe tap \
  --uid com.homepodflow.virtual-audio.surround71.v1 \
  --seconds 5 --tone --wav /tmp/fr-probe.wav --report /tmp/fr-probe.json --all-channels

# 仅麦克风
build/Build/Products/Debug/AudioProbe input \
  --uid <mic-uid> --seconds 3 --wav /tmp/fr-mic.wav --report /tmp/fr-mic.json
```

### 13.4 产物校验

```sh
/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_type,codec_name,channels,sample_rate:stream_tags=title \
  -show_entries format=duration,size -of json FaceTime.mp4

/opt/homebrew/bin/ffprobe -v error \
  -show_entries stream=index,codec_type,codec_name,channels,sample_rate:stream_tags=title \
  -show_entries format=duration,size -of json FaceTime.mkv
```

### 13.5 双音分析工具

`tests/tools/tone_probe.py` 由 QA 编写，只依赖 Python 标准库：

- 读取 WAV；
- 对 440/880 Hz 做 Goertzel；
- 输出 JSON：`{ "440": {"present": true, "dbfs": -12.3}, "880": {...} }`；
- 阈值默认 -30 dBFS；
- 不修改产品代码。

### 13.6 证据目录

```text
tests/evidence/2026-11-07/
  AC-09/
    ffprobe-mp4.json
    ffprobe-mkv.json
    human-note.md
    diagnostics.json
  AC-31/
    tone-analysis.json
    ffprobe-mkv.json
    FaceTime.mp4
    FaceTime.mkv
```

---

## 14. 技术风险与缓解

| 风险 | 技术缓解 | 验证 |
|---|---|---|
| 无 TCC 全零 | 自检 + 全零分类；禁止以 start 成功判定 | AC-03/04/06 |
| 默认输出不是虚拟 | 路由校验先于自检；接管 lease | AC-05/12 |
| 监听误用系统默认输出 | `MonitorRouteResolver` 排除虚拟；显式绑定物理设备 | AC-33 |
| 自动接管无确认，用户误以为系统声音异常 | 开关下一行说明、自动恢复、状态行提示；高级区完整风险 | AC-37 |
| 极简 UI 隐藏诊断，排障困难 | 状态行给失败原因；高级区保留权限/诊断/日志 | AC-35/36 |
| 8ch 标签不符 | 按标签取 FL/FR；回退记录；自检 FL/FR | AC-02/03 |
| 时钟漂移 | host time t0 + WAV 前导静音 + 监听自适应 + 录制漂移估计 | AC-18 |
| 回调分配/锁 | 实时路径只 push ring；worker 做转换/写盘 | 代码审查 + Instruments |
| AEC 无效 | VPIO 默认 + AEC 状态 + 耳机建议；G5 不通过不宣称 | G5 |
| VPIO 设备路由 | Phase 2 spike；备选 aggregate；失败标 unavailable | G5 |
| FFmpeg 缺失/失败 | 预检 + 单产物降级 + WAV/`take.mov` 保留 | AC-16/34 |
| 混音削波/一方过小 | 1.0/1.0 + limiter 0.95；440/880 自动测试 | AC-31/32 |
| MP4 默认音轨错误 | 强制 `-map "[mix]"`；ffprobe 1 audio；tone probe | AC-31 |
| 视频崩溃不可恢复 | `movieFragmentInterval=1s` | AC-23 |
| 设备热插拔 | 属性监听 + 安全停止 | AC-17 |
| 睡眠/时钟跳变 | 阻止空闲睡眠 + gap 诊断 | AC-27 |
| 系统声音混入 | UI 提示；P2 按进程 tap | 文档/验收 |
| 法律风险 | 同意提示；不隐蔽 | AC-25 |

---

## 15. 技术开放问题

1. `AVAudioEngine` 的 VPIO 是否能在“系统默认输出=虚拟设备”时把 outputNode 显式路由到物理监听设备，并同时采集物理麦克风？Phase 2 spike 必须验证；失败则走 aggregate 或标 `AEC unavailable`。
2. `AVAssetWriter` 视频-only `take.mov` 在 macOS 26.5.2 上的 fragment/恢复行为；Phase 4 验证。
3. FFmpeg `amix` + `alimiter` 从 WAV 到 MP4/MKV 的音画同步/限幅延迟；AC-09/31 验证。
4. `ScreenCaptureKit` 捕获 FaceTime 窗口是否受限；AC-21；失败退回整屏。
5. 设备标签在 `kAudioDevicePropertyPreferredChannelLayout` 不可用时的回退行为；必须写 `channel_map_assumed`。
6. 蓝牙耳机监听延迟与 AEC 参考的交互；G5 单独记录。
7. 15 分钟/60 分钟 WAV + 双产物文件大小/磁盘；需要 AC-18/AC-20。
8. MP4 失败但 MKV 可用时的产品状态；建议 `finished` 降级，等待总调度确认。

---

## 16. 交接清单

- [x] 模块图与数据流（远端/麦克风/监听/视频/WAV/混音/导出）。
- [x] 线程与缓冲模型、SPSC ring、格式转换、漂移/自适应缓冲。
- [x] 8ch→stereo 按标签 FL/FR；8ch 诊断。
- [x] 自检阈值与失败分类。
- [x] AEC 现状、VPIO 默认、可替换接口、AEC3 边界（未实现）。
- [x] 录制阶段不混音；MP4/MKV 导出阶段混音。
- [x] 监听物理输出解析，排除虚拟设备。
- [x] 文件布局/命名/半成品清理。
- [x] 分阶段实施与构建/验证命令（Mac 路径）。
- [x] 440/880 双音测试命令与验收口径。
- [x] V1 极简主界面、两个开关、自动设备/接管/固定物理监听/FaceTime 窗口决策。
- [x] 高级折叠区（设备状态/监听只读/权限/诊断/日志/FFmpeg/8ch）。
- [ ] 总调度确认 AEC/路由/声道/混音方案。
- [ ] Dev Agent 按模块边界实现；不得改驱动/旧仓库。
- [ ] QA Agent 按测试矩阵归档证据。

---

## 17. 变更记录

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| 1.0 | 2026-11-07 | 首版：模块、线程、自检、AEC、文件与分阶段方案 | 产品 Agent |
| 1.1 | 2026-11-07 | 改为源轨 WAV + 导出 MP4（Mix）/MKV（Mix/Remote/Mic）；监听强制物理输出；增加 440/880 双音验收 | 产品 Agent |
| 1.2 | 2026-11-07 | V1 极简主界面；自动接管/固定物理监听/FaceTime 窗口；StartRequest 只剩两个开关；高级折叠 | 产品 Agent |
