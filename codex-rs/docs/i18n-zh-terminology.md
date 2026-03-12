# Codex 汉化术语统一表

| 英文术语 | 统一中文 | 说明 |
|---|---|---|
| session | 会话 | 指完整对话上下文 |
| thread | 线程 | 多代理或分叉后的执行单元 |
| fork | 分叉 | 基于已有会话创建新线程 |
| resume | 恢复 | 继续已有会话 |
| sandbox | 沙箱 | 受限执行环境 |
| approval policy | 审批策略 | 命令执行审批规则 |
| sandbox policy | 沙箱策略 | 文件/网络访问限制策略 |
| feature flag / feature | 功能开关 / 功能 | 按上下文选择其一，避免“特性”混用 |
| profile | 配置档 | 用户可切换的配置集合 |
| model | 模型 | LLM 型号标识 |
| reasoning effort | 推理强度 | 模型推理开销级别 |
| Fast mode | 快速模式 | service tier 开关 |
| realtime | 实时 | 音频设备与实时会话场景 |
| skill | 技能 | SKILL.md 定义的能力模块 |
| app / connector | 应用 | 外部应用连接项 |
| status line | 状态栏 | TUI 底部状态信息 |
| external editor | 外部编辑器 | 由 `$VISUAL`/`$EDITOR` 指定 |

## 约定

- 面向用户的提示文案统一使用简体中文。
- telemetry key、配置键名、协议字段、日志埋点保持英文原样，不做翻译。
- 命令、路径、环境变量名（如 `CODEX_HOME`）保持原样。
