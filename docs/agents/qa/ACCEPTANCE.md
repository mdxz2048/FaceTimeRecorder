# FaceTime Recorder G1–G6 验收清单

版本：1.2 · 日期：2026-11-07 · 维护：测试 Agent · 使用：总调度/产品/开发

> **2026-11-07 总调度新决策**：主界面只保留“录制对方声音”“录制我的麦克风”两个开关 + 开始/停止。远端设备、麦克风、监听、系统输出接管自动；高级区默认收起。本版新增 §0.1 极简 UI 验收，并更新 G1–G4/G6 的开关组合项。

> 规则：只有同时具备“可复现命令/文件、执行时间、退出码、证据路径、必要的人工记录”才能勾选。  
> 未执行的项必须保持 `[ ]`，不得用“代码看起来对”代替验收。  
> 现有 `artifacts/G1-2026-11-07/fr-tcc.*` 与 `artifacts/G1-2026-11-07/monitor-mix/*` 都是**合成信号**，不是 FaceTime 真人通话。

## 0. 总览

| Gate | 目标 | 状态 | 主要证据 |
|---|---|---|---|
| G0 | 现状审计 | ✅ 完成 | `docs/audit/G0_AUDIT.md`、`REPORTS/2026-11-07-l1-audioprobe-list.txt` |
| G1 | 远端采集 | 🟡 部分完成（合成信号通过；真人 FaceTime 待验） | `artifacts/G1-2026-11-07/fr-tcc.json`、`.wav`、`monitor-mix/*` |
| G2 | 监听 | ⬜ 未完成 | 现有非接管场景诊断通过；30 分钟/接管场景待验 |
| G3 | 双轨 | 🟡 封装层结构通过；真机双轨待验 | `REPORTS/2026-11-07-dual-tone-verify.json` |
| G4 | 视频 / MKV / MP4 | 🟡 封装层结构通过；真机视频待验 | 同上 + 现有 `monitor-mix`（无视频） |
| G5 | 回声 | ⬜ 未开始 | 需真人通话 |
| G6 | 发布候选 | ⬜ 未开始 | 需 15 分钟通话 + 崩溃/权限路径 |
| UI | 极简双开关 | ⬜ 未实现 | §0.1；当前 `ContentView` 仍为多卡片，Core 无 `recordRemote` |

## 0.1 极简 UI 验收（新增，跨 G1–G4/G6）

> 当前实现缺口（2026-11-07）：`Sources/App/ContentView.swift` 仍是多卡片界面（设备/麦克风选择器、画面开关、监听开关、接管开关等）；`RecorderConfiguration` 没有“关闭远端录制”字段，`RecorderEngine` 仍总是启动 tap/远端轨。以下项目全部保持 `[ ]`，直到 UI/Dev 完成极简改造。不得用“启动 tap + 静音 remote 轨”伪造关闭远端。

- [ ] **UI-01 主界面极简**：打开 App 后主界面只有两个开关（“录制对方声音”“录制我的麦克风”）和一个开始/停止主按钮；两个开关默认开启；没有任何“必须选择”的远端/麦克风/监听下拉。系统权限弹窗/首次同意确认可作为一次性提示，但不得变成第三个常驻开关。  
  证据：窗口截图、控件清单/可访问性树。
- [ ] **UI-02 一键开始，设备全自动**：只点一次开始；远端自动为 HomePod Flow（UID `com.homepodflow.virtual-audio.surround71.v1`），麦克风自动为系统默认输入，监听自动为物理输出，系统输出在需要时自动接管并在停止后恢复。  
  证据：diagnostics、系统设置截图、MP4/MKV、人工听感。  
  判据：`outputTakeOver=true`（需要接管时）、`monitor.outputDeviceUID != tap.deviceUID`、停止后默认输出恢复。
