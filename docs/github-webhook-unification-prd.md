# Historical PRD: GitHub Webhook Unification

**Version**: 1.0  
**Date**: 2026-03-07  
**Author**: Product Owner (via prd-compiler skill)  
**Quality Score**: 92/100  
**Status**: Superseded historical PRD

> Historical note: this PRD is preserved as design history, not as the current product contract.
> Current implementation and docs already cover six events; treat older present-tense statements, open questions,
> and outdated defaults in this file as superseded by `codex-rs/docs/github-webhook.md` and `docs/config.md`.

---

## Executive Summary

`codex github` 在本 PRD 起草后已经扩展到 `issue_comment`、`issues`、`pull_request`、`pull_request_review`、`pull_request_review_comment`、`push` 六类事件，但这里保留了当时统一 webhook 配置与认证模型的设计背景。

核心价值:

- 支持更多触发场景 (issue 开/关、PR 状态变化、push 事件)
- 提供 GitHub App 原生支持 (JWT + installation token)
- 敏感值不落盘,配置层只保存环境变量名称
- CLI 参数覆盖 config 默认值,保持现有运维灵活性

---

## Historical Problem Statement

**起草时的状况**:

- 事件面已扩展,但本文档关注的统一配置、认证和事件归一化问题仍然存在
- 起草时 webhook 来源支持与认证入口还未统一,对 organization webhook 和 GitHub App webhook 的合同也不清晰
- 起草时配置分散在环境变量和 CLI 参数,缺少统一的配置模型
- 起草时 GitHub App 模式仍被视为需要手工 JWT 签名和 installation token 管理
- 起草时敏感值(secret/token/private key)主要靠环境变量管理,缺少统一的配置层合同

**期望结果**:

- 支持 6+ 核心 GitHub 事件,覆盖评论、状态变化、代码提交
- 明确支持 repo webhook、org webhook、GitHub App webhook
- 新增顶层 `[github_webhook]` 配置段,统一管理默认值、环境变量名称、权限策略
- GitHub App 模式下自动处理 JWT 签名和 installation token 获取
- 敏感值通过环境变量提供,配置里只保存 env 名称和非敏感默认值
- 保持向后兼容:现有 `GITHUB_WEBHOOK_SECRET`、`GITHUB_TOKEN` 环境变量继续有效

**为何现在做**:

- 用户已明确需要 issue 自动化和 PR 状态触发
- GitHub App 是组织级部署的推荐模式,当前缺失会阻碍大规模采用
- 配置模型缺失导致文档和默认值管理混乱

---

## Goals

- 扩展支持事件至: `issue_comment`、`issues`、`pull_request`、`pull_request_review`、`pull_request_review_comment`、`push`
- 明确支持三种 webhook 来源: repo webhook、organization webhook、GitHub App webhook
- 新增 `[github_webhook]` 顶层配置段,包含:
  - 默认环境变量名称 (webhook_secret_env、github_token_env、github_app_id_env 等)
  - 默认命令前缀 (command_prefix)
  - 默认权限策略 (min_permission)
  - 默认 TTL 配置 (delivery_ttl_days、repo_ttl_days)
  - allowlist 默认值 (allow_repos)
- GitHub App 模式支持:
  - 从环境变量读取 `GITHUB_APP_ID`、`GITHUB_APP_PRIVATE_KEY`
  - 自动生成 JWT token
  - 从 webhook payload 提取 `installation.id` 并动态获取 installation token
- CLI 参数覆盖 config 默认值,保持现有运维习惯
- 保持向后兼容:未配置 `[github_webhook]` 时,行为与当前版本完全一致

## Non-Goals

- **不支持 profile 级配置**: webhook 配置仅在顶层 `[github_webhook]`,不引入 profile 复杂度
- **不主动推送状态到 GitHub**: 仅接收 webhook 并执行本地任务,不实现 commit status / check run API
- **不支持多 GitHub App 实例**: 单进程仅支持一套 GitHub App 凭证
- **不迁移现有环境变量约定**: `GITHUB_WEBHOOK_SECRET`、`GITHUB_TOKEN` 继续作为默认值,不强制重命名
- **不修改 webhook payload 校验逻辑**: 现有 HMAC-SHA256 校验保持不变

