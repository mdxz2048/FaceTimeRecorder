# FaceTime Recorder 产品需求文档（PRD）

| 项目 | 内容 |
|---|---|
| 文档版本 | 1.2 |
| 日期 | 2026-11-07 |
| 作者 | 产品 Agent |
| 状态 | 待总调度确认；确认后作为 UI/Dev/QA 的输入基线 |
| 适用仓库 | `C:\Users\MDXZ\OneDrive\文档\ChatGPT\FaceTimeRecorder`（Windows 工作副本） |
| Mac 构建路径 | `/Users/lvzhipeng/Developer/FaceTimeRecorder` |
| 事实依据 | `docs/agents/CHARTER.md`、`docs/agents/STATUS.md`、`docs/agents/product/INPUT_BRIEF.md`、`docs/audit/G0_AUDIT.md` |

> **验证状态声明（必须保留）**
>
> 截至 2026-11-07，FaceTime 真人通话的远端音频尚未完成人工听感验证。本文所有涉及 FaceTime 音频能力的表述只能写“待验证”，不得写“支持 FaceTime 音频录制”。只有总调度在 G1/G6 取得真人通话证据并书面签字后，才能移除该限制。

---

## 0. 结论摘要

### 0.1 产品一句话

一个独立的 macOS 原生 App：用户主动开始后，录制 FaceTime 通话的**画面 + 对方声音 + 本地麦克风**；录制时对方声音始终从 MacBook 扬声器/耳机实时播放。结束后交付两个文件：

- `FaceTime.mp4`：H.264 画面 + 1 条“双方混音”AAC 音轨，**默认可直接播放/分享**；
- `FaceTime.mkv`：画面 + 3 条音轨（Mix / 远端 / 麦克风），用于后期归档。

录制阶段保留 `remote.wav` 与 `microphone.wav` 两条独立音轨，不实时混音；混音只发生在停止后的 FFmpeg 导出阶段。失败时保留可诊断、可恢复的素材。

### 0.2 第一阶段硬事实

1. 已安装虚拟设备 `HomePod Flow Audio`，UID `com.homepodflow.virtual-audio.surround71.v1`，传输类型 Virtual，**只有输出**：8ch、48 kHz、Float32 packed interleaved，1 个输出 stream（stream 70），**0 个输入 stream、0 个输入通道**。
2. 驱动 `WriteMix` 是纯 sink，不保留 PCM、不提供共享缓冲、不向客户端提供时间戳。**没有 Loopback 输入**。
3. 远端采集唯一可行路径是 Core Audio device tap：`CATapDescription(andDeviceUID:)` + 私有 aggregate；aggregate 的主时钟必须来自另一个真实输出设备，不能是虚拟设备自己。
4. 无 TCC 时 tap 的 IOProc 仍会正常回调、帧数正常，但**所有样本严格为 0**，不会报错。“启动成功”不等于“采集成功”。
5. 因此产品必须同时做两件事：
   - **路由校验**：系统默认输出必须是虚拟设备，或用户显式同意接管；
   - **非静音自检**：向虚拟设备播放 1 kHz 低电平测试音，tap 读取并验证 FL/FR 有非零 PCM。
6. FaceTime 使用系统默认输出。若默认输出不是虚拟设备，FaceTime 声音不会进入 tap；此时即使自检通过也不能开始录制。
7. 本机无可用 WebRTC AEC3 构建依赖。V1 AEC 默认关闭；高级区可开 Apple VoiceProcessingIO；AEC3 只能作为未来可替换实现，当前**未实现**。

### 0.3 默认产品取值

| 项目 | 默认值 | 说明 |
|---|---|---|
| 系统输出接管 | 录制对方声音开启时自动接管；关闭时不接管 | 不弹确认框；开关下方一行说明；停止/退出自动恢复 |
| 监听 | 录制对方声音开启时自动开启 | 固定把远端送到“接管前的那台物理默认输出”；UI 不出现监听设备选择，也不出现音量滑杆；音量由 macOS 自身控制；麦克风永不进入监听 |
| 监听输出 | 固定为接管前的物理默认输出 | 不再让用户选择；即使系统默认输出被接管到虚拟声卡，监听仍从该物理设备出声 |
| 麦克风 | 开启 | 权限被拒时降级为“仅远端音轨” |
| 视频 | 自动录制 FaceTime 窗口 | 启动时按 `appName=FaceTime` 查找窗口；找不到才回退主显示器并在状态行说明；UI 不出现窗口/显示器选择器 |
| 远端声道 | FL/FR 降混为立体声 | 8ch 原始采集仅用于诊断，不默认落盘 |
| 远端缺失时 | 阻止开始 | 不允许生成“静音远端”的假成功文件 |
| 录制阶段混音 | 不混音 | 保留 `remote.wav` + `microphone.wav`；混音只在停止后的导出阶段发生 |
| 默认主文件 | `FaceTime.mp4` | H.264 + 双方混音 AAC；双击即可听到双方 |
| 归档文件 | `FaceTime.mkv` | 第 1 条音轨=Mix，第 2 条=Remote，第 3 条=Mic |
| 文件目录 | `~/Movies/FaceTime Recorder/` | 按日期和会话分目录 |
| 单实例 | 是 | 第二个实例只唤醒已有窗口，不并发录制 |
| 主界面 | 极简模式 | 只保留两个开关、一个按钮、状态/结果/同意提示；高级默认折叠 |
| AEC | 默认关闭 | 高级区可开 Apple VoiceProcessingIO；不得写“已消除回声” |

### 0.4 极简主界面（V1 产品形态，不是临时 demo）

**总调度决策（2026-11-07，覆盖此前所有“主界面选择设备/窗口/音量”的描述）**：

V1 的唯一主界面只允许以下元素：

1. 标题：`FaceTime 录音`。
2. 两个大开关：
   - `录制对方声音`（默认开）；
   - `录制我的麦克风`（默认开）。
3. 一个主按钮：`开始录制` / `停止并保存`。
4. 一行状态：`空闲` / `准备中` / `录制中 00:12` / `正在生成视频` / `完成` / `失败：<原因>`。
5. 完成后一行结果：`已保存 FaceTime.mp4（双方声音）` + `在 Finder 中显示`。
6. 一行常驻小字：`请确保通话对方同意录音。`
7. `录制对方声音` 开启时，开关下方一行说明：`会自动切换系统声音并在停止后恢复。`
8. 底部固定小字：`远端音频：待真人通话验证`。
9. `高级` 折叠入口。

除以上元素外，主界面不显示设备选择、窗口/显示器选择、监听开关、音量、权限详情、诊断、日志、FFmpeg/8ch 徽章。它们全部收进 `高级` 折叠区，默认收起。

**自动行为（主界面不提供选择）**：

| 项目 | 自动规则 |
|---|---|
| 远端设备 | 自动选 `HomePod Flow Audio`（UID `com.homepodflow.virtual-audio.surround71.v1`） |
| 麦克风 | 自动选系统默认输入 |
| 监听 | 开启 `录制对方声音` 时自动开启；固定使用接管前的那台物理默认输出（MacBook 扬声器或已连接耳机）；UI 不出现设备选择/音量滑杆，音量由 macOS 控制；启动时该设备不可用则失败，不自动换设备 |
| 系统输出接管 | **只在点“开始录制”时**自动切到虚拟设备；App 启动/空闲时不切；停止/退出/崩溃恢复自动还原 |
| 画面 | 自动查找 `appName=FaceTime` 窗口；找到录窗口，找不到回退主显示器并在状态行说明；不选窗口/显示器 |
| AEC | 默认关闭；高级区可开 Apple VoiceProcessingIO；不得写“已消除回声” |
| 视频/Audio 产物 | 正常导出 `FaceTime.mp4`（双方混音）+ `FaceTime.mkv`（Mix/Remote/Mic） |

**开关组合**：

| 录制对方 | 录制麦克风 | 行为 |
|---|---|---|
| 开 | 开 | 自动接管；监听开；MP4 双方混音；MKV Mix/Remote/Mic |
| 开 | 关 | 自动接管；监听开；MP4 仅对方；MKV Mix/Remote |
| 关 | 开 | 不接管；监听关；MP4 仅麦克风；MKV Mix/Mic |
| 关 | 关 | 主按钮禁用；状态行提示“请至少开启一项” |

录制中两个开关锁定，不允许切换；需要改变组合必须停止后重新开始。

> 后文第 5、9、11 节中出现的设备选择、窗口选择、权限详情等，均属于 `高级` 折叠区或内部规范，不再是 V1 主界面的必填交互。监听设备/音量不是可选项：固定物理默认输出 + macOS 音量。

### 0.5 能力边界（回答用户四问）

| 用户问题 | V1 答案 |
|---|---|
| 视频录什么？ | **只录 FaceTime 窗口**。点“开始录制”时用 `SCShareableContent` 查找 `appName=FaceTime` 的窗口；找到就录该窗口；找不到才回退主显示器，并在状态行说明“未找到 FaceTime 窗口，已录制主显示器”。UI 不提供窗口/显示器选择器。 |
| 音频录什么？ | **远端 + 麦克风两条独立源轨**：`remote.wav`（远端立体声）与 `microphone.wav`（麦克风单声道）。录制阶段不混音；停止后导出 `FaceTime.mp4`（1 条双方混音）和 `FaceTime.mkv`（Mix/Remote/Mic）。 |
| 音画怎么对齐？ | 用 **host time** 记录视频首帧、远端首样本、麦克风首样本，建立统一 `t0`；WAV 从 `t0` 写前导静音/裁剪；导出时用 **FFmpeg `-itsoffset`**（或等价 PTS 偏移）把视频/音频对齐到同一时间轴。15 分钟音画差 ≤100 ms。 |
| 对方声音怎么实时听到？ | 监听是内部通路：把远端 PCM 送到“接管前的物理默认输出”（MacBook 扬声器或已连接耳机）。UI 不出现监听设备/音量；音量由 macOS 控制。麦克风永不进入监听。 |

补充硬规则：

1. 系统默认输出只在**点“开始录制”时**切到 `HomePod Flow Audio`；**不在 App 启动时切**。原因：启动就切会让用户空闲时整台 Mac 没有声音。
2. 停止、正常退出、崩溃后下次启动自动恢复原系统输出。
3. AEC 默认关闭；高级区可开 Apple VPIO。任何文案不得写“已消除回声”。
4. FaceTime 真人通话未验证前，底部固定 `远端音频：待真人通话验证`。

---

## 1. 用户画像

### 1.1 画像 A：远程访谈者 / 咨询顾问

- 典型用户：35 岁左右，咨询、招聘、律师、医疗问诊等需要留档的职业用户。
- 设备：Apple Silicon MacBook Pro，常用 AirPods 或外接耳机，偶尔用内置扬声器。
- 目标：把客户/候选人的画面、对方声音、自己的提问分别留下；会后能快速整理纪要或交付录音。
- 痛点：系统录音工具只能录一个混合音轨；对方声音和自己声音混在一起，后期无法降噪、转写或单独引用。
- 成功标准：一次 30–60 分钟通话，结束后默认 MP4 双击就能同时听到双方；MKV 里远端和麦克风两条轨都独立、时间对齐、可分别静音。
- 最不能接受：录完才发现远端是静音；文件损坏；录制中监听中断；把麦克风声音播回扬声器造成回声。

### 1.2 画像 B：家庭通话留存者

- 典型用户：55–65 岁，非技术用户，用 Mac 与异地家人 FaceTime。
- 设备：MacBook Air / iMac，内置扬声器和内置麦克风。
- 目标：一键把家人的画面和声音留下来，不需要理解“虚拟声卡”“aggregate”“device tap”。
- 痛点：系统设置复杂；授权弹窗不知道点哪个；录到一半崩溃后不知道怎么恢复声音输出。
- 成功标准：首次启动由系统自动弹授权，主界面只有两个开关和一个按钮；点一次“开始录制”就能录；结束后文件在“影片”里能找到；崩溃后重新打开 App 自动恢复原输出。
- 最不能接受：App 把系统声音切走后没有恢复，导致整台电脑没声音；录制按钮状态不清楚；失败提示只有技术术语。

### 1.3 画像 C：内容创作者 / 研究者

