# 远端通话音频采集方案（V1 正式方案）

更新：2026-11-08 · 状态：process tap 已实测非零；真人通话完整验收待签字

## 1. 结论

FaceTime 的对方声音**不通过普通系统混音，也不保证进入虚拟声卡**。  
V1 正式采用 **Core Audio process tap 采集 `/usr/libexec/avconferenced`**，而不是 tap 虚拟声卡，也不是 ScreenCaptureKit 系统音频。

实测成功数据（2026-11-07 20:32）：

- `remote.wav`：468,992 帧，RMS 0.012，峰值 0.375
- 来源：`process:755`（avconferenced）
- MP4 / MKV 均生成成功

## 2. 为什么不用虚拟声卡

| 路径 | 实测结果 |
|---|---|
| 普通系统声音 `afplay` → 8ch 虚拟声卡 → device tap | ✅ 非零 PCM（peak 0.0063） |
| FaceTime → 8ch 虚拟声卡 → device tap | ❌ 回调/帧数正常，样本全 0 |
| ScreenCaptureKit `capturesAudio=true` | ❌ 本机未拿到 FaceTime 音频；avconferenced 无窗口，SCK 在应用层抓不到 |
| process tap `avconferenced` | ✅ 非零 PCM（RMS 0.012，peak 0.375） |

原因：FaceTime 通话音频由后台进程 `/usr/libexec/avconferenced` 渲染；它不是普通 App 音频，也不保证输出到 8ch 虚拟设备。

## 3. 正式链路

```text
FaceTime 通话
  ↓
/usr/libexec/avconferenced
  ↓ pgrep avconferenced → PID
  ↓ kAudioHardwarePropertyTranslatePIDToProcessObject
Core Audio process object
  ↓ CATapDescription(stereoMixdownOfProcesses:)
AudioHardwareCreateProcessTap
  ↓ 私有 Aggregate Device（内置扬声器作时钟）
AudioDeviceCreateIOProcID
  ↓
48 kHz / 2ch / Float32 PCM → remote.wav

麦克风（BuiltInMicrophone，3ch/44.1k）
  ↓ HAL input IOProc
  ↓ 3ch → 单声道
  ↓ AVAudioConverter → 48k stereo
microphone.wav

屏幕（ScreenCaptureKit，选中的 FaceTime 窗口）
  ↓ AVAssetWriter H.264（Retina 2×，20 Mbps）
screen.mov

停止后 FFmpeg
  ↓ amix（Remote + Mic）+ itsoffset（音画对齐）
FaceTime.mp4（1 条混音轨）
FaceTime.mkv（Mix / Remote / Microphone 三轨）
```

## 4. 关键 API 与权限

- API：`CATapDescription` + `AudioHardwareCreateProcessTap`（macOS 14.2+ 公开 API）
- 进程对象：必须先用 `kAudioHardwarePropertyTranslatePIDToProcessObject` 把 Unix PID 转成 `AudioObjectID`；直接传 PID 会得到 `!obj`。
- TCC：`kTCCServiceAudioCapture`（音频录制）、Screen Recording、Microphone。
- Info.plist：`NSAudioCaptureUsageDescription` 必须直接写入 plist；仅用 `INFOPLIST_KEY_*` 可能不生效。
- 拒绝时：tap 创建可能返回 `noErr`，但 PCM 全 0；必须做非静音自检/诊断，不能把“启动成功”当作“录到”。

## 5. 监听与系统输出

- process tap 模式下**不接管系统输出**，也不启动 AUHAL 监听；
- FaceTime 照常从 MacBook 扬声器/耳机播放，用户自然听到对方；
- 麦克风永不进入监听；
- 旧虚拟声卡模式（device tap + AUHAL 监听）保留为兼容/诊断路径，不作为 FaceTime 主路径。

## 6. 麦克风音量偏小的原因与修复

实测：`microphone.wav` RMS 0.00117、峰值 0.037，比远端低约 20 dB。

原因：

1. 本机内置麦克风是 **3 声道阵列**，当前只取 **ch0**；
2. 没有输入增益/AGC；
3. 混音时 mic 仍按 1.0，远端 RMS 明显更高，所以听起来小。

修复计划：

- 3ch 改为**取能量最大通道**或三路平均（先测量再定）；
- 软件增益 **+12 dB**，峰值限幅（limiter）防止削波；
- 混音端 mic 单独增益，MP4 混音保持双方响度接近；
- 高级里显示麦克风峰值，削波时提示。

## 7. 后期提取音轨

MKV 音轨顺序固定：

| 索引 | 内容 |
|---|---|
| 0 | Mix（对方 + 麦克风） |
| 1 | Remote（对方） |
| 2 | Microphone（你） |

提取命令：

```sh
# 提取对方
ffmpeg -i FaceTime.mkv -map 0:a:1 -c copy remote.m4a

# 提取自己
ffmpeg -i FaceTime.mkv -map 0:a:2 -c copy microphone.m4a

# 提取混音
ffmpeg -i FaceTime.mkv -map 0:a:0 -c copy mix.m4a

# 只保留视频 + 对方音轨
ffmpeg -i FaceTime.mkv -map 0:v:0 -map 0:a:1 -c copy remote_only.mp4
```

说明：

- `FaceTime.mp4` 只有一条混音轨，无法从 MP4 分离两路；
- 会话目录同时保留 `remote.wav` 与 `microphone.wav`，可直接用于后期；
- MKV 是“多轨归档”，MP4 是“直接播放/分享”主文件。

## 8. UI 收敛

process tap 生效后，以下高级设置不再需要：

- 远端设备（HomePod Flow）
- 监听输出
- 系统输出接管
- AEC

保留：

- 录制窗口选择 + 刷新窗口
- 权限状态
- 诊断文件 / 日志
- 麦克风峰值提示

## 9. 验收

- process tap 启动、回调/帧数、非零 RMS；
- PID→process object 负例（`!obj`）；
- 3ch 麦克风降单声道后非零、增益不削波；
- MP4 默认播放双方声音；
- MKV 三轨可独立提取；
- 手动选择 FaceTime 窗口后为 Retina 2× 分辨率。