---

## Confirmed Facts, Assumptions, and Open Questions

### Confirmed Facts

- 当前已支持 `issue_comment`、`issues`、`pull_request`、`pull_request_review`、`pull_request_review_comment`、`push`
- 当前环境变量: `GITHUB_WEBHOOK_SECRET` (webhook secret)、`GITHUB_TOKEN` (GitHub API token)
- 当前 CLI 参数: `--listen`、`--allow-repo`、`--min-permission`、`--command-prefix`、`--delivery-ttl-days`、`--repo-ttl-days`
- 代码路径: `codex-rs/cli/src/github_cmd.rs`
- 现有文档: `codex-rs/docs/github-webhook.md`、`docs/config.md`
- 配置模型: `codex-rs/core/src/config/mod.rs`、`ConfigToml` 结构

### Working Assumptions

- GitHub App private key 通过 `GITHUB_APP_PRIVATE_KEY` 环境变量提供 (PEM 格式字符串或 base64 编码)
- GitHub App ID 通过 `GITHUB_APP_ID` 环境变量提供 (整数)
- installation token 有效期足够短 (1 小时),每次 webhook 触发时重新获取即可
- `push` 事件的 work item 对应 commit SHA,复用现有 repo cache 机制
- 新事件的 work item 解析逻辑可以在 `handle_webhook -> parse_work_item` 边界增加归一化层
- 新增的 `issues`、`pull_request`、`push` 事件仅在 payload 正文或 head commit message 以配置的命令前缀开头时才触发,不引入无提示自动执行

### Historical Open Questions (resolved later)

- `issues` 事件中,哪些 action 需要触发 work item? (opened / edited / closed / reopened / labeled 等)
- `pull_request` 事件中,哪些 action 需要触发 work item? (opened / synchronize / closed / reopened 等)
- `push` 事件是否需要 allowlist 逻辑防止意外大量触发?
- GitHub App 模式下,是否需要验证 installation 是否覆盖目标 repo?

---

## Users and Primary Jobs

### Primary User

- **角色**: DevOps / Platform Engineer
- **目标**: 部署 `codex github` 作为常驻服务,响应 GitHub 事件自动执行本地任务
- **痛点**: 原始实现曾只覆盖评论类事件,难以自动化 issue 状态变化、PR merge、代码提交等场景

### Secondary User

- **角色**: GitHub App 开发者
- **目标**: 使用 GitHub App 模式部署到多个组织,避免手工管理 personal access token
- **痛点**: 当前必须手工生成 JWT 和 installation token,运维复杂度高

---

## User Stories & Acceptance Criteria

### Story 1: 支持 `issues` 事件

**As a** DevOps engineer  
**I want to** 在 issue 被打开、编辑或重新打开时自动触发 Codex 任务  
**So that** 可以实现自动化分类、标签、通知等流程

**Acceptance Criteria:**

- [ ] webhook 收到 `issues` 事件时,根据 `action` 字段决定是否创建 work item
- [ ] 支持的 action 至少包含: `opened`、`edited`、`reopened`
- [ ] 仅当 issue body 以配置的命令前缀开头时才创建 work item
- [ ] work item 包含 issue number、title、body、sender
- [ ] 生成的 worktree 路径为 `~/.codex/github-repos/<owner>/<repo>/issues/<number>`
- [ ] 错误处理:未知 action 不创建 work item,记录日志

### Story 2: 支持 `pull_request` 事件

**As a** DevOps engineer  
**I want to** 在 PR 被打开、编辑、重新打开或同步(新 commit push)时自动触发 Codex 任务  
**So that** 可以实现 PR 自动化 review、测试、merge 流程

**Acceptance Criteria:**

- [ ] webhook 收到 `pull_request` 事件时,根据 `action` 字段决定是否创建 work item
- [ ] 支持的 action 至少包含: `opened`、`edited`、`reopened`、`synchronize`
- [ ] 仅当 PR body 以配置的命令前缀开头时才创建 work item
- [ ] work item 包含 PR number、title、head SHA、base branch、sender
- [ ] 生成的 worktree 路径为 `~/.codex/github-repos/<owner>/<repo>/pulls/<number>`
- [ ] 错误处理:未知 action 不创建 work item,记录日志