- 典型用户：28–40 岁，播客、视频访谈、用户研究、田野调查。
- 设备：Apple Silicon Mac，外接麦克风、监听耳机、外接显示器。
- 目标：长时段录制；远端和本地分轨；需要知道丢帧、时钟漂移、监听缓冲和失败原因；素材可进入后期流程。
- 痛点：长录制后音画漂移；监听缓冲越来越延迟；不知道是哪一段丢了；文件命名混乱。
- 成功标准：45–60 分钟录制后，MP4 默认播放可听双方；MKV 内三条音轨（Mix、远端、麦克风）+ 视频可被 `ffprobe` 识别；诊断 JSON 能解释丢帧/漂移/溢出；文件命名可排序、不覆盖。
- 最不能接受：为了“看起来成功”而隐藏静音或丢帧；无法定位失败原因；长录后音画不同步。

---

## 2. 三个核心场景

### 场景 1：客户访谈留档（画像 A）

**背景**：用户已安装 HomePod Flow 驱动，FaceTime 已登录。今天有一次 45 分钟客户访谈，用户戴耳机，希望会后把对方和自己分开整理。

**主路径**：

1. 打开 App，主界面只有“FaceTime 录音”、两个默认开启的开关、开始按钮、状态行、同意提示、底部“远端音频：待真人通话验证”。
2. 用户不需要选择画面源/麦克风/监听输出；App 自动使用 FaceTime 窗口（找不到才回退主显示器）、系统默认输入、接管前物理默认输出。
3. 用户点击“开始录制”。App 自动接管系统输出、开启监听、做 1 秒非静音自检。
4. 自检通过后进入 `recording`，状态行显示“录制中 00:12”。
5. 用户进行 FaceTime 通话；耳机里能听到对方；麦克风声音不会被播到耳机。
6. 结束后点击“停止并保存”，App 进入 `stopping`、`muxing`，生成 MP4（双方混音）和 MKV（多轨归档）。
7. 主界面结果行显示“已保存 FaceTime.mp4（双方声音）”和“在 Finder 中显示”；MKV 多轨归档放在高级区。

**成功判定**：MP4 默认播放能同时听到双方；MKV 的 Mix/Remote/Mic 三条音轨独立可播；时间差不超过 100 ms；自动监听不影响录制。

**失败敏感点**：远端静音、回声、音画漂移、监听中断、文件损坏。

### 场景 2：家人通话留存（画像 B）

**背景**：用户第一次使用，系统默认输出是内置扬声器，不知道虚拟声卡是什么。用户想录下与家人的 20 分钟通话。

**主路径**：

1. 首次启动由系统自动弹麦克风/屏幕/系统音频授权；主界面不出现权限卡片。
2. `录制对方声音` 默认开；开关下方只显示一行“会自动切换系统声音并在停止后恢复。”
3. 用户点击“开始录制”；App 自动记录原输出、写 lease、切到 `HomePod Flow Audio`，不弹确认框。
4. 自检通过后开始录制；状态行显示录制计时；用户仍从 MacBook 扬声器/耳机听到对方。
5. 结束后 App 自动导出并恢复原输出；结果行显示“已保存 FaceTime.mp4（双方声音）”。
6. 若 App 崩溃，下次启动检测到 lease 后自动尝试恢复原输出；失败才在状态行/高级区提示。

**成功判定**：非技术用户能在 3 分钟内完成首次录制；默认 MP4 双击就能听到双方；系统输出在正常停止和崩溃恢复后都回到原设备；没有“整台电脑没声音”的状态。

**失败敏感点**：权限拒绝后不知道怎么办；接管后没有恢复；崩溃后无提示；错误信息只有英文技术码。

### 场景 3：长访谈 / 素材采集（画像 C）

**背景**：用户要录 60 分钟远程访谈，使用外接麦克风和监听耳机，后期需要分轨。

**主路径**：

1. 主界面保持极简；用户如需要外接麦克风/耳机，只在 `高级` 中覆盖默认设备，不改变主流程。
2. 开始前 App 自动检查磁盘空间、FFmpeg、设备格式、默认输出、tap 自检。
3. 录制中主界面只显示计时；电平、丢帧、监听缓冲、漂移估计在 `高级` 中查看；监听缓冲目标 150 ms。
4. 监听随“录制对方声音”自动开启；高级区可调音量；麦克风永远不进入监听总线。
5. 停止后 App 先完成媒体收尾，再用 FFmpeg 导出 MP4（混音）和 MKV（多轨）；若某一产物失败，保留另一个可播放产物和 WAV，并明确告知。
6. 诊断 JSON 包含：设备快照、tap 描述、自检结果、每声道 RMS、声道映射、丢帧、ring 溢出、监听 underrun、漂移 ppm、视频帧数、错误码。

**成功判定**：60 分钟录制无未解释的丢帧；音画漂移不超过 100 ms；监听不累积延迟；诊断能回答“为什么没录到/为什么有缺口”。

**失败敏感点**：长录漂移、ring 溢出、磁盘写满、FFmpeg 失败、设备热插拔、睡眠唤醒。

---

## 3. 功能范围

### 3.1 P0（首个可交付版本必须做）

| ID | 功能 | 说明 | 验收 |
|---|---|---|---|
| P0-01 | 设备发现与硬校验 | 按 UID 查找 `HomePod Flow Audio`；校验输出 8ch/48k/Float32；输入通道必须为 0 时按“仅输出设备”处理 | AC-02 |
| P0-02 | 首次启动授权 | 首次开始时由 macOS 自动弹权限；拒绝后在状态行/高级区给出降级与修复路径 | AC-05、AC-07、AC-08 |
| P0-03 | 路由校验 | 开启“录制对方声音”时自动接管到虚拟设备；未开启时不接管；接管失败阻止开始 | AC-05、AC-12 |
| P0-04 | 非静音自检 | 1 秒 1 kHz 低电平音；检查 FL/FR RMS、回调、帧数；失败阻止开始 | AC-03、AC-06 |
| P0-05 | 自动可逆接管 | “录制对方声音”开启时自动接管，不弹确认框；停止/退出恢复；lease 崩溃恢复 | AC-12、AC-13、AC-14、AC-35 |
| P0-06 | 远端 device tap | 私有 tap + 私有 aggregate；时钟来自独立物理输出；可变帧数 | AC-03 |
| P0-07 | 8ch→stereo | 按设备标签取 FL/FR；保留 8ch 诊断能力；不平均所有声道 | AC-03、AC-09 |
| P0-08 | 麦克风采集 | 48 kHz 单声道；AEC 默认关闭，高级区可开 Apple VPIO | AC-09、AC-11 |
| P0-09 | 远端监听 | “录制对方声音”开启时自动监听；固定使用接管前的物理默认输出；UI 不出现设备/音量；麦克风永不进入监听 | AC-10、AC-11、AC-33、AC-35 |
| P0-10 | 视频录制 | ScreenCaptureKit；自动 `appName=FaceTime` 窗口；找不到回退主显示器并说明；H.264；不做选择器 | AC-21、AC-41 |
| P0-11 | 双产物导出 | `FaceTime.mp4`：H.264 + 双方混音 AAC；`FaceTime.mkv`：H.264 + Mix/Remote/Mic 三条音轨；录制阶段保留 `remote.wav` + `microphone.wav` | AC-09、AC-31 |
| P0-12 | 仅音频降级 | 屏幕权限被拒或视频源不可用时，生成 `FaceTime.m4a`（混音，可直接播放）+ `FaceTime.mka`（Mix/Remote/Mic） | AC-08 |
| P0-13 | 麦克风降级 | 麦克风权限被拒时，MP4 的 Mix 仅含远端；MKV 为 Mix/Remote 两条音轨；明确标注“无麦克风音轨” | AC-07 |
| P0-14 | 完整状态机 | `idle→preparing→recording→stopping→muxing→finished/failed` | AC-09、AC-13 |
| P0-15 | 失败诊断 | 每个失败有稳定错误码、中文解释、可执行动作、诊断 JSON | AC-06、AC-16 |
| P0-16 | 文件组织 | 日期/会话目录；不覆盖；半成品保留；空目录清理 | AC-22 |
| P0-17 | 崩溃/异常恢复 | lease 恢复输出；`.inprogress` 会话尝试重新导出或保留素材 | AC-13、AC-23 |
| P0-18 | 单实例 | 第二实例只激活已有窗口；不允许并发录制 | AC-24 |
| P0-19 | 录制中基础守护 | 磁盘低、设备消失、视频源断开、睡眠唤醒至少能安全收尾 | AC-15、AC-17、AC-27 |
| P0-20 | 同意提示 | 首次录制前明确提示“需征得通话对方同意”；用户确认后才能开始 | AC-25 |
| P0-21 | 双音混音验收 | 440 Hz 远端 + 880 Hz 麦克风双音测试；`FaceTime.mp4` 默认音轨同时可测到两个频率 | AC-31、AC-32 |
| P0-22 | 监听物理路由 | 录制对方声音开启时自动监听；固定接管前物理默认输出；永远排除虚拟声卡；接管系统输出后仍从该物理设备出声 | AC-33 |
| P0-23 | 极简主界面 | 只显示标题、两个开关、主按钮、状态行、结果行、同意提示、未验证提示 | AC-35 |
| P0-24 | 高级折叠区 | 设备选择、音量、权限详情、诊断、日志、FFmpeg/8ch 徽章默认收起 | AC-36 |

### 3.2 P1（首个版本后优先）

| ID | 功能 | 说明 |
|---|---|---|
| P1-01 | 混音增益/重混 | 允许调整 Remote/Mic 在 Mix 中的增益并重新导出；默认 1.0/1.0 + 限幅 |
| P1-02 | 8ch 原始诊断 WAV | 可选保留整段 8ch；默认关闭，失败时自动保存自检 1 秒 8ch |
| P1-03 | 单声道兼容 | FL 有信号、FR 静音时，可把 FL 复制到双声道；默认关闭 |
| P1-04 | 设备热插拔自动恢复 | 设备 5 秒内重新出现则尝试继续；否则安全停止 |
| P1-05 | 导出失败重试 | 不重新录制，直接用 `take.mov` + WAV 重跑 MP4/MKV 导出 |
| P1-06 | 菜单栏迷你控制 | 开始/停止/计时（不含监听开关） |
| P1-07 | 通知 | 录制完成、失败、输出恢复失败 |
| P1-08 | 监听状态只读 | 高级区显示当前固定监听设备；不提供选择或音量滑杆 |
| P1-09 | 麦克风选择 | 内置/外接/连续互通麦克风 |
| P1-10 | 视频质量设置 | 720p/1080p、帧率、码率 |
| P1-11 | 自动清理中间文件 | 成功导出后删除 `take.mov`；失败保留 |
| P1-12 | 恢复向导增强 | 对未完成会话提供“尝试恢复 / 仅保留素材 / 删除” |

### 3.3 P2（明确延后）

- 4K/60fps 录制、HEVC 硬件编码选项。
- 系统声音与其他 App 声音分离（按进程 tap）。
- 自动转写、说话人分离、章节、静音裁剪。
- 云盘上传、分享链接、协作批注。
- 摄像头画中画、虚拟摄像头输出。
- 直播推流、实时字幕。
- Intel Mac 与 macOS 15 以下版本。
- iPhone/iPad 端录制。
- 自动检测 FaceTime 通话并自动开始（不做，必须用户主动）。
- 多实例并发录制。

### 3.4 Non-goals（不做）

1. **不修改 HomePod Flow 驱动、旧 HomePod Flow 仓库或任何系统音频驱动。**
2. **不实现 Loopback 输入，不把虚拟声卡改造成输入设备。**
3. **不安装、不依赖额外的虚拟麦克风。**
4. **不依赖 HomePod、AirPlay、HomePod Flow App 的运行状态。**
5. **不绕过 TCC、不绕过屏幕录制/系统音频/麦克风授权、不绕过 DRM。**
6. **不做隐蔽录制、不在用户不知情时开始、不自动接听。**
7. **不在 FaceTime 真人通话验证前宣称“支持 FaceTime 音频录制”。**
8. **不保证所有 FaceTime 拓扑（群组 FaceTime、SharePlay、连续互通、屏幕共享）可用；这些属于待验证范围。**
9. **不提供视频剪辑、手动多轨混音台、降噪、变声、字幕等后期功能；仅提供导出阶段的固定 Mix 轨。**
10. **不把远端静音的文件标记为成功；不以“有文件”代替“有有效音轨”。**
11. **不在录制中把麦克风混入监听输出。**
12. **不自动删除用户已产生的媒体文件。**
13. **不在录制阶段实时混音；混音只在停止后的导出阶段发生。**

