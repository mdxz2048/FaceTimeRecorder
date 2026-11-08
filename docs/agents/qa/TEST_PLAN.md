# FaceTime Recorder 测试计划

版本：1.2 · 日期：2026-11-07 · 作者：测试 Agent · 状态：L0 已实现并执行；L1 已执行；极简 UI 目标待实现；L2–L6 待执行

> **2026-11-07 总调度新决策（覆盖旧 UI 方案）**：产品改为极简 UI，只保留两个开关（“录制对方声音”“录制我的麦克风”）和一个开始/停止按钮。远端设备、麦克风、监听、系统输出接管全部自动；高级区默认收起。旧的多卡片/多下拉方案不再作为验收目标。
>
> 本版新增 `L2-UI` 默认路径与开关组合用例，并把“关闭远端/关闭麦克风”纳入 G1/G2/G3/G4 验收。旧的真人 FaceTime、双音混音、监听物理输出、30 分钟稳定性用例全部保留。

## 0. 结论摘要

1. **L0 离线单测已落地**：6 个 XCTest 文件、67 个测试方法，在 macOS 26.5.2 / Xcode 26.6 上通过。命令与日志见 `REPORTS/2026-11-07-baseline.md` 和 `REPORTS/2026-11-07-coretests.log`。
2. **L1 设备枚举已执行**：HomePod Flow Audio 仍为 Virtual、0 输入 / 8 输出、48 kHz、Float32、32 B/frame，标签为 `FL FR FC LFE BL BR SL SR`。见 `REPORTS/2026-11-07-l1-audioprobe-list.txt`。
3. **L5 的封装层双音测试已离线执行**：合成 440 Hz 远端 + 880 Hz 麦克风，`FaceTime.mp4` 只有一条混音轨且两个频率都在；`FaceTime.mkv` 为 Mix / Remote / Microphone 三轨，顺序和隔离正确。见 `REPORTS/2026-11-07-dual-tone-verify.json`。这证明封装代码，不证明真机采集。
4. **监听路由已有诊断级检查**：现有 `monitor-mix` 证据中 tap 为虚拟设备、监听输出为 `BuiltInSpeakerDevice`，且引擎已加入“请求的监听设备不能是虚拟设备”的解析逻辑。见 `REPORTS/2026-11-07-monitor-route-verify.json`。
5. **尚未执行**：GUI 授权后的 L2 正向自检、30 分钟 L3、真机双轨 L4、带视频 L5、真人 FaceTime L6。任何人不得把现有合成波形证据写成“FaceTime 已支持”。
6. **极简 UI 是当前目标，不是当前事实**：截至本版，`Sources/App/ContentView.swift` 仍显示远端/麦克风选择器、画面开关、监听开关、接管控件等完整卡片；`RecorderConfiguration` 没有“关闭远端录制”字段，`RecorderEngine` 仍会始终启动 tap/远端轨。TC-UI/L2-UI 用例在 UI/Dev 改完前不能勾选。
7. **“关闭录制对方声音”是新增实现缺口**：当前 Core 没有 `recordRemote` 开关；不得用“启动 tap 但写空/静音远端轨”伪造只录麦克风。必须先由 Dev/UI 增加明确路径，QA 再验收。

## 1. 范围

### 1.1 范围内

- 远端采集：HomePod Flow Audio 的设备 tap、8 声道布局、FL/FR 降混。
- 本地麦克风：独立轨、AEC 开关、与监听互不影响。
- 监听：远端 PCM 到物理输出；监听开关不改变录音轨。
- 封装：`FaceTime.mp4` 单条混音轨（默认播放即同时听到双方）；`FaceTime.mkv` 首轨 Mix，随后 Remote、Microphone。
- 视频：ScreenCaptureKit 画面 + 双音轨。
- 异常：权限拒绝、设备拔插、设备忙、全零 PCM、mux 失败、崩溃恢复。

### 1.2 非目标

- 不修改 HomePod Flow 驱动，不验证驱动内部实现。
- 不验证 FaceTime 服务端、账号、网络质量。
- 不把 P1/P2 功能（例如多窗口、直播推流）纳入本轮门禁。
- 不在单测里模拟 TCC；TCC 只能在 GUI 进程里真实验证。

## 2. 测试分层与自动化边界

| 层级 | 名称 | 环境 | 自动化程度 | 证明什么 | 不能证明什么 | 对应门禁 |
|---|---|---|---|---|---|---|
| L0 | 纯离线单测 | macOS 15+、Xcode、无 TCC、无硬件依赖 | 全自动 | ring、重采样、WAV、降混映射、mux 参数、自检 Code 语义 | 真实设备、权限、音频内容 | 支撑 G1–G6 |
| L1 | 设备枚举 / 格式 | 真机、只读 Core Audio 枚举 | 全自动命令 + 人工核对 | 设备存在、方向、通道、采样率、标签 | 能否采集、TCC、路由 | G0/G1 |
| L2-UI | 极简 UI 默认路径 / 开关组合 | 真机 GUI、已授权 | 人工操作 + 截图 + 文件检查 | 两开关即可开始、自动设备/监听/接管、开关组合语义、高级区收起 | 音频内容、回声、长时稳定 | G1/G2/G3/G4 |
| L2 | GUI 授权后的 tap 自检 | 已授权 GUI 进程、虚拟声卡 | 人工授权 + 半自动自检 | tap 数据面、FL/FR 非零、权限区分 | FaceTime 内容、监听、麦克风 | G1 |
| L3 | 监听 30 分钟 | 真机、物理输出、真人听感 | 人工听 + 自动指标 | 稳定性、漂移、欠载、监听路由 | 内容正确性、回声 | G2 |
| L4 | 双轨 | 真机、麦克风、远端信号 | 人工录制 + 自动文件检查 | Remote/Mic 独立、时间戳、丢块 | 回声、视频 | G3 |
| L5 | 视频 + MKV/MP4 | 真机、ScreenCaptureKit | 人工录制 + 自动 ffprobe/频谱 | 容器、轨道顺序、A/V 同步、默认播放混音 | FaceTime 真人 | G4 |
| L6 | 真人 FaceTime | 两台设备/账号、真人通话 | 必须人工 | 端到端内容、回声、15 分钟稳定性 | 无 | G1/G5/G6 |

### 2.1 自动化 / 人工矩阵

| 检查项 | 可自动化 | 必须人工 | 说明 |
|---|---|---|---|
| L0 全部单测 | 是 | 否 | `xcodebuild test -scheme CoreTests` |
| 设备枚举与格式 | 是 | 否 | `AudioProbe list`，输出可归档 |
| 极简 UI 默认值/布局 | 半自动 | 是 | XCUITest 或截图核对两开关、开始/停止、高级区默认收起 |
| 默认路径自动设备/监听/接管 | 半自动 | 是 | 检查 diagnostics + 系统输出 + 人耳监听 |
| 关闭对方/关闭麦克风开关 | 半自动 | 是 | 文件结构自动检查 + 人耳确认 |
| 权限弹窗与授权 | 否 | 是 | TCC 只能由 GUI 用户操作 |
| 采集自检（1 kHz） | 半自动 | 授权、看结果 | 自检本身可由 App 执行并写 JSON |
| 监听是否真的听得到 | 否 | 是 | 需要人耳；诊断只能证明设备与电平 |
| 30 分钟稳定性 | 半自动 | 是 | 脚本计时/指标 + 人耳抽听 |
| 双轨是否独立 | 半自动 | 是 | ffprobe/WAV 检查 + 人耳 |
| 视频与音轨同步 | 半自动 | 是 | ffprobe + 拍手/口型人工判断 |
| 440 + 880 双音 | 半自动 | 是（真机注入） | 离线 mux 已验证；真机采集需扬声器/麦克风 |
| 回声（G5） | 半自动 | 是 | 需要真人说话、扬声器外放、人耳判断 |
| 真人 FaceTime | 否 | 是 | 两台设备、真实通话 |

## 3. 环境与前置

### 3.1 已知环境（2026-11-07）

- macOS 26.5.2（25F84），arm64。
- Xcode 26.6（17F113），xcodegen 2.45.4，ffmpeg/ffprobe 9.0.2（`/opt/homebrew/bin`）。
- 虚拟设备：`HomePod Flow Audio`，UID `com.homepodflow.virtual-audio.surround71.v1`，Virtual，0 输入 / 8 输出，48 kHz，Float32 packed，32 B/frame，标签 `FL FR FC LFE BL BR SL SR`。
- 物理输出：`BuiltInSpeakerDevice`（MacBook Pro 扬声器，2ch/48k）。
- 物理输入：`BuiltInMicrophoneDevice`（1ch/44.1k）；另有 iPhone 连续互通麦克风（1ch/48k）。