### Story 3: 支持 `push` 事件

**As a** DevOps engineer  
**I want to** 在代码 push 到特定分支时自动触发 Codex  
**So that** 可以实现 CI/CD 集成、自动化测试、部署流程

**Acceptance Criteria:**

- [ ] webhook 收到 `push` 事件时,提取 `ref`、`after` (commit SHA)、`commits` 列表
- [ ] 仅当 head commit message 以配置的命令前缀开头时才创建 work item
- [ ] work item 包含 ref、commit SHA、pusher、commit message
- [ ] 生成的 worktree 路径为 `~/.codex/github-repos/<owner>/<repo>/pushes/<hash>`
- [ ] 边缘情况:如果 `after` 为全零 SHA (删除分支),不创建 work item
- [ ] 错误处理:如果 commit SHA 不存在,记录错误并跳过

### Story 4: 新增 `[github_webhook]` 配置

**As a** platform engineer  
**I want to** 在 `config.toml` 中配置 GitHub webhook 的默认行为  
**So that** 可以统一管理默认值,避免每次启动都传递大量 CLI 参数

**Acceptance Criteria:**

- [ ] `ConfigToml` 新增 `github_webhook` 字段,类型为 `Option<GitHubWebhookToml>`
- [ ] `GitHubWebhookToml` 包含以下字段:
  - `webhook_secret_env: Option<String>` (默认 `GITHUB_WEBHOOK_SECRET`)
  - `github_token_env: Option<String>` (默认 `GITHUB_TOKEN`)
  - `github_app_id_env: Option<String>` (默认 `GITHUB_APP_ID`)
  - `github_app_private_key_env: Option<String>` (默认 `GITHUB_APP_PRIVATE_KEY`)
  - `command_prefix: Option<String>` (默认 `/codex`)
  - `min_permission: Option<String>` (默认 `triage`)
  - `delivery_ttl_days: Option<u64>` (默认 `7`)
  - `repo_ttl_days: Option<u64>` (默认 `0`)
  - `allow_repos: Option<Vec<String>>` (默认空,允许所有仓库)
- [ ] CLI 参数继续支持 `--command-prefix`、`--min-permission` 等,覆盖 config 默认值
- [ ] 未配置 `[github_webhook]` 时,行为与当前版本完全一致
- [ ] 运行 `just write-config-schema` 更新 `core/config.schema.json`

### Story 5: GitHub App 认证支持

**As a** GitHub App 开发者  
**I want to** 使用 GitHub App 凭证替代 personal access token  
**So that** 可以部署到多个组织,避免 token 泄漏风险

**Acceptance Criteria:**

- [ ] 从环境变量读取 `GITHUB_APP_ID` (整数) 和 `GITHUB_APP_PRIVATE_KEY` (PEM 格式字符串)
- [ ] 如果两者都存在,自动生成 JWT token (使用 RS256 算法,有效期 10 分钟)
- [ ] 从 webhook payload 的 `installation.id` 字段提取 installation ID
- [ ] 调用 GitHub API `/app/installations/{installation_id}/access_tokens` 获取 installation token
- [ ] installation token 用于后续 GitHub API 调用 (替代 `GITHUB_TOKEN`)
- [ ] 错误处理:如果 JWT 生成失败、installation ID 缺失、或 token 获取失败,记录错误并跳过
- [ ] 向后兼容:如果 `GITHUB_APP_ID` 或 `GITHUB_APP_PRIVATE_KEY` 未设置,继续使用 `GITHUB_TOKEN`

### Story 6: 事件归一化层

**As a** contributor  
**I want to** 在 `handle_webhook -> parse_work_item` 边界增加来源/事件归一化层  
**So that** 可以统一处理不同来源的 webhook payload,降低后续逻辑复杂度

**Acceptance Criteria:**

