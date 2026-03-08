verdict: REQUEST_CHANGES
issues:
  - severity: high
    file: codex-rs/README.md:7
    description: >-
      子目录 README 仍把当前仓库的安装入口指向上游 `@openai/codex` 与
      `openai/codex` Releases（`codex-rs/README.md:7-15`），而仓库根 README
      已明确把用户导向本 fork 的 `stellarlinkco/codex` 安装脚本（`README.md:21-37`）。
      这不是普通文案分叉；按 `codex-rs/README.md` 安装拿到的是上游二进制，随后再去遵循
      本仓库的 GitHub webhook/overlay 文档，会直接落到“文档与实际安装产物不兼容”的状态。
    fix: >-
      把 `codex-rs/README.md` 的安装说明与仓库根 README 对齐：同一仓库、同一发行源、同一
      binary 获取路径；若确实要同时支持上游与 fork，必须显式区分“当前仓库构建/发行物”和
      “上游官方包”，不要再把两者写成同一个默认入口。
  - severity: medium
    file: codex-rs/docs/github-webhook.md:48
    description: >-
      webhook 运行文档把 `[github_webhook]` 示例放在“非敏感默认值可以写进 `config.toml`”
      语境下，并给出 `min_permission = "read"`（`codex-rs/docs/github-webhook.md:38-65`）；
      `docs/config.md:114-149` 也复用了同一组“默认值”示例。但运行时代码在未显式配置时实际回落到
      `MinPermission::Triage`（`codex-rs/cli/src/github_cmd.rs:788-793`）。这会把一个安全敏感的
      默认门槛写错：读文档的人会以为默认是 `read`，而真实行为是 `triage`。
    fix: >-
      要么把两处文档明确改成“示例配置”并去掉默认语义，要么直接把示例中的
      `min_permission` 改成真实默认 `triage`，同时在同段显式写清 CLI > config > built-in default
      的优先级和真实内置值。
  - severity: high
    file: harness-tasks.json:38
    description: >-
      这组 webhook/config/doc 变更在仓库现状里并没有完成验证闭环。`task-002`
      明确失败，原因是 schema 精确校验在恢复过程中被中断且无法安全重试
      （`harness-tasks.json:38-87`）；其后的 `task-003` 到 `task-006` 全部因为依赖 `task-002`
      失败而阻塞（`harness-tasks.json:89-193`）。也就是说，`AGENTS.md:163-166` 指向的稳定
      当前契约虽然和 `docs/github-outcome-first-overlay.md:5-17`、
      `codex-rs/docs/github-webhook.md:128-140` 在语义上大体一致，但当前工作树没有通过最起码的
      schema / CLI / 回归验证，不能算 merge-ready。
    fix: >-
      先补齐被阻塞的验证链：至少重新完成 `cargo test -p codex-core
      config_schema_matches_fixture -- --exact` 与 `cargo test -p codex-cli github_cmd`，确认
      文档声称的配置模型、事件面和认证路径都有可重复的测试信号，再谈合并。
risks:
  - >-
    security: `min_permission` 文档把默认门槛写成 `read`，而代码默认是 `triage`。运维若照抄示例，
    会把触发 webhook 自动执行的权限面放宽到比真实默认更低的等级。
  - >-
    correctness: `README.md:21-37` 与 `codex-rs/README.md:7-15` 指向不同发行源；用户按子目录
    README 安装上游包后，再遵循本 fork 文档，得到的行为不再由当前仓库保证。
  - >-
    performance: 审阅到的 overlay / native webhook 语义本身没有新增明显性能矛盾；真正的风险是
    `harness-tasks.json:169-193` 显示完整回归根本没跑完，扩展后的事件面与清理逻辑缺少已完成的
    回归信号。
merge_ready: false
