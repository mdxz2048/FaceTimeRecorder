# G0 现状审计报告

日期：2026-11-07 · 执行：总调度 · 主机：MacBook Pro（Apple Silicon）

## 1. 结论摘要

| 问题 | 结论 | 证据 |
|---|---|---|
| 现有 HomePod Flow 声卡是否实现 Loopback 输入？ | **否**。设备只有输出 stream，WriteMix 是 sink，无共享 PCM、无输入通道、无客户端时间戳 | 设备枚举 + 驱动源码 |
| 能否读取 FaceTime 远端声音？ | **可以走 device tap**，但必须：(a) FaceTime 输出到该虚拟设备；(b) 进程获得音频录制 TCC | 历史 GUI 证据 + 本次对照实验 |
| 无 TCC 时会发生什么？ | 回调与帧数完全正常，但**所有样本为 0**，不会报错 | 303 次回调/155136 帧/全零 |
| 是否需要改驱动？ | 不需要。不得修改现有驱动 | 本结论 |
| 是否影响 HomePod Flow？ | 本工具只读设备、创建私有 tap/aggregate，不改驱动、不改默认输出（除非用户显式开启接管） | 设计约束 |

## 2. 系统与工具

- macOS 26.5.2（25F84），arm64。
- Xcode 26.6（17F113），Swift 6 工具链。
- xcodegen 2.45.4、ffmpeg 9.0.2，位于 `/opt/homebrew/bin`（非交互 ssh 需显式加入 PATH）。
- 新工程目录：`/Users/lvzhipeng/Developer/FaceTimeRecorder`（独立于旧仓库）。

## 3. 设备枚举（AudioProbe list）

```
[69] HomePod Flow Audio
  UID        : com.homepodflow.virtual-audio.surround71.v1
  model      : com.homepodflow.virtual-audio.model.surround71.v1
  transport  : Virtual (0x76697274)
  direction  : in=0ch / out=8ch
  sampleRate : 48000 Hz
  buffer     : 512 frames
  latency    : device=0 safety=0 frames
  out stream 70: 48000 Hz, 8 ch, Float32, 32 B/frame
  labels     : FL FR FC LFE BL BR SL SR
```

关键点：

- **0 个输入 stream、0 个输入通道**。系统设置里不会出现“HomePod Flow Audio 输入”。
- 8 声道布局由驱动给出，顺序为 `FL FR FC LFE BL BR SL SR`，与常见 7.1 的 `FL FR FC LFE SL SR BL BR` 不同；取 FaceTime 立体声必须按标签取 FL/FR（索引 0/1），不能假定后 4 通道顺序。
- `kAudioDevicePropertyBufferFrameSize` 由 coreaudiod 管理（15..4096），驱动自身报 512 不代表固定 512；DoIO 必须接受可变帧数。

其他设备：MacBook Pro 扬声器（2ch/48k）、MacBook Pro 麦克风（1ch/44.1k）、iPhone 连续互通麦克风（1ch/48k）。

## 4. 驱动实现审计（只读）

参考路径（旧仓库，未修改）：

```
platforms/macos/VirtualAudioDriver/src/FlowVirtualAudio.c
```

- `DoIO` 只接受 `kAudioServerPlugInIOOperationWriteMix`，注释明确写着：
  > Intentionally consumes no data. Tap visibility of this render stream must be demonstrated externally; **this sink is not itself a loopback device**.
- 没有 ReadInput 实现，没有共享缓冲区，没有把 WriteMix 数据暴露给其他进程。
- `kAudioDevicePropertyStreams` 的 input scope 返回 0。
- 运行状态使用引用计数 `gRunning`；多客户端时共享同一设备时钟，新增客户端不重置时钟。
- 因此“从虚拟声卡输入端读取”在本设备上**不成立**。正确路径是 tap 它的输出。

## 5. TCC 对照实验

### 5.1 虚拟设备 tap + 向虚拟设备播放 1 kHz 正弦

```
create tap status=0
create aggregate status=0
start status=0
tone start status=0
RESULT callbacks=303 frames=155136 nonzero=0
ch0..ch7 rms=0.0 peak=0.0
```

### 5.2 内置扬声器 tap + 向内置扬声器播放 800 Hz 正弦

```
RESULT cb=232 frames=118784 nz=0 peak=0.0 rms=0.0
```

### 5.3 解释

两种设备、两条完全不同的信号链都得到“回调正常、帧数正常、样本全零”。这排除了“虚拟声卡不转发声音”这一单一解释，指向**运行环境没有音频采集授权**：通过 sshd 启动的进程不属于已授权的 GUI App，TCC 让 tap 返回静音而不是错误。

历史记录（旧项目第六候选验收）显示：在带 `NSAudioCaptureUsageDescription` 且已授权的 GUI 进程中，同一虚拟设备的 device tap 得到 `callbacks=301 frames=154112 nonzero=142436 rmsL=0.169940 rmsR=0.000000`，左右声道独立。这说明数据面本身可行，但**必须由已授权 GUI 进程执行**。

### 5.4 产品要求

- 首次启动必须引导用户在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制/麦克风”中授权。
- 每次开始录制前做 **1 秒非静音自检**（向虚拟设备播极低电平 1 kHz，tap 读取 RMS）。失败则拒绝开始，并显示 `permission_required` 或 `route_silent` 的具体诊断。
- 禁止把“tap 创建成功”当作“能录到 FaceTime”。

## 6. 对产品方案的约束

1. 不改驱动、不加 Loopback、不重构 HomePod Flow。
2. 录制必须使用私有 device tap + aggregate；aggregate 的时钟必须来自另一个真实输出设备（不能是虚拟设备自己）。
3. FaceTime 使用系统默认输出；App 需要可选、可逆的默认输出接管，并在停止/退出/崩溃恢复时还原。
4. 远端音轨默认取 FL/FR 降混为立体声；保留 8ch 原始采集用于诊断。
5. 监听必须把远端 PCM 送到用户选择的物理输出；麦克风不得回放。
6. 所有“通过”必须有 WAV/JSON/日志证据；FaceTime 真人通话验收只能由用户完成。

## 7. 复现命令

```sh
cd /Users/lvzhipeng/Developer/FaceTimeRecorder
export PATH=/opt/homebrew/bin:$PATH
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme AudioProbe \
  -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
build/Build/Products/Debug/AudioProbe list
build/Build/Products/Debug/AudioProbe tap \
  --uid com.homepodflow.virtual-audio.surround71.v1 \
  --seconds 5 --tone --wav /tmp/fr-probe.wav --report /tmp/fr-probe.json
```

预期（无 TCC 的 ssh 环境）：`callbacks > 0`，`frames > 0`，`code = all_zero_pcm`。这本身就是诊断证据，不是失败伪装。