- [ ] 新增 `WebhookSource` 枚举: `RepoWebhook`、`OrgWebhook`、`GitHubApp`
- [ ] 新增 `parse_webhook_source(headers: &HeaderMap, payload: &Value) -> WebhookSource` 函数
- [ ] 区分逻辑:如果 payload 包含 `installation.id`,判定为 `GitHubApp`;否则优先结合 `X-GitHub-Hook-Installation-Target-Type` 头与 payload 结构区分 `OrgWebhook` 或 `RepoWebhook`
- [ ] `parse_work_item` 接受 `WebhookSource` 参数,根据来源调整解析逻辑
- [ ] 测试覆盖:至少包含 repo webhook、org webhook、GitHub App webhook 三种来源的 payload 样例

---

## Functional Requirements

### Requirement 1: 扩展支持事件

- **描述**: 支持 `issues`、`pull_request`、`push` 事件
- **触发**: webhook 收到 `X-GitHub-Event: issues/pull_request/push`
- **预期结果**: 根据 `action` 与 payload 中显式出现的命令前缀创建 work item,与现有 `issue_comment` 流程保持一致
- **备注**: 每种事件的 action allowlist 在实现时确定,初期保守 (仅支持明确需要的 action)

### Requirement 2: GitHub App 模式支持

- **描述**: 从环境变量读取 GitHub App 凭证,自动生成 JWT 和 installation token
- **触发**: 启动时检测到 `GITHUB_APP_ID` 和 `GITHUB_APP_PRIVATE_KEY` 环境变量
- **预期结果**: webhook 收到 payload 后,提取 `installation.id`,调用 GitHub API 获取 installation token,用于后续 API 调用
- **备注**: installation token 有效期 1 小时,每次 webhook 触发时重新获取

### Requirement 3: 顶层 `[github_webhook]` 配置

- **描述**: 新增 `ConfigToml.github_webhook` 字段,包含默认值和环境变量名称
- **触发**: 启动时加载 `config.toml`
- **预期结果**: CLI 参数优先,config 次之,硬编码默认值最后
- **备注**: 配置里只保存环境变量名称,不保存实际敏感值

### Requirement 4: 向后兼容

- **描述**: 未配置 `[github_webhook]` 时,行为与当前版本完全一致
- **触发**: 启动时未检测到 `config.toml` 中的 `[github_webhook]` 字段
- **预期结果**: 使用硬编码默认值 (`GITHUB_WEBHOOK_SECRET`、`GITHUB_TOKEN`、`/codex` 等)
- **备注**: 现有部署无需修改 config.toml 即可继续工作

---

## Historical Acceptance Matrix

| ID  | Requirement                                                      | Priority | How to Verify                                                                   |
| --- | ---------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------- |
| A1  | 支持 `issues` 事件 (opened, edited, reopened)                    | P0       | 手工触发 issue 创建/编辑/重新打开,验证 worktree 创建和 Codex 执行               |
| A2  | 支持 `pull_request` 事件 (opened, edited, reopened, synchronize) | P0       | 手工触发 PR 创建/编辑/更新,验证 worktree 创建和 Codex 执行                      |
| A3  | 支持 `push` 事件                                                 | P0       | 手工 push commit,验证 worktree 创建和 Codex 执行                                |
| A4  | `[github_webhook]` 配置生效                                      | P0       | 配置 `config.toml`,启动后验证默认值读取正确                                     |
| A5  | CLI 参数覆盖 config 默认值                                       | P0       | 同时设置 config 和 CLI 参数,验证 CLI 优先                                       |
| A6  | GitHub App JWT 生成                                              | P0       | 设置 `GITHUB_APP_ID` 和 `GITHUB_APP_PRIVATE_KEY`,验证 JWT token 生成成功        |
| A7  | installation token 获取                                          | P0       | GitHub App webhook payload,验证 installation token 获取并用于 API 调用          |
| A8  | 向后兼容                                                         | P0       | 不修改 config.toml,启动后验证行为与当前版本一致                                 |
| A9  | 事件归一化层                                                     | P1       | 单元测试覆盖 repo webhook、org webhook、GitHub App webhook                      |
| A10 | schema 更新                                                      | P1       | 运行 `just write-config-schema`,验证 `core/config.schema.json` 包含新字段       |
| A11 | 文档更新                                                         | P1       | 更新 `codex-rs/docs/github-webhook.md` 和 `docs/config.md`,包含新事件和配置示例 |