### 3.2 每次执行前

1. 确认只操作 QA 副本：`/Users/lvzhipeng/Developer/FaceTimeRecorder-qa`；不得修改主目录或虚拟声卡驱动。
2. 确认没有其他 App 独占虚拟设备或麦克风。
3. 记录 `date`、`sw_vers`、`xcodebuild -version`、`ffmpeg -version`。
4. 清空或新建独立输出目录，避免把旧 WAV/MKV 当成本次证据。
5. 检查系统默认输出、监听输出、FaceTime 输出路由，记录到证据 JSON。

### 3.3 构建与 L0 命令

```sh
export PATH=/opt/homebrew/bin:$PATH
cd /Users/lvzhipeng/Developer/FaceTimeRecorder-qa
xcodegen generate
xcodebuild -project FaceTimeRecorder.xcodeproj -scheme CoreTests \
  -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- test
```

## 4. 用例

### 4.1 L0：纯离线单测

> L0 的共同前置：macOS 15+、Xcode、已生成工程；不要求 TCC、麦克风、虚拟声卡或 ffmpeg。共同证据：`REPORTS/2026-11-07-coretests.log`。共同通过判据：`Executed 67 tests, with 0 failures`。

#### TC-L0-01 SPSC 基本写入/读取

- 前置：无。
- 步骤：运行 `RingBufferTests/testNewRingIsEmptyAndReportsConfiguration`、`testWriteThenReadReturnsExactFrames`、`testReadLessThanAvailableLeavesRemainder`。
- 期望：容量/可用帧数正确；写入后按写入顺序读出；读少于可用时保留剩余。
- 证据类型：XCTest 日志。
- 通过判据：3 个测试全部通过，样本逐位相等。
- 自动化：是。

#### TC-L0-02 回绕

- 前置：容量 1024、2 声道。
- 步骤：运行 `RingBufferTests/testWrapAroundPreservesOrder`；先写 700、读 700，再写 700 触发回绕。
- 期望：第二次写入跨过存储末端后仍按顺序读出。
- 证据类型：XCTest 日志。
- 通过判据：700 帧逐样本相等。
- 自动化：是。

#### TC-L0-03 溢出计数与部分写入

- 前置：容量 1024。
- 步骤：运行 `RingBufferTests/testOverflowIsCountedAndPartialWritesReturnRoom`。
- 期望：满时写入返回 0 且溢出计数 +1；释放 100 帧后写 200 只接受 100，不额外计溢出。
- 证据类型：XCTest 日志。
- 通过判据：返回值、可用帧数、溢出计数与上述一致。
- 自动化：是。

#### TC-L0-04 peek / advance / clear

- 前置：容量 1024。
- 步骤：运行 `RingBufferTests/testPeekDoesNotAdvanceAndHonoursOffset`、`testAdvanceClampsToAvailable`、`testClearDiscardsUnreadFrames`。
- 期望：peek 不推进读指针；offset 越界返回 0；advance 超过可用时钳制；clear 丢弃未读。
- 证据类型：XCTest 日志。
- 通过判据：全部断言通过。
- 自动化：是。

#### TC-L0-05 Block ring 元数据 / 丢块 / 超大块

- 前置：slots=4、max_frames=256、2 声道。
- 步骤：运行 `RingBufferTests/testBlockRingRoundTripPreservesMetadata`、`testBlockRingDropsWhenFullAndAcceptsAgainAfterPop`、`testBlockRingRejectsChannelMismatchAndEmptyPush`、`testBlockRingOversizedPushTruncatesToMaxFrames`、`testBlockRingPopWithTooSmallBufferDoesNotAdvance`。
- 期望：frames/channels/timestamp/host_time/sample_time/sequence/dropped_before 正确；满时 push 返回 0 并计数；pop 缓冲不足返回 -1 且不推进；超大块当前实现截断到 max_frames（见 DEFECTS QA-002）。
- 证据类型：XCTest 日志。
- 通过判据：全部断言通过，且测试名明确记录截断行为。
- 自动化：是。

#### TC-L0-06 重采样直通

- 前置：ring 7200 帧（等于 48 kHz 的 0.15 s 目标填充）。
- 步骤：运行 `DriftResamplerTests/testPassthroughAtTargetFillHasUnityRatio`，请求 480 帧。
- 期望：ratio=1，输出与输入逐样本一致，无欠载，读指针前进 480。
- 证据类型：XCTest 日志。
- 通过判据：`lastRatio == 1`、`underrunFrames == 0`、480 帧全部相等。
- 自动化：是。

#### TC-L0-07 比例偏差（过填/欠填）

- 前置：目标 1000 帧，最大 trim 0.01。
- 步骤：运行 `testOverfillTrimsRatioAboveOne`（填 4000，请求 100）和 `testUnderfillTrimsRatioBelowOne`（填 100，请求 100）。
- 期望：过填时 ratio > 1 且受 1.01 上限约束；欠填时 ratio < 1；输出按插值比例变化。
- 证据类型：XCTest 日志。
- 通过判据：ratio 分别约为 1.0002 / 0.9998；过填测试 `testRatioNeverExceedsMaximumTrim` 200 次后不超过 1.0100001。
- 自动化：是。

#### TC-L0-08 欠载补零

- 前置：空 ring，目标 1000 帧。
- 步骤：运行 `testUnderrunFillsZerosAndCountsMissingFrames`，请求 64 帧。
- 期望：输出全 0；欠载计数为 64+2 个保护帧；不崩溃。
- 证据类型：XCTest 日志。
- 通过判据：`underrunFrames == 66`，输出全零。
- 自动化：是。

#### TC-L0-09 重采样边界与无崩溃

- 前置：ring 有数据或无数据。
- 步骤：运行 `testZeroFrameRequestIsNoOp`、`testHugeRequestIsClampedToScratchAndDoesNotCrash`、`testTinyScratchDoesNotCrash`、`testPhaseContinuesAcrossProcessCalls`、`testResetRestoresUnityRatio`。
- 期望：0 帧无操作；超大请求被 scratch 钳制并计欠载；极小 scratch 不越界；相位跨调用连续；reset 恢复 ratio=1。
- 证据类型：XCTest 日志。
- 通过判据：全部测试通过，输出均为有限值。
- 自动化：是。

#### TC-L0-10 WAV 头字段

- 前置：临时目录。
- 步骤：运行 `WAVWriterTests/testHeaderFieldsForEmptyStereoFile`，写 0 帧并关闭。
- 期望：44 字节头；RIFF/WAVE/fmt/data；format=3；2ch；48 kHz；byteRate=384000；blockAlign=8；bits=32；dataSize=0；RIFF size=36。
- 证据类型：XCTest 日志。
- 通过判据：所有字段逐字节匹配。
- 自动化：是。

#### TC-L0-11 WAV duration / 写读回

- 前置：48 kHz、2ch。
- 步骤：运行 `testHeaderAndDurationArePatchedOnClose`、`testFloat32StereoRoundTrip`、`testDurationAtFortyFourOne`。
- 期望：关闭时回填 dataSize/RIFF size；480 帧 duration=0.01 s；Float32 逐位回读；44.1 kHz 下 44100 帧 duration=1.0。
- 证据类型：XCTest 日志。
- 通过判据：`WAVReader.info` 与写入值一致。
- 自动化：是。

#### TC-L0-12 WAV 单声道 / 非法参数 / 关闭后写入

- 前置：临时目录。
- 步骤：运行 `testMonoFileHasCorrectHeaderAndDuration`、`testInvalidConfigurationIsRejected`、`testWriteAfterCloseThrows`、`testCloseIsIdempotent`、`testEmptyWriteIsNoOp`、`testExplicitZeroFrameWriteIsNoOp`、`testHeaderDataSizeStaysZeroUntilClose`。
- 期望：单声道 blockAlign=4；非法 channels/rate 抛 `cannotCreate`；close 后写入抛 `closed`；重复 close 无异常；空写不改变长度；close 前 dataSize 仍为 0（QA-004 崩溃风险）。
- 证据类型：XCTest 日志。
- 通过判据：全部断言通过。
- 自动化：是。

#### TC-L0-13 降混按标签找 FL/FR（8ch）