- [ ] **UI-03 关闭“录制对方声音”**：只录麦克风 + 画面；不创建 tap/aggregate、不生成 remote.wav、不生成 Remote 音轨、不写输出接管 lease；系统默认输出保持/恢复物理设备；MP4 只有一条麦克风音轨。  
  证据：文件列表、ffprobe、diagnostics、系统输出截图。  
  依赖：**Core 需新增关闭远端路径；当前 BLOCKED。**
- [ ] **UI-04 关闭“录制我的麦克风”**：只录对方 + 画面；不请求/不阻塞于麦克风权限；不生成 microphone.wav、不生成 Microphone 轨；远端 tap、自动接管、物理监听照常；MP4 只有一条远端音轨。  
  证据：文件列表、ffprobe、diagnostics、权限截图。  
  判据：远端非静音；无 mic 文件/轨；麦克风拒绝不影响开始。
- [ ] **UI-05 两个开关都关闭**：行为必须有明确产品口径；推荐禁用开始并提示“至少开启一项”，不得生成空音轨/空 MP4 假成功。若允许“仅画面”，主按钮必须明确写“仅录画面”，且产物无音频轨。  
  证据：截图、ffprobe、diagnostics。
- [ ] **UI-06 高级区默认收起**：初始 collapsed；展开不是开始录制的必要条件；展开/收起不改变两个主开关；高级区没有必填字段；主流程不因高级区布局跳动。  
  证据：展开前后截图、控件清单、一次完整默认路径录制。
- [ ] **UI-07 默认路径失败诊断**：HomePod Flow 缺失、无物理监听输出、屏幕权限拒绝、麦克风权限拒绝分别有短中文原因和下一步动作；不接管后不恢复；不生成假成功文件。  
  证据：截图、diagnostics、文件列表、系统输出状态。
- [ ] **UI-08 关闭对方时系统输出不被接管/已恢复**：关闭“录制对方声音”后不因远端而接管虚拟设备；若检测到自己的旧 lease，恢复原物理输出；不覆盖用户手动选择。  
  证据：系统输出截图、lease 文件、diagnostics。

## 1. G1 远端采集

### 1.1 必达清单

- [x] **G1-01 设备枚举**：HomePod Flow Audio 存在，UID `com.homepodflow.virtual-audio.surround71.v1`，Virtual，0 输入 / 8 输出，48 kHz，Float32 packed，32 B/frame。  
  证据：`docs/audit/G0_AUDIT.md`；`REPORTS/2026-11-07-l1-audioprobe-list.txt`（2026-11-07 18:29，退出码 0）。
- [x] **G1-02 无 TCC 负对照**：sshd 进程 tap 回调/帧数正常但所有样本为 0，不能把“启动成功”当“采集成功”。  
  证据：`docs/audit/G0_AUDIT.md` §5.1/5.2：303 callbacks / 155136 frames / nonzero=0；内置扬声器 232/118784/0。  
  2026-11-07 18:36 CST 复跑 2 s：206 callbacks / 105472 frames / 8 通道全零 / `all_zero_pcm` / 退出码 10；`REPORTS/2026-11-07-l2-negative.json`。
- [x] **G1-03 GUI 授权后非零自检**：已授权 GUI 进程的 1 kHz 自检得到非零 FL/FR。  
  证据：`artifacts/G1-2026-11-07/fr-tcc.json`、`artifacts/G1-2026-11-07/fr-tcc.wav`（2026-11-07 18:12）。
  - callbacks=487，frames=249344，droppedBlocks=0，allSilent=false。
  - FL/FR nonzeroSamples=239088，RMS=0.055275973，peak=0.08；FC/LFE/BL/BR/SL/SR 全 0。
  - tap：8ch/48k，clock=`BuiltInSpeakerDevice`，格式 32 B/frame。
  - verdict=`pcm_detected`。
