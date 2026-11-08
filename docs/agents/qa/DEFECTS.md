# FaceTime Recorder 缺陷单（QA）

版本：1.0 · 日期：2026-11-07 · 维护：测试 Agent

## 严重度

| 级别 | 定义 |
|---|---|
| P0 | 数据丢失、隐私泄露、伪造通过、崩溃不可恢复 |
| P1 | 门禁必达能力失败，且无可用绕过 |
| P2 | 功能/诊断明显错误，有绕过或影响有限 |
| P3 | 边界、文档、可测试性、低概率问题 |

## 当前缺陷

### QA-001 · P2 · `silentFrames` 统计在每块内只计首次非零之前的帧

- 文件：`Sources/Core/TrackRecorder.swift:139-147`
- 复现：构造一个 block：前 100 帧全零，随后 412 帧非零。按语义 `silentFrames` 应 +100；实际 `frameNonzero` 一旦置 true 就不再复位，后续即使全零也不计数，只有块首的前导零被统计。
- 期望：每帧独立判断“该帧所有通道是否全零”，再累加 `silentFrames`。
- 实际：`var frameNonzero` 在 block 循环外初始化，循环内不复位；`if !frameNonzero { stats.silentFrames += 1 }` 只反映块首前导静音。
- 证据：
  - 静态代码：`TrackRecorder.swift:139-147`。
  - 旁证：`artifacts/G1-2026-11-07/monitor-mix/diagnostics.json` 中连续 440 Hz、289792 帧仅 `silentFrames=1`；`fr-tcc.json` 中 487 个 block 出现 `zeroFrames=10256`。两者都只能说明“块首零”被计数，不能证明块内静音被计数。
- 影响：诊断字段会低估静音/断音，误导“为什么没录到”的排查；不影响 PCM 数据本身。
- 建议：把逐帧静音判定抽成纯函数（例如 `isSilent(frame)`），QA 可单测；或至少在每帧开始重置 `frameNonzero`。
- 状态：Open（待 Dev）

### QA-002 · P3 · Block ring 对超长 block 静默截断且不增加丢帧计数

- 文件：`Sources/CRing/FRAudioRing.c:214`
- 复现：`fr_block_ring_create(2, 64, 2)` 后 `fr_block_ring_push(..., frames=100, ...)`。
- 期望：超长 block 返回错误，或截断时把被丢弃的帧计入 `dropped`，并让调用方可见。
- 实际：`copy = min(frames, max_frames)`，返回 1（成功），`FRBlockMeta.frames=64`，36 帧静默丢失，`dropped` 不变。
- 证据：`Tests/CoreTests/RingBufferTests.swift::testBlockRingOversizedPushTruncatesToMaxFrames` 通过（该测试明确 pin 当前行为）；L0 日志 `REPORTS/2026-11-07-coretests.log`。
- 影响：当前 `max_frames=16384`、HAL block 通常 ≤4096，正常路径不可达；但一旦驱动/aggregate 给出更大 block，会静默丢尾。
- 建议：返回 -1 或增加 truncated/dropped 计数；调用方记录诊断。
- 状态：Open（待 Dev 决策）

### QA-003 · P3 · `fr_block_ring_push` 头文件语义与实现不一致

- 文件：`Sources/CRing/FRAudioRing.h`（`channels must be <=`）与 `Sources/CRing/FRAudioRing.c:207`（`channels != ring->channels` 直接返回 -1）
- 复现：创建 2ch ring，push `channels=1`。
- 期望：按头文件“<= 创建通道数”接受并只写前 1 通道，或把头文件改成“必须相等”。
- 实际：返回 -1。
- 证据：`RingBufferTests::testBlockRingRejectsChannelMismatchAndEmptyPush`。
- 影响：调用方若按头文件传更少通道会失败；当前唯一调用方 `DeviceTapCapture` 总是传精确通道数，未触发。
- 建议：统一文档与实现；若支持更少通道，明确未写通道的填充规则。
- 状态：Open（待 Dev）

### QA-004 · P2 · WAV 头在 `close()` 前 dataSize 一直为 0，崩溃后文件时长错误