### 3.5 版本门禁与“待验证”标记

| 能力 | 当前状态 | 允许的 UI 文案 | 解除条件 |
|---|---|---|---|
| 远端 device tap 采集 | 历史 GUI 证据可用；本次 SSH 对照为全零 | “远端音频（待验证）” | GUI 授权后 AudioProbe 非零 + 自检通过 |
| FaceTime 真人通话音频 | **未验证** | “远端音频：待真人通话验证” | 两台设备真人通话 5 分钟，远端轨有对方声音 |
| MP4 默认播放双方 + MKV 三音轨 | 设计目标 | “MP4 可直接播放（双方声音）；MKV 多轨归档” | 15 分钟录制，MP4 可听双方，MKV 三音轨，音画差 ≤100 ms |
| 回声消除 | 默认关闭；开启 VPIO 时待实测 | “Apple 语音处理（可能降低回声）” | G5 通过；不得写“已消除回声” |
| 群组 FaceTime | 未验证 | 不主动宣传 | 单独验收 |

---

## 4. 产品规则

### 4.1 设备与路由

1. 只接受 UID `com.homepodflow.virtual-audio.surround71.v1` 的 `HomePod Flow Audio` 作为远端源。设备不存在、UID 变化、输出通道为 0 时阻止开始。
2. **只在点“开始录制”时**自动把系统默认输出切到该虚拟设备；App 启动/空闲时不切。原因：启动即切会让用户空闲时整台 Mac 没有声音。
3. 自动接管失败时**不得开始**。错误码 `output_takeover_failed`；高级区显示原因和“打开声音设置”，主界面只显示一行失败原因。
4. 监听固定使用“接管前的那台物理默认输出”（MacBook 扬声器或已连接耳机）。UI 不提供监听设备选择，也不提供音量滑杆；音量由 macOS 控制。启动时该设备不可用则报 `monitor_output_missing`，不自动换设备。
5. 录制期间如果用户从系统设置把默认输出切走：
   - 立即显示红色警告“FaceTime 声音已切走，远端将静音”；
   - 不自动改回，不覆盖用户选择；
   - 若 10 秒内未恢复，写入 `route_changed_during_recording` 警告；
   - 停止时只在“当前默认输出仍等于虚拟设备”时才恢复 lease 中的原输出。
6. 接管期间所有系统声音都会进入虚拟设备，因此也可能被远端音轨录入。UI 必须提示关闭其他会发声的 App/通知。P0 不做按进程隔离。
7. `录制对方声音` 开启时自动监听；监听设备固定为接管前原默认物理输出。虚拟设备永远不在候选中。主界面不提供监听开关、设备选择或音量。
8. 开启 `录制对方声音` 但该固定物理设备不可用时，阻止开始并报 `monitor_output_missing`。录制中该设备消失时，不自动换设备；关闭监听并状态行警告，录制继续。
9. 系统默认输出被接管到虚拟声卡后，监听输出单元必须显式绑定到物理设备；不得依赖 `AVAudioEngine.outputNode` 的“系统默认输出”，否则会把监听送到虚拟声卡，用户听不到。

### 4.2 音轨规则

1. 远端音轨：从 tap 的 8ch 中按设备标签取 `FL`（索引 0）和 `FR`（索引 1），组成立体声；不得平均 8 个声道，不得假定后 4 通道顺序。
2. 设备标签来自 `kAudioDevicePropertyPreferredChannelLayout`；G0 实测标签顺序为 `FL FR FC LFE BL BR SL SR`，与常见 7.1 的 `FL FR FC LFE SL SR BL BR` 不同。标签不可用时才回退索引 0/1，并记录 `channel_map_assumed` 警告。
3. 如果 tap 只有 1ch，复制到 L/R；如果是 2ch，使用 0/1；如果 >2ch，必须按标签。
4. 若 FL 有信号、FR 静音，默认保留原样（不人为复制）；P1 提供“单声道复制到双声道”开关，默认关闭。
5. 麦克风音轨：单声道 48 kHz Float32；AEC 默认关闭，高级区可开 Apple VoiceProcessingIO；不得写“已消除回声”。
6. 录制阶段不混音；必须保留 `remote.wav`（远端立体声）与 `microphone.wav`（麦克风单声道）作为独立源轨。混音只在停止后的 FFmpeg 导出阶段自动生成。
7. 监听只使用远端；麦克风永远不进入监听总线。
8. 正常视频会话交付两个文件：
   - `FaceTime.mp4`：`0:v` H.264 画面 + `0:a:0` Mix（双方混音），只有 1 条音频轨，作为默认分享/播放主文件；
   - `FaceTime.mkv`：`0:v` H.264 画面 + `0:a:0` Mix + `0:a:1` 远端 + `0:a:2` 麦克风，作为多轨归档。
9. 音轨标题固定：`Mix（双方）`、`远端（FaceTime）`、`麦克风`。MKV 顺序不得改变。
10. Mix 规则：远端保持立体声；麦克风上混为立体声；两路默认增益均为 1.0；使用限幅器防止削波；不得使用会把两路都压低的自动归一化。440 Hz/880 Hz 双音测试必须能在 MP4 默认音轨中同时测到。

### 4.3 时间与状态

1. 所有轨以同一会话时间轴 `t0` 为基准：
   - 视频会话：`t0` = 第一帧被接受的视频帧 host time；早于 `t0` 的音频样本丢弃，晚于 `t0` 的音频写前导静音；
   - 纯音频会话：`t0` = 第一个有效音频块 host time；另一路补前导静音。
2. 视频 PTS、WAV 起始位置都换算为相对 `t0`；不以“文件写入顺序”代替时间戳。`remote.wav` 与 `microphone.wav` 必须从 `t0` 开始，而不是各自从第一块样本开始。
3. 录制计时从进入 `recording` 后第一个有效样本/帧开始；UI 显示 `HH:MM:SS`。
4. 停止后先收尾媒体，再导出 MP4/MKV；导出期间不得显示“已完成”。
5. 任何“成功”必须以最终文件通过 `ffprobe` 校验为准；只有 WAV/`take.mov` 中间文件不算成功。

### 4.4 文件规则