- [x] **G1-04 WAV 格式**：`fr-tcc.wav` 为 48 kHz、2ch、32-bit float、5.194667 s（ffprobe），与 JSON `wavInfo` 一致。  
  证据：`artifacts/G1-2026-11-07/fr-tcc.wav`、`fr-tcc.json`。
- [x] **G1-05 FL/FR 选择**：8ch 布局按标签取 `FL/FR`（索引 0/1），未把 `BL/BR` 当左右。  
  证据：`fr-tcc.json` 仅 ch0/ch1 非零；`Tests/CoreTests/DownmixTests.swift` 覆盖实际布局与任意排列。
- [x] **G1-06 合成 440 Hz 封装基线**：6 秒 440 Hz 远端信号生成 MP4 单混音轨与 MKV Mix+Remote；MP4 默认音轨含 440 Hz。  
  证据：`artifacts/G1-2026-11-07/monitor-mix/`；复核 `REPORTS/2026-11-07-monitor-mix-verify.json`。  
  限制：无麦克风、无视频、`outputTakeOver=false`；不能证明 FaceTime 真人。
- [ ] **G1-07 FaceTime 真人通话远端音频**：真人通话中对方声音进入 remote 轨，且 WAV 非静音。  
  通过判据：真人通话 ≥5 分钟；remote.wav 非静音；人工确认是对方声音；不能使用合成音。  
  证据：待补（L6）。
- [ ] **G1-08 默认路径自动接管后 FaceTime 路由正确**：极简 UI 下无需额外开关，点开始即自动把系统默认输出切到虚拟设备；FaceTime 声音实际进入 tap；停止自动恢复。  
  通过判据：`outputTakeOver=true`、`tap.deviceUID=HomePod Flow`、`monitor.outputDeviceUID=BuiltInSpeakerDevice/耳机`、真人听到对方、无手动切换步骤。  
  证据：待补（L3-04 + L6）。
- [ ] **G1-09 失败诊断可读**：权限、路由、格式、设备忙至少各有一条真实失败证据，文案与 `SelfTestResult.Code` 对应。  
  证据：待补（L2/L6 异常路径）。
- [ ] **G1-10 关闭对方时远端不采集**：关闭“录制对方声音”后不创建 tap/aggregate、无 remote.wav、无 Remote 音轨、无接管 lease；不得用静音 remote 轨代替。  
  证据：待补（TC-UI-03 / L4-07）；**当前 Core 无 `recordRemote`，BLOCKED**。
- [ ] **G1-11 关闭麦克风时远端仍正常**：关闭“录制我的麦克风”后远端 tap/自检/监听/接管不受影响；麦克风权限拒绝不阻塞。  
  证据：待补（TC-UI-04 / L4-08）。

### 1.2 当前结论

G1 **不能整体判定通过**。已证明“设备与 tap 数据面在 GUI 授权下可产生非零 PCM”，但尚未证明“FaceTime 真人声音被采集”；极简 UI 默认路径和“关闭对方”路径也尚未实现。现有证据只能写“合成/自检音采集通过”，不得写“支持 FaceTime 音频录制”。

## 2. G2 监听

- [ ] **G2-01 能听到远端（自动监听）**：录制中监听自动开启，输出为物理设备（内置扬声器/耳机），人耳听到远端节目；主界面不要求用户手动选监听。  
  证据：待补（L3-01）。
- [ ] **G2-02 监听与录音互不影响**：主界面无监听开关；若高级区提供监听控制，切换 10 次，remote/mic WAV 帧数与内容不变。  
  证据：待补（L3-02）。
- [ ] **G2-03 30 分钟稳定**：无爆音/断音；`monitorRingOverflows=0`；`monitorUnderrunFrames` ≤8640（30 分钟）；无单次 >100 ms 静音。  
  证据：待补（L3-01/03）。
- [ ] **G2-04 漂移可控**：30 分钟远端帧数对应时长与墙钟偏差 <50 ms。  
  证据：待补（L3-03）。