- 文件：`Sources/Core/WAVWriter.swift:49`（初始化写 `dataBytes: 0`）与 `:85-95`（仅 close 回填）
- 复现：创建 writer，写 10 帧，在 close 前用另一个句柄读取文件：文件已有 80 字节 PCM，但 `data` chunk size 仍为 0；进程若在此刻被杀，磁盘上的 WAV 头就是 0 长度。
- 期望：崩溃后可通过“总文件大小 - 44”修复 dataSize/RIFF size，或录制中周期性回填；至少启动时提供修复工具。
- 实际：无周期回填、无修复扫描；`close()` 才写正确头。
- 证据：`WAVWriterTests::testHeaderDataSizeStaysZeroUntilClose`（当前行为 pin）；`WAVWriter.swift:49/85-95`。
- 影响：G6 崩溃恢复要求下，remote.wav/mic.wav 可能被播放器显示 0 秒；PCM 字节仍在，可手工修复。
- 建议：启动时扫描 session 目录，按文件大小修复头；或每 N 秒回填一次（注意不要与写线程竞争）。
- 状态：Open（待产品/Dev 决策；影响 G6）

### QA-005 · P2 · 远端设备未强制为虚拟声卡，自检音可能从物理扬声器播出

- 文件：`Sources/Core/RecorderEngine.swift:432-446`（`validate` 只检查 `outputChannels > 0`）
- 复现：把 `remoteDeviceUID` 设为 `BuiltInSpeakerDevice`（out=2ch），启动录制；自检会向该设备播放 1 kHz、幅度 0.06 的音。
- 期望：远端采集设备必须是 HomePod Flow / Virtual（或至少 UI 只允许该设备）；否则应返回 `invalidConfiguration`，不能发出可听自检音。
- 实际：只检查有输出通道；自检音会从内置扬声器播出，且“远端轨”实际是系统输出而非 FaceTime。
- 证据：`RecorderEngine.validate` 静态代码；`AudioProbe list` 显示 BuiltInSpeakerDevice out=2ch；自检 `runSelfTest` 直接向 `configuration.remoteDeviceUID` 播放。
- 影响：误选设备时产生可听蜂鸣、录制语义错误；当前 UI 可能限制，但引擎层无兜底。
- 建议：`validate` 增加 `device.isHomePodFlowDevice || device.isVirtual`；UI 同步过滤。
- 状态：Open（待 Dev/产品）

### QA-006 · P3 · `probeDuration` 用字符串替换推导 ffprobe 路径，遇到含 “ffmpeg” 的目录会错

- 文件：`Sources/Core/MediaMuxer.swift:189-190`
- 复现：设置 `FFMPEG_PATH=/Users/ffmpeg/bin/ffmpeg`，调用 `MediaMuxer.probeDuration`。
- 期望：ffprobe 与 ffmpeg 同目录，路径为 `/Users/ffmpeg/bin/ffprobe`。
- 实际：`replacingOccurrences(of: "/ffmpeg", with: "/ffprobe")` 会把目录名也替换，得到 `/Users/ffprobe/bin/ffprobe`，探测失败返回 nil。
- 证据：静态代码；当前默认 `/opt/homebrew/bin/ffmpeg` 不触发。
- 影响：自定义 FFMPEG_PATH 时 MP4/MKV duration 诊断为空；不影响 mux 成功。
- 建议：用 `deletingLastPathComponent().appendingPathComponent("ffprobe")`。
- 状态：Open（待 Dev）

### QA-007 · P3 · `channelLabels` 回退顺序与 HomePod Flow 实际 8ch 布局不同

- 文件：`Sources/Core/CoreAudioSupport.swift:250`
- 复现：设备不提供 `kAudioDevicePropertyPreferredChannelLayout` 时，8ch 回退为 `FL FR FC LFE SL SR BL BR`。
- 期望：与设备实际/文档一致的 `FL FR FC LFE BL BR SL SR`。
- 实际：回退把 SL/SR 放在 BL/BR 前；实际设备描述为 BL/BR 在前。
- 证据：`G0_AUDIT.md` §3 与 `fr-tcc.json` 的 `preferredOutputChannelLabels`；静态 fallback 代码。
- 影响：仅诊断标签错误；降混仍按 FL/FR（0/1），音频不受影响。若未来按 BL/SL 标签做处理会出错。
- 建议：回退使用设备实际顺序，或直接复用文档常量。
- 状态：Open（待 Dev）