1. 默认根目录：`~/Movies/FaceTime Recorder/`。
2. 会话目录：`~/Movies/FaceTime Recorder/YYYY-MM-DD/YYYY-MM-DD_HH-mm-ss/`。
3. 视频会话主文件：`FaceTime_YYYY-MM-DD_HH-mm-ss.mp4`（默认播放/分享）；归档文件：同名 `.mkv`（Mix/Remote/Mic）。
4. 仅音频降级：`FaceTime_YYYY-MM-DD_HH-mm-ss.m4a`（混音，可直接播放）+ 同名 `.mka`（Mix/Remote/Mic）。
5. 录制源轨：会话目录必须保留 `remote.wav` 与 `microphone.wav`（麦克风被拒时后者不存在）。
6. 文档中的 `FaceTime.mp4` / `FaceTime.mkv` 指产物类型；实际文件名带时间戳以避免覆盖。
7. 同名冲突时追加 `-2`、`-3`，绝不覆盖。
8. 会话目录必须包含 `manifest.json` 与 `diagnostics.json`；`take.mov` 为视频中间文件，成功后删除，失败时保留。
9. 录制中写 `.inprogress` 标记；成功后删除；失败时保留并写 `FAILED.txt`。
10. 不在文件名中使用 `:`、`/`、`\`、换行或 emoji。

### 4.5 使用与合规

1. 主界面必须常驻显示“请确保通话对方同意录音。”。点击“开始录制”即视为用户确认；V1 不额外弹确认框。
2. App 不自动开始、不后台偷录、不在 FaceTime 接通时自动弹录制。
3. 用户必须能随时看到“正在录制”的明确指示（窗口标题、状态栏、菜单栏至少一处）。
4. 录制指示不得被隐藏或伪装。

---

## 5. 主流程

### 5.1 首次启动与主界面

1. App 启动，进入 `idle`。
2. 主界面只显示 `0.4` 规定的元素：标题、两个开关、主按钮、状态行、结果行、同意提示、未验证提示、`高级` 入口。
3. `录制对方声音` 默认开；`录制我的麦克风` 默认开。
4. 高级区默认折叠；设备检查、权限详情、FFmpeg/8ch 徽章不显示。
5. 首次运行时由系统自动弹麦克风/屏幕/系统音频授权；不在主界面堆权限卡片。
6. 用户点击 `开始录制`；不选择设备、窗口、显示器、监听输出。视频自动找 FaceTime 窗口，监听固定接管前物理默认输出。

### 5.2 开始录制（preparing，自动决策）

1. 校验单实例；若已有会话，激活已有窗口并停止本次请求。
2. 读取两个开关：
   - 都为关：不创建会话；状态行“请至少开启一项”；主按钮禁用。
   - 只开麦克风：不接管系统输出、不启动远端 tap/自检/监听；录 FaceTime 窗口（找不到回退主显示器）+ 麦克风。
   - 开启对方声音：自动进入远端路径。
3. 开启对方声音时：
   - 校验 `HomePod Flow Audio` 存在、8ch/48k/Float32；
   - 记录接管前的系统默认物理输出；
   - 自动写 lease、切换系统默认输出到虚拟设备，不弹确认框；
   - 固定解析接管前的物理默认输出；不可用则 `monitor_output_missing`，不自动换设备；
   - 创建 tap/aggregate，执行 1 秒非静音自检；失败则清理并 `failed`。
4. 麦克风开启：自动选系统默认输入；权限拒绝时降级为“只录对方”，状态行显示原因；不阻塞录制。
5. 画面：自动查找 `appName=FaceTime` 窗口；找到录窗口，找不到回退主显示器并在状态行说明；屏幕权限拒绝时降级为仅音频（M4A/MKA）。
6. 创建会话目录、`.inprogress`、`manifest.json`；创建视频/WAV 写入器；预分配 ring。
7. 启动写入器，进入 `recording`。录制阶段不创建 Mix、不混音。

### 5.3 录制中（recording）

1. 主界面状态行显示 `录制中 MM:SS`；主按钮变为 `停止并保存`。
2. 两个开关锁定；不显示电平、监听开关、音量、磁盘等主界面控件。
3. 电平、丢帧、监听缓冲、磁盘、路由变化只在 `高级` 展开后显示；诊断写文件。
4. 开启对方声音时监听自动开启；固定送接管前物理默认输出；主界面不暴露监听开关/设备/音量，音量由 macOS 控制。
5. 远端连续 10 秒全零时，状态行仍显示录制中；高级区显示黄色警告，不自动停止。
6. 设备消失、默认输出被切走、视频源断开、磁盘低、睡眠唤醒时按异常流程处理，状态行给出原因。

### 5.4 停止与导出（stopping → muxing）

1. 用户点击“停止并保存”或触发自动停止。
2. 停止接收新数据；等待 300 ms 排空 ring；关闭 `take.mov`、`remote.wav`、`microphone.wav` 写入器；停止 tap/麦克风/监听。
3. 恢复默认输出（仅当 App 实际接管且当前默认仍是虚拟设备）。
4. 销毁 aggregate/tap；写 `manifest.json` 状态 `stopping`。
5. 进入 `muxing`，用 FFmpeg 按固定顺序导出：
   - 先生成一次 `mix.wav`（远端+麦克风混音，仅导出中间文件）；
   - 先导出 `FaceTime.mp4`：H.264 画面 + 1 条 Mix AAC（远端+麦克风）；
   - 再导出 `FaceTime.mkv`：H.264 画面 + 第 1 条 Mix、第 2 条 Remote、第 3 条 Mic；
   - 仅音频模式导出 `FaceTime.m4a`（Mix）+ `FaceTime.mka`（Mix/Remote/Mic）。
6. 混音只在此阶段发生；`remote.wav`/`microphone.wav` 不参与实时监听，也不在录制中混合。
7. 用 `ffprobe` 校验：
   - MP4：1 视频 + 1 音频（Mix）；默认音轨可播放；
   - MKV：1 视频 + 3 音频，顺序为 Mix/Remote/Mic；
   - 时长 >0；音轨可读；MP4 默认音轨中双方声音都在。
8. 成功：写 `diagnostics.json`、删除 `.inprogress`、删除 `take.mov`/`mix.wav`（保留源轨 WAV/MP4/MKV），进入 `finished`。
9. 失败：保留 `take.mov`/WAV/诊断。若一个产物成功、另一个失败，进入 `finished` 降级并明确标注；若没有可播放产物，进入 `failed`。

### 5.5 完成结果

1. 主界面只显示一行结果：`已保存 FaceTime.mp4（双方声音）` + `在 Finder 中显示`。
2. 麦克风关闭时显示 `已保存 FaceTime.mp4（仅对方声音）`；对方关闭时显示 `已保存 FaceTime.mp4（仅麦克风）`。
3. 仅音频模式显示 `已保存 FaceTime.m4a（双方声音）` + `在 Finder 中显示`。
4. MKV 多轨归档、两条路径、时长、大小、警告、输出恢复结果、诊断入口全部放在 `高级` 展开区。
5. 若输出恢复失败，状态行/高级区显示红色原因；不把主界面变成错误面板。

---

## 6. 异常流程

### 6.1 权限拒绝矩阵

| 权限 | 拒绝/受限时 | 产品行为 | 是否允许开始 | 用户可见 |
|---|---|---|---|---|
| 麦克风 | 拒绝/限制 | 录制视频+远端；MP4 的 Mix 仅含远端；MKV 为 Mix/Remote 两条音轨；结果行标注 | 是 | “本次没有麦克风音轨；MP4 只能听到对方。可在系统设置中授权后重新录制。” |
| 系统音频录制 | 拒绝/自检静音 | 阻止开始；不生成静音远端文件 | 否 | “无法读取 HomePod Flow Audio 的声音。请检查系统音频录制权限和系统输出。” |
| 屏幕录制 | 拒绝/受限 | 提供“仅录制声音”；若用户拒绝仅声音则阻止 | 是（仅声音） | “没有屏幕录制权限。可以只录声音。” |
| 屏幕录制 + 麦克风 | 都拒绝 | 仅远端音频：生成 `FaceTime.m4a`（远端）+ `FaceTime.mka`（Mix/Remote） | 是 | “本次只录制对方声音。” |
| 系统音频 + 屏幕 | 都拒绝 | 阻止 | 否 | “至少需要系统音频权限才能录制对方声音。” |
| 监听输出不可用 | 开始前固定物理输出不可用 | 阻止开始并提示连接耳机/扬声器；不自动换设备 | 否（录制对方时） | “没有可用的扬声器/耳机。” |
| 监听输出运行中消失 | 固定设备消失/被占用 | 关闭监听，录制继续；不自动换设备 | 是（已开始） | “监听已关闭，录制仍在继续。” |

### 6.2 设备与路由异常

| 场景 | 检测 | 行为 | 状态 | 错误码 |
|---|---|---|---|---|
| 虚拟设备不存在 | `deviceID(forUID:) == nil` | 阻止开始；提供“重新扫描”“打开音频 MIDI 设置” | `failed` | `device_missing` |
| 输出通道为 0 | 设备快照 | 阻止开始 | `failed` | `device_no_output` |
| 格式不是 8ch/48k/Float32 | ASBD 校验 | 阻止开始；显示实际格式 | `failed` | `format_unsupported` |
| 默认输出不是虚拟设备 | 默认输出 UID | 录制对方声音开启时自动接管；失败则阻止开始；关闭时不检查 | `failed` | `route_not_default` / `output_takeover_failed` |
| 接管失败 | `setDefaultOutput` 返回错误 | 回滚 lease；阻止开始 | `failed` | `output_takeover_failed` |
| 没有独立时钟设备 | 候选物理输出为空 | 阻止开始 | `failed` | `aggregate_clock_missing` |
| 没有物理监听输出 | 监听开启且候选中无物理设备 | 阻止开始；提示连接耳机/扬声器；若用户明确关闭监听则仅警告 | `failed` | `monitor_output_missing` |
| 录制中默认输出被切走 | 属性监听 | 警告；10 秒未恢复写诊断；继续录制 | `recording` | `route_changed_during_recording` |
| 录制中虚拟设备消失 | 属性监听 | 停止接收；尝试收尾；能导出则 `finished` 带警告，否则 `failed` | `stopping` | `device_lost` |
| 录制中监听输出消失 | 属性监听 | 关闭监听；录制继续；不自动换设备 | `recording` | `monitor_device_lost` |
| 视频源断开 | SCStream 停止/窗口关闭 | 声音继续；显示警告；停止后导出 M4A/MKA | `recording` | `video_source_lost` |

### 6.3 自检失败分类

| 现象 | 判定 | 错误码 | 用户动作 |
|---|---|---|---|
| 无回调 | 1 秒内 callbacks=0 | `self_test_no_callbacks` | 检查设备/aggregate；重试 |
| 回调有但帧数过少 | frames < 24000 | `self_test_frame_starved` | 检查设备忙/时钟；重试 |
| 全零 | 所有样本为 0 | `permission_audio_capture_denied_or_silent` | 打开系统音频录制权限；检查默认输出 |
| FL/FR 低于阈值 | `max(rmsFL,rmsFR) < 0.005` | `self_test_silent` | 检查权限/路由/音量；重试 |
| 只有非 FL/FR 有信号 | 其它通道有能量但 FL/FR 无 | `channel_map_mismatch` | 打开诊断；不要开始 |
| 测试音播放失败 | TonePlayer 启动失败 | `self_test_tone_failed` | 检查虚拟设备/时钟；重试 |
| tap 创建失败 | OSStatus | `tap_create_failed` | 检查 TCC/设备；重试 |
| aggregate 创建失败 | OSStatus | `aggregate_create_failed` | 检查时钟设备；重试 |

### 6.4 录制中异常

| 场景 | 产品行为 | 结果 |
|---|---|---|
| 磁盘剩余 < 500 MB | 立即自动停止；提示“磁盘空间不足，已保存已录部分” | 能导出则 `finished` 带警告；否则 `failed` |
| 磁盘剩余 < 2 GB（开始前） | 阻止开始；提示清理 | `failed` |
| Ring 溢出 | 记录计数；不阻塞实时回调；UI 黄色警告 | 继续；诊断含 `ring_overflow` |
| 监听 underrun | 记录计数；短暂静音；不停止录制 | 继续；诊断含 `monitor_underrun` |
| 时钟不连续（睡眠/唤醒） | 记录 gap；若 >2 秒写警告；继续 | 状态行/高级区提示“检测到时间缺口” |
| 视频写入失败 | 尝试继续音频；停止后导出 M4A/MKA | `finished` 带警告或 `failed` |
| 音频写入失败 | 停止录制；保留已写素材；诊断 | `failed` 或降级 |
| FFmpeg 不存在 | 开始前阻止，提示安装（MP4/MKV 都依赖 FFmpeg） | `mux_tool_missing` |
| MP4 导出失败 | 保留 MKV/WAV；若 MKV 可播放，`finished` 降级并标“MP4 缺失”；否则 `failed` | `mp4_export_failed` |
| MKV 导出失败 | 保留 MP4/WAV；若 MP4 可播放，`finished` 降级并标“归档缺失”；否则 `failed` | `mkv_export_failed` |
| 混音失败 | 保留 WAV；尝试只导出 Remote 版；失败则 `failed` | `mix_failed` |
| 两个产物都不可播放 | 保留 `take.mov`/WAV/诊断；提供恢复导出 | `failed` / `dual_output_incomplete` |
| 输出恢复失败 | 状态行/高级区红色提示；提供“立即恢复”；写 lease 保留 | `output_restore_failed` |
| 应用退出 | 提示“停止并保存/继续录制/强制退出” | 停止并保存走正常流程 |
| 应用崩溃/强制退出 | 下次启动检测 lease 和 `.inprogress`；提示恢复 | 见 7.4 |
| 第二个实例 | 激活已有窗口；不开始新录制 | `already_running` |

### 6.5 失败提示原则

1. 每条失败必须包含：**发生了什么、为什么、用户能做什么、诊断在哪**。
2. 不显示“未知错误”作为唯一信息；至少给出错误码和日志路径。
3. 不把“权限被拒”伪装成“设备忙”。
4. 不把“全零 PCM”显示为“录制成功”。
5. 不用红色错误吓唬可降级的场景（麦克风拒绝、屏幕拒绝）；用黄色警告。
6. 技术细节放在“诊断详情”折叠区，默认给普通人能懂的中文。

---

## 7. 状态机

### 7.1 主状态图

```text
                 startRequested
    ┌────────┐  ───────────────▶  ┌────────────┐
    │  idle  │                    │ preparing  │
    └────────┘  ◀───────────────  └────────────┘
        ▲          prepareFailed        │
        │                                │ prepareSucceeded
        │                                ▼
        │                         ┌────────────┐
        │        stopRequested    │ recording  │
        │      ┌─────────────────│            │
        │      │                 └────────────┘
        │      ▼                        │ fatalError
        │  ┌────────────┐               │
        │  │  stopping  │ ◀─────────────┘
        │  └────────────┘
        │        │ stopCompleted
        │        ▼
        │  ┌────────────┐   muxSucceeded   ┌────────────┐
        │  │   muxing   │ ───────────────▶ │  finished  │
        │  └────────────┘                  └────────────┘
        │        │ muxFailed
        │        ▼
        │  ┌────────────┐
        └─ │   failed   │
           └────────────┘