- 前置：标签数组。
- 步骤：运行 `DownmixTests/testHomePodFlowEightChannelLayoutSelectsFirstTwo`、`testCanonicalSevenOneOrderStillSelectsFLFR`、`testSelectionFollowsLabelsWhenFLFRAreNotFirst`、`testSelectionFindsFLFRAtTheEnd`、`testSwappedLabelsAreHonoured`。
- 期望：实际布局 `FL FR FC LFE BL BR SL SR` 取 (0,1)；任意排列按标签取；不得把 BL/BR 当作左右。
- 证据类型：XCTest 日志。
- 通过判据：索引与标签一致。
- 自动化：是。

#### TC-L0-14 降混单声道 / 别名 / 缺标签 / 钳制

- 前置：标签数组。
- 步骤：运行 `testSelectionIsCaseInsensitive`、`testSelectionAcceptsLongNames`、`testMonoDuplicatesChannelZero`、`testMissingLabelsFallBackToFirstTwoChannels`、`testIndicesAreClampedToChannelCount`。
- 期望：大小写不敏感；Left/Right 别名；1ch 返回 (0,0)；缺标签回退 (0,1)；越界索引钳制。
- 证据类型：XCTest 日志。
- 通过判据：全部断言通过。
- 自动化：是。

#### TC-L0-15 Core Audio 标签名映射

- 前置：无。
- 步骤：运行 `DownmixTests/testCoreAudioLabelNamesMatchDeviceVocabulary`。
- 期望：Left→FL、Right→FR、Center→FC、LFE→LFE、LeftSurroundDirect→BL、RightSurroundDirect→BR、LeftSurround→SL、RightSurround→SR、Mono→M。
- 证据类型：XCTest 日志。
- 通过判据：全部相等。
- 自动化：是。

#### TC-L0-16 MKV 参数：Mix + Remote + Mic

- 前置：video/remote/mic 三个 URL。
- 步骤：运行 `MuxArgumentsTests/testMkvWithAllThreeInputsMapsMixThenRemoteThenMic`、`testMkvWithoutVideoReindexesInputs`、`testMkvMapOrderIsMixRemoteMic`、`testVideoOnlyProducesNoAudioArguments`、`testRemoteOnlyUsesAnullMixAndRemoteMetadata`、`testMicOnlyUsesAnullMixAndStreamOne`。
- 期望：MKV 音频顺序为 `[mix]`、Remote、Mic；标题分别为 Mix (Remote + Mic)、Remote、Microphone；无视频时输入索引重排；单轨时用 anull 生成 mix。
- 证据类型：XCTest 日志。
- 通过判据：参数序列、map 顺序、标题全部匹配。
- 自动化：是。

#### TC-L0-17 MP4 参数：只保留单条混音轨

- 前置：video/remote/mic 三个 URL。
- 步骤：运行 `MuxArgumentsTests/testMp4WithAllThreeInputsExportsSingleMixTrack`。
- 期望：只有 video map + `[mix]` map；没有 Remote/Mic 独立 map；`-movflags +faststart`；音频 AAC 256k/48k/2ch。
- 证据类型：XCTest 日志。
- 通过判据：音频 map 数为 1，且 filter 同时引用 remote 和 mic。
- 自动化：是。

#### TC-L0-18 mux 偏移 / 路径 / 空输入

- 前置：URL 含空格、偏移为正/负/极小值。
- 步骤：运行 `testOffsetsArePlacedImmediatelyBeforeTheirInput`、`testTinyAndNegativeOffsetsAreIgnored`、`testPathsWithSpacesArePassedAsSingleArguments`、`testMuxWithoutInputsThrowsBeforeRunningFFmpeg`、`testContainerRawValues`。
- 期望：`-itsoffset` 紧跟对应 `-i`；≤0.0005 或负数忽略；含空格路径作为单参数；全空输入抛 `invalidInputs`。
- 证据类型：XCTest 日志。
- 通过判据：全部断言通过。
- 自动化：是。

#### TC-L0-19 自检 Code 语义 / 未知设备

- 前置：无 TCC；使用不存在的 UID。
- 步骤：运行 `SelfTestMappingTests` 全部 6 个测试。
- 期望：5 个 Code 的 rawValue 稳定；只有 `.passed` 的 `passed == true`；未知设备返回 `.tapError`、0 回调、0 帧、空 RMS；错误描述包含 code。
- 证据类型：XCTest 日志。
- 通过判据：未知设备绝不返回 `.passed`。
- 自动化：是。

### 4.2 L1：设备枚举 / 格式

#### TC-L1-01 枚举 HomePod Flow Audio

- 前置：虚拟声卡已安装；QA 副本已构建 AudioProbe。
- 步骤：`build/Build/Products/Debug/AudioProbe list`。
- 期望：出现 `[69] HomePod Flow Audio`，UID `com.homepodflow.virtual-audio.surround71.v1`，transport Virtual，in=0ch/out=8ch，48000 Hz，buffer 512，32 B/frame。
- 证据类型：文本输出（`REPORTS/2026-11-07-l1-audioprobe-list.txt`）。
- 通过判据：上述字段逐项一致；退出码 0。
- 自动化：是。

#### TC-L1-02 8ch 标签顺序

- 前置：虚拟声卡已安装；QA 副本的 AudioProbe 可运行；`list` 输出包含 HomePod Flow 块。
- 步骤：检查 `AudioProbe list` 的 `labels` 行。
- 期望：`FL FR FC LFE BL BR SL SR`，不得写成常见 7.1 的 `FL FR FC LFE SL SR BL BR`。
- 证据类型：文本输出。
- 通过判据：标签顺序完全一致；降混仍只取 FL/FR。
- 自动化：是。

#### TC-L1-03 物理输入/输出存在

- 前置：Mac 内置设备可用。
- 步骤：检查 `list` 中 `BuiltInSpeakerDevice`（out=2ch/48k）与 `BuiltInMicrophoneDevice`（in=1ch/44.1k）。
- 期望：至少有一个物理输出和一个物理输入；监听不得落到虚拟设备。
- 证据类型：文本输出。
- 通过判据：两个 UID 存在且方向正确。
- 自动化：是。

#### TC-L1-04 ffmpeg/ffprobe 可用

- 前置：Homebrew 环境。
- 步骤：`which ffmpeg ffprobe`；`ffmpeg -version`；`ffprobe -version`。
- 期望：路径在 `/opt/homebrew/bin`，版本可读；`MediaMuxer.locateFFmpeg()` 能返回可执行路径。
- 证据类型：命令输出 + 环境记录。
- 通过判据：两者均可执行；否则 L5 只能标记 SKIPPED，不能标记 PASS。
- 自动化：是。

### 4.2A L2-UI：极简 UI 默认路径与开关组合（新增决策）

> **实现前置/当前缺口（2026-11-07）**：`Sources/App/ContentView.swift` 目前仍是多卡片界面（远端/麦克风选择器、画面开关、监听开关、接管控件等），不是“两个开关 + 开始/停止”；`Sources/Core/Models.swift` 的 `RecorderConfiguration` 没有“关闭远端录制”字段，`RecorderEngine.start` 仍总是创建 tap 并启动远端轨。以下 TC-UI 用例是目标验收，当前不能勾选。关闭远端不得用“写一条静音 remote 轨”伪造。默认值按“两开关开启”验收；若产品改为默认关闭，需同步更新用例，但“打开 App 只需两个开关即可开始”不变。

#### TC-UI-01 极简默认态与布局

- 前置：新极简 UI 已实现；HomePod Flow、物理输出、ffmpeg 可用；权限已授予（或首次启动允许弹权限）。
- 步骤：冷启动 App，不展开高级区；截图并检查可交互控件。
- 期望：主界面只有两个开关（“录制对方声音”“录制我的麦克风”）和一个开始/停止主按钮；两个开关默认开启；没有必须手动选择的远端设备/麦克风/监听下拉；高级区默认收起；开始按钮可用，或在缺权限/设备时给出具体原因。系统权限弹窗/首次“已获对方同意”确认不计入常驻控件，但不得变成第三个常驻开关。
- 证据类型：窗口截图、可访问性树/控件清单、启动日志。
- 通过判据：主流程不需要打开高级区或选择设备；默认两开关为开；高级区初始 collapsed。
- 自动化：人工/XCUITest（当前未建立 UI 测试）。

#### TC-UI-02 一键开始：设备/监听/接管全自动

