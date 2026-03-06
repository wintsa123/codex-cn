use anyhow::Context;
use anyhow::Result;
use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::http::HeaderValue;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::routing::post;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use codex_core::config::find_codex_home;
use codex_utils_cli::CliConfigOverrides;
use hmac::Hmac;
use hmac::Mac;
use reqwest::header::ACCEPT;
use reqwest::header::AUTHORIZATION;
use reqwest::header::HeaderMap as ReqwestHeaderMap;
use reqwest::header::HeaderName;
use reqwest::header::HeaderValue as ReqwestHeaderValue;
use reqwest::header::USER_AGENT;
use serde_json::Value;
use sha2::Sha256;
use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncReadExt;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio::sync::Semaphore;

const DEFAULT_LISTEN_ADDR: &str = "127.0.0.1:8787";
const DEFAULT_WEBHOOK_SECRET_ENV: &str = "GITHUB_WEBHOOK_SECRET";
const DEFAULT_GITHUB_TOKEN_ENV: &str = "GITHUB_TOKEN";
const DEFAULT_COMMAND_PREFIX: &str = "/codex";
const GITHUB_API_BASE_URL: &str = "https://api.github.com";
const GITHUB_API_VERSION: &str = "2022-11-28";
const GITHUB_CONTEXT_FILENAME: &str = ".codex_github_context.md";
const REPO_MANAGED_MARKER_FILENAME: &str = ".codex_github_managed";
const REPO_LAST_USED_FILENAME: &str = ".codex_github_last_used";
const DEFAULT_DELIVERY_TTL_DAYS: u64 = 7;
const DEFAULT_REPO_TTL_DAYS: u64 = 0;
const GITHUB_API_PER_PAGE: usize = 100;
const GITHUB_API_MAX_PAGES: usize = 100;
const MAX_WEBHOOK_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_MAX_CONCURRENCY: usize = 2;
const GITHUB_API_TIMEOUT: Duration = Duration::from_secs(20);
const GC_INTERVAL: Duration = Duration::from_secs(60 * 60);
const GIT_COMMAND_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const CODEX_EXEC_TIMEOUT: Duration = Duration::from_secs(20 * 60);

type HmacSha256 = Hmac<Sha256>;

fn ttl_from_days(days: u64) -> Option<Duration> {
    if days == 0 {
        return None;
    }
    let secs = days.saturating_mul(24 * 60 * 60);
    Some(Duration::from_secs(secs))
}