```

### 7.2 状态定义

| 状态 | 进入条件 | 系统行为 | UI | 允许事件 | 退出 |
|---|---|---|---|---|---|
| `idle` | 启动/重置 | 不持有 tap/aggregate/写入器；不持有 lease | 主界面：两个开关/开始按钮/状态行；高级可展开 | `startRequested` | → `preparing` |
| `preparing` | 用户点击开始 | 单实例、设备、路由、权限、目录、tap、自检、写入器 | 状态行“准备中”；主按钮禁用 | `prepareSucceeded`、`prepareFailed` | 成功→`recording`；失败→`failed` |
| `recording` | 自检通过、写入器已启动 | 实时采集、监听、写 `take.mov` + `remote.wav` + `microphone.wav`；不混音；更新诊断、守护磁盘/设备 | 状态行“录制中 MM:SS”；主按钮“停止并保存”；开关锁定 | `stopRequested`、`fatalError` | → `stopping` |
| `stopping` | 用户停止/致命错误/自动停止 | 停止新数据、排空 300 ms、关闭视频/WAV 写入器、恢复输出、销毁 tap | 状态行“准备中/正在收尾” | `stopCompleted`、`stopTimeout` | → `muxing` 或 `failed` |
| `muxing` | 媒体收尾完成 | 混音并导出 MP4 + MKV（或 M4A + MKA）；ffprobe 校验；清理中间文件 | 状态行“正在生成视频” | `muxSucceeded`、`muxFailed`、`muxTimeout` | → `finished` 或 `failed` |
| `finished` | 至少一个主产物通过校验；`deliveryStatus=complete/degraded` | 保留结果；不再写媒体 | 状态行“完成”；结果行“已保存 FaceTime.mp4（双方声音）”；高级区看 MKV/警告 | `reset` | → `idle` |
| `failed` | 无法产生可播放结果，或准备阶段硬失败 | 保留诊断；清理实时资源；恢复输出 | 状态行“失败：<原因>”；高级区看诊断/恢复 | `startRequested`、`reset` | `reset`→`idle`；`startRequested`→`preparing` |

### 7.3 状态转换表

| 当前 | 事件 | 守卫 | 动作 | 下一状态 |
|---|---|---|---|---|
| `idle` | `startRequested` | 单实例通过 | 创建会话 ID；开始准备 | `preparing` |
| `preparing` | `prepareSucceeded` | 设备/路由/自检/写入器全部成功 | 记录 `t0`；启动计时 | `recording` |
| `preparing` | `prepareFailed` | 任一硬校验失败 | 清理；恢复输出；写诊断 | `failed` |
| `recording` | `stopRequested` | 用户点击 | 停止新数据；排空 | `stopping` |
| `recording` | `fatalError` | 设备丢失/写入失败/磁盘耗尽 | 记录 `stopReason`；尝试收尾 | `stopping` |
| `stopping` | `stopCompleted` | 媒体已关闭；有可导出素材 | 恢复输出；启动 MP4/MKV 导出 | `muxing` |
| `stopping` | `stopTimeout` | 5 秒未完成 | 强制关闭；保留素材；写诊断 | `failed` |
| `muxing` | `muxSucceeded` | MP4 + MKV（或 M4A + MKA）至少主产物通过 ffprobe；`deliveryStatus` 记录完整/降级 | 写结果；删除 `.inprogress`；保留 WAV | `finished` |
| `muxing` | `muxFailed` | 没有任何可播放产物 | 保留 `take.mov`/WAV；写诊断 | `failed` |
| `muxing` | `muxTimeout` | 单产物 300 秒或总 600 秒未完成 | 终止 FFmpeg；保留素材 | `failed` |
| `finished` | `reset` | 用户关闭结果/再录 | 清理会话引用 | `idle` |
| `failed` | `reset` | 用户关闭错误 | 清理会话引用 | `idle` |
| `failed` | `startRequested` | 用户点击主按钮 | 保留诊断；重新准备 | `preparing` |

### 7.4 崩溃恢复

1. 每次状态变化原子写 `manifest.json`：`state`、`sessionID`、`startedAt`、`t0HostTime`、`outputLease`、`files`、`warnings`、`errorCode`。
2. `output-lease.json` 位于 `~/Library/Application Support/FaceTime Recorder/output-lease.json`；字段至少：
   - `createdAt`
   - `virtualDeviceUID`
   - `originalDefaultOutputUID`
   - `didChangeDefaultOutput`
   - `processIdentifier`
   - `sessionID`
3. 启动时先检查 lease：
   - 当前默认输出 == 虚拟设备，且 lease 的原设备仍存在：自动恢复，不弹确认框；状态行短暂显示结果；
   - 当前默认输出 != 虚拟设备：说明用户已自行改回；删除 lease，不改系统；
   - 原设备不存在：不自动切换；状态行提示，高级区让用户选择输出；
   - 检测到同 bundle id 的存活进程：不自动恢复；状态行提示“可能仍有另一个实例在录制”。
4. 启动时扫描 `~/Movies/FaceTime Recorder/**/.inprogress`：
   - 有有效 `take.mov` 或主文件：高级区提供“尝试恢复导出”；
   - 只有损坏中间文件：高级区提供“保留素材/在 Finder 中查看/删除”；
   - 空目录或小于 1 MB 且无有效媒体：可清理，但必须先写诊断并在 UI 说明。
5. 绝不覆盖已有结果；恢复导出使用新文件名或 `-recovered` 后缀。
6. 恢复失败时保留原目录，写 `FAILED.txt`，不删除用户素材。

---
## 8. 权限引导与降级

### 8.1 权限清单

| 权限 | Info.plist 键 | 用途 | 触发方式 | 拒绝后的降级 |
|---|---|---|---|---|
| 麦克风 | `NSMicrophoneUsageDescription` | 录制本地麦克风音轨 | `AVCaptureDevice.requestAccess(for: .audio)` | 继续录视频+远端；无麦克风轨 |
| 系统音频录制 | `NSAudioCaptureUsageDescription` | 读取虚拟设备输出（远端） | 创建 tap + 非静音自检；无可靠公开 preflight | 硬阻止；不生成静音远端 |
| 屏幕录制 | `NSScreenCaptureUsageDescription` | ScreenCaptureKit 录制画面 | `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` / `SCShareableContent` | 提供“仅录制声音” |

> macOS 15/26 的设置面板可能把系统音频与屏幕录制合并显示为“屏幕与系统音频录制”。文案使用“屏幕与系统音频录制（不同系统版本可能显示为‘屏幕录制’）”。

### 8.2 首次启动引导（极简模式）

1. 首次启动不显示三步向导；由 macOS 在第一次需要时自动弹麦克风/屏幕/系统音频授权。
2. 主界面不增加权限卡片；权限状态、解释、打开设置入口全部在 `高级` 折叠区。
3. 用户拒绝麦克风：继续录对方；状态行/结果行说明“仅对方声音”。
4. 用户拒绝屏幕：自动仅音频；不新增“仅录制声音”按钮。
5. 用户拒绝系统音频：无法录对方；状态行显示失败原因；高级区提供授权入口。
6. 授权后仍失败：高级区提示“退出并重新打开 App”。

### 8.3 拒绝后的交互

1. 麦克风拒绝：主界面不增加控件；开始后状态行显示“麦克风未授权，仅录对方”，结果行相应改为“仅对方声音”；高级区提供“打开系统设置”。
2. 系统音频拒绝：主按钮不可用；状态行显示“失败：远端音频权限未开启”；高级区提供权限详情、打开设置、重新自检；不允许“静音继续”。
3. 屏幕拒绝：自动降级为仅音频；状态行提示“无屏幕权限，仅录音频”；主按钮仍是“开始录制”，不新增按钮。
4. 权限状态变化：用户从系统设置返回 App 时自动刷新；不反复弹系统授权框。
5. 授权后仍失败：状态行显示“授权可能未生效”；高级区提供“重新启动”按钮。

### 8.4 打开系统设置

- 麦克风：`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
- 屏幕/系统音频：`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- 若深链失败：打开“系统设置 → 隐私与安全性”，让用户手动选择。
- 不要求辅助功能、完全磁盘访问、自动化权限。

---

## 9. 默认输出接管

### 9.1 产品原则

1. `录制对方声音` 开启且用户点“开始录制”时自动接管系统默认输出；App 启动/空闲时不接管；关闭该开关时不接管。V1 不弹确认框。
2. 主界面只显示一行说明：“会自动切换系统声音并在停止后恢复。”
3. 接管是“租约”行为：写 lease → 改默认 → 录制 → 恢复 → 删 lease。
4. 恢复只在“当前默认仍是虚拟设备”时执行；用户中途手动改走，不覆盖。
5. 停止、正常退出、崩溃后下次启动都自动尝试恢复；失败才在状态行/高级区提示。
6. 接管只改变“系统默认输出”；监听输出始终显式绑定物理设备，不随系统默认输出漂移到虚拟声卡。

### 9.2 接管前置条件

- 虚拟设备存在且可用；
- 能读取当前默认输出 UID；
- 当前没有其他 lease；
- 当前默认输出不等于虚拟设备（否则无需接管）；
- `录制对方声音` 已开启；
- 接管前的那台物理默认输出可用（内置扬声器/耳机）；不做设备选择；
- 不需要用户确认；开关本身就是授权。

### 9.3 正常接管与恢复

1. 读取 `originalDefaultOutputUID`，并把它作为监听输出候选（若为物理设备）。
2. 原子写 lease（临时文件 + rename）。
3. 调用 `AudioDeviceCatalog.setDefaultOutput(uid:)`。
4. 重新读取默认输出，确认等于虚拟设备；否则回滚并报 `output_takeover_failed`。
5. 录制停止/失败/取消时自动恢复：
   - 读当前默认输出；
   - 若等于虚拟设备且原设备仍存在：恢复到原设备，校验，删除 lease；
   - 若用户已改走：删除 lease，不修改；
   - 若原设备不存在：保留 lease，提示用户选择输出。
6. 应用正常退出：在 `applicationShouldTerminate` 中先尝试停止会话并恢复；最多等待 5 秒；超时则保留 lease，下次恢复。
7. 接管成功后、开始录制前，监听引擎必须把输出单元显式设置到“接管前的物理默认输出”；设置失败则阻止开始并报 `monitor_output_missing`，不自动换设备。

### 9.4 崩溃恢复（自动）

**启动时检测到 lease 且 PID 不存活：**

- 自动尝试恢复到 lease 中的原设备；不弹确认框。
- 恢复成功：主界面状态行短暂显示“系统声音已恢复”，随后回到 `空闲`。
- 恢复失败：状态行显示“系统声音未恢复”，高级区提供“立即恢复”“打开声音设置”“复制诊断”。
- 若原设备不存在：不自动切到别的设备；状态行提示，高级区让用户选择。

### 9.5 风险提示

接管期间，所有系统声音（包括通知、音乐、其他 App）都会进入虚拟设备，并可能被远端音轨录入。主界面只显示一行说明；完整风险放在高级区：

> 主界面：“会自动切换系统声音并在停止后恢复。”
>
> 高级区：“接管期间，其他 App 的提示音也可能被录入远端音轨。建议关闭通知和无关的声音 App。”

---

## 10. 文件、半成品与清理

### 10.1 目录结构

```text
~/Movies/FaceTime Recorder/
  2026-11-07/
    2026-11-07_14-30-05/
      FaceTime_2026-11-07_14-30-05.mp4   # 默认主文件：H.264 + Mix
      FaceTime_2026-11-07_14-30-05.mkv   # 多轨归档：Mix/Remote/Mic
      remote.wav                          # 录制源轨：远端立体声
      microphone.wav                      # 录制源轨：麦克风单声道
      mix.wav                             # 导出中间文件：成功后删除，失败保留
      take.mov                            # 视频中间文件；成功后删除，失败保留
      manifest.json                       # 状态、产物、轨道、警告、错误
      diagnostics.json                    # 设备/tap/自检/丢帧/漂移/混音
      .inprogress                         # 录制中标记
      FAILED.txt                          # 仅失败时
