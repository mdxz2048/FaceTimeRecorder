# FaceTime Recorder 实现笔记（Dev Agent）

更新：2026-11-08  
范围：远端采集最终方案、麦克风 3ch 修复、后续高级设置收敛、音轨提取命令。  
约束：本文只记录实现事实与踩坑，不改产品代码；Core 源码以仓库当前版本为准。

## 1. 远端采集最终结论

**最终路径：Core Audio process tap on `avconferenced`。**

总调度已在真机实测该路径收到非零远端 PCM；本笔记按此结论记录。

FaceTime 的通话音频由 `/usr/libexec/avconferenced` 渲染，不是由 FaceTime UI 进程渲染。因此：

- 不要 tap FaceTime UI 进程；
- 不要依赖 HomePod Flow 虚拟声卡的 device tap 作为最终方案；
- 不要为了采集远端而切换系统默认输出；
- process tap 在输出设备之前取音频，FaceTime 可以继续从当前扬声器/耳机正常播放；
- 因此最终路径不需要监听输出、监听音量、系统输出 takeover，也不需要 AEC。

> 这一结论取代之前“监听固定为接管前物理默认输出”的方案；process tap 不切换默认输出，也不需要 AUHALMonitor。

`RecorderEngine` 会优先选择：

```text
recordRemote == true
  ├─ 找到 avconferenced → ProcessTapCapture（最终方案）
  ├─ 找不到且 recordVideo → ScreenCaptureKit 系统音频（内部回退）
  └─ 找不到且无视频 → DeviceTapCapture + SilentKeepAlive（内部回退，可能需要旧 takeover 逻辑）
```

最终产品说明和高级设置只应围绕第一条路径；回退路径由 Core 内部处理，不应暴露成用户设置。

## 2. PID → Process Object → Tap → Aggregate → IOProc

实现位置：`Sources/Core/ProcessTapCapture.swift`。

### 2.1 找 PID

```swift
ProcessTapCapture.findProcess(named: "avconferenced")
```

内部使用：

```text
/usr/bin/pgrep -x avconferenced
```

注意：

- 必须用 `-x` 精确匹配，避免匹配到带前后缀的辅助进程；
- PID 是 Unix `pid_t`，每次通话/进程重启都可能变化，**每个会话重新查找，不能缓存跨会话 PID**；
- 找不到时返回 `nil`，Core 才进入 SCK/device-tap 回退。

### 2.2 PID 不能直接当 AudioObjectID

`CATapDescription(stereoMixdownOfProcesses:)` 接收的是 **Core Audio process object**，不是 Unix PID。必须通过：

```text
kAudioHardwarePropertyTranslatePIDToProcessObject
```

在 `kAudioObjectSystemObject` 上做一次属性转换：

```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var pid = pid_t(...)
var object = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)

AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject),
    &address,
    UInt32(MemoryLayout<pid_t>.size),   // qualifier size
    &pid,                               // qualifier data = pid_t
    &size,
    &object)
```

必须检查：

```swift
status == noErr && object != kAudioObjectUnknown
```

**踩坑：** 直接把 `pid` 强转成 `AudioObjectID`（例如 `AudioObjectID(pid)`）传给 `CATapDescription`，对象会变成无效/不存在的 process object，日志里可能出现 `!obj`，之后常见结果是：

- tap 看似创建成功，但没有回调；
- 或回调全零；
- 或 `CATapDescription`/`AudioHardwareCreateProcessTap` 直接失败。

`!obj` 不是“进程没声音”，而是“你给的不是 Core Audio process object”。

另外两个实际踩坑点：

- `avconferenced` 进程刚启动时，PID 可能已经存在，但 Core Audio process object 还没注册；translation 返回 `kAudioObjectUnknown` 时建议短退避重试（例如 50 ms × 10），不要立刻判定“进程不存在”并回退到 device tap；
- process object 的生命周期跟随进程，通话结束/进程重启后旧对象失效；每个会话重新 `findProcess` + `processObject`，不要跨会话缓存 `AudioObjectID`。

### 2.3 创建 process tap

```swift
let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
description.name = "FaceTime Recorder call audio"
description.isPrivate = true
description.muteBehavior = .unmuted

AudioHardwareCreateProcessTap(description, &createdTap)
```

要点：

- 用 `stereoMixdownOfProcesses`，远端直接得到立体声混音；
- `isPrivate = true`，不暴露成系统可见设备；
- `muteBehavior = .unmuted`，不要静音原通话输出；
- 创建后通过 `kAudioTapPropertyUID` 取 tap UID，通过 `kAudioTapPropertyFormat` 取 tap 格式；
- 当前只接受 Float32 packed、1...8 通道；最终 stereo mixdown 通常是 2 通道。

### 2.4 私有 aggregate

tap 不能单独直接 start；需要挂到一个私有 aggregate 上：