---

## Historical Edge Cases & Failure Handling

- **Case**: `push` 事件的 `after` 为全零 SHA (删除分支)
  - **预期行为**: 不创建 work item,记录 info 级日志
- **Case**: `issues` 或 `pull_request` 事件的 `action` 不在 allowlist 中
  - **预期行为**: 不创建 work item,记录 debug 级日志
- **Failure**: GitHub App JWT 生成失败 (private key 格式错误)
  - **起草时预期**: 记录 error 级日志,跳过当前 webhook,返回 500 状态码
- **Failure**: installation token 获取失败 (installation ID 不存在或权限不足)
  - **起草时预期**: 记录 error 级日志,跳过当前 webhook,返回 500 状态码
- **Failure**: `parse_work_item` 无法识别事件类型
  - **起草时预期**: 记录 warn 级日志,返回 200 状态码 (避免 GitHub 重试)
- **Recovery**: GitHub API rate limit
  - **起草时预期**: 记录 error 级日志,跳过当前 webhook,返回 429 状态码

---

## Technical Constraints & Non-Functional Requirements

### Performance

- installation token 获取延迟 < 2 秒 (P95)
- JWT 生成延迟 < 100 毫秒 (P99)
- webhook 处理延迟与当前版本持平 (不引入显著回归)

### Security & Compliance

- 敏感值 (webhook secret、GitHub token、GitHub App private key) 仅通过环境变量提供,不落盘
- JWT token 有效期 ≤ 10 分钟,降低泄漏风险
- installation token 不缓存,每次 webhook 触发时重新获取
- HMAC-SHA256 签名校验保持不变

### Integration & Dependencies

- **GitHub REST API**: 需要调用 `/app/installations/{id}/access_tokens` (GitHub App 模式)
- **jsonwebtoken crate**: 用于 JWT 生成 (RS256 算法)
- **现有 GitHub API client**: 复用现有 `GithubClient` 结构,增加 installation token 支持

### Platform Constraints