- [x] **G2-05 非接管场景监听落到物理设备**：现有 `monitor-mix` 诊断中 tap=HomePod Flow，监听=`BuiltInSpeakerDevice`（transport Built-in，out=2ch），二者不同。  
  证据：`artifacts/G1-2026-11-07/monitor-mix/diagnostics.json`；`REPORTS/2026-11-07-monitor-route-verify.json`。  
  限制：`outputTakeOver=false`，且未做人耳听感；只证明配置，不证明可听。
- [ ] **G2-06 自动接管后监听仍在物理设备（新增验收）**：极简 UI 点开始即自动接管，`outputTakeOver=true` 时监听仍为物理输出，且不能选虚拟设备。  
  通过判据：`verify_monitor_route.py --expect-takeover` 全 pass；`monitor.outputDeviceUID != tap.deviceUID`；人耳可听；主界面/高级区都不提供虚拟设备作为监听。  
  证据：待补（L3-04）。
- [ ] **G2-07 麦克风不播放到扬声器**：监听路径只消费远端 ring，不消费 mic ring；人耳无法从扬声器听到自己。  
  证据：代码审查 + L3 人工；待补。
- [ ] **G2-08 关闭对方时不接管/不监听虚拟设备**：关闭“录制对方声音”后，系统默认输出保持/恢复物理设备；不写 lease；监听不应把虚拟设备当目标。  
  证据：待补（TC-UI-03 / L3-06）。
- [ ] **G2-09 高级区不影响监听主路径**：监听自动解析不受高级区展开/收起影响；高级区若允许覆盖，必须显示实际监听设备。  
  证据：待补（TC-UI-06）。

## 3. G3 双轨

- [ ] **G3-01 远端 + 麦克风独立轨**：真机同时录制，remote.wav/mic.wav 均非静音且内容对应不同人。  
  证据：待补（L4-01）。
- [ ] **G3-02 轨道时间戳/偏移**：两轨相对视频起点 |offset| <50 ms；MKV 各音轨 start_time/duration 正确。  
  证据：待补（L4-02）。
- [ ] **G3-03 丢块可诊断**：`droppedBlocks`/`monitorPushDroppedFrames` 在异常时可见，不静默丢数据。  
  证据：待补（L4-04）。
- [x] **G3-04 封装层三轨结构（离线）**：440/880 双音经 `MediaMuxer` 生成 MKV，音轨顺序 `Mix (Remote + Mic)` → `Remote` → `Microphone`，Remote 仅 440、Mic 仅 880。  
  证据：`REPORTS/2026-11-07-dual-tone-verify.json`（13/13 checks pass）；校验和见 `REPORTS/2026-11-07-baseline.md`。  
  限制：这是离线 WAV→mux，不是真机采集。
- [ ] **G3-05 8ch 原始诊断**：`remoteChannelMode=native` 时保留 8ch WAV，且通道 RMS 可解释。  
  证据：待补（L4）。
- [ ] **G3-06 仅麦克风模式轨道结构（关闭对方）**：remote.wav/Remote 轨不存在；microphone.wav 非静音；MP4 只有麦克风音轨；MKV 不含 Remote；系统输出不接管。  
  证据：待补（TC-UI-03 / L4-07）；**当前 Core 无 `recordRemote`，BLOCKED**。
- [ ] **G3-07 仅远端模式轨道结构（关闭麦克风）**：microphone.wav/Microphone 轨不存在；远端非静音；MP4 只有远端音轨；MKV 为 Mix+Remote；麦克风权限不阻塞。  
  证据：待补（TC-UI-04 / L4-08）。
- [ ] **G3-08 默认双开组合**：两个开关默认开启时，MP4 Mix 同时含双方；MKV Mix/Remote/Microphone 三轨；无需高级区。  
  证据：待补（TC-UI-02 / L4-05）。

## 4. G4 视频 / MKV / MP4