- 前置：两个开关默认开启；系统默认输出为物理扬声器；权限已授予；HomePod Flow 存在。
- 步骤：启动后只点一次“开始”，录制 10 秒，停止；检查 diagnostics、系统输出、生成文件；人耳确认监听。
- 期望：远端自动解析为 `com.homepodflow.virtual-audio.surround71.v1`；麦克风自动选系统默认输入；监听自动解析到物理输出（内置扬声器/耳机，绝不是虚拟设备）；系统输出在开始时自动接管到虚拟设备，停止后恢复原物理输出；MP4 单混音轨、MKV 三轨；无需用户打开高级区。
- 证据类型：diagnostics.json、系统设置截图、MP4/MKV、人工听感。
- 通过判据：`outputTakeOver=true`；`tap.deviceUID` 为虚拟设备；`monitor.outputDeviceUID` 为物理设备且不等于 tap；停止后默认输出恢复；一次点击即可开始。
- 自动化：半自动（点击/授权人工，诊断可脚本检查）。

#### TC-UI-03 关闭“录制对方声音”：只录麦克风 + 画面

- 前置：极简 UI 已支持关闭远端采集；HomePod Flow 不需要参与；麦克风/屏幕权限已授予。
- 步骤：关闭“录制对方声音”，保持“录制我的麦克风”开启；开始，录制 10 秒；停止；检查会话目录、diagnostics、系统输出。
- 期望：只生成麦克风轨和视频；没有 tap/aggregate、没有 remote.wav、没有 Remote 音轨；不写输出接管 lease；系统默认输出保持/恢复为原物理设备；MP4 只有一条麦克风音轨；MKV 不含 Remote 轨（Mix/Microphone 的最终命名按产品确认，但不得伪造 Remote）；监听不应把虚拟设备当作输出。
- 证据类型：diagnostics、文件列表、ffprobe、系统输出截图、人工听感。
- 通过判据：无 remote 文件/轨；`outputTakeOver=false` 或停止后已恢复；默认输出不是虚拟设备；MP4 单音轨且内容为麦克风。
- 自动化：半自动。
- 依赖：**当前 Core 缺 `recordRemote` 开关，未实现前此用例 BLOCKED，不得用静音远端轨代替。**

#### TC-UI-04 关闭“录制我的麦克风”：只录对方 + 画面

- 前置：麦克风开关关闭；麦克风权限可拒绝；HomePod Flow、屏幕权限可用。
- 步骤：关闭“录制我的麦克风”，开始，录制 10 秒；停止；检查文件与权限提示。
- 期望：不请求/不阻塞于麦克风权限；没有 microphone.wav、没有 Microphone 轨；远端 tap、自动接管、物理监听照常；MP4 只有一条远端音轨；MKV 为 Mix + Remote（无 Microphone）。
- 证据类型：diagnostics、文件列表、ffprobe、权限截图。
- 通过判据：`microphone` 段缺失或 `recordMicrophone=false`；无 mic 文件/轨；远端轨非静音；接管/监听正常。
- 自动化：半自动。

#### TC-UI-05 两个开关都关闭

- 前置：两个开关均可关闭。
- 步骤：关闭两个开关；观察开始按钮；若仍可开始，录制 5 秒并检查产物。
- 期望（建议，待产品最终确认）：开始按钮禁用并显示“至少开启一项”；不得生成空音轨/空 MP4 假成功。若产品决定允许“仅画面”，主按钮必须明确写“仅录画面”，且 MP4 无音频轨、MKV 无音频轨，并在结果页提示无声音。
- 证据类型：截图、diagnostics、ffprobe。
- 通过判据：行为与产品最终口径一致；绝不生成“有文件但无任何声音且显示成功”的文件。
- 自动化：人工/XCUITest。

#### TC-UI-06 高级区默认收起且不影响主流程

- 前置：默认启动。
- 步骤：截图初始状态；展开高级区，修改/查看可选设置后收起；再切换两个主开关并开始；对比主流程。
- 期望：高级区初始 collapsed；展开不是开始录制的必要条件；收起后主开关状态保留；高级区的设备覆盖/诊断/音量等不改变默认路径的自动解析；布局不跳动、不遮挡开始按钮。
- 证据类型：展开前后截图、控件清单、diagnostics。
- 通过判据：不展开也能完成 TC-UI-02；展开/收起不改变两个主开关；没有必填高级字段。
- 自动化：人工/XCUITest。

#### TC-UI-07 默认路径失败时的自动诊断

- 前置：分别制造 HomePod Flow 缺失、无物理监听输出、屏幕权限拒绝、麦克风权限拒绝。
- 步骤：启动并点击开始；观察主界面原因/错误卡。
- 期望：每种失败给出短中文原因和下一步动作；不接管输出后不恢复；不生成假成功文件；麦克风拒绝只在“录制我的麦克风”开启时阻塞；屏幕拒绝可按产品降级为仅声音或明确阻止。
- 证据类型：截图、diagnostics、文件列表、系统输出状态。
- 通过判据：错误可理解、可恢复；系统输出不留在虚拟设备；无伪造音轨。
- 自动化：人工。

#### TC-UI-08 关闭对方时系统输出不被接管/已恢复

- 前置：系统默认输出原为物理设备；关闭“录制对方声音”；可先手动或由上次会话把默认输出设为虚拟设备，模拟残留。
- 步骤：开始仅麦克风+画面录制；停止；检查默认输出与 lease。
- 期望：App 不因远端关闭而接管虚拟设备；若检测到自己的旧 lease，恢复原物理输出；不覆盖用户手动选择；不出现“整台 Mac 没声音”。
- 证据类型：系统输出截图、lease 文件、diagnostics。
- 通过判据：停止后默认输出为物理设备；无遗留 lease；`outputTakeOver` 与实际行为一致。
- 自动化：半自动。

### 4.3 L2：GUI 授权后的 tap 自检

#### TC-L2-00 无 TCC 负对照

- 前置：通过 sshd 启动的进程，未获音频录制授权。
- 步骤：`AudioProbe tap --uid com.homepodflow.virtual-audio.surround71.v1 --seconds 5 --tone --wav ... --report ...`。
- 期望：callbacks > 0、frames > 0，但所有通道 nonzero=0、RMS/peak=0；verdict 为 `all_zero_pcm`，不得当成功。
- 证据类型：JSON + WAV。
- 通过判据：`code=all_zero_pcm` 且 `nonzeroSamples` 全 0；若返回错误，也必须是明确的权限/格式诊断，不能静默通过。
- 自动化：是（负向基线）。2026-11-07 18:36 CST 复跑（2 s）：206 callbacks / 105472 frames / 8 通道全零 / `all_zero_pcm` / 退出码 10；证据 `REPORTS/2026-11-07-l2-negative.json` 与 `.log`。

#### TC-L2-01 GUI 授权后 1 kHz 自检通过

- 前置：用户在“系统设置 → 隐私与安全性”授予音频录制/麦克风/屏幕录制；App 从 GUI 启动。
- 步骤：执行 App 的采集自检（1 秒，1 kHz，幅度 0.06），保存 JSON/WAV。
- 期望：`code=passed`；FL/FR RMS 明显非零；其余 6 通道为 0 或接近 0；无丢块。
- 证据类型：`diagnostics.json`、自检 JSON、WAV、ffprobe。
- 通过判据：`callbacks>0`、`frames>0`、`channelRMS[0]>0.01`、`channelRMS[1]>0.01`、`droppedBlocks=0`；人工确认 JSON 的权限结论。
- 自动化：半自动（人工授权）。

#### TC-L2-02 音频录制权限拒绝

- 前置：撤销“屏幕与系统音频录制”或音频采集授权。
- 步骤：再次启动/自检；观察 UI 与诊断。
- 期望：不进入 recording；返回 `allZero` 或 `tapError`；文案明确指出权限；不得弹出“录制成功”。
- 证据类型：UI 截图、diagnostics、JSON。
- 通过判据：状态为 failed；有具体权限诊断；无录音文件被标为成功。
- 自动化：半自动（人工撤销/授予）。

#### TC-L2-03 设备忙 / tap 创建失败

- 前置：另一进程独占虚拟设备或复用同一 tap 配置。
- 步骤：启动录制；观察错误码与恢复。
- 期望：`tapCreationFailed` / `aggregateCreationFailed` / `ioProcFailed` / `startFailed` 之一；UI 显示 OSStatus/fourCC；不留下半开 tap/aggregate。
- 证据类型：diagnostics、系统日志、`AudioProbe list`。
- 通过判据：错误明确、可重试、无崩溃；停止后设备仍可用。
- 自动化：半自动。