- Rust 版本 ≥ 1.70 (支持 `jsonwebtoken` crate)
- 运行环境需要支持环境变量读取
- GitHub App private key 格式为 PEM (PKCS#1 或 PKCS#8)

---

## MVP Scope & Delivery

### Must Have (MVP)

- 支持 `issues` 事件 (opened, edited, reopened)
- 支持 `pull_request` 事件 (opened, edited, reopened, synchronize)
- 支持 `push` 事件
- 新增 `[github_webhook]` 配置
- GitHub App 认证支持 (JWT + installation token)
- 向后兼容
- 更新 schema、文档、测试

### Nice to Have (Later)

- 支持更多 `issues` action (labeled, assigned, milestoned)
- 支持更多 `pull_request` action (review_requested, ready_for_review)
- installation token 缓存 (降低 API 调用频率)
- 配置校验 (启动时检查环境变量是否存在)
- Prometheus metrics (webhook 处理成功/失败计数)

### Rollout Notes

- 分阶段合并:先合并配置模型变更,再合并事件扩展,最后合并 GitHub App 支持
- 回归测试:验证现有 `issue_comment`、`pull_request_review_comment`、`pull_request_review` 事件不受影响
- 文档先行:在代码合并前更新 `codex-rs/docs/github-webhook.md` 和 `docs/config.md`

---

## Examples and Counterexamples

### Good Outcome Example

**配置文件** (`config.toml`):

```toml
[github_webhook]
command_prefix = "/codex"
min_permission = "write"
delivery_ttl_days = 7
repo_ttl_days = 0
allow_repos = ["owner/repo"]
webhook_secret_env = "GITHUB_WEBHOOK_SECRET"
github_token_env = "GITHUB_TOKEN"
github_app_id_env = "GITHUB_APP_ID"
github_app_private_key_env = "GITHUB_APP_PRIVATE_KEY"
```

**启动命令**:

```bash
export GITHUB_WEBHOOK_SECRET=my-secret
export GITHUB_APP_ID=12345
export GITHUB_APP_PRIVATE_KEY="$(cat private-key.pem)"
codex github --listen 127.0.0.1:8787
```

**webhook payload** (GitHub App `issues` 事件):

```json
{
  "action": "opened",
  "issue": {
    "number": 42,
    "title": "Bug in feature X",
    "body": "/codex fix this issue"
  },
  "repository": {
    "full_name": "owner/repo"
  },
  "installation": {
    "id": 67890
  }
}
```

**预期行为**:

1. 验证 HMAC 签名
2. 检测到 `installation.id`,判定为 GitHub App webhook
3. 使用 `GITHUB_APP_ID` 和 `GITHUB_APP_PRIVATE_KEY` 生成 JWT token
4. 调用 GitHub API 获取 installation token
5. 创建 worktree `~/.codex/github-repos/owner/repo/issues/42`
6. 使用 installation token clone/fetch 仓库
7. 执行 Codex,传递 issue 上下文
8. 将结果回贴到 issue comment

### Counterexample

**错误配置** (`config.toml`):

```toml
[github_webhook]
github_app_id = 12345  # ❌ 不应在配置里保存实际值
github_app_private_key = "-----BEGIN RSA PRIVATE KEY-----\n..."  # ❌ 敏感值不应落盘
```

**正确做法**:

```toml
[github_webhook]
github_app_id_env = "GITHUB_APP_ID"  # ✅ 只保存环境变量名称
github_app_private_key_env = "GITHUB_APP_PRIVATE_KEY"  # ✅ 只保存环境变量名称
```

---

## Risks & Dependencies

| Risk                                                | Probability | Impact | Mitigation                                                        |
| --------------------------------------------------- | ----------- | ------ | ----------------------------------------------------------------- |
| GitHub App JWT 库引入安全漏洞                       | Low         | High   | 使用官方推荐的 `jsonwebtoken` crate,定期更新依赖                  |
| installation token 获取失败导致 webhook 丢失        | Medium      | Medium | 记录详细错误日志,返回 500 状态码触发 GitHub 重试                  |
| `push` 事件大量触发导致资源耗尽                     | Medium      | Medium | 初期通过 allowlist 限制触发范围,后续增加 rate limiting            |
| 配置模型变更导致向后兼容性回归                      | Low         | High   | 单元测试覆盖未配置 `[github_webhook]` 的场景,集成测试覆盖现有事件 |
| `issues` / `pull_request` action 选择不当导致误触发 | Medium      | Low    | 初期保守 (仅支持明确需要的 action),后续根据用户反馈扩展           |

**Dependencies:**

- `jsonwebtoken` crate (Rust JWT 库)
- GitHub REST API (`/app/installations/{id}/access_tokens`)
- 现有 `GithubClient` 和 `parse_work_item` 逻辑

---

## Handoff Notes for Implementation and Testing

**实现团队必须理解的核心点**:

- 敏感值 (secret/token/private key) 绝对不允许落盘,配置层只保存环境变量名称
- `[github_webhook]` 配置是可选的,未配置时必须保持与当前版本完全一致的行为
- `issues` 和 `pull_request` 事件的 action allowlist 需要在实现时确定,初期保守
- 新增的非评论事件不做无提示自动执行;必须显式携带命令前缀,避免噪音和误触发
- GitHub App 模式和 `GITHUB_TOKEN` 模式是互斥的,优先级:GitHub App > `GITHUB_TOKEN`

**测试团队应首先验证**:

- 向后兼容性:未配置 `[github_webhook]` 时,现有 `issue_comment` 等事件仍正常工作
- GitHub App 认证流程:JWT 生成、installation token 获取、API 调用全链路
- 事件归一化层:repo webhook、org webhook、GitHub App webhook 三种来源的 payload 解析正确
- 配置优先级:CLI 参数 > config.toml > 硬编码默认值

**仍然模糊且需要实现前确认的点**:

- `issues` 事件的 action allowlist (当前建议:opened, edited, reopened)
- `pull_request` 事件的 action allowlist (当前建议:opened, edited, reopened, synchronize)
- `push` 事件是否需要额外的 allowlist 逻辑 (例如只允许特定分支)
- installation token 是否需要缓存 (当前建议:不缓存,每次重新获取)

---

_This PRD was created through interactive requirements gathering and is optimized for implementation handoff, testability, and scope clarity._