- [ ] **G4-01 画面录制**：ScreenCaptureKit 生成 screen.mov，帧数/分辨率/时长正确。  
  证据：待补（L5-01）。
- [x] **G4-02 MP4 默认播放单混音轨（离线）**：`FaceTime.mp4` 只有 1 条 AAC 音轨（handler `FaceTime Mix`），440 与 880 同时在，幅度约 0.209。  
  证据：`REPORTS/2026-11-07-dual-tone-verify.json`。  
  限制：无视频、无真机采集；默认播放“双方可听”仍需 L5-03 人耳确认。
- [x] **G4-03 MKV 三轨标题/顺序（离线）**：Mix/Remote/Microphone 三轨，标题与顺序正确。  
  证据：同上。
- [ ] **G4-04 MKV + 视频可播放**：真实录制文件可在播放器打开、拖动、无花屏；视频 + 3 音轨。  
  证据：待补（L5-01）。
- [ ] **G4-05 A/V 同步**：拍手/口型偏差 <100 ms。  
  证据：待补（L5-02）。
- [ ] **G4-06 mux 失败可见**：ffmpeg 缺失/输入损坏时 `success=false`、exitCode 非 0、WAV 保留。  
  证据：待补（L5-04；L0 已覆盖参数/空输入）。
- [ ] **G4-07 视频文件与音频时长一致**：MKV/MP4 时长差 ≤1 个音频帧或 ≤50 ms。  
  证据：待补。
- [ ] **G4-08 仅麦克风 + 画面产物**：关闭对方后录制；MP4 1 视频 + 1 麦克风音轨；MKV 1 视频 + 不含 Remote 的音频轨；音画同步；无虚拟设备接管。  
  证据：待补（TC-UI-03 / L5-07）。
- [ ] **G4-09 仅远端 + 画面产物**：关闭麦克风后录制；MP4 1 视频 + 1 远端音轨；MKV 1 视频 + Mix/Remote（无 Microphone）；自动接管/监听正常。  
  证据：待补（TC-UI-04 / L5-08）。

## 5. G5 回声

- [ ] **G5-01 监听外放时麦克风不录回对方**：AEC 开启，mic 轨中远端残留比 remote 轨低 ≥20 dB（阈值待产品确认）。  
  证据：待补（L6-02）。
- [ ] **G5-02 无啸叫/明显回声**：真人听感确认。  
  证据：待补。
- [ ] **G5-03 AEC 不可用有明确警告**：`aecEnabled=false` + warning，不静默退化。  
  证据：待补（L6-02）。
- [ ] **G5-04 耳机场景**：戴耳机时监听/录音正常，无反馈。  
  证据：待补。

## 6. G6 发布候选

- [ ] **G6-01 15 分钟真人通话端到端**：MP4 默认播放双方可听；MKV 三轨正确；无中断。  
  证据：待补（L6-03）。
- [ ] **G6-02 崩溃恢复**：录制中 `kill -9`；重启后默认输出恢复、lease 清理、WAV 可恢复/提示、可再次录制。  
  证据：待补（L6-03）。
- [ ] **G6-03 权限拒绝路径**：音频/麦克风/屏幕分别拒绝，均有具体文案且不生成成功文件。  
  证据：待补（L6-04）。
- [ ] **G6-04 设备拔插/设备忙**：不崩溃、可诊断、可重试。  
  证据：待补（L6-05）。
- [x] **G6-05 测试文档齐全**：`TEST_PLAN.md`、`ACCEPTANCE.md`、`DEFECTS.md`、`REPORTS/2026-11-07-baseline.md` 已落盘。  
  证据：本目录。
- [ ] **G6-06 无未关闭 P0/P1**：当前 DEFECTS 中 P2/P3 待评估；P0/P1 必须为 0。  
  证据：待补。
- [ ] **G6-07 打包/签名/安装**：按发布流程构建，最小权限、Hardened Runtime、可启动。  
  证据：待补。
