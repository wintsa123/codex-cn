## Hodexctl Guide

`hodexctl` manages `hodex` release installs and source download/sync/toolchain prep without touching existing `codex` installs.

### Rules

- `hodex` is only for release management.
- `hodexctl source ...` only handles source download, sync, and toolchain prep.
- Source mode does not build or deploy and does not take over `hodex`.
- Existing `codex` installs are unaffected by `hodexctl` uninstall.

### Supported Platforms

- macOS
- Linux
- WSL
- Windows PowerShell

On Linux/WSL, release assets are chosen in `gnu` -> `musl` order.

### Quick Start

#### macOS / Linux / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/install-hodexctl.sh | bash
```

#### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/install-hodexctl.ps1 | iex
```

The installer finishes the `hodexctl` setup and prints the next steps. Afterwards, use:

```bash
hodexctl
```

### Make It Effective Immediately (Current Terminal)

> `curl | bash` runs in a subshell, so it cannot modify your parent shell environment (including `PATH`).

- macOS / Linux / WSL:
  - Run `source ~/.zshrc` / `source ~/.bashrc` as shown by the installer (depending on your shell), or open a new terminal.
  - If you want to verify without relying on `PATH`, run the wrapper directly: `~/.hodex/commands/hodexctl status` (or your custom `--state-dir/--command-dir`).

- Windows PowerShell:
  - `irm ... | iex` runs in the current session; the installer tries to refresh `$env:Path`, so `hodexctl status` should work right away.
  - If it still doesn't work: reopen PowerShell, or run `$env:LOCALAPPDATA\\hodex\\commands\\hodexctl.cmd status`.

If you prefer to download the script and run it manually:

```bash
curl -fsSL https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/hodexctl/hodexctl.sh -o ./hodexctl.sh && chmod +x ./hodexctl.sh && ./hodexctl.sh
```

```powershell
$script = Join-Path $env:TEMP "hodexctl.ps1"; Invoke-WebRequest https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/hodexctl/hodexctl.ps1 -OutFile $script; & $script
```

### Common Commands

```bash
hodexctl install
hodexctl list
hodexctl upgrade
hodexctl upgrade 1.2.2
hodexctl downgrade 1.2.1
hodexctl download 1.2.2
hodexctl status
hodexctl relink
hodexctl repair
hodexctl uninstall
```

```bash
hodexctl source install --repo stellarlinkco/codex --ref main
hodexctl source update --profile codex-source
hodexctl source switch --profile codex-source --ref feature/my-branch
hodexctl source status
hodexctl source list
hodexctl source uninstall --profile codex-source
```

### Default Locations

- State dir:
  - macOS / Linux / WSL: `~/.hodex`
  - Windows: `%LOCALAPPDATA%\\hodex`
- Recommended source checkout location: `~/hodex-src/<host>/<owner>/<repo>`

### PATH Management

`hodexctl` writes the command directory to your `PATH` by default so new terminals can use `hodex` / `hodexctl` immediately.

- macOS / Linux / WSL:
  - zsh writes to `~/.zprofile` and `~/.zshrc`; bash writes to `~/.bash_profile` and `~/.bashrc`.
  - Inserted content includes marker blocks that uninstall/repair can clean:
    - `# >>> hodexctl >>>` / `# <<< hodexctl <<<`
    - Legacy markers: `# >>> hodex installer >>>` / `# <<< hodex installer <<<`
  - If you use `--no-path-update` or set `HODEXCTL_NO_PATH_UPDATE=1`, the script will not change `PATH`; you must add the command dir yourself.

- Windows PowerShell:
  - Writes to the user PATH (registry User Path) only; it does not touch the system PATH.
  - `hodexctl status` shows `PATH managed by hodexctl` and `PATH source`; uninstall only rolls back managed entries and will not remove your existing PATH items.

Common values for `PATH source` in `hodexctl status`:

- `managed-profile-block` / `managed-user-path`: written and managed by `hodexctl`.
- `preexisting-profile` / `preexisting-user-path`: already present, not owned by `hodexctl`.
- `current-process-only`: only visible in the current session (for example manual `export PATH=...`); status will suggest `hodexctl repair` to persist it.
- `disabled` / `user-skipped`: you disabled auto-write or skipped the prompt.
- `<unknown>`: legacy or incomplete install state; `hodexctl repair` will usually normalize it on the next successful pass.

### Behavior Notes

- Running `hodexctl` directly shows help.
- `list` shows available versions and changelog viewing.
- The changelog AI summary prefers local `hodex`, and falls back to `codex` if needed.
- When the GitHub API returns `403`, the script tries `gh api` as a fallback; if `gh` is unavailable, not logged in, or lacks permission, it prints a clear hint.
- `relink` only rebuilds wrappers; it does not re-download binaries.
- `repair` self-heals wrapper / PATH / state drift; if the release binary is missing, it will prompt you to run `hodexctl install` / `hodexctl upgrade`.

### Status

```bash
hodexctl status
```

The status page shows the release install, command dir, PATH handling, and source profile summary.

If `hodex` or `hodexctl` is missing after install/upgrade, run:

```bash
hodexctl status && hodexctl repair
```

```powershell
hodexctl status; hodexctl repair
```

`relink` vs `repair`:

- `relink`: rebuilds `hodex` / `hodexctl` wrappers and refreshes state-related links.
- `repair`: runs `relink` plus additional diagnostics/self-heal (for example fixing `PATH` that is only visible in the current session).

### Uninstall

```bash
hodexctl uninstall
```

- Removes managed release installs; if only the manager is installed, it will be cleaned too.
- Source profiles must be removed via `hodexctl source uninstall`.
- When the last release/source profile is removed, the `hodexctl` wrappers and managed PATH entries are cleaned as well.

### Common Options

```bash
hodexctl install --yes --no-path-update
hodexctl install --github-token <token>
hodexctl status --state-dir /custom/state
hodexctl source install --git-url git@github.com:someone/codex.git --profile codex-fork
```

Windows PowerShell parameter names: `-Yes`, `-NoPathUpdate`, `-GitHubToken`, `-StateDir`, `-GitUrl`, `-Profile`.

### Environment Variables (Advanced)

These environment variables control install location, mirrors, or behavior:

- `HODEX_STATE_DIR`: state dir (default `~/.hodex` / `%LOCALAPPDATA%\\hodex`).
- `HODEX_COMMAND_DIR` / `INSTALL_DIR`: command dir (default `<state_dir>/commands`).
- `HODEX_DOWNLOAD_DIR`: download dir (used by `download`, default `~/Downloads`).
- `HODEXCTL_REPO` / `CODEX_REPO`: target repo (default `stellarlinkco/codex`).
- `HODEX_CONTROLLER_URL_BASE`: controller download base (mirror support; default `https://raw.githubusercontent.com`).
- `HODEX_CONTROLLER_REF`: Git ref used when downloading the controller script (default `main`).
- `HODEX_RELEASE_BASE_URL`: release download base (mirror/testing).
- `HODEXCTL_NO_PATH_UPDATE=1`: disable PATH auto-write.
- `GITHUB_TOKEN`: GitHub API token (mitigate anonymous rate limits).