#### TC-L2-04 FaceTime 路由错误（自检不能替代）

- 前置：自检通过，但 FaceTime 输出到内置扬声器，未指向虚拟声卡。
- 步骤：真人通话 30 秒；观察 remote RMS 与 WAV。
- 期望：自检仍通过（因为自检音直接写入虚拟设备），但实际远端音轨接近静音；诊断提示“FaceTime 未路由到虚拟设备”。
- 证据类型：diagnostics、remote.wav、监听记录。
- 通过判据：不得把“自检通过”写成“FaceTime 可录”；必须有人工通话证据或明确失败结论。
- 自动化：人工。

#### TC-L2-05 监听输出不得选虚拟设备

- 前置：监听输出候选列表。
- 步骤：打开监听设备选择；检查 HomePod Flow Audio 是否出现；若通过配置强行指定虚拟 UID，检查引擎回退。
- 期望：UI 不提供虚拟设备；`RecorderEngine.resolveMonitorUID` 拒绝虚拟/与远端相同的 UID，回退到物理默认或 BuiltInSpeakerDevice；diagnostics 的 `monitor.outputDeviceUID` 不等于 `tap.deviceUID`；`MonitorEngine.start` 也应自行拒绝虚拟输出（QA-012）。
- 证据类型：UI 截图、diagnostics、`verify_monitor_route.py` 输出。
- 通过判据：虚拟设备不可选；强制配置时回退且记录 warning；人耳能听到监听。
- 自动化：半自动；诊断部分可用脚本。

### 4.4 L3：监听 30 分钟

#### TC-L3-01 30 分钟连续监听

- 前置：L2 通过；物理输出可用；播放一段 30 分钟已知音频到虚拟设备。
- 步骤：开始录制并开启监听；持续 30 分钟；每 5 分钟记录 RMS、ring fill、overflows、underruns；结束后听回放。
- 期望：全程可听；无爆音/断音；`monitorRingOverflows=0`；`monitorUnderrunFrames` 总量 ≤ 8640 帧（约 0.18 秒，0.01%）；无单次 >100 ms 静音。
- 证据类型：diagnostics、屏幕录像、人工听感记录。
- 通过判据：上述指标 + 人耳确认；录音轨不受监听开关影响。
- 自动化：半自动。

#### TC-L3-02 录制中开关监听

- 前置：正在录制远端 + 麦克风。
- 步骤：监听开/关各 10 次；对比 remote.wav/mic.wav 的帧数与时长。
- 期望：监听只改输出音量，不改变两条 WAV 的帧数/内容；无 gap。
- 证据类型：WAV 前后 hash/帧数、diagnostics。
- 通过判据：WAV 帧数差 ≤ 1 个 block；无新增 droppedBlocks。
- 自动化：半自动。

#### TC-L3-03 时钟漂移 / 欠载

- 前置：30 分钟录制。
- 步骤：比较 remote WAV 帧数 / 48000 与墙钟时长；检查 `remote.stats`、`monitorUnderrunFrames`。
- 期望：远端采样时钟与墙钟偏差 <50 ms/30 min；监听欠载不累积成可听断音；ring fill 在 min/max 之间。
- 证据类型：diagnostics、WAV ffprobe。
- 通过判据：偏差 <50 ms；无持续欠载；无 overflow。
- 自动化：半自动。

#### TC-L3-04 默认路径自动接管时监听仍在物理设备（新增验收）

- 前置：极简 UI 默认路径，两个开关开启；“录制对方声音”开启；系统默认输出原为 `BuiltInSpeakerDevice`；主界面没有“接管系统输出”开关。
- 步骤：只点“开始”；确认 App 自动把系统默认输出切到 HomePod Flow（FaceTime 路由）；检查监听输出 UID/名称；人耳确认从内置扬声器/耳机听到远端；停止；确认默认输出自动恢复。
- 期望：`outputTakeOver=true`（App 自己写 lease）；`tap.deviceUID=HomePod Flow`；`monitor.outputDeviceUID=BuiltInSpeakerDevice` 或耳机；两者不相等；监听可听；停止/崩溃恢复后默认输出回到原设备；用户无需打开高级区或手动切换。
- 证据类型：diagnostics、`verify_monitor_route.py --expect-takeover`、系统设置截图、人工听感。
- 通过判据：路由正确、监听可听、恢复成功；不得出现“接管后监听静音”。
- 自动化：半自动（点击/听感人工，路由可脚本检查）。

#### TC-L3-06 关闭“录制对方声音”时不接管系统输出

- 前置：极简 UI；“录制对方声音”关闭；“录制我的麦克风”开启；系统默认输出为物理设备。
- 步骤：开始仅麦克风+画面录制；停止；检查系统默认输出、lease、监听输出。
- 期望：不创建 tap/aggregate、不写接管 lease、不把默认输出切到虚拟设备；若上次会话留下自己的 lease，启动/停止时恢复；监听不应以虚拟设备为目标。
- 证据类型：diagnostics、lease、系统设置截图、人工听感。
- 通过判据：`outputTakeOver=false` 或已恢复；默认输出为物理设备；无 remote 文件/轨；无遗留 lease。
- 自动化：半自动。

#### TC-L3-05 监听输出热插拔

- 前置：录制中，监听为内置扬声器。
- 步骤：插入/拔出耳机或蓝牙输出；观察是否切换、是否爆音、录音是否继续。
- 期望：能跟随系统输出或明确 warning；不崩溃；remote/mic 轨连续；无默认输出误改。
- 证据类型：diagnostics、系统日志、人工听感。
- 通过判据：录音不中断；错误可诊断；恢复后监听可用。
- 自动化：半自动。

### 4.5 L4：双轨

#### TC-L4-01 远端 + 麦克风独立轨

- 前置：L2 通过；麦克风可用；远端有节目声。
- 步骤：同时录制 60 秒；对远端说话/播放节目，对麦克风说话；停止；检查 remote.wav/mic.wav。
- 期望：两条 WAV 均非静音；内容分别对应远端与本地；帧率 48 kHz；MKV 中 Remote/Mic 独立。
- 证据类型：WAV、diagnostics、ffprobe。
- 通过判据：两轨 RMS > 阈值；人工听感确认内容分离。
- 自动化：半自动。

#### TC-L4-02 轨道时间戳 / 偏移

- 前置：同时录制。
- 步骤：检查 diagnostics 的 remote offset、mic offset；ffprobe 检查 MKV 各音轨 start_time/duration；用拍手或双音标记对齐。
- 期望：两轨相对视频起点偏移绝对值 <50 ms；无丢帧；MKV duration 与 WAV 一致（±1 帧）。
- 证据类型：diagnostics、ffprobe JSON。
- 通过判据：偏移与时长在阈值内；无 `droppedBlocks`。
- 自动化：半自动。

#### TC-L4-03 单轨降级（兼容旧配置）

- 前置：分别关闭麦克风/关闭远端节目；不是极简 UI 的主路径（主路径见 TC-L4-07/08）。
- 步骤：录制 mic-only、remote-only；停止；检查 MP4/MKV。
- 期望：仍能生成 MP4 单混音轨和 MKV（Mix + 存在的轨道）；无崩溃；diagnostics 标明缺失轨。
- 证据类型：MKV/MP4、diagnostics。
- 通过判据：文件可播放；缺失轨不被伪造成非静音。
- 自动化：半自动。

#### TC-L4-04 丢块 / 过载诊断

- 前置：正常录制；人为增加 CPU 负载或缩小 ring。
- 步骤：观察 `droppedBlocks`、`monitorPushDroppedFrames`、WAV 连续性。
- 期望：丢块计数可见；日志/诊断解释；不得静默丢数据。
- 证据类型：diagnostics、日志。
- 通过判据：计数与现象一致；无“全零却显示成功”。
- 自动化：半自动。

#### TC-L4-05 真机 440 + 880 双音（新增验收）