- [ ] **G6-08 极简 UI 主流程**：新用户打开 App 只看到两个开关和一个开始/停止；默认双开；点一次开始即可录制；高级区默认收起。  
  证据：待补（UI-01/UI-02/UI-06）。
- [ ] **G6-09 开关组合回归**：双开、仅麦克风、仅远端、双关四种组合均按 §0.1 行为；不生成假轨/假成功。  
  证据：待补（UI-03/04/05 + G3/G4 对应项）。
- [ ] **G6-10 默认路径不依赖高级区**：把高级区收起并重启 App 后，仍能完成一次双开录制；展开/收起不改变主开关。  
  证据：待补（TC-UI-06）。

## 7. 现有证据索引与校验

| 证据 | 路径 | 说明 |
|---|---|---|
| G1 自检 JSON | `artifacts/G1-2026-11-07/fr-tcc.json` | 487 callbacks/249344 frames；FL/FR 非零；`pcm_detected` |
| G1 自检 WAV | `artifacts/G1-2026-11-07/fr-tcc.wav` | 48k/2ch/f32/5.194667 s；SHA-256 `fd7eb571…34d156` |
| G1 合成监听/封装 | `artifacts/G1-2026-11-07/monitor-mix/` | 440 Hz；MP4 1 音轨；MKV 2 音轨（无 mic）；无视频；`outputTakeOver=false` |
| G1 JSON 快照 | `REPORTS/2026-11-07-g1-fr-tcc.snapshot.json`、`REPORTS/2026-11-07-monitor-mix-diagnostics.snapshot.json` | 便于本地复核；原始路径仍在 `artifacts/` |
| L0 日志 | `docs/agents/qa/REPORTS/2026-11-07-coretests.log` | 67 tests / 0 failures / TEST SUCCEEDED |
| L1 枚举 | `docs/agents/qa/REPORTS/2026-11-07-l1-audioprobe-list.txt` | 4 设备；HomePod Flow 8ch/48k/标签正确 |
| 双音 mux | `docs/agents/qa/REPORTS/2026-11-07-dual-tone-verify.json` | 13 checks pass；MP4 1 轨、MKV 3 轨 |
| monitor-mix 复核 | `docs/agents/qa/REPORTS/2026-11-07-monitor-mix-verify.json` | 440 存在、880 不存在（符合无 mic 证据） |
| 监听路由复核 | `docs/agents/qa/REPORTS/2026-11-07-monitor-route-verify.json` | tap 虚拟、监听 Built-in、非接管场景 |

校验和：

- `fr-tcc.wav`：`fd7eb571bdfa3c6fcf0abdfcdb4960a84e4f8cf44e0b57c39b1a0b5a0034d156`
- `fr-tcc.json`：`3a78907657a112d58d3cb4a0c7e7a3ac14f86901ed1672487cd6f37b89cf77e8`
- 离线双音 `FaceTime.mp4`：`5f3f6ca29282317809e1c2eeaa1f1db427da1655eaa0726ade54af9d57265c81`
- 离线双音 `FaceTime.mkv`：`d6e608d8da6dcce5235b631d36733f459273e64800a61413f2801731d72bf4f0`

## 8. 签署

| 角色 | 姓名/Agent | G1 | G2 | G3 | G4 | G5 | G6 | 日期 |
|---|---|---|---|---|---|---|---|---|
| 测试 | QA | 🟡 | ⬜ | 🟡 | 🟡 | ⬜ | ⬜ | 2026-11-07 |
| 开发 | Dev | — | — | — | — | — | — | 待 |
| 产品 | Product | — | — | — | — | — | — | 待 |
| 总调度 | Coordinator | — | — | — | — | — | — | 待 |

> G6 通过前，任何对外文档/UI 只能写“FaceTime 音频录制待真人验证”，不得写“已支持 FaceTime”。