### QA-008 · P3 · 自检硬编码 FL/FR，单声道设备永远无法通过

- 文件：`Sources/Core/RecorderEngine.swift:418`
- 复现：用 1ch 设备运行 `runSelfTest`；`loud=[0]`，`!loud.contains(1)` 为 true。
- 期望：单声道设备按“唯一通道非零”判定 passed，或明确返回“不支持单声道”而不是 `partialChannels`。
- 实际：返回 `partialChannels`，即使采集正常。
- 证据：静态代码；`SelfTestMappingTests` 只覆盖 Code 语义/未知设备。
- 影响：非目标设备误报；HomePod Flow 8ch 不受影响。
- 建议：判定改为“期望通道集合”，由设备布局生成；至少 1ch 特判。
- 状态：Open（待 Dev）

### QA-009 · P3 · `MicTrackRecorder` 在 converter 创建失败时按 2ch 读取 1ch ring

- 文件：`Sources/Core/TrackRecorder.swift:332-353`（`if let converter ... else commit(samples:frames:)`）
- 复现：源格式 48 kHz/1ch，`AVAudioConverter` 创建返回 nil（当前代码只记录 `conversionError`，仍继续）；`converter == nil` 分支把 ring 当作 48k stereo 调用 `commit`，`commit` 固定按 `frame*2+channel` 读取。
- 期望：converter 创建失败时停止该轨并报告错误，或至少按实际通道数读取。
- 实际：可能越界读/写错误数据；错误只记录在 `conversionError`，录音继续。
- 证据：静态代码；正常 VPIO 路径通常会成功创建 converter，概率低。
- 影响：罕见配置下崩溃/脏数据；不影响正常 8ch 远端 + 44.1k mic 路径。
- 建议：converter nil 时 `return` 并设置失败状态；`commit` 接收通道数。
- 状态：Open（待 Dev）

### QA-010 · P3 · 麦克风 ring 溢出没有计数/诊断

- 文件：`Sources/Core/MonitorEngine.swift`（input tap 中 `_ = fr_sample_ring_write(...)`），`MicRecorderStats` 无 overflow 字段
- 复现：麦克风回调持续大于 `MicTrackRecorder` 消费速度（例如主线程/磁盘阻塞），ring 满后写入被丢弃。
- 期望：`micRingOverflows` 出现在 diagnostics，和 `monitorRingOverflows` 一样可诊断。
- 实际：返回值被忽略，无计数；只能从 WAV 帧数偏少间接猜测。
- 证据：静态代码；`Diagnostics.swift` 的 `MicDiagnostics` 无 overflow 字段。
- 影响：G3 丢帧可诊断性不足。
- 建议：增加原子计数并写入 diagnostics。
- 状态：Open（待 Dev）

### QA-011 · P3 · `resolveMonitorUID` 静默回退，诊断不记录请求值/回退原因

- 文件：`Sources/Core/RecorderEngine.swift:455-471`
- 复现：请求一个虚拟/不存在的监听 UID；引擎回退到默认物理设备。
- 期望：UI/诊断明确“请求的监听设备不可用，已回退到 X”，避免用户以为选中的是耳机。
- 实际：回退是静默的；`diagnostics.monitor.outputDeviceUID` 只记录最终值，没有 requested/reason。
- 证据：静态代码；现有 `monitor-mix` 诊断无 requested 字段。
- 影响：用户可能误判监听设备；不影响音频安全（回退到物理设备）。
- 建议：增加 `requestedOutputDeviceUID` 与 `resolveReason` 到 `MonitorStatus/Diagnostics`。
- 状态：Open（待 Dev）

### QA-012 · P3 · `MonitorEngine.start` 自身不拒绝虚拟输出，只依赖上层 `RecorderEngine`