- 前置：GUI 授权；远端路径可播放 440 Hz 正弦到 HomePod Flow；麦克风能拾取 880 Hz（扬声器靠近麦克风或第二台设备）；监听输出为物理设备。
- 步骤：同时播放 440/880；录制 6 秒；停止；对 `FaceTime.mp4` 与 `FaceTime.mkv` 运行 `Tests/Integration/verify_mix.py --expect-mic --remote-hz 440 --mic-hz 880`；再人工听。
- 期望：MP4 单音轨中 440 与 880 都存在且电平合理（幅度 ≥0.002，相对控制频率 ≥20 倍）；MKV 三轨标题/顺序正确，Remote 主要 440、Mic 主要 880。
- 证据类型：WAV、MP4、MKV、verify JSON、人工听感。
- 通过判据：verify 全部 pass；人耳能同时听到两个音；不得把离线合成结果当作真机采集结果。
- 自动化：半自动（真机注入 + 自动分析）。

#### TC-L4-06 离线 mux 双音（已执行）

- 前置：ffmpeg/ffprobe；QA 副本；无 TCC/硬件。
- 步骤：`make_dual_tone_wav.py` 生成 440/880 WAV；编译 `MuxHarness` 调用 `MediaMuxer.mux`；运行 `verify_mix.py --expect-mic`。
- 期望：MP4 1 条混音轨，440/880 幅度约 0.209；MKV 3 轨 Mix/Remote/Microphone，Remote 仅 440、Mic 仅 880。
- 证据类型：`REPORTS/2026-11-07-dual-tone-verify.json`、`REPORTS/2026-11-07-dual-tone-mux-harness.log`。
- 通过判据：13 项检查全部 pass；退出码 0。
- 自动化：是（封装层）；不证明采集层。

#### TC-L4-07 仅麦克风模式（关闭“录制对方声音”）

- 前置：极简 UI；远端开关关闭、麦克风开关开启；麦克风/屏幕权限已授予；HomePod Flow 不作为必需设备。
- 步骤：只点开始，录制 30 秒；停止；检查 remote.wav、microphone.wav、MP4/MKV、diagnostics、系统默认输出。
- 期望：remote.wav 不存在；microphone.wav 非静音；MP4 只有一条麦克风音轨；MKV 不含 Remote 轨；不启动 tap、不写 lease；系统输出保持/恢复物理设备；diagnostics 明确 `remote disabled`。
- 证据类型：文件列表、WAV、ffprobe、diagnostics、系统输出截图。
- 通过判据：无 remote 文件/轨；mic 轨非静音；默认输出未被留在虚拟设备。
- 自动化：半自动；**依赖 Core 新增关闭远端路径，当前 BLOCKED**。

#### TC-L4-08 仅远端模式（关闭“录制我的麦克风”）

- 前置：极简 UI；麦克风开关关闭、远端开关开启；麦克风权限可不授予；屏幕权限可用。
- 步骤：只点开始，录制 30 秒；停止；检查 microphone.wav、MP4/MKV、diagnostics、系统输出/监听。
- 期望：无 microphone.wav、无 Microphone 轨；MP4 只有一条远端音轨；MKV 为 Mix + Remote；自动接管/物理监听正常；麦克风权限不阻塞。
- 证据类型：文件列表、ffprobe、diagnostics、权限截图、人工听感。
- 通过判据：无 mic 文件/轨；远端非静音；接管/监听正常。
- 自动化：半自动。

### 4.6 L5：视频 + MKV/MP4

#### TC-L5-01 视频 + 双音轨 MKV

- 前置：L4 通过；屏幕录制权限；选择一个显示器/窗口。
- 步骤：录制 60 秒屏幕 + 双音轨；停止；ffprobe 检查。
- 期望：视频流存在；MKV 音频 3 轨，顺序 Mix/Remote/Microphone；标题正确；可播放。
- 证据类型：MKV、ffprobe JSON、播放器截图。
- 通过判据：轨道数/标题/时长正确；播放器可拖动、无花屏。
- 自动化：半自动（ffprobe 自动，播放人工）。

#### TC-L5-02 A/V 同步

- 前置：录制包含拍手/秒表/口型画面。
- 步骤：逐帧对比画面动作与音频瞬态；检查 offset。
- 期望：音画偏差 <100 ms；无明显漂移。
- 证据类型：MKV/MP4、逐帧截图、人工判断。
- 通过判据：人耳/人眼确认在阈值内。
- 自动化：人工（可用 ffprobe 辅助）。

#### TC-L5-03 MP4 默认播放即双方可听（新增验收）

- 前置：MP4 已生成；有远端和麦克风两条源。
- 步骤：用 QuickTime/系统默认播放器直接打开 `FaceTime.mp4`，不手动选轨；检查只有一条音轨；人耳确认双方声音都在。
- 期望：MP4 只有 1 条 AAC 混音轨；默认播放同时听到双方；电平不削波（limiter 0.95）。
- 证据类型：ffprobe（audio=1）、播放器截图、人工听感。
- 通过判据：ffprobe 1 条音轨 + 人耳确认；不得要求用户切换音轨。
- 自动化：半自动（ffprobe 自动，听感人工）。

#### TC-L5-04 mux 失败处理

- 前置：`FFMPEG_PATH` 指向不存在/不可执行文件，或输入 WAV 为空/损坏。
- 步骤：停止录制；观察 mux 结果与 diagnostics。
- 期望：`MuxResult.success=false`、exitCode 非 0、stderrTail 有原因；WAV 保留；UI 明确失败；不得把空文件标为成功。
- 证据类型：diagnostics.mux、session-error.log、文件列表。
- 通过判据：失败可见、原始 WAV 可恢复、无伪造 MKV。
- 自动化：是（可注入坏 FFMPEG_PATH）。

#### TC-L5-05 双音 mux 容器检查（已执行）

- 前置：ffmpeg/ffprobe 可用；QA 副本；已生成 440/880 输入的 `FaceTime.mp4` 与 `FaceTime.mkv`；无 TCC/硬件要求。
- 步骤：运行 `verify_mix.py --expect-mic --remote-hz 440 --mic-hz 880`，检查 MP4 单音轨、MKV 三轨、频率/电平。
- 期望：MP4 1 条混音轨且 440/880 均存在；MKV 轨道顺序 Mix/Remote/Microphone，Remote 仅 440、Mic 仅 880。
- 证据类型：ffprobe JSON、verify JSON、mux harness 日志。
- 通过判据：`REPORTS/2026-11-07-dual-tone-verify.json` 13/13 checks pass，退出码 0。
- 自动化：是。

#### TC-L5-06 磁盘满 / 半成品

- 前置：可用空间小于预计录制大小。
- 步骤：录制至写入失败；停止；检查 WAV/MKV 与 UI。
- 期望：写入错误可见；已写 WAV 可读或明确标记损坏；不生成“成功”MKV；不崩溃。
- 证据类型：diagnostics、文件大小、日志。
- 通过判据：错误明确；无静默截断；可清理后重试。
- 自动化：半自动。

#### TC-L5-07 仅麦克风 + 画面（关闭对方）

- 前置：TC-UI-03 / TC-L4-07 可实现；屏幕录制权限。
- 步骤：关闭“录制对方声音”，开启麦克风；录制 30 秒画面+麦克风；停止；ffprobe 检查 MP4/MKV；人耳确认。
- 期望：MP4 1 视频 + 1 麦克风音轨；MKV 1 视频 + 不含 Remote 的音频轨；画面与麦克风同步；无虚拟设备接管。
- 证据类型：MP4/MKV、ffprobe、播放器截图、人工听感。
- 通过判据：无 Remote 轨；麦克风可听；音画偏差 <100 ms；系统输出未留在虚拟设备。
- 自动化：半自动。

#### TC-L5-08 仅远端 + 画面（关闭麦克风）

- 前置：TC-UI-04 / TC-L4-08 可实现；屏幕录制权限；HomePod Flow 可用。
- 步骤：关闭“录制我的麦克风”，开启对方；录制 30 秒画面+远端；停止；ffprobe 检查 MP4/MKV；人耳确认。
- 期望：MP4 1 视频 + 1 远端音轨；MKV 1 视频 + Mix/Remote（无 Microphone）；自动接管与监听正常；无 mic 权限阻塞。
- 证据类型：MP4/MKV、ffprobe、播放器截图、人工听感。
- 通过判据：无 Microphone 轨；远端可听；音画偏差 <100 ms；默认输出恢复。
- 自动化：半自动。

### 4.7 L6：真人 FaceTime

#### TC-L6-01 真人 FaceTime 10 分钟

