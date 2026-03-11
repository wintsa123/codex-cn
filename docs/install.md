## Installing & building

### System requirements

| Requirement                 | Details                                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Operating systems           | macOS 12+, Linux (the shell installer prefers `gnu` assets and falls back to `musl`; `gnu` assets require glibc >= 2.35), or Windows 11 **via WSL2** |
| Git (optional, recommended) | 2.23+ for built-in PR helpers                                                                                                               |
| RAM                         | 4-GB minimum (8-GB recommended)                                                                                                             |

> **Note:** The shell installer prefers `gnu` Linux assets and falls back to `musl` when older releases only provide `musl`. `gnu` assets require glibc 2.35 or newer.

### Hodexctl

If you want to manage `hodex` releases without touching existing `codex`, use `hodexctl`.

Recommended first install:

```bash
curl -fsSL https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/install-hodexctl.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/install-hodexctl.ps1 | iex
```

After install, use:

- `hodexctl`
- `hodexctl install`
- `hodexctl list`

Notes:

- On macOS / Linux / WSL, `curl | bash` runs in a subshell. After install, open a new terminal or follow the installer output and run `source ~/.zshrc` / `source ~/.bashrc` to make `hodexctl` available in the current session.
- On Windows PowerShell, `irm | iex` runs in the current session and tries to refresh `$env:Path`; if it still doesn’t work, reopen PowerShell.
- If PATH / wrapper / state drift makes commands unavailable, run `hodexctl repair` to self-heal.

Common usage:

macOS / Linux / WSL：

- `./scripts/hodexctl/hodexctl.sh install`
- `hodexctl list`
- `hodexctl upgrade`
- `hodexctl status`

Windows PowerShell：

- `.\scripts\hodexctl\hodexctl.ps1 install`
- `hodexctl list`
- `hodexctl upgrade`
- `hodexctl status`

Notes:

- `hodex` manages releases only.
- `hodexctl source ...` only handles source download, sync, and toolchain prep.
- `hodexctl uninstall` does not affect existing `codex`.
- See [../scripts/hodexctl/README.md](../scripts/hodexctl/README.md) for detailed parameters and interactive guidance.

### DotSlash

The GitHub Release also contains a [DotSlash](https://dotslash-cli.com/) file for the Codex CLI named `codex`. Using a DotSlash file makes it possible to make a lightweight commit to source control to ensure all contributors use the same version of an executable, regardless of what platform they use for development.

### Build from source

```bash
# Clone the repository and navigate to the root of the Cargo workspace.
git clone https://github.com/stellarlinkco/codex.git
cd codex/codex-rs

# Install the Rust toolchain, if necessary.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup component add rustfmt
rustup component add clippy
# Install helper tools used by the workspace justfile:
cargo install just
# Optional: install nextest for the `just test` helper
cargo install --locked cargo-nextest

# Build Codex.
cargo build

# Launch the TUI with a sample prompt.
cargo run --bin codex -- "explain this codebase to me"

# After making changes, use the root justfile helpers (they default to codex-rs):
just fmt
just fix -p <crate-you-touched>

# Run the relevant tests (project-specific is fastest), for example:
cargo test -p codex-tui
# If you have cargo-nextest installed, `just test` runs the test suite via nextest:
just test
# Avoid `--all-features` for routine local runs because it increases build
# time and `target/` disk usage by compiling additional feature combinations.
# If you specifically want full feature coverage, use:
cargo test --all-features
```

## Tracing / verbose logging

Codex is written in Rust, so it honors the `RUST_LOG` environment variable to configure its logging behavior.

The TUI defaults to `RUST_LOG=codex_core=info,codex_tui=info,codex_rmcp_client=info` and log messages are written to `~/.codex/log/codex-tui.log` by default. For a single run, you can override the log directory with `-c log_dir=...` (for example, `-c log_dir=./.codex-log`).

```bash
tail -F ~/.codex/log/codex-tui.log
```

By comparison, the non-interactive mode (`codex exec`) defaults to `RUST_LOG=error`, but messages are printed inline, so there is no need to monitor a separate file.

See the Rust documentation on [`RUST_LOG`](https://docs.rs/env_logger/latest/env_logger/#enabling-logging) for more information on the configuration options.
