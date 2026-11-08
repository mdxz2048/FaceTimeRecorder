# 项目状态板（唯一进度源）

更新：2026-11-08 · 维护：总调度

## 2026-11-08 最新收敛（覆盖下方旧记录）

| 项 | 结论 |
|---|---|
| 远端声音方案 | **avconferenced 进程 tap**（`ProcessTapCapture`），已实测非零；不依赖虚拟声卡 loopback，不改 HomePod Flow 驱动 |
| 对方声音播放 | 不接管系统输出；FaceTime 仍走 Mac 扬声器，tap 只旁路读取，因此“边录边听”成立 |
| 视频 | ScreenCaptureKit 抓 FaceTime 窗口，Retina 2×，H.264 |
| 麦克风 | HAL 直采，3ch→mono→48k stereo；音量偏小的问题待接入后处理链（已离线验证参数） |
| 界面 | **252×58 极简小窗**：`对方声音 ☑` `麦克风 ☑` + 状态灯/计时 + `录制 / 暂停 / 继续 / 停止`；无高级设置、无卡片 |
| 新增能力 | 暂停/继续：视频帧丢弃并按暂停时长回拉 PTS，两条 WAV 同步停写，监听与 tap 不停，保证继续后可听可说 |
| 进行中 | 麦克风后处理入 App、MP4 三音轨默认轨设置、侧车 M4A、Logo 出图 |

## 当前阶段

`G0 完成 → G1 系统/tap 链路已通 → 等待 FaceTime 真人通话 → G2 监听验证中`

## 角色状态

| Agent | 任务 | 状态 | 交付物 | 备注 |
|---|---|---|---|---|
| 总调度 | 核心层、AudioProbe、真机验收 | 进行中 | `Sources/Core/**`、`Sources/Probe/**`、本文件 | 已完成 tap→监听→混音封装链路 |
| 产品 | PRD + 技术方案 | ✅ 完成，待按新目标修订 | `product/PRD.md`、`TECH_PLAN.md`、`HANDOFF.md` | 需补“导出混音轨”目标 |
| UI | 界面与交互规范 | 进行中 | `ui/UI_SPEC.md` | 已产出 23KB 规范 |
| 开发 | Recorder App 实现 | 进行中 | `Sources/App/**` | 正在写 SwiftUI 外壳 |
| 测试 | 测试计划与离线单测 | 进行中 | `qa/**`、`Tests/**` | 待产出 |

## 门禁

| Gate | 状态 | 证据 |
|---|---|---|
| G0 审计 | ✅ 完成 | `docs/audit/G0_AUDIT.md`、AudioProbe 枚举输出 |
| G1 远端采集 | 🟡 系统链路通过，FaceTime 待验 | GUI 授权下 tap→WAV 非零：`artifacts/G1-2026-11-07/fr-tcc.wav` |
| G1.5 混音导出 | ✅ 通过（合成音） | `artifacts/G1-2026-11-07/monitor-mix/`：MKV Mix+Remote、MP4 Mix |
| G2 监听 | 🟡 数据面通过，听感待验 | 6 s 会话监听 underrun 8 帧、overflow 0；输出为 MacBook Pro 扬声器 |
| G3 双轨 | ⬜ 未开始 | — |
| G4 视频/封装 | ⬜ 未开始 | — |
| G5 回声 | ⬜ 未开始 | — |
| G6 发布候选 | ⬜ 未开始 | — |

## 阻塞与决策

| 编号 | 事项 | 状态 | 决策 |
|---|---|---|---|
| D-001 | 现有声卡无 Loopback 输入 | 关闭 | 不改驱动；使用 device tap |
| D-002 | Tap 在无 TCC 时返回全零而非报错 | 关闭 | 产品必须内置非静音自检并明确报错 |
| D-003 | WebRTC AEC3 无可构建依赖 | 待产品确认 | 默认 Apple VPIO，保留 AEC 接口；文档标注差异 |
| D-004 | 是否自动接管系统默认输出 | 待产品确认 | 默认关闭，用户显式开启，停止/退出恢复 |
| D-005 | 8ch 取声道 | 关闭 | 设备布局为 FL FR FC LFE BL BR SL SR；取索引 0/1，已用自检音验证 |
| D-006 | 最终交付物形态 | 关闭 | 必须“画面+双方声音可播放”：MP4 主文件为双方混音；MKV 首轨也为混音，另含 Remote/Mic 两独立轨 |
| D-007 | 监听输出 | 关闭 | 监听永远解析到物理输出，禁止选到虚拟声卡本身；接管默认输出后仍从 MacBook 扬声器/耳机出声 |
| D-008 | AEC3 | 待确认 | 本机无 WebRTC AEC3 可构建依赖；默认 Apple VPIO，UI 只写“效果待验证” |