- 前置：两台 Apple 设备/两个账号；FaceTime 输出指向虚拟声卡；L2–L5 通过。
- 步骤：真人双向通话 10 分钟；说普通话/音乐；停止；默认播放 MP4；检查 MKV。
- 期望：远端人声在 MP4 默认音轨中可听；本地人声也在；MKV Remote/Mic 独立；无中断。
- 证据类型：MP4/MKV、WAV、diagnostics、人工记录。
- 通过判据：真人确认双方声音；无“只录到本地”或“只录到远端”；不得用合成音代替。
- 自动化：人工。

#### TC-L6-02 回声（G5）

- 前置：监听外放（内置扬声器），AEC 开启；对方持续说话。
- 步骤：录制 3 分钟；检查 mic.wav 中是否含远端声音；AEC 开/关对比；再戴耳机复测。
- 期望：AEC 开启时 mic 轨中远端残留显著低于远端轨；无啸叫；关闭 AEC 时允许但明确警告。
- 证据类型：remote.wav/mic.wav、相关性/频谱分析、人工听感。
- 通过判据：人耳无明显回声；mic 轨远端能量比远端轨低至少 20 dB（阈值待产品确认）。
- 自动化：半自动（分析）+ 人工。

#### TC-L6-03 15 分钟发布候选（G6）

- 前置：完整构建；权限、设备、ffmpeg 正常。
- 步骤：15 分钟真人通话；中途 `kill -9`；重启 App；检查默认输出恢复、lease 清理、WAV 可恢复；再完整跑一次不崩溃。
- 期望：崩溃后默认输出恢复；无孤儿 lease；WAV 头部可修复或明确提示；再次录制成功；MP4/MKV 可播放。
- 证据类型：diagnostics、lease 文件、WAV、系统默认输出截图、崩溃日志。
- 通过判据：恢复路径可复现；无 P0/P1 缺陷；文档齐全。
- 自动化：半自动 + 人工。

#### TC-L6-04 权限拒绝端到端

- 前置：分别拒绝音频录制、麦克风、屏幕录制。
- 步骤：启动录制；观察 UI/诊断/文件。
- 期望：每种拒绝都有具体文案；不生成成功文件；不接管默认输出后不恢复。
- 证据类型：截图、diagnostics、文件列表。
- 通过判据：拒绝路径全部可解释；恢复默认输出。
- 自动化：人工。

#### TC-L6-05 通话中设备拔插

- 前置：真人通话；虚拟设备或物理输出可拔插。
- 步骤：拔掉耳机/虚拟设备；重新插入；观察录制与监听。
- 期望：不崩溃；错误可见；能恢复则继续，不能恢复则安全停止并保留已写文件。
- 证据类型：diagnostics、日志、人工记录。
- 通过判据：无静默数据损坏；默认输出/设备状态可恢复。
- 自动化：人工。

## 5. 异常矩阵

| 编号 | 场景 / 触发 | 期望行为与诊断 | 证据 | 通过判据 | 自动化 |
|---|---|---|---|---|---|
| E-01 | 音频录制 TCC 拒绝 | tap 回调正常但全零 → `allZero`；或 tap 创建失败 → `tapError`；UI 明确“权限未授予” | 自检 JSON、WAV、UI | 不进入 recording；有具体权限文案 | 半自动 |
| E-02 | 麦克风 TCC 拒绝 | MonitorEngine 启动失败/无输入；诊断 `noMicrophone` 或权限错误；不伪造 mic 轨 | diagnostics、日志 | 明确失败；远端轨仍可单独录 | 半自动 |
| E-03 | 屏幕录制拒绝 | 视频轨失败但音频轨可继续，或整体失败；UI 明确 | diagnostics.video、日志 | 不生成“有画面”的假 MKV | 半自动 |
| E-04 | 设备拔出（远端/虚拟） | tap 停止；`noRemoteBlocks` 或 dropped 增加；安全停止；WAV 可读 | diagnostics、WAV | 不崩溃；错误可见；不伪造成功 | 半自动 |
| E-05 | 设备重新插入 | 可重新枚举；用户可重试；不残留旧 tap/aggregate | `AudioProbe list`、日志 | 重试成功或明确失败 | 半自动 |
| E-06 | 设备忙 / 独占 | `tapCreationFailed`/`aggregateCreationFailed`/`startFailed`，含 OSStatus | diagnostics、日志 | 错误码可见；设备释放后可重试 | 半自动 |
| E-07 | 全零 PCM（回调正常） | `allZero`，不得当 passed；提示权限或路由 | 自检 JSON | `nonzero=0` 时绝不 passed | 自动（负向） |
| E-08 | 无回调 | `noCallbacks`；提示 tap/aggregate 问题 | 自检 JSON | callbacks=0 时明确失败 | 半自动 |
| E-09 | tap 创建失败 | `tapCreationFailed(status)` + fourCC | 日志/UI | 不留下半开资源 | 半自动 |
| E-10 | aggregate 创建失败 | `aggregateCreationFailed(status)` | 日志/UI | 清理 tap；可重试 | 半自动 |
| E-11 | 无独立时钟设备 | `noIndependentClock`；不得用虚拟设备自 clock | 日志 | 明确失败 | 半自动 |
| E-12 | 采样率/格式不匹配 | `unsupportedFormat`，打印 ASBD | 日志 | 不尝试错误格式采集 | 自动（枚举层） |
| E-13 | 8ch 标签变化/缺失 | 按标签找 FL/FR；缺标签回退前两通道并警告 | diagnostics.captureFormat、降混测试 | 不把 BL/BR 当左右 | 半自动 |
| E-14 | ffmpeg 缺失 | `ffmpegNotFound`；WAV 保留；UI 提示安装 | diagnostics.mux | 不生成假 MKV | 自动 |
| E-15 | mux 输入损坏/零长 | ffmpeg 非 0；stderrTail；WAV 保留 | diagnostics.mux | 失败可见；原始 WAV 可恢复 | 自动 |
| E-16 | 磁盘满 | 写入错误；停止；WAV 可能截断但需可诊断 | 文件大小、日志 | 不标成功；不崩溃 | 半自动 |
| E-17 | 录制中崩溃 | 重启恢复默认输出；清理 lease；WAV 头部修复/提示 | lease、WAV、崩溃日志 | 系统状态恢复；无孤儿 | 半自动 |
| E-18 | 默认输出接管失败 | `cannotPersistLease`/`restoreFailed`；保持原默认输出 | diagnostics、系统设置 | 不留下错误路由 | 半自动 |
| E-19 | 接管后崩溃 | 下次启动 `recoverStaleLease` 恢复 | lease、系统设置 | 默认输出恢复 | 半自动 |
| E-20 | 监听输出拔出 | warning/跟随系统；录音继续 | diagnostics、日志 | 不崩溃；可恢复 | 半自动 |
| E-21 | AEC 不可用 | `aecEnabled=false` + warning；回退无 AEC | diagnostics.monitor | 明确告知；G5 仍需人工 | 半自动 |
| E-22 | ring 溢出 / CPU 过载 | `monitorRingOverflows`/`droppedBlocks` 增加；日志 | diagnostics | 计数可见；不静默丢 | 半自动 |
| E-23 | 睡眠/唤醒 | 采集恢复或安全停止；默认输出不丢失 | 日志、diagnostics | 不崩溃；可诊断 | 人工 |
| E-24 | FaceTime 未路由到虚拟设备 | 自检仍通过但远端轨静音；提示路由 | 真人通话、WAV | 不得把自检当 FaceTime 证据 | 人工 |
| E-25 | 虚拟设备缺失/卸载 | 设备枚举失败；`deviceNotFound`；不崩溃 | 日志 | 明确提示重装/选择设备 | 自动 |
| E-26 | 蓝牙/AirPlay 输出切换 | 监听跟随或 warning；录音不受影响 | diagnostics | 不崩溃；无默认输出误改 | 半自动 |
| E-27 | 单声道/2ch 设备 | 单声道复制到 L/R；自检硬编码 FL/FR 会失败（见 QA-009） | 自检 JSON | 明确说明设备不支持或修正判定 | 半自动 |
| E-28 | 监听选到虚拟设备 | 引擎拒绝/回退物理输出；UI 不提供虚拟设备 | diagnostics、UI | `monitor.outputDeviceUID != tap.deviceUID` | 半自动 |
| E-29 | 关闭“录制对方声音”但旧实现仍启动 tap | 不得写静音 remote 轨；要么不启动 tap，要么明确阻止；系统输出不接管 | diagnostics、文件列表 | 无 remote 文件/轨；无 lease；默认输出物理 | 半自动 |
| E-30 | 关闭“录制我的麦克风”但权限被拒 | 不阻塞开始；不生成 mic 轨；远端/监听正常 | 权限截图、diagnostics | `recordMicrophone=false`；无 mic 文件/轨 | 半自动 |
| E-31 | 两个开关都关闭 | 推荐禁用开始并说明“至少开启一项”；若允许仅画面，明确标注无音频 | 截图、ffprobe | 不生成空音轨假成功 | 人工 |
| E-32 | 默认路径自动接管失败 | 阻止开始或明确失败；不留下虚拟默认输出 | diagnostics、系统设置 | 错误可见；默认输出恢复/不变 | 半自动 |
| E-33 | 默认路径无物理监听输出 | 阻止开始或关闭监听并红色警告；录音不得静默 | diagnostics、UI | 用户知道“听不到对方” | 半自动 |
| E-34 | 高级区展开后修改设备覆盖 | 默认路径仍按主开关工作；覆盖值有明确提示；不改主开关 | screenshots、diagnostics | 主流程不依赖高级区 | 人工 |
| E-35 | 关闭对方后系统输出仍为虚拟 | 恢复原物理输出；不覆盖用户手动选择；无残留 lease | lease、系统设置 | 停止后默认输出物理 | 半自动 |
| E-36 | 极简 UI 默认值与持久化冲突 | 首次启动两开关为开；若产品要求记忆上次状态，必须有明确说明 | 截图、配置 | 默认路径只需两个开关 | 人工 |