- 文件：`Sources/Core/MonitorEngine.swift:65-112`、`:201-212`
- 复现：直接调用 `MonitorEngine().start(outputDeviceUID: "com.homepodflow.virtual-audio.surround71.v1", ...)`；`applyOutputDevice` 只检查 UID 能否翻译成设备，不检查 `isVirtual`。
- 期望：监听 API 自身拒绝虚拟/与采集相同的设备，或明确要求调用方保证；至少返回 warning/error。
- 实际：会尝试把 AVAudioEngine 输出设到虚拟 sink；听不到声音，且 `status.engineRunning` 仍可能为 true。
- 证据：静态代码；`RecorderEngine.resolveMonitorUID` 已在上层做了过滤，正常 App 路径不触发。
- 影响：未来新增调用方/测试工具可能绕过；防御性不足。
- 建议：在 `MonitorEngine.start` 内复用 `AudioDeviceCatalog` 的 `isVirtual` 检查，并返回明确错误。
- 状态：Open（待 Dev）

## 已验证但不算缺陷的观察

1. **`fr-tcc.json` 的 `durationSeconds=5.1841` 与 WAV 5.194667 s 相差约 10.6 ms**：前者来自 host time，后者来自样本数。当前未发现丢帧（`droppedBlocks=0`、`lostFramesEstimate=0`），记录为观察项，待长时间测试确认是否累积。
2. **`monitor-mix` 的 MP4 无 `title` 标签，只有 `handler_name=FaceTime Mix`**：MP4 标准下 title 不一定落盘；默认音轨只有一条，满足“默认播放”要求。若产品要求可见标题，再另开需求。
3. **`monitor-mix` 的 MKV 只有 2 条音轨**：该证据没有麦克风输入，代码在 mic 存在时才会生成第 3 条；离线双音测试已覆盖 3 轨。

## 复测记录

| 缺陷 | 复测命令/证据 | 结果 | 日期 |
|---|---|---|---|
| QA-002 | `RingBufferTests/testBlockRingOversizedPushTruncatesToMaxFrames` | 仍为截断成功 | 2026-11-07 |
| QA-004 | `WAVWriterTests/testHeaderDataSizeStaysZeroUntilClose` | 仍为 close 前 0 | 2026-11-07 |
| 其他 | 静态审查 | 未修复 | 2026-11-07 |

## 实现缺口（2026-11-07 极简 UI 新决策，非代码回归）

### GAP-UI-01 · P1 · 当前 UI 仍为完整多卡片，不是“两个开关 + 开始/停止”

- 文件：`Sources/App/ContentView.swift:20-40`（readiness/routing/capture/monitor/takeover/permissions 多卡片）、`:165-340`（设备/麦克风 Picker、画面/监听/接管 Toggle）。
- 期望：主界面只有“录制对方声音”“录制我的麦克风”两个开关 + 一个开始/停止；高级区默认收起；远端/麦克风/监听/接管自动。
- 实际：多卡片、多下拉、多开关；主流程需要用户理解设备与路由。
- 影响：TC-UI-01/02/06、G6-08/10 无法通过；不是新回归，是 UI 尚未按新决策改造。
- 状态：Open（待 UI/Dev）

### GAP-UI-02 · P1 · “关闭录制对方声音”没有 Core 实现路径

- 文件：`Sources/Core/Models.swift:192-230`（`RecorderConfiguration` 无 `recordRemote`）、`Sources/Core/RecorderEngine.swift:155-187`（start 总是创建 tap 并启动 `RemoteAudioRecorder`）。
- 期望：关闭“录制对方声音”时完全不启动 tap/aggregate、不写 remote.wav、不生成 Remote 轨、不接管系统输出；仅录麦克风+画面。
- 实际：没有关闭远端的配置/路径；只能通过不启动整个录制来规避，或可能被错误实现为“静音 remote 轨”。
- 影响：TC-UI-03、TC-L4-07、TC-L5-07、G1-10、G3-06、G4-08 均 BLOCKED。
- 状态：Open（待 Dev/UI）
