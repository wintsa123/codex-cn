## Hodexctl Guide

`hodexctl` manages `hodex` release installs separately from source checkout / sync / toolchain setup; it does not overwrite an existing `codex` install.

### Fixed Rules

- `hodex` is only used for release version management.
- `hodexctl source ...` only handles source download, sync, and toolchain preparation.
- Source mode does not compile, deploy, or take over `hodex`.
- Uninstalling `hodexctl` does not affect the existing `codex` installation.

### Supported Platforms

- macOS
- Linux
- WSL
- Windows PowerShell

On Linux/WSL, release assets are chosen in `gnu` -> `musl` order to prefer glibc builds while keeping older musl-only releases installable.

### Quick Start

#### macOS / Linux / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/hodexctl/hodexctl.sh -o ./hodexctl.sh
chmod +x ./hodexctl.sh
./hodexctl.sh
```

#### Windows PowerShell

```powershell
$script = Join-Path $env:TEMP "hodexctl.ps1"
Invoke-WebRequest https://raw.githubusercontent.com/stellarlinkco/codex/main/scripts/hodexctl/hodexctl.ps1 -OutFile $script
& $script
```

After the first install, use:

```bash
hodexctl
```

### Common Commands

#### Release Management

```bash
hodexctl install
hodexctl list
hodexctl upgrade
hodexctl upgrade 1.2.2
hodexctl downgrade 1.2.1
hodexctl download 1.2.2
hodexctl status
hodexctl relink
hodexctl uninstall
```

#### Source Management

```bash
hodexctl source install
hodexctl source install 1.2.2
hodexctl source update
hodexctl source status
hodexctl source shell
hodexctl source doctor
hodexctl source clean
```

### Notes

- `hodexctl install` downloads the latest release and installs/updates `hodex`.
- `hodexctl upgrade <version>` upgrades/downgrades to the target release.
- `hodexctl download <version>` only downloads the archive to the local cache without relinking.
- `hodexctl relink` refreshes command shims if the state directory has been moved.
- `hodexctl source install` clones the repository and prepares the development toolchain.
- `hodexctl source shell` opens a shell inside the source checkout with the expected environment loaded.
