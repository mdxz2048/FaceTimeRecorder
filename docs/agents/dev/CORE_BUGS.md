# Core 缺陷与对接限制（Dev Agent）

日期：2026-11-07  
范围：仅记录开发 Agent 实现 SwiftUI App 外壳时发现的问题；**未修改 `Sources/Core/**`**。  
处理方式：App 层可规避的已规避；不能规避的在此登记，等待总调度裁决。

| 编号 | 严重度 | 位置 | 问题 | App 当前规避 |
|---|---|---|---|---|
| C-01 | 高 | `RecorderEngine.swift:432` `validate(_:)` | Core 只校验远端设备存在且有输出通道，不校验系统默认输出是否等于该设备。若调用方未自行检查，`start()` 可能在 FaceTime 声音没进入 tap 的情况下“成功”开始。 | `RecorderViewModel.startBlockReason` 在开始前检查 `defaultOutputUID == remoteDeviceUID`，除非用户开启接管；不满足则拒绝开始并提供“开启接管/打开声音设置”。 |
| C-02 | 中 | `RecorderEngine.swift:218`、`:507` | 启动失败只写 `session-error.log`（纯文本），不写产品要求的 `diagnostics.json` 结构化诊断。 | App 把 `session-error.log` 作为诊断路径展示，另写 `app-events.log`（App 事件环形缓冲）到会话目录。 |
| C-03 | 中 | `RecorderEngine.swift:404` | Core 自检只要求 `peak > 0.0005`，没有帧数下限，也不检查 FL/FR RMS 阈值；少量噪声也可能被判为 passed。 | App 用更严格的 `SelfTestEvaluator`：`frames >= 24000` 且 FL/FR 最大 RMS `>= 0.005`；通过后才调用 `engine.start(performSelfTest: false)`，避免重复播放 1 kHz 测试音。 |
| C-04 | 中 | `TrackRecorder.swift:85`、`:97`、`:287`、`:296` | `remoteRMS` / `micRMS` 是“会话开始至今的累计平均”，不是滑动窗口瞬时值；Peak 是会话峰值保持。因此电平条对静音/语音起伏反应迟钝，10 秒静音告警可能被早期声音拖住。 | UI 明确标注“累计 RMS”，不伪造瞬时波形；远端连续无电平 10 秒提示仍可用，但可能延迟。 |
| C-05 | 低 | `RecorderEngine.swift:328` | `snapshot.elapsed` 在停止后继续增长，因为 `startedAt` 不清空。 | App 在点击停止时冻结 `frozenElapsed`，停止/封装阶段显示冻结时长，完成后用 `RecordingResult.durationSeconds`。 |
| C-06 | 中 | `RecorderEngine.swift:309` | `stop()` 无论 MP4/MKV 是否生成，都把状态置为 `.finished`。两个主文件都失败时，调用方容易误判成功。 | App 检查 `mp4URL == nil && mkvURL == nil`，把结果降级为 `.failed`，保留 WAV/MOV 素材并在失败页展示路径。 |
| C-07 | 低 | `RecorderEngine.swift:167` | 当 `monitorEnabled == true` 且调用方传入了 `microphoneUID` 时，即使 `recordMicrophone == false`，`MonitorEngine` 仍会配置麦克风并开启输入 tap/VPIO。 | App 在 `makeConfiguration()` 中把 `microphoneUID` 置 nil（当麦克风轨关闭或权限未授权），避免多余采集。 |
| C-08 | 低 | `RecorderEngine.swift:7` `LiveSnapshot` | `LiveSnapshot` 不包含 Core 最终解析到的监听输出 UID/名称（`MonitorStatus.outputDeviceName` 只在 Core 内部）。 | App 用与 Core 相同的规则预先解析物理监听设备，显示“实际监听”；若运行中 Core 回退到别的设备，App 文案可能短暂不一致。 |
| C-09 | 低 | `RecorderEngine.swift:507` | 若启动在创建会话目录之前失败（如 `validate` 失败），Core 没有可写的诊断目录，`writeFailureLog` 直接返回。 | App 写 `~/Library/Application Support/FaceTime Recorder/last-failure.log` 并展示该路径。 |
| C-10 | 行为变更 | `RecorderEngine.swift:194-208` | Core 已改为“1.5 秒内没有远端音频块也继续录制”，只写 warning；这与 PRD“远端缺失时阻止开始”不同，但看起来是总调度为等待 FaceTime 通话而做的有意变更。 | App 用自检 + 路由检查做硬门槛；录制中连续约 10 秒远端无电平时提示用户，但不自动停止。**需总调度确认这是最终产品行为。** |
| C-11 | 已关闭 | `RecorderConfiguration.recordRemote` | Core 已新增 `recordRemote`：关闭时不创建 device tap、不写 remote 轨、不接管默认输出。 | App 的“录制对方声音”直接映射到 `recordRemote`；关闭时允许仅有麦克风的录制。 |
| C-12 | 中 | `RecorderEngine.swift:485` `validate()` | Core 的启动逻辑已支持“FaceTime 窗口优先、主显示器兜底”，但 `validate()` 仍要求 `recordVideo && recordRemote` 时 `captureDisplayID` 或 `captureWindowID` 至少一个非 nil，二者都 nil 会直接抛 `invalidConfiguration`。这与“让 Core 自动查找 FaceTime 窗口”冲突。 | App 在 remote 开启且录制视频时传入 `captureDisplayID = CGMainDisplayID()` 作为兜底，`captureWindowID = nil`；Core 仍会先尝试 `ScreenRecorder.faceTimeWindowID()`，只有找不到 FaceTime 窗口时才用主显示器。remote 关闭时二者都传 nil。建议 Core 放宽 validate 允许自动模式。 |

## 备注

1. App 的开始流程是：先执行 Core 的 `runSelfTest(deviceUID:seconds:1.0)`，用 App 侧更严格阈值判定；通过后再 `start(performSelfTest: false)`。这样仍满足“1 秒 1 kHz 低电平自检”，且不会重复两次测试音。
2. 如果总调度希望 Core 成为唯一自检门禁，应把 C-03 的阈值并入 Core；App 再把 `performSelfTest` 改回 `true`。
3. “退出时自动停止并恢复默认输出”已通过 `AppDelegate.applicationShouldTerminate` 实现（无确认弹窗）；单实例仍未实现。若在 `.preparing` 阶段退出，Core 的同步 `start()` 无法安全取消，可能留下部分素材，依赖 lease/下次启动恢复。
