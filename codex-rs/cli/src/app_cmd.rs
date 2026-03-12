use clap::Parser;
use std::path::PathBuf;

const DEFAULT_CODEX_DMG_URL: &str = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";

#[derive(Debug, Parser)]
pub struct AppCommand {
    /// 在 Codex Desktop 中打开的工作区路径。
    #[arg(value_name = "PATH", default_value = ".")]
    pub path: PathBuf,

    /// 覆盖 macOS DMG 下载地址（高级）。
    #[arg(long, default_value = DEFAULT_CODEX_DMG_URL)]
    pub download_url: String,
}

#[cfg(target_os = "macos")]
pub async fn run_app(cmd: AppCommand) -> anyhow::Result<()> {
    let workspace = std::fs::canonicalize(&cmd.path).unwrap_or(cmd.path);
    crate::desktop_app::run_app_open_or_install(workspace, cmd.download_url).await
}
