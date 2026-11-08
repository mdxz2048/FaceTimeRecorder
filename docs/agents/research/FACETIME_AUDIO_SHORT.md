# FaceTime 音频调研

**1. 能否 tap FaceTime**：能，但不能 tap `com.apple.FaceTime`——通话音频由 `/usr/libexec/avconferenced` 渲染。`CATapDescription(stereoMixdownOfProcesses:[id])`→`AudioHardwareCreateProcessTap`→私有聚合设备→IOProc→`AudioDeviceStart`。TCC=`kTCCServiceAudioCapture`，`NSAudioCaptureUsageDescription` 须直写 Info.plist（`INFOPLIST_KEY_*` 被忽略），弹窗在 AudioDeviceStart 触发。无失败码：拒绝时全 `noErr`、buffer 全 0。https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

**2. SCK `capturesAudio` 能录到对方吗**：不能。SCK 只在应用层，avconferenced 无窗口（Thunder Kitty 2026 实测，OBS 社区同）。官方仅有 `excludesCurrentProcessAudio`，无“排除受保护音频”说明，失败沉默。例外：输出改到 2ch 虚拟设备可录。

**3. 只支持 stereo/拒 8ch**：无官方说明。实证只取 ch1–2，多输出/聚合设备常无声（Apple SE 400591、RME“VoIP 只取 ch1”）。8ch 单流风险最高，2ch 稳定。

**最推荐**：tap `avconferenced`（stereo+私有聚合设备 48k/2ch）；兜底 BlackHole 2ch 作 FaceTime 输出再 tap 该设备。