```text
kAudioAggregateDeviceNameKey        = "FaceTime Recorder call capture"
kAudioAggregateDeviceUIDKey         = "com.mdxz.facetime.recorder.process.<UUID>"
kAudioAggregateDeviceIsPrivateKey   = true
kAudioAggregateDeviceIsStackedKey   = false
kAudioAggregateDeviceMainSubDeviceKey = <物理时钟设备 UID>
kAudioAggregateDeviceSubDeviceListKey = [[kAudioSubDeviceUIDKey: <物理时钟设备 UID>]]
kAudioAggregateDeviceTapAutoStartKey = true
kAudioAggregateDeviceTapListKey = [[
    kAudioSubTapUIDKey: <tapUID>,
    kAudioSubTapDriftCompensationKey: true
]]
```

时钟设备必须是**物理输出**：

- 优先当前默认输出（如果它不是 HomePod Flow 虚拟设备）；
- 否则用 `BuiltInSpeakerDevice`；
- 不能把 HomePod Flow 虚拟声卡当 process tap aggregate 的主时钟。

### 2.5 IOProc

```swift
AudioDeviceCreateIOProcID(
    aggregate,
    processTapIOProc,
    Unmanaged.passUnretained(context).toOpaque(),
    &ioProc)

AudioDeviceStart(aggregate, ioProc)
```

IOProc 只做实时安全的事情：

- 检查 `input.mNumberBuffers == 1`；
- 检查 `mNumberChannels == channels`；
- `frames = mDataByteSize / (4 * channels)`；
- 将 Float32 interleaved 样本推入 SPSC block ring，同时记录 `hostTime/sampleTime/timestampFlags/sequence/droppedBefore`；
- 清零 output buffer；
- 不分配、不加锁、不做文件 IO、不日志。

### 2.6 清理顺序

```text
AudioDeviceStop(aggregate, ioProc)
AudioDeviceDestroyIOProcID(aggregate, ioProc)
AudioHardwareDestroyAggregateDevice(aggregate)
AudioHardwareDestroyProcessTap(tap)
fr_block_ring_destroy(ring)
```

`deinit` 也要调用 stop；否则私有 aggregate/tap 可能泄漏，下一次创建会失败或行为异常。

### 2.7 与旧 device tap 的区别

- `ProcessTapCapture`：按 **进程** 取 avconferenced，`deviceUID = "process:<pid>"`；
- `DeviceTapCapture`：按 **设备 UID** 取该设备的渲染混音，是旧方案/回退；
- process tap 的 WAV 通过 `RemoteAudioRecorder(source: tap, labels: ["FL", "FR"], mode: .stereoDownmix, monitorRing: nil)` 写入；
- process tap 不需要 `SilentKeepAlive`，不需要 takeover，也不需要监听 ring。

## 3. TCC、自检与“非零”验证

- process tap 仍受音频采集 TCC 约束；未授权时可能创建成功但全零。
- 旧的“向 HomePod Flow 播 1 kHz，再 tap 检测 FL/FR”自检针对 device tap；**不能验证 avconferenced process tap**。
- 最终 path 的自检应改成：启动 process tap 后，在真实 FaceTime 通话中确认收到非零 remote blocks/RMS；不能伪造通过。
- 1.5 秒内没有音频块是正常的“等待通话音频”，应记录 warning，不要把它当成 tap 失败。
- 诊断中应保留 tap UID/aggregate UID/clock、回调数、帧数、RMS/Peak、首块 host time、静音帧数。

## 4. 麦克风 3ch 问题与修复

### 4.1 问题

MacBook 内置麦克风阵列常报告 3 通道（甚至更多）。`AVAudioFormat` 的 interleaved 3 通道布局可能无法创建，导致：

```text
AVAudioConverter could not be created
microphone format unavailable: sr=... ch=3 flags=...
```

最终表现为麦克风轨没有数据或启动失败。

### 4.2 当前已做的修复：>2ch 降单声道

`Sources/Core/MicCaptureRecorder.swift`：

```swift
downmixToMono = nativeFormat.mChannelsPerFrame > 2
let targetChannels: UInt32 = downmixToMono ? 1 : nativeFormat.mChannelsPerFrame
```

降混时取输入块的第 0 通道：

```swift
destination[0][frame] = base[frame * inputChannels]
```

然后交给 `AVAudioConverter` 转成 48 kHz stereo：

```text
native(1..2ch, native sample rate)
  → mono (if native > 2ch)
  → 48 kHz / 2ch / Float32
→ microphone.wav
```

为什么取 channel 0 而不是平均所有通道：

- 内置阵列的第 0 通道通常是主/波束成形信号；
- 直接平均 3 通道可能互相抵消、变闷或降低信噪比；
- 当前实现选择 channel 0，是已验证可用的折中。

### 4.3 还需要补的软件增益：+12 dB

当前 `MicCaptureRecorder.commit()` 直接把样本写入 WAV，**没有 +12 dB 软件增益**。修复思路：

- 在降混/转换完成后、写 `microphone.wav` 之前乘增益：

```text
gain = pow(10, 12.0 / 20.0) ≈ 3.9810717
sample = clamp(sample * gain, -1.0, 1.0)
```

- 增益应作用在麦克风轨本身，这样：
  - `microphone.wav` 不会过小；
  - 最终 Mix 轨也自然获得同样增益；
  - 只在混音 filter 里加 `volume=3.98` 会让独立 Mic 轨仍然偏小，不推荐。