```

### 10.2 命名

- 会话目录与主文件使用 `yyyy-MM-dd_HH-mm-ss`。
- 视频会话：主文件 `FaceTime_..._.mp4`；归档 `FaceTime_..._.mkv`。
- 仅音频：`FaceTime_..._.m4a`（混音，可直接播放）+ `FaceTime_..._.mka`（多轨归档）。
- 源轨固定名：`remote.wav`、`microphone.wav`。
- 冲突追加 `-2`、`-3`。
- 不使用中文文件名作为主文件，避免跨工具兼容问题；UI 显示中文标题即可。

### 10.3 半成品策略

1. **准备阶段失败且未创建媒体**：删除空会话目录；诊断写到 App Support 的 `diagnostics/`。
2. **已创建媒体但录制失败**：保留会话目录、`take.mov`、`manifest.json`、`diagnostics.json`、`FAILED.txt`；不自动删除。
3. **MP4 成功、MKV 失败**：进入 `finished`，`deliveryStatus=degraded`；保留 MP4/WAV；UI 标“多轨归档缺失”。
4. **MKV 成功、MP4 失败**：进入 `finished`，`deliveryStatus=degraded`；保留 MKV/WAV；UI 标“默认可播放文件缺失，可用 MKV”。
5. **两个产物都失败**：进入 `failed`；保留 `take.mov`/WAV；提供“尝试恢复导出”。
6. **崩溃后**：扫描 `.inprogress`；优先用 `take.mov` + WAV 重新导出；不覆盖原文件。
7. **清理**：只清理空目录/无效临时文件；`remote.wav`/`microphone.wav`/用户媒体永不自动删除。

### 10.4 磁盘策略

- 开始前：可用空间 < 2 GB 阻止开始；2–5 GB 黄色警告。
- 录制中：每 5 秒检查；< 500 MB 自动停止并保存。
- 预估：1080p30 H.264 约 8 Mbps + 两条 WAV + MP4/MKV 双产物，15 分钟约 2–3 GB（实际以文件为准）；UI 不承诺精确值。

---

## 11. 中文界面文案清单

> 文案原则：先说他能懂的结果，再说技术原因；不夸大、不承诺未验证能力。

### 11.0 极简主界面（V1 唯一主界面）

| Key | 中文文案 | 使用位置 |
|---|---|---|
| `main.title` | FaceTime 录音 | 标题 |
| `main.toggle.remote` | 录制对方声音 | 大开关，默认开 |
| `main.toggle.mic` | 录制我的麦克风 | 大开关，默认开 |
| `main.toggle.remoteHint` | 会自动切换系统声音并在停止后恢复。 | 远端开关下方一行 |
| `main.button.start` | 开始录制 | 主按钮 |
| `main.button.stop` | 停止并保存 | 录制中主按钮 |
| `main.status.idle` | 空闲 | 状态行 |
| `main.status.preparing` | 准备中 | 状态行 |
| `main.status.recording` | 录制中 %@ | 状态行，%@ 为 MM:SS |
| `main.status.muxing` | 正在生成视频 | 状态行 |
| `main.status.done` | 完成 | 状态行 |
| `main.status.failed` | 失败：%@ | 状态行，%@ 为中文原因 |
| `main.result.saved` | 已保存 FaceTime.mp4（双方声音） | 完成后一行 |
| `main.result.saved.remoteOnly` | 已保存 FaceTime.mp4（仅对方声音） | 麦克风关闭/拒绝 |
| `main.result.saved.micOnly` | 已保存 FaceTime.mp4（仅麦克风） | 对方关闭 |
| `main.result.saved.audioOnly` | 已保存 FaceTime.m4a（双方声音） | 仅音频 |
| `main.result.reveal` | 在 Finder 中显示 | 结果行按钮 |
| `main.consent` | 请确保通话对方同意录音。 | 常驻小字 |
| `main.unverified` | 远端音频：待真人通话验证 | 底部固定小字 |
| `main.advanced` | 高级 | 折叠区标题 |
| `main.toggleBothOff` | 请至少开启一项 | 两个开关都关时的状态行 |

> 以下 11.1–11.7 为 `高级` 折叠区或内部规范文案，不是 V1 主界面的必显元素。

### 11.1 全局与状态（高级/内部）

| Key | 中文文案 | 使用位置 |
|---|---|---|
| `app.title` | FaceTime 录制器 | 窗口标题 |
| `app.subtitle` | 录下画面和双方声音；默认 MP4 直接能听，MKV 保留多轨。 | 首页副标题 |
| `badge.faceTimeUnverified` | 远端音频：待真人通话验证 | 高级区徽章；主界面使用 `main.unverified` |
| `status.idle` | 准备录制 | 状态栏 |
| `status.preparing` | 正在检查设备与权限… | 状态栏 |
| `status.preparing.selfTest` | 正在做 1 秒非静音自检… | 准备进度 |
| `status.recording` | 录制中 | 状态栏；窗口标题加红点 |
| `status.stopping` | 正在收尾… | 状态栏 |
| `status.muxing` | 正在生成 MP4 / MKV… | 状态栏 |
| `status.finished` | 已完成 | 结果页 |
| `status.failed` | 录制失败 | 错误页 |
| `status.recovering` | 正在恢复上次录制… | 启动恢复 |

### 11.2 按钮

| Key | 中文文案 | 说明 |
|---|---|---|
| `button.start` | 开始录制 | 主按钮 |
| `button.start.audioOnly` | 仅录制声音 | 高级/内部；主界面自动降级，不新增按钮 |
| `button.stop` | 停止并保存 | 录制中 |
| `button.cancel` | 取消 | 高级/内部（V1 主界面无取消按钮） |
| `button.retry` | 重试 | 失败页 |
| `button.recordAgain` | 再录一次 | 结果页 |
| `button.reveal` | 在 Finder 中显示 | 结果页 |
| `button.copyDiagnostics` | 复制诊断信息 | 失败页/结果页 |
| `button.openSettings` | 打开系统设置 | 权限 |
| `button.openSoundSettings` | 打开声音设置 | 路由/恢复 |
| `button.takeover` | 重新尝试自动切换 | 高级区 |
| `button.restore` | 恢复原输出 | 高级区 |
| `button.keepCurrent` | 保留当前设置 | 高级区 |
| `button.recheck` | 重新检查 | 高级区 |
| `button.restart` | 重新启动 App | 高级区，授权后仍失败 |

### 11.3 设备与路由

| Key | 中文文案 | 说明 |
|---|---|---|
| `device.virtual.name` | HomePod Flow Audio | 设备名 |
| `device.virtual.ready` | 虚拟声卡已就绪（8 声道 / 48 kHz / 仅输出） | 设备卡片 |
| `device.virtual.missing` | 没有找到 HomePod Flow Audio。请确认驱动已安装。 | 错误 |
| `route.current` | 当前系统输出：%@ | 首页 |
| `route.needed` | 自动切换系统声音失败，FaceTime 的声音不会进入录制。 | 高级区错误 |
| `route.takeover.explain` | 会自动把系统声音切到 HomePod Flow Audio，停止后恢复到“%@”。 | 高级区说明 |
| `route.takeover.systemAudioWarning` | 接管期间，其他 App 的提示音也可能被录入远端音轨。建议关闭通知和无关的声音 App。 | 高级区说明 |
| `route.takeover.success` | 已自动切换到 HomePod Flow Audio，录制结束后会自动恢复。 | 状态行/高级区 |
| `route.restore.success` | 系统声音已恢复到“%@”。 | 状态行/高级区 |
| `route.restore.failed` | 无法自动恢复系统声音。请打开声音设置，把输出改回“%@”。 | 高级区错误 |
| `route.changed` | FaceTime 的声音已切走，远端将静音。 | 状态行/高级区 |

### 11.4 监听与电平

| Key | 中文文案 | 说明 |
|---|---|---|
| `monitor.title` | 监听状态（只读） | 高级区 |
| `monitor.hint` | 只监听对方，不会把你的麦克风播出去。 | 说明 |
| `monitor.off` | 监听已关闭，录制仍在继续。 | 提示 |
| `monitor.unavailable` | 固定监听设备不可用；录制仍在继续，但你可能听不到对方。 | 警告 |
| `monitor.physicalOnly` | 监听固定使用接管前的 MacBook 扬声器/耳机；音量由 macOS 控制。 | 说明 |
| `level.remote` | 对方 | 电平标签 |
| `level.mic` | 麦克风 | 电平标签 |
| `level.remoteSilent` | 远端已经 10 秒没有声音，可能未接通或路由异常。 | 黄色提示 |
| `level.micClipping` | 麦克风过载，请离远一点或调低输入音量。 | 黄色提示 |

### 11.5 权限

| Key | 中文文案 |
|---|---|
| `permission.mic.title` | 录制你的声音 |
| `permission.mic.body` | 用于生成独立的麦克风音轨。拒绝也可以继续，只是不会有你的声音轨。 |
| `permission.audio.title` | 读取对方的声音 |
| `permission.audio.body` | FaceTime 的声音会先送到 HomePod Flow Audio，App 需要系统音频录制权限才能读取。这个权限不会修改驱动。 |
| `permission.audio.denied` | 无法读取 HomePod Flow Audio 的声音。请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许本 App。 |
| `permission.screen.title` | 录制通话画面 |
| `permission.screen.body` | 自动录制 FaceTime 窗口；找不到窗口才回退主显示器。拒绝也可以只录声音。 |
| `permission.screen.denied` | 没有屏幕录制权限。可以只录声音，或去系统设置授权。 |
| `permission.restartHint` | 授权后如果仍失败，请退出并重新打开 App。 |
| `permission.recheck` | 我已授权，重新检查 |

### 11.6 结果与警告

| Key | 中文文案 |
|---|---|
| `result.primary.mp4` | 可直接播放（双方声音） |
| `result.primary.m4a` | 可直接播放（双方声音，仅音频） |
| `result.archive.mkv` | 多轨归档：Mix / 远端 / 麦克风 |
| `result.archive.mka` | 多轨归档：Mix / 远端 / 麦克风（仅音频） |
| `result.tracks` | MP4：画面 + 双方混音；MKV：画面 + Mix/远端/麦克风 |
| `result.tracks.audioOnly` | M4A：双方混音；MKA：Mix/远端/麦克风 |
| `result.noMic` | 本次没有麦克风音轨；MP4 只能听到对方声音。 |
| `result.noVideo` | 本次没有画面（屏幕录制权限未开启或画面源中断）。 |
| `result.mp4Fallback` | MP4 导出失败；MKV 多轨归档可用。 |
| `result.mkvFallback` | MKV 导出失败；MP4 可直接播放。 |
| `result.mka` | 仅音频模式，已生成 M4A（可直接播放）和 MKA（多轨归档）。 |
| `result.duration` | 时长：%@ |
| `result.size` | 大小：%@ |
| `result.path` | 文件位置：%@ |
| `result.mp4Path` | 可直接播放的 MP4：%@ |
| `result.mkvPath` | 多轨归档 MKV：%@ |
| `warning.droppedFrames` | 本次录制有丢帧，详情见诊断信息。 |
| `warning.clockGap` | 检测到时间缺口（可能由睡眠/设备切换引起）。 |
| `warning.routeChanged` | 录制过程中系统输出被切换过，远端可能有静音段。 |
| `warning.videoLost` | 画面源已断开，声音仍在录制。 |
| `warning.diskLow` | 磁盘空间不足，已自动停止并保存。 |
| `warning.echo` | 检测到可能的回声。建议佩戴耳机，或开启 Apple 语音处理。 |
| `warning.unverified` | FaceTime 真人通话音频仍待验证；请先做一次短通话测试。 |

### 11.7 错误

| Key | 中文文案 | 动作 |
|---|---|---|
| `error.deviceMissing` | 没有找到 HomePod Flow Audio。请确认驱动已安装，并在“音频 MIDI 设置”中启用。 | 重新检查 / 打开音频 MIDI 设置 |
| `error.routeNotDefault` | 自动切换系统声音失败，FaceTime 的声音没有送到录制设备。 | 重新尝试 / 打开声音设置 |
| `error.monitorMissing` | 没有可用的 MacBook 扬声器/耳机，无法实时听到对方。 | 连接耳机 / 打开声音设置 |
| `error.selfTestSilent` | 能启动采集，但读到的声音全是静音。通常是系统音频权限未授权，或没有声音送到虚拟设备。 | 打开设置 / 重新自检 |
| `error.selfTestNoCallbacks` | 采集没有收到任何音频回调。请检查设备是否被其他程序占用。 | 重试 / 诊断 |
| `error.selfTestToneFailed` | 无法播放自检音。请检查 HomePod Flow Audio 是否正常。 | 重试 / 诊断 |
| `error.formatUnsupported` | 设备格式不是预期的 8 声道 / 48 kHz / Float32。 | 诊断 |
| `error.muxToolMissing` | 找不到 FFmpeg，无法生成 MP4/MKV。 | 安装说明 / 重试 |
| `error.mixFailed` | 双方混音生成失败。已保留远端/麦克风 WAV，可尝试恢复导出。 | 恢复导出 / Finder |
| `error.mp4Failed` | MP4 导出失败；MKV 可能仍可用。 | 打开 MKV / 恢复导出 |
| `error.mkvFailed` | MKV 导出失败；MP4 可能仍可用。 | 打开 MP4 / 恢复导出 |
| `error.muxFailed` | 两个可播放文件都没有生成。已保留原始素材。 | 恢复导出 / Finder |
| `error.dualOutputIncomplete` | 只完成了部分产物；请查看缺失的是 MP4 还是 MKV。 | 查看详情 / 恢复导出 |
| `error.toneValidationFailed` | 双音测试未同时检出 440 Hz 与 880 Hz，混音可能不完整。 | 查看诊断 / 重试导出 |
| `error.diskFull` | 磁盘空间不足，录制已停止。 | 清理 / Finder |
| `error.outputRestoreFailed` | 系统声音没有恢复。请手动把输出改回原设备。 | 立即恢复 / 打开声音设置 |
| `error.alreadyRunning` | 已经有一个录制窗口在运行。 | 激活已有窗口 |
| `error.videoSourceLost` | 画面源已断开。声音仍可继续，停止后将只保留声音。 | 继续 / 停止 |

---

## 12. 可测验收标准

> 证据目录约定：`tests/evidence/YYYY-MM-DD/<case-id>/`。每条至少包含 `command.txt`、`exit_code.txt`、`stdout.log`、`stderr.log`；涉及音频的附 `report.json` 与 WAV；涉及界面的附截图；涉及听感的附 `human-note.md`。没有证据的“通过”不算通过。

### 12.1 构建与基线

| ID | P | 前置 | 步骤 | 期望 | 证据 | 执行 |
|---|---|---|---|---|---|---|
| AC-01 | P0 | Mac 路径 `/Users/lvzhipeng/Developer/FaceTimeRecorder`；Xcode 26.6；xcodegen 2.45.4；ffmpeg 9.0.2 | `export PATH=/opt/homebrew/bin:$PATH`；`xcodegen generate`；`xcodebuild -project FaceTimeRecorder.xcodeproj -scheme FaceTimeRecorder -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build`；`xcodebuild -project FaceTimeRecorder.xcodeproj -scheme CoreTests -derivedDataPath build CODE_SIGN_IDENTITY=- test` | 两条命令退出码均为 0；生成 `build/Build/Products/Debug/FaceTime Recorder.app`；`file` 显示 arm64；无签名错误 | `command.txt`、`build.log`、`test.xcresult`、`file.txt` | Dev/QA |
| AC-02 | P0 | 驱动已安装；GUI 会话 | `build/Build/Products/Debug/AudioProbe list --json` | 输出包含 UID `com.homepodflow.virtual-audio.surround71.v1`；`inputChannels=0`、`outputChannels=8`、`nominalSampleRate=48000`；标签为 `FL FR FC LFE BL BR SL SR` | `list.json`、`stdout.log` | QA |
| AC-03 | P0 | GUI 已授权系统音频；默认输出为虚拟设备；无其他声音 | `AudioProbe tap --uid com.homepodflow.virtual-audio.surround71.v1 --seconds 5 --tone --wav /tmp/fr-g1.wav --report /tmp/fr-g1.json --all-channels` | `verdict.code=pcm_detected`；callbacks>0；frames>0；FL 或 FR 的 RMS ≥0.005；8ch WAV 可读；退出码 0 | `report.json`、`fr-g1.wav`、`stdout.log` | QA/总调度 |
| AC-04 | P0 | 从 sshd 启动、无 TCC | 同 AC-03 命令 | `verdict.code=all_zero_pcm`；callbacks>0；frames>0；所有通道 RMS=0；退出码 10 | `report.json`、`stdout.log` | 总调度 |
| AC-05 | P0 | 虚拟设备缺失或模拟接管失败；`录制对方声音` 开启 | 启动 App，点击“开始录制” | 不进入 `recording`；状态行“失败：无法切换系统声音/找不到虚拟声卡”；高级区显示 `device_missing` 或 `output_takeover_failed`；不创建媒体文件 | 截图、`diagnostics.json`、`manifest.json` | QA |

### 12.2 权限与自检

| ID | P | 前置 | 步骤 | 期望 | 证据 | 执行 |
|---|---|---|---|---|---|---|
| AC-06 | P0 | 系统音频权限被拒/撤销；默认输出为虚拟设备 | 启动 App，点击开始 | 进入 `preparing` 后失败；错误码 `permission_audio_capture_denied_or_silent` 或 `self_test_silent`；不生成主文件；自检 8ch WAV 保存 | 截图、`self-test-8ch.wav`、`diagnostics.json` | QA |
| AC-07 | P0 | 麦克风权限被拒；系统音频/屏幕已授权 | 开始录制 30 秒，说话并停止 | 生成 `FaceTime.mp4`（1 视频 + 1 条 Mix=仅远端）和 `FaceTime.mkv`（1 视频 + 2 条音频：Mix/Remote）；结果行显示“仅对方声音” | `ffprobe.txt`、截图、`diagnostics.json` | QA |
| AC-08 | P0 | 屏幕录制权限被拒；系统音频/麦克风已授权 | 保持默认，录制 30 秒 | 生成 `FaceTime.m4a`（1 条 Mix）和 `FaceTime.mka`（3 条音频：Mix/Remote/Mic）；无视频轨；状态行/结果行明确“仅音频” | `ffprobe.txt`、截图 | QA |
| AC-09 | P0 | 全部权限已授权；默认输出虚拟；耳机监听 | 录制 60 秒，双方说话，停止 | 生成 `FaceTime.mp4`（1 视频 + 1 条 Mix）和 `FaceTime.mkv`（1 视频 + 3 条音频：Mix/Remote/Mic）；`remote.wav`/`microphone.wav` 存在；默认播放 MP4 能同时听到双方；MKV 三条音轨时长差 ≤0.5 秒 | `ffprobe.txt`、`report.json`、`human-note.md`、WAV 信息 | QA/总调度 |
| AC-10 | P0 | 录制中；自动监听开启 | 录制 60 秒；调整 macOS 系统音量 3 次 | 录制不中断；计时连续；最终音频轨无 >100 ms 缺口；系统音量不改变音轨数量 | `diagnostics.json`、`human-note.md` | QA |
| AC-11 | P0 | 耳机接物理输出；监听开启；远端静音 | 对着麦克风说话 20 秒，同时录制 | 耳机中听不到自己的声音；麦克风轨有信号；监听总线无麦克风样本 | `human-note.md`、`diagnostics.json`、代码审查记录 | QA/Dev |

### 12.3 输出接管与恢复

| ID | P | 前置 | 步骤 | 期望 | 证据 | 执行 |
|---|---|---|---|---|---|---|
| AC-12 | P0 | 默认输出为内置扬声器；`录制对方声音` 开；无 lease | 点击开始，录制 20 秒后停止 | 不弹确认框；开始前自动切到虚拟；停止后恢复为内置扬声器；lease 删除；状态行/高级区显示恢复成功 | `default-output-before.txt`、`after.txt`、`lease.json`、截图 | QA |
| AC-13 | P0 | 接管录制中 | `kill -9 <FaceTime Recorder pid>`；重新打开 App | 检测到 stale lease 后自动恢复原输出，不弹确认框；状态行短暂显示恢复结果；高级区提供上次会话恢复入口 | 截图、`lease.json`、`default-output-after.txt` | 总调度/QA |
| AC-14 | P0 | 接管录制中 | 在系统设置把默认输出改成内置扬声器；停止录制 | App 显示路由警告；停止时**不**覆盖用户选择；lease 清理；诊断含 `route_changed_during_recording` | 截图、`diagnostics.json`、`default-output-after.txt` | QA |
| AC-15 | P0 | 录制中；模拟磁盘低（测试注入或小容量卷） | 让可用空间降到 500 MB 以下 | 30 秒内自动停止；已录部分可播放或保留素材；提示磁盘不足 | `diagnostics.json`、文件列表、截图 | QA |

### 12.4 文件、混音导出与恢复

| ID | P | 前置 | 步骤 | 期望 | 证据 | 执行 |
|---|---|---|---|---|---|---|
| AC-16 | P0 | 临时重命名/遮挡 `/opt/homebrew/bin/ffmpeg` | 录制 20 秒后停止 | 开始前提示 `mux_tool_missing`；不显示“MP4/MKV 成功”；WAV/`take.mov` 保留 | 截图、`diagnostics.json`、`ffprobe.txt` | QA |
| AC-17 | P0 | 录制中；虚拟设备被移除/驱动重载（测试环境） | 录制 20 秒后使设备消失 | App 安全停止；保留已录素材；诊断含 `device_lost`；不崩溃 | `diagnostics.json`、崩溃日志（无） | 总调度/QA |
| AC-18 | P0 | 正常环境 | 连续录制 15 分钟（合成测试音 + 画面） | 无 ring 溢出；监听 underrun=0 或可解释；音画漂移 ≤100 ms；文件可播放；内存无持续增长 | `diagnostics.json`、`ffprobe.txt`、`activity.txt` | QA |
| AC-19 | P0 | 两台设备；双方同意；FaceTime 真人通话 | 进行 5 分钟真人通话，双方说话，录制并停止 | **默认双击 `FaceTime.mp4` 就能同时听到双方**；MKV 的 Mix/Remote/Mic 三条轨独立可播；时间对齐；无持续回声 | `ffprobe.txt`、`human-note.md`、原始文件哈希 | 总调度 + 用户 |
| AC-20 | P0 | AC-19 通过 | 15 分钟真人通话，含静音段、耳机监听、一次 macOS 音量调整 | 端到端可用；MP4 默认播放双方声音；MKV 三音轨；无未解释丢帧；音画差 ≤100 ms；状态行无红色失败 | `ffprobe.txt`、`human-note.md`、`diagnostics.json` | 总调度 + 用户 |
| AC-21 | P0 | 屏幕权限已授权；FaceTime 窗口已打开 | 保持默认，录制 20 秒 | 自动找到 `appName=FaceTime` 窗口并只录该窗口；不要求用户选择；画面可读 | 截图、抽帧 PNG、`ffprobe.txt` | QA |
| AC-22 | P0 | 正常环境 | 连续录制两次，第二次在同一秒内开始 | 两个会话目录；文件名不覆盖；冲突追加 `-2`；`manifest.json` 各自完整 | 目录列表、`manifest.json` | QA |
| AC-23 | P0 | 导出中 | 在 `muxing` 时 `kill -9` FFmpeg 或 App | 重新启动后可用 `take.mov` + WAV 重新导出；不丢原始素材；不覆盖旧结果 | 截图、`take.mov`、恢复后的 `ffprobe.txt` | QA |

### 12.5 交互与稳定性

| ID | P | 前置 | 步骤 | 期望 | 证据 | 执行 |
|---|---|---|---|---|---|---|
| AC-24 | P0 | 已有一个 App 实例在录制 | 再打开一个实例 | 第二个实例不开始录制；激活已有窗口；提示 `already_running` | 截图、进程列表 | QA |
| AC-25 | P0 | 首次安装/清空同意记录 | 打开主界面，点击开始 | “请确保通话对方同意录音。”常驻可见；不弹额外确认框；点击开始即视为确认；进入 `preparing` | 截图、`manifest.json` | QA |
| AC-26 | P0 | 录制中 | 点击关闭窗口/退出 App，选择“停止并保存” | 正常进入 `stopping`/`muxing`；生成文件或保留素材；输出恢复 | 截图、`ffprobe.txt`、`default-output-after.txt` | QA |
| AC-27 | P0 | 录制中 | 让 Mac 进入睡眠 30 秒后唤醒 | 若阻止了空闲睡眠：录制连续；若发生睡眠：停止并保存，状态行/高级区提示时间缺口；不产生损坏主文件 | `diagnostics.json`、截图、`ffprobe.txt` | QA |
| AC-28 | P0 | 旧 HomePod Flow 仓库 | 在旧仓库执行 `git status --short` | 无任何本项目的修改；本工具没有改驱动文件 | `git-status.txt`、`diff.txt` | 总调度 |
| AC-29 | P0 | 正常环境 | 录制 30 秒后检查源轨 | `remote.wav`（立体声）与 `microphone.wav`（单声道）存在；`WAVReader.info` 可读；时长与 MP4 差 ≤0.5 秒 | `wav-info.json`、`ffprobe.txt` | QA |
| AC-30 | P1 | 8ch 诊断开启 | 录制 30 秒 | 生成 8ch WAV；标签/通道顺序与设备一致；文件可读 | `wav-info.json`、`report.json` | QA |
| AC-31 | P0 | 合成 `remote440.wav`（立体声 48k）+ `mic880.wav`（单声道 48k）+ 10 秒视频 | 用与 App 相同的导出器生成 MP4/MKV；提取 MP4 默认音轨做 Goertzel/FFT | MP4 只有 1 条音频轨，440 Hz 与 880 Hz 均高于阈值（建议 ≥-30 dBFS 相对峰值）；MKV 有 3 条音轨且顺序为 Mix/Remote/Mic；Mix 轨同时含两个频率 | `ffprobe.json`、`tone-analysis.json`、`FaceTime.mp4`、`FaceTime.mkv` | QA/Dev |
| AC-32 | P0 | 虚拟设备播放 440 Hz；物理扬声器/手机在麦克风附近播放 880 Hz；双方权限已授权 | 录制 15 秒，停止导出；默认播放 MP4 | MP4 默认音轨能同时听到/测到 440 与 880；MKV 的 Remote 轨只有 440、Mic 轨只有 880（允许串音但主峰正确） | `tone-analysis.json`、`human-note.md`、`ffprobe.json` | 总调度/QA |
| AC-33 | P0 | 接管前物理默认输出（耳机/内置扬声器）可用；系统输出被接管到虚拟设备 | 录制 20 秒，播放系统音乐并对着麦克风说话 | 监听从接管前物理设备出声；虚拟设备不作为监听输出；UI 无设备/音量选择；耳机中听不到自己的麦克风；诊断 `monitorOutputUID == originalPhysicalUID` | 截图、`diagnostics.json`、`human-note.md` | QA |
| AC-34 | P0 | 正常录制 20 秒素材 | 分别注入 MP4 导出失败、MKV 导出失败 | MP4 失败但 MKV 可播放：`finished` 降级并标“MP4 缺失”；MKV 失败但 MP4 可播放：`finished` 降级并标“归档缺失”；两者都失败：`failed`；WAV 保留 | 截图、`manifest.json`、`diagnostics.json` | QA |
| AC-35 | P0 | 首次启动/恢复默认设置 | 打开主界面 | 只显示：标题“FaceTime 录音”、两个开关、一个主按钮、状态行、同意提示、底部“远端音频：待真人通话验证”、高级入口；不显示设备/窗口/显示器/音量/权限卡片/FFmpeg/8ch | 主界面截图、可访问性树 | QA/UI |
| AC-36 | P0 | 主界面 | 展开“高级” | 高级区默认收起；展开后可看到设备、音量、权限详情、诊断、日志、FFmpeg/8ch；收起后不影响主流程 | 收起/展开截图 | QA/UI |
| AC-37 | P0 | 两个开关默认开；默认输出为内置扬声器 | 点击开始录制 20 秒 | 不出现接管确认弹窗；开关下方一行说明；自动切到虚拟；监听从内置扬声器出声；停止后自动恢复；结果行“已保存 FaceTime.mp4（双方声音）” | 录屏/截图、`lease.json`、`diagnostics.json`、`ffprobe` | QA |
| AC-38 | P0 | 主界面 | 分别测试四种开关组合 | 开/开：双方混音；开/关：仅对方；关/开：不接管、仅麦克风；关/关：主按钮禁用、状态“请至少开启一项”；录制中开关锁定 | 截图、`ffprobe`、`diagnostics.json` | QA |
| AC-39 | P0 | 录制完成 | 查看主界面结果行 | 结果行显示“已保存 FaceTime.mp4（双方声音）”+“在 Finder 中显示”；MKV 多轨归档只在高级区；点击 Finder 能定位 MP4 | 截图、Finder 窗口 | QA/UI |
| AC-40 | P0 | 录制中 | 尝试点击两个开关 | 开关禁用/不可切换；需停止后才能改变组合 | 截图 | QA/UI |
| AC-41 | P0 | 屏幕权限已授权；没有 FaceTime 窗口 | 保持默认，点击开始 | 回退主显示器录制；状态行明确“未找到 FaceTime 窗口，已录制主显示器”；不弹选择器 | 截图、`ffprobe.txt` | QA |

### 12.6 验收判定

1. P0 的 AC-01 至 AC-29、AC-31 至 AC-41 全部通过，才可进入 G6。
2. AC-19/AC-20 未完成前，产品状态只能是“远端音频：待真人通话验证”，不得发布“支持 FaceTime”的文案。
3. 任何 P0 失败必须附缺陷单、复现步骤、日志、影响范围；不允许用“环境问题”无证据关闭。
4. 降级路径（无麦克风、仅音频、MP4/MKV 单产物缺失）必须明确标注，不得当作完整成功。

---

## 13. 风险声明

| ID | 风险 | 概率/影响 | 缓解 | 当前状态 |
|---|---|---|---|---|
| R-01 | FaceTime 真人通话音频未验证，可能因路由/编码/权限导致远端静音 | 高/高 | 强制路由校验 + 非静音自检 + 真人 5/15 分钟验收；文案写“待验证” | **未消除** |
| R-02 | 无 TCC 时 tap 全零且不报错，容易被误判为成功 | 高/高 | 自检阈值、全零分类、禁止“启动即成功” | 已设计，待实测 |
| R-03 | 接管系统默认输出影响全系统声音；崩溃可能导致用户没声音 | 中/高 | 开关下一行说明、自动接管、lease、崩溃自动恢复、停止恢复 | 已设计，待实测 |
| R-04 | 设备级 tap 会录入所有送到虚拟设备的系统声音，不只 FaceTime | 高/中 | UI 提示关闭通知/无关 App；P2 再做按进程隔离 | 接受 |
| R-05 | Apple VPIO 与 WebRTC AEC3 效果不同；AEC 可能无效或改变音色 | 中/高 | 默认关闭；高级可开 VPIO；耳机建议；G5 实测；不宣称“已消除回声” | 待验证 |
| R-06 | 长录时钟漂移导致音画不同步 | 中/高 | host time PTS、监听自适应重采样、漂移诊断、15 分钟门禁 | 待实测 |
| R-07 | FFmpeg 缺失/失败导致无法生成 MP4/MKV | 中/中 | 开始前检查；单产物降级；保留 WAV/`take.mov`；P1 重试导出 | 已设计 |
| R-08 | 虚拟驱动升级/卸载导致 UID/格式变化 | 中/高 | 启动校验；明确错误；不自动改驱动 | 已设计 |
| R-09 | ScreenCaptureKit 权限/窗口变化导致视频缺失 | 中/中 | 仅音频降级；视频源断开警告；窗口/全屏兜底 | 已设计 |
| R-10 | 用户未取得对方同意，产生法律风险 | 中/高 | 首次同意提示；文档声明；不提供隐蔽模式 | 产品约束 |
| R-11 | 磁盘/CPU/内存不足导致录制中断 | 中/中 | 2 GB 门槛、500 MB 自动停止、ring 上限、诊断 | 已设计 |
| R-12 | 群组 FaceTime、SharePlay、连续互通、屏幕共享未验证 | 中/中 | 不宣传；单独验收；标注待验证 | 未验证 |
| R-13 | 受 DRM/系统保护的内容可能无法录制 | 低/中 | 不绕过；失败时提示；不承诺 | 接受 |
| R-14 | 蓝牙耳机延迟/切换导致监听与 AEC 异常 | 中/中 | 固定接管前物理输出；掉线则关闭监听并警告；AEC 默认关 | 待实测 |
| R-15 | 混音削波/一方过小，MP4 默认播放听不清双方 | 中/高 | 1.0/1.0 + 限幅；440/880 双音自动测试；真人默认播放验收 | 待实测 |
| R-16 | 监听误用系统默认输出，接管后被送到虚拟声卡 | 中/高 | 监听设备解析排除虚拟；显式绑定物理设备；AC-33 | 待实测 |
| R-17 | 极简 UI 隐藏权限/诊断，用户不知道失败原因 | 中/中 | 状态行给一句中文原因；高级区保留全部详情；AC-35/36 | 待实测 |

---

## 14. 待总调度裁决的问题

| ID | 问题 | 产品建议 | 影响 | 需要谁 |
|---|---|---|---|---|
| D-003 | 是否确认 AEC 默认关闭 + 高级可开 Apple VPIO，不引入 AEC3？ | 确认。AEC3 当前不可构建；默认关闭；开启 VPIO 后只写“可能降低回声” | 技术方案、UI 文案、G5 | 总调度 |
| D-004 | 默认输出接管策略？ | **已被 2026-11-07 极简模式决策覆盖**：开启“录制对方声音”时自动接管，不弹确认框；关闭时不接管 | 交互、权限、崩溃恢复 | 总调度 |
| D-005 | 8ch 取声道是否按标签 FL/FR？ | 确认；标签不可用才回退 0/1，并写 `channel_map_assumed`；自检验证 | 音频质量、诊断 | 总调度 |
| D-006 | V1 是否采用极简主界面？ | **已确认**：两个开关 + 一个主按钮 + 状态/结果/同意提示；其余进高级折叠区 | UI/交互/验收 | 总调度 |
| Q-001 | “仅音频”降级是否纳入 P0？ | 建议纳入；屏幕权限拒绝很常见，音频仍有价值 | 范围、状态机、导出 | 总调度 |
| Q-002 | 是否默认保留 `remote.wav`/`microphone.wav`？ | 确认默认保留；这是“录制阶段不混音”的源轨，也是恢复导出的基础 | 存储、导出 | 总调度 |
| Q-003 | FFmpeg 缺失时是否允许无 MP4/MKV 录制？ | P0 阻止并提示安装；不提供“只录中间文件”的普通用户模式 | 安装门槛、体验 | 总调度 |
| Q-004 | 8ch 原始 WAV 是否默认开启？ | 否；失败时保存 1 秒自检 8ch 即可 | 存储、诊断 | 总调度 |
| Q-005 | FL 有信号/FR 静音时是否默认复制到双声道？ | 否；保留原样，P1 开关 | 听感、真实性 | 总调度 |
| Q-006 | 最低系统是否保持 macOS 15？ | 保持项目现状 15.0；只在 26.5.2 真机验收，其他版本标“未验证” | 兼容性 | 总调度 |
| Q-007 | 验证徽章移除标准？ | 5 分钟 + 15 分钟真人通话；MP4 默认播放双方声音；MKV 三音轨；同步；无持续回声；总调度签字 | 发布文案 | 总调度 + 用户 |
| Q-008 | 是否允许“仅画面、无声音”模式？ | P2；P0 不做，避免产生无价值文件 | 范围 | 总调度 |
| Q-009 | 录制中睡眠是阻止还是允许后收尾？ | P0 用 `beginActivity` 阻止空闲睡眠；合盖睡眠无法阻止，唤醒后收尾并警告 | 稳定性 | 总调度 |
| Q-010 | 监听默认开启是否合适？ | 开启“录制对方声音”时自动开启；关闭该开关时不监听；主界面不提供开关 | 体验 | 总调度 |
| Q-011 | Mix 默认增益与限幅参数？ | Remote=1.0、Mic=1.0、limiter=0.95；以 440/880 测试和真人听感为准 | 混音质量 | 总调度 |
| Q-012 | MP4 失败但 MKV 可用时算完成还是失败？ | 建议 `finished` 降级并明确“MP4 缺失”，不丢弃可用素材 | 状态/UI | 总调度 |

---

## 15. 交接清单

- [x] Scope：P0/P1/P2 与 Non-goals 已列明。
- [x] 用户画像与 3 个核心场景已列明。
- [x] 主流程、异常流程、完整状态机已列明。
- [x] 权限引导与拒绝降级已列明。
- [x] 默认输出接管、崩溃恢复、失败提示已列明。
- [x] 中文文案清单已列明。
- [x] 可测验收标准含前置、步骤、期望、证据。
- [x] 风险声明含“FaceTime 真人通话未验证前不得宣称支持”。
- [x] 双产物 MP4/MKV、录制阶段不混音、监听物理输出、440/880 双音验收已列明。
- [x] V1 极简主界面（两个开关 + 一个按钮 + 状态/结果/同意提示）已列明；复杂设置移入高级折叠区。
- [ ] 总调度确认 D-003/D-004/D-005/D-006 与 Q-001~Q-012。
- [ ] UI Agent 输出 `ui/UI_SPEC.md` 与可实现的 SwiftUI 结构。
- [ ] Dev Agent 输出模块骨架与可构建的最小闭环。
- [ ] QA Agent 输出 `qa/TEST_PLAN.md` 与离线单测。

---

## 16. 变更记录

| 版本 | 日期 | 变更 | 作者 |
|---|---|---|---|
| 1.0 | 2026-11-07 | 首版：基于 G0 审计收敛 P0/P1/P2、状态机、权限、接管、验收与风险 | 产品 Agent |
| 1.1 | 2026-11-07 | 增加 MP4（Mix）主交付 + MKV（Mix/Remote/Mic）归档；录制源轨 WAV；监听物理输出；440/880 验收 | 产品 Agent |
| 1.2 | 2026-11-07 | V1 极简主界面：两个开关 + 一个按钮 + 状态/结果/同意提示；自动接管/固定物理监听/FaceTime 窗口；高级折叠 | 产品 Agent |