#[cfg(test)]
std::thread_local! {
    static TEST_GIT_COMMAND_TIMEOUT_MS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

fn git_command_timeout() -> Duration {
    #[cfg(test)]
    {
        let ms = TEST_GIT_COMMAND_TIMEOUT_MS.with(std::cell::Cell::get);
        if ms != 0 {
            return Duration::from_millis(ms);
        }
    }
    GIT_COMMAND_TIMEOUT
}

#[cfg(test)]
struct TestGitCommandTimeoutGuard;

#[cfg(test)]
impl TestGitCommandTimeoutGuard {
    fn set(timeout: Duration) -> Self {
        let ms = timeout.as_millis().try_into().unwrap_or(u64::MAX);
        TEST_GIT_COMMAND_TIMEOUT_MS.with(|slot| slot.set(ms));
        Self
    }
}

#[cfg(test)]
impl Drop for TestGitCommandTimeoutGuard {
    fn drop(&mut self) {
        TEST_GIT_COMMAND_TIMEOUT_MS.with(|slot| slot.set(0));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, clap::ValueEnum)]
#[value(rename_all = "kebab-case")]
enum MinPermission {
    Read,
    Triage,
    Write,
    Maintain,
    Admin,
}

impl MinPermission {
    fn allows(self, actual: &str) -> bool {
        let Some(actual_rank) = permission_rank(actual) else {
            return false;
        };
        let required_rank = permission_rank(match self {
            MinPermission::Read => "read",
            MinPermission::Triage => "triage",
            MinPermission::Write => "write",
            MinPermission::Maintain => "maintain",
            MinPermission::Admin => "admin",
        })
        .expect("hardcoded permissions must have ranks");
        actual_rank >= required_rank
    }
}

fn permission_rank(permission: &str) -> Option<u8> {
    match permission {
        "read" => Some(1),
        "triage" => Some(2),
        "write" => Some(3),
        "maintain" => Some(4),
        "admin" => Some(5),
        _ => None,
    }
}

#[derive(Debug, clap::Parser)]
#[command(override_usage = "codex github [OPTIONS]")]
pub struct GithubCommand {
    /// Address to listen on.
    #[arg(long, default_value = DEFAULT_LISTEN_ADDR, value_name = "ADDR")]
    listen: std::net::SocketAddr,

    /// Environment variable that contains the GitHub webhook secret.
    #[arg(long, default_value = DEFAULT_WEBHOOK_SECRET_ENV, value_name = "ENV")]
    webhook_secret_env: String,

    /// Environment variable that contains the GitHub token used for API calls.
    #[arg(long, default_value = DEFAULT_GITHUB_TOKEN_ENV, value_name = "ENV")]
    github_token_env: String,

    /// Minimum required permission for the GitHub sender on the repository.
    #[arg(long, value_enum, default_value_t = MinPermission::Triage, value_name = "PERMISSION")]
    min_permission: MinPermission,

    /// Only handle events for these repositories (repeatable), e.g. OWNER/REPO.
    ///
    /// If omitted, all repositories are allowed (permission checks still apply).
    #[arg(long = "allow-repo", value_name = "OWNER/REPO")]
    allow_repo: Vec<String>,

    /// Comment prefix that triggers Codex.
    #[arg(long, default_value = DEFAULT_COMMAND_PREFIX, value_name = "PREFIX")]
    command_prefix: String,

    /// Delete delivery marker files older than this many days (0 disables).
    #[arg(long, default_value_t = DEFAULT_DELIVERY_TTL_DAYS, value_name = "DAYS")]
    delivery_ttl_days: u64,

    /// Delete repo caches older than this many days since last use, when no worktrees exist (0 disables).
    #[arg(long, default_value_t = DEFAULT_REPO_TTL_DAYS, value_name = "DAYS")]
    repo_ttl_days: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RepoKey {
    owner: String,
    repo: String,
}

#[derive(Clone)]
struct AppState {
    secret: Arc<Vec<u8>>,
    github: Arc<GithubApi>,
    github_token: Arc<String>,
    allow_repos: Arc<HashSet<String>>,
    min_permission: MinPermission,
    command_prefix: Arc<String>,
    repo_root: Arc<PathBuf>,
    codex_bin: Arc<PathBuf>,
    codex_config_overrides: Arc<Vec<String>>,
    delivery_markers_dir: Arc<PathBuf>,
    thread_state_dir: Arc<PathBuf>,
    delivery_ttl: Option<Duration>,
    repo_ttl: Option<Duration>,
    concurrency_limit: Arc<Semaphore>,
    work_locks: Arc<Mutex<HashMap<WorkKey, Arc<Mutex<()>>>>>,
    repo_locks: Arc<Mutex<HashMap<RepoKey, Arc<Mutex<()>>>>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct WorkKey {
    owner: String,
    repo: String,
    kind: WorkKind,
    number: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum WorkKind {
    Issue,
    Pull,
}

impl WorkKind {
    fn dir_name(self) -> &'static str {
        match self {
            WorkKind::Issue => "issues",
            WorkKind::Pull => "pulls",
        }
    }

    fn label(self) -> &'static str {
        match self {
            WorkKind::Issue => "issue",
            WorkKind::Pull => "pull",
        }
    }
}

#[derive(Debug, Clone)]
struct WorkItem {
    repo_full_name: String,
    sender_login: String,
    work: WorkKey,
    prompt: String,
    response_target: ResponseTarget,
}

#[derive(Debug, Clone)]
enum ResponseTarget {
    IssueComment { issue_number: u64 },
    ReviewCommentReply { comment_id: u64 },
    PullRequestReview { pull_number: u64 },
}

struct GithubApi {
    client: reqwest::Client,
    base_url: String,
}

impl GithubApi {
    fn new(token: String) -> Result<Self> {
        Self::new_with_base_url(token, GITHUB_API_BASE_URL.to_string())
    }

    fn new_with_base_url(token: String, base_url: String) -> Result<Self> {
        let base_url = base_url.trim_end_matches('/').to_string();
        let mut headers = ReqwestHeaderMap::new();
        let auth = format!("Bearer {token}");
        headers.insert(
            AUTHORIZATION,
            ReqwestHeaderValue::from_str(&auth).context("invalid GitHub token")?,
        );
        headers.insert(
            ACCEPT,
            ReqwestHeaderValue::from_static("application/vnd.github+json"),
        );
        headers.insert(USER_AGENT, ReqwestHeaderValue::from_static("codex-cli"));
        headers.insert(
            HeaderName::from_static("x-github-api-version"),
            ReqwestHeaderValue::from_static(GITHUB_API_VERSION),
        );

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .timeout(GITHUB_API_TIMEOUT)
            .build()
            .context("failed to build GitHub HTTP client")?;

        Ok(Self { client, base_url })
    }

    async fn repo_permission(&self, owner: &str, repo: &str, user: &str) -> Result<Option<String>> {
        let url = format!(
            "{}/repos/{owner}/{repo}/collaborators/{user}/permission",
            self.base_url
        );
        let res = self
            .client
            .get(url)
            .send()
            .await
            .context("failed to query collaborator permission")?;
        let status = res.status();
        let body = res.text().await.unwrap_or_default();
        if status == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !status.is_success() {
            anyhow::bail!("GitHub permission API failed ({status}): {body}");
        }
        let v: Value = serde_json::from_str(&body).context("invalid GitHub permission JSON")?;
        let permission = v
            .get("permission")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if permission.is_empty() {
            anyhow::bail!("GitHub permission API returned empty permission: {body}");
        }
        Ok(Some(permission.to_string()))
    }

    async fn repo_default_branch(&self, owner: &str, repo: &str) -> Result<String> {
        let url = format!("{}/repos/{owner}/{repo}", self.base_url);
        let res = self
            .client
            .get(url)
            .send()
            .await
            .context("failed to query repository metadata")?;
        let status = res.status();
        let body = res.text().await.unwrap_or_default();
        if !status.is_success() {
            anyhow::bail!("GitHub repo API failed ({status}): {body}");
        }
        let v: Value = serde_json::from_str(&body).context("invalid GitHub repo JSON")?;
        let default_branch = v
            .get("default_branch")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if default_branch.is_empty() {
            anyhow::bail!("GitHub repo API returned empty default_branch: {body}");
        }
        Ok(default_branch.to_string())
    }

    async fn get_json_value(&self, url: String) -> Result<Value> {
        let res = self
            .client
            .get(url)
            .send()
            .await
            .context("failed to call GitHub API")?;
        let status = res.status();
        let text = res.text().await.unwrap_or_default();
        if !status.is_success() {
            anyhow::bail!("GitHub API failed ({status}): {text}");
        }
        serde_json::from_str(&text).context("invalid GitHub JSON")
    }

    async fn get_json_vec(&self, url: String) -> Result<Vec<Value>> {
        let res = self
            .client
            .get(url)
            .send()
            .await
            .context("failed to call GitHub API")?;
        let status = res.status();
        let text = res.text().await.unwrap_or_default();
        if !status.is_success() {
            anyhow::bail!("GitHub API failed ({status}): {text}");
        }
        serde_json::from_str(&text).context("invalid GitHub JSON")
    }

    async fn list_paginated(&self, url_base: String) -> Result<Vec<Value>> {
        let mut out = Vec::new();
        for page in 1..=GITHUB_API_MAX_PAGES {
            let url = format!("{url_base}?per_page={GITHUB_API_PER_PAGE}&page={page}");
            let batch = self.get_json_vec(url).await?;
            let n = batch.len();
            out.extend(batch);
            if n < GITHUB_API_PER_PAGE {
                return Ok(out);
            }
        }
        anyhow::bail!("GitHub API pagination exceeded max pages ({GITHUB_API_MAX_PAGES})");
    }

    async fn post_issue_comment(
        &self,
        owner: &str,
        repo: &str,
        issue_number: u64,
        body: &str,
    ) -> Result<()> {
        let url = format!(
            "{}/repos/{owner}/{repo}/issues/{issue_number}/comments",
            self.base_url
        );
        self.post_json(url, serde_json::json!({ "body": body }))
            .await
    }

    async fn post_review_comment_reply(
        &self,
        owner: &str,
        repo: &str,
        comment_id: u64,
        body: &str,
    ) -> Result<()> {
        let url = format!(
            "{}/repos/{owner}/{repo}/pulls/comments/{comment_id}/replies",
            self.base_url
        );
        self.post_json(url, serde_json::json!({ "body": body }))
            .await
    }

    async fn create_pr_review(
        &self,
        owner: &str,
        repo: &str,
        pull_number: u64,
        body: &str,
    ) -> Result<()> {
        let url = format!(
            "{}/repos/{owner}/{repo}/pulls/{pull_number}/reviews",
            self.base_url
        );
        self.post_json(
            url,
            serde_json::json!({
                "body": body,
                "event": "COMMENT"
            }),
        )
        .await
    }

    async fn post_json(&self, url: String, body: Value) -> Result<()> {
        let res = self
            .client
            .post(url)
            .json(&body)
            .send()
            .await
            .context("failed to call GitHub API")?;
        let status = res.status();
        let text = res.text().await.unwrap_or_default();
        if !status.is_success() {
            anyhow::bail!("GitHub API failed ({status}): {text}");
        }
        Ok(())
    }
}

pub async fn run_main(cmd: GithubCommand, root_config_overrides: CliConfigOverrides) -> Result<()> {
    run_main_with_shutdown(cmd, root_config_overrides, shutdown_signal()).await
}

async fn run_main_with_shutdown<F>(
    cmd: GithubCommand,
    root_config_overrides: CliConfigOverrides,
    shutdown: F,
) -> Result<()>
where
    F: std::future::Future<Output = ()> + Send + 'static,
{
    let secret = read_env_required(&cmd.webhook_secret_env, "GitHub webhook secret")?;
    let token = read_env_required(&cmd.github_token_env, "GitHub token")?;

    let codex_home = find_codex_home().context("failed to resolve CODEX_HOME")?;
    let repo_root = codex_home.join("github-repos");
    let delivery_markers_dir = codex_home.join("github").join("deliveries");
    let thread_state_dir = codex_home.join("github").join("threads");

    let github = GithubApi::new(token.clone())?;
    let allow_repos = normalize_allowlist(&cmd.allow_repo);
    let codex_bin = std::env::current_exe().context("failed to resolve current executable")?;

    let mut codex_config_overrides = root_config_overrides.raw_overrides;
    codex_config_overrides.push("approval_policy=\"never\"".to_string());
    codex_config_overrides.push("sandbox_mode=\"workspace-write\"".to_string());

    let delivery_ttl = ttl_from_days(cmd.delivery_ttl_days);
    let repo_ttl = ttl_from_days(cmd.repo_ttl_days);

    let state = AppState {
        secret: Arc::new(secret.into_bytes()),
        github: Arc::new(github),
        github_token: Arc::new(token),
        allow_repos: Arc::new(allow_repos),
        min_permission: cmd.min_permission,
        command_prefix: Arc::new(cmd.command_prefix),
        repo_root: Arc::new(repo_root),
        codex_bin: Arc::new(codex_bin),
        codex_config_overrides: Arc::new(codex_config_overrides),
        delivery_markers_dir: Arc::new(delivery_markers_dir),
        thread_state_dir: Arc::new(thread_state_dir),
        delivery_ttl,
        repo_ttl,
        concurrency_limit: Arc::new(Semaphore::new(DEFAULT_MAX_CONCURRENCY)),
        work_locks: Arc::new(Mutex::new(HashMap::new())),
        repo_locks: Arc::new(Mutex::new(HashMap::new())),
    };

    if state.delivery_ttl.is_some() || state.repo_ttl.is_some() {
        tokio::spawn(gc_loop(state.clone()));
    }

    let app = Router::new()
        .route("/", post(handle_webhook))
        .route("/healthz", get(healthz))
        .with_state(state);

    let listener = TcpListener::bind(cmd.listen)
        .await
        .with_context(|| format!("failed to bind {}", cmd.listen))?;

    eprintln!("codex github listening on http://{}", cmd.listen);
    axum::serve(listener, app.into_make_service())
        .with_graceful_shutdown(shutdown)
        .await
        .context("github webhook server failed")?;

    Ok(())
}

async fn gc_loop(state: AppState) {
    loop {
        if let Some(ttl) = state.delivery_ttl
            && let Err(err) = gc_delivery_markers(state.delivery_markers_dir.as_ref(), ttl).await {
                eprintln!("delivery gc failed: {err:#}");
            }
        if let Some(ttl) = state.repo_ttl
            && let Err(err) = gc_repo_caches(&state, ttl).await {
                eprintln!("repo gc failed: {err:#}");
            }
        tokio::time::sleep(GC_INTERVAL).await;
    }
}

async fn gc_delivery_markers(dir: &Path, ttl: Duration) -> Result<()> {
    let mut rd = match tokio::fs::read_dir(dir).await {
        Ok(rd) => rd,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", dir.display())),
    };
    let now = SystemTime::now();
    while let Some(entry) = rd
        .next_entry()
        .await
        .with_context(|| format!("failed to read {}", dir.display()))?
    {
        let path = entry.path();
        if path.extension().and_then(std::ffi::OsStr::to_str) != Some("marker") {
            continue;
        }
        let meta = match entry.metadata().await {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() {
            continue;
        }
        let modified = match meta.modified() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let age = match now.duration_since(modified) {
            Ok(d) => d,
            Err(_) => continue,
        };
        if age < ttl {
            continue;
        }
        let _ = tokio::fs::remove_file(path).await;
    }
    Ok(())
}

async fn gc_repo_caches(state: &AppState, ttl: Duration) -> Result<()> {
    let root = state.repo_root.as_ref();
    let mut owners = match tokio::fs::read_dir(root).await {
        Ok(rd) => rd,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", root.display())),
    };

    while let Some(owner_entry) = owners
        .next_entry()
        .await
        .with_context(|| format!("failed to read {}", root.display()))?
    {
        let owner_ft = match owner_entry.file_type().await {
            Ok(ft) => ft,
            Err(_) => continue,
        };
        if !owner_ft.is_dir() {
            continue;
        }
        let owner_name = owner_entry.file_name();
        let Some(owner) = owner_name.to_str() else {
            continue;
        };
        let owner_dir = owner_entry.path();
        let mut repos = match tokio::fs::read_dir(&owner_dir).await {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        while let Some(repo_entry) = repos.next_entry().await? {
            let repo_ft = match repo_entry.file_type().await {
                Ok(ft) => ft,
                Err(_) => continue,
            };
            if !repo_ft.is_dir() {
                continue;
            }
            let repo_name = repo_entry.file_name();
            let Some(repo) = repo_name.to_str() else {
                continue;
            };
            gc_repo_cache_if_stale(state, owner, repo, ttl).await?;
        }
    }

    Ok(())
}

async fn gc_repo_cache_if_stale(
    state: &AppState,
    owner: &str,
    repo: &str,
    ttl: Duration,
) -> Result<()> {
    let repo_dir = state.repo_root.join(owner).join(repo);
    if !repo_dir.join(REPO_MANAGED_MARKER_FILENAME).exists() {
        return Ok(());
    }

    let Some(last_used) = read_repo_last_used(&repo_dir).await? else {
        return Ok(());
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if now < last_used {
        return Ok(());
    }
    let age = Duration::from_secs(now - last_used);
    if age < ttl {
        return Ok(());
    }

    if !repo_worktrees_are_empty(&repo_dir).await? {
        return Ok(());
    }

    let repo_lock = repo_lock_for(state, owner, repo).await;
    let _guard = repo_lock.lock().await;

    if !repo_dir.join(REPO_MANAGED_MARKER_FILENAME).exists() {
        return Ok(());
    }
    let Some(last_used) = read_repo_last_used(&repo_dir).await? else {
        return Ok(());
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if now < last_used {
        return Ok(());
    }
    let age = Duration::from_secs(now - last_used);
    if age < ttl {
        return Ok(());
    }
    if !repo_worktrees_are_empty(&repo_dir).await? {
        return Ok(());
    }

    tokio::fs::remove_dir_all(&repo_dir)
        .await
        .with_context(|| format!("failed to delete {}", repo_dir.display()))?;
    Ok(())
}

async fn repo_worktrees_are_empty(repo_dir: &Path) -> Result<bool> {
    let issues_ok = dir_is_empty(&repo_dir.join("issues")).await?;
    let pulls_ok = dir_is_empty(&repo_dir.join("pulls")).await?;
    Ok(issues_ok && pulls_ok)
}

async fn dir_is_empty(path: &Path) -> Result<bool> {
    let mut rd = match tokio::fs::read_dir(path).await {
        Ok(rd) => rd,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    Ok(rd.next_entry().await?.is_none())
}

async fn read_repo_last_used(repo_dir: &Path) -> Result<Option<u64>> {
    let path = repo_dir.join(REPO_LAST_USED_FILENAME);
    let content = match tokio::fs::read_to_string(&path).await {
        Ok(s) => s,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    match trimmed.parse::<u64>() {
        Ok(v) => Ok(Some(v)),
        Err(_) => Ok(None),
    }
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn handle_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    if body.len() > MAX_WEBHOOK_BYTES {
        return (StatusCode::PAYLOAD_TOO_LARGE, "payload too large").into_response();
    }
    let Some(event) = header_string(&headers, "X-GitHub-Event") else {
        return (StatusCode::BAD_REQUEST, "missing X-GitHub-Event").into_response();
    };
    let Some(delivery_id) = header_string(&headers, "X-GitHub-Delivery") else {
        return (StatusCode::BAD_REQUEST, "missing X-GitHub-Delivery").into_response();
    };
    let signature = header_value(&headers, "X-Hub-Signature-256");
    if !verify_github_signature(&state.secret, &body, signature) {
        return (StatusCode::UNAUTHORIZED, "bad signature").into_response();
    }

    let payload: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => return (StatusCode::BAD_REQUEST, "invalid json").into_response(),
    };

    let work_item = match parse_work_item(&event, &payload, &state.command_prefix) {
        Ok(Some(item)) => item,
        Ok(None) => return (StatusCode::ACCEPTED, "ignored").into_response(),
        Err(err) => {
            eprintln!("payload parse failed: {err:#}");
            return (StatusCode::BAD_REQUEST, "invalid payload").into_response();
        }
    };

    if !repo_allowed(&state.allow_repos, &work_item.repo_full_name) {
        return (StatusCode::ACCEPTED, "ignored").into_response();
    }

    let permit = match state.concurrency_limit.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return (StatusCode::SERVICE_UNAVAILABLE, "busy").into_response(),
    };

    match sender_allowed(&state, &work_item).await {
        Ok(true) => {}
        Ok(false) => return (StatusCode::ACCEPTED, "ignored").into_response(),
        Err(err) => {
            eprintln!("sender permission check failed: {err:#}");
            return (StatusCode::INTERNAL_SERVER_ERROR, "permission check failed").into_response();
        }
    }

    match claim_delivery(&state.delivery_markers_dir, &delivery_id).await {
        Ok(false) => return (StatusCode::ACCEPTED, "duplicate delivery").into_response(),
        Ok(true) => {}
        Err(err) => {
            eprintln!("delivery claim failed: {err:#}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed to claim delivery",
            )
                .into_response();
        }
    }

    tokio::spawn(process_work_item(state, work_item, permit));
    (StatusCode::ACCEPTED, "queued").into_response()
}

fn header_value<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a HeaderValue> {
    headers.get(name)
}

fn header_string(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
}

fn read_env_required(env_var: &str, label: &str) -> Result<String> {
    let value = std::env::var(env_var)
        .with_context(|| format!("{label} not set: missing env {env_var}"))?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        anyhow::bail!("{label} is empty: env {env_var}");
    }
    Ok(trimmed.to_string())
}

fn normalize_allowlist(items: &[String]) -> HashSet<String> {
    items
        .iter()
        .map(|s| normalize_repo_full_name(s))
        .filter(|s| !s.is_empty())
        .collect()
}

fn normalize_repo_full_name(s: &str) -> String {
    s.trim().to_ascii_lowercase()
}

fn repo_allowed(allow_repos: &HashSet<String>, repo_full_name: &str) -> bool {
    if allow_repos.is_empty() {
        return true;
    }
    allow_repos.contains(&normalize_repo_full_name(repo_full_name))
}

async fn sender_allowed(state: &AppState, item: &WorkItem) -> Result<bool> {
    let owner = item.work.owner.as_str();
    let repo = item.work.repo.as_str();
    let sender = item.sender_login.as_str();
    if sender.eq_ignore_ascii_case(owner) {
        return Ok(true);
    }
    let permission = state
        .github
        .repo_permission(owner, repo, sender)
        .await
        .with_context(|| format!("permission API failed for {owner}/{repo} {sender}"))?;
    let Some(permission) = permission else {
        eprintln!("sender {sender} not allowed on {owner}/{repo} (permission API returned 404)");
        return Ok(false);
    };
    if state.min_permission.allows(&permission) {
        Ok(true)
    } else {
        eprintln!(
            "sender {sender} has {permission} but requires {:?}",
            state.min_permission
        );
        Ok(false)
    }
}

fn verify_github_signature(secret: &[u8], body: &[u8], signature: Option<&HeaderValue>) -> bool {
    let Some(signature) = signature.and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let Some(hex) = signature.strip_prefix("sha256=") else {
        return false;
    };
    let Some(sig_bytes) = decode_hex(hex) else {
        return false;
    };

    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC keys have no fixed length");
    mac.update(body);
    mac.verify_slice(&sig_bytes).is_ok()
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let mut it = s.as_bytes().iter().copied();
    while let (Some(hi), Some(lo)) = (it.next(), it.next()) {
        let hi = from_hex_digit(hi)?;
        let lo = from_hex_digit(lo)?;
        out.push((hi << 4) | lo);
    }
    Some(out)
}

fn from_hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

async fn claim_delivery(dir: &Path, delivery_id: &str) -> Result<bool> {
    tokio::fs::create_dir_all(dir)
        .await
        .with_context(|| format!("failed to create delivery markers dir {}", dir.display()))?;
    let marker_name = sanitize_filename_component(delivery_id);
    let marker = dir.join(format!("{marker_name}.marker"));
    match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(marker)
        .await
    {
        Ok(_) => Ok(true),
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
        Err(err) => Err(err).context("failed to create delivery marker file"),
    }
}

fn sanitize_filename_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => out.push(ch),
            _ => out.push('_'),
        }
    }
    if out.is_empty() { "_".to_string() } else { out }
}

fn parse_work_item(event: &str, payload: &Value, command_prefix: &str) -> Result<Option<WorkItem>> {
    enum GithubEvent {
        IssueComment,
        PullRequestReviewComment,
        PullRequestReview,
    }

    let event = match event {
        "issue_comment" => GithubEvent::IssueComment,
        "pull_request_review_comment" => GithubEvent::PullRequestReviewComment,
        "pull_request_review" => GithubEvent::PullRequestReview,
        _ => return Ok(None),
    };

    let repo_full_name = payload
        .get("repository")
        .and_then(|v| v.get("full_name"))
        .and_then(Value::as_str)
        .context("missing repository.full_name")?;
    let (owner, repo) = split_owner_repo(repo_full_name)?;
    let sender_login = payload
        .get("sender")
        .and_then(|v| v.get("login"))
        .and_then(Value::as_str)
        .context("missing sender.login")?;

    match event {
        GithubEvent::IssueComment => parse_issue_comment(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
        GithubEvent::PullRequestReviewComment => parse_review_comment(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
        GithubEvent::PullRequestReview => parse_review(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
    }
}

fn split_owner_repo(full_name: &str) -> Result<(&str, &str)> {
    let mut it = full_name.split('/');
    let owner = it.next().unwrap_or_default();
    let repo = it.next().unwrap_or_default();
    if owner.is_empty() || repo.is_empty() || it.next().is_some() {
        anyhow::bail!("invalid repository.full_name: {full_name}");
    }
    if !is_safe_repo_component(owner) || !is_safe_repo_component(repo) {
        anyhow::bail!("invalid repository.full_name: {full_name}");
    }
    Ok((owner, repo))
}

fn is_safe_repo_component(s: &str) -> bool {
    if matches!(s, "." | "..") {
        return false;
    }
    s.chars()
        .all(|c| matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.'))
}

fn parse_issue_comment(
    owner: &str,
    repo: &str,
    repo_full_name: &str,
    sender_login: &str,
    payload: &Value,
    command_prefix: &str,
) -> Result<Option<WorkItem>> {
    let action = payload
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(action, "created" | "edited") {
        return Ok(None);
    }

    let body = payload
        .get("comment")
        .and_then(|v| v.get("body"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let prompt = strip_prefix_prompt(body, command_prefix)?;
    let Some(prompt) = prompt else {
        return Ok(None);
    };

    let issue = payload.get("issue").context("missing issue")?;
    let issue_number = issue
        .get("number")
        .and_then(Value::as_u64)
        .context("missing issue.number")?;
    let is_pr = issue.get("pull_request").is_some();

    let kind = if is_pr {
        WorkKind::Pull
    } else {
        WorkKind::Issue
    };
    Ok(Some(WorkItem {
        repo_full_name: repo_full_name.to_string(),
        sender_login: sender_login.to_string(),
        work: WorkKey {
            owner: owner.to_string(),
            repo: repo.to_string(),
            kind,
            number: issue_number,
        },
        prompt,
        response_target: ResponseTarget::IssueComment {
            issue_number,
        },
    }))
}

fn parse_review_comment(
    owner: &str,
    repo: &str,
    repo_full_name: &str,
    sender_login: &str,
    payload: &Value,
    command_prefix: &str,
) -> Result<Option<WorkItem>> {
    let action = payload
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(action, "created" | "edited") {
        return Ok(None);
    }

    let comment = payload.get("comment").context("missing comment")?;
    let body = comment
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let prompt = strip_prefix_prompt(body, command_prefix)?;
    let Some(prompt) = prompt else {
        return Ok(None);
    };
    let comment_id = comment
        .get("id")
        .and_then(Value::as_u64)
        .context("missing comment.id")?;
    let pull_number = payload
        .get("pull_request")
        .and_then(|v| v.get("number"))
        .and_then(Value::as_u64)
        .context("missing pull_request.number")?;

    Ok(Some(WorkItem {
        repo_full_name: repo_full_name.to_string(),
        sender_login: sender_login.to_string(),
        work: WorkKey {
            owner: owner.to_string(),
            repo: repo.to_string(),
            kind: WorkKind::Pull,
            number: pull_number,
        },
        prompt,
        response_target: ResponseTarget::ReviewCommentReply { comment_id },
    }))
}

fn parse_review(
    owner: &str,
    repo: &str,
    repo_full_name: &str,
    sender_login: &str,
    payload: &Value,
    command_prefix: &str,
) -> Result<Option<WorkItem>> {
    let action = payload
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !matches!(action, "submitted" | "edited") {
        return Ok(None);
    }
    let pull_number = payload
        .get("pull_request")
        .and_then(|v| v.get("number"))
        .and_then(Value::as_u64)
        .context("missing pull_request.number")?;

    let review_body = payload
        .get("review")
        .and_then(|v| v.get("body"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let prompt = strip_prefix_lines(review_body, command_prefix);
    let Some(prompt) = prompt else {
        return Ok(None);
    };

    Ok(Some(WorkItem {
        repo_full_name: repo_full_name.to_string(),
        sender_login: sender_login.to_string(),
        work: WorkKey {
            owner: owner.to_string(),
            repo: repo.to_string(),
            kind: WorkKind::Pull,
            number: pull_number,
        },
        prompt,
        response_target: ResponseTarget::PullRequestReview { pull_number },
    }))
}

fn strip_prefix_prompt(body: &str, prefix: &str) -> Result<Option<String>> {
    let body = body.trim_start();
    let Some(rest) = strip_prefix_with_boundary(body, prefix) else {
        return Ok(None);
    };
    let rest = rest.trim_start();
    if rest.is_empty() {
        return Ok(None);
    }
    Ok(Some(rest.to_string()))
}

fn strip_prefix_lines(body: &str, prefix: &str) -> Option<String> {
    let mut out = Vec::new();
    for line in body.lines() {
        let line = line.trim_start();
        let Some(rest) = strip_prefix_with_boundary(line, prefix) else {
            continue;
        };
        let rest = rest.trim_start();
        if rest.is_empty() {
            continue;
        }
        out.push(rest.to_string());
    }
    if out.is_empty() {
        None
    } else {
        Some(out.join("\n"))
    }
}

fn strip_prefix_with_boundary<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if !s.starts_with(prefix) {
        return None;
    }
    let rest = &s[prefix.len()..];
    if rest.is_empty() {
        return Some(rest);
    }
    rest.chars().next().filter(|c| c.is_whitespace())?;
    Some(rest)
}

async fn process_work_item(
    state: AppState,
    item: WorkItem,
    _permit: tokio::sync::OwnedSemaphorePermit,
) {
    let work_lock = {
        let mut locks = state.work_locks.lock().await;
        locks
            .entry(item.work.clone())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    };
    let _guard = work_lock.lock_owned().await;
    if let Err(err) = process_work_item_inner(&state, &item).await {
        eprintln!("work item failed: {err:#}");
        let _ = post_failure(&state, &item, &format!("{err:#}")).await;
    }
}

async fn process_work_item_inner(state: &AppState, item: &WorkItem) -> Result<()> {
    let work_dir = worktree_path(state, &item.work);
    ensure_repo_and_worktree(state, &item.work, &work_dir).await?;
    let output = run_codex_in_worktree(state, item, &work_dir).await?;
    if let Some(thread_id) = output.thread_id.as_deref() {
        write_thread_id(state, &item.work, thread_id).await?;
    }
    post_success(state, item, &output.last_message).await?;
    Ok(())
}

fn worktree_path(state: &AppState, key: &WorkKey) -> PathBuf {
    state
        .repo_root
        .join(&key.owner)
        .join(&key.repo)
        .join(key.kind.dir_name())
        .join(key.number.to_string())
}

fn clone_path(state: &AppState, key: &WorkKey) -> PathBuf {
    state
        .repo_root
        .join(&key.owner)
        .join(&key.repo)
        .join("repo")
}

async fn repo_lock_for(state: &AppState, owner: &str, repo: &str) -> Arc<Mutex<()>> {
    let mut locks = state.repo_locks.lock().await;
    locks
        .entry(RepoKey {
            owner: owner.to_string(),
            repo: repo.to_string(),
        })
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

async fn touch_repo_markers(state: &AppState, key: &WorkKey) -> Result<()> {
    let repo_parent = state.repo_root.join(&key.owner).join(&key.repo);
    tokio::fs::create_dir_all(&repo_parent)
        .await
        .with_context(|| format!("failed to create {}", repo_parent.display()))?;

    let managed = repo_parent.join(REPO_MANAGED_MARKER_FILENAME);
    let _ = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&managed)
        .await;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let last_used = repo_parent.join(REPO_LAST_USED_FILENAME);
    tokio::fs::write(&last_used, format!("{now}\n"))
        .await
        .with_context(|| format!("failed to write {}", last_used.display()))?;
    Ok(())
}

async fn ensure_repo_and_worktree(state: &AppState, key: &WorkKey, work_dir: &Path) -> Result<()> {
    let repo_dir = clone_path(state, key);
    let repo_lock = repo_lock_for(state, &key.owner, &key.repo).await;
    let _repo_guard = repo_lock.lock().await;

    touch_repo_markers(state, key).await?;
    ensure_clone(state, key, &repo_dir).await?;
    ensure_worktree(state, key, &repo_dir, work_dir).await?;
    Ok(())
}

async fn ensure_clone(state: &AppState, key: &WorkKey, repo_dir: &Path) -> Result<()> {
    if repo_dir.join(".git").exists() {
        run_git(
            repo_dir,
            git_args(&["fetch", "--prune", "origin"]),
            state.github_token.as_str(),
        )
        .await?;
        return Ok(());
    }

    let parent = repo_dir.parent().context("repo dir must have parent")?;
    tokio::fs::create_dir_all(parent)
        .await
        .with_context(|| format!("failed to create {}", parent.display()))?;

    let owner = &key.owner;
    let repo = &key.repo;
    let repo_spec = format!("{owner}/{repo}");
    let mut cmd = tokio::process::Command::new("gh");
    cmd.kill_on_drop(true);
    cmd.current_dir(parent)
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_TOKEN", state.github_token.as_str())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .args(["repo", "clone"])
        .arg(repo_spec)
        .arg(repo_dir)
        .arg("--")
        .arg("--filter=blob:none");
    let gh_result =
        command_output_with_timeout(&mut cmd, parent, git_command_timeout(), "gh repo clone").await;

    match gh_result {
        Ok(TimedCommandOutput::Completed(output)) if output.status.success() => return Ok(()),
        Ok(TimedCommandOutput::Completed(output)) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!("gh repo clone failed for {owner}/{repo}: {stderr}");
        }
        Ok(TimedCommandOutput::TimedOut) => {
            eprintln!("gh repo clone timed out in {}", parent.display())
        }
        Err(err) => eprintln!("gh repo clone failed for {owner}/{repo}: {err:#}"),
    }

    let url = github_clone_url(owner, repo);
    let mut args = git_args(&["clone", "--filter=blob:none"]);
    args.push(url);
    args.push(repo_dir.display().to_string());
    run_git(parent, args, state.github_token.as_str())
        .await
        .context("git clone failed")?;

    Ok(())
}

fn github_clone_url(owner: &str, repo: &str) -> String {
    format!("https://github.com/{owner}/{repo}.git")
}

async fn ensure_worktree(
    state: &AppState,
    key: &WorkKey,
    repo_dir: &Path,
    work_dir: &Path,
) -> Result<()> {
    match tokio::fs::metadata(work_dir).await {
        Ok(meta) => {
            if !meta.is_dir() {
                anyhow::bail!(
                    "existing worktree path is not a directory at {}",
                    work_dir.display()
                );
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(err).with_context(|| format!("failed to stat {}", work_dir.display()));
        }
    }

    if work_dir.exists() {
        let dot_git = work_dir.join(".git");
        let dot_git_meta = tokio::fs::metadata(&dot_git)
            .await
            .with_context(|| format!("existing worktree missing {}", dot_git.display()))?;
        if !dot_git_meta.is_file() {
            anyhow::bail!(
                "existing worktree has invalid .git marker at {}",
                dot_git.display()
            );
        }
        let dot_git_contents = tokio::fs::read_to_string(&dot_git)
            .await
            .with_context(|| format!("failed to read {}", dot_git.display()))?;
        let gitdir_raw = dot_git_contents
            .trim()
            .strip_prefix("gitdir:")
            .map(str::trim)
            .context("worktree .git file missing gitdir")?;
        let gitdir = tokio::fs::canonicalize(gitdir_raw)
            .await
            .with_context(|| format!("failed to resolve gitdir {gitdir_raw}"))?;
        let expected = tokio::fs::canonicalize(repo_dir.join(".git").join("worktrees"))
            .await
            .with_context(|| {
                format!("failed to resolve worktrees dir for {}", repo_dir.display())
            })?;
        if !gitdir.starts_with(&expected) {
            anyhow::bail!(
                "existing worktree gitdir {} is not under {}",
                gitdir.display(),
                expected.display()
            );
        }
        return Ok(());
    }

    let branch = format!("codex/github/{}-{}", key.kind.label(), key.number);

    match key.kind {
        WorkKind::Issue => {
            let default_branch = state
                .github
                .repo_default_branch(&key.owner, &key.repo)
                .await?;
            let base = format!("origin/{default_branch}");
            let mut args = git_args(&["worktree", "add", "-B"]);
            args.push(branch);
            args.push(work_dir.display().to_string());
            args.push(base);
            run_git(repo_dir, args, state.github_token.as_str()).await?;
        }
        WorkKind::Pull => {
            let refspec = format!("pull/{}/head:{}", key.number, branch);
            run_git(
                repo_dir,
                vec!["fetch".to_string(), "origin".to_string(), refspec],
                state.github_token.as_str(),
            )
            .await?;
            let mut args = git_args(&["worktree", "add"]);
            args.push(work_dir.display().to_string());
            args.push(branch);
            run_git(repo_dir, args, state.github_token.as_str()).await?;
        }
    }

    Ok(())
}

fn git_args(args: &[&str]) -> Vec<String> {
    args.iter().map(ToString::to_string).collect()
}

fn github_git_auth_header(token: &str) -> String {
    let encoded = BASE64_STANDARD.encode(format!("x-access-token:{token}"));
    format!("Authorization: basic {encoded}")
}

fn git_needs_auth(args: &[String]) -> bool {
    matches!(args.first().map(String::as_str), Some("clone" | "fetch"))
}

enum TimedCommandOutput {
    Completed(std::process::Output),
    TimedOut,
}

async fn command_output_with_timeout(
    cmd: &mut tokio::process::Command,
    cwd: &Path,
    timeout: Duration,
    label: &str,
) -> Result<TimedCommandOutput> {
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd
        .spawn()
        .with_context(|| format!("failed to run {label} in {}", cwd.display()))?;
    let mut stdout = child.stdout.take().context("child stdout missing")?;
    let mut stderr = child.stderr.take().context("child stderr missing")?;
    let stdout_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        stdout.read_to_end(&mut buf).await.map(|_| buf)
    });
    let stderr_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        stderr.read_to_end(&mut buf).await.map(|_| buf)
    });

    let status = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(status) => {
            status.with_context(|| format!("failed to run {label} in {}", cwd.display()))?
        }
        Err(_) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            let _ = stdout_task.await;
            let _ = stderr_task.await;
            return Ok(TimedCommandOutput::TimedOut);
        }
    };

    let stdout = stdout_task.await.context("failed to join stdout task")??;
    let stderr = stderr_task.await.context("failed to join stderr task")??;
    Ok(TimedCommandOutput::Completed(std::process::Output {
        status,
        stdout,
        stderr,
    }))
}

async fn run_git(cwd: &Path, args: Vec<String>, github_token: &str) -> Result<()> {
    let mut cmd = tokio::process::Command::new("git");
    cmd.kill_on_drop(true);
    cmd.current_dir(cwd)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C");
    if git_needs_auth(&args) {
        cmd.arg("-c").arg(format!(
            "http.extraHeader={}",
            github_git_auth_header(github_token)
        ));
    }
    cmd.args(args);
    let output =
        match command_output_with_timeout(&mut cmd, cwd, GIT_COMMAND_TIMEOUT, "git").await? {
            TimedCommandOutput::Completed(output) => output,
            TimedCommandOutput::TimedOut => anyhow::bail!("git timed out in {}", cwd.display()),
        };
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git failed: {stderr}");
    }
}

#[derive(Debug)]
struct CodexOutput {
    thread_id: Option<String>,
    last_message: String,
}

struct FetchedGithubContext {
    title: String,
    markdown: String,
}

async fn fetch_github_context(github: &GithubApi, key: &WorkKey) -> Result<FetchedGithubContext> {
    match key.kind {
        WorkKind::Issue => fetch_issue_context(github, key).await,
        WorkKind::Pull => fetch_pull_context(github, key).await,
    }
}

async fn fetch_issue_context(github: &GithubApi, key: &WorkKey) -> Result<FetchedGithubContext> {
    let owner = key.owner.as_str();
    let repo = key.repo.as_str();
    let number = key.number;
    let issue_url = format!("{}/repos/{owner}/{repo}/issues/{number}", github.base_url);
    let issue = github.get_json_value(issue_url).await?;

    let comments_url = format!(
        "{}/repos/{owner}/{repo}/issues/{number}/comments",
        github.base_url
    );
    let comments = github.list_paginated(comments_url).await?;

    Ok(format_issue_context(key, &issue, &comments))
}

async fn fetch_pull_context(github: &GithubApi, key: &WorkKey) -> Result<FetchedGithubContext> {
    let owner = key.owner.as_str();
    let repo = key.repo.as_str();
    let number = key.number;

    let pr_url = format!("{}/repos/{owner}/{repo}/pulls/{number}", github.base_url);
    let pr = github.get_json_value(pr_url).await?;

    let issue_comments_url = format!(
        "{}/repos/{owner}/{repo}/issues/{number}/comments",
        github.base_url
    );
    let issue_comments = github.list_paginated(issue_comments_url).await?;

    let review_comments_url = format!(
        "{}/repos/{owner}/{repo}/pulls/{number}/comments",
        github.base_url
    );
    let review_comments = github.list_paginated(review_comments_url).await?;

    let reviews_url = format!(
        "{}/repos/{owner}/{repo}/pulls/{number}/reviews",
        github.base_url
    );
    let reviews = github.list_paginated(reviews_url).await?;

    Ok(format_pull_context(
        key,
        &pr,
        &issue_comments,
        &review_comments,
        &reviews,
    ))
}

fn format_issue_context(key: &WorkKey, issue: &Value, comments: &[Value]) -> FetchedGithubContext {
    let title = json_str(issue, "title").to_string();
    let url = json_str(issue, "html_url");
    let author = json_user_login(issue);
    let state = json_str(issue, "state");
    let created_at = json_str(issue, "created_at");
    let updated_at = json_str(issue, "updated_at");
    let body = json_str(issue, "body");

    let mut out = String::new();
    out.push_str(&format!(
        "# Issue {}/{}#{number}\n\n",
        key.owner,
        key.repo,
        number = key.number
    ));
    if !title.is_empty() {
        out.push_str(&format!("Title: {title}\n"));
    }
    if !url.is_empty() {
        out.push_str(&format!("URL: {url}\n"));
    }
    if !author.is_empty() {
        out.push_str(&format!("Author: @{author}\n"));
    }
    if !state.is_empty() {
        out.push_str(&format!("State: {state}\n"));
    }
    if !created_at.is_empty() {
        out.push_str(&format!("Created: {created_at}\n"));
    }
    if !updated_at.is_empty() {
        out.push_str(&format!("Updated: {updated_at}\n"));
    }

    out.push_str("\n## Body\n\n");
    out.push_str(body);
    out.push('\n');

    out.push_str(&format!("\n## Comments ({})\n\n", comments.len()));
    for comment in comments {
        format_issue_comment(&mut out, comment);
    }

    FetchedGithubContext {
        title,
        markdown: out,
    }
}

fn format_pull_context(
    key: &WorkKey,
    pr: &Value,
    issue_comments: &[Value],
    review_comments: &[Value],
    reviews: &[Value],
) -> FetchedGithubContext {
    let title = json_str(pr, "title").to_string();
    let url = json_str(pr, "html_url");
    let author = json_user_login(pr);
    let state = json_str(pr, "state");
    let created_at = json_str(pr, "created_at");
    let updated_at = json_str(pr, "updated_at");
    let body = json_str(pr, "body");
    let base_ref = pr
        .get("base")
        .and_then(|v| v.get("ref"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let head_ref = pr
        .get("head")
        .and_then(|v| v.get("ref"))
        .and_then(Value::as_str)
        .unwrap_or_default();

    let mut out = String::new();
    out.push_str(&format!(
        "# Pull Request {}/{}#{number}\n\n",
        key.owner,
        key.repo,
        number = key.number
    ));
    if !title.is_empty() {
        out.push_str(&format!("Title: {title}\n"));
    }
    if !url.is_empty() {
        out.push_str(&format!("URL: {url}\n"));
    }
    if !author.is_empty() {
        out.push_str(&format!("Author: @{author}\n"));
    }
    if !state.is_empty() {
        out.push_str(&format!("State: {state}\n"));
    }
    if !created_at.is_empty() {
        out.push_str(&format!("Created: {created_at}\n"));
    }
    if !updated_at.is_empty() {
        out.push_str(&format!("Updated: {updated_at}\n"));
    }
    if !base_ref.is_empty() || !head_ref.is_empty() {
        out.push_str(&format!("Branch: {head_ref} -> {base_ref}\n"));
    }

    out.push_str("\n## Body\n\n");
    out.push_str(body);
    out.push('\n');

    out.push_str(&format!(
        "\n## Issue comments ({})\n\n",
        issue_comments.len()
    ));
    for comment in issue_comments {
        format_issue_comment(&mut out, comment);
    }

    out.push_str(&format!(
        "\n## Review comments ({})\n\n",
        review_comments.len()
    ));
    for comment in review_comments {
        format_review_comment(&mut out, comment);
    }

    out.push_str(&format!("\n## Reviews ({})\n\n", reviews.len()));
    for review in reviews {
        format_review(&mut out, review);
    }

    FetchedGithubContext {
        title,
        markdown: out,
    }
}

fn format_issue_comment(out: &mut String, comment: &Value) {
    let id = comment
        .get("id")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let url = json_str(comment, "html_url");
    let author = json_user_login(comment);
    let created_at = json_str(comment, "created_at");
    let updated_at = json_str(comment, "updated_at");
    let body = json_str(comment, "body");

    out.push_str(&format!("---\nComment id: {id}\n"));
    if !url.is_empty() {
        out.push_str(&format!("URL: {url}\n"));
    }
    if !author.is_empty() {
        out.push_str(&format!("Author: @{author}\n"));
    }
    if !created_at.is_empty() {
        out.push_str(&format!("Created: {created_at}\n"));
    }
    if !updated_at.is_empty() {
        out.push_str(&format!("Updated: {updated_at}\n"));
    }
    out.push('\n');
    out.push_str(body);
    out.push_str("\n\n");
}

fn format_review_comment(out: &mut String, comment: &Value) {
    let id = comment
        .get("id")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let url = json_str(comment, "html_url");
    let author = json_user_login(comment);
    let created_at = json_str(comment, "created_at");
    let updated_at = json_str(comment, "updated_at");
    let body = json_str(comment, "body");
    let path = json_str(comment, "path");
    let line = comment
        .get("line")
        .and_then(Value::as_u64)
        .unwrap_or_default();

    out.push_str(&format!("---\nReview comment id: {id}\n"));
    if !url.is_empty() {
        out.push_str(&format!("URL: {url}\n"));
    }
    if !author.is_empty() {
        out.push_str(&format!("Author: @{author}\n"));
    }
    if !created_at.is_empty() {
        out.push_str(&format!("Created: {created_at}\n"));
    }
    if !updated_at.is_empty() {
        out.push_str(&format!("Updated: {updated_at}\n"));
    }
    if !path.is_empty() {
        out.push_str(&format!("Path: {path}\n"));
    }
    if line != 0 {
        out.push_str(&format!("Line: {line}\n"));
    }
    out.push('\n');
    out.push_str(body);
    out.push_str("\n\n");
}

fn format_review(out: &mut String, review: &Value) {
    let id = review.get("id").and_then(Value::as_u64).unwrap_or_default();
    let url = json_str(review, "html_url");
    let author = json_user_login(review);
    let state = json_str(review, "state");
    let submitted_at = json_str(review, "submitted_at");
    let body = json_str(review, "body");

    out.push_str(&format!("---\nReview id: {id}\n"));
    if !url.is_empty() {
        out.push_str(&format!("URL: {url}\n"));
    }
    if !author.is_empty() {
        out.push_str(&format!("Author: @{author}\n"));
    }
    if !state.is_empty() {
        out.push_str(&format!("State: {state}\n"));
    }
    if !submitted_at.is_empty() {
        out.push_str(&format!("Submitted: {submitted_at}\n"));
    }
    out.push('\n');
    out.push_str(body);
    out.push_str("\n\n");
}

fn json_str<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn json_user_login(v: &Value) -> &str {
    v.get("user")
        .and_then(|u| u.get("login"))
        .and_then(Value::as_str)
        .unwrap_or_default()
}

async fn run_codex_in_worktree(
    state: &AppState,
    item: &WorkItem,
    work_dir: &Path,
) -> Result<CodexOutput> {
    let thread_id = read_thread_id(state, &item.work).await?;

    let tempdir = tempfile::tempdir().context("failed to create temp dir")?;
    let last_message_path = tempdir.path().join("last_message.txt");
    let context_path = work_dir.join(GITHUB_CONTEXT_FILENAME);
    let (context_title, context_note) =
        match fetch_github_context(state.github.as_ref(), &item.work).await {
            Ok(ctx) => {
                if let Err(err) = tokio::fs::write(&context_path, ctx.markdown).await {
                    eprintln!("failed to write {}: {err:#}", context_path.display());
                    (
                        ctx.title,
                        "Context: (failed to write context file)\n".to_string(),
                    )
                } else {
                    (ctx.title, format!("Context: {GITHUB_CONTEXT_FILENAME}\n"))
                }
            }
            Err(err) => {
                eprintln!("failed to fetch GitHub context: {err:#}");
                let _ = tokio::fs::write(
                    &context_path,
                    format!("# GitHub context fetch failed\n\n{err:#}\n"),
                )
                .await;
                (
                    String::new(),
                    format!("Context: {GITHUB_CONTEXT_FILENAME} (fetch failed)\n"),
                )
            }
        };

    let title_line = if context_title.is_empty() {
        String::new()
    } else {
        format!("Title: {context_title}\n")
    };
    let prompt = format!(
        "GitHub {kind} event for {repo_full_name}#{number} from @{sender}.\n{title_line}{context_note}\nCommand:\n{command}\n\nRead {GITHUB_CONTEXT_FILENAME} first, then do the command.",
        kind = item.work.kind.label(),
        repo_full_name = item.repo_full_name.as_str(),
        number = item.work.number,
        sender = item.sender_login.as_str(),
        command = item.prompt.as_str()
    );

    let mut cmd = tokio::process::Command::new(state.codex_bin.as_ref());
    for ov in state.codex_config_overrides.iter() {
        cmd.arg("-c").arg(ov);
    }
    cmd.arg("exec")
        .arg("--json")
        .arg("-C")
        .arg(work_dir)
        .arg("-o")
        .arg(&last_message_path)
        .arg("--skip-git-repo-check");

    if let Some(thread_id) = &thread_id {
        cmd.arg("resume").arg(thread_id);
    }

    cmd.arg(prompt);

    cmd.kill_on_drop(true);
    let mut child = cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .context("failed to spawn codex exec")?;

    let stdout = child.stdout.take().context("missing stdout")?;
    let mut reader = tokio::io::BufReader::new(stdout).lines();
    let mut observed_thread_id: Option<String> = None;
    let mut stdout_closed = false;
    let mut exit_status = None;
    let deadline = tokio::time::sleep(CODEX_EXEC_TIMEOUT);
    tokio::pin!(deadline);

    while exit_status.is_none() || !stdout_closed {
        tokio::select! {
            _ = &mut deadline => {
                let _ = child.kill().await;
                anyhow::bail!("codex exec timed out");
            }
            line = reader.next_line(), if !stdout_closed => {
                let line = line.context("failed to read codex exec stdout")?;
                match line {
                    Some(line) => {
                        if observed_thread_id.is_none()
                            && let Ok(v) = serde_json::from_str::<Value>(&line)
                                && v.get("type").and_then(Value::as_str) == Some("thread.started")
                                && let Some(id) = v.get("thread_id").and_then(Value::as_str)
                            {
                                observed_thread_id = Some(id.to_string());
                            }
                    }
                    None => stdout_closed = true,
                }
            }
            status = child.wait(), if exit_status.is_none() => {
                exit_status = Some(status.context("failed to wait for codex exec")?);
            }
        }
    }

    let status = exit_status.context("missing codex exec exit status")?;
    if !status.success() {
        anyhow::bail!("codex exec failed ({status})");
    }

    let last_message = tokio::fs::read_to_string(&last_message_path)
        .await
        .with_context(|| format!("failed to read {}", last_message_path.display()))?;
    if last_message.trim().is_empty() {
        anyhow::bail!(
            "codex exec did not write output to {}",
            last_message_path.display()
        );
    }
    Ok(CodexOutput {
        thread_id: observed_thread_id,
        last_message: truncate_for_github(&last_message),
    })
}

fn truncate_for_github(s: &str) -> String {
    const LIMIT: usize = 60_000;
    if s.len() <= LIMIT {
        return s.to_string();
    }
    let mut end = LIMIT;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n\n[truncated]", &s[..end])
}

async fn read_thread_id(state: &AppState, key: &WorkKey) -> Result<Option<String>> {
    let path = thread_id_path(state, key);
    let content = match tokio::fs::read_to_string(&path).await {
        Ok(s) => s,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).context("failed to read thread id file"),
    };
    let trimmed = content.trim();
    if trimmed.is_empty() {
        Ok(None)
    } else {
        Ok(Some(trimmed.to_string()))
    }
}

async fn write_thread_id(state: &AppState, key: &WorkKey, thread_id: &str) -> Result<()> {
    let path = thread_id_path(state, key);
    let dir = path.parent().context("thread id path must have parent")?;
    tokio::fs::create_dir_all(dir)
        .await
        .with_context(|| format!("failed to create {}", dir.display()))?;
    tokio::fs::write(&path, thread_id)
        .await
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn thread_id_path(state: &AppState, key: &WorkKey) -> PathBuf {
    state
        .thread_state_dir
        .join(&key.owner)
        .join(&key.repo)
        .join(key.kind.dir_name())
        .join(format!("{}.txt", key.number))
}

async fn post_success(state: &AppState, item: &WorkItem, message: &str) -> Result<()> {
    let owner = item.work.owner.as_str();
    let repo = item.work.repo.as_str();
    match item.response_target {
        ResponseTarget::IssueComment { issue_number } => {
            state
                .github
                .post_issue_comment(owner, repo, issue_number, message)
                .await?;
        }
        ResponseTarget::ReviewCommentReply { comment_id } => {
            state
                .github
                .post_review_comment_reply(owner, repo, comment_id, message)
                .await?;
        }
        ResponseTarget::PullRequestReview { pull_number } => {
            state
                .github
                .create_pr_review(owner, repo, pull_number, message)
                .await?;
        }
    }
    Ok(())
}

async fn post_failure(state: &AppState, item: &WorkItem, err: &str) -> Result<()> {
    let body = truncate_for_github(&format!("codex github failed:\n\n{err}"));
    post_success(state, item, &body).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::Query;
    use pretty_assertions::assert_eq;
    use serde_json::json;
    use std::collections::HashMap;
    use std::path::Path;
    use std::sync::OnceLock;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;

    #[cfg(unix)]
    static ENV_MUTEX: OnceLock<std::sync::Mutex<()>> = OnceLock::new();

    #[cfg(unix)]
    struct PathGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        previous: Option<std::ffi::OsString>,
    }

    #[cfg(unix)]
    impl PathGuard {
        fn prepend(dir: &Path) -> Self {
            let lock = ENV_MUTEX
                .get_or_init(|| std::sync::Mutex::new(()))
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let previous = std::env::var_os("PATH");
            let mut next = std::ffi::OsString::new();
            next.push(dir.as_os_str());
            if let Some(prev) = previous.as_ref() {
                next.push(":");
                next.push(prev);
            }
            // set_var/remove_var are unsafe because mutating the process env is racy; we serialize
            // all env mutations in tests via ENV_MUTEX.
            unsafe {
                std::env::set_var("PATH", next);
            }
            Self {
                _lock: lock,
                previous,
            }
        }
    }

    #[cfg(unix)]
    impl Drop for PathGuard {
        fn drop(&mut self) {
            unsafe {
                match self.previous.as_ref() {
                    Some(prev) => std::env::set_var("PATH", prev),
                    None => std::env::remove_var("PATH"),
                }
            }
        }
    }

    #[cfg(unix)]
    struct EnvSnapshot {
        _lock: std::sync::MutexGuard<'static, ()>,
        previous: Vec<(String, Option<std::ffi::OsString>)>,
    }

    #[cfg(unix)]
    impl EnvSnapshot {
        fn set(vars: &[(&str, &str)]) -> Self {
            let lock = ENV_MUTEX
                .get_or_init(|| std::sync::Mutex::new(()))
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut previous = Vec::with_capacity(vars.len());
            for (k, v) in vars {
                previous.push(((*k).to_string(), std::env::var_os(k)));
                unsafe {
                    std::env::set_var(k, v);
                }
            }
            Self {
                _lock: lock,
                previous,
            }
        }
    }

    #[cfg(unix)]
    impl Drop for EnvSnapshot {
        fn drop(&mut self) {
            for (k, prev) in self.previous.iter() {
                unsafe {
                    match prev {
                        Some(v) => std::env::set_var(k, v),
                        None => std::env::remove_var(k),
                    }
                }
            }
        }
    }

    #[cfg(unix)]
    fn write_exe(path: &Path, contents: &str) {
        use std::os::unix::fs::PermissionsExt;

        std::fs::write(path, contents).expect("write script");
        let mut perms = std::fs::metadata(path)
            .expect("script metadata")
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms).expect("chmod");
    }

    fn test_state(temp: &tempfile::TempDir) -> AppState {
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .expect("create github api");
        AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new(DEFAULT_COMMAND_PREFIX.to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn spawn_test_server(
        listener: TcpListener,
        app: Router,
    ) -> tokio::task::JoinHandle<std::io::Result<()>> {
        tokio::spawn(async move {
            let _ = axum::serve(listener, app.into_make_service()).await;
            Ok(())
        })
    }

    #[cfg(unix)]
    #[test]
    fn env_snapshot_restores_existing_variable() {
        unsafe {
            std::env::set_var("CODEX_GITHUB_TEST_ENV", "before");
        }
        {
            let _snapshot = EnvSnapshot::set(&[("CODEX_GITHUB_TEST_ENV", "after")]);
            assert_eq!(std::env::var("CODEX_GITHUB_TEST_ENV").unwrap(), "after");
        }
        assert_eq!(std::env::var("CODEX_GITHUB_TEST_ENV").unwrap(), "before");
        unsafe {
            std::env::remove_var("CODEX_GITHUB_TEST_ENV");
        }
    }

    #[cfg(unix)]
    #[test]
    fn path_guard_restores_missing_path() {
        let lock = ENV_MUTEX
            .get_or_init(|| std::sync::Mutex::new(()))
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let previous = std::env::var_os("PATH");
        unsafe {
            std::env::remove_var("PATH");
        }
        drop(lock);

        let temp = tempfile::tempdir().unwrap();
        drop(PathGuard::prepend(temp.path()));
        assert_eq!(std::env::var_os("PATH"), None);

        if let Some(previous) = previous {
            let lock = ENV_MUTEX
                .get_or_init(|| std::sync::Mutex::new(()))
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            unsafe {
                std::env::set_var("PATH", previous);
            }
            drop(lock);
        }
    }

    #[test]
    fn decode_hex_rejects_odd_length() {
        assert_eq!(decode_hex("0"), None);
    }

    #[test]
    fn decode_hex_rejects_invalid_chars() {
        assert_eq!(decode_hex("xx"), None);
    }

    #[test]
    fn decode_hex_accepts_uppercase() {
        assert_eq!(decode_hex("0A").as_deref(), Some(&[0x0a_u8][..]));
    }

    #[test]
    fn verify_github_signature_accepts_valid_signature() {
        let secret = b"sekrit";
        let body = b"hello world";

        let header = signature_header(secret, body);
        assert!(verify_github_signature(secret, body, Some(&header)));
    }

    #[test]
    fn verify_github_signature_rejects_wrong_prefix() {
        let secret = b"sekrit";
        let body = b"hello world";
        let header = HeaderValue::from_static("sha1=deadbeef");
        assert!(!verify_github_signature(secret, body, Some(&header)));
    }

    #[test]
    fn verify_github_signature_rejects_invalid_hex() {
        let secret = b"sekrit";
        let body = b"hello world";
        let header = HeaderValue::from_static("sha256=not-hex");
        assert!(!verify_github_signature(secret, body, Some(&header)));
    }

    #[test]
    fn github_command_defaults_to_github_env_vars() {
        let cmd = <GithubCommand as clap::Parser>::try_parse_from(["github"].as_ref())
            .expect("parse should succeed");
        assert_eq!(cmd.webhook_secret_env, DEFAULT_WEBHOOK_SECRET_ENV);
        assert_eq!(cmd.github_token_env, DEFAULT_GITHUB_TOKEN_ENV);
    }

    #[test]
    fn github_clone_url_uses_standard_https() {
        assert_eq!(github_clone_url("o", "r"), "https://github.com/o/r.git");
    }

    #[test]
    fn github_git_auth_header_uses_basic_auth() {
        assert_eq!(
            github_git_auth_header("t"),
            "Authorization: basic eC1hY2Nlc3MtdG9rZW46dA=="
        );
    }

    #[test]
    fn ttl_from_days_disables_on_zero() {
        assert_eq!(ttl_from_days(0), None);
        assert_eq!(ttl_from_days(1), Some(Duration::from_secs(24 * 60 * 60)));
    }

    #[test]
    fn min_permission_allows_rejects_unknown_permission() {
        assert_eq!(MinPermission::Read.allows("nope"), false);
        assert_eq!(permission_rank("nope"), None);
    }

    #[test]
    fn work_kind_dir_name_and_label_are_distinct() {
        assert_eq!(WorkKind::Issue.dir_name(), "issues");
        assert_eq!(WorkKind::Pull.dir_name(), "pulls");
        assert_eq!(WorkKind::Issue.label(), "issue");
        assert_eq!(WorkKind::Pull.label(), "pull");
    }

    #[test]
    fn github_api_new_rejects_invalid_token_header_value() {
        let err = GithubApi::new("bad\ntoken".to_string()).err().unwrap();
        assert!(format!("{err:#}").contains("invalid GitHub token"));
    }

    #[tokio::test]
    async fn repo_permission_errors_on_empty_permission() {
        let app = Router::new().route(
            "/repos/o/r/collaborators/u/permission",
            get(|| async { axum::Json(json!({ "permission": "" })) }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let err = github.repo_permission("o", "r", "u").await.unwrap_err();
        assert!(format!("{err:#}").contains("empty permission"));

        server.abort();
    }

    #[tokio::test]
    async fn repo_default_branch_errors_on_non_success() {
        let app = Router::new().route(
            "/repos/o/r",
            get(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "no") }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let err = github.repo_default_branch("o", "r").await.unwrap_err();
        assert!(format!("{err:#}").contains("repo API failed"));

        server.abort();
    }

    #[tokio::test]
    async fn repo_default_branch_errors_on_empty_default_branch() {
        let app = Router::new().route(
            "/repos/o/r",
            get(|| async { axum::Json(json!({ "default_branch": "" })) }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let err = github.repo_default_branch("o", "r").await.unwrap_err();
        assert!(format!("{err:#}").contains("empty default_branch"));

        server.abort();
    }

    #[tokio::test]
    async fn get_json_vec_errors_on_non_success() {
        let app = Router::new().route("/v", get(|| async { (StatusCode::BAD_REQUEST, "no") }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let url = format!("http://{addr}/v");
        let err = github.get_json_vec(url).await.unwrap_err();
        assert!(format!("{err:#}").contains("GitHub API failed"));

        server.abort();
    }

    #[tokio::test]
    async fn list_paginated_errors_when_exceeding_max_pages() {
        let app = Router::new().route(
            "/v",
            get(|| async { axum::Json(vec![Value::Null; GITHUB_API_PER_PAGE]) }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let url_base = format!("http://{addr}/v");
        let err = github.list_paginated(url_base).await.unwrap_err();
        assert!(format!("{err:#}").contains("pagination exceeded max pages"));

        server.abort();
    }

    #[tokio::test]
    async fn post_issue_comment_errors_on_non_success() {
        let app = Router::new().route(
            "/repos/o/r/issues/1/comments",
            post(|| async { (StatusCode::BAD_REQUEST, "no") }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let err = github
            .post_issue_comment("o", "r", 1, "hi")
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("GitHub API failed"));

        server.abort();
    }

    #[test]
    fn parse_issue_comment_requires_prefix() {
        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 32 },
            "comment": { "body": "hello" }
        });
        let item = parse_work_item("issue_comment", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn parse_issue_comment_ignores_unknown_action() {
        let payload = serde_json::json!({
            "action": "deleted",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 32 },
            "comment": { "body": "/codex hi" }
        });
        let item = parse_work_item("issue_comment", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn command_prefix_requires_boundary() {
        assert_eq!(strip_prefix_prompt("/codexx hi", "/codex").unwrap(), None);
        assert_eq!(
            strip_prefix_prompt(" /codex hi", "/codex").unwrap(),
            Some("hi".to_string())
        );
    }

    #[test]
    fn strip_prefix_prompt_rejects_empty_prompt() {
        assert_eq!(strip_prefix_prompt("/codex   ", "/codex").unwrap(), None);
    }

    #[test]
    fn review_prefix_requires_boundary() {
        assert_eq!(
            strip_prefix_lines("/codexx no\n/codex yes", "/codex"),
            Some("yes".to_string())
        );
    }

    #[test]
    fn strip_prefix_lines_skips_empty_and_returns_none() {
        assert_eq!(strip_prefix_lines("/codex\n/codex   \n", "/codex"), None);
    }

    #[test]
    fn strip_prefix_with_boundary_allows_exact_prefix() {
        assert_eq!(strip_prefix_with_boundary("/codex", "/codex"), Some(""));
    }

    #[test]
    fn parse_issue_comment_on_pr_maps_to_pull_worktree() {
        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 32, "pull_request": { "url": "x" } },
            "comment": { "body": "/codex fix it" }
        });
        let item = parse_work_item("issue_comment", &payload, "/codex")
            .unwrap()
            .unwrap();
        assert_eq!(item.work.kind, WorkKind::Pull);
        assert_eq!(item.work.number, 32);
        assert_eq!(item.prompt, "fix it");
    }

    #[test]
    fn parse_review_comment_ignores_unknown_action() {
        let payload = serde_json::json!({
            "action": "deleted",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "comment": { "id": 123, "body": "/codex reply please" }
        });
        let item = parse_work_item("pull_request_review_comment", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn parse_review_comment_requires_prefix() {
        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "comment": { "id": 123, "body": "hello" }
        });
        let item = parse_work_item("pull_request_review_comment", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn parse_review_body_scans_multiple_lines() {
        let payload = serde_json::json!({
            "action": "submitted",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "review": { "body": "hi\n/codex do a\n/codex do b\nbye" }
        });
        let item = parse_work_item("pull_request_review", &payload, "/codex")
            .unwrap()
            .unwrap();
        assert_eq!(item.prompt, "do a\ndo b");
    }

    #[test]
    fn parse_review_ignores_unknown_action() {
        let payload = serde_json::json!({
            "action": "dismissed",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "review": { "body": "/codex hi" }
        });
        let item = parse_work_item("pull_request_review", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn parse_review_requires_prefix() {
        let payload = serde_json::json!({
            "action": "submitted",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "review": { "body": "hello" }
        });
        let item = parse_work_item("pull_request_review", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn parse_review_comment_extracts_ids() {
        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "pull_request": { "number": 7 },
            "comment": { "id": 123, "body": "/codex reply please" }
        });
        let item = parse_work_item("pull_request_review_comment", &payload, "/codex")
            .unwrap()
            .unwrap();
        assert_eq!(item.work.kind, WorkKind::Pull);
        assert_eq!(item.work.number, 7);
        assert_eq!(item.prompt, "reply please");
        match item.response_target {
            ResponseTarget::ReviewCommentReply { comment_id } => assert_eq!(comment_id, 123),
            other => panic!("unexpected response target: {other:?}"),
        }
    }

    #[test]
    fn parse_work_item_ignores_unknown_event_without_repo_fields() {
        let payload = serde_json::json!({ "some": "thing" });
        let item = parse_work_item("push", &payload, "/codex").unwrap();
        assert_eq!(item.is_none(), true);
    }

    #[test]
    fn min_permission_ranking_is_monotonic() {
        assert_eq!(MinPermission::Write.allows("read"), false);
        assert_eq!(MinPermission::Write.allows("write"), true);
        assert_eq!(MinPermission::Write.allows("maintain"), true);
    }

    #[test]
    fn min_permission_allows_covers_variants() {
        assert_eq!(MinPermission::Read.allows("read"), true);
        assert_eq!(MinPermission::Maintain.allows("admin"), true);
        assert_eq!(MinPermission::Admin.allows("admin"), true);
    }

    #[test]
    fn repo_allowed_normalizes_case() {
        let allow = normalize_allowlist(&["O/R".to_string()]);
        assert_eq!(repo_allowed(&allow, "o/r"), true);
        assert_eq!(repo_allowed(&allow, "O/R"), true);
        assert_eq!(repo_allowed(&allow, "x/y"), false);
    }

    #[test]
    fn split_owner_repo_rejects_unsafe_components() {
        assert!(split_owner_repo("../x").is_err());
        assert!(split_owner_repo("x/..").is_err());
        assert!(split_owner_repo("x/y").is_ok());
    }

    #[tokio::test]
    async fn claim_delivery_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(claim_delivery(dir.path(), "abc").await.unwrap(), true);
        assert_eq!(claim_delivery(dir.path(), "abc").await.unwrap(), false);
    }

    #[tokio::test]
    async fn claim_delivery_errors_when_marker_path_is_directory() {
        let dir = tempfile::tempdir().unwrap();
        let marker_root = dir.path().join("markers");
        tokio::fs::write(&marker_root, "not-a-dir").await.unwrap();
        let err = claim_delivery(&marker_root, "x").await.unwrap_err();
        assert!(format!("{err:#}").contains("delivery markers dir"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn claim_delivery_surfaces_marker_create_error() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let marker_root = dir.path().join("markers");
        tokio::fs::create_dir_all(&marker_root).await.unwrap();
        let mut perms = std::fs::metadata(&marker_root).unwrap().permissions();
        perms.set_mode(0o555);
        std::fs::set_permissions(&marker_root, perms).unwrap();

        let err = claim_delivery(&marker_root, "x").await.unwrap_err();
        assert!(format!("{err:#}").contains("failed to create delivery marker file"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_main_with_shutdown_serves_healthz() {
        let temp = tempfile::tempdir().unwrap();
        let _env = EnvSnapshot::set(&[
            ("CODEX_HOME", temp.path().to_str().unwrap()),
            (DEFAULT_WEBHOOK_SECRET_ENV, "sekrit"),
            (DEFAULT_GITHUB_TOKEN_ENV, "t"),
        ]);

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);

        let cmd = GithubCommand {
            listen: addr,
            webhook_secret_env: DEFAULT_WEBHOOK_SECRET_ENV.to_string(),
            github_token_env: DEFAULT_GITHUB_TOKEN_ENV.to_string(),
            min_permission: MinPermission::Triage,
            allow_repo: Vec::new(),
            command_prefix: DEFAULT_COMMAND_PREFIX.to_string(),
            delivery_ttl_days: 0,
            repo_ttl_days: 0,
        };

        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            run_main_with_shutdown(cmd, CliConfigOverrides::default(), async move {
                let _ = rx.await;
            })
            .await
        });

        let url = format!("http://{addr}/healthz");
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(res) = reqwest::get(&url).await
                    && res.status() == StatusCode::OK
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();

        let _ = tx.send(());
        server.await.unwrap().unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_main_with_shutdown_spawns_gc_when_ttl_enabled() {
        let temp = tempfile::tempdir().unwrap();
        let _env = EnvSnapshot::set(&[
            ("CODEX_HOME", temp.path().to_str().unwrap()),
            (DEFAULT_WEBHOOK_SECRET_ENV, "sekrit"),
            (DEFAULT_GITHUB_TOKEN_ENV, "t"),
        ]);

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);

        let cmd = GithubCommand {
            listen: addr,
            webhook_secret_env: DEFAULT_WEBHOOK_SECRET_ENV.to_string(),
            github_token_env: DEFAULT_GITHUB_TOKEN_ENV.to_string(),
            min_permission: MinPermission::Triage,
            allow_repo: Vec::new(),
            command_prefix: DEFAULT_COMMAND_PREFIX.to_string(),
            delivery_ttl_days: 1,
            repo_ttl_days: 0,
        };

        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            run_main_with_shutdown(cmd, CliConfigOverrides::default(), async move {
                let _ = rx.await;
            })
            .await
        });

        let url = format!("http://{addr}/healthz");
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(res) = reqwest::get(&url).await
                    && res.status() == StatusCode::OK
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();

        let _ = tx.send(());
        server.await.unwrap().unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_main_with_shutdown_errors_when_env_missing() {
        let temp = tempfile::tempdir().unwrap();
        let _env = EnvSnapshot::set(&[("CODEX_HOME", temp.path().to_str().unwrap())]);
        unsafe {
            std::env::remove_var(DEFAULT_WEBHOOK_SECRET_ENV);
            std::env::remove_var(DEFAULT_GITHUB_TOKEN_ENV);
        }

        let cmd = GithubCommand {
            listen: DEFAULT_LISTEN_ADDR.parse().unwrap(),
            webhook_secret_env: DEFAULT_WEBHOOK_SECRET_ENV.to_string(),
            github_token_env: DEFAULT_GITHUB_TOKEN_ENV.to_string(),
            min_permission: MinPermission::Triage,
            allow_repo: Vec::new(),
            command_prefix: DEFAULT_COMMAND_PREFIX.to_string(),
            delivery_ttl_days: 0,
            repo_ttl_days: 0,
        };

        let err = run_main_with_shutdown(cmd, CliConfigOverrides::default(), async {})
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains(DEFAULT_WEBHOOK_SECRET_ENV));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_main_with_shutdown_errors_when_env_empty() {
        let temp = tempfile::tempdir().unwrap();
        let _env = EnvSnapshot::set(&[
            ("CODEX_HOME", temp.path().to_str().unwrap()),
            (DEFAULT_WEBHOOK_SECRET_ENV, "   "),
            (DEFAULT_GITHUB_TOKEN_ENV, "t"),
        ]);

        let cmd = GithubCommand {
            listen: DEFAULT_LISTEN_ADDR.parse().unwrap(),
            webhook_secret_env: DEFAULT_WEBHOOK_SECRET_ENV.to_string(),
            github_token_env: DEFAULT_GITHUB_TOKEN_ENV.to_string(),
            min_permission: MinPermission::Triage,
            allow_repo: Vec::new(),
            command_prefix: DEFAULT_COMMAND_PREFIX.to_string(),
            delivery_ttl_days: 0,
            repo_ttl_days: 0,
        };

        let err = run_main_with_shutdown(cmd, CliConfigOverrides::default(), async {})
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("is empty"));
    }

    #[tokio::test]
    async fn repo_lock_for_reuses_lock_per_repo() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let a = repo_lock_for(&state, "o", "r").await;
        let b = repo_lock_for(&state, "o", "r").await;
        let c = repo_lock_for(&state, "o", "x").await;
        assert_eq!(Arc::ptr_eq(&a, &b), true);
        assert_eq!(Arc::ptr_eq(&a, &c), false);
    }

    #[tokio::test]
    async fn touch_repo_markers_creates_files() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        touch_repo_markers(&state, &key).await.unwrap();
        let repo_parent = state.repo_root.join("o").join("r");
        assert_eq!(
            repo_parent.join(REPO_MANAGED_MARKER_FILENAME).exists(),
            true
        );
        let last_used = tokio::fs::read_to_string(repo_parent.join(REPO_LAST_USED_FILENAME))
            .await
            .unwrap();
        assert!(last_used.trim().parse::<u64>().is_ok());
    }

    #[tokio::test]
    async fn read_repo_last_used_parses_or_returns_none() {
        let temp = tempfile::tempdir().unwrap();
        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();

        assert_eq!(read_repo_last_used(&repo_dir).await.unwrap(), None);

        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "\n")
            .await
            .unwrap();
        assert_eq!(read_repo_last_used(&repo_dir).await.unwrap(), None);

        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "nope\n")
            .await
            .unwrap();
        assert_eq!(read_repo_last_used(&repo_dir).await.unwrap(), None);

        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "123\n")
            .await
            .unwrap();
        assert_eq!(read_repo_last_used(&repo_dir).await.unwrap(), Some(123));
    }

    #[tokio::test]
    async fn dir_is_empty_treats_missing_as_empty() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(
            dir_is_empty(&temp.path().join("missing")).await.unwrap(),
            true
        );

        let dir = temp.path().join("d");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        assert_eq!(dir_is_empty(&dir).await.unwrap(), true);

        tokio::fs::write(dir.join("x"), "1").await.unwrap();
        assert_eq!(dir_is_empty(&dir).await.unwrap(), false);
    }

    #[tokio::test]
    async fn gc_delivery_markers_skips_non_markers_and_deletes_markers() {
        let temp = tempfile::tempdir().unwrap();
        tokio::fs::create_dir_all(temp.path()).await.unwrap();
        tokio::fs::write(temp.path().join("a.marker"), "x")
            .await
            .unwrap();
        tokio::fs::write(temp.path().join("b.txt"), "x")
            .await
            .unwrap();
        tokio::fs::create_dir_all(temp.path().join("c.marker"))
            .await
            .unwrap();

        gc_delivery_markers(temp.path(), Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(temp.path().join("a.marker").exists(), false);
        assert_eq!(temp.path().join("b.txt").exists(), true);
        assert_eq!(temp.path().join("c.marker").exists(), true);
    }

    #[tokio::test]
    async fn gc_delivery_markers_returns_ok_when_dir_missing() {
        let temp = tempfile::tempdir().unwrap();
        gc_delivery_markers(&temp.path().join("missing"), Duration::from_secs(1))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn gc_delivery_markers_errors_when_path_is_file() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("f");
        tokio::fs::write(&file, "x").await.unwrap();
        let err = gc_delivery_markers(&file, Duration::from_secs(1))
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("failed to read"));
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_deletes_managed_repo_without_worktrees() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "0\n")
            .await
            .unwrap();

        gc_repo_cache_if_stale(&state, "o", "r", Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(repo_dir.exists(), false);
    }

    #[tokio::test]
    async fn gc_repo_cache_skips_when_worktrees_present() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(repo_dir.join("issues").join("1"))
            .await
            .unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "0\n")
            .await
            .unwrap();

        gc_repo_cache_if_stale(&state, "o", "r", Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_caches_scans_repo_root() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        tokio::fs::create_dir_all(state.repo_root.as_ref())
            .await
            .unwrap();
        tokio::fs::write(state.repo_root.join("junk"), "x")
            .await
            .unwrap();

        let stale = state.repo_root.join("o").join("stale");
        tokio::fs::create_dir_all(&stale).await.unwrap();
        tokio::fs::write(stale.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(stale.join(REPO_LAST_USED_FILENAME), "0\n")
            .await
            .unwrap();

        let unmanaged = state.repo_root.join("o").join("keep");
        tokio::fs::create_dir_all(&unmanaged).await.unwrap();
        tokio::fs::write(unmanaged.join(REPO_LAST_USED_FILENAME), "0\n")
            .await
            .unwrap();

        gc_repo_caches(&state, Duration::ZERO).await.unwrap();
        assert_eq!(stale.exists(), false);
        assert_eq!(unmanaged.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_caches_skips_repo_files() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let good_owner = state.repo_root.join("good");
        tokio::fs::create_dir_all(&good_owner).await.unwrap();
        tokio::fs::write(good_owner.join("repo-file"), "x")
            .await
            .unwrap();

        gc_repo_caches(&state, Duration::ZERO).await.unwrap();
        assert_eq!(good_owner.join("repo-file").exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_caches_returns_ok_when_root_missing() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = test_state(&temp);
        state.repo_root = Arc::new(temp.path().join("missing"));
        gc_repo_caches(&state, Duration::from_secs(1))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn gc_repo_caches_errors_when_root_is_file() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = test_state(&temp);
        let root = temp.path().join("root-file");
        tokio::fs::write(&root, "x").await.unwrap();
        state.repo_root = Arc::new(root);
        let err = gc_repo_caches(&state, Duration::from_secs(1))
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("failed to read"));
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_returns_ok_when_last_used_missing() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();

        gc_repo_cache_if_stale(&state, "o", "r", Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_returns_ok_when_last_used_is_future() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            format!("{}\n", now + 60),
        )
        .await
        .unwrap();

        gc_repo_cache_if_stale(&state, "o", "r", Duration::ZERO)
            .await
            .unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_returns_ok_when_recent() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), format!("{now}\n"))
            .await
            .unwrap();

        gc_repo_cache_if_stale(&state, "o", "r", Duration::from_secs(60))
            .await
            .unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn dir_is_empty_errors_when_path_is_file() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("f");
        tokio::fs::write(&file, "x").await.unwrap();
        let err = dir_is_empty(&file).await.unwrap_err();
        assert!(format!("{err:#}").contains("failed to read"));
    }

    #[tokio::test]
    async fn read_repo_last_used_errors_when_path_is_directory() {
        let temp = tempfile::tempdir().unwrap();
        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(REPO_LAST_USED_FILENAME))
            .await
            .unwrap();
        let err = read_repo_last_used(&repo_dir).await.unwrap_err();
        assert!(format!("{err:#}").contains("failed to read"));
    }

    #[tokio::test]
    async fn gc_loop_runs_once_then_sleeps() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = test_state(&temp);
        state.delivery_ttl = Some(Duration::ZERO);
        state.repo_ttl = Some(Duration::ZERO);
        tokio::fs::create_dir_all(state.delivery_markers_dir.as_ref())
            .await
            .unwrap();
        tokio::fs::write(state.delivery_markers_dir.join("d.marker"), "x")
            .await
            .unwrap();
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(repo_dir.join(REPO_LAST_USED_FILENAME), "0\n")
            .await
            .unwrap();

        let _ = tokio::time::timeout(Duration::from_millis(50), gc_loop(state)).await;
        assert_eq!(
            temp.path().join("deliveries").join("d.marker").exists(),
            false
        );
        assert_eq!(
            temp.path().join("repos").join("o").join("r").exists(),
            false
        );
    }

    #[tokio::test]
    async fn gc_delivery_markers_skips_recent_marker() {
        let temp = tempfile::tempdir().unwrap();
        tokio::fs::write(temp.path().join("a.marker"), "x")
            .await
            .unwrap();

        gc_delivery_markers(temp.path(), Duration::from_secs(60))
            .await
            .unwrap();
        assert_eq!(temp.path().join("a.marker").exists(), true);
    }

    #[tokio::test]
    async fn gc_loop_logs_gc_errors_and_keeps_running() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = test_state(&temp);
        let deliveries = temp.path().join("deliveries-file");
        let repos = temp.path().join("repos-file");
        tokio::fs::write(&deliveries, "x").await.unwrap();
        tokio::fs::write(&repos, "x").await.unwrap();
        state.delivery_markers_dir = Arc::new(deliveries);
        state.repo_root = Arc::new(repos);
        state.delivery_ttl = Some(Duration::ZERO);
        state.repo_ttl = Some(Duration::ZERO);

        let _ = tokio::time::timeout(Duration::from_millis(50), gc_loop(state)).await;
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_rechecks_marker_under_lock() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            "0
",
        )
        .await
        .unwrap();

        let repo_lock = repo_lock_for(&state, "o", "r").await;
        let guard = repo_lock.lock().await;
        let state_for_task = state.clone();
        let task = tokio::spawn(async move {
            gc_repo_cache_if_stale(&state_for_task, "o", "r", Duration::ZERO).await
        });
        tokio::task::yield_now().await;
        tokio::fs::remove_file(repo_dir.join(REPO_MANAGED_MARKER_FILENAME))
            .await
            .unwrap();
        drop(guard);
        task.await.unwrap().unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_rechecks_last_used_under_lock() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            "0
",
        )
        .await
        .unwrap();

        let repo_lock = repo_lock_for(&state, "o", "r").await;
        let guard = repo_lock.lock().await;
        let state_for_task = state.clone();
        let task = tokio::spawn(async move {
            gc_repo_cache_if_stale(&state_for_task, "o", "r", Duration::ZERO).await
        });
        tokio::task::yield_now().await;
        tokio::fs::remove_file(repo_dir.join(REPO_LAST_USED_FILENAME))
            .await
            .unwrap();
        drop(guard);
        task.await.unwrap().unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_rechecks_future_last_used_under_lock() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            "0
",
        )
        .await
        .unwrap();

        let repo_lock = repo_lock_for(&state, "o", "r").await;
        let guard = repo_lock.lock().await;
        let state_for_task = state.clone();
        let task = tokio::spawn(async move {
            gc_repo_cache_if_stale(&state_for_task, "o", "r", Duration::ZERO).await
        });
        tokio::task::yield_now().await;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            format!(
                "{}
",
                now + 60
            ),
        )
        .await
        .unwrap();
        drop(guard);
        task.await.unwrap().unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_rechecks_recent_last_used_under_lock() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            "0
",
        )
        .await
        .unwrap();

        let repo_lock = repo_lock_for(&state, "o", "r").await;
        let guard = repo_lock.lock().await;
        let state_for_task = state.clone();
        let task = tokio::spawn(async move {
            gc_repo_cache_if_stale(&state_for_task, "o", "r", Duration::from_secs(60)).await
        });
        tokio::task::yield_now().await;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            format!(
                "{now}
"
            ),
        )
        .await
        .unwrap();
        drop(guard);
        task.await.unwrap().unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn gc_repo_cache_if_stale_rechecks_worktrees_under_lock() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = state.repo_root.join("o").join("r");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::write(repo_dir.join(REPO_MANAGED_MARKER_FILENAME), "")
            .await
            .unwrap();
        tokio::fs::write(
            repo_dir.join(REPO_LAST_USED_FILENAME),
            "0
",
        )
        .await
        .unwrap();

        let repo_lock = repo_lock_for(&state, "o", "r").await;
        let guard = repo_lock.lock().await;
        let state_for_task = state.clone();
        let task = tokio::spawn(async move {
            gc_repo_cache_if_stale(&state_for_task, "o", "r", Duration::ZERO).await
        });
        tokio::task::yield_now().await;
        tokio::fs::create_dir_all(repo_dir.join("issues").join("1"))
            .await
            .unwrap();
        drop(guard);
        task.await.unwrap().unwrap();
        assert_eq!(repo_dir.exists(), true);
    }

    #[tokio::test]
    async fn handle_webhook_rejects_payload_too_large() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let body = vec![0_u8; MAX_WEBHOOK_BYTES + 1];
        let res = handle_webhook(State(state), HeaderMap::new(), Bytes::from(body))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn handle_webhook_requires_event_header() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let res = handle_webhook(State(state), HeaderMap::new(), Bytes::from_static(b"{}"))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn handle_webhook_requires_delivery_header() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        let res = handle_webhook(State(state), headers, Bytes::from_static(b"{}"))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn handle_webhook_rejects_missing_signature() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        let res = handle_webhook(State(state), headers, Bytes::from_static(b"{}"))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn handle_webhook_rejects_invalid_json() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let body = Bytes::from_static(b"not-json");
        let header = signature_header(b"sekrit", body.as_ref());

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, body)
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn handle_webhook_rejects_invalid_payload() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let payload = json!({
            "action": "created",
            "repository": { "full_name": "invalid" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = Bytes::from(serde_json::to_vec(&payload).unwrap());
        let header = signature_header(b"sekrit", body.as_ref());

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, body)
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn handle_webhook_ignores_when_comment_missing_prefix() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let payload = json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "hello" }
        });
        let body = Bytes::from(serde_json::to_vec(&payload).unwrap());
        let header = signature_header(b"sekrit", body.as_ref());

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, body)
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::ACCEPTED);
    }

    #[tokio::test]
    async fn handle_webhook_ignores_when_repo_not_allowed() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = test_state(&temp);
        state.allow_repos = Arc::new(HashSet::from([normalize_repo_full_name("x/y")]));

        let payload = json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "o" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = Bytes::from(serde_json::to_vec(&payload).unwrap());
        let header = signature_header(b"sekrit", body.as_ref());

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, body)
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::ACCEPTED);
    }

    #[tokio::test]
    async fn handle_webhook_returns_500_when_permission_api_errors() {
        let app = Router::new().route(
            "/repos/o/r/collaborators/u/permission",
            get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(2)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let payload = json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = serde_json::to_vec(&payload).unwrap();
        let header = signature_header(b"sekrit", &body);

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, Bytes::from(body))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);

        server.abort();
    }

    #[tokio::test]
    async fn handle_webhook_returns_500_when_delivery_claim_fails() {
        let temp = tempfile::tempdir().unwrap();
        let delivery_markers_dir = temp.path().join("deliveries");
        tokio::fs::write(&delivery_markers_dir, "not a dir")
            .await
            .unwrap();

        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(delivery_markers_dir),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(2)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let payload = json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "o" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = serde_json::to_vec(&payload).unwrap();
        let header = signature_header(b"sekrit", &body);

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, Bytes::from(body))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn handle_webhook_returns_busy_before_permission_check() {
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(0)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = serde_json::to_vec(&payload).unwrap();
        let header = signature_header(b"sekrit", &body);

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, Bytes::from(body))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[tokio::test]
    async fn handle_webhook_ignores_when_sender_is_not_collaborator() {
        let app = Router::new().route(
            "/repos/o/r/collaborators/u/permission",
            get(|| async { StatusCode::NOT_FOUND }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(2)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let payload = serde_json::json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex hi" }
        });
        let body = serde_json::to_vec(&payload).unwrap();
        let header = signature_header(b"sekrit", &body);

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state), headers, Bytes::from(body))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::ACCEPTED);

        server.abort();
    }

    #[tokio::test]
    async fn sender_allowed_allows_repo_owner_without_permission_api() {
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "o".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "hi".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        assert_eq!(sender_allowed(&state, &item).await.unwrap(), true);
    }

    #[tokio::test]
    async fn sender_allowed_rejects_when_permission_too_low() {
        let app = Router::new().route(
            "/repos/o/r/collaborators/u/permission",
            get(|| async {
                (
                    StatusCode::OK,
                    axum::Json(serde_json::json!({ "permission": "read" })),
                )
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "hi".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        assert_eq!(sender_allowed(&state, &item).await.unwrap(), false);

        server.abort();
    }

    #[tokio::test]
    async fn fetch_issue_context_fetches_title_body_and_all_comments() {
        let app = Router::new()
            .route(
                "/repos/o/r/issues/1",
                get(|| async {
                    axum::Json(json!({
                        "title": "Issue title",
                        "body": "Issue body",
                        "html_url": "https://example.invalid/o/r/issues/1",
                        "user": { "login": "alice" },
                        "state": "open",
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z"
                    }))
                }),
            )
            .route(
                "/repos/o/r/issues/1/comments",
                get(|Query(q): Query<HashMap<String, String>>| async move {
                    let page: usize = q
                        .get("page")
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or(1);
                    let per_page: usize = q
                        .get("per_page")
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or_default();
                    assert_eq!(per_page, GITHUB_API_PER_PAGE);

                    let (start, count) = if page == 1 {
                        (0, GITHUB_API_PER_PAGE)
                    } else if page == 2 {
                        (GITHUB_API_PER_PAGE, GITHUB_API_PER_PAGE)
                    } else {
                        (GITHUB_API_PER_PAGE * 2, 1)
                    };
                    let comments: Vec<Value> = (0..count)
                        .map(|i| {
                            let id = (start + i) as u64;
                            json!({
                                "id": id,
                                "html_url": format!("https://example.invalid/o/r/issues/1#issuecomment-{id}"),
                                "user": { "login": format!("u{id}") },
                                "created_at": "2026-03-05T00:00:00Z",
                                "updated_at": "2026-03-05T00:00:00Z",
                                "body": format!("comment-body-{id}"),
                            })
                        })
                        .collect();
                    axum::Json(comments)
                }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let ctx = fetch_issue_context(&github, &key).await.unwrap();
        assert_eq!(ctx.title, "Issue title");
        assert!(ctx.markdown.contains("Issue body"));
        assert!(ctx.markdown.contains("comment-body-0"));
        assert!(
            ctx.markdown
                .contains(&format!("comment-body-{GITHUB_API_PER_PAGE}"))
        );

        server.abort();
    }

    #[tokio::test]
    async fn fetch_pull_context_includes_body_and_comment_types() {
        let app = Router::new()
            .route(
                "/repos/o/r/pulls/7",
                get(|| async {
                    axum::Json(json!({
                        "title": "PR title",
                        "body": "PR body",
                        "html_url": "https://example.invalid/o/r/pull/7",
                        "user": { "login": "alice" },
                        "state": "open",
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z",
                        "base": { "ref": "main" },
                        "head": { "ref": "feature" }
                    }))
                }),
            )
            .route(
                "/repos/o/r/issues/7/comments",
                get(|| async {
                    axum::Json(vec![json!({
                        "id": 1,
                        "html_url": "https://example.invalid/o/r/pull/7#issuecomment-1",
                        "user": { "login": "bob" },
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z",
                        "body": "issue comment body"
                    })])
                }),
            )
            .route(
                "/repos/o/r/pulls/7/comments",
                get(|| async {
                    axum::Json(vec![json!({
                        "id": 2,
                        "html_url": "https://example.invalid/o/r/pull/7#discussion_r2",
                        "user": { "login": "carol" },
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z",
                        "path": "src/lib.rs",
                        "line": 10,
                        "body": "review comment body"
                    })])
                }),
            )
            .route(
                "/repos/o/r/pulls/7/reviews",
                get(|| async {
                    axum::Json(vec![json!({
                        "id": 3,
                        "html_url": "https://example.invalid/o/r/pull/7#pullrequestreview-3",
                        "user": { "login": "dave" },
                        "state": "APPROVED",
                        "submitted_at": "2026-03-05T00:00:00Z",
                        "body": "review body"
                    })])
                }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Pull,
            number: 7,
        };
        let ctx = fetch_github_context(&github, &key).await.unwrap();
        assert_eq!(ctx.title, "PR title");
        assert!(ctx.markdown.contains("PR body"));
        assert!(ctx.markdown.contains("issue comment body"));
        assert!(ctx.markdown.contains("review comment body"));
        assert!(ctx.markdown.contains("Path: src/lib.rs"));
        assert!(ctx.markdown.contains("review body"));
        assert!(ctx.markdown.contains("State: APPROVED"));

        server.abort();
    }

    #[test]
    fn format_context_skips_empty_metadata_fields() {
        let issue_key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let issue = json!({ "body": "issue body" });
        let issue_ctx = format_issue_context(&issue_key, &issue, &[]);
        assert_eq!(issue_ctx.title, "");
        assert_eq!(issue_ctx.markdown.contains("Title:"), false);

        let pr_key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Pull,
            number: 7,
        };
        let pr = json!({ "body": "pr body", "base": {}, "head": {} });
        let pr_ctx = format_pull_context(&pr_key, &pr, &[], &[], &[]);
        assert_eq!(pr_ctx.title, "");
        assert_eq!(pr_ctx.markdown.contains("Title:"), false);
        assert_eq!(pr_ctx.markdown.contains("Branch:"), false);

        let mut out = String::new();
        format_issue_comment(&mut out, &json!({ "id": 1, "body": "c" }));
        assert_eq!(out.contains("URL:"), false);
        assert_eq!(out.contains("Author:"), false);

        out.clear();
        format_review_comment(&mut out, &json!({ "id": 2, "body": "c" }));
        assert_eq!(out.contains("URL:"), false);
        assert_eq!(out.contains("Path:"), false);
        assert_eq!(out.contains("Line:"), false);

        out.clear();
        format_review(&mut out, &json!({ "id": 3, "body": "c" }));
        assert_eq!(out.contains("URL:"), false);
        assert_eq!(out.contains("State:"), false);
    }

    #[test]
    fn sanitize_filename_component_replaces_unsafe_chars_and_handles_empty() {
        assert_eq!(sanitize_filename_component(""), "_");
        assert_eq!(sanitize_filename_component("a/b"), "a_b");
    }

    #[tokio::test]
    async fn ensure_worktree_accepts_existing_valid_marker() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        let git_worktrees = repo_dir.join(".git").join("worktrees");
        let gitdir = git_worktrees.join("wt");
        tokio::fs::create_dir_all(&gitdir).await.unwrap();

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();
        tokio::fs::write(
            work_dir.join(".git"),
            format!("gitdir: {}\n", gitdir.display()),
        )
        .await
        .unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn ensure_worktree_rejects_directory_git_marker() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(".git").join("worktrees"))
            .await
            .unwrap();

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(work_dir.join(".git"))
            .await
            .unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("invalid .git marker"));
    }

    #[tokio::test]
    async fn ensure_worktree_rejects_git_marker_missing_gitdir() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(".git").join("worktrees"))
            .await
            .unwrap();

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();
        tokio::fs::write(work_dir.join(".git"), "nope\n")
            .await
            .unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("missing gitdir"));
    }

    #[tokio::test]
    async fn ensure_worktree_rejects_gitdir_outside_expected() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(".git").join("worktrees"))
            .await
            .unwrap();

        let other = temp.path().join("other");
        tokio::fs::create_dir_all(&other).await.unwrap();

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();
        tokio::fs::write(
            work_dir.join(".git"),
            format!("gitdir: {}\n", other.display()),
        )
        .await
        .unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("is not under"));
    }

    #[tokio::test]
    async fn ensure_worktree_rejects_non_directory_work_dir() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        let work_dir = temp.path().join("work");
        tokio::fs::write(&work_dir, "x").await.unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("not a directory"));
    }

    #[tokio::test]
    async fn ensure_worktree_errors_when_repo_worktrees_dir_missing() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let repo_dir = temp.path().join("repo");
        let work_dir = temp.path().join("work");
        let gitdir = temp.path().join("gitdir");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        tokio::fs::create_dir_all(&work_dir).await.unwrap();
        tokio::fs::create_dir_all(&gitdir).await.unwrap();
        tokio::fs::write(
            work_dir.join(".git"),
            format!(
                "gitdir: {}
",
                gitdir.display()
            ),
        )
        .await
        .unwrap();

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("failed to resolve worktrees dir"));
    }

    #[tokio::test]
    async fn ensure_worktree_issue_errors_when_default_branch_api_fails() {
        let app = Router::new().route(
            "/repos/o/r",
            get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        let work_dir = temp.path().join("work");

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("repo API failed"));

        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_worktree_pull_fetches_and_creates_worktree() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        let work_dir = temp.path().join("work");
        let log = temp.path().join("git.log");

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\necho \"$*\" >> \"{log}\"\ncase \" $* \" in\n  *\" worktree add \"*) mkdir -p \"{work_dir}\" ;;\nesac\n",
                log = log.display(),
                work_dir = work_dir.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Pull,
            number: 7,
        };
        ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap();

        assert_eq!(work_dir.exists(), true);
        let logged = tokio::fs::read_to_string(&log).await.unwrap();
        assert!(logged.contains("fetch origin pull/7/head:codex/github/pull-7"));
        assert!(logged.contains("worktree add"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_worktree_pull_errors_when_fetch_fails() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(&repo_dir).await.unwrap();
        let work_dir = temp.path().join("work");

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(bin_dir.join("git").as_path(), "#!/bin/sh\nexit 1\n");
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Pull,
            number: 7,
        };
        let err = ensure_worktree(&state, &key, &repo_dir, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("git failed"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_prefers_gh_when_available() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        let parent = repo_dir.parent().unwrap();
        tokio::fs::create_dir_all(parent).await.unwrap();

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("gh").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\nmkdir -p \"{repo_dir}/.git\"\nexit 0\n",
                repo_dir = repo_dir.display()
            ),
        );
        write_exe(bin_dir.join("git").as_path(), "#!/bin/sh\nexit 1\n");
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        ensure_clone(&state, &key, &repo_dir).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_fetches_when_repo_exists() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(".git"))
            .await
            .unwrap();
        let log = temp.path().join("git.log");

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\necho \"$*\" >> \"{log}\"\nexit 0\n",
                log = log.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        ensure_clone(&state, &key, &repo_dir).await.unwrap();
        let logged = tokio::fs::read_to_string(&log).await.unwrap();
        assert!(logged.contains("fetch --prune origin"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_errors_when_fetch_fails() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        tokio::fs::create_dir_all(repo_dir.join(".git"))
            .await
            .unwrap();

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("git").as_path(),
            "#!/bin/sh\nset -eu\necho \"no\" 1>&2\nexit 1\n",
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let err = ensure_clone(&state, &key, &repo_dir).await.unwrap_err();
        assert!(format!("{err:#}").contains("git failed"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_falls_back_when_gh_is_missing() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        let parent = repo_dir.parent().unwrap();
        tokio::fs::create_dir_all(parent).await.unwrap();

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\ncase \" $* \" in\n  *\" clone \"*) /bin/mkdir -p \"{repo_dir}/.git\" ;;\nesac\n",
                repo_dir = repo_dir.display()
            ),
        );
        let _env = EnvSnapshot::set(&[("PATH", bin_dir.to_str().unwrap())]);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        ensure_clone(&state, &key, &repo_dir).await.unwrap();
        assert_eq!(repo_dir.join(".git").exists(), true);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_falls_back_when_gh_is_not_executable() {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);

        let repo_dir = temp.path().join("repo");
        let parent = repo_dir.parent().unwrap();
        tokio::fs::create_dir_all(parent).await.unwrap();

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        let gh_path = bin_dir.join("gh");
        std::fs::write(&gh_path, "#!/bin/sh\nexit 0\n").unwrap();
        let mut perms = std::fs::metadata(&gh_path).unwrap().permissions();
        perms.set_mode(0o644);
        std::fs::set_permissions(&gh_path, perms).unwrap();

        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\ncase \" $* \" in\n  *\" clone \"*) mkdir -p \"{repo_dir}/.git\" ;;\nesac\n",
                repo_dir = repo_dir.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        ensure_clone(&state, &key, &repo_dir).await.unwrap();
        assert_eq!(repo_dir.join(".git").exists(), true);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn ensure_clone_times_out_then_falls_back() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let _timeout_guard = TestGitCommandTimeoutGuard::set(Duration::from_millis(10));

        let repo_dir = temp.path().join("repo");
        let parent = repo_dir.parent().unwrap();
        tokio::fs::create_dir_all(parent).await.unwrap();

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(bin_dir.join("gh").as_path(), "#!/bin/sh\nsleep 60\n");
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\ncase \" $* \" in\n  *\" clone \"*) mkdir -p \"{repo_dir}/.git\" ;;\nesac\n",
                repo_dir = repo_dir.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };

        ensure_clone(&state, &key, &repo_dir).await.unwrap();
        assert_eq!(repo_dir.join(".git").exists(), true);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_git_surfaces_command_failure() {
        let temp = tempfile::tempdir().unwrap();
        let log = temp.path().join("err.txt");
        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\necho \"no\" > \"{log}\"\necho \"no\" 1>&2\nexit 1\n",
                log = log.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let err = run_git(temp.path(), vec!["status".to_string()], "t")
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("git failed"));
    }

    #[tokio::test]
    async fn post_success_supports_all_response_targets() {
        let issue_body = Arc::new(tokio::sync::Mutex::new(String::new()));
        let reply_body = Arc::new(tokio::sync::Mutex::new(String::new()));
        let review_payload = Arc::new(tokio::sync::Mutex::new(Value::Null));

        let app = {
            let issue_body = Arc::clone(&issue_body);
            let reply_body = Arc::clone(&reply_body);
            let review_payload = Arc::clone(&review_payload);
            Router::new()
                .route(
                    "/repos/o/r/issues/1/comments",
                    post(move |axum::Json(v): axum::Json<Value>| {
                        let issue_body = Arc::clone(&issue_body);
                        async move {
                            *issue_body.lock().await = v
                                .get("body")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string();
                            StatusCode::CREATED
                        }
                    }),
                )
                .route(
                    "/repos/o/r/pulls/comments/123/replies",
                    post(move |axum::Json(v): axum::Json<Value>| {
                        let reply_body = Arc::clone(&reply_body);
                        async move {
                            *reply_body.lock().await = v
                                .get("body")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string();
                            StatusCode::CREATED
                        }
                    }),
                )
                .route(
                    "/repos/o/r/pulls/7/reviews",
                    post(move |axum::Json(v): axum::Json<Value>| {
                        let review_payload = Arc::clone(&review_payload);
                        async move {
                            *review_payload.lock().await = v;
                            StatusCode::CREATED
                        }
                    }),
                )
        };

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let issue_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };
        post_success(&state, &issue_item, "m1").await.unwrap();
        assert_eq!(issue_body.lock().await.as_str(), "m1");

        let reply_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Pull,
                number: 7,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::ReviewCommentReply { comment_id: 123 },
        };
        post_success(&state, &reply_item, "m2").await.unwrap();
        assert_eq!(reply_body.lock().await.as_str(), "m2");

        let review_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Pull,
                number: 7,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::PullRequestReview { pull_number: 7 },
        };
        post_success(&state, &review_item, "m3").await.unwrap();

        let posted = review_payload.lock().await.clone();
        assert_eq!(posted.get("body").and_then(Value::as_str), Some("m3"));
        assert_eq!(posted.get("event").and_then(Value::as_str), Some("COMMENT"));

        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn process_work_item_posts_failure_comment() {
        let posted_body = Arc::new(Mutex::new(String::new()));
        let app = Router::new().route(
            "/repos/o/r/issues/1/comments",
            post({
                let posted_body = Arc::clone(&posted_body);
                move |axum::Json(v): axum::Json<Value>| {
                    let posted_body = Arc::clone(&posted_body);
                    async move {
                        *posted_body.lock().await = v
                            .get("body")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        StatusCode::CREATED
                    }
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let repo_root = temp.path().join("repos");
        let repo_dir = repo_root.join("o").join("r").join("repo");
        let work_dir = repo_root.join("o").join("r").join("issues").join("1");

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(bin_dir.join("gh").as_path(), "#!/bin/sh\nexit 1\n");
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\nmkdir -p \"{repo_dir}\"\ncase \" $* \" in\n  *\" clone \"*) mkdir -p \"{repo_dir}/.git\" ;;\n  *\" worktree add \"*) mkdir -p \"{work_dir}\" ; printf 'gitdir: {repo_dir}/.git/worktrees/issue-1\\n' > \"{work_dir}/.git\" ;;\nesac\n",
                repo_dir = repo_dir.display(),
                work_dir = work_dir.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(repo_root),
            codex_bin: Arc::new(temp.path().join("missing-codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do the thing".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let permit = state
            .concurrency_limit
            .clone()
            .acquire_owned()
            .await
            .unwrap();
        process_work_item(state, item, permit).await;
        assert!(posted_body.lock().await.contains("codex github failed"));

        server.abort();
    }

    #[tokio::test]
    async fn post_success_errors_when_github_api_fails() {
        let app = Router::new()
            .route(
                "/repos/o/r/issues/1/comments",
                post(|| async { (StatusCode::BAD_REQUEST, "no") }),
            )
            .route(
                "/repos/o/r/pulls/comments/123/replies",
                post(|| async { (StatusCode::BAD_REQUEST, "no") }),
            )
            .route(
                "/repos/o/r/pulls/7/reviews",
                post(|| async { (StatusCode::BAD_REQUEST, "no") }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(PathBuf::from("codex")),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let issue_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };
        assert!(post_success(&state, &issue_item, "m1").await.is_err());

        let reply_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Pull,
                number: 7,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::ReviewCommentReply { comment_id: 123 },
        };
        assert!(post_success(&state, &reply_item, "m2").await.is_err());

        let review_item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "u".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Pull,
                number: 7,
            },
            prompt: "x".to_string(),
            response_target: ResponseTarget::PullRequestReview { pull_number: 7 },
        };
        assert!(post_success(&state, &review_item, "m3").await.is_err());

        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_writes_context_file() {
        use std::os::unix::fs::PermissionsExt;

        let app = Router::new()
            .route(
                "/repos/o/r/issues/1",
                get(|| async {
                    axum::Json(json!({
                        "title": "Issue title",
                        "body": "Issue body",
                        "html_url": "https://example.invalid/o/r/issues/1",
                        "user": { "login": "alice" },
                        "state": "open",
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z"
                    }))
                }),
            )
            .route(
                "/repos/o/r/issues/1/comments",
                get(|| async { axum::Json(Vec::<Value>::new()) }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let prompt_log = temp.path().join("prompt.txt");
        let codex_path = temp.path().join("codex");
        std::fs::write(
            &codex_path,
            format!(
                "#!/bin/sh\nset -eu\nlast=\"\"\nfor arg in \"$@\"; do last=\"$arg\"; done\necho \"$last\" > \"{}\"\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"{{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"thr-1\\\"}}\"\nprintf %s \"ok\" > \"$out\"\n",
                prompt_log.display()
            ),
        )
        .unwrap();
        let mut perms = std::fs::metadata(&codex_path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&codex_path, perms).unwrap();

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do the thing".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let output = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap();
        assert_eq!(output.thread_id.as_deref(), Some("thr-1"));
        assert_eq!(output.last_message, "ok");

        let context = tokio::fs::read_to_string(work_dir.join(GITHUB_CONTEXT_FILENAME))
            .await
            .unwrap();
        assert!(context.contains("Issue title"));
        assert!(context.contains("Issue body"));

        let prompt = tokio::fs::read_to_string(&prompt_log).await.unwrap();
        assert!(prompt.contains("Title: Issue title"));
        assert!(prompt.contains(&format!("Context: {GITHUB_CONTEXT_FILENAME}")));
        assert!(prompt.contains("do the thing"));

        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_notes_context_write_failure_and_passes_overrides() {
        let app = Router::new()
            .route(
                "/repos/o/r/issues/1",
                get(|| async {
                    axum::Json(json!({
                        "title": "Issue title",
                        "body": "Issue body",
                        "html_url": "https://example.invalid/o/r/issues/1",
                        "user": { "login": "alice" },
                        "state": "open",
                        "created_at": "2026-03-05T00:00:00Z",
                        "updated_at": "2026-03-05T00:00:00Z"
                    }))
                }),
            )
            .route(
                "/repos/o/r/issues/1/comments",
                get(|| async { axum::Json(Vec::<Value>::new()) }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();

        let args_log = temp.path().join("args.txt");
        let codex_path = temp.path().join("codex");
        write_exe(
            &codex_path,
            &format!(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$@\" > \"{args_log}\"\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"{{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"thr-1\\\"}}\"\necho \"hello\"\nprintf %s \"ok\" > \"$out\"\n",
                args_log = args_log.display()
            ),
        );

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();
        tokio::fs::create_dir_all(work_dir.join(GITHUB_CONTEXT_FILENAME))
            .await
            .unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(vec!["k=v".to_string()]),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do the thing".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let output = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap();
        assert_eq!(output.last_message, "ok");

        let args = tokio::fs::read_to_string(&args_log).await.unwrap();
        assert!(args.contains("-c\nk=v\n"));
        assert!(args.contains("failed to write context file"));

        server.abort();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_errors_on_empty_output_file() {
        let app = Router::new()
            .route(
                "/repos/o/r/issues/1",
                get(|| async { axum::Json(json!({ "title": "", "body": "" })) }),
            )
            .route(
                "/repos/o/r/issues/1/comments",
                get(|| async { axum::Json(Vec::<Value>::new()) }),
            );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();

        let codex_path = temp.path().join("codex");
        write_exe(
            &codex_path,
            "#!/bin/sh\nset -eu\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"thr-1\\\"}\"\n: > \"$out\"\n",
        );

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let err = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("did not write output"));

        server.abort();
    }

    #[test]
    fn truncate_for_github_truncates_and_preserves_utf8() {
        const LIMIT: usize = 60_000;
        let mut s = "a".repeat(LIMIT - 1);
        s.push('🦀');
        s.push_str("tail");
        let out = truncate_for_github(&s);
        assert!(out.contains("[truncated]"));
        assert!(out.is_char_boundary(out.len()));
        assert!(out.len() <= LIMIT + 20);
    }

    #[tokio::test]
    async fn read_thread_id_returns_none_when_file_is_empty() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let path = thread_id_path(&state, &key);
        tokio::fs::create_dir_all(path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&path, "\n").await.unwrap();
        assert_eq!(read_thread_id(&state, &key).await.unwrap(), None);
    }

    #[tokio::test]
    async fn read_thread_id_errors_when_path_is_directory() {
        let temp = tempfile::tempdir().unwrap();
        let state = test_state(&temp);
        let key = WorkKey {
            owner: "o".to_string(),
            repo: "r".to_string(),
            kind: WorkKind::Issue,
            number: 1,
        };
        let path = thread_id_path(&state, &key);
        tokio::fs::create_dir_all(&path).await.unwrap();
        let err = read_thread_id(&state, &key).await.unwrap_err();
        assert!(format!("{err:#}").contains("thread id file"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_handles_context_fetch_failure_and_resume() {
        let app = Router::new().route(
            "/repos/o/r/issues/1",
            get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();

        let args_log = temp.path().join("args.txt");
        let codex_path = temp.path().join("codex");
        write_exe(
            &codex_path,
            &format!(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$@\" > \"{args_log}\"\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"{{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"thr-1\\\"}}\"\nprintf %s \"ok\" > \"$out\"\n",
                args_log = args_log.display()
            ),
        );

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        write_thread_id(&state, &item.work, "thr-old")
            .await
            .unwrap();
        let output = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap();
        assert_eq!(output.thread_id.as_deref(), Some("thr-1"));
        assert_eq!(output.last_message, "ok");

        let context = tokio::fs::read_to_string(work_dir.join(GITHUB_CONTEXT_FILENAME))
            .await
            .unwrap();
        assert!(context.contains("context fetch failed"));

        let args = tokio::fs::read_to_string(&args_log).await.unwrap();
        assert!(args.contains("resume"));
        assert!(args.contains("thr-old"));
        assert!(args.contains("fetch failed"));

        server.abort();
    }

    #[tokio::test]
    async fn run_codex_in_worktree_errors_when_codex_spawn_fails() {
        let temp = tempfile::tempdir().unwrap();
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();
        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let missing = temp.path().join("missing-codex");
        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(missing),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let err = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("failed to spawn codex exec"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_errors_when_codex_exits_nonzero() {
        let temp = tempfile::tempdir().unwrap();
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();

        let codex_path = temp.path().join("codex");
        write_exe(&codex_path, "#!/bin/sh\nexit 1\n");
        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let err = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("codex exec failed"));
    }

    #[cfg(unix)]
    #[tokio::test(start_paused = true)]
    async fn run_codex_in_worktree_times_out() {
        let temp = tempfile::tempdir().unwrap();
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();

        let codex_path = temp.path().join("codex");
        write_exe(&codex_path, "#!/bin/sh\nexec tail -f /dev/null\n");
        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let handle =
            tokio::spawn(async move { run_codex_in_worktree(&state, &item, &work_dir).await });
        tokio::task::yield_now().await;
        tokio::time::advance(CODEX_EXEC_TIMEOUT + Duration::from_millis(1)).await;
        let err = handle.await.unwrap().unwrap_err();
        assert!(format!("{err:#}").contains("timed out"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn run_codex_in_worktree_ignores_non_thread_started_stdout() {
        let github =
            GithubApi::new_with_base_url("t".to_string(), "http://example.invalid".to_string())
                .unwrap();
        let temp = tempfile::tempdir().unwrap();

        let codex_path = temp.path().join("codex");
        write_exe(
            &codex_path,
            "#!/bin/sh\nset -eu\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"hello\"\nprintf %s \"ok\" > \"$out\"\n",
        );

        let work_dir = temp.path().join("work");
        tokio::fs::create_dir_all(&work_dir).await.unwrap();

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(temp.path().join("repos")),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let item = WorkItem {
            repo_full_name: "o/r".to_string(),
            sender_login: "bob".to_string(),
            work: WorkKey {
                owner: "o".to_string(),
                repo: "r".to_string(),
                kind: WorkKind::Issue,
                number: 1,
            },
            prompt: "do it".to_string(),
            response_target: ResponseTarget::IssueComment { issue_number: 1 },
        };

        let output = run_codex_in_worktree(&state, &item, &work_dir)
            .await
            .unwrap();
        assert_eq!(output.thread_id, None);
        assert_eq!(output.last_message, "ok");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn handle_webhook_processes_issue_comment_end_to_end() {
        let post_calls = Arc::new(AtomicUsize::new(0));
        let posted_body = Arc::new(tokio::sync::Mutex::new(String::new()));
        let app = {
            let post_calls = Arc::clone(&post_calls);
            let posted_body = Arc::clone(&posted_body);
            Router::new()
                .route(
                    "/repos/o/r/collaborators/u/permission",
                    get(|| async { axum::Json(json!({ "permission": "admin" })) }),
                )
                .route(
                    "/repos/o/r",
                    get(|| async { axum::Json(json!({ "default_branch": "master" })) }),
                )
                .route(
                    "/repos/o/r/issues/1",
                    get(|| async {
                        axum::Json(json!({
                            "title": "Issue title",
                            "body": "Issue body",
                            "html_url": "https://example.invalid/o/r/issues/1",
                            "user": { "login": "alice" },
                            "state": "open",
                            "created_at": "2026-03-05T00:00:00Z",
                            "updated_at": "2026-03-05T00:00:00Z"
                        }))
                    }),
                )
                .route(
                    "/repos/o/r/issues/1/comments",
                    get(|| async { axum::Json(Vec::<Value>::new()) }).post(
                        move |axum::Json(v): axum::Json<Value>| {
                            let post_calls = Arc::clone(&post_calls);
                            let posted_body = Arc::clone(&posted_body);
                            async move {
                                post_calls.fetch_add(1, Ordering::SeqCst);
                                let body = v
                                    .get("body")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_string();
                                *posted_body.lock().await = body;
                                StatusCode::CREATED
                            }
                        },
                    ),
                )
        };

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = spawn_test_server(listener, app);

        let github =
            GithubApi::new_with_base_url("t".to_string(), format!("http://{addr}")).unwrap();
        let temp = tempfile::tempdir().unwrap();

        let repo_root = temp.path().join("repos");
        let repo_dir = repo_root.join("o").join("r").join("repo");
        let work_dir = repo_root.join("o").join("r").join("issues").join("1");

        let bin_dir = temp.path().join("bin");
        std::fs::create_dir_all(&bin_dir).unwrap();
        write_exe(bin_dir.join("gh").as_path(), "#!/bin/sh\nexit 1\n");
        write_exe(
            bin_dir.join("git").as_path(),
            &format!(
                "#!/bin/sh\nset -eu\nmkdir -p \"{repo_dir}\"\ncase \" $* \" in\n  *\" clone \"*) mkdir -p \"{repo_dir}/.git\" ;;\n  *\" worktree add \"*) mkdir -p \"{work_dir}\" ;;\nesac\n",
                repo_dir = repo_dir.display(),
                work_dir = work_dir.display()
            ),
        );
        let _path_guard = PathGuard::prepend(&bin_dir);

        let codex_path = temp.path().join("codex");
        write_exe(
            &codex_path,
            "#!/bin/sh\nset -eu\nout=\"\"\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; continue; fi\n  shift\ndone\necho \"{\\\"type\\\":\\\"thread.started\\\",\\\"thread_id\\\":\\\"thr-1\\\"}\"\nprintf %s \"ok\" > \"$out\"\n",
        );

        let state = AppState {
            secret: Arc::new(b"sekrit".to_vec()),
            github: Arc::new(github),
            github_token: Arc::new("t".to_string()),
            allow_repos: Arc::new(HashSet::new()),
            min_permission: MinPermission::Triage,
            command_prefix: Arc::new("/codex".to_string()),
            repo_root: Arc::new(repo_root),
            codex_bin: Arc::new(codex_path),
            codex_config_overrides: Arc::new(Vec::new()),
            delivery_markers_dir: Arc::new(temp.path().join("deliveries")),
            thread_state_dir: Arc::new(temp.path().join("threads")),
            delivery_ttl: None,
            repo_ttl: None,
            concurrency_limit: Arc::new(Semaphore::new(2)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
            repo_locks: Arc::new(Mutex::new(HashMap::new())),
        };

        let payload = json!({
            "action": "created",
            "repository": { "full_name": "o/r" },
            "sender": { "login": "u" },
            "issue": { "number": 1 },
            "comment": { "body": "/codex do the thing" }
        });
        let body = serde_json::to_vec(&payload).unwrap();
        let header = signature_header(b"sekrit", &body);

        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);

        let res = handle_webhook(State(state.clone()), headers, Bytes::from(body.clone()))
            .await
            .into_response();
        assert_eq!(res.status(), StatusCode::ACCEPTED);

        let header = signature_header(b"sekrit", &body);
        let mut headers = HeaderMap::new();
        headers.insert("X-GitHub-Event", HeaderValue::from_static("issue_comment"));
        headers.insert("X-GitHub-Delivery", HeaderValue::from_static("d1"));
        headers.insert("X-Hub-Signature-256", header);
        let dup = handle_webhook(State(state.clone()), headers, Bytes::from(body))
            .await
            .into_response();
        assert_eq!(dup.status(), StatusCode::ACCEPTED);

        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if post_calls.load(Ordering::SeqCst) == 1 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();

        assert_eq!(post_calls.load(Ordering::SeqCst), 1);
        assert_eq!(posted_body.lock().await.as_str(), "ok");

        let context = tokio::fs::read_to_string(work_dir.join(GITHUB_CONTEXT_FILENAME))
            .await
            .unwrap();
        assert!(context.contains("Issue title"));
        assert!(context.contains("Issue body"));

        let thread_id_path = state
            .thread_state_dir
            .join("o")
            .join("r")
            .join("issues")
            .join("1.txt");
        assert_eq!(
            tokio::fs::read_to_string(&thread_id_path)
                .await
                .unwrap()
                .trim(),
            "thr-1"
        );

        let marker_path = state.delivery_markers_dir.join("d1.marker");
        assert_eq!(marker_path.exists(), true);

        server.abort();
    }

    fn signature_header(secret: &[u8], body: &[u8]) -> HeaderValue {
        let mut mac = HmacSha256::new_from_slice(secret).unwrap();
        mac.update(body);
        let sig = mac.finalize().into_bytes();
        let header = format!("sha256={}", bytes_to_lower_hex(&sig));
        HeaderValue::from_str(&header).unwrap()
    }

    fn bytes_to_lower_hex(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push(hex_digit((b >> 4) & 0xf));
            out.push(hex_digit(b & 0xf));
        }
        out
    }

    fn hex_digit(n: u8) -> char {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        char::from(HEX[n as usize])
    }
}