- 可按峰值做软限幅/峰值保护，避免 +12 dB 后削波；当前代码没有这一步。
- 建议用 `ffmpeg -af astats` 对比修复前后的 Peak/RMS，确认不是靠 limiter 掩盖削波。

### 4.4 混音端 limiter

`Sources/Core/MediaMuxer.swift` 已使用：

```text
[remote]aformat=...volume=1.0[rmt]
[mic]aformat=...volume=1.0[mic]
[rmt][mic]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[mix]
```

要点：

- `normalize=0`：不要因为 1 路变 2 路自动把音量减半；
- `alimiter=limit=0.95`：两轨相加后的峰值保护；
- +12 dB 应先作用在 Mic 轨，再由 Mix 端 limiter 兜底；
- 若要检查，用 `ffmpeg -i FaceTime.mkv -map 0:a:0 -af astats -f null -` 查看 Peak/RMS 和 clipping。

### 4.5 AEC 说明

最终麦克风路径是 `DirectInputCapture` + `MicCaptureRecorder`，不是 `AVAudioEngine`/VoiceProcessingIO，因此：

- `stats.aecEnabled` 为 `false`；
- 旧的 AEC 开关在最终 UI 中应删除；
- 不要把“AEC 已开启”写进产品文案。
- 删除 AEC 后，外放场景下麦克风可能录到对方声音；产品文案应建议耳机，且不得宣称已消除回声。

## 5. 高级设置收敛清单

process tap 最终方案下，高级设置应删除：

- 远端设备 Picker（`remoteDeviceUID`）；
- 监听输出 Picker（`monitorOutputUID`）；
- 监听音量 Slider；
- 系统输出 takeover 开关（`takeOverSystemOutput`）；
- AEC 开关（`echoCancellation`）。

保留：

- 窗口选择；
- 刷新窗口；
- 权限（麦克风/屏幕/系统音频）；
- 诊断（诊断路径、日志、会话素材）。

“录制对方声音”开关本身保留（映射 `recordRemote`），删除的是它下面的远端设备选择；“录制我的麦克风”开关同样保留。

原因：

- 远端按 `avconferenced` 进程取，不按设备取；
- process tap 在输出前取音频，FaceTime 正常从当前输出播放，不需要 takeover/监听；
- 麦克风走 DirectInputCapture，不启用 VPIO，AEC 不适用；
- 窗口选择/刷新仍用于 ScreenCaptureKit 画面源；
- 权限和诊断仍是排障必需。

> 备注：旧 device-tap 回退内部仍可能用到 takeover/monitor，但那是 Core 的兜底实现，不应作为用户高级设置暴露。

## 6. 音轨提取命令

正常双音源时，`FaceTime.mkv` 的音频轨约定：

```text
0:a:0 = Mix（Remote + Mic，默认播放）
0:a:1 = Remote（对方）
0:a:2 = Mic（本地麦克风）

画面：0:v:0
```

先确认：

```bash
ffprobe -v error -select_streams a \
  -show_entries stream=index,codec_name:stream_tags=title \
  -of compact FaceTime.mkv
```

提取：

```bash
ffmpeg -y -i FaceTime.mkv -map 0:a:0 -c copy mix.m4a
ffmpeg -y -i FaceTime.mkv -map 0:a:1 -c copy remote.m4a
ffmpeg -y -i FaceTime.mkv -map 0:a:2 -c copy mic.m4a
```

提取为 WAV（示例：Remote）：

```bash
ffmpeg -y -i FaceTime.mkv -map 0:a:1 \
  -c:a pcm_s16le -ar 48000 -ac 2 remote.wav
```

MP4 只有一个混音音轨：

```bash
ffmpeg -y -i FaceTime.mp4 -map 0:a:0 -c copy mix.m4a
```

注意：

- 只有双音源都存在时，固定 `a:0/a:1/a:2` 才成立；
- 如果关闭了麦克风或远端，Core 只映射存在的轨，索引会前移；
- 此时用 `ffprobe` 的 `title`/`handler_name` 识别（Mix / Remote / Microphone）。

## 7. 验证清单

- [ ] `pgrep -x avconferenced` 能找到进程；
- [ ] `kAudioHardwarePropertyTranslatePIDToProcessObject` 返回非 `kAudioObjectUnknown`；
- [ ] `CATapDescription(stereoMixdownOfProcesses:)` 的 description 不出现 `!obj`；
- [ ] `AudioHardwareCreateProcessTap` 成功，且 tap format 为 Float32 packed；
- [ ] 私有 aggregate 的时钟是物理设备，不是 HomePod Flow；
- [ ] IOProc 有回调，真实 FaceTime 通话时 remote RMS/Peak 非零；
- [ ] 停止后 aggregate/tap/IOProc 全部销毁，重复开始不报错；
- [ ] 麦克风 3ch 能降为 mono 并生成 `microphone.wav`；
- [ ] +12 dB 增益已生效，Mix 端 `alimiter=0.95` 未持续削波；
- [ ] `FaceTime.mkv` 的 Mix/Remote/Mic 三音轨可用上述命令提取。
