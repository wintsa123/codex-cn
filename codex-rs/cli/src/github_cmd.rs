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
use tokio::io::AsyncBufReadExt;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio::sync::Semaphore;

const DEFAULT_LISTEN_ADDR: &str = "127.0.0.1:8787";
const DEFAULT_WEBHOOK_SECRET_ENV: &str = "GITHUB_WEBHOOK_SECRET";
const DEFAULT_GITHUB_TOKEN_ENV: &str = "GITHUB_TOKEN";
const DEFAULT_COMMAND_PREFIX: &str = "/codex";
const GITHUB_API_BASE_URL: &str = "https://api.github.com";
const GITHUB_API_VERSION: &str = "2022-11-28";
const MAX_WEBHOOK_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_MAX_CONCURRENCY: usize = 2;
const GITHUB_API_TIMEOUT: Duration = Duration::from_secs(20);
const GIT_COMMAND_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const CODEX_EXEC_TIMEOUT: Duration = Duration::from_secs(20 * 60);

type HmacSha256 = Hmac<Sha256>;

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
    concurrency_limit: Arc<Semaphore>,
    work_locks: Arc<Mutex<HashMap<WorkKey, Arc<Mutex<()>>>>>,
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
        concurrency_limit: Arc::new(Semaphore::new(DEFAULT_MAX_CONCURRENCY)),
        work_locks: Arc::new(Mutex::new(HashMap::new())),
    };

    let app = Router::new()
        .route("/", post(handle_webhook))
        .route("/healthz", get(healthz))
        .with_state(state);

    let listener = TcpListener::bind(cmd.listen)
        .await
        .with_context(|| format!("failed to bind {}", cmd.listen))?;

    eprintln!("codex github listening on http://{}", cmd.listen);
    axum::serve(listener, app.into_make_service())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("github webhook server failed")?;

    Ok(())
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

    let mut mac = match HmacSha256::new_from_slice(secret) {
        Ok(m) => m,
        Err(_) => return false,
    };
    mac.update(body);
    mac.verify_slice(&sig_bytes).is_ok()
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
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
    if !matches!(
        event,
        "issue_comment" | "pull_request_review_comment" | "pull_request_review"
    ) {
        return Ok(None);
    }

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
        "issue_comment" => parse_issue_comment(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
        "pull_request_review_comment" => parse_review_comment(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
        "pull_request_review" => parse_review(
            owner,
            repo,
            repo_full_name,
            sender_login,
            payload,
            command_prefix,
        ),
        _ => Ok(None),
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
            issue_number: issue_number,
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

async fn ensure_repo_and_worktree(state: &AppState, key: &WorkKey, work_dir: &Path) -> Result<()> {
    let repo_dir = clone_path(state, key);
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
    let gh_result = tokio::time::timeout(GIT_COMMAND_TIMEOUT, cmd.output()).await;

    match gh_result {
        Ok(Ok(output)) if output.status.success() => return Ok(()),
        Ok(Ok(output)) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!("gh repo clone failed for {owner}/{repo}: {stderr}");
        }
        Ok(Err(err)) => eprintln!("gh repo clone failed for {owner}/{repo}: {err:#}"),
        Err(_) => eprintln!("gh repo clone timed out in {}", parent.display()),
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
    format!("https://github.com:443/{owner}/{repo}.git")
}

async fn ensure_worktree(
    state: &AppState,
    key: &WorkKey,
    repo_dir: &Path,
    work_dir: &Path,
) -> Result<()> {
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
    let output = tokio::time::timeout(GIT_COMMAND_TIMEOUT, cmd.output())
        .await
        .with_context(|| format!("git timed out in {}", cwd.display()))?
        .with_context(|| format!("failed to run git in {}", cwd.display()))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git failed: {stderr}");
    }
}

struct CodexOutput {
    thread_id: Option<String>,
    last_message: String,
}

async fn run_codex_in_worktree(
    state: &AppState,
    item: &WorkItem,
    work_dir: &Path,
) -> Result<CodexOutput> {
    let thread_id = read_thread_id(state, &item.work).await?;

    let tempdir = tempfile::tempdir().context("failed to create temp dir")?;
    let last_message_path = tempdir.path().join("last_message.txt");
    let prompt = format!(
        "GitHub event for {}#{} from @{}:\n\n{}",
        item.repo_full_name, item.work.number, item.sender_login, item.prompt
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
                        if observed_thread_id.is_none() {
                            if let Ok(v) = serde_json::from_str::<Value>(&line)
                                && v.get("type").and_then(Value::as_str) == Some("thread.started")
                                && let Some(id) = v.get("thread_id").and_then(Value::as_str)
                            {
                                observed_thread_id = Some(id.to_string());
                            }
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
        .unwrap_or_default();
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
    use pretty_assertions::assert_eq;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;

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
    fn github_command_defaults_to_github_env_vars() {
        let cmd = <GithubCommand as clap::Parser>::try_parse_from(["github"].as_ref())
            .expect("parse should succeed");
        assert_eq!(cmd.webhook_secret_env, DEFAULT_WEBHOOK_SECRET_ENV);
        assert_eq!(cmd.github_token_env, DEFAULT_GITHUB_TOKEN_ENV);
    }

    #[test]
    fn github_clone_url_uses_port_443() {
        assert_eq!(github_clone_url("o", "r"), "https://github.com:443/o/r.git");
    }

    #[test]
    fn github_git_auth_header_uses_basic_auth() {
        assert_eq!(
            github_git_auth_header("t"),
            "Authorization: basic eC1hY2Nlc3MtdG9rZW46dA=="
        );
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
    fn command_prefix_requires_boundary() {
        assert_eq!(strip_prefix_prompt("/codexx hi", "/codex").unwrap(), None);
        assert_eq!(
            strip_prefix_prompt(" /codex hi", "/codex").unwrap(),
            Some("hi".to_string())
        );
    }

    #[test]
    fn review_prefix_requires_boundary() {
        assert_eq!(
            strip_prefix_lines("/codexx no\n/codex yes", "/codex"),
            Some("yes".to_string())
        );
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
        let ResponseTarget::ReviewCommentReply { comment_id } = item.response_target else {
            panic!("expected review comment reply target");
        };
        assert_eq!(comment_id, 123);
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
    async fn handle_webhook_returns_busy_before_permission_check() {
        let calls = Arc::new(AtomicUsize::new(0));
        let app = {
            let calls = Arc::clone(&calls);
            Router::new().route(
                "/repos/o/r/collaborators/u/permission",
                get(move || {
                    let calls = Arc::clone(&calls);
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        (
                            StatusCode::OK,
                            axum::Json(serde_json::json!({"permission":"admin"})),
                        )
                    }
                }),
            )
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app.into_make_service())
                .await
                .unwrap();
        });

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
            concurrency_limit: Arc::new(Semaphore::new(0)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
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
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        server.abort();
    }

    #[tokio::test]
    async fn handle_webhook_ignores_when_sender_is_not_collaborator() {
        let app = Router::new().route(
            "/repos/o/r/collaborators/u/permission",
            get(|| async { StatusCode::NOT_FOUND }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app.into_make_service())
                .await
                .unwrap();
        });

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
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
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
        let calls = Arc::new(AtomicUsize::new(0));
        let app = {
            let calls = Arc::clone(&calls);
            Router::new().route(
                "/repos/o/r/collaborators/o/permission",
                get(move || {
                    let calls = Arc::clone(&calls);
                    async move {
                        calls.fetch_add(1, Ordering::SeqCst);
                        StatusCode::INTERNAL_SERVER_ERROR
                    }
                }),
            )
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app.into_make_service())
                .await
                .unwrap();
        });

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
            concurrency_limit: Arc::new(Semaphore::new(1)),
            work_locks: Arc::new(Mutex::new(HashMap::new())),
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
        assert_eq!(calls.load(Ordering::SeqCst), 0);

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
        match n {
            0..=9 => char::from(b'0' + n),
            10..=15 => char::from(b'a' + (n - 10)),
            _ => '?',
        }
    }
}