## 6. 不可单测的逻辑与原因

| 逻辑 | 为什么不能 L0 单测 | 替代验证 |
|---|---|---|
| TCC 授权 | 权限由 GUI/用户会话决定，单元测试进程无法可靠复现授权/拒绝 | L2 人工授权 + 自检 JSON |
| Device tap / private aggregate | 依赖 coreaudiod、真实设备和进程权限；创建/销毁有系统副作用 | L2 / L6 真机 |
| AVAudioEngine / VPIO AEC | 依赖硬件、驱动、系统 AEC；输出非确定 | L6 真人回声 |
| ScreenCaptureKit | 依赖屏幕录制权限和真实显示器 | L5 真机 |
| ffmpeg 子进程实际封装 | 依赖外部二进制和文件系统；参数构建已单测 | L5 离线 mux + 真机 mux |
| 30 分钟稳定性/漂移 | 需要真实时间与设备时钟 | L3 |
| 人耳听感/回声 | 感知问题，无法用断言替代 | L3/L6 |
| 默认输出接管/恢复 | 会修改系统状态，不能放在单测里 | L3 + 总调度人工 |
| 极简 UI 布局/默认值/高级区收起 | SwiftUI 视图状态需要 XCUITest 或人工截图；当前 CoreTests 不覆盖 UI | TC-UI 人工/XCUITest |
| 关闭“录制对方声音”路径 | 当前 `RecorderConfiguration` 没有 `recordRemote`，`RecorderEngine` 总是启动 tap；需要 Dev 新增路径后才能测 | TC-UI-03 / L4-07；当前 BLOCKED |
| 自动设备/监听/接管解析 | 依赖真实设备枚举与系统默认输出；不能在无硬件单测 | TC-UI-02 / L3-04 + diagnostics |
| 自检阈值判定 | 逻辑嵌在 `RecorderEngine.runSelfTest` 的硬件路径里，未抽纯函数 | 只测 Code 语义 + 未知设备 `tapError`；阈值需真机自检 |
| 远端实际降混写盘 | `RemoteAudioRecorder.downmix` 私有，依赖 tap block | 只测公开的 `frontStereoIndices`；实际写盘由 L2/L4 覆盖 |
| WAV 崩溃恢复 | 需要进程中断/文件系统故障注入 | L6 崩溃测试 |

## 7. 证据规范

1. 每个门禁一个目录：`artifacts/<gate>-<YYYY-MM-DD>/`；QA 的计划/日志放 `docs/agents/qa/REPORTS/`。
2. 每条“通过”至少包含：命令、执行时间、退出码、原始日志/JSON/WAV 路径、校验和（大文件）。
3. 合成信号必须标注 `synthetic`、频率、幅度、时长；不得写成 FaceTime 内容。
4. 真人通话必须包含：通话双方、时长、设备、路由、人工听感结论。
5. 失败也必须归档：错误码、UI 文案、是否恢复、是否保留 WAV。
6. 不得只截取 UI 成功提示；必须有底层 JSON/WAV/ffprobe 证据。

## 8. 缺陷与复测

- 缺陷统一写入 `docs/agents/qa/DEFECTS.md`，格式：编号、严重度、复现、期望、实际、证据、状态。
- QA 不修改 `Sources/**` 或 `project.yml`；修复由 Dev 完成，QA 只复测并更新状态。
- 复测必须引用原缺陷编号，并给出新证据路径。

## 9. 执行状态与证据索引

| 项目 | 状态 | 证据 |
|---|---|---|
| L0 67 个单测 | ✅ 通过 | `REPORTS/2026-11-07-coretests.log` |
| L1 设备枚举 | ✅ 通过 | `REPORTS/2026-11-07-l1-audioprobe-list.txt` |
| 离线双音 mux（440/880） | ✅ 通过 | `REPORTS/2026-11-07-dual-tone-verify.json`、`.../dual-tone-mux-harness.log` |
| 现有 monitor-mix 证据复核 | ✅ 通过（仅 440，无麦克风/视频） | `REPORTS/2026-11-07-monitor-mix-verify.json` |
| 监听路由诊断复核 | ✅ 通过（非接管场景） | `REPORTS/2026-11-07-monitor-route-verify.json` |
| L2 无 TCC 负对照 | ✅ 通过（all_zero_pcm） | `REPORTS/2026-11-07-l2-negative.json`、`.log` |
| L2-UI 极简默认路径 | ⬜ 未实现/未执行 | 当前 `ContentView` 仍为多卡片；Core 无 `recordRemote` |
| 极简 UI/关闭远端实现 | ⬜ BLOCKED | `DEFECTS.md` GAP-UI-01 / GAP-UI-02 |
| 关闭对方（仅麦克风+画面） | ⬜ BLOCKED | 需新增关闭远端路径；见 TC-UI-03/L4-07 |
| 关闭麦克风（仅对方+画面） | ⬜ 未执行 | 现有 `recordMicrophone=false` 可支撑，待 UI 极简化 |
| L2 GUI 正向自检 | ⬜ 未执行 | 需 GUI 授权；已有 18:12 证据 |
| L3 30 分钟监听 | ⬜ 未执行 | 需真机/人耳 |
| L4 真机双轨/双音 | ⬜ 未执行 | 需麦克风/注入 |
| L5 视频 + MKV | ⬜ 未执行 | 需 ScreenCaptureKit |
| L6 真人 FaceTime | ⬜ 未执行 | 需两台设备/真人 |

## 10. 待确认问题

1. MP4 视频编码/分辨率/码率是否有产品硬指标；当前 mux 使用 `-c:v copy`。
2. 监听欠载的可接受阈值（本计划暂定 30 分钟 ≤8640 帧）。
3. 双音测试的 880 Hz 如何稳定注入麦克风（扬声器外放/第二台设备/虚拟输入）。
4. 崩溃后 WAV 头部修复是否作为 G6 必达项（当前只在 close 时回填）。
5. 监听输出候选是否由 UI 完全过滤虚拟设备，还是也允许“强制选择后回退”。
6. FaceTime 真人验收由谁执行、使用哪两台设备/账号。
7. 两个开关都关闭时：阻止开始，还是允许“仅画面”？推荐阻止；需产品确认。
8. 高级区包含哪些项（设备覆盖/诊断/音量）？是否记忆上次展开状态？默认必须收起。
9. 单源模式下 MP4/MKV 的轨道标题/命名：远端关闭时是否仍叫 `Mix (Remote + Mic)`？不得在标题中声称不存在的一路。
10. 关闭对方时监听是否自动关闭，还是仍允许监听系统直接播放的 FaceTime 声音？App 不介入时为“系统直出”，不应显示为 App 监听。
11. 自动接管是否允许用户在高级区关闭？默认路径必须自动；若允许关闭，需明确失败诊断。
12. 开关状态是否跨启动记忆？若记忆，首次启动仍必须是两个开启。
13. “已获对方同意”的确认放在哪里？若保留，应是一次性弹窗/首次确认，不得在主界面形成第三个常驻开关。