## 最新证据（2026-11-07 18:24）

- 合成 440 Hz 送入虚拟声卡 → tap 捕获 8ch → FL/FR RMS 0.0353；6 s 会话 566 次回调 / 289792 帧，丢块 0。
- 监听：MacBook Pro 扬声器 48 kHz，underrun 8 帧，ring overflow 0。
- 产出：`FaceTime.mkv`（Mix + Remote 两音轨，6.09 s）、`FaceTime.mp4`（Mix，6.06 s）。
- 注意：这是合成音验证，不是 FaceTime 真人通话；不能据此宣称“已支持 FaceTime 音频录制”。

## 2026-11-07 18:55 产品方向调整（总调度决定）

**V1 改为极简 UI**：用户明确要求“界面简单一点，只要选择是不是录对方的声音、或者录麦克风的声音就完了”。

- 主界面只保留：`录制对方声音` 开关、`录制我的麦克风` 开关、`开始录制/停止并保存` 按钮、一行状态、一行结果、底部小字“请确保对方同意录音”。
- 远端设备、麦克风、监听输出、画面源、系统输出接管、AEC 全部自动处理；设备/音量/权限/诊断/日志收进“高级”，默认收起。
- 画面固定录主显示器；开启“录制对方声音”时自动接管系统默认输出并在停止/退出时恢复；监听强制走物理输出且默认开启。
- UI Agent 重写 UI_SPEC/WIREFRAMES；Dev Agent 重写 ContentView；QA 更新验收；产品更新 PRD/TECH_PLAN/HANDOFF。

## 当前技术阻塞（2026-11-07 18:55）

1. **远端链路已验证**：App 内自动会话（无麦克风）得到 298496 帧、RMS 0.0354、583 次回调；MP4/MKV 正常。
2. **VPIO 与 tap 冲突**：启用 Apple VoiceProcessingIO 时远端回调归零。已把启动顺序改为“监听/VPIO 先初始化 → 再接管默认输出 → 再创建 tap”，并把 tap 聚合时钟改为虚拟设备自身（3 秒 302 次回调已验证）。该修复仍需在麦克风授权后用真机复验。
3. **麦克风 TCC**：每次 ad-hoc 重签都会重置麦克风授权；App 在“准备中”等待系统提示。最终构建后需用户授权一次，随后不再重签，才能完成双轨真机验收。
4. **稳定签名**：SSH 会话无法使用 Apple Development 私钥（`errSecInternalComponent`）。计划用独立自签名代码签名证书固定 designated requirement，使 TCC 跨重建保留；在完成前不宣称双轨已通过。

## 2026-11-07 19:07 极简版构建与最新真机结果

- 极简 UI 已构建并启动：单窗口 520×420，两个开关（录制对方声音 / 录制我的麦克风）+ 一个开始/停止按钮；设备、音量、AEC、权限、诊断、日志收进默认收起的“高级”。
- App 内自动会话（仅远端，合成 440 Hz）：`304640` 帧 / `595` 次回调 / FL FR RMS `0.0354`；MP4 默认音轨可测得 440 Hz；监听输出为 `MacBook Pro扬声器`，ring overflow 0。
- 视频自动会话被系统阻止：`屏幕录制权限未授予`。已打开“麦克风”和“屏幕与系统音频录制”隐私面板，等待用户为最终构建授权。
- 因 VPIO 在本机曾使 tap 回调归零，V1 默认关闭 AEC（高级中可开）；在真人通话验证前不宣称回声已消除。
- 最终构建后不再重签；用户授权麦克风 + 屏幕录制并重启 App 后，执行 1 分钟 FaceTime 真人测试（G1/G2/G3/G4 合并验收）。

## 2026-11-08 远端音频突破（正式方案）

- **process tap on `avconferenced` 已实测成功**：`remote.wav` 468,992 帧，RMS 0.012，峰值 0.375；MP4/MKV 均生成。
- 关键修正：Unix PID 必须先经 `kAudioHardwarePropertyTranslatePIDToProcessObject` 转为 Core Audio process object；直接传 PID 会得到 `!obj`。
- 虚拟声卡 device tap 与 ScreenCaptureKit 系统音频均无法稳定拿到 FaceTime 对方声音；虚拟声卡保留为兼容/诊断路径。
- 正式方案文档：`docs/agents/product/REMOTE_AUDIO_ARCHITECTURE.md`。
- 当前已知问题：麦克风 3ch 仅取 ch0，RMS 偏低（0.00117 / peak 0.037），计划 3ch→单声道 + 软件增益 +12dB + limiter。

## 交接记录

| 日期 | 从 | 到 | 文档 | 内容 |
|---|---|---|---|---|
| 2026-11-07 | 总调度 | 产品 | `product/INPUT_BRIEF.md` | 需求、审计事实、约束、待决策 |
