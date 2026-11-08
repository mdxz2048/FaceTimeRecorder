# FaceTime Recorder — Agent 协作章程

版本：1.0 · 生效：2026-11-07 · 维护者：总调度

## 1. 目标

交付一个**独立**的 macOS App：录制 FaceTime 视频、远端音频（HomePod Flow 虚拟声卡）、本地麦克风，实时监听，双音轨封装。复用已安装的 HomePod Flow 虚拟声卡，**不修改**其驱动与仓库。

## 2. 角色与边界

| 角色 | 负责 | 唯一写入范围 | 不负责 |
|---|---|---|---|
| 总调度（Coordinator） | 需求收敛、派工、集成、真机验收、Git、发布判断、STATUS 维护 | `docs/agents/STATUS.md`、`docs/agents/decisions/**`、仓库根配置、最终集成 | 不替产品改需求，不替 QA 伪造结论 |
| 产品 Agent（Product） | 功能逻辑、用户流程、范围裁剪、验收口径、技术方案与风险 | `docs/agents/product/**` | 不写 UI 代码，不写实现代码 |
| UI Agent（UI） | 信息架构、界面布局、交互状态、视觉规范、可实现的 SwiftUI 结构 | `docs/agents/ui/**`、`Sources/App/UI/**`（仅视图文件） | 不改音频/视频核心，不改产品范围 |
| 开发 Agent（Dev） | Swift/SwiftUI 实现、Core Audio/ScreenCaptureKit/AVFoundation、构建修复 | `Sources/App/**`（UI 目录除外）、`Sources/Core/**` 新增文件、`Scripts/**` | 不改产品文档，不改测试断言，不装机 |
| 测试 Agent（QA） | 测试计划、离线单测、真机脚本、证据归档、缺陷单 | `Tests/**`、`tests/**`、`docs/agents/qa/**` | 不修产品代码（只提交可复现缺陷），不改验收口径 |

## 3. 交接规则

1. **文档即事实**。任何口头结论必须落到本目录文件；未落盘的结论视为不存在。
2. 上游交付物必须包含：`Scope`、`Non-goals`、`Acceptance`、`Open questions`、`Handoff checklist`。
3. 下游只能在交接文档齐全后开工；发现缺口先在 `docs/agents/STATUS.md` 登记 `BLOCKED`，由总调度裁决。
4. 任何 agent 不得声称“已验证”，除非给出：命令、时间、退出码、原始日志/报告路径、人工听感记录（如适用）。
5. 真机安装、默认输出切换、驱动改动、系统权限授权只能由总调度执行；其他 agent 可读、可测，但不得改系统状态。
6. 代码冲突：总调度为最终合并者。并行任务必须文件集不相交。

## 4. 阶段门

| Gate | 内容 | 通过条件 |
|---|---|---|
| G0 | 现状审计 | 设备枚举、驱动能力、Loopback 结论、TCC 行为有证据 |
| G1 | 远端采集 | 浏览器/系统音来自虚拟设备，AudioProbe 产出非零 WAV；FaceTime 真人通话另验 |
| G2 | 监听 | 能听到远端，录音与监听互不影响，30 分钟稳定 |
| G3 | 双轨 | 远端 + 麦克风独立轨道，时间戳与丢帧可诊断 |
| G4 | 视频 | ScreenCaptureKit 画面 + 双音轨 MKV 可播放 |
| G5 | 回声 | 监听开启时本地麦克风不把对方声音录回去 |
| G6 | 发布候选 | 15 分钟通话端到端、崩溃恢复、权限拒绝路径、文档齐全 |

**在 FaceTime 真人通话未验证前，任何文档与 UI 只能写“待验证”，不得写“支持 FaceTime 音频录制”。**

## 5. 当前技术事实（G0）

- 系统：macOS 26.5.2 (25F84)，arm64，Xcode 26.6。
- 已安装虚拟设备：`HomePod Flow Audio`，UID `com.homepodflow.virtual-audio.surround71.v1`，传输类型 Virtual。
- 能力：**仅输出**，8ch，48 kHz，Float32 packed interleaved，1 个输出 stream；**0 个输入 stream、0 个输入通道**。
- 驱动 `WriteMix` 为纯 sink，不保留 PCM、不提供共享缓冲、不向客户端提供时间戳；多个客户端由 running 引用计数管理。
- 结论：**没有 Loopback 输入**。采集必须走 Core Audio device tap（`CATapDescription(andDeviceUID:)` + 私有 aggregate）。
- TCC：在 sshd 启动的进程里，tap 的 IOProc 正常回调（约 100 次/秒、帧数正常），但**所有样本严格为 0**；历史证据显示在已授权的 GUI 进程中同一路径可得到非零 PCM。故“启动成功”不等于“采集成功”，必须做非静音自检。
- 系统默认输出当前为 `BuiltInSpeakerDevice`。FaceTime 走系统默认输出，因此需要可逆的默认输出接管与恢复。
- WebRTC AEC3 在本机没有可用的 Homebrew 包；不得引入无法构建的依赖。AEC 以可插拔接口实现，默认 Apple VoiceProcessingIO，并在文档中标注与 AEC3 的差异。

## 6. 交付物

```
FaceTimeRecorder/
  docs/agents/**            协作与交接文档
  Sources/CRing/**          C SPSC ring
  Sources/Core/**           设备、采集、监听、录制、封装
  Sources/Probe/**          AudioProbe CLI
  Sources/App/**            SwiftUI App
  Tests/CoreTests/**        离线单测
  tests/**                  真机脚本与证据
  Scripts/**                构建、打包、验收
```
