#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SELF_PATH="${BASH_SOURCE[0]}"
DISPLAY_COMMAND="${HODEX_DISPLAY_NAME:-$SCRIPT_NAME}"
DEFAULT_REPO="stellarlinkco/codex"
DEFAULT_STATE_DIR="${HODEX_STATE_DIR:-$HOME/.hodex}"
DEFAULT_CONTROLLER_URL_BASE="https://raw.githubusercontent.com"
DEFAULT_DOWNLOAD_DIR="${HODEX_DOWNLOAD_DIR:-$HOME/downloads}"
PATH_BLOCK_START="# >>> hodexctl >>>"
PATH_BLOCK_END="# <<< hodexctl <<<"
LEGACY_PATH_BLOCK_START="# >>> hodex installer >>>"
LEGACY_PATH_BLOCK_END="# <<< hodex installer <<<"
NODE_DOWNLOAD_URL="https://nodejs.org/en/download"
NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh"

COMMAND="install"
REQUESTED_VERSION="latest"
REPO="$DEFAULT_REPO"
STATE_DIR="$DEFAULT_STATE_DIR"
COMMAND_DIR=""
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
NODE_MODE="ask"
AUTO_YES=0
NO_PATH_UPDATE=0
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CONTROLLER_URL_BASE="${HODEX_CONTROLLER_URL_BASE:-$DEFAULT_CONTROLLER_URL_BASE}"
CONTROLLER_REF="${HODEX_CONTROLLER_REF:-main}"
RELEASE_BASE_URL="${HODEX_RELEASE_BASE_URL:-}"
API_USER_AGENT="hodexctl"
FORCED_COMMAND=""
SOURCE_ACTION=""
SOURCE_PROFILE=""
EXPLICIT_SOURCE_REPO=0
SOURCE_REF=""
SOURCE_GIT_URL=""
SOURCE_CHECKOUT_DIR=""
SOURCE_CHECKOUT_POLICY="ask"
DEFAULT_SOURCE_PROFILE_NAME="codex-source"
DEFAULT_SOURCE_REF="main"
EXPLICIT_SOURCE_PROFILE=0
EXPLICIT_SOURCE_REF=0
HELP_REQUESTED=0
DEFAULT_RETRY_ATTEMPTS="${HODEX_RETRY_ATTEMPTS:-3}"
DEFAULT_RETRY_DELAY_SECONDS="${HODEX_RETRY_DELAY_SECONDS:-2}"
DEFAULT_RETRY_DELAY_STEP_SECONDS="${HODEX_RETRY_DELAY_STEP_SECONDS:-2}"
GH_API_FALLBACK_REASON=""
GH_API_FALLBACK_DETAIL=""

JSON_BACKEND=""
OS_NAME=""
ARCH_NAME=""
PLATFORM_LABEL=""
IS_WSL=0
PATH_UPDATE_MODE="skipped"
PATH_PROFILE=""
NODE_SETUP_CHOICE="skip"
COLOR_ENABLED=0
COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_HEADER=""
COLOR_SELECTED=""
COLOR_INSTALLED=""
COLOR_HINT=""
COLOR_STATUS=""
COLOR_ALERT=""
TEE_COMMAND=""
ORIGINAL_STDOUT_IS_TTY=0

STATE_INSTALLED_VERSION=""
STATE_RELEASE_TAG=""
STATE_RELEASE_NAME=""
STATE_ASSET_NAME=""
STATE_BINARY_PATH=""
STATE_CONTROLLER_PATH=""
STATE_COMMAND_DIR=""
STATE_PATH_UPDATE_MODE=""
STATE_PATH_PROFILE=""
STATE_PATH_MANAGED_BY_HODEXCTL="false"
STATE_PATH_DETECTED_SOURCE=""
STATE_NODE_SETUP_CHOICE=""
STATE_INSTALLED_AT=""
PATH_UPDATE_MODE=""
PATH_PROFILE=""
PATH_MANAGED_BY_HODEXCTL="false"
PATH_DETECTED_SOURCE=""

usage() {
  local usage_command standalone_command
  usage_command="$DISPLAY_COMMAND"
  standalone_command="./hodexctl.sh"
  if [[ "$usage_command" != "hodexctl" ]]; then
    usage_command="$standalone_command"
  fi

  cat <<EOF
Usage:
  ${usage_command}
  ${usage_command} <command> [version] [options]

Commands:
  install [version]      Install or reinstall hodex (default: latest)
  upgrade [version]      Upgrade to latest or a specific version
  download [version]     Download release asset for current platform (default: latest)
  downgrade <version>    Downgrade to a specific version
  source <action>        Source download/sync/toolchain management
  uninstall              Remove hodex files
  status                 Show current install status
  list                   Interactive version list + changelog
  relink                 Regenerate hodex / hodexctl wrappers
  repair                 Self-heal wrapper / PATH / state drift
  help                   Show help

Options:
  --repo <owner/repo>            GitHub repo (default: stellarlinkco/codex)
  --install-dir <path>           Command dir (same as --command-dir)
  --command-dir <path>           Directory for hodex / hodexctl wrappers
  --state-dir <path>             State dir (default: ~/.hodex)
  --download-dir <path>          Download dir (default: ~/downloads)
  --node-mode <mode>             Node handling: ask|skip|native|nvm|manual
  --git-url <url>                Source mode Git clone URL
  --ref <branch|tag|commit>      Source mode ref (default: main)
  --checkout-dir <path>          Source mode checkout dir
  --profile <profile-name>       Source profile name (default: codex-source)
  --keep-checkout                Keep checkout on source uninstall
  --remove-checkout              Remove checkout on source uninstall
  --list                         Same as list
  --yes, -y                      Non-interactive (accept defaults)
  --no-path-update               Do not modify PATH
  --github-token <token>         GitHub API token (mitigate rate limit)
  --help, -h                     Show help

Examples (after install, recommended via hodexctl):
  hodexctl
  hodexctl status
  hodexctl list
  hodexctl upgrade
  hodexctl download 1.2.3 --download-dir ~/downloads
  hodexctl downgrade 1.2.2
  hodexctl source install --repo stellarlinkco/codex --ref main
  hodexctl source switch --profile codex-source --ref feature/my-branch
  hodexctl source status
  hodexctl source list
  hodexctl relink --command-dir ~/.local/bin
  hodexctl repair
  hodexctl uninstall

Examples (run script directly):
  ${standalone_command} install
  ${standalone_command} install 1.2.2
  ${standalone_command} upgrade
  ${standalone_command} download 1.2.3 --download-dir ~/downloads
  ${standalone_command} list
  ${standalone_command} downgrade 1.2.2
  ${standalone_command} source install --git-url https://github.com/stellarlinkco/codex.git --ref main
  ${standalone_command} relink --command-dir ~/.local/bin
  ${standalone_command} repair
  ${standalone_command} uninstall
EOF
}

source_usage() {
  local usage_command standalone_command
  usage_command="$DISPLAY_COMMAND source"
  standalone_command="./hodexctl.sh source"
  if [[ "$DISPLAY_COMMAND" != "hodexctl" ]]; then
    usage_command="$standalone_command"
  fi

  cat <<EOF
Source mode usage:
  ${usage_command} <action> [options]

Actions:
  install                Download source and prepare toolchain (does not take over hodex)
  update                 Sync latest code for current ref and reuse checkout
  switch                 Switch to --ref and sync source
  status                 Show source profile status
  uninstall              Remove source profile (optional checkout deletion)
  list                   List all source profiles
  help                   Show help

Common options:
  --repo <owner/repo>            GitHub repo
  --git-url <url>                HTTPS / SSH Git URL
  --ref <branch|tag|commit>      Source ref
  --checkout-dir <path>          Source checkout dir
  --profile <profile-name>       Source profile name (default: codex-source)
                                  Note: this is not a command name and will not take over hodex
  --keep-checkout                Keep checkout on uninstall
  --remove-checkout              Remove checkout on uninstall

Examples:
  hodexctl source install --repo stellarlinkco/codex --ref main
  hodexctl source install --git-url git@github.com:someone/codex.git --profile codex-fork
  hodexctl source switch --profile codex-source --ref feature/my-branch
  hodexctl source status --profile codex-source
EOF
}

list_usage() {
  local usage_command standalone_command
  usage_command="$DISPLAY_COMMAND list"
  standalone_command="./hodexctl.sh list"
  if [[ "$DISPLAY_COMMAND" != "hodexctl" ]]; then
    usage_command="$standalone_command"
  fi

  cat <<EOF
Release list usage:
  ${usage_command}

List view:
  Up / Down      Move selection
  Left / Right   Change page
  n / p    Next / previous page
  /        Search
  0        Enter source download/management
  Enter    View changelog
  ?        Show help
  q        Quit

Changelog view:
  a        AI summary (hodex/codex)
  i        Install selected version
  d        Download asset for current platform
  b        Back to list
  q        Quit
EOF
}

log_step() {
  printf '==> %s\n' "$1"
}

log_info() {
  printf '%s\n' "$1"
}

log_warn() {
  printf 'Warning: %s\n' "$1" >&2
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_local_tool_paths() {
  local candidate
  for candidate in "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    [[ -d "$candidate" ]] || continue
    case ":$PATH:" in
      *":$candidate:"*) ;;
      *) export PATH="$candidate:$PATH" ;;
    esac
  done
}

find_command_path() {
  local command_name="$1"
  local candidate

  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return 0
  fi

  for candidate in \
    "/usr/bin/$command_name" \
    "/bin/$command_name" \
    "/usr/sbin/$command_name" \
    "/sbin/$command_name" \
    "/usr/local/bin/$command_name" \
    "/usr/local/sbin/$command_name" \
    "/opt/homebrew/bin/$command_name" \
    "/opt/homebrew/sbin/$command_name"; do
    [[ -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

retry_error_summary() {
  local error_file="$1"
  local error_text
  error_text="$(tr '\r\n' '  ' <"$error_file" 2>/dev/null | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  printf '%s' "${error_text:0:240}"
}

is_retryable_failure() {
  local label="$1"
  local exit_code="$2"
  local error_file="$3"
  local error_text
  error_text="$(retry_error_summary "$error_file")"

  [[ -n "$error_text" ]] || return 1

  case "$label" in
    github-api | release-download | controller-download | rustup-install | brew-install | nvm-install)
      [[ "$error_text" =~ ([Tt]imed[[:space:]-]?out|SSL|TLS|Could[[:space:]]not[[:space:]]resolve[[:space:]]host|Failed[[:space:]]to[[:space:]]connect|Connection[[:space:]]reset|Recv[[:space:]]failure|HTTP/[0-9.]+[[:space:]]5|returned[[:space:]]error:[[:space:]]5|transfer[[:space:]]closed) ]]
      ;;
    git-clone | git-fetch)
      [[ "$error_text" =~ (Could[[:space:]]not[[:space:]]resolve[[:space:]]host|Failed[[:space:]]to[[:space:]]connect|Connection[[:space:]]timed[[:space:]]out|Connection[[:space:]]reset|TLS|SSL|RPC[[:space:]]failed|remote[[:space:]]end[[:space:]]hung[[:space:]]up|unable[[:space:]]to[[:space:]]access) ]]
      ;;
    cargo-metadata | cargo-build | cargo-install)
      [[ "$error_text" =~ ([Ss]purious[[:space:]]network[[:space:]]error|failed[[:space:]]to[[:space:]]download|index\.crates\.io|SSL[[:space:]]connect[[:space:]]error|[Nn]etwork[[:space:]]error|[Tt]imed[[:space:]-]?out|Connection[[:space:]]reset|Could[[:space:]]not[[:space:]]connect|failed[[:space:]]to[[:space:]]get) ]]
      ;;
    *)
      return 1
      ;;
  esac
}

run_with_retry() {
  local label="$1"
  shift

  local max_attempts="$DEFAULT_RETRY_ATTEMPTS"
  local delay_seconds="$DEFAULT_RETRY_DELAY_SECONDS"
  local delay_step="$DEFAULT_RETRY_DELAY_STEP_SECONDS"
  local attempt=1 exit_code stdout_file stderr_file

  while true; do
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"

    if [[ -n "$TEE_COMMAND" ]]; then
      "$@" > >("$TEE_COMMAND" "$stdout_file") 2> >("$TEE_COMMAND" "$stderr_file" >&2)
      exit_code=$?
    else
      "$@" >"$stdout_file" 2>"$stderr_file"
      exit_code=$?
    fi

    if ((exit_code == 0)); then
      [[ -n "$TEE_COMMAND" ]] || cat "$stdout_file"
      rm -f "$stdout_file" "$stderr_file"
      return 0
    fi

    if ((attempt >= max_attempts)) || ! is_retryable_failure "$label" "$exit_code" "$stderr_file"; then
      [[ -n "$TEE_COMMAND" ]] || {
        cat "$stdout_file"
        cat "$stderr_file" >&2
      }
      rm -f "$stdout_file" "$stderr_file"
      return "$exit_code"
    fi

    log_warn "$label failed; retrying in ${delay_seconds}s (${attempt}/${max_attempts}): $(retry_error_summary "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
    delay_seconds=$((delay_seconds + delay_step))
  done
}

normalize_user_path() {
  local raw="$1"
  # shellcheck disable=SC2088
  case "$raw" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${raw#~/}"
      ;;
    /*)
      printf '%s\n' "$raw"
      ;;
    *)
      printf '%s/%s\n' "$PWD" "$raw"
      ;;
  esac
}

normalize_version() {
  local raw="$1"
  case "$raw" in
    "" | latest)
      printf 'latest\n'
      ;;
    rust-v*)
      printf '%s\n' "${raw#rust-v}"
      ;;
    v*)
      printf '%s\n' "${raw#v}"
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

parse_args() {
  local positional=()
  local original_argc=$#
  while (($# > 0)); do
    case "$1" in
      install | upgrade | download | downgrade | source | uninstall | status | list | relink | repair | help | manager-install)
        positional+=("$1")
        shift
        ;;
      --repo)
        (($# >= 2)) || die "--repo requires a value"
        REPO="$2"
        EXPLICIT_SOURCE_REPO=1
        shift 2
        ;;
      --install-dir | --command-dir)
        (($# >= 2)) || die "$1 requires a value"
        COMMAND_DIR="$(normalize_user_path "$2")"
        shift 2
        ;;
      --state-dir)
        (($# >= 2)) || die "--state-dir requires a value"
        STATE_DIR="$(normalize_user_path "$2")"
        shift 2
        ;;
      --download-dir)
        (($# >= 2)) || die "--download-dir requires a value"
        DOWNLOAD_DIR="$(normalize_user_path "$2")"
        shift 2
        ;;
      --node-mode)
        (($# >= 2)) || die "--node-mode requires a value"
        NODE_MODE="$2"
        shift 2
        ;;
      --git-url)
        (($# >= 2)) || die "--git-url requires a value"
        SOURCE_GIT_URL="$2"
        shift 2
        ;;
      --ref)
        (($# >= 2)) || die "--ref requires a value"
        SOURCE_REF="$2"
        EXPLICIT_SOURCE_REF=1
        shift 2
        ;;
      --checkout-dir)
        (($# >= 2)) || die "--checkout-dir requires a value"
        SOURCE_CHECKOUT_DIR="$(normalize_user_path "$2")"
        shift 2
        ;;
      --profile | --name)
        (($# >= 2)) || die "$1 requires a value"
        if [[ "$1" == "--name" ]]; then
          log_warn "--name is deprecated; use --profile."
        fi
        SOURCE_PROFILE="$2"
        EXPLICIT_SOURCE_PROFILE=1
        shift 2
        ;;
      --activate)
        die "Source mode will not take over hodex; source checkout is only for sync and toolchain management."
        ;;
      --no-activate)
        die "Source mode will not take over hodex and will not create source command wrappers; --no-activate is not supported."
        ;;
      --keep-checkout)
        SOURCE_CHECKOUT_POLICY="keep"
        shift
        ;;
      --remove-checkout)
        SOURCE_CHECKOUT_POLICY="remove"
        shift
        ;;
      --list)
        FORCED_COMMAND="list"
        shift
        ;;
      --yes | -y)
        AUTO_YES=1
        shift
        ;;
      --no-path-update)
        NO_PATH_UPDATE=1
        shift
        ;;
      --github-token)
        (($# >= 2)) || die "--github-token requires a value"
        GITHUB_TOKEN="$2"
        shift 2
        ;;
      --help | -h)
        HELP_REQUESTED=1
        shift
        ;;
      --*)
        die "Unknown argument: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if ((original_argc == 0)); then
    usage
    exit 0
  fi

  if ((${#positional[@]} > 0)); then
    case "${positional[0]}" in
      install | upgrade | download | downgrade | source | uninstall | status | list | relink | repair | help | manager-install)
        COMMAND="${positional[0]}"
        positional=("${positional[@]:1}")
        ;;
      *)
        COMMAND="install"
        ;;
    esac
  fi

  if [[ -n "$FORCED_COMMAND" ]]; then
    COMMAND="$FORCED_COMMAND"
  fi

  case "$COMMAND" in
    install | upgrade | download)
      if ((${#positional[@]} > 0)); then
        REQUESTED_VERSION="${positional[0]}"
        positional=("${positional[@]:1}")
      fi
      ;;
    downgrade)
      if ((${#positional[@]} == 0)); then
        die "downgrade requires an explicit version"
      fi
      REQUESTED_VERSION="${positional[0]}"
      positional=("${positional[@]:1}")
      ;;
    source)
      if ((${#positional[@]} == 0)); then
        SOURCE_ACTION="list"
      else
        SOURCE_ACTION="${positional[0]}"
        positional=("${positional[@]:1}")
      fi
      ;;
    uninstall | status | list | relink | repair | manager-install)
      ;;
    help)
      usage
      exit 0
      ;;
  esac

  if ((${#positional[@]} > 0)); then
    die "Unexpected extra args: ${positional[*]}"
  fi

  case "$NODE_MODE" in
    ask | skip | native | nvm | manual)
      ;;
    *)
      die "--node-mode supports only ask|skip|native|nvm|manual"
      ;;
  esac

  if [[ "$COMMAND" == "source" ]]; then
    case "$SOURCE_ACTION" in
      install | update | rebuild | switch | status | uninstall | list | help)
        ;;
      *)
        die "source supports only install|update|switch|status|uninstall|list|help; rebuild alias was removed and now only shows a hint."
        ;;
    esac

    if [[ -z "$SOURCE_REF" ]]; then
      SOURCE_REF="$DEFAULT_SOURCE_REF"
    fi
  fi

  if ((HELP_REQUESTED)); then
    case "$COMMAND" in
      source)
        source_usage
        ;;
      list)
        list_usage
        ;;
      *)
        usage
        ;;
    esac
    exit 0
  fi
}

init_json_backend_if_available() {
  JSON_BACKEND=""
  if command_exists python3; then
    JSON_BACKEND="python3"
    return
  fi

  if command_exists jq; then
    JSON_BACKEND="jq"
    return
  fi
}

require_json_backend() {
  local feature="${1:-current command}"
  init_json_backend_if_available
  [[ -n "$JSON_BACKEND" ]] && return 0
  die "${feature} requires python3 or jq; install one of them and retry."
}

require_base_commands() {
  command_exists curl || die "Missing dependency: curl"
  command_exists mktemp || die "Missing dependency: mktemp"
  command_exists chmod || die "Missing dependency: chmod"
  command_exists mkdir || die "Missing dependency: mkdir"
  command_exists cp || die "Missing dependency: cp"
  command_exists install || die "Missing dependency: install"
  command_exists awk || die "Missing dependency: awk"
  command_exists grep || die "Missing dependency: grep"
  command_exists date || die "Missing dependency: date"
  command_exists sleep || die "Missing dependency: sleep"
}

init_color_theme() {
  local colors
  if [[ ! -t 1 ]] || ! command_exists tput; then
    return
  fi

  colors="$(tput colors 2>/dev/null || printf '0')"
  [[ "$colors" =~ ^[0-9]+$ ]] || return
  if ((colors < 8)); then
    return
  fi

  COLOR_ENABLED=1
  COLOR_RESET="$(tput sgr0)"
  COLOR_BOLD="$(tput bold)"
  COLOR_DIM="$(tput dim)"
  COLOR_HEADER="$(tput setaf 6)"
  COLOR_SELECTED="$(tput setaf 2)"
  COLOR_INSTALLED="$(tput setaf 3)"
  COLOR_HINT="$(tput setaf 4)"
  COLOR_STATUS="$(tput setaf 5)"
  COLOR_ALERT="$(printf '\033[1;30;43m')"
}

is_wsl_platform() {
  local version_source="/proc/version"

  if [[ -n "${HODEXCTL_TEST_PROC_VERSION_FILE:-}" ]]; then
    version_source="${HODEXCTL_TEST_PROC_VERSION_FILE}"
  fi

  [[ -r "$version_source" ]] || return 1
  grep -qiE 'microsoft|wsl' "$version_source"
}

detect_platform() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  case "$uname_s" in
    Darwin)
      OS_NAME="darwin"
      ;;
    Linux)
      OS_NAME="linux"
      ;;
    *)
      die "This script supports macOS, Linux, and WSL only; use scripts/hodexctl/hodexctl.ps1 on Windows."
      ;;
  esac

  if [[ "$OS_NAME" == "linux" ]] && is_wsl_platform; then
    IS_WSL=1
  fi

  case "$uname_m" in
    arm64 | aarch64)
      ARCH_NAME="aarch64"
      ;;
    x86_64 | amd64)
      ARCH_NAME="x86_64"
      ;;
    *)
      die "Unsupported architecture: $uname_m"
      ;;
  esac

  if [[ "$OS_NAME" == "darwin" && "$ARCH_NAME" == "x86_64" ]]; then
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
      ARCH_NAME="aarch64"
    fi
  fi

  if [[ "$OS_NAME" == "darwin" ]]; then
    if [[ "$ARCH_NAME" == "aarch64" ]]; then
      PLATFORM_LABEL="macOS (Apple Silicon)"
    else
      PLATFORM_LABEL="macOS (Intel)"
    fi
  elif ((IS_WSL)); then
    if [[ "$ARCH_NAME" == "aarch64" ]]; then
      PLATFORM_LABEL="WSL (ARM64)"
    else
      PLATFORM_LABEL="WSL (x64)"
    fi
  elif [[ "$ARCH_NAME" == "aarch64" ]]; then
    PLATFORM_LABEL="Linux (ARM64)"
  else
    PLATFORM_LABEL="Linux (x64)"
  fi
}

get_asset_candidates() {
  if [[ "$OS_NAME" == "darwin" ]]; then
    if [[ "$ARCH_NAME" == "aarch64" ]]; then
      printf '%s\n' "codex-aarch64-apple-darwin"
    else
      printf '%s\n' "codex-x86_64-apple-darwin"
    fi
    return
  fi

  if [[ "$ARCH_NAME" == "aarch64" ]]; then
    printf '%s\n' \
      "codex-aarch64-unknown-linux-gnu" \
      "codex-aarch64-unknown-linux-musl"
  else
    printf '%s\n' \
      "codex-x86_64-unknown-linux-gnu" \
      "codex-x86_64-unknown-linux-musl"
  fi
}

http_get_to_file() {
  local url="$1"
  local output="$2"
  local status_code
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: $API_USER_AGENT"
  )

  if [[ -n "$GITHUB_TOKEN" ]]; then
    headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  GH_API_FALLBACK_REASON=""
  GH_API_FALLBACK_DETAIL=""

  status_code="$(
    run_with_retry "github-api" \
      curl -sSL \
      -w '%{http_code}' \
      -o "$output" \
      "${headers[@]}" \
      "$url"
  )" || status_code=""

  if [[ "$status_code" == "200" ]]; then
    return 0
  fi

  if gh_api_get_to_file "$url" "$output"; then
    if [[ "$GH_API_FALLBACK_REASON" == "gh-success" && -n "$GH_API_FALLBACK_DETAIL" ]]; then
      log_info "$GH_API_FALLBACK_DETAIL"
    fi
    return 0
  fi

  return 1
}

gh_api_path_from_url() {
  local url="$1"
  case "$url" in
    https://api.github.com/*)
      printf '%s\n' "${url#https://api.github.com/}"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

gh_api_get_to_file() {
  local url="$1"
  local output="$2"
  local api_path stderr_file

  GH_API_FALLBACK_REASON=""
  GH_API_FALLBACK_DETAIL=""

  command_exists gh || {
    GH_API_FALLBACK_REASON="gh-missing"
    return 1
  }

  api_path="$(gh_api_path_from_url "$url")" || {
    GH_API_FALLBACK_REASON="gh-unsupported"
    return 1
  }

  stderr_file="$(mktemp)"
  if [[ -n "$GITHUB_TOKEN" ]]; then
    if GH_TOKEN="$GITHUB_TOKEN" gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$api_path" >"$output" 2>"$stderr_file"; then
      GH_API_FALLBACK_REASON="gh-success"
      GH_API_FALLBACK_DETAIL="Automatically switched to gh api for GitHub data."
      rm -f "$stderr_file"
      return 0
    fi
  else
    if gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$api_path" >"$output" 2>"$stderr_file"; then
      GH_API_FALLBACK_REASON="gh-success"
      GH_API_FALLBACK_DETAIL="Automatically switched to gh api for GitHub data."
      rm -f "$stderr_file"
      return 0
    fi
  fi

  GH_API_FALLBACK_DETAIL="$(retry_error_summary "$stderr_file")"
  if grep -qiE 'not logged in|authenticate|gh auth login|authentication required' "$stderr_file"; then
    GH_API_FALLBACK_REASON="gh-not-authenticated"
  elif grep -qiE 'HTTP 401|HTTP 403|HTTP 404|Resource not accessible|Not Found|Forbidden|insufficient_scope|requires authentication' "$stderr_file"; then
    GH_API_FALLBACK_REASON="gh-access-denied"
  else
    GH_API_FALLBACK_REASON="gh-failed"
  fi
  rm -f "$stderr_file"
  return 1
}

github_api_fetch_failure_message() {
  local base_message="$1"

  case "$GH_API_FALLBACK_REASON" in
    gh-success)
      printf '%s\n%s\n' "$base_message" "$GH_API_FALLBACK_DETAIL"
      ;;
    gh-missing)
      printf '%s. gh is not available; set GITHUB_TOKEN or install and authenticate gh, then retry.\n' "$base_message"
      ;;
    gh-not-authenticated)
      printf '%s. gh fallback attempted, but gh is not authenticated; run gh auth login or set GITHUB_TOKEN, then retry.\n' "$base_message"
      ;;
    gh-access-denied)
      printf '%s. gh fallback attempted, but the current gh session/token lacks access to %s: %s\n' "$base_message" "$REPO" "${GH_API_FALLBACK_DETAIL:-<unknown>}"
      ;;
    gh-failed)
      printf '%s. gh fallback attempted, but gh api still failed: %s\n' "$base_message" "${GH_API_FALLBACK_DETAIL:-<unknown>}"
      ;;
    *)
      if [[ -n "$GITHUB_TOKEN" ]]; then
        printf '%s. GITHUB_TOKEN is set but GitHub API is still unavailable; you can also try gh auth login.\n' "$base_message"
      else
        printf '%s. Set GITHUB_TOKEN, or install and authenticate gh, then retry.\n' "$base_message"
      fi
      ;;
  esac
}

format_byte_size() {
  local bytes="${1:-0}"
  awk -v bytes="$bytes" '
    function fmt(value, unit) {
      if (unit == 0) return sprintf("%.0f B", value)
      if (value < 10) return sprintf("%.1f %s", value, suffix[unit])
      return sprintf("%.0f %s", value, suffix[unit])
    }
    BEGIN {
      suffix[1] = "KB"; suffix[2] = "MB"; suffix[3] = "GB"; suffix[4] = "TB"
      if (bytes < 1024) {
        print fmt(bytes, 0)
        exit
      }
      value = bytes / 1024
      unit = 1
      while (value >= 1024 && unit < 4) {
        value /= 1024
        unit++
      }
      print fmt(value, unit)
    }
  '
}

format_duration_seconds() {
  local seconds="${1:-0}"
  awk -v seconds="$seconds" '
    BEGIN {
      if (seconds < 60) {
        printf "%.1fs\n", seconds
      } else if (seconds < 3600) {
        printf "%dm%.0fs\n", int(seconds / 60), seconds % 60
      } else {
        printf "%dh%dm%.0fs\n", int(seconds / 3600), int((seconds % 3600) / 60), seconds % 60
      }
    }
  '
}

curl_download_with_stats() {
  local stats_file="$1"
  shift
  curl "$@" -w '%{size_download}\t%{speed_download}\t%{time_total}\n' >"$stats_file"
}

download_binary() {
  local url="$1"
  local output="$2"
  local label="${3:-download file}"
  local curl_args=(-fL "$url" -o "$output")
  local stats_file bytes_downloaded average_speed elapsed

  if [[ -t 1 ]]; then
    log_info "Starting download: $label"
    if curl --help all 2>/dev/null | grep -F -- '--progress-bar' >/dev/null 2>&1; then
      curl_args=(--progress-bar "${curl_args[@]}")
    fi
  else
    curl_args=(-sS "${curl_args[@]}")
  fi

  stats_file="$(mktemp)"
  if run_with_retry "release-download" curl_download_with_stats "$stats_file" "${curl_args[@]}" >/dev/null; then
    :
  else
    rm -f "$stats_file"
    return 1
  fi

  IFS=$'\t' read -r bytes_downloaded average_speed elapsed <"$stats_file" || true
  rm -f "$stats_file"

  if [[ -n "$bytes_downloaded" && -n "$average_speed" && -n "$elapsed" ]]; then
    log_info "Download complete: $(format_byte_size "$bytes_downloaded"), took $(format_duration_seconds "$elapsed"), avg $(format_byte_size "$average_speed")/s"
  fi
}

json_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

shell_json_get_top_level_string() {
  local json_file="$1"
  local field="$2"
  awk -v key="$field" '
    $0 ~ ("^  \"" key "\"[[:space:]]*:") {
      line = $0
      sub("^  \"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
      sub("\",[[:space:]]*,?[[:space:]]*$", "", line)
      print line
      exit
    }
  ' "$json_file"
}

shell_json_get_top_level_bool() {
  local json_file="$1"
  local field="$2"
  awk -v key="$field" '
    $0 ~ ("^  \"" key "\"[[:space:]]*:") {
      line = $0
      sub("^  \"" key "\"[[:space:]]*:[[:space:]]*", "", line)
      sub("[[:space:]]*,?[[:space:]]*$", "", line)
      if (line == "true") {
        print "true"
      } else {
        print "false"
      }
      exit
    }
  ' "$json_file"
}

shell_state_source_profile_count() {
  local state_file="$1"
  [[ -f "$state_file" ]] || {
    printf '0\n'
    return 0
  }

  awk '
    /^  "source_profiles": \{/ {in_block = 1; next}
    in_block && /^  },?$/ {done = 1; print count + 0; exit}
    in_block && /^    "[^"]+": \{/ {count++}
    END {
      if (!done) {
        print count + 0
      }
    }
  ' "$state_file"
}

ensure_release_only_shell_state() {
  local state_file="$1"
  local feature="${2:-current command}"
  local source_profile_count

  [[ -f "$state_file" ]] || return 0
  source_profile_count="$(shell_state_source_profile_count "$state_file")"
  [[ "$source_profile_count" == "0" ]] && return 0

  die "${feature} detected source profiles in the current state, but python3/jq is missing; cannot handle safely. Install python3 or jq and retry."
}

detect_installed_binary_version() {
  local binary_path="$1"
  local version_line

  [[ -x "$binary_path" ]] || return 0
  version_line="$("$binary_path" --version 2>/dev/null | awk 'NR == 1 {print; exit}')"
  [[ -n "$version_line" ]] || return 0
  printf '%s\n' "$version_line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | awk 'NR == 1 {print; exit}'
}

release_download_root() {
  if [[ -n "$RELEASE_BASE_URL" ]]; then
    printf '%s\n' "${RELEASE_BASE_URL%/}"
    return 0
  fi

  printf 'https://github.com/%s/releases\n' "$REPO"
}

probe_release_asset_url() {
  local url="$1"
  run_with_retry "release-download" curl -fsSL --range 0-0 "$url" >/dev/null
}

emit_release_descriptor_json() {
  local output_file="$1"
  local release_tag="$2"
  local release_name="$3"
  local published_at="$4"
  local html_url="$5"
  local body="$6"
  local asset_name="$7"
  local asset_url="$8"
  local asset_digest="$9"

  {
    printf '{\n'
    printf '  "tag_name": %s,\n' "$(json_quote "$release_tag")"
    printf '  "name": %s,\n' "$(json_quote "$release_name")"
    printf '  "published_at": %s,\n' "$(json_quote "$published_at")"
    printf '  "html_url": %s,\n' "$(json_quote "$html_url")"
    printf '  "body": %s,\n' "$(json_quote "$body")"
    printf '  "assets": [\n'
    printf '    {\n'
    printf '      "name": %s,\n' "$(json_quote "$asset_name")"
    printf '      "browser_download_url": %s,\n' "$(json_quote "$asset_url")"
    printf '      "digest": %s\n' "$(json_quote "$asset_digest")"
    printf '    }\n'
    printf '  ]\n'
    printf '}\n'
  } >"$output_file"
}

resolve_release_direct() {
  local requested="$1"
  local output_file="$2"
  local base_root normalized asset_name="" asset_url="" asset_digest="" release_tag="" release_name="" html_url=""
  local -a asset_candidates=()
  local -a tag_candidates=()
  local candidate tag

  base_root="$(release_download_root)"
  normalized="$(normalize_version "$requested")"

  while IFS= read -r candidate; do
    asset_candidates+=("$candidate")
  done < <(get_asset_candidates)

  if [[ "$requested" == "latest" ]]; then
    for candidate in "${asset_candidates[@]}"; do
      if probe_release_asset_url "${base_root}/latest/download/${candidate}"; then
        asset_name="$candidate"
        asset_url="${base_root}/latest/download/${candidate}"
        release_tag="latest"
        release_name="latest"
        html_url="${base_root}/latest"
        break
      fi
    done
  else
    for tag in "$requested" "$normalized" "v${normalized}" "rust-v${normalized}"; do
      [[ -n "$tag" ]] || continue
      case " ${tag_candidates[*]} " in
        *" ${tag} "*) ;;
        *) tag_candidates+=("$tag") ;;
      esac
    done

    for tag in "${tag_candidates[@]}"; do
      for candidate in "${asset_candidates[@]}"; do
        if probe_release_asset_url "${base_root}/download/${tag}/${candidate}"; then
          asset_name="$candidate"
          asset_url="${base_root}/download/${tag}/${candidate}"
          release_tag="$tag"
          release_name="$(normalize_version "$tag")"
          if [[ -n "$RELEASE_BASE_URL" ]]; then
            html_url="${base_root}/download/${tag}"
          else
            html_url="https://github.com/${REPO}/releases/tag/${tag}"
          fi
          break 2
        fi
      done
    done
  fi

  [[ -n "$asset_name" ]] || die "No release asset found for version ${requested} on this platform: ${asset_candidates[*]}"

  emit_release_descriptor_json \
    "$output_file" \
    "$release_tag" \
    "$release_name" \
    "" \
    "$html_url" \
    "" \
    "$asset_name" \
    "$asset_url" \
    "$asset_digest"
}

json_select_release() {
  local source_file="$1"
  local requested="$2"
  local output_file="$3"
  local normalized
  normalized="$(normalize_version "$requested")"

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$source_file" "$requested" "$normalized" "$output_file" <<'PY'
import json
import sys

source_file, requested, normalized, output_file = sys.argv[1:5]
with open(source_file, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

if isinstance(payload, dict):
    release = payload
else:
    candidates = []
    for value in (requested, normalized, f"v{normalized}", f"rust-v{normalized}"):
        if value and value not in candidates:
            candidates.append(value)

    release = None
    for item in payload:
        tag = item.get("tag_name", "")
        name = item.get("name", "")
        if tag in candidates or name in candidates:
            release = item
            break

    if release is None:
        for item in payload:
            if item.get("name", "") == normalized:
                release = item
                break

if not release:
    sys.exit(1)

with open(output_file, "w", encoding="utf-8") as fh:
    json.dump(release, fh, ensure_ascii=False)
PY
    return
  fi

  require_json_backend "release list parsing"
  jq -cer \
    --arg requested "$requested" \
    --arg normalized "$normalized" \
    '
      if type == "array" then
        (
          map(
            select(
              .tag_name == $requested
              or .name == $requested
              or .tag_name == ("v" + $normalized)
              or .tag_name == ("rust-v" + $normalized)
              or .name == $normalized
              or .name == ("v" + $normalized)
            )
          ) | .[0]
        )
      else
        .
      end
    ' "$source_file" >"$output_file"
}

json_get_field() {
  local json_file="$1"
  local field="$2"
  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$json_file" "$field" <<'PY'
import json
import sys

json_file, field = sys.argv[1:3]
with open(json_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field, "")
if value is None:
    value = ""
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    shell_json_get_top_level_string "$json_file" "$field"
    return
  fi

  jq -r --arg field "$field" '.[$field] // ""' "$json_file"
}

json_find_asset_info() {
  local json_file="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ "$JSON_BACKEND" == "python3" ]]; then
      local output
      output="$(
        python3 - "$json_file" "$candidate" <<'PY'
import json
import sys

json_file, candidate = sys.argv[1:3]
with open(json_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)
for asset in data.get("assets", []):
    if asset.get("name") == candidate:
        print(
            "\t".join(
                [
                    asset.get("name", ""),
                    asset.get("browser_download_url", ""),
                    asset.get("digest", "") or "",
                ]
            )
        )
        break
PY
      )"
      if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
        return 0
      fi
      continue
    fi

    if [[ "$JSON_BACKEND" != "jq" ]]; then
      local name url digest current_name
      name=""
      url=""
      digest=""
      current_name=""
      while IFS= read -r line; do
        case "$line" in
          '      "name": '*)
            current_name="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*"name":[[:space:]]*"([^"]*)".*$/\1/')"
            ;;
          '      "browser_download_url": '*)
            url="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*"browser_download_url":[[:space:]]*"([^"]*)".*$/\1/')"
            ;;
          '      "digest": '*)
            digest="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*"digest":[[:space:]]*"([^"]*)".*$/\1/')"
            ;;
        esac

        if [[ -n "$current_name" && -n "$url" ]]; then
          if [[ "$current_name" == "$candidate" ]]; then
            printf '%s\t%s\t%s\n' "$current_name" "$url" "$digest"
            return 0
          fi
          current_name=""
          url=""
          digest=""
        fi
      done <"$json_file"
      continue
    fi

    local output
    output="$(
      jq -r \
        --arg candidate "$candidate" \
        '.assets[]? | select(.name == $candidate) | [.name, .browser_download_url, (.digest // "")] | @tsv' \
        "$json_file" | head -n 1
    )"
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
  done

  return 1
}

json_array_length() {
  local json_file="$1"
  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
print(len(payload) if isinstance(payload, list) else (1 if payload else 0))
PY
    return
  fi

  require_json_backend "release list parsing"
  jq -r 'if type == "array" then length else (if . then 1 else 0 end) end' "$json_file"
}

json_merge_arrays() {
  local output_file="$1"
  local append_file="$2"
  local temp_file
  temp_file="$(mktemp)"

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$output_file" "$append_file" "$temp_file" <<'PY'
import json
import sys

output_file, append_file, temp_file = sys.argv[1:4]
with open(output_file, "r", encoding="utf-8") as fh:
    left = json.load(fh)
with open(append_file, "r", encoding="utf-8") as fh:
    right = json.load(fh)
if not isinstance(left, list):
    left = [left]
if not isinstance(right, list):
    right = [right]
with open(temp_file, "w", encoding="utf-8") as fh:
    json.dump(left + right, fh, ensure_ascii=False)
PY
    mv "$temp_file" "$output_file"
    return
  fi

  require_json_backend "release list parsing"
  jq -s '.[0] + .[1]' "$output_file" "$append_file" >"$temp_file"
  mv "$temp_file" "$output_file"
}

json_emit_matching_releases() {
  local json_file="$1"
  shift

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$json_file" "$@" <<'PY'
import json
import sys

def normalize_version(value: str) -> str:
    if not value:
        return ""
    if value.startswith("rust-v"):
        return value[6:]
    if value.startswith("v"):
        return value[1:]
    return value

json_file = sys.argv[1]
candidates = sys.argv[2:]
with open(json_file, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

if isinstance(payload, dict):
    payload = [payload]

for release in payload:
    assets = release.get("assets") or []
    asset = None
    for candidate in candidates:
        for item in assets:
            if item.get("name") == candidate:
                asset = item
                break
        if asset is not None:
            break

    if asset is None:
        continue

    tag = release.get("tag_name", "") or ""
    name = release.get("name", "") or ""
    print(
        "\t".join(
            [
                normalize_version(tag or name),
                tag,
                name,
                release.get("published_at", "") or "",
                asset.get("name", "") or "",
                asset.get("browser_download_url", "") or "",
                asset.get("digest", "") or "",
                release.get("html_url", "") or "",
            ]
        )
    )
PY
    return
  fi

  require_json_backend "version list"
  jq -r --args "$@" '
    def normalize_version(value):
      if value == null or value == "" then ""
      elif (value | startswith("rust-v")) then value[6:]
      elif (value | startswith("v")) then value[1:]
      else value
      end;
    .[]? as $release
    | ([$ARGS.positional[] as $candidate | $release.assets[]? | select(.name == $candidate)][0] // empty) as $asset
    | select($asset != null)
    | [
        normalize_version($release.tag_name // $release.name // ""),
        ($release.tag_name // ""),
        ($release.name // ""),
        ($release.published_at // ""),
        ($asset.name // ""),
        ($asset.browser_download_url // ""),
        ($asset.digest // ""),
        ($release.html_url // "")
      ]
    | @tsv
  ' "$json_file"
}

write_state_file() {
  local state_file="$1"
  local installed_version="$2"
  local release_tag="$3"
  local release_name="$4"
  local asset_name="$5"
  local binary_path="$6"
  local controller_path="$7"
  local command_dir="$8"
  local hodex_wrapper="$9"
  local hodexctl_wrapper="${10}"
  local path_update_mode="${11}"
  local path_profile="${12}"
  local path_managed_by_hodexctl="${13}"
  local path_detected_source="${14}"
  local node_setup_choice="${15}"
  local installed_at="${16}"

  mkdir -p "$(dirname "$state_file")"

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - \
      "$state_file" \
      "$REPO" \
      "$installed_version" \
      "$release_tag" \
      "$release_name" \
      "$asset_name" \
      "$binary_path" \
      "$controller_path" \
      "$command_dir" \
      "$hodex_wrapper" \
      "$hodexctl_wrapper" \
      "$path_update_mode" \
      "$path_profile" \
      "$path_managed_by_hodexctl" \
      "$path_detected_source" \
      "$node_setup_choice" \
      "$installed_at" <<'PY'
import json
import sys

(
    state_file,
    repo,
    installed_version,
    release_tag,
    release_name,
    asset_name,
    binary_path,
    controller_path,
    command_dir,
    hodex_wrapper,
    hodexctl_wrapper,
    path_update_mode,
    path_profile,
    path_managed_by_hodexctl,
    path_detected_source,
    node_setup_choice,
    installed_at,
) = sys.argv[1:]

payload = {
    "schema_version": 2,
    "repo": repo,
    "installed_version": installed_version,
    "release_tag": release_tag,
    "release_name": release_name,
    "asset_name": asset_name,
    "binary_path": binary_path,
    "controller_path": controller_path,
    "command_dir": command_dir,
    "wrappers_created": [hodex_wrapper, hodexctl_wrapper],
    "path_update_mode": path_update_mode,
    "path_profile": path_profile,
    "path_managed_by_hodexctl": str(path_managed_by_hodexctl).lower() == "true",
    "path_detected_source": path_detected_source,
    "node_setup_choice": node_setup_choice,
    "installed_at": installed_at,
}

existing = {}
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        existing = json.load(fh)
except FileNotFoundError:
    existing = {}
except json.JSONDecodeError:
    existing = {}

source_profiles = existing.get("source_profiles", {})
if not isinstance(source_profiles, dict):
    source_profiles = {}

active_runtime_aliases = existing.get("active_runtime_aliases", {})
if not isinstance(active_runtime_aliases, dict):
    active_runtime_aliases = {}

if payload.get("binary_path"):
    active_runtime_aliases["hodex"] = "release"
else:
    active_runtime_aliases.pop("hodex", None)
active_runtime_aliases.pop("hodex_stable", None)

payload["source_profiles"] = source_profiles
payload["active_runtime_aliases"] = active_runtime_aliases

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    ensure_release_only_shell_state "$state_file" "write release install state"
    {
      printf '{\n'
      printf '  "schema_version": 2,\n'
      printf '  "repo": %s,\n' "$(json_quote "$REPO")"
      printf '  "installed_version": %s,\n' "$(json_quote "$installed_version")"
      printf '  "release_tag": %s,\n' "$(json_quote "$release_tag")"
      printf '  "release_name": %s,\n' "$(json_quote "$release_name")"
      printf '  "asset_name": %s,\n' "$(json_quote "$asset_name")"
      printf '  "binary_path": %s,\n' "$(json_quote "$binary_path")"
      printf '  "controller_path": %s,\n' "$(json_quote "$controller_path")"
      printf '  "command_dir": %s,\n' "$(json_quote "$command_dir")"
      printf '  "wrappers_created": [\n'
      printf '    %s,\n' "$(json_quote "$hodex_wrapper")"
      printf '    %s\n' "$(json_quote "$hodexctl_wrapper")"
      printf '  ],\n'
      printf '  "path_update_mode": %s,\n' "$(json_quote "$path_update_mode")"
      printf '  "path_profile": %s,\n' "$(json_quote "$path_profile")"
      printf '  "path_managed_by_hodexctl": %s,\n' "$(if [[ "$path_managed_by_hodexctl" == "true" ]]; then printf 'true'; else printf 'false'; fi)"
      printf '  "path_detected_source": %s,\n' "$(json_quote "$path_detected_source")"
      printf '  "node_setup_choice": %s,\n' "$(json_quote "$node_setup_choice")"
      printf '  "installed_at": %s,\n' "$(json_quote "$installed_at")"
      printf '  "source_profiles": {},\n'
      printf '  "active_runtime_aliases": {\n'
      printf '    "hodex": "release"\n'
      printf '  }\n'
      printf '}\n'
    } >"$state_file"
    return
  fi

  local existing_file
  existing_file="$(mktemp)"
  if [[ -f "$state_file" ]]; then
    cp "$state_file" "$existing_file"
  else
    printf '{}\n' >"$existing_file"
  fi

  jq -n \
    --arg repo "$REPO" \
    --arg installed_version "$installed_version" \
    --arg release_tag "$release_tag" \
    --arg release_name "$release_name" \
    --arg asset_name "$asset_name" \
    --arg binary_path "$binary_path" \
    --arg controller_path "$controller_path" \
    --arg command_dir "$command_dir" \
    --arg hodex_wrapper "$hodex_wrapper" \
    --arg hodexctl_wrapper "$hodexctl_wrapper" \
    --arg path_update_mode "$path_update_mode" \
    --arg path_profile "$path_profile" \
    --arg path_managed_by_hodexctl "$path_managed_by_hodexctl" \
    --arg path_detected_source "$path_detected_source" \
    --arg node_setup_choice "$node_setup_choice" \
    --arg installed_at "$installed_at" \
    --slurpfile existing "$existing_file" \
    '($existing[0] // {}) as $existing
    | ($existing.active_runtime_aliases // {}) as $aliases
    | {
        schema_version: 2,
        repo: $repo,
        installed_version: $installed_version,
        release_tag: $release_tag,
        release_name: $release_name,
        asset_name: $asset_name,
        binary_path: $binary_path,
        controller_path: $controller_path,
        command_dir: $command_dir,
        wrappers_created: [$hodex_wrapper, $hodexctl_wrapper],
        path_update_mode: $path_update_mode,
        path_profile: $path_profile,
        path_managed_by_hodexctl: ($path_managed_by_hodexctl == "true"),
        path_detected_source: $path_detected_source,
        node_setup_choice: $node_setup_choice,
        installed_at: $installed_at,
        source_profiles: ($existing.source_profiles // {}),
        active_runtime_aliases: (
          if $binary_path != "" then
            (($aliases + {hodex: "release"}) | del(.hodex_stable))
          else
            ($aliases | del(.hodex) | del(.hodex_stable))
          end
        )
      }' >"$state_file.tmp.$$"
  mv "$state_file.tmp.$$" "$state_file"
  rm -f "$existing_file"
}

persist_release_state_snapshot() {
  local state_file="$1"

  # Read caller-provided state_* locals via bash dynamic scope to keep the
  # write_state_file argument list consistent across install flows.
  write_state_file \
    "$state_file" \
    "$state_installed_version" \
    "$state_release_tag" \
    "$state_release_name" \
    "$state_asset_name" \
    "$state_binary_path" \
    "$state_controller_path" \
    "$COMMAND_DIR" \
    "$COMMAND_DIR/hodex" \
    "$COMMAND_DIR/hodexctl" \
    "$PATH_UPDATE_MODE" \
    "$PATH_PROFILE" \
    "$PATH_MANAGED_BY_HODEXCTL" \
    "$PATH_DETECTED_SOURCE" \
    "$state_node_setup_choice" \
    "$state_installed_at"
}

load_state_env() {
  local state_file="$1"
  [[ -f "$state_file" ]] || die "State file not found: $state_file"

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    eval "$(
      python3 - "$state_file" <<'PY'
import json
import shlex
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

mapping = {
    "STATE_INSTALLED_VERSION": data.get("installed_version", ""),
    "STATE_RELEASE_TAG": data.get("release_tag", ""),
    "STATE_RELEASE_NAME": data.get("release_name", ""),
    "STATE_ASSET_NAME": data.get("asset_name", ""),
    "STATE_BINARY_PATH": data.get("binary_path", ""),
    "STATE_CONTROLLER_PATH": data.get("controller_path", ""),
    "STATE_COMMAND_DIR": data.get("command_dir", ""),
    "STATE_PATH_UPDATE_MODE": data.get("path_update_mode", ""),
    "STATE_PATH_PROFILE": data.get("path_profile", ""),
    "STATE_PATH_MANAGED_BY_HODEXCTL": "true" if data.get("path_managed_by_hodexctl", False) else "false",
    "STATE_PATH_DETECTED_SOURCE": data.get("path_detected_source", ""),
    "STATE_NODE_SETUP_CHOICE": data.get("node_setup_choice", ""),
    "STATE_INSTALLED_AT": data.get("installed_at", ""),
}
for key, value in mapping.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
    )"
  elif [[ "$JSON_BACKEND" == "jq" ]]; then
    eval "$(
      jq -r '
        [
          "STATE_INSTALLED_VERSION=" + (.installed_version // "" | @sh),
          "STATE_RELEASE_TAG=" + (.release_tag // "" | @sh),
          "STATE_RELEASE_NAME=" + (.release_name // "" | @sh),
          "STATE_ASSET_NAME=" + (.asset_name // "" | @sh),
          "STATE_BINARY_PATH=" + (.binary_path // "" | @sh),
          "STATE_CONTROLLER_PATH=" + ((.controller_path // "") | @sh),
          "STATE_COMMAND_DIR=" + (.command_dir // "" | @sh),
          "STATE_PATH_UPDATE_MODE=" + (.path_update_mode // "" | @sh),
          "STATE_PATH_PROFILE=" + (.path_profile // "" | @sh),
          "STATE_PATH_MANAGED_BY_HODEXCTL=" + (if (.path_managed_by_hodexctl // false) then "true" else "false" end | @sh),
          "STATE_PATH_DETECTED_SOURCE=" + (.path_detected_source // "" | @sh),
          "STATE_NODE_SETUP_CHOICE=" + (.node_setup_choice // "" | @sh),
          "STATE_INSTALLED_AT=" + (.installed_at // "" | @sh)
        ] | .[]
      ' "$state_file"
    )"
  else
    ensure_release_only_shell_state "$state_file" "read install state"
    STATE_INSTALLED_VERSION="$(shell_json_get_top_level_string "$state_file" "installed_version")"
    STATE_RELEASE_TAG="$(shell_json_get_top_level_string "$state_file" "release_tag")"
    STATE_RELEASE_NAME="$(shell_json_get_top_level_string "$state_file" "release_name")"
    STATE_ASSET_NAME="$(shell_json_get_top_level_string "$state_file" "asset_name")"
    STATE_BINARY_PATH="$(shell_json_get_top_level_string "$state_file" "binary_path")"
    STATE_CONTROLLER_PATH="$(shell_json_get_top_level_string "$state_file" "controller_path")"
    STATE_COMMAND_DIR="$(shell_json_get_top_level_string "$state_file" "command_dir")"
    STATE_PATH_UPDATE_MODE="$(shell_json_get_top_level_string "$state_file" "path_update_mode")"
    STATE_PATH_PROFILE="$(shell_json_get_top_level_string "$state_file" "path_profile")"
    STATE_PATH_MANAGED_BY_HODEXCTL="$(shell_json_get_top_level_bool "$state_file" "path_managed_by_hodexctl")"
    STATE_PATH_DETECTED_SOURCE="$(shell_json_get_top_level_string "$state_file" "path_detected_source")"
    STATE_NODE_SETUP_CHOICE="$(shell_json_get_top_level_string "$state_file" "node_setup_choice")"
    STATE_INSTALLED_AT="$(shell_json_get_top_level_string "$state_file" "installed_at")"
  fi

  if [[ -z "$STATE_CONTROLLER_PATH" ]]; then
    STATE_CONTROLLER_PATH="$STATE_DIR/libexec/hodexctl.sh"
  fi
  if [[ -z "$STATE_PATH_MANAGED_BY_HODEXCTL" ]]; then
    STATE_PATH_MANAGED_BY_HODEXCTL="false"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-Y}"
  local answer

  if ((AUTO_YES)); then
    case "$default_answer" in
      Y | y) return 0 ;;
      *) return 1 ;;
    esac
  fi

  printf 'Awaiting confirmation input; press Enter to accept default %s.\n' "$default_answer"
  printf '%s' "$prompt"
  read -r answer
  printf '\n'
  case "${answer:-$default_answer}" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

current_utc_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

state_get_active_hodex_alias() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

aliases = payload.get("active_runtime_aliases", {})
if isinstance(aliases, dict):
    value = aliases.get("hodex", "") or ""
    if not value and payload.get("binary_path"):
        value = "release"
    print(value)
else:
    print("release" if payload.get("binary_path") else "")
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    ensure_release_only_shell_state "$state_file" "read active hodex target"
    local active_alias
    active_alias="$(
      awk '
        /^  "active_runtime_aliases": \{/ {in_block = 1; next}
        in_block && /^  },?$/ {exit}
        in_block && /^    "hodex": "/ {
          line = $0
          sub(/^[[:space:]]*"hodex":[[:space:]]*"/, "", line)
          sub(/".*$/, "", line)
          print line
          exit
        }
      ' "$state_file"
    )"
    if [[ "$active_alias" == "release" ]]; then
      printf '%s\n' "$active_alias"
    elif [[ -n "$(shell_json_get_top_level_string "$state_file" "binary_path")" ]]; then
      printf 'release\n'
    fi
    return
  fi

  jq -r '
    if (.active_runtime_aliases.hodex // "") == "release" then
      "release"
    elif (.binary_path // "") != "" then
      "release"
    else
      ""
    end
  ' "$state_file"
}

state_count_source_profiles() {
  local state_file="$1"
  [[ -f "$state_file" ]] || {
    printf '0\n'
    return 0
  }

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

profiles = payload.get("source_profiles", {})
print(len(profiles) if isinstance(profiles, dict) else 0)
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    shell_state_source_profile_count "$state_file"
    return
  fi

  jq -r '(.source_profiles // {}) | if type == "object" then length else 0 end' "$state_file"
}

state_emit_source_profiles() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

profiles = payload.get("source_profiles", {})
if not isinstance(profiles, dict):
    profiles = {}

for name, profile in sorted(profiles.items()):
    if not isinstance(profile, dict):
        profile = {}
    print(
        "\t".join(
            [
                name,
                str(profile.get("repo_input", "") or ""),
                str(profile.get("remote_url", "") or ""),
                str(profile.get("checkout_dir", "") or ""),
                str(profile.get("workspace_mode", "") or ""),
                str(profile.get("current_ref", "") or ""),
                str(profile.get("ref_kind", "") or ""),
                str(profile.get("build_workspace_root", "") or ""),
                str(profile.get("binary_path", "") or ""),
                str(profile.get("wrapper_path", "") or ""),
                str(profile.get("installed_at", "") or ""),
                str(profile.get("last_synced_at", profile.get("last_built_at", "")) or ""),
                "false",
            ]
        )
    )
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    ensure_release_only_shell_state "$state_file" "read source profiles list"
    return 0
  fi

  jq -r '
    (.source_profiles // {})
    | to_entries[]
    | [
        .key,
        (.value.repo_input // ""),
        (.value.remote_url // ""),
        (.value.checkout_dir // ""),
        (.value.workspace_mode // ""),
        (.value.current_ref // ""),
        (.value.ref_kind // ""),
        (.value.build_workspace_root // ""),
        (.value.binary_path // ""),
        (.value.wrapper_path // ""),
        (.value.installed_at // ""),
        (.value.last_synced_at // .value.last_built_at // ""),
        "false"
      ]
    | @tsv
  ' "$state_file"
}

state_get_source_profile_field() {
  local state_file="$1"
  local profile_name="$2"
  local field_name="$3"
  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" "$profile_name" "$field_name" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

profile = (payload.get("source_profiles", {}) or {}).get(sys.argv[2], {})
if not isinstance(profile, dict):
    profile = {}
value = profile.get(sys.argv[3], "")
if sys.argv[3] == "last_synced_at" and (value == "" or value is None):
    value = profile.get("last_built_at", "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
    return
  fi

  jq -r --arg name "$profile_name" --arg field "$field_name" '
    (.source_profiles[$name][$field] // "") as $value
    | if ($value | type) == "boolean" then (if $value then "true" else "false" end) else $value end
  ' "$state_file"
}

state_source_profile_exists() {
  local state_file="$1"
  local profile_name="$2"

  [[ -f "$state_file" ]] || return 1
  if [[ -n "$(state_get_source_profile_field "$state_file" "$profile_name" "name")" ]]; then
    return 0
  fi
  return 1
}

state_upsert_source_profile() {
  local state_file="$1"
  local name="$2"
  local repo_input="$3"
  local remote_url="$4"
  local checkout_dir="$5"
  local workspace_mode="$6"
  local current_ref="$7"
  local ref_kind="$8"
  local build_workspace_root="$9"
  local binary_path="${10}"
  local wrapper_path="${11}"
  local installed_at="${12}"
  local last_synced_at="${13}"
  local toolchain_snapshot_json="${14}"
  local activation_mode="${15}"
  local command_dir="${16}"
  local controller_path="${17}"

  mkdir -p "$(dirname "$state_file")"
  [[ -n "$toolchain_snapshot_json" ]] || toolchain_snapshot_json='{}'

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - \
      "$state_file" \
      "$name" \
      "$repo_input" \
      "$remote_url" \
      "$checkout_dir" \
      "$workspace_mode" \
      "$current_ref" \
      "$ref_kind" \
      "$build_workspace_root" \
      "$binary_path" \
      "$wrapper_path" \
      "$installed_at" \
      "$last_synced_at" \
      "$toolchain_snapshot_json" \
      "$activation_mode" \
      "$command_dir" \
      "$controller_path" <<'PY'
import json
import os
import sys

(
    state_file,
    name,
    repo_input,
    remote_url,
    checkout_dir,
    workspace_mode,
    current_ref,
    ref_kind,
    build_workspace_root,
    binary_path,
    wrapper_path,
    installed_at,
    last_synced_at,
    toolchain_snapshot_json,
    activation_mode,
    command_dir,
    controller_path,
) = sys.argv[1:]

payload = {}
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

profiles = payload.get("source_profiles", {})
if not isinstance(profiles, dict):
    profiles = {}

aliases = payload.get("active_runtime_aliases", {})
if not isinstance(aliases, dict):
    aliases = {}

existing = profiles.get(name, {})
if not isinstance(existing, dict):
    existing = {}

toolchain_snapshot = {}
if toolchain_snapshot_json:
    try:
        toolchain_snapshot = json.loads(toolchain_snapshot_json)
    except json.JSONDecodeError:
        toolchain_snapshot = {"raw": toolchain_snapshot_json}

profile = {
    "name": name,
    "repo_input": repo_input,
    "remote_url": remote_url,
    "checkout_dir": checkout_dir,
    "workspace_mode": workspace_mode,
    "current_ref": current_ref,
    "ref_kind": ref_kind,
    "build_workspace_root": build_workspace_root,
    "binary_path": binary_path,
    "wrapper_path": wrapper_path,
    "installed_at": installed_at or existing.get("installed_at", ""),
    "last_synced_at": last_synced_at,
    "toolchain_snapshot": toolchain_snapshot,
    "activated_as_hodex": False,
}

profiles[name] = profile
payload["schema_version"] = 2
payload["source_profiles"] = profiles
payload["command_dir"] = command_dir or payload.get("command_dir", "")
payload["controller_path"] = controller_path or payload.get("controller_path", "")

release_installed = bool(payload.get("binary_path"))
if release_installed:
    aliases["hodex"] = "release"
else:
    aliases.pop("hodex", None)
aliases.pop("hodex_stable", None)

payload["active_runtime_aliases"] = aliases

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    return
  fi

  local existing_file
  existing_file="$(mktemp)"
  if [[ -f "$state_file" ]]; then
    cp "$state_file" "$existing_file"
  else
    printf '{}\n' >"$existing_file"
  fi

  jq \
    --arg name "$name" \
    --arg repo_input "$repo_input" \
    --arg remote_url "$remote_url" \
    --arg checkout_dir "$checkout_dir" \
    --arg workspace_mode "$workspace_mode" \
    --arg current_ref "$current_ref" \
    --arg ref_kind "$ref_kind" \
    --arg build_workspace_root "$build_workspace_root" \
    --arg binary_path "$binary_path" \
    --arg wrapper_path "$wrapper_path" \
    --arg installed_at "$installed_at" \
    --arg last_synced_at "$last_synced_at" \
    --arg activation_mode "$activation_mode" \
    --arg command_dir "$command_dir" \
    --arg controller_path "$controller_path" \
    --argjson toolchain_snapshot "$toolchain_snapshot_json" '
    .schema_version = 2
    | .source_profiles = (.source_profiles // {})
    | .active_runtime_aliases = (.active_runtime_aliases // {})
    | .command_dir = ($command_dir // .command_dir)
    | .controller_path = ($controller_path // .controller_path)
    | (.source_profiles[$name] // {}) as $existing
    | .source_profiles[$name] = {
        name: $name,
        repo_input: $repo_input,
        remote_url: $remote_url,
        checkout_dir: $checkout_dir,
        workspace_mode: $workspace_mode,
        current_ref: $current_ref,
        ref_kind: $ref_kind,
        build_workspace_root: $build_workspace_root,
        binary_path: $binary_path,
        wrapper_path: $wrapper_path,
        installed_at: (if $installed_at == "" then ($existing.installed_at // "") else $installed_at end),
        last_synced_at: $last_synced_at,
        toolchain_snapshot: $toolchain_snapshot,
        activated_as_hodex: false
      }
    | if (.binary_path // "") != "" then
        .active_runtime_aliases.hodex = "release" | del(.active_runtime_aliases.hodex_stable)
      else
        del(.active_runtime_aliases.hodex) | del(.active_runtime_aliases.hodex_stable)
      end
  ' "$existing_file" >"$state_file"
  rm -f "$existing_file"
}

state_update_runtime_metadata() {
  local state_file="$1"
  local command_dir="$2"
  local controller_path="$3"
  local path_update_mode="$4"
  local path_profile="$5"
  local path_managed_by_hodexctl="$6"
  local path_detected_source="$7"

  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" "$command_dir" "$controller_path" "$path_update_mode" "$path_profile" "$path_managed_by_hodexctl" "$path_detected_source" <<'PY'
import json
import sys

state_file, command_dir, controller_path, path_update_mode, path_profile, path_managed_by_hodexctl, path_detected_source = sys.argv[1:8]

with open(state_file, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

payload["command_dir"] = command_dir
payload["controller_path"] = controller_path
payload["path_update_mode"] = path_update_mode
payload["path_profile"] = path_profile
payload["path_managed_by_hodexctl"] = str(path_managed_by_hodexctl).lower() == "true"
payload["path_detected_source"] = path_detected_source

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    return
  fi

  jq \
    --arg command_dir "$command_dir" \
    --arg controller_path "$controller_path" \
    --arg path_update_mode "$path_update_mode" \
    --arg path_profile "$path_profile" \
    --arg path_managed_by_hodexctl "$path_managed_by_hodexctl" \
    --arg path_detected_source "$path_detected_source" '
    .command_dir = $command_dir
    | .controller_path = $controller_path
    | .path_update_mode = $path_update_mode
    | .path_profile = $path_profile
    | .path_managed_by_hodexctl = ($path_managed_by_hodexctl == "true")
    | .path_detected_source = $path_detected_source
  ' "$state_file" >"$state_file.tmp.$$"
  mv "$state_file.tmp.$$" "$state_file"
}

state_remove_source_profile() {
  local state_file="$1"
  local profile_name="$2"
  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" "$profile_name" <<'PY'
import json
import sys

state_file, profile_name = sys.argv[1:3]

try:
    with open(state_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

profiles = payload.get("source_profiles", {})
if not isinstance(profiles, dict):
    profiles = {}
profiles.pop(profile_name, None)
payload["source_profiles"] = profiles

aliases = payload.get("active_runtime_aliases", {})
if not isinstance(aliases, dict):
    aliases = {}

if payload.get("binary_path"):
    aliases["hodex"] = "release"
else:
    aliases.pop("hodex", None)
aliases.pop("hodex_stable", None)

payload["active_runtime_aliases"] = aliases
payload["schema_version"] = 2

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    return
  fi

  jq --arg name "$profile_name" '
    .schema_version = 2
    | .source_profiles = ((.source_profiles // {}) | del(.[$name]))
    | .active_runtime_aliases = (.active_runtime_aliases // {})
    | if (.binary_path // "") != "" then
        .active_runtime_aliases.hodex = "release" | del(.active_runtime_aliases.hodex_stable)
      else
        del(.active_runtime_aliases.hodex) | del(.active_runtime_aliases.hodex_stable)
      end
  ' "$state_file" >"$state_file.tmp.$$"
  mv "$state_file.tmp.$$" "$state_file"
}

clear_release_state_file() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$state_file" <<'PY'
import json
import sys

state_file = sys.argv[1]
try:
    with open(state_file, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    payload = {}

for key in [
    "repo",
    "installed_version",
    "release_tag",
    "release_name",
    "asset_name",
    "binary_path",
    "wrappers_created",
    "node_setup_choice",
    "installed_at",
]:
    payload[key] = "" if key != "wrappers_created" else []

aliases = payload.get("active_runtime_aliases", {})
if not isinstance(aliases, dict):
    aliases = {}

if aliases.get("hodex") == "release":
    aliases.pop("hodex", None)
aliases.pop("hodex_stable", None)
payload["active_runtime_aliases"] = aliases
payload["schema_version"] = 2

with open(state_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    return
  fi

  if [[ "$JSON_BACKEND" != "jq" ]]; then
    ensure_release_only_shell_state "$state_file" "clear release install state"
    local controller_path command_dir path_update_mode path_profile path_managed_by_hodexctl path_detected_source
    controller_path="$(shell_json_get_top_level_string "$state_file" "controller_path")"
    command_dir="$(shell_json_get_top_level_string "$state_file" "command_dir")"
    path_update_mode="$(shell_json_get_top_level_string "$state_file" "path_update_mode")"
    path_profile="$(shell_json_get_top_level_string "$state_file" "path_profile")"
    path_managed_by_hodexctl="$(shell_json_get_top_level_bool "$state_file" "path_managed_by_hodexctl")"
    path_detected_source="$(shell_json_get_top_level_string "$state_file" "path_detected_source")"
    {
      printf '{\n'
      printf '  "schema_version": 2,\n'
      printf '  "repo": "",\n'
      printf '  "installed_version": "",\n'
      printf '  "release_tag": "",\n'
      printf '  "release_name": "",\n'
      printf '  "asset_name": "",\n'
      printf '  "binary_path": "",\n'
      printf '  "controller_path": %s,\n' "$(json_quote "$controller_path")"
      printf '  "command_dir": %s,\n' "$(json_quote "$command_dir")"
      printf '  "wrappers_created": [],\n'
      printf '  "path_update_mode": %s,\n' "$(json_quote "$path_update_mode")"
      printf '  "path_profile": %s,\n' "$(json_quote "$path_profile")"
      printf '  "path_managed_by_hodexctl": %s,\n' "$(if [[ "$path_managed_by_hodexctl" == "true" ]]; then printf 'true'; else printf 'false'; fi)"
      printf '  "path_detected_source": %s,\n' "$(json_quote "$path_detected_source")"
      printf '  "node_setup_choice": "",\n'
      printf '  "installed_at": "",\n'
      printf '  "source_profiles": {},\n'
      printf '  "active_runtime_aliases": {}\n'
      printf '}\n'
    } >"$state_file"
    return
  fi

  jq '
    .schema_version = 2
    | .repo = ""
    | .installed_version = ""
    | .release_tag = ""
    | .release_name = ""
    | .asset_name = ""
    | .binary_path = ""
    | .wrappers_created = []
    | .node_setup_choice = ""
    | .installed_at = ""
    | .active_runtime_aliases = (.active_runtime_aliases // {})
    | if (.active_runtime_aliases.hodex // "") == "release" then del(.active_runtime_aliases.hodex) else . end
    | del(.active_runtime_aliases.hodex_stable)
  ' "$state_file" >"$state_file.tmp.$$"
  mv "$state_file.tmp.$$" "$state_file"
}

ensure_dir_writable() {
  local dir="$1"
  mkdir -p "$dir" || die "Failed to create directory: $dir"
  local probe="$dir/.hodex-write-test.$$"
  : >"$probe" || die "Directory not writable: $dir"
  rm -f "$probe"
}

select_command_dir() {
  local preferred_command_dir="$STATE_DIR/commands"

  if [[ -n "$COMMAND_DIR" ]]; then
    ensure_dir_writable "$COMMAND_DIR"
    return
  fi

  if [[ -n "$STATE_COMMAND_DIR" ]]; then
    COMMAND_DIR="$STATE_COMMAND_DIR"
    ensure_dir_writable "$COMMAND_DIR"
    return
  fi

  if ((AUTO_YES)); then
    COMMAND_DIR="$preferred_command_dir"
    ensure_dir_writable "$COMMAND_DIR"
    return
  fi

  local choice custom_dir
  while true; do
    cat <<EOF
Select command directory for hodex / hodexctl:
  1. $preferred_command_dir
  2. $STATE_DIR/bin
  3. Custom directory
EOF
    printf 'Enter choice [1/2/3]: '
    read -r choice
    case "$choice" in
      1)
        COMMAND_DIR="$preferred_command_dir"
        break
        ;;
      2)
        COMMAND_DIR="$STATE_DIR/bin"
        break
        ;;
      3)
        printf 'Enter install directory: '
        read -r custom_dir
        [[ -n "$custom_dir" ]] || {
          log_warn "Directory cannot be empty."
          continue
        }
        COMMAND_DIR="$(normalize_user_path "$custom_dir")"
        break
        ;;
      *)
        log_warn "Please enter 1, 2, or 3."
        ;;
    esac
  done

  ensure_dir_writable "$COMMAND_DIR"
}

select_profile_file() {
  if [[ -n "$STATE_PATH_PROFILE" ]]; then
    printf '%s\n' "$STATE_PATH_PROFILE"
    return
  fi

  if [[ -n "${SHELL:-}" ]]; then
    case "$SHELL" in
      */zsh)
        printf '%s\n' "$HOME/.zshrc"
        return
        ;;
      */bash)
        printf '%s\n' "$HOME/.bashrc"
        return
        ;;
    esac
  fi

  if [[ -f "$HOME/.zshrc" ]]; then
    printf '%s\n' "$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    printf '%s\n' "$HOME/.bashrc"
  else
    printf '%s\n' "$HOME/.profile"
  fi
}

path_profile_targets() {
  local primary_profile="${1:-}"
  local shell_name targets_key target
  local -a targets=()

  if [[ -n "$primary_profile" ]]; then
    targets+=("$primary_profile")
  fi

  shell_name="${SHELL:-}"
  case "$shell_name" in
    */zsh)
      targets+=("$HOME/.zprofile" "$HOME/.zshrc")
      ;;
    */bash)
      targets+=("$HOME/.bash_profile" "$HOME/.bashrc")
      ;;
  esac

  targets_key="|"
  for target in "${targets[@]-}"; do
    [[ -n "$target" ]] || continue
    case "$targets_key" in
      *"|$target|"*) ;;
      *)
        targets_key="${targets_key}${target}|"
        printf '%s\n' "$target"
        ;;
    esac
  done
}

any_path_block_present() {
  local profile_file
  while IFS= read -r profile_file; do
    [[ -f "$profile_file" ]] || continue
    if grep -F "$PATH_BLOCK_START" "$profile_file" >/dev/null 2>&1 || grep -F "$LEGACY_PATH_BLOCK_START" "$profile_file" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

profile_file_has_command_dir_evidence() {
  local profile_file="$1"
  local target="$2"
  [[ -f "$profile_file" ]] || return 1

  if grep -F -- "$target" "$profile_file" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$target" == "$(normalize_user_path "$HOME/.local/bin")" ]]; then
    if grep -E '(^|[[:space:]])(\.|source)[[:space:]]+["'"'"']?(\$HOME|~)/\.local/bin/env["'"'"']?' "$profile_file" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

any_profile_has_command_dir_evidence() {
  local target="$1"
  shift
  local profile_file
  for profile_file in "$@"; do
    [[ -n "$profile_file" ]] || continue
    if profile_file_has_command_dir_evidence "$profile_file" "$target"; then
      return 0
    fi
  done
  return 1
}

is_path_segment_present() {
  local path_value="$1"
  local target="$2"
  case ":$path_value:" in
    *":$target:"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_path_block() {
  local profile_file="$1"
  remove_path_block "$profile_file"
  {
    printf '\n%s\n' "$PATH_BLOCK_START"
    printf 'export PATH="%s:$PATH"\n' "$COMMAND_DIR"
    printf '%s\n' "$PATH_BLOCK_END"
  } >>"$profile_file"
}

update_path_if_needed() {
  PATH_UPDATE_MODE="skipped"
  PATH_PROFILE=""
  PATH_MANAGED_BY_HODEXCTL="false"
  PATH_DETECTED_SOURCE=""

  if ((NO_PATH_UPDATE)); then
    PATH_UPDATE_MODE="disabled"
    PATH_DETECTED_SOURCE="disabled"
    return
  fi

  local profile_file
  profile_file="$(select_profile_file)"
  local -a profile_targets=()
  while IFS= read -r profile_file_target; do
    profile_targets+=("$profile_file_target")
  done < <(path_profile_targets "$profile_file")

  if any_path_block_present < <(printf '%s\n' "${profile_targets[@]-}"); then
    local target
    for target in "${profile_targets[@]-}"; do
      ensure_dir_writable "$(dirname "$target")"
      touch "$target"
      write_path_block "$target"
    done
    PATH_PROFILE="$profile_file"
    PATH_UPDATE_MODE="configured"
    PATH_MANAGED_BY_HODEXCTL="true"
    PATH_DETECTED_SOURCE="managed-profile-block"
    if ! is_path_segment_present "$PATH" "$COMMAND_DIR"; then
      export PATH="$COMMAND_DIR:$PATH"
    fi
    return
  fi

  if any_profile_has_command_dir_evidence "$COMMAND_DIR" "${profile_targets[@]-}"; then
    PATH_PROFILE="$profile_file"
    PATH_DETECTED_SOURCE="preexisting-profile"
    if ! is_path_segment_present "$PATH" "$COMMAND_DIR"; then
      export PATH="$COMMAND_DIR:$PATH"
      PATH_UPDATE_MODE="configured"
    else
      PATH_UPDATE_MODE="already"
    fi
    return
  fi

  PATH_PROFILE="$profile_file"
  if is_path_segment_present "$PATH" "$COMMAND_DIR"; then
    PATH_DETECTED_SOURCE="current-process-only"
  fi

  local should_update=1
  if ((AUTO_YES)); then
    should_update=0
  else
    if [[ "$PATH_DETECTED_SOURCE" == "current-process-only" ]]; then
      printf '%s\n' "Command directory $COMMAND_DIR is only on PATH for this session; no persistent config was found."
    else
      printf '%s\n' "Command directory $COMMAND_DIR is not on PATH."
    fi
    printf 'Add to PATH automatically? [Y/n]: '
    local answer
    read -r answer
    case "${answer:-Y}" in
      y | Y | yes | YES | "")
        should_update=0
        ;;
      *)
        should_update=1
        ;;
    esac
  fi

  if ((should_update)); then
    PATH_UPDATE_MODE="user-skipped"
    if [[ -z "$PATH_DETECTED_SOURCE" ]]; then
      PATH_DETECTED_SOURCE="user-skipped"
    fi
    return
  fi

  local target
  for target in "${profile_targets[@]-}"; do
    ensure_dir_writable "$(dirname "$target")"
    touch "$target"
    write_path_block "$target"
  done
  PATH_PROFILE="$profile_file"
  PATH_UPDATE_MODE="added"
  PATH_MANAGED_BY_HODEXCTL="true"
  PATH_DETECTED_SOURCE="managed-profile-block"

  if ! is_path_segment_present "$PATH" "$COMMAND_DIR"; then
    export PATH="$COMMAND_DIR:$PATH"
  fi
}

remove_path_block() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || return 0

  local temp_file
  temp_file="$(mktemp)"
  awk -v start="$PATH_BLOCK_START" -v end="$PATH_BLOCK_END" -v legacy_start="$LEGACY_PATH_BLOCK_START" -v legacy_end="$LEGACY_PATH_BLOCK_END" '
    $0 == start || $0 == legacy_start { skip = 1; next }
    $0 == end || $0 == legacy_end { skip = 0; next }
    !skip { print }
  ' "$profile_file" >"$temp_file"
  mv "$temp_file" "$profile_file"
}

remove_path_blocks_for_targets() {
  local primary_profile="$1"
  local target
  while IFS= read -r target; do
    remove_path_block "$target"
  done < <(path_profile_targets "$primary_profile")
}

profile_file_has_path_block() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || return 1
  if grep -F "$PATH_BLOCK_START" "$profile_file" >/dev/null 2>&1; then
    return 0
  fi
  if grep -F "$LEGACY_PATH_BLOCK_START" "$profile_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

cleanup_path_blocks_for_uninstall() {
  local primary_profile="$1"
  local -a candidates=()
  local target cleaned=0 seen_key="|"

  if [[ -n "$primary_profile" ]]; then
    candidates+=("$primary_profile")
  fi

  candidates+=(
    "$HOME/.zprofile"
    "$HOME/.zshrc"
    "$HOME/.bash_profile"
    "$HOME/.bashrc"
    "$HOME/.profile"
  )

  for target in "${candidates[@]-}"; do
    [[ -n "$target" ]] || continue
    case "$seen_key" in
      *"|$target|"*) continue ;;
      *) seen_key="${seen_key}${target}|" ;;
    esac
    if profile_file_has_path_block "$target"; then
      remove_path_block "$target"
      cleaned=1
    fi
  done

  if ((cleaned)); then
    log_info "Removed managed PATH blocks."
  fi
}

generate_hodex_wrapper() {
  local wrapper_path="$1"
  local binary_path="$2"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -x "$binary_path" ]]; then
  echo "hodex binary is missing; run hodexctl install first." >&2
  exit 1
fi
exec "$binary_path" "\$@"
EOF
  chmod 0755 "$wrapper_path"
}

generate_runtime_wrapper() {
  local wrapper_path="$1"
  local binary_path="$2"
  local command_name="$3"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -x "$binary_path" ]]; then
  echo "${command_name} binary is missing; rerun hodexctl install or rebuild." >&2
  exit 1
fi
exec "$binary_path" "\$@"
EOF
  chmod 0755 "$wrapper_path"
}

generate_hodexctl_wrapper() {
  local wrapper_path="$1"
  local controller_path="$2"
  local state_dir="$3"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f "$controller_path" ]]; then
  echo "hodexctl manager script copy is missing; reinstall hodexctl." >&2
  exit 1
fi
export HODEX_DISPLAY_NAME="hodexctl"
export HODEX_STATE_DIR="$state_dir"
if [[ "\$#" -eq 0 ]]; then
  exec "$controller_path" help
fi
exec "$controller_path" "\$@"
EOF
  chmod 0755 "$wrapper_path"
}

sync_controller_copy() {
  local target_path="$1"
  local target_dir
  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir"

  if [[ -f "$SELF_PATH" && "$SELF_PATH" != "/dev/stdin" && "$SELF_PATH" != "bash" ]]; then
    if [[ -e "$target_path" && "$SELF_PATH" -ef "$target_path" ]]; then
      chmod 0755 "$target_path" 2>/dev/null || true
      return
    fi
    cp "$SELF_PATH" "$target_path"
    chmod 0755 "$target_path"
    return
  fi

  local raw_url="${CONTROLLER_URL_BASE}/${REPO}/${CONTROLLER_REF}/scripts/hodexctl/hodexctl.sh"
  log_step "Download hodexctl manager script"
  download_binary "$raw_url" "$target_path" "Downloading hodexctl.sh"
  chmod 0755 "$target_path"
}

resolve_release() {
  local requested="$1"
  local output_file="$2"
  local temp_json
  init_json_backend_if_available

  if [[ -n "$RELEASE_BASE_URL" || -z "$JSON_BACKEND" ]]; then
    resolve_release_direct "$requested" "$output_file"
    return
  fi

  temp_json="$(mktemp)"

  if [[ "$requested" == "latest" ]]; then
    http_get_to_file "https://api.github.com/repos/${REPO}/releases/latest" "$temp_json" \
      || die "$(github_api_fetch_failure_message "Failed to fetch latest release; check repo, GitHub API rate limits, or network.")"
    mv "$temp_json" "$output_file"
    return
  fi

  http_get_to_file "https://api.github.com/repos/${REPO}/releases?per_page=100" "$temp_json" \
    || die "$(github_api_fetch_failure_message "Failed to fetch release list; check repo, GitHub API rate limits, or network.")"

  if ! json_select_release "$temp_json" "$requested" "$output_file"; then
    rm -f "$temp_json"
    die "Release not found for version $requested."
  fi

  rm -f "$temp_json"
}

fetch_all_releases() {
  local output_file="$1"
  local page=1
  local page_file count

  require_json_backend "version list"

  printf '[]\n' >"$output_file"

  while true; do
    page_file="$(mktemp)"
    if ! http_get_to_file "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}" "$page_file"; then
      rm -f "$page_file"
      die "$(github_api_fetch_failure_message "Failed to fetch release list; check repo, GitHub API rate limits, or network.")"
    fi

    count="$(json_array_length "$page_file")"
    if [[ "$count" == "0" ]]; then
      rm -f "$page_file"
      break
    fi

    json_merge_arrays "$output_file" "$page_file"
    rm -f "$page_file"

    if ((count < 100)); then
      break
    fi

    page=$((page + 1))
  done
}

compute_sha256() {
  local file_path="$1"
  if command_exists shasum; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return
  fi
  if command_exists sha256sum; then
    sha256sum "$file_path" | awk '{print $1}'
    return
  fi
  if command_exists openssl; then
    openssl dgst -sha256 "$file_path" | awk '{print $NF}'
    return
  fi
  printf '\n'
}

verify_digest_if_present() {
  local download_path="$1"
  local asset_digest="$2"
  if [[ -z "$asset_digest" ]]; then
    log_warn "Release did not provide a digest; skipping SHA-256 verification."
    return
  fi
  if [[ "$asset_digest" != sha256:* ]]; then
    log_warn "Unsupported digest format: $asset_digest"
    return
  fi

  local expected actual
  expected="${asset_digest#sha256:}"
  actual="$(compute_sha256 "$download_path")"
  [[ -n "$actual" ]] || die "No available SHA-256 verification command in this environment."
  [[ "$actual" == "$expected" ]] || die "SHA-256 verification failed: expected $expected, got $actual"
  log_step "SHA-256 verified: $actual"
}

fetch_matching_release_lines() {
  local releases_file="$1"
  local -a asset_candidates=()
  local candidate

  while IFS= read -r candidate; do
    asset_candidates+=("$candidate")
  done < <(get_asset_candidates)

  json_emit_matching_releases "$releases_file" "${asset_candidates[@]}"
}

maybe_show_in_pager() {
  local content="$1"
  if [[ -t 0 && -t 1 ]] && command_exists less; then
    printf '%s\n' "$content" | less -RFX
    return
  fi
  printf '%s\n' "$content"
}

build_release_details_text() {
  local release_file="$1"
  local selected_version="$2"
  local release_tag release_name published_at asset_name html_url body output
  local -a asset_candidates=()
  local candidate

  release_tag="$(json_get_field "$release_file" "tag_name")"
  release_name="$(json_get_field "$release_file" "name")"
  published_at="$(json_get_field "$release_file" "published_at")"
  html_url="$(json_get_field "$release_file" "html_url")"
  body="$(json_get_field "$release_file" "body")"

  while IFS= read -r candidate; do
    asset_candidates+=("$candidate")
  done < <(get_asset_candidates)

  asset_name="$(json_find_asset_info "$release_file" "${asset_candidates[@]}" | awk -F '\t' 'NR==1 {print $1}')"

  output="Version: ${selected_version}
Release: ${release_name:-<unknown>} (${release_tag:-<unknown>})
Published: ${published_at:-<unknown>}
Asset: ${asset_name:-<unknown>}
Page: ${html_url:-<unknown>}

Changelog:
"

  if [[ -n "$body" ]]; then
    output+="$body"
  else
    output+="<No changelog provided for this release>"
  fi

  printf '%s' "$output"
}

build_release_summary_prompt() {
  local release_file="$1"
  local selected_version="$2"
  local release_tag release_name published_at html_url body

  release_tag="$(json_get_field "$release_file" "tag_name")"
  release_name="$(json_get_field "$release_file" "name")"
  published_at="$(json_get_field "$release_file" "published_at")"
  html_url="$(json_get_field "$release_file" "html_url")"
  body="$(json_get_field "$release_file" "body")"

  if [[ -z "$body" ]]; then
    body="<No changelog provided for this release>"
  fi

  cat <<EOF
Please summarize the full changelog for the Hodex release below in English.

Requirements:
1. Output only the final summary. Do not include analysis, reasoning, drafts, or extra preface.
2. Organize the summary by category. Recommended order:
   - New features
   - Improvements
   - Fixes
   - Breaking changes / migration
   - Other notes
3. Omit empty categories and do not invent content.
4. Use concise bullet points for each category, prioritizing the most important changes.
5. If there are breaking changes, compatibility impacts, config changes, or manual steps, call them out explicitly.
6. Do not omit important information or invent content not in the changelog.
7. Start directly with the summary content. Do not add a "Summary" preface.

Version: ${selected_version}
Release: ${release_name:-<unknown>} (${release_tag:-<unknown>})
Published: ${published_at:-<unknown>}
Page: ${html_url:-<unknown>}

Full changelog:
${body}
EOF
}

release_summary_agent_candidates() {
  if command_exists hodex; then
    printf 'hodex\n'
  fi
  if command_exists codex; then
    printf 'codex\n'
  fi
}

agent_supports_exec() {
  local agent_command="$1"
  "$agent_command" exec --help >/dev/null 2>&1
}

pause_after_release_summary() {
  if [[ -t 0 && -t 1 ]]; then
    printf '\nPress Enter to return to release details...'
    read -r _
  fi
}

clear_screen_if_interactive() {
  if [[ -t 0 && -t 1 ]]; then
    printf '\033[H\033[2J'
  fi
}

parse_release_summary_json_stream_python() {
  python3 -u -c '
import json
import sys

streamed = set()

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except Exception:
        continue

    event_type = event.get("type", "")
    item = event.get("item") or {}
    item_id = item.get("id") or event.get("item_id") or ""

    def extract_text(value):
        if isinstance(value, str):
            return value
        if isinstance(value, dict):
            for key in ("text", "output_text", "delta", "content"):
                candidate = value.get(key)
                if isinstance(candidate, str):
                    return candidate
        return ""

    if event_type == "item.delta":
        text = extract_text(event.get("delta"))
        if text:
            sys.stdout.write(text)
            sys.stdout.flush()
            if item_id:
                streamed.add(item_id)
    elif event_type == "item.completed" and item.get("type") == "agent_message":
        text = item.get("text") or ""
        if not text:
            continue
        if item_id and item_id in streamed:
            if not text.endswith("\n"):
                sys.stdout.write("\n")
                sys.stdout.flush()
        else:
            sys.stdout.write(text)
            if not text.endswith("\n"):
                sys.stdout.write("\n")
            sys.stdout.flush()
'
}

parse_release_summary_json_stream_jq() {
  local line event_type item_type item_id text streamed_ids='|'

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    event_type="$(printf '%s\n' "$line" | jq -r '.type // empty' 2>/dev/null || true)"
    case "$event_type" in
      item.delta)
        item_id="$(printf '%s\n' "$line" | jq -r '.item_id // .item.id // empty' 2>/dev/null || true)"
        text="$(printf '%s\n' "$line" | jq -r '.delta.text // .delta.output_text // .delta // empty' 2>/dev/null || true)"
        if [[ -n "$text" ]]; then
          printf '%s' "$text"
          streamed_ids="${streamed_ids}${item_id}|"
        fi
        ;;
      item.completed)
        item_type="$(printf '%s\n' "$line" | jq -r '.item.type // empty' 2>/dev/null || true)"
        [[ "$item_type" == "agent_message" ]] || continue
        item_id="$(printf '%s\n' "$line" | jq -r '.item.id // empty' 2>/dev/null || true)"
        text="$(printf '%s\n' "$line" | jq -r '.item.text // empty' 2>/dev/null || true)"
        [[ -n "$text" ]] || continue
        if [[ "$streamed_ids" == *"|${item_id}|"* ]]; then
          [[ "$text" == *$'\n' ]] || printf '\n'
        else
          printf '%s' "$text"
          [[ "$text" == *$'\n' ]] || printf '\n'
        fi
        ;;
    esac
  done
}

parse_release_summary_json_stream() {
  if command_exists python3; then
    parse_release_summary_json_stream_python
    return 0
  fi
  parse_release_summary_json_stream_jq
}

run_release_summary_with_agent() {
  local agent_command="$1"
  local prompt_file="$2"
  local stderr_file exit_code=0

  stderr_file="$(mktemp)"
  printf 'Generating AI summary, please wait...\n\n'
  if "$agent_command" exec --skip-git-repo-check --color never --json - <"$prompt_file" 2>"$stderr_file" | parse_release_summary_json_stream; then
    exit_code=0
  else
    exit_code=$?
  fi
  if ((exit_code != 0)); then
    log_warn "${agent_command} failed: $(retry_error_summary "$stderr_file")"
  fi
  rm -f "$stderr_file"
  return "$exit_code"
}

summarize_release_changelog() {
  local release_file="$1"
  local selected_version="$2"
  local prompt_file candidate used_fallback=0
  local -a candidates=()

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    candidates+=("$candidate")
  done < <(release_summary_agent_candidates)

  if ((${#candidates[@]} == 0)); then
    clear_screen_if_interactive
    log_warn "No available hodex/codex command; cannot summarize the changelog automatically."
    pause_after_release_summary
    return 1
  fi

  prompt_file="$(mktemp)"
  build_release_summary_prompt "$release_file" "$selected_version" >"$prompt_file"

  for candidate in "${candidates[@]}"; do
    if ! agent_supports_exec "$candidate"; then
      used_fallback=1
      continue
    fi

    clear_screen_if_interactive
    if ((used_fallback)); then
      log_warn "Preferred command unavailable; switched to ${candidate}."
      printf '\n'
    fi

    if run_release_summary_with_agent "$candidate" "$prompt_file"; then
      rm -f "$prompt_file"
      pause_after_release_summary
      return 0
    fi

    used_fallback=1
    printf '\n'
    log_warn "${candidate} failed to summarize the changelog; trying the next available command."
    printf '\n'
  done

  rm -f "$prompt_file"
  clear_screen_if_interactive
  log_warn "All available hodex/codex commands failed to summarize the changelog."
  pause_after_release_summary
  return 1
}

render_release_details_page() {
  local detail_file="$1"
  local selected_version="$2"
  local start_line="$3"
  local page_size="$4"
  local total_lines="$5"
  local end_line current_page total_pages header_style hint_style status_style reset_style

  end_line=$((start_line + page_size - 1))
  if ((end_line > total_lines)); then
    end_line=$total_lines
  fi
  current_page=$(((start_line - 1) / page_size + 1))
  total_pages=$(((total_lines + page_size - 1) / page_size))

  header_style=""
  hint_style=""
  status_style=""
  reset_style=""
  if ((COLOR_ENABLED)); then
    header_style="${COLOR_HEADER}${COLOR_BOLD}"
    hint_style="${COLOR_HINT}"
    status_style="${COLOR_STATUS}"
    reset_style="${COLOR_RESET}"
  fi

  printf '\033[H\033[2J'
  printf '%sRelease details%s %s\n' "$header_style" "$reset_style" "$selected_version"
  local ai_hint="an AI summary"
  if ((COLOR_ENABLED)); then
    ai_hint="${COLOR_ALERT} AI summary (A) ${COLOR_RESET}${hint_style}"
  fi
  printf '%sEnter/Space next page  Up/Down scroll line  Left/Right scroll page  %s  i install  d download  b back  q quit%s\n' "$hint_style" "$ai_hint" "$reset_style"
  printf '%sPage %d/%d | Lines %d-%d / %d | A=AI summary (hodex/codex)%s\n\n' "$status_style" "$current_page" "$total_pages" "$start_line" "$end_line" "$total_lines" "$reset_style"
  sed -n "${start_line},${end_line}p" "$detail_file"
}

print_release_details() {
  local release_file="$1"
  local selected_version="$2"
  local details_text detail_file total_lines rows page_size start_line
  local key key2 key3

  details_text="$(build_release_details_text "$release_file" "$selected_version")"

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '%s\n' "$details_text"
    return 0
  fi

  detail_file="$(mktemp)"
  printf '%s\n' "$details_text" >"$detail_file"
  total_lines="$(wc -l <"$detail_file" | tr -d ' ')"
  rows="$(tput lines 2>/dev/null || printf '24')"
  page_size=$((rows - 6))
  if ((page_size < 8)); then
    page_size=8
  fi
  start_line=1

  while true; do
    render_release_details_page "$detail_file" "$selected_version" "$start_line" "$page_size" "$total_lines"
    IFS= read -rsn1 key
    case "$key" in
      "" | " " | n | N)
        start_line=$((start_line + page_size))
        if ((start_line > total_lines)); then
          start_line=$total_lines
        fi
        ;;
      p | P)
        start_line=$((start_line - page_size))
        if ((start_line < 1)); then
          start_line=1
        fi
        ;;
      j | J)
        start_line=$((start_line + 1))
        if ((start_line > total_lines)); then
          start_line=$total_lines
        fi
        ;;
      k | K)
        start_line=$((start_line - 1))
        if ((start_line < 1)); then
          start_line=1
        fi
        ;;
      b | B)
        rm -f "$detail_file"
        return 0
        ;;
      i | I)
        rm -f "$detail_file"
        return 10
        ;;
      d | D)
        rm -f "$detail_file"
        return 11
        ;;
      a | A | s | S)
        rm -f "$detail_file"
        return 12
        ;;
      q | Q)
        rm -f "$detail_file"
        return 20
        ;;
      $'\033')
        if IFS= read -rsn1 key2; then
          if [[ "$key2" == "[" ]]; then
            if IFS= read -rsn1 key3; then
              case "$key3" in
                A)
                  start_line=$((start_line - 1))
                  if ((start_line < 1)); then
                    start_line=1
                  fi
                  ;;
                B)
                  start_line=$((start_line + 1))
                  if ((start_line > total_lines)); then
                    start_line=$total_lines
                  fi
                  ;;
                C)
                  start_line=$((start_line + page_size))
                  if ((start_line > total_lines)); then
                    start_line=$total_lines
                  fi
                  ;;
                D)
                  start_line=$((start_line - page_size))
                  if ((start_line < 1)); then
                    start_line=1
                  fi
                  ;;
                5)
                  IFS= read -rsn1 _ || true
                  start_line=$((start_line - page_size))
                  if ((start_line < 1)); then
                    start_line=1
                  fi
                  ;;
                6)
                  IFS= read -rsn1 _ || true
                  start_line=$((start_line + page_size))
                  if ((start_line > total_lines)); then
                    start_line=$total_lines
                  fi
                  ;;
              esac
            fi
          fi
        fi
        ;;
    esac
  done
}

perform_download() {
  local requested="$1"
  local release_file asset_line asset_name asset_url asset_digest
  local release_tag release_name download_dir output_path
  local -a asset_candidates=()
  local candidate

  release_file="$(mktemp)"
  resolve_release "$requested" "$release_file"

  release_name="$(json_get_field "$release_file" "name")"
  release_tag="$(json_get_field "$release_file" "tag_name")"

  while IFS= read -r candidate; do
    asset_candidates+=("$candidate")
  done < <(get_asset_candidates)

  asset_line="$(json_find_asset_info "$release_file" "${asset_candidates[@]}")" \
    || {
      rm -f "$release_file"
      die "No matching release asset found for this platform: ${asset_candidates[*]}"
    }
  IFS=$'\t' read -r asset_name asset_url asset_digest <<<"$asset_line"

  download_dir="$(normalize_user_path "$DOWNLOAD_DIR")"
  ensure_dir_writable "$download_dir"
  output_path="${download_dir}/${asset_name}"

  if [[ -f "$output_path" && -t 0 ]]; then
    local overwrite
    printf 'Target file already exists. Overwrite? [Y/n]: '
    read -r overwrite
    case "${overwrite:-Y}" in
      n | N | no | NO)
        rm -f "$release_file"
        log_info "Download canceled."
        return 0
        ;;
    esac
  fi

  log_step "Download Hodex asset"
  log_step "Matched release: ${release_name:-<unknown>} (${release_tag:-<unknown>})"
  log_step "Download asset: $asset_name"
  log_step "Save path: $output_path"
  download_binary "$asset_url" "$output_path" "Downloading $asset_name"
  chmod 0755 "$output_path"
  verify_digest_if_present "$output_path" "$asset_digest"
  log_info "Downloaded to: $output_path"
  rm -f "$release_file"
}

release_line_matches_query() {
  local line="$1"
  local query="$2"
  local selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url search_text
  [[ -z "$query" ]] && return 0
  IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
  search_text="${selected_version}
${release_tag}
${release_name}"
  printf '%s\n' "$search_text" | grep -Fqi -- "$query"
}

extract_version_from_release_line() {
  local line="$1"
  local selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url
  IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
  printf '%s\n' "$selected_version"
}

source_entry_matches_query() {
  local query="$1"
  [[ -z "$query" ]] && return 0
  printf '%s\n' 'source download manage sync dev fork branch git toolchain checkout' | grep -Fqi -- "$query"
}

build_filtered_release_indices() {
  local idx
  filtered_indices=()
  if source_entry_matches_query "$query"; then
    filtered_indices+=("-1")
  fi
  for ((idx = 0; idx < ${#release_lines[@]}; idx++)); do
    if release_line_matches_query "${release_lines[$idx]}" "$query"; then
      filtered_indices+=("$idx")
    fi
  done
}

sync_release_cursor() {
  if ((${#filtered_indices[@]} == 0)); then
    cursor=0
    page_start=0
    return
  fi

  if ((cursor < 0)); then
    cursor=0
  fi
  if ((cursor >= ${#filtered_indices[@]})); then
    cursor=$((${#filtered_indices[@]} - 1))
  fi

  if ((cursor < page_start)); then
    page_start=$cursor
  fi
  if ((cursor >= page_start + page_size)); then
    page_start=$((cursor - page_size + 1))
  fi

  if ((page_start < 0)); then
    page_start=0
  fi

  local max_page_start
  max_page_start=$((${#filtered_indices[@]} - page_size))
  if ((max_page_start < 0)); then
    max_page_start=0
  fi
  if ((page_start > max_page_start)); then
    page_start=$max_page_start
  fi
}

set_cursor_by_version() {
  local target_version="$1"
  local idx line selected_version
  [[ -n "$target_version" ]] || return 1

  for ((idx = 0; idx < ${#filtered_indices[@]}; idx++)); do
    line="${release_lines[${filtered_indices[$idx]}]}"
    selected_version="$(extract_version_from_release_line "$line")"
    if [[ "$selected_version" == "$target_version" ]]; then
      cursor=$idx
      sync_release_cursor
      return 0
    fi
  done

  return 1
}

persist_current_release_selection() {
  return 0
}

highlight_query_matches() {
  local text="$1"
  local query="$2"
  local base_style="$3"
  local highlight_style restore_style

  if [[ -z "$query" ]] || ((${#query} < 2)) || ((COLOR_ENABLED == 0)) || ! command_exists perl; then
    printf '%s' "$text"
    return 0
  fi

  highlight_style="${COLOR_BOLD}${COLOR_STATUS}"
  restore_style="${COLOR_RESET}${base_style}"

  perl -e '
    use strict;
    use warnings;
    my ($text, $query, $highlight, $restore) = @ARGV;
    my $quoted = quotemeta($query);
    $text =~ s/($quoted)/$highlight$1$restore/ig;
    print $text;
  ' "$text" "$query" "$highlight_style" "$restore_style"
}

render_release_status_bar() {
  local cols separator line selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url marker summary entry_index

  if ((${#filtered_indices[@]} == 0)); then
    return 0
  fi

  cols="$(tput cols 2>/dev/null || printf '80')"
  if ((cols < 40)); then
    cols=80
  fi

  entry_index="${filtered_indices[$cursor]}"
  if ((entry_index < 0)); then
    summary="Selected source download / manage | supports fork, branch switch, toolchain check, checkout management"
  else
    line="${release_lines[$entry_index]}"
    IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
    marker=""
    if [[ -n "$current_version" && "$selected_version" == "$current_version" ]]; then
      marker=" | installed"
    fi
    summary="Selected ${selected_version} | ${published_at:-<unknown>} | ${asset_name}${marker}"
  fi
  separator="$(printf '%*s' "$cols" '' | tr ' ' '-')"

  if ((COLOR_ENABLED)); then
    printf '%s%s%s\n' "$COLOR_DIM" "$separator" "$COLOR_RESET"
    printf '%s%s%s\n' "$COLOR_DIM" "$summary" "$COLOR_RESET"
  else
    printf '%s\n' "$separator"
    printf '%s\n' "$summary"
  fi
}

show_release_help_popup() {
  printf '\033[H\033[2J'
  if ((COLOR_ENABLED)); then
    printf '%s%sKeyboard shortcuts%s\n\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
  else
    printf 'Keyboard shortcuts\n\n'
  fi
  printf '  Up / Down      Move selection\n'
  printf '  Left / Right   Page\n'
  printf '  n / p    Next / previous page\n'
  printf '  /        Search (type to filter)\n'
  printf '  0        Enter source download / manage\n'
  printf '  Enter    View changelog\n'
  printf '  ?        Show this help\n'
  printf '  q        Quit selector\n'
  printf '\n'
  printf 'Changelog view:\n'
  if ((COLOR_ENABLED)); then
    printf '  %sA / a  AI summary%s  Summarize current changelog with hodex/codex\n' "$COLOR_ALERT" "$COLOR_RESET"
  else
    printf '  A / a    AI summary    Summarize current changelog with hodex/codex\n'
  fi
  printf '  i        Install selected version\n'
  printf '  d        Download current platform asset to %s\n' "$DOWNLOAD_DIR"
  printf '  b        Back to list\n'
  printf '  q        Quit\n'
  printf '\nPress any key to return to the list...'
  IFS= read -rsn1 _
}

render_release_selector() {
  local rows cols total page_end idx line marker prefix page_count page_number entry_index
  local header_style hint_style selected_style installed_style status_style reset_style search_display base_style
  local selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url
  local display_version display_published display_asset

  rows="$(tput lines 2>/dev/null || printf '24')"
  cols="$(tput cols 2>/dev/null || printf '80')"
  page_size=$((rows - 10))
  if ((page_size < 5)); then
    page_size=5
  fi

  header_style=""
  hint_style=""
  selected_style=""
  installed_style=""
  status_style=""
  reset_style=""
  if ((COLOR_ENABLED)); then
    header_style="${COLOR_HEADER}${COLOR_BOLD}"
    hint_style="${COLOR_HINT}"
    selected_style="${COLOR_SELECTED}${COLOR_BOLD}"
    installed_style="${COLOR_INSTALLED}"
    status_style="${COLOR_STATUS}"
    reset_style="${COLOR_RESET}"
  fi

  search_display="${query:-<all>}"
  if ((search_mode)); then
    search_display="${query}_"
  fi

  printf '\033[H\033[2J'
  printf '%sHodex version selector%s (%s)\n' "$header_style" "$reset_style" "$PLATFORM_LABEL"
  printf '%sUp/Down move  Enter view changelog/source menu  /search  n next  p prev  Left/Right page  0 source menu  ? help  q quit%s\n' "$hint_style" "$reset_style"
  printf '%sSearch%s: %s\n' "$hint_style" "$reset_style" "$search_display"

  total=${#filtered_indices[@]}
  if ((total == 0)); then
    printf 'No matching versions.\n'
    if [[ -n "$status_message" ]]; then
      printf '\n%s%s%s\n' "$status_style" "$status_message" "$reset_style"
    fi
    return
  fi

  sync_release_cursor
  page_count=$(((total + page_size - 1) / page_size))
  page_number=$((page_start / page_size + 1))
  page_end=$((page_start + page_size))
  if ((page_end > total)); then
    page_end=$total
  fi

  printf 'Matched %d, page %d/%d\n\n' "$total" "$page_number" "$page_count"

  for ((idx = page_start; idx < page_end; idx++)); do
    entry_index="${filtered_indices[$idx]}"
    if ((entry_index < 0)); then
      prefix="  "
      if ((idx == cursor)); then
        prefix="> "
      fi
      if ((idx == cursor)) && ((COLOR_ENABLED)); then
        printf '%s%s%3s. %-12s %s%s\n' "$selected_style" "$prefix" "0" "Source mode" "Source download / manage" "$reset_style"
      else
        printf '%s%3s. %-12s %s\n' "$prefix" "0" "Source mode" "Source download / manage"
      fi
      continue
    fi

    line="${release_lines[$entry_index]}"
    IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
    marker=""
    if [[ -n "$current_version" && "$selected_version" == "$current_version" ]]; then
      if ((COLOR_ENABLED)); then
        marker=" ${installed_style}[installed]${reset_style}"
      else
        marker=" [installed]"
      fi
    fi

    base_style=""
    if ((idx == cursor)) && ((COLOR_ENABLED)); then
      base_style="$selected_style"
    fi
    display_version="$(highlight_query_matches "$selected_version" "$query" "$base_style")"
    display_published="$(highlight_query_matches "${published_at:-<unknown>}" "$query" "$base_style")"
    display_asset="$(highlight_query_matches "$asset_name" "$query" "$base_style")"

    prefix="  "
    if ((idx == cursor)); then
      prefix="> "
    fi
    if ((idx == cursor)) && ((COLOR_ENABLED)); then
      printf '%s%s%3d. %-12s %s %s%s%s\n' "$selected_style" "$prefix" "$((entry_index + 1))" "$display_version" "$display_published" "$display_asset" "$marker" "$reset_style"
    else
      printf '%s%3d. %-12s %s %s%s\n' "$prefix" "$((entry_index + 1))" "$display_version" "$display_published" "$display_asset" "$marker"
    fi
  done

  printf '\n'
  render_release_status_bar

  if [[ -n "$status_message" ]]; then
    printf '\n%s%s%s\n' "$status_style" "$status_message" "$reset_style"
  fi

  if ((cols > 0)); then
    printf '\n'
  fi
}

prompt_release_search() {
  local original_query="$query"
  local original_cursor="$cursor"
  local original_page_start="$page_start"
  local key

  search_mode=1
  status_message="Search mode: type to filter, Enter to confirm, Esc to cancel, Backspace to delete."

  while true; do
    render_release_selector
    IFS= read -rsn1 key
    case "$key" in
      "")
        search_mode=0
        status_message=""
        persist_current_release_selection
        return 0
        ;;
      $'\177' | $'\b')
        if [[ -n "$query" ]]; then
          query="${query%?}"
        fi
        ;;
      $'\033')
        search_mode=0
        query="$original_query"
        cursor="$original_cursor"
        page_start="$original_page_start"
        build_filtered_release_indices
        sync_release_cursor
        status_message="Search canceled."
        persist_current_release_selection
        return 1
        ;;
      *)
        query+="$key"
        ;;
    esac

    cursor=0
    page_start=0
    build_filtered_release_indices
    sync_release_cursor
    persist_current_release_selection
  done
}

show_release_actions() {
  local line="$1"
  local action_rc release_file selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url

  IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
  release_file="$(mktemp)"
  resolve_release "${release_tag:-$selected_version}" "$release_file"
  while true; do
    if print_release_details "$release_file" "$selected_version"; then
      action_rc=0
    else
      action_rc=$?
    fi

    case "$action_rc" in
      10)
        rm -f "$release_file"
        perform_install_like "${release_tag:-$selected_version}" "Install"
        return 10
        ;;
      11)
        rm -f "$release_file"
        perform_download "${release_tag:-$selected_version}"
        return 11
        ;;
      12)
        summarize_release_changelog "$release_file" "$selected_version" || true
        ;;
      20)
        rm -f "$release_file"
        return 20
        ;;
      *)
        rm -f "$release_file"
        return 0
        ;;
    esac
  done
}

perform_list() {
  local releases_file choice line idx key key2 key3
  local current_version=""
  local -a release_lines=()
  local -a filtered_indices=()
  local selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url
  local query="" status_message="" cursor=0 page_start=0 page_size=10 action_rc
  local search_mode=0

  require_json_backend "version list"
  releases_file="$(mktemp)"
  fetch_all_releases "$releases_file"

  while IFS= read -r line; do
    [[ -n "$line" ]] && release_lines+=("$line")
  done < <(fetch_matching_release_lines "$releases_file")

  rm -f "$releases_file"

  if ((${#release_lines[@]} == 0)); then
    die "No release assets available for this platform."
  fi

  if [[ -f "$STATE_DIR/state.json" ]]; then
    load_state_env "$STATE_DIR/state.json"
    current_version="$STATE_INSTALLED_VERSION"
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'Available versions for this platform: %s\n' "$PLATFORM_LABEL"
    printf '%3s. %-12s %s\n' "0" "Source mode" "Source download/management"
    idx=1
    for line in "${release_lines[@]}"; do
      IFS=$'\t' read -r selected_version release_tag release_name published_at asset_name asset_url asset_digest html_url <<<"$line"
      printf '%3d. %-12s %s %s\n' "$idx" "$selected_version" "${published_at:-<unknown>}" "$asset_name"
      idx=$((idx + 1))
    done
    return 0
  fi

  build_filtered_release_indices
  cursor=0
  page_start=0
  sync_release_cursor
  persist_current_release_selection

  while true; do
    render_release_selector
    IFS= read -rsn1 key

    case "$key" in
      "")
        if ((${#filtered_indices[@]} == 0)); then
          status_message="No matches for the current search."
          continue
        fi
        if ((${filtered_indices[$cursor]} < 0)); then
          show_source_management_menu
          action_rc=0
        else
          line="${release_lines[${filtered_indices[$cursor]}]}"
          if show_release_actions "$line"; then
            action_rc=0
          else
            action_rc=$?
          fi
        fi
        case "$action_rc" in
          10)
            if [[ -f "$STATE_DIR/state.json" ]]; then
              load_state_env "$STATE_DIR/state.json"
              current_version="$STATE_INSTALLED_VERSION"
            fi
            status_message="Install complete, current version: ${current_version:-<unknown>}"
            build_filtered_release_indices
            sync_release_cursor
            persist_current_release_selection
            ;;
          11)
            status_message="Download complete, target dir: $(normalize_user_path "$DOWNLOAD_DIR")"
            persist_current_release_selection
            ;;
          20)
            printf '\033[H\033[2J'
            return 0
            ;;
          *)
            status_message=""
            ;;
        esac
        ;;
      q | Q)
        printf '\033[H\033[2J'
        return 0
        ;;
      /)
        if prompt_release_search; then
          :
        else
          :
        fi
        ;;
      '?')
        show_release_help_popup
        ;;
      0)
        show_source_management_menu
        ;;
      n | N)
        if ((${#filtered_indices[@]} > 0)); then
          page_start=$((page_start + page_size))
          if ((page_start >= ${#filtered_indices[@]})); then
            page_start=$(((${#filtered_indices[@]} - 1) / page_size * page_size))
          fi
          cursor=$page_start
          status_message=""
          persist_current_release_selection
        fi
        ;;
      p | P)
        if ((${#filtered_indices[@]} > 0)); then
          page_start=$((page_start - page_size))
          if ((page_start < 0)); then
            page_start=0
          fi
          cursor=$page_start
          status_message=""
          persist_current_release_selection
        fi
        ;;
      $'\033')
        if IFS= read -rsn2 key2; then
          case "$key2" in
            "[A")
              if ((${#filtered_indices[@]} > 0)); then
                cursor=$((cursor - 1))
                sync_release_cursor
                status_message=""
                persist_current_release_selection
              fi
              ;;
            "[B")
              if ((${#filtered_indices[@]} > 0)); then
                cursor=$((cursor + 1))
                sync_release_cursor
                status_message=""
                persist_current_release_selection
              fi
              ;;
            "[C")
              if ((${#filtered_indices[@]} > 0)); then
                page_start=$((page_start + page_size))
                if ((page_start >= ${#filtered_indices[@]})); then
                  page_start=$(((${#filtered_indices[@]} - 1) / page_size * page_size))
                fi
                cursor=$page_start
                status_message=""
                persist_current_release_selection
              fi
              ;;
            "[D")
              if ((${#filtered_indices[@]} > 0)); then
                page_start=$((page_start - page_size))
                if ((page_start < 0)); then
                  page_start=0
                fi
                cursor=$page_start
                status_message=""
                persist_current_release_selection
              fi
              ;;
          esac
        fi
        ;;
      *)
        ;;
    esac
  done
}

prompt_node_choice() {
  local previous_choice="${1:-}"

  if command_exists node; then
    NODE_SETUP_CHOICE="already-installed"
    return
  fi

  if [[ "$NODE_MODE" == "ask" && -n "$previous_choice" ]]; then
    NODE_SETUP_CHOICE="$previous_choice"
    log_info "Node.js not detected; reusing previous choice: $previous_choice"
    return
  fi

  if [[ "$NODE_MODE" == "ask" && $AUTO_YES -eq 1 ]]; then
    NODE_SETUP_CHOICE="skip"
    log_warn "Node.js not detected; non-interactive mode defaults to skip."
    return
  fi

  local effective_mode="$NODE_MODE"
  if [[ "$effective_mode" == "ask" ]]; then
    cat <<EOF
Node.js is not installed. Choose an option:
  1. System install
     - macOS: Homebrew
     - Linux/WSL: apt / dnf / yum / pacman / zypper
  2. Use nvm
  3. Manual install (official download)
  4. Skip
EOF
    local answer
    while true; do
      printf 'Choose [1/2/3/4]: '
      read -r answer
      case "$answer" in
        1)
          effective_mode="native"
          break
          ;;
        2)
          effective_mode="nvm"
          break
          ;;
        3)
          effective_mode="manual"
          break
          ;;
        4)
          effective_mode="skip"
          break
          ;;
        *)
          log_warn "Please enter 1, 2, 3, or 4."
          ;;
      esac
    done
  fi

  NODE_SETUP_CHOICE="$effective_mode"
  case "$effective_mode" in
    skip)
      log_info "Skipped Node.js setup."
      ;;
    manual)
      log_info "Install Node.js manually: $NODE_DOWNLOAD_URL"
      ;;
    native)
      install_node_native
      ;;
    nvm)
      install_node_with_nvm
      ;;
  esac
}

validate_source_profile_name() {
  local profile_name="$1"
  [[ -n "$profile_name" ]] || die "Source profile name cannot be empty."
  [[ "$profile_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Source profile name may only include letters, numbers, dots, underscores, and hyphens."
  case "$profile_name" in
    hodex | hodexctl | hodex-stable)
      die "Source profile name cannot use reserved name: $profile_name"
      ;;
  esac
}

resolve_source_repo_input() {
  local state_file="${1:-}"
  local profile_name="${2:-}"

  if [[ -n "$SOURCE_GIT_URL" ]]; then
    printf '%s\t%s\n' "$SOURCE_GIT_URL" "$SOURCE_GIT_URL"
    return
  fi

  if ((EXPLICIT_SOURCE_REPO)) && [[ -n "$REPO" ]]; then
    printf '%s\thttps://github.com/%s.git\n' "$REPO" "$REPO"
    return
  fi

  if [[ -n "$state_file" && -n "$profile_name" && -f "$state_file" ]]; then
    local existing_repo existing_remote
    existing_repo="$(state_get_source_profile_field "$state_file" "$profile_name" "repo_input")"
    existing_remote="$(state_get_source_profile_field "$state_file" "$profile_name" "remote_url")"
    if [[ -n "$existing_repo" || -n "$existing_remote" ]]; then
      printf '%s\t%s\n' "$existing_repo" "$existing_remote"
      return
    fi
  fi

  if ((AUTO_YES)); then
    printf '%s\thttps://github.com/%s.git\n' "$DEFAULT_REPO" "$DEFAULT_REPO"
    return
  fi

  local answer
  printf 'Enter source repo (owner/repo or Git URL, default %s): ' "$DEFAULT_REPO"
  read -r answer
  answer="${answer:-$DEFAULT_REPO}"
  if [[ "$answer" == *"://"* || "$answer" == git@*:* ]]; then
    printf '%s\t%s\n' "$answer" "$answer"
  else
    printf '%s\thttps://github.com/%s.git\n' "$answer" "$answer"
  fi
}

parse_source_remote_identity() {
  local remote_input="$1"
  local host path_part

  if [[ "$remote_input" == *"://"* ]]; then
    local stripped="${remote_input#*://}"
    stripped="${stripped#*@}"
    host="${stripped%%/*}"
    path_part="${stripped#*/}"
  elif [[ "$remote_input" == git@*:* ]]; then
    local after_at="${remote_input#*@}"
    host="${after_at%%:*}"
    path_part="${after_at#*:}"
  else
    host="github.com"
    path_part="$remote_input"
  fi

  path_part="${path_part%.git}"
  path_part="${path_part#/}"
  printf '%s\t%s\n' "$host" "$path_part"
}

default_source_checkout_dir() {
  local remote_input="$1"
  local host repo_path
  IFS=$'\t' read -r host repo_path <<<"$(parse_source_remote_identity "$remote_input")"
  printf '%s/hodex-src/%s/%s\n' "$HOME" "$host" "$repo_path"
}

declare -a CHOICE_CANDIDATES=()
declare -a CHOICE_FILTERED_CANDIDATES=()

reset_choice_candidates() {
  CHOICE_CANDIDATES=()
}

append_choice_candidate() {
  local value="$1"
  local existing
  [[ -n "$value" ]] || return 0
  for existing in "${CHOICE_CANDIDATES[@]-}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  CHOICE_CANDIDATES+=("$value")
}

print_choice_candidates() {
  local idx=1
  local value
  [[ ${#CHOICE_CANDIDATES[@]} -gt 0 ]] || return 0
  printf '  Candidates:\n'
  for value in "${CHOICE_CANDIDATES[@]-}"; do
    printf '    %d. %s\n' "$idx" "$value"
    idx=$((idx + 1))
  done
}

build_filtered_choice_candidates() {
  local query="${1:-}"
  local value

  CHOICE_FILTERED_CANDIDATES=()
  if [[ -z "$query" ]]; then
    for value in "${CHOICE_CANDIDATES[@]-}"; do
      CHOICE_FILTERED_CANDIDATES+=("$value")
    done
    return 0
  fi

  for value in "${CHOICE_CANDIDATES[@]-}"; do
    if printf '%s\n' "$value" | grep -Fqi -- "$query"; then
      CHOICE_FILTERED_CANDIDATES+=("$value")
    fi
  done
}

render_choice_candidates_page() {
  local label="$1"
  local default_value="$2"
  local note="$3"
  local query="$4"
  local page_start="$5"
  local page_size="$6"
  local total="${#CHOICE_FILTERED_CANDIDATES[@]}"
  local page_end page_number page_count idx visible_index value

  clear_screen_if_interactive
  printf '%s\n' "$label" >&2
  printf '  Default: %s\n' "$default_value" >&2
  [[ -z "$note" ]] || printf '  Note: %s\n' "$note" >&2
  printf '  Enter a number from this page, or type a custom value\n' >&2
  printf '  n/p page, / filter, c clear filter\n' >&2
  if [[ -n "$query" ]]; then
    printf '  Current filter: %s\n' "$query" >&2
  fi

  if ((total == 0)); then
    printf '  No candidates match the current filter\n' >&2
    printf '> ' >&2
    return 0
  fi

  page_end=$((page_start + page_size))
  if ((page_end > total)); then
    page_end=$total
  fi
  page_count=$(((total + page_size - 1) / page_size))
  page_number=$((page_start / page_size + 1))
  printf '  Candidates: page %d/%d, total %d\n' "$page_number" "$page_count" "$total" >&2
  for ((idx = page_start; idx < page_end; idx++)); do
    visible_index=$((idx - page_start + 1))
    value="${CHOICE_FILTERED_CANDIDATES[$idx]}"
    printf '    %d. %s\n' "$visible_index" "$value" >&2
  done
  printf '> ' >&2
}

prompt_value_with_choice_candidates() {
  local label="$1"
  local default_value="$2"
  local note="${3:-}"
  local answer choice_index
  local query="" page_size=10 page_start=0 total visible_count

  if [[ ${#CHOICE_CANDIDATES[@]} -gt 12 ]]; then
    while true; do
      build_filtered_choice_candidates "$query"
      total=${#CHOICE_FILTERED_CANDIDATES[@]}
      if ((page_start < 0)); then
        page_start=0
      fi
      if ((total > 0)) && ((page_start >= total)); then
        page_start=$((((total - 1) / page_size) * page_size))
      fi

      render_choice_candidates_page "$label" "$default_value" "$note" "$query" "$page_start" "$page_size"
      read -r answer

      case "$answer" in
        "")
          printf '%s\n' "$default_value"
          return 0
          ;;
        n | N)
          if ((total > 0)); then
            page_start=$((page_start + page_size))
            if ((page_start >= total)); then
              page_start=$((((total - 1) / page_size) * page_size))
            fi
          fi
          continue
          ;;
        p | P)
          page_start=$((page_start - page_size))
          if ((page_start < 0)); then
            page_start=0
          fi
          continue
          ;;
        c | C)
          query=""
          page_start=0
          continue
          ;;
        /*)
          query="${answer#/}"
          page_start=0
          continue
          ;;
      esac

      if [[ "$answer" =~ ^[0-9]+$ ]] && ((total > 0)); then
        visible_count=$((total - page_start))
        if ((visible_count > page_size)); then
          visible_count=$page_size
        fi
        if ((answer >= 1 && answer <= visible_count)); then
          printf '%s\n' "${CHOICE_FILTERED_CANDIDATES[$((page_start + answer - 1))]}"
          return 0
        fi
        log_warn "Enter a number within the current page."
        continue
      fi

      printf '%s\n' "$answer"
      return 0
    done
  fi

  while true; do
    printf '%s\n' "$label" >&2
    printf '  Default: %s\n' "$default_value" >&2
    [[ -z "$note" ]] || printf '  Note: %s\n' "$note" >&2
    print_choice_candidates >&2
    printf '  Enter a number to select, or type a custom value\n' >&2
    printf '> ' >&2
    read -r answer

    if [[ -z "$answer" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi

    if [[ "$answer" =~ ^[0-9]+$ ]] && [[ ${#CHOICE_CANDIDATES[@]} -gt 0 ]]; then
      choice_index=$((answer - 1))
      if ((choice_index >= 0 && choice_index < ${#CHOICE_CANDIDATES[@]})); then
        printf '%s\n' "${CHOICE_CANDIDATES[$choice_index]}"
        return 0
      fi
      log_warn "Number out of range; please try again."
      continue
    fi

    printf '%s\n' "$answer"
    return 0
  done
}

derive_source_profile_suggestion() {
  local repo_input="$1"
  local host repo_path repo_name suggestion
  IFS=$'\t' read -r host repo_path <<<"$(parse_source_remote_identity "$repo_input")"
  repo_name="${repo_path##*/}"
  repo_name="${repo_name%.git}"
  suggestion="$(printf '%s-source' "$repo_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  [[ -n "$suggestion" ]] && printf '%s\n' "$suggestion"
}

emit_source_repo_candidates() {
  local state_file="${1:-}"
  local profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at

  printf '%s\n' "$DEFAULT_REPO"
  printf 'https://github.com/%s.git\n' "$DEFAULT_REPO"

  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$repo_input" ]] && printf '%s\n' "$repo_input"
    if [[ -n "$remote_url" && "$remote_url" != "https://github.com/${repo_input}.git" ]]; then
      printf '%s\n' "$remote_url"
    fi
  done < <(state_emit_source_profiles "$state_file")
}

emit_source_profile_candidates() {
  local repo_input="$1"
  local state_file="${2:-}"
  local suggested profile_name repo_value remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at

  printf '%s\n' "$DEFAULT_SOURCE_PROFILE_NAME"
  suggested="$(derive_source_profile_suggestion "$repo_input")"
  [[ -n "$suggested" ]] && printf '%s\n' "$suggested"

  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r profile_name repo_value remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$profile_name" ]] && printf '%s\n' "$profile_name"
  done < <(state_emit_source_profiles "$state_file")
}

emit_git_checkout_ref_candidates() {
  local checkout_dir="$1"
  local ref_name

  [[ -n "$checkout_dir" && -d "$checkout_dir/.git" ]] || return 0
  git -C "$checkout_dir" fetch --all --tags --prune --force >/dev/null 2>&1 || true

  while IFS= read -r ref_name; do
    [[ -n "$ref_name" ]] || continue
    [[ "$ref_name" == "origin/HEAD" ]] && continue
    [[ "$ref_name" == origin/* ]] && ref_name="${ref_name#origin/}"
    [[ "$ref_name" == "origin" ]] && continue
    printf '%s\n' "$ref_name"
  done < <(
    git -C "$checkout_dir" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null || true
  )
}

emit_source_ref_candidates() {
  local repo_input="$1"
  local state_file="${2:-}"
  local current_source_profile="${3:-}"
  local checkout_dir="${4:-}"
  local profile_name repo_value remote_url workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at

  printf '%s\n' "${SOURCE_REF:-$DEFAULT_SOURCE_REF}"
  printf '%s\n' "$DEFAULT_SOURCE_REF"
  printf 'master\n'
  printf 'develop\n'
  printf 'dev\n'
  emit_git_checkout_ref_candidates "$checkout_dir"

  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r profile_name repo_value remote_url _ workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$current_ref" ]] || continue
    if [[ -n "$current_source_profile" && "$profile_name" == "$current_source_profile" ]]; then
      printf '%s\n' "$current_ref"
    elif [[ -n "$repo_input" && "$repo_value" == "$repo_input" ]]; then
      printf '%s\n' "$current_ref"
    fi
  done < <(state_emit_source_profiles "$state_file")
}

emit_source_checkout_candidates() {
  local remote_url="$1"
  local default_checkout="$2"
  local state_file="${3:-}"
  local profile_name repo_value existing_remote checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at

  printf '%s\n' "$default_checkout"
  printf '%s\n' "$HOME/hodex-src"

  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r profile_name repo_value existing_remote checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$checkout_dir" ]] || continue
    if [[ -n "$remote_url" && "$existing_remote" == "$remote_url" ]]; then
      printf '%s\n' "$checkout_dir"
    fi
  done < <(state_emit_source_profiles "$state_file")
}

prompt_source_ref_with_candidates() {
  local state_file="$1"
  local repo_input="${2:-}"
  local profile_name="${3:-}"
  local default_ref="${4:-$DEFAULT_SOURCE_REF}"
  local checkout_dir="${5:-}"
  local candidate

  reset_choice_candidates
  while IFS= read -r candidate; do
    append_choice_candidate "$candidate"
  done < <(emit_source_ref_candidates "$repo_input" "$state_file" "$profile_name" "$checkout_dir")
  prompt_value_with_choice_candidates 'Target ref (branch / tag / commit)' "$default_ref" 'Candidates show branches by default; tags or commits can be entered directly'
}

resolve_source_checkout_dir() {
  local default_dir="$1"
  local profile_name="$2"
  local state_file="${3:-}"

  if [[ -n "$SOURCE_CHECKOUT_DIR" ]]; then
    printf '%s\n' "$SOURCE_CHECKOUT_DIR"
    return
  fi

  if [[ -n "$state_file" && -n "$profile_name" && -f "$state_file" ]]; then
    local existing_dir
    existing_dir="$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")"
    if [[ -n "$existing_dir" ]]; then
      printf '%s\n' "$existing_dir"
      return
    fi
  fi

  if ((AUTO_YES)); then
    printf '%s\n' "$default_dir"
    return
  fi

  local answer
  printf 'Source checkout directory [%s]: ' "$default_dir"
  read -r answer
  if [[ -z "$answer" ]]; then
    printf '%s\n' "$default_dir"
  else
    printf '%s\n' "$(normalize_user_path "$answer")"
  fi
}

source_repo_input_to_remote_url() {
  local repo_input="$1"
  if [[ "$repo_input" == *"://"* || "$repo_input" == git@*:* ]]; then
    printf '%s\n' "$repo_input"
  else
    printf 'https://github.com/%s.git\n' "$repo_input"
  fi
}

run_source_install_wizard() {
  local repo_answer name_answer ref_answer checkout_answer remote_url default_checkout state_file
  state_file="$STATE_DIR/state.json"

  [[ -t 0 && -t 1 ]] || return 0
  ((AUTO_YES)) && return 0
  [[ -n "$SOURCE_GIT_URL" || -n "$SOURCE_CHECKOUT_DIR" || -n "$SOURCE_PROFILE" || "$SOURCE_REF" != "$DEFAULT_SOURCE_REF" || "$REPO" != "$DEFAULT_REPO" ]] && return 0

  while true; do
    printf '\033[H\033[2J'
    if ((COLOR_ENABLED)); then
      printf '%s%sSource download wizard%s\n\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
      printf '%sYou will confirm repo, source profile, ref, and checkout directory in order.%s\n' "$COLOR_HINT" "$COLOR_RESET"
      printf '%sPress Enter to accept defaults; source mode only downloads/syncs and does not build.%s\n' "$COLOR_HINT" "$COLOR_RESET"
      printf '%sStep 1/4%s Repo\n\n' "$COLOR_STATUS" "$COLOR_RESET"
    else
      printf 'Source download wizard\n\n'
      printf 'You will confirm repo, source profile, ref, and checkout directory in order.\n'
      printf 'Press Enter to accept defaults; source mode only downloads/syncs and does not build.\n'
      printf 'Step 1/4 Repo\n\n'
    fi

    reset_choice_candidates
    while IFS= read -r repo_answer; do
      append_choice_candidate "$repo_answer"
    done < <(emit_source_repo_candidates "$state_file")
    repo_answer="$(prompt_value_with_choice_candidates 'Source repo (owner/repo or Git URL)' "$DEFAULT_REPO")"

    while true; do
      if ((COLOR_ENABLED)); then
        printf '\n%sStep 2/4%s Source profile name\n' "$COLOR_STATUS" "$COLOR_RESET"
      else
        printf '\nStep 2/4 Source profile name\n'
      fi
      reset_choice_candidates
      while IFS= read -r name_answer; do
        append_choice_candidate "$name_answer"
      done < <(emit_source_profile_candidates "$repo_answer" "$state_file")
      name_answer="$(
        prompt_value_with_choice_candidates \
          'Source profile name' \
          "$DEFAULT_SOURCE_PROFILE_NAME" \
          'This is a source profile/workspace identifier, not a command name'
      )"
      if validate_source_profile_name "$name_answer" >/dev/null 2>&1; then
        break
      fi
      log_warn "Source profile name cannot use reserved names."
    done

    if ((COLOR_ENABLED)); then
      printf '\n%sStep 3/4%s Ref\n' "$COLOR_STATUS" "$COLOR_RESET"
    else
      printf '\nStep 3/4 Ref\n'
    fi
    remote_url="$(source_repo_input_to_remote_url "$repo_answer")"
    default_checkout="$(default_source_checkout_dir "$remote_url")"
    reset_choice_candidates
    while IFS= read -r ref_answer; do
      append_choice_candidate "$ref_answer"
    done < <(emit_source_ref_candidates "$repo_answer" "$state_file" "$name_answer" "$default_checkout")
    ref_answer="$(prompt_value_with_choice_candidates 'Source ref (branch / tag / commit)' "$DEFAULT_SOURCE_REF" 'Candidates show branches by default; tags or commits can be entered directly')"

    if ((COLOR_ENABLED)); then
      printf '\n%sStep 4/4%s Checkout\n' "$COLOR_STATUS" "$COLOR_RESET"
      printf '%sDefault checkout goes to the managed source directory for reuse by update/switch.%s\n' "$COLOR_HINT" "$COLOR_RESET"
    else
      printf '\nStep 4/4 Checkout\n'
      printf 'Default checkout goes to the managed source directory for reuse by update/switch.\n'
    fi
    reset_choice_candidates
    while IFS= read -r checkout_answer; do
      append_choice_candidate "$checkout_answer"
    done < <(emit_source_checkout_candidates "$remote_url" "$default_checkout" "$state_file")
    checkout_answer="$(prompt_value_with_choice_candidates 'Source checkout directory' "$default_checkout")"
    checkout_answer="$(normalize_user_path "$checkout_answer")"

    printf '\n'
    if ((COLOR_ENABLED)); then
      printf '%s%sWizard Summary%s\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
    else
      printf 'Wizard Summary\n'
    fi
    printf '  Repo: %s\n' "$repo_answer"
    printf '  Source profile: %s\n' "$name_answer"
    printf '  ref: %s\n' "$ref_answer"
    printf '  checkout: %s\n' "$checkout_answer"

    printf '\nProceeding to confirmation.\n'
    if prompt_yes_no "Continue with this configuration? [Y/n]: " "Y"; then
      if [[ "$repo_answer" == *"://"* || "$repo_answer" == git@*:* ]]; then
        SOURCE_GIT_URL="$repo_answer"
      else
        REPO="$repo_answer"
        EXPLICIT_SOURCE_REPO=1
      fi
      SOURCE_PROFILE="$name_answer"
      SOURCE_REF="$ref_answer"
      SOURCE_CHECKOUT_DIR="$checkout_answer"
      return 0
    fi

    if ! prompt_yes_no "Redo the source download wizard? [Y/n]: " "Y"; then
      log_info "Canceled."
      return 1
    fi
  done
}

render_source_profile_selector() {
  local current_index="$1"
  shift
  local -a lines=("$@")
  local idx selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at prefix style reset_style separator cols

  printf '\033[H\033[2J'
  if ((COLOR_ENABLED)); then
    printf '%s%sSelect source profile%s\n\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
    printf '%sTotal %d profiles; default prefers %s, otherwise the first.%s\n' "$COLOR_HINT" "${#lines[@]}" "$DEFAULT_SOURCE_PROFILE_NAME" "$COLOR_RESET"
    printf '%sUp/Down move  Enter confirm  q cancel%s\n\n' "$COLOR_HINT" "$COLOR_RESET"
    style="${COLOR_SELECTED}${COLOR_BOLD}"
    reset_style="$COLOR_RESET"
  else
    printf 'Select source profile\n\n'
    printf 'Total %d profiles; default prefers %s, otherwise the first.\n' "${#lines[@]}" "$DEFAULT_SOURCE_PROFILE_NAME"
    printf 'Up/Down move  Enter confirm  q cancel\n\n'
    style=""
    reset_style=""
  fi

  for ((idx = 0; idx < ${#lines[@]}; idx++)); do
    IFS=$'\t' read -r selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _ <<<"${lines[$idx]}"
    prefix="  "
    if ((idx == current_index)); then
      prefix="> "
      if ((COLOR_ENABLED)); then
        printf '%s%s%s | %s | %s%s\n' "$style" "$prefix" "$selected_name" "${current_ref:-<unknown>}" "${repo_input:-<unknown>}" "$reset_style"
      else
        printf '%s%s | %s | %s\n' "$prefix" "$selected_name" "${current_ref:-<unknown>}" "${repo_input:-<unknown>}"
      fi
    else
      printf '%s%s | %s | %s\n' "$prefix" "$selected_name" "${current_ref:-<unknown>}" "${repo_input:-<unknown>}"
    fi
  done

  cols="$(tput cols 2>/dev/null || printf '80')"
  separator="$(printf '%*s' "$cols" '' | tr ' ' '-')"
  IFS=$'\t' read -r selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _ <<<"${lines[$current_index]}"
  printf '\n'
  if ((COLOR_ENABLED)); then
    printf '%s%s%s\n' "$COLOR_DIM" "$separator" "$COLOR_RESET"
    printf '%sSelected summary%s: %s | ref=%s | checkout=%s\n' "$COLOR_DIM" "$COLOR_RESET" "$selected_name" "${current_ref:-<unknown>}" "${checkout_dir:-<unknown>}"
  else
    printf '%s\n' "$separator"
    printf 'Selected summary: %s | ref=%s | checkout=%s\n' "$selected_name" "${current_ref:-<unknown>}" "${checkout_dir:-<unknown>}"
  fi
}

classify_source_error() {
  local message="$1"
  case "$message" in
    *"msvc-build-tools"*)
      printf 'Toolchain issue\n'
      ;;
    *"cargo build"* | *"build"* | *"compile"* | *"artifact"*)
      printf 'Build issue\n'
      ;;
    *"toolchain"* | *"missing"* | *"rustup"* | *"cargo"* | *"rustc"* | *"xcode-clt"*)
      printf 'Toolchain issue\n'
      ;;
    *"Git repository"* | *"remote"* | *"clone"* | *"git"* | *"checkout"* | *"uncommitted changes"*)
      printf 'Git / source directory issue\n'
      ;;
    *"ref"* | *"branch"* | *"tag"* | *"commit"*)
      printf 'Target ref issue\n'
      ;;
    *"name"* | *"reserved"* | *"-dev"* | *"argument"* )
      printf 'Input parameter issue\n'
      ;;
    *)
      printf 'Uncategorized issue\n'
      ;;
  esac
}

print_source_result_summary() {
  local action_label="$1"
  local profile_name="$2"
  local ref_name="$3"
  local checkout_dir="$4"
  local binary_path="$5"
  local wrapper_path="$6"

  printf '\n'
  if ((COLOR_ENABLED)); then
    printf '%s%sResult summary%s\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
  else
    printf 'Result summary\n'
  fi
  printf '  Action: %s\n' "$action_label"
  printf '  Source profile: %s\n' "$profile_name"
  if [[ -n "$ref_name" ]]; then
    printf '  Current ref: %s\n' "$ref_name"
  fi
  if [[ -n "$checkout_dir" ]]; then
    printf '  checkout: %s\n' "$checkout_dir"
  fi
}

print_source_menu_action_preview() {
  local choice="$1"
  local state_file="$STATE_DIR/state.json"
  local preview_name preview_repo preview_remote preview_checkout
  local source_count="0"

  if [[ -f "$state_file" ]]; then
    source_count="$(state_count_source_profiles "$state_file")"
  fi

  case "$choice" in
    1)
      preview_name="${SOURCE_PROFILE:-$DEFAULT_SOURCE_PROFILE_NAME}"
      if [[ -n "$SOURCE_GIT_URL" ]]; then
        preview_repo="$SOURCE_GIT_URL"
      else
        preview_repo="${REPO:-$DEFAULT_REPO}"
      fi
      preview_remote="$(source_repo_input_to_remote_url "$preview_repo")"
      preview_checkout="${SOURCE_CHECKOUT_DIR:-$(default_source_checkout_dir "$preview_remote")}"
      printf '  Default repo: %s\n' "$preview_repo"
      printf '  Default source profile: %s\n' "$preview_name"
      printf '  Default ref: %s\n' "${SOURCE_REF:-$DEFAULT_SOURCE_REF}"
      printf '  Default checkout: %s\n' "$preview_checkout"
      printf '  Actions: clone/fetch, toolchain check, register source profile\n'
      ;;
    2)
      printf '  Default target: single profile auto-selected; multiple profiles open selector\n'
      printf '  Actions: fetch latest code, checkout current ref, sync checkout\n'
      printf '  Keep rule: manage only source directory and toolchain; does not affect hodex release\n'
      ;;
    3)
      printf '  Default target: single profile auto-selected; multiple profiles open selector\n'
      printf '  Target ref: %s\n' "${SOURCE_REF:-$DEFAULT_SOURCE_REF}"
      printf '  Actions: confirm new branch/tag/commit, then switch and sync source\n'
      printf '  Safety: refuse to switch if checkout has uncommitted changes\n'
      ;;
    4)
      printf '  Source build capability has been removed in this version.\n'
      printf '  For latest source, use "Update source" or "Switch ref".\n'
      ;;
    5)
      printf '  Default target: single profile shows details; multiple profiles show summary list\n'
      printf '  Shows: repo, ref, checkout, workspace, last sync time\n'
      ;;
    6)
      printf '  Default target: single profile auto-selected; multiple profiles open selector\n'
      printf '  Removes: source profile record; optional checkout removal\n'
      printf '  Final cleanup: if this is the last runtime, also removes hodexctl and managed PATH\n'
      ;;
    7)
      printf '  Shows: summary of repo/ref/checkout for all source profiles\n'
      printf '  Currently recorded: %s\n' "$source_count"
      ;;
  esac
}

run_source_menu_action() {
  local source_action="$1"
  shift

  local -a cmd=("$SELF_PATH" "source" "$source_action" "--state-dir" "$STATE_DIR")

  if [[ -n "$COMMAND_DIR" ]]; then
    cmd+=("--command-dir" "$COMMAND_DIR")
  fi
  if ((AUTO_YES)); then
    cmd+=("--yes")
  fi
  if ((NO_PATH_UPDATE)); then
    cmd+=("--no-path-update")
  fi
  if [[ -n "$GITHUB_TOKEN" ]]; then
    cmd+=("--github-token" "$GITHUB_TOKEN")
  fi
  if [[ -n "$SOURCE_GIT_URL" ]]; then
    cmd+=("--git-url" "$SOURCE_GIT_URL")
  elif [[ -n "$REPO" && "$REPO" != "$DEFAULT_REPO" ]]; then
    cmd+=("--repo" "$REPO")
  fi
  if ((EXPLICIT_SOURCE_PROFILE)) && [[ -n "$SOURCE_PROFILE" ]]; then
    cmd+=("--profile" "$SOURCE_PROFILE")
  fi
  if ((EXPLICIT_SOURCE_REF)) && [[ -n "$SOURCE_REF" ]]; then
    cmd+=("--ref" "$SOURCE_REF")
  fi
  if [[ -n "$SOURCE_CHECKOUT_DIR" ]]; then
    cmd+=("--checkout-dir" "$SOURCE_CHECKOUT_DIR")
  fi
  case "$SOURCE_CHECKOUT_POLICY" in
    keep) cmd+=("--keep-checkout") ;;
    remove) cmd+=("--remove-checkout") ;;
  esac

  "${cmd[@]}" "$@"
}

select_existing_source_profile_name() {
  local state_file="$1"
  local preferred_name="${2:-$DEFAULT_SOURCE_PROFILE_NAME}"
  local -a lines=()
  local line index choice selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at

  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done < <(state_emit_source_profiles "$state_file")

  ((${#lines[@]} > 0)) || die "No source profiles found. Run 'hodexctl source install' first."

  for line in "${lines[@]}"; do
    IFS=$'\t' read -r selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _ <<<"$line"
    if [[ "$selected_name" == "$preferred_name" ]]; then
      printf '%s\n' "$selected_name"
      return 0
    fi
  done

  if ((${#lines[@]} == 1)) || ((AUTO_YES)); then
    IFS=$'\t' read -r selected_name _ <<<"${lines[0]}"
    printf '%s\n' "$selected_name"
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    local cursor=0 key key2
    for ((index = 0; index < ${#lines[@]}; index++)); do
      IFS=$'\t' read -r selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _ <<<"${lines[$index]}"
      if [[ "$selected_name" == "$preferred_name" ]]; then
        cursor=$index
        break
      fi
    done
    while true; do
      render_source_profile_selector "$cursor" "${lines[@]}"
      IFS= read -rsn1 key
      case "$key" in
        "")
          IFS=$'\t' read -r selected_name _ <<<"${lines[$cursor]}"
          printf '%s\n' "$selected_name"
          return 0
          ;;
        q | Q)
          die "Source profile selection canceled."
          ;;
        $'\033')
          if IFS= read -rsn2 key2; then
            case "$key2" in
              "[A")
                cursor=$((cursor - 1))
                if ((cursor < 0)); then cursor=$((${#lines[@]} - 1)); fi
                ;;
              "[B")
                cursor=$((cursor + 1))
                if ((cursor >= ${#lines[@]})); then cursor=0; fi
                ;;
            esac
          fi
          ;;
      esac
    done
  fi

  printf '\nSelect a source profile:\n'
  index=1
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r selected_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _ <<<"$line"
    printf '  %d. %s | %s | %s\n' "$index" "$selected_name" "${current_ref:-<unknown>}" "${repo_input:-<unknown>}"
    index=$((index + 1))
  done

  while true; do
    printf 'Enter a number to select a source profile [1-%d]: ' "${#lines[@]}"
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] || {
      log_warn "Please enter a valid number."
      continue
    }
    if ((choice >= 1 && choice <= ${#lines[@]})); then
      IFS=$'\t' read -r selected_name _ <<<"${lines[$((choice - 1))]}"
      printf '%s\n' "$selected_name"
      return 0
    fi
    log_warn "Please enter a number between 1 and ${#lines[@]}."
  done
}

resolve_source_profile_name() {
  local state_file="$1"
  local require_existing="${2:-0}"
  local default_name="${SOURCE_PROFILE:-$DEFAULT_SOURCE_PROFILE_NAME}"

  if ((require_existing)); then
    if ((EXPLICIT_SOURCE_PROFILE)) && [[ -n "$SOURCE_PROFILE" ]]; then
      printf '%s\n' "$SOURCE_PROFILE"
      return
    fi
    select_existing_source_profile_name "$state_file" "$DEFAULT_SOURCE_PROFILE_NAME"
    return
  fi

  if [[ -z "$SOURCE_PROFILE" ]] && ! ((AUTO_YES)); then
    local answer
    printf 'Source profile name [%s]: ' "$DEFAULT_SOURCE_PROFILE_NAME"
    read -r answer
    default_name="${answer:-$DEFAULT_SOURCE_PROFILE_NAME}"
  fi

  printf '%s\n' "$default_name"
}

confirm_source_action_plan() {
  local action_label="$1"
  local profile_name="$2"
  local repo_input="$3"
  local checkout_dir="$4"
  local ref_name="$5"
  local extra_hint="${6:-}"
  local checkout_mode_preview="${7:-}"
  local current_ref_value="${8:-}"
  local current_checkout_value="${9:-}"

  if ! [[ -t 0 && -t 1 ]]; then
    return 0
  fi

  printf '\n'
  if ((COLOR_ENABLED)); then
    printf '%s%sAbout to run%s: %s\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET" "$action_label"
    printf '%s  profile%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "$profile_name"
    printf '%s  repo%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "${repo_input:-<unknown>}"
    printf '%s  checkout%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "${checkout_dir:-<unknown>}"
    printf '%s  ref%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "${ref_name:-<unknown>}"
    if [[ -n "$current_ref_value" && "$current_ref_value" != "$ref_name" ]]; then
      printf '%s  current -> target ref%s: %s -> %s\n' "$COLOR_HINT" "$COLOR_RESET" "$current_ref_value" "$ref_name"
    fi
    if [[ -n "$current_checkout_value" && "$current_checkout_value" != "$checkout_dir" ]]; then
      printf '%s  current -> target checkout%s: %s -> %s\n' "$COLOR_HINT" "$COLOR_RESET" "$current_checkout_value" "$checkout_dir"
    fi
    if [[ -n "$checkout_mode_preview" ]]; then
      printf '%s  checkout strategy%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "$checkout_mode_preview"
    fi
    if [[ -n "$extra_hint" ]]; then
      printf '%s  note%s: %s\n' "$COLOR_HINT" "$COLOR_RESET" "$extra_hint"
    fi
  else
    printf 'About to run: %s\n' "$action_label"
    printf '  source profile: %s\n' "$profile_name"
    printf '  repo: %s\n' "${repo_input:-<unknown>}"
    printf '  checkout: %s\n' "${checkout_dir:-<unknown>}"
    printf '  ref: %s\n' "${ref_name:-<unknown>}"
    if [[ -n "$current_ref_value" && "$current_ref_value" != "$ref_name" ]]; then
      printf '  current -> target ref: %s -> %s\n' "$current_ref_value" "$ref_name"
    fi
    if [[ -n "$current_checkout_value" && "$current_checkout_value" != "$checkout_dir" ]]; then
      printf '  current -> target checkout: %s -> %s\n' "$current_checkout_value" "$checkout_dir"
    fi
    if [[ -n "$checkout_mode_preview" ]]; then
      printf '  checkout strategy: %s\n' "$checkout_mode_preview"
    fi
    if [[ -n "$extra_hint" ]]; then
      printf '  note: %s\n' "$extra_hint"
    fi
  fi

  prompt_yes_no "Continue? [Y/n]: " "Y" || {
    log_info "Canceled."
    return 1
  }
}

ensure_git_worktree_clean() {
  local checkout_dir="$1"
  local status_output

  status_output="$(git -C "$checkout_dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
  [[ -z "$status_output" ]] || die "Source checkout has uncommitted changes. Commit or clean before switching/updating: $checkout_dir"
}

summarize_git_fetch_output() {
  local output_file="$1"
  local remote_line line

  remote_line="$(grep -E '^From ' "$output_file" | head -n 1 || true)"
  [[ -n "$remote_line" ]] && {
    printf '%s\n' "$remote_line" >&2
  }

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line" >&2
  done < <(grep -E '\[(new tag|tag update|new branch)\]' "$output_file" || true)

  return 0
}

git_fetch_with_summary() {
  local checkout_dir="$1"
  local output_file exit_code
  output_file="$(mktemp)"

  if git -C "$checkout_dir" fetch --all --tags --prune --force >"$output_file" 2>&1; then
    summarize_git_fetch_output "$output_file"
    rm -f "$output_file"
    return 0
  fi

  exit_code=$?
  cat "$output_file" >&2
  rm -f "$output_file"
  return "$exit_code"
}

summarize_git_checkout_output() {
  local output_file="$1"
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line"
  done < <(grep -E "^(Already on |Switched to branch |Switched to a new branch |Your branch is )" "$output_file" || true)
}

git_checkout_with_summary() {
  local checkout_dir="$1"
  shift
  local output_file exit_code
  output_file="$(mktemp)"

  if git -C "$checkout_dir" "$@" >"$output_file" 2>&1; then
    summarize_git_checkout_output "$output_file"
    rm -f "$output_file"
    return 0
  fi

  exit_code=$?
  cat "$output_file" >&2
  rm -f "$output_file"
  return "$exit_code"
}

summarize_git_merge_output() {
  local output_file="$1"
  local range_line status_line

  if grep -F "Already up to date." "$output_file" >/dev/null 2>&1; then
    printf 'Already up to date.\n'
    return 0
  fi

  range_line="$(grep -E '^Updating ' "$output_file" | tail -n 1 || true)"
  status_line="$(grep -E '^[[:space:]]*[0-9]+ files? changed' "$output_file" | tail -n 1 | sed 's/^[[:space:]]*//' || true)"

  [[ -n "$range_line" ]] && printf '%s\n' "$range_line"
  [[ -n "$status_line" ]] && printf '%s\n' "$status_line"
}

git_merge_ff_only_with_summary() {
  local checkout_dir="$1"
  local target_ref="$2"
  local output_file exit_code
  output_file="$(mktemp)"

  if git -C "$checkout_dir" merge --ff-only "$target_ref" >"$output_file" 2>&1; then
    summarize_git_merge_output "$output_file"
    rm -f "$output_file"
    return 0
  fi

  exit_code=$?
  cat "$output_file" >&2
  rm -f "$output_file"
  return "$exit_code"
}

detect_source_ref_kind() {
  local checkout_dir="$1"
  local ref_name="$2"

  [[ -d "$checkout_dir/.git" ]] || die "Source checkout does not exist or is not a Git repo: $checkout_dir"
  run_with_retry "git-fetch" git_fetch_with_summary "$checkout_dir" \
    || die "Failed to sync source remote: $checkout_dir"

  if git -C "$checkout_dir" show-ref --verify --quiet "refs/remotes/origin/${ref_name}"; then
    printf 'branch\n'
    return
  fi
  if git -C "$checkout_dir" show-ref --verify --quiet "refs/heads/${ref_name}"; then
    printf 'branch\n'
    return
  fi
  if git -C "$checkout_dir" show-ref --verify --quiet "refs/tags/${ref_name}"; then
    printf 'tag\n'
    return
  fi
  if git -C "$checkout_dir" rev-parse --verify "${ref_name}^{commit}" >/dev/null 2>&1; then
    printf 'commit\n'
    return
  fi

  die "No matching ref found: $ref_name"
}

switch_source_checkout_to_ref() {
  local checkout_dir="$1"
  local ref_name="$2"
  local ref_kind="$3"

  case "$ref_kind" in
    branch)
      ensure_git_worktree_clean "$checkout_dir"
      if git -C "$checkout_dir" show-ref --verify --quiet "refs/heads/${ref_name}"; then
        git_checkout_with_summary "$checkout_dir" checkout "$ref_name"
      else
        git_checkout_with_summary "$checkout_dir" checkout -b "$ref_name" --track "origin/${ref_name}"
      fi
      git_merge_ff_only_with_summary "$checkout_dir" "origin/${ref_name}"
      ;;
    tag)
      ensure_git_worktree_clean "$checkout_dir"
      git_checkout_with_summary "$checkout_dir" checkout "$ref_name"
      ;;
    commit)
      ensure_git_worktree_clean "$checkout_dir"
      git_checkout_with_summary "$checkout_dir" checkout "$ref_name"
      ;;
    *)
      die "Unknown source ref type: $ref_kind"
      ;;
  esac
}

detect_source_workspace_root() {
  local checkout_dir="$1"

  if [[ -f "$checkout_dir/codex-rs/Cargo.toml" ]]; then
    printf '%s\n' "$checkout_dir/codex-rs"
    return
  fi
  if [[ -f "$checkout_dir/Cargo.toml" ]]; then
    printf '%s\n' "$checkout_dir"
    return
  fi

  die "No supported source build entry found (missing codex-rs/Cargo.toml or Cargo.toml)."
}

detect_source_build_strategy() {
  local workspace_root="$1"
  local metadata_file
  metadata_file="$(mktemp)"
  run_with_retry "cargo-metadata" cargo metadata --format-version 1 --no-deps --manifest-path "$workspace_root/Cargo.toml" >"$metadata_file" \
    || die "Failed to read cargo metadata: $workspace_root"

  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$metadata_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

for package in payload.get("packages", []):
    if package.get("name") != "codex-cli":
        continue
    for target in package.get("targets", []):
        if target.get("name") == "codex" and "bin" in (target.get("kind") or []):
            print("package\tcodex-cli")
            raise SystemExit(0)

for package in payload.get("packages", []):
    for target in package.get("targets", []):
        if target.get("name") == "codex" and "bin" in (target.get("kind") or []):
            print("bin\tcodex")
            raise SystemExit(0)

raise SystemExit(1)
PY
  else
    jq -r '
      (
        [.packages[]? | select(.name == "codex-cli") | .targets[]? | select(.name == "codex" and (.kind | index("bin")))][0]
      ) as $pkg
      | if $pkg != null then
          "package\tcodex-cli"
        elif ([.packages[]? | .targets[]? | select(.name == "codex" and (.kind | index("bin")))] | length) > 0 then
          "bin\tcodex"
        else
          empty
        end
    ' "$metadata_file"
  fi
  rm -f "$metadata_file"
}

run_cargo_build_with_progress() {
  local workspace_root="$1"
  local build_mode="$2"
  local build_target="$3"
  local helper_file manifest_path

  manifest_path="$workspace_root/Cargo.toml"

  if ((ORIGINAL_STDOUT_IS_TTY == 0)) || ! command_exists python3; then
    case "$build_mode" in
      package)
        cargo build --manifest-path "$manifest_path" -p "$build_target" --bin codex --release
        ;;
      bin)
        cargo build --manifest-path "$manifest_path" --bin "$build_target" --release
        ;;
      *)
        return 1
        ;;
    esac
    return $?
  fi

  helper_file="$(mktemp)"
  cat >"$helper_file" <<'PY'
import json
import shutil
import subprocess
import sys
import time
from collections import deque


def load_metadata(manifest_path):
    result = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--manifest-path", manifest_path],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def find_root_package_id(payload, build_mode, build_target):
    packages = payload.get("packages", [])
    if build_mode == "package":
        for package in packages:
            if package.get("name") == build_target:
                return package["id"]
    else:
        for package in packages:
            for target in package.get("targets", []):
                if target.get("name") == build_target and "bin" in (target.get("kind") or []):
                    return package["id"]
    raise SystemExit("No Cargo package found for the source build target.")


def collect_reachable_package_ids(payload, root_package_id):
    resolve = payload.get("resolve") or {}
    node_map = {node["id"]: node for node in resolve.get("nodes", [])}
    reachable = set()
    queue = deque([root_package_id])
    while queue:
        package_id = queue.popleft()
        if package_id in reachable:
            continue
        reachable.add(package_id)
        node = node_map.get(package_id) or {}
        for dep in node.get("deps", []):
            dep_id = dep.get("pkg")
            if dep_id and dep_id not in reachable:
                queue.append(dep_id)
    return reachable


def estimate_total_units(payload, reachable_ids):
    compile_kinds = {"bin", "lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro", "custom-build"}
    total = 0
    for package in payload.get("packages", []):
        if package.get("id") not in reachable_ids:
            continue
        for target in package.get("targets", []):
            kinds = set(target.get("kind") or [])
            if not (kinds & compile_kinds):
                continue
            if {"example", "bench", "test"} & kinds:
                continue
            total += 1
    return max(total, 1)


def format_duration(seconds):
    if seconds is None or seconds < 0:
        return "--:--"
    seconds = int(seconds)
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def truncate_label(text, width):
    if len(text) <= width:
        return text
    if width <= 1:
        return text[:width]
    return text[: width - 1] + "..."


def render_progress(completed, total, started_at, current_label, fresh_count, final=False):
    percent = 100 if final else min(int((completed / total) * 100), 99)
    elapsed = max(time.time() - started_at, 0.001)
    remaining = None
    if completed > 0 and not final:
        remaining = (elapsed / completed) * max(total - completed, 0)
    elif final:
        remaining = 0
    columns = shutil.get_terminal_size((100, 20)).columns
    bar_width = 24 if columns >= 96 else 18
    filled = bar_width if final else max(1 if completed > 0 else 0, int((completed / total) * bar_width))
    filled = min(filled, bar_width)
    bar = "#" * filled + "-" * (bar_width - filled)
    status = f"[{bar}] {percent:3d}% {completed}/{total} ETA {format_duration(remaining)}"
    if fresh_count > 0:
        status += f" fresh={fresh_count}"
    label_width = max(columns - len(status) - 12, 12)
    label = truncate_label(current_label or "Waiting for Cargo events", label_width)
    sys.stderr.write("\r" + status + " | " + label + " " * 4)
    sys.stderr.flush()
    if final:
        sys.stderr.write("\n")
        sys.stderr.flush()


def emit_text_line(line):
    sys.stderr.write("\r" + " " * max(shutil.get_terminal_size((100, 20)).columns - 1, 40) + "\r")
    sys.stderr.flush()
    print(line, flush=True)


def main():
    manifest_path, build_mode, build_target = sys.argv[1:4]
    payload = load_metadata(manifest_path)
    root_package_id = find_root_package_id(payload, build_mode, build_target)
    reachable_ids = collect_reachable_package_ids(payload, root_package_id)
    total_units = estimate_total_units(payload, reachable_ids)

    cargo_args = ["cargo", "build", "--message-format", "json-render-diagnostics", "--manifest-path", manifest_path, "--release"]
    if build_mode == "package":
        cargo_args.extend(["-p", build_target, "--bin", "codex"])
    else:
        cargo_args.extend(["--bin", build_target])

    print(f"Estimated compile progress: {total_units} compilation units", flush=True)
    process = subprocess.Popen(
        cargo_args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    compile_kinds = {"bin", "lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro", "custom-build"}
    completed = 0
    fresh_count = 0
    seen = set()
    started_at = time.time()
    render_progress(0, total_units, started_at, "Preparing build graph", 0)

    assert process.stdout is not None
    for raw_line in process.stdout:
        line = raw_line.rstrip("\n")
        stripped = line.lstrip()
        parsed = None
        if stripped.startswith("{"):
            try:
                parsed = json.loads(stripped)
            except json.JSONDecodeError:
                parsed = None

        if isinstance(parsed, dict):
            reason = parsed.get("reason")
            if reason == "compiler-artifact":
                target = parsed.get("target") or {}
                kinds = tuple(target.get("kind") or [])
                if set(kinds) & compile_kinds and not ({"example", "bench", "test"} & set(kinds)):
                    key = (parsed.get("package_id"), target.get("name"), kinds)
                    if key not in seen:
                        seen.add(key)
                        completed = len(seen)
                        if parsed.get("fresh"):
                            fresh_count += 1
                        current = f"{target.get('name') or '<unknown>'} ({'/'.join(kinds) or 'target'})"
                        render_progress(completed, total_units, started_at, current, fresh_count)
                continue
            if reason == "compiler-message":
                message = parsed.get("message") or {}
                rendered = message.get("rendered")
                if rendered:
                    sys.stderr.write("\n")
                    sys.stderr.flush()
                    print(rendered, end="" if rendered.endswith("\n") else "\n", flush=True)
                    render_progress(completed, total_units, started_at, message.get("message") or "Compiler message", fresh_count)
                continue
            if reason == "build-script-executed":
                continue
            if reason == "build-finished":
                success = bool(parsed.get("success"))
                render_progress(total_units if success else completed, total_units, started_at, "Build finished", fresh_count, final=success)
                continue

        emit_text_line(line)
        render_progress(completed, total_units, started_at, "Processing", fresh_count)

    exit_code = process.wait()
    if exit_code != 0:
        sys.stderr.write("\n")
        sys.stderr.flush()
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY

  python3 "$helper_file" "$manifest_path" "$build_mode" "$build_target"
  local exit_code=$?
  rm -f "$helper_file"
  return "$exit_code"
}

build_source_binary() {
  local workspace_root="$1"
  local binary_output_path="$2"
  local build_mode build_target source_binary

  IFS=$'\t' read -r build_mode build_target <<<"$(detect_source_build_strategy "$workspace_root")" \
    || die "No buildable codex CLI entry found in the source repo."

  log_step "Build Hodex from source"
  case "$build_mode" in
    package)
      run_with_retry "cargo-build" run_cargo_build_with_progress "$workspace_root" "$build_mode" "$build_target" \
        || die "Source build failed: $workspace_root"
      ;;
    bin)
      run_with_retry "cargo-build" run_cargo_build_with_progress "$workspace_root" "$build_mode" "$build_target" \
        || die "Source build failed: $workspace_root"
      ;;
    *)
      die "Unknown source build mode: $build_mode"
      ;;
  esac

  source_binary="$workspace_root/target/release/codex"
  [[ -x "$source_binary" ]] || die "Source build finished but expected artifact not found: $source_binary"

  ensure_dir_writable "$(dirname "$binary_output_path")"
  install -m 0755 "$source_binary" "$binary_output_path"
}

SOURCE_REQUIRED_MISSING=()
SOURCE_OPTIONAL_MISSING=()

append_missing_tool() {
  local array_name="$1"
  local item="$2"
  eval "$array_name+=(\"\$item\")"
}

array_length_safe() {
  local array_name="$1"
  local count
  count="$(eval "set -- \${${array_name}[@]-}; printf '%s' \$#")"
  printf '%s\n' "$count"
}

array_items_safe() {
  local array_name="$1"
  eval "printf '%s\n' \"\${${array_name}[@]-}\""
}

detect_source_toolchain_report() {
  SOURCE_REQUIRED_MISSING=()
  SOURCE_OPTIONAL_MISSING=()

  command_exists git || append_missing_tool SOURCE_REQUIRED_MISSING git
  command_exists rustup || append_missing_tool SOURCE_REQUIRED_MISSING rustup
  command_exists cargo || append_missing_tool SOURCE_REQUIRED_MISSING cargo
  command_exists rustc || append_missing_tool SOURCE_REQUIRED_MISSING rustc

  case "$OS_NAME" in
    darwin)
      xcode-select -p >/dev/null 2>&1 || append_missing_tool SOURCE_REQUIRED_MISSING xcode-clt
      command_exists pkg-config || append_missing_tool SOURCE_REQUIRED_MISSING pkg-config
      ;;
    linux)
      command_exists cc || append_missing_tool SOURCE_REQUIRED_MISSING cc
      command_exists c++ || append_missing_tool SOURCE_REQUIRED_MISSING cxx
      command_exists pkg-config || append_missing_tool SOURCE_REQUIRED_MISSING pkg-config
      ;;
  esac

  command_exists just || append_missing_tool SOURCE_OPTIONAL_MISSING just
  command_exists node || append_missing_tool SOURCE_OPTIONAL_MISSING node
  if ! command_exists npm && ! command_exists pnpm; then
    append_missing_tool SOURCE_OPTIONAL_MISSING npm
  fi
}

print_source_toolchain_report() {
  local item
  printf 'Source toolchain check:\n'
  printf '  Required:\n'
  for item in git rustup cargo rustc; do
    if command_exists "$item"; then
      printf '    - %s: installed\n' "$item"
    else
      printf '    - %s: missing\n' "$item"
    fi
  done

  case "$OS_NAME" in
    darwin)
      if xcode-select -p >/dev/null 2>&1; then
        printf '    - xcode-clt: installed\n'
      else
        printf '    - xcode-clt: missing\n'
      fi
      if command_exists pkg-config; then
        printf '    - pkg-config: installed\n'
      else
        printf '    - pkg-config: missing\n'
      fi
      ;;
    linux)
      for item in cc c++ pkg-config; do
        if command_exists "$item"; then
          printf '    - %s: installed\n' "$item"
        else
          printf '    - %s: missing\n' "$item"
        fi
      done
      ;;
  esac

  printf '  Optional:\n'
  for item in just node; do
    if command_exists "$item"; then
      printf '    - %s: installed\n' "$item"
    else
      printf '    - %s: missing\n' "$item"
    fi
  done
  if command_exists npm || command_exists pnpm; then
    printf '    - npm/pnpm: installed\n'
  else
    printf '    - npm/pnpm: missing\n'
  fi
}

install_rustup_via_script() {
  log_step "Install Rust toolchain (rustup)"
  run_with_retry "rustup-install" /bin/bash -lc "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  export PATH="$HOME/.cargo/bin:$PATH"
}

detect_linux_package_manager() {
  local candidate
  for candidate in apt-get dnf yum pacman zypper; do
    if command_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

install_homebrew_if_needed() {
  if command_exists brew; then
    return 0
  fi

  prompt_yes_no "Homebrew not detected. Install Homebrew first? [Y/n]: " "Y" || return 1
  log_step "Install Homebrew"
  run_with_retry "brew-install" /bin/bash -lc 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  command_exists brew
}

auto_install_source_toolchain() {
  local item package_manager install_packages=() required_count optional_count

  detect_source_toolchain_report
  required_count="$(array_length_safe SOURCE_REQUIRED_MISSING)"
  optional_count="$(array_length_safe SOURCE_OPTIONAL_MISSING)"
  ((required_count > 0 || optional_count > 0)) || return 0

  case "$OS_NAME" in
    darwin)
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        case "$item" in
          git | pkg-config | node)
            install_homebrew_if_needed || die "Homebrew is missing; cannot auto-install $item."
            brew install "$item"
            ;;
          just)
            command_exists cargo || install_rustup_via_script
            log_step "Install just"
            run_with_retry "cargo-install" cargo install just
            export PATH="$HOME/.cargo/bin:$PATH"
            ;;
          rustup | cargo | rustc)
            install_rustup_via_script
            ;;
          xcode-clt)
            xcode-select --install || true
            die "Triggered Xcode Command Line Tools installer. Finish installation and rerun."
            ;;
        esac
      done < <(
        array_items_safe SOURCE_REQUIRED_MISSING
        array_items_safe SOURCE_OPTIONAL_MISSING
      )
      ;;
    linux)
      package_manager="$(detect_linux_package_manager)" || die "No supported Linux package manager detected for auto-install."
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        case "$item" in
          git) install_packages+=("git") ;;
          cc | cxx)
            case "$package_manager" in
              apt-get) install_packages+=("build-essential") ;;
              dnf | yum) install_packages+=("gcc" "gcc-c++" "make") ;;
              pacman) install_packages+=("base-devel") ;;
              zypper) install_packages+=("gcc" "gcc-c++" "make") ;;
            esac
            ;;
          pkg-config) install_packages+=("pkg-config") ;;
          node | npm)
            case "$package_manager" in
              apt-get) install_packages+=("nodejs" "npm") ;;
              dnf | yum | zypper) install_packages+=("nodejs" "npm") ;;
              pacman) install_packages+=("nodejs" "npm") ;;
            esac
            ;;
          just)
            command_exists cargo || install_rustup_via_script
            log_step "Install just"
            run_with_retry "cargo-install" cargo install just
            export PATH="$HOME/.cargo/bin:$PATH"
            ;;
          rustup | cargo | rustc)
            install_rustup_via_script
            ;;
        esac
      done < <(
        array_items_safe SOURCE_REQUIRED_MISSING
        array_items_safe SOURCE_OPTIONAL_MISSING
      )
      if ((${#install_packages[@]} > 0)); then
        case "$package_manager" in
          apt-get)
            sudo apt-get update
            sudo apt-get install -y "${install_packages[@]}"
            ;;
          dnf)
            sudo dnf install -y "${install_packages[@]}"
            ;;
          yum)
            sudo yum install -y "${install_packages[@]}"
            ;;
          pacman)
            sudo pacman -Sy --noconfirm "${install_packages[@]}"
            ;;
          zypper)
            sudo zypper --non-interactive install "${install_packages[@]}"
            ;;
        esac
      fi
      ;;
  esac
}

source_toolchain_snapshot_json() {
  if [[ "$JSON_BACKEND" == "python3" ]]; then
    python3 - "$OS_NAME" "$ARCH_NAME" "$(printf '%s\n' "${SOURCE_REQUIRED_MISSING[@]-}")" "$(printf '%s\n' "${SOURCE_OPTIONAL_MISSING[@]-}")" <<'PY'
import json
import sys

os_name, arch_name, required_raw, optional_raw = sys.argv[1:5]
required = [line for line in required_raw.splitlines() if line]
optional = [line for line in optional_raw.splitlines() if line]
print(json.dumps({
    "os": os_name,
    "arch": arch_name,
    "required_missing": required,
    "optional_missing": optional,
}, ensure_ascii=False))
PY
    return
  fi

  local required optional
  required="$(printf '%s\n' "${SOURCE_REQUIRED_MISSING[@]-}" | awk 'NF' | jq -R . | jq -s .)"
  optional="$(printf '%s\n' "${SOURCE_OPTIONAL_MISSING[@]-}" | awk 'NF' | jq -R . | jq -s .)"
  jq -n \
    --arg os "$OS_NAME" \
    --arg arch "$ARCH_NAME" \
    --argjson required_missing "${required:-[]}" \
    --argjson optional_missing "${optional:-[]}" \
    '{
      os: $os,
      arch: $arch,
      required_missing: $required_missing,
      optional_missing: $optional_missing
    }'
}

ensure_source_toolchain_ready() {
  local required_count optional_count
  detect_source_toolchain_report
  print_source_toolchain_report

  required_count="$(array_length_safe SOURCE_REQUIRED_MISSING)"
  optional_count="$(array_length_safe SOURCE_OPTIONAL_MISSING)"
  if ((required_count == 0 && optional_count == 0)); then
    return 0
  fi

  if prompt_yes_no "Auto-install missing tools above? [Y/n]: " "Y"; then
    auto_install_source_toolchain
    detect_source_toolchain_report
    print_source_toolchain_report
  fi

  required_count="$(array_length_safe SOURCE_REQUIRED_MISSING)"
  ((required_count == 0)) || die "Source build toolchain is still incomplete. Install missing items and retry."
}

prepare_source_checkout() {
  local remote_url="$1"
  local checkout_dir="$2"

  if [[ ! -e "$checkout_dir" ]]; then
    ensure_dir_writable "$(dirname "$checkout_dir")"
    log_step "Clone source repo"
    run_with_retry "git-clone" git clone "$remote_url" "$checkout_dir" \
      || die "Failed to clone source repo: $remote_url"
    return
  fi

  if [[ -d "$checkout_dir/.git" ]]; then
    log_step "Reuse existing source checkout"
    local current_remote
    current_remote="$(git -C "$checkout_dir" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$current_remote" && "$current_remote" != "$remote_url" ]]; then
      if prompt_yes_no "Source checkout exists with a different remote. Update origin to $remote_url ? [y/N]: " "N"; then
        git -C "$checkout_dir" remote set-url origin "$remote_url"
      else
        die "Source checkout remote does not match requested: $checkout_dir"
      fi
    fi
    return
  fi

  die "Source checkout path exists but is not a Git repo: $checkout_dir"
}

apply_source_profile_runtime_choice() {
  local state_file="$1"
  local profile_name="$2"
  local current_mode="$3"
  : "$current_mode"

  printf 'no\n'
}

perform_source_sync() {
  local state_file="$1"
  local profile_name="$2"
  local activation_mode="${3:-preserve}"
  local action_label="${4:-Sync source profile}"
  local skip_plan_confirm="${5:-0}"
  local repo_input remote_url checkout_dir default_checkout_dir ref_name ref_kind workspace_mode workspace_root existing_checkout_dir
  local installed_at last_synced_at toolchain_snapshot checkout_mode_preview

  validate_source_profile_name "$profile_name"
  if [[ -f "$state_file" ]]; then
    load_state_env "$state_file"
  fi
  IFS=$'\t' read -r repo_input remote_url <<<"$(resolve_source_repo_input "$state_file" "$profile_name")"
  [[ -n "$remote_url" ]] || die "No valid source repo provided."

  default_checkout_dir="$(default_source_checkout_dir "$remote_url")"
  existing_checkout_dir="$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")"
  checkout_dir="$(resolve_source_checkout_dir "$default_checkout_dir" "$profile_name" "$state_file")"
  ref_name="$SOURCE_REF"
  checkout_mode_preview="Reuse existing checkout"
  if [[ ! -e "$checkout_dir" ]]; then
    checkout_mode_preview="Clone into new directory"
  elif [[ -n "$SOURCE_CHECKOUT_DIR" && "$checkout_dir" != "$default_checkout_dir" ]]; then
    checkout_mode_preview="Use explicitly specified checkout"
  fi

  if ((skip_plan_confirm == 0)); then
    confirm_source_action_plan "$action_label" "$profile_name" "$repo_input" "$checkout_dir" "$ref_name" "" "$checkout_mode_preview" "$(state_get_source_profile_field "$state_file" "$profile_name" "current_ref")" "$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")" || return 0
  fi

  ensure_source_toolchain_ready
  prepare_source_checkout "$remote_url" "$checkout_dir"
  ref_kind="$(detect_source_ref_kind "$checkout_dir" "$ref_name")"
  switch_source_checkout_to_ref "$checkout_dir" "$ref_name" "$ref_kind"
  if [[ -f "$checkout_dir/codex-rs/Cargo.toml" ]]; then
    workspace_root="$checkout_dir/codex-rs"
  elif [[ -f "$checkout_dir/Cargo.toml" ]]; then
    workspace_root="$checkout_dir"
  else
    workspace_root="$checkout_dir"
  fi

  select_command_dir
  sync_controller_copy "$STATE_DIR/libexec/hodexctl.sh"

  workspace_mode="shared"
  if [[ -n "$SOURCE_CHECKOUT_DIR" && -n "$existing_checkout_dir" && "$checkout_dir" != "$existing_checkout_dir" ]]; then
    workspace_mode="isolated"
  elif [[ -z "$existing_checkout_dir" && -n "$SOURCE_CHECKOUT_DIR" && "$checkout_dir" != "$default_checkout_dir" ]]; then
    workspace_mode="isolated"
  fi
  installed_at="$(state_get_source_profile_field "$state_file" "$profile_name" "installed_at")"
  [[ -n "$installed_at" ]] || installed_at="$(current_utc_timestamp)"
  last_synced_at="$(current_utc_timestamp)"
  toolchain_snapshot="$(source_toolchain_snapshot_json)"

  state_upsert_source_profile \
    "$state_file" \
    "$profile_name" \
    "$repo_input" \
    "$remote_url" \
    "$checkout_dir" \
    "$workspace_mode" \
    "$ref_name" \
    "$ref_kind" \
    "$workspace_root" \
    "" \
    "" \
    "$installed_at" \
    "$last_synced_at" \
    "$toolchain_snapshot" \
    "$activation_mode" \
    "$COMMAND_DIR" \
    "$STATE_DIR/libexec/hodexctl.sh"

  sync_runtime_wrappers_from_state "$state_file" "$COMMAND_DIR" "$STATE_DIR/libexec/hodexctl.sh"
  update_path_if_needed
  state_update_runtime_metadata "$state_file" "$COMMAND_DIR" "$STATE_DIR/libexec/hodexctl.sh" "$PATH_UPDATE_MODE" "$PATH_PROFILE" "$PATH_MANAGED_BY_HODEXCTL" "$PATH_DETECTED_SOURCE"

  log_step "Source sync completed: $checkout_dir"
  print_source_result_summary "$action_label" "$profile_name" "$ref_name" "$checkout_dir" "" ""
}

perform_source_install() {
  local state_file="$STATE_DIR/state.json"
  local profile_name activation_mode

  run_source_install_wizard || return 0
  profile_name="$(resolve_source_profile_name "$state_file" 0)"
  activation_mode="no"
  perform_source_sync "$state_file" "$profile_name" "$activation_mode" "Download source and prepare toolchain" 1
}

perform_source_update() {
  local state_file="$STATE_DIR/state.json"
  local profile_name current_ref

  [[ -f "$state_file" ]] || die "No source profiles found. Run 'hodexctl source install' first."
  profile_name="$(resolve_source_profile_name "$state_file" 1)"
  current_ref="$(state_get_source_profile_field "$state_file" "$profile_name" "current_ref")"
  [[ -n "$SOURCE_REF" && "$SOURCE_REF" != "$DEFAULT_SOURCE_REF" ]] || SOURCE_REF="${current_ref:-$DEFAULT_SOURCE_REF}"
  perform_source_sync "$state_file" "$profile_name" "no" "Update source"
}

perform_source_rebuild() {
  die "source rebuild has been removed; source mode now only keeps download/sync and toolchain prep."
}

perform_source_switch() {
  local state_file="$STATE_DIR/state.json"
  local profile_name

  [[ -f "$state_file" ]] || die "No source profiles found. Run 'hodexctl source install' first."
  profile_name="$(resolve_source_profile_name "$state_file" 1)"
  if ! ((EXPLICIT_SOURCE_REF)); then
    if [[ -t 0 && -t 1 ]] && ! ((AUTO_YES)); then
      SOURCE_REF="$(
        prompt_source_ref_with_candidates \
          "$state_file" \
          "$(state_get_source_profile_field "$state_file" "$profile_name" "repo_input")" \
          "$profile_name" \
          "$(state_get_source_profile_field "$state_file" "$profile_name" "current_ref")" \
          "$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")"
      )"
      EXPLICIT_SOURCE_REF=1
    else
      die "source switch requires --ref to specify branch/tag/commit."
    fi
  fi
  perform_source_sync "$state_file" "$profile_name" "no" "Switch ref and sync source"
}

perform_source_status() {
  local state_file="$STATE_DIR/state.json"
  local profile_name source_count

  printf 'Source mode status:\n'
  source_count="$(state_count_source_profiles "$state_file")"
  if [[ ! -f "$state_file" ]] || [[ "$source_count" == "0" ]]; then
    printf '  No source profiles installed\n'
    return 0
  fi

  if ((EXPLICIT_SOURCE_PROFILE)); then
    profile_name="$SOURCE_PROFILE"
  elif [[ "$source_count" == "1" ]]; then
    profile_name="$(resolve_source_profile_name "$state_file" 1)"
  fi

  if [[ -n "$profile_name" ]]; then
    [[ -n "$(state_get_source_profile_field "$state_file" "$profile_name" "name")" ]] || die "Source profile not found: $profile_name"
    printf '  Name: %s\n' "$profile_name"
    printf '  Repo: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "repo_input")"
    printf '  Remote: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "remote_url")"
    printf '  Checkout: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")"
    printf '  Ref: %s (%s)\n' \
      "$(state_get_source_profile_field "$state_file" "$profile_name" "current_ref")" \
      "$(state_get_source_profile_field "$state_file" "$profile_name" "ref_kind")"
    printf '  Workspace: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "build_workspace_root")"
    printf '  Installed at: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "installed_at")"
    printf '  Last synced: %s\n' "$(state_get_source_profile_field "$state_file" "$profile_name" "last_synced_at")"
    printf '  Mode: manage checkout and toolchain only; no source command wrappers generated\n'
    return 0
  fi

  while IFS=$'\t' read -r profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$profile_name" ]] || continue
    printf '  - %s | %s | %s | %s | source-only management\n' "$profile_name" "${repo_input:-<unknown>}" "${current_ref:-<unknown>}" "${checkout_dir:-<unknown>}"
  done < <(state_emit_source_profiles "$state_file")
}

perform_source_list() {
  local state_file="$STATE_DIR/state.json"
  local profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at
  printf 'Source profiles:\n'
  if [[ ! -f "$state_file" ]] || [[ "$(state_count_source_profiles "$state_file")" == "0" ]]; then
    printf '  No source profiles recorded\n'
    return 0
  fi
  while IFS=$'\t' read -r profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$profile_name" ]] || continue
    printf '  - %s | %s | %s | %s | source-only management\n' "$profile_name" "${repo_input:-<unknown>}" "${current_ref:-<unknown>}" "${checkout_dir:-<unknown>}"
  done < <(state_emit_source_profiles "$state_file")
}

perform_source_uninstall() {
  local state_file="$STATE_DIR/state.json"
  local profile_name binary_path checkout_dir current_ref remove_checkout answer final_source_count final_has_release

  [[ -f "$state_file" ]] || die "No source profiles found."
  load_state_env "$state_file"
  profile_name="$(resolve_source_profile_name "$state_file" 1)"
  binary_path="$(state_get_source_profile_field "$state_file" "$profile_name" "binary_path")"
  checkout_dir="$(state_get_source_profile_field "$state_file" "$profile_name" "checkout_dir")"
  current_ref="$(state_get_source_profile_field "$state_file" "$profile_name" "current_ref")"
  confirm_source_action_plan "Uninstall source profile" "$profile_name" "$(state_get_source_profile_field "$state_file" "$profile_name" "repo_input")" "$checkout_dir" "$current_ref" "This will remove the source profile record; optionally delete the checkout." "Remove existing profile assets" "$current_ref" "$checkout_dir" || return 0

  rm -f "$COMMAND_DIR/$profile_name" "$STATE_COMMAND_DIR/$profile_name" 2>/dev/null || true
  [[ -n "$binary_path" ]] && rm -f "$binary_path"

  case "$SOURCE_CHECKOUT_POLICY" in
    remove)
      remove_checkout=1
      ;;
    keep)
      remove_checkout=0
      ;;
    *)
      if ((AUTO_YES)); then
        remove_checkout=0
      else
        if prompt_yes_no "Also delete checkout directory ${checkout_dir} ? [y/N]: " "N"; then
          remove_checkout=1
        else
          remove_checkout=0
        fi
      fi
      ;;
  esac

  if ((remove_checkout)) && [[ -n "$checkout_dir" ]]; then
    rm -rf "$checkout_dir"
  fi

  state_remove_source_profile "$state_file" "$profile_name"

  if [[ -f "$state_file" ]]; then
    if [[ -n "$STATE_COMMAND_DIR" ]]; then
      COMMAND_DIR="$STATE_COMMAND_DIR"
    elif [[ -n "$(json_get_field "$state_file" "command_dir")" ]]; then
      COMMAND_DIR="$(json_get_field "$state_file" "command_dir")"
    fi
    if [[ -n "$COMMAND_DIR" ]]; then
      sync_runtime_wrappers_from_state "$state_file" "$COMMAND_DIR" "${STATE_CONTROLLER_PATH:-$STATE_DIR/libexec/hodexctl.sh}"
    fi
  fi

  final_source_count="$(state_count_source_profiles "$state_file")"
  final_has_release=0
  if [[ -f "$state_file" ]] && [[ -n "$(json_get_field "$state_file" "binary_path")" ]]; then
    final_has_release=1
  fi

  if [[ -f "$state_file" ]] && [[ "$final_source_count" == "0" ]] && ((final_has_release == 0)); then
    cleanup_path_blocks_for_uninstall "$(select_profile_file)"
    rm -f "${STATE_COMMAND_DIR:-$COMMAND_DIR}/hodexctl" 2>/dev/null || true
    rm -f "$state_file"
    rm -f "$STATE_DIR/list-ui-state.json"
    rm -f "${STATE_CONTROLLER_PATH:-$STATE_DIR/libexec/hodexctl.sh}"
    rmdir "${STATE_COMMAND_DIR:-$COMMAND_DIR}" 2>/dev/null || true
    rmdir "$STATE_DIR/libexec" 2>/dev/null || true
    rmdir "$STATE_DIR/bin/source/${profile_name}" 2>/dev/null || true
    rmdir "$STATE_DIR/bin/source" 2>/dev/null || true
    rmdir "$STATE_DIR/bin" 2>/dev/null || true
    rmdir "$STATE_DIR/src" 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
  fi

  printf 'Source profile uninstalled: %s\n' "$profile_name"
  print_source_result_summary "Uninstall source profile" "$profile_name" "$current_ref" "$checkout_dir" "" ""
}

show_source_management_menu() {
  local state_file="$STATE_DIR/state.json"
  local source_count
  local action_label=""
  local action_hint=""
  local saved_source_ref saved_explicit_source_ref ref_answer

  while true; do
    source_count="0"
    if [[ -f "$state_file" ]]; then
      source_count="$(state_count_source_profiles "$state_file")"
    fi

    printf '\033[H\033[2J'
    if ((COLOR_ENABLED)); then
      printf '%s%sSource download / management%s\n\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
      printf '%sRule%s: `hodex` always points to release; source mode only manages checkout and toolchain.\n' "$COLOR_HINT" "$COLOR_RESET"
      printf '%sCurrent%s: %s source profiles recorded\n\n' "$COLOR_HINT" "$COLOR_RESET" "$source_count"
    else
      printf 'Source download / management\n\n'
      printf 'Rule: `hodex` always points to release; source mode only manages checkout and toolchain.\n'
      printf 'Current: %s source profiles recorded\n\n' "$source_count"
    fi
    printf '  [Sync]\n'
    printf '  1. Download source and prepare toolchain         Download or reuse checkout and check dev toolchain\n'
    printf '  2. Update source                                 Fetch latest code for current profile ref\n'
    printf '  3. Switch branch / tag / commit and sync         Switch to new ref then sync source\n'
    printf '\n'
    printf '  [View / Clean up]\n'
    printf '  5. View source status                     Show one or all source profiles\n'
    printf '  6. Uninstall source profile               Remove profile record; optionally delete checkout\n'
    printf '  7. List source profiles                   Quick summary of all source profiles\n'
    printf '  q. Back to version list\n\n'
    printf 'Choose an action (enter number): '

    local choice
    read -r choice
    case "$choice" in
      1)
        action_label="Download source and prepare toolchain"
        action_hint="Next: confirm repo, checkout dir, toolchain, and source profile name."
        ;;
      2)
        action_label="Update source"
        action_hint="Will fetch latest code for the current profile and sync checkout."
        ;;
      3)
        action_label="Switch ref and sync source"
        action_hint="Next: specify a new branch / tag / commit."
        if ((AUTO_YES)); then
          if [[ -z "$SOURCE_REF" ]]; then
            SOURCE_REF="$DEFAULT_SOURCE_REF"
          fi
          EXPLICIT_SOURCE_REF=1
        fi
        ;;
      5)
        action_label="View source status"
        action_hint="Will show detailed status for source profiles."
        ;;
      6)
        action_label="Uninstall source profile"
        action_hint="Will remove the selected profile record; optionally delete the checkout."
        ;;
      7)
        action_label="List source profiles"
        action_hint="Will show a summary for all source profiles."
        ;;
      q | Q) return 0 ;;
      *)
        log_warn "Please enter 1, 2, 3, 5, 6, 7, or q."
        printf '\nPress Enter to continue...'
        read -r _
        continue
        ;;
    esac

    printf '\033[H\033[2J'
    if ((COLOR_ENABLED)); then
      printf '%s%sSource download / management%s\n\n' "$COLOR_HEADER" "$COLOR_BOLD" "$COLOR_RESET"
      printf '%sEntering%s: %s\n' "$COLOR_STATUS" "$COLOR_RESET" "$action_label"
      printf '%sHint%s: %s\n\n' "$COLOR_HINT" "$COLOR_RESET" "$action_hint"
    else
      printf 'Source download / management\n\n'
      printf 'Entering: %s\n' "$action_label"
      printf 'Hint: %s\n\n' "$action_hint"
    fi
    print_source_menu_action_preview "$choice"
    printf '\n'

    saved_source_ref="$SOURCE_REF"
    saved_explicit_source_ref="$EXPLICIT_SOURCE_REF"
    local action_rc
    printf 'Real-time logs and prompts will follow.\n\n'
    set +e
    case "$choice" in
      1) run_source_menu_action install ;;
      2) run_source_menu_action update ;;
      3) run_source_menu_action switch ;;
      5) run_source_menu_action status ;;
      6) run_source_menu_action uninstall ;;
      7) run_source_menu_action list ;;
    esac
    action_rc=$?
    set -e
    SOURCE_REF="$saved_source_ref"
    EXPLICIT_SOURCE_REF="$saved_explicit_source_ref"

    printf '\n'
    if ((action_rc == 0)); then
      log_info "Completed: $action_label"
    else
      log_warn "Failed: $action_label"
      log_warn "Check the log above to diagnose the issue."
    fi
    printf '\nPress Enter to continue...'
    read -r _
  done
}

run_with_optional_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi

  if command_exists sudo; then
    sudo "$@"
    return
  fi

  die "Elevated privileges required but sudo is not available: $*"
}

install_node_native() {
  if [[ "$OS_NAME" == "darwin" ]]; then
    if ! command_exists brew; then
      log_warn "Homebrew not detected. Cannot install via system package manager. Use manual install: $NODE_DOWNLOAD_URL"
      return
    fi
    log_step "Install Node.js with Homebrew"
    brew install node || log_warn "Homebrew failed to install Node.js; please install manually later."
    return
  fi

  if command_exists apt; then
    log_step "Install Node.js with apt"
    run_with_optional_sudo apt update
    run_with_optional_sudo apt install -y nodejs npm
    return
  fi
  if command_exists dnf; then
    log_step "Install Node.js with dnf"
    run_with_optional_sudo dnf install -y nodejs npm
    return
  fi
  if command_exists yum; then
    log_step "Install Node.js with yum"
    run_with_optional_sudo yum install -y nodejs npm
    return
  fi
  if command_exists pacman; then
    log_step "Install Node.js with pacman"
    run_with_optional_sudo pacman -Sy --noconfirm nodejs npm
    return
  fi
  if command_exists zypper; then
    log_step "Install Node.js with zypper"
    run_with_optional_sudo zypper install -y nodejs npm
    return
  fi

  log_warn "No supported native package manager detected. Use nvm or manual install: $NODE_DOWNLOAD_URL"
}

install_node_with_nvm() {
  if [[ "$OS_NAME" != "darwin" && "$OS_NAME" != "linux" ]]; then
    log_warn "Auto nvm install is not supported on this platform."
    return
  fi

  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    log_step "Install nvm"
    run_with_retry "nvm-install" /bin/bash -lc "curl -fsSL '$NVM_INSTALL_URL' | bash"
  fi

  # shellcheck disable=SC1090
  source "$nvm_dir/nvm.sh"
  log_step "Install Node.js LTS with nvm"
  nvm install --lts
  nvm alias default 'lts/*' >/dev/null 2>&1 || true
}

remove_managed_runtime_wrappers_from_dir() {
  local command_dir="$1"
  local state_file="$2"
  local line profile_name

  [[ -n "$command_dir" ]] || return 0

  rm -f "$command_dir/hodex" "$command_dir/hodex-stable" "$command_dir/hodexctl"
  [[ -f "$state_file" ]] || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    profile_name="${line%%$'\t'*}"
    [[ -n "$profile_name" ]] || continue
    rm -f "$command_dir/$profile_name"
  done < <(state_emit_source_profiles "$state_file")
}

sync_runtime_wrappers_from_state() {
  local state_file="$1"
  local command_dir="$2"
  local controller_path="$3"
  local line profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at
  local release_binary_path release_installed=0 source_count=0 keep_controller_wrapper=0

  ensure_dir_writable "$command_dir"
  remove_managed_runtime_wrappers_from_dir "$command_dir" "$state_file"

  if [[ -f "$state_file" ]]; then
    load_state_env "$state_file"
    source_count="$(state_count_source_profiles "$state_file")"
    if [[ -n "$STATE_BINARY_PATH" && -f "$STATE_BINARY_PATH" ]]; then
      release_installed=1
      release_binary_path="$STATE_BINARY_PATH"
    fi
  fi

  if [[ -f "$state_file" && -n "$controller_path" ]]; then
    keep_controller_wrapper=1
  fi
  if ((keep_controller_wrapper)); then
    generate_hodexctl_wrapper "$command_dir/hodexctl" "$controller_path" "$STATE_DIR"
  fi

  while IFS=$'\t' read -r profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
    [[ -n "$profile_name" ]] || continue
    if [[ -n "$binary_path" && -f "$binary_path" ]]; then
      generate_runtime_wrapper "$command_dir/$profile_name" "$binary_path" "$profile_name"
    fi
  done < <(state_emit_source_profiles "$state_file")

  if ((release_installed)); then
    generate_hodex_wrapper "$command_dir/hodex" "$release_binary_path"
  fi
}

remove_old_wrappers_if_needed() {
  local new_command_dir="$1"
  if [[ -n "$STATE_COMMAND_DIR" && "$STATE_COMMAND_DIR" != "$new_command_dir" ]]; then
    remove_managed_runtime_wrappers_from_dir "$STATE_COMMAND_DIR" "$STATE_DIR/state.json"
  fi
}

perform_install_like() {
  local requested="$1"
  local action_label="$2"
  local state_file="$STATE_DIR/state.json"
  local had_existing_state=0
  local existing_node_choice=""
  local release_file tmp_dir download_path asset_line asset_name asset_url asset_digest
  local resolved_version detected_version release_tag release_name binary_dir binary_path controller_path install_time
  local state_installed_version state_release_tag state_release_name state_asset_name state_binary_path state_controller_path state_node_setup_choice state_installed_at
  local -a asset_candidates=()

  if [[ -f "$state_file" ]]; then
    load_state_env "$state_file"
    had_existing_state=1
    existing_node_choice="$STATE_NODE_SETUP_CHOICE"
  fi

  release_file="$(mktemp)"
  resolve_release "$requested" "$release_file"

  release_name="$(json_get_field "$release_file" "name")"
  release_tag="$(json_get_field "$release_file" "tag_name")"
  resolved_version="$(normalize_version "${release_tag:-$release_name}")"

  while IFS= read -r candidate; do
    asset_candidates+=("$candidate")
  done < <(get_asset_candidates)
  asset_line="$(json_find_asset_info "$release_file" "${asset_candidates[@]}")" \
    || die "Release has no matching asset for this platform: ${asset_candidates[*]}"
  IFS=$'\t' read -r asset_name asset_url asset_digest <<<"$asset_line"

  log_step "$action_label Hodex"
  log_step "Detected platform: $PLATFORM_LABEL"
  log_step "Selected release: ${release_name:-<unknown>} (${release_tag:-<unknown>})"
  log_step "Download asset: $asset_name"

  select_command_dir
  binary_dir="$STATE_DIR/bin"
  binary_path="$binary_dir/codex"
  controller_path="$STATE_DIR/libexec/hodexctl.sh"
  ensure_dir_writable "$binary_dir"
  ensure_dir_writable "$(dirname "$controller_path")"

  tmp_dir="$(mktemp -d)"
  download_path="$tmp_dir/$asset_name"
  log_step "Temp download path: $download_path"
  log_step "Install target binary: $binary_path"
  log_step "Command dir: $COMMAND_DIR"

  download_binary "$asset_url" "$download_path" "Downloading $asset_name"
  chmod 0755 "$download_path"
  verify_digest_if_present "$download_path" "$asset_digest"

  install -m 0755 "$download_path" "$binary_path"
  sync_controller_copy "$controller_path"
  if ((had_existing_state)); then
    remove_old_wrappers_if_needed "$COMMAND_DIR"
  fi
  prompt_node_choice "$existing_node_choice"

  detected_version="$(detect_installed_binary_version "$binary_path")"
  if [[ -n "$detected_version" ]]; then
    resolved_version="$detected_version"
    if [[ "$release_tag" == "latest" ]]; then
      release_tag="v${detected_version}"
    fi
    if [[ "$release_name" == "latest" || -z "$release_name" ]]; then
      release_name="$detected_version"
    fi
  fi

  install_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  state_installed_version="$resolved_version"
  state_release_tag="$release_tag"
  state_release_name="$release_name"
  state_asset_name="$asset_name"
  state_binary_path="$binary_path"
  state_controller_path="$controller_path"
  state_node_setup_choice="$NODE_SETUP_CHOICE"
  state_installed_at="$install_time"
  persist_release_state_snapshot "$state_file"

  sync_runtime_wrappers_from_state "$state_file" "$COMMAND_DIR" "$controller_path"
  update_path_if_needed
  persist_release_state_snapshot "$state_file"

  log_step "Install complete: $binary_path"
  "$binary_path" --version

  case "$PATH_UPDATE_MODE" in
    added)
      log_info "PATH updated (written): $PATH_PROFILE"
      ;;
    configured)
      log_info "PATH refreshed: $PATH_PROFILE"
      ;;
    user-skipped | disabled)
      log_warn "Command dir not added to PATH; add manually: $COMMAND_DIR"
      ;;
    already)
      log_info "Command dir already in PATH: $COMMAND_DIR"
      ;;
  esac

  log_info "Next: run 'hodex --version' to verify the install"
  log_info "Management: 'hodexctl status' / 'hodexctl list'"

  rm -rf "$tmp_dir"
}

perform_manager_install() {
  local state_file="$STATE_DIR/state.json"
  local had_existing_state=0
  local install_time
  local controller_path
  local state_installed_version state_release_tag state_release_name state_asset_name state_binary_path state_controller_path state_node_setup_choice state_installed_at

  if [[ -f "$state_file" ]]; then
    load_state_env "$state_file"
    had_existing_state=1
  fi

  log_step "Install hodexctl manager"
  select_command_dir

  controller_path="$STATE_DIR/libexec/hodexctl.sh"
  ensure_dir_writable "$(dirname "$controller_path")"
  sync_controller_copy "$controller_path"

  if ((had_existing_state)); then
    remove_old_wrappers_if_needed "$COMMAND_DIR"
  fi

  install_time="${STATE_INSTALLED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  state_installed_version="$STATE_INSTALLED_VERSION"
  state_release_tag="$STATE_RELEASE_TAG"
  state_release_name="$STATE_RELEASE_NAME"
  state_asset_name="$STATE_ASSET_NAME"
  state_binary_path="$STATE_BINARY_PATH"
  state_controller_path="$controller_path"
  state_node_setup_choice="$STATE_NODE_SETUP_CHOICE"
  state_installed_at="$install_time"
  persist_release_state_snapshot "$state_file"

  sync_runtime_wrappers_from_state "$state_file" "$COMMAND_DIR" "$controller_path"
  update_path_if_needed
  persist_release_state_snapshot "$state_file"

  log_step "hodexctl installed: $COMMAND_DIR/hodexctl"
  log_info "State dir: $STATE_DIR"
  log_info "Command dir: $COMMAND_DIR"
  log_info "Only the manager is installed; run: hodexctl install"

  case "$PATH_UPDATE_MODE" in
    added)
      log_info "PATH updated (written): $PATH_PROFILE"
      ;;
    configured)
      log_info "PATH refreshed: $PATH_PROFILE"
      ;;
    already)
      log_info "Command dir already in PATH: $COMMAND_DIR"
      ;;
    disabled | user-skipped)
      log_warn "Command dir not added to PATH; add manually: $COMMAND_DIR"
      ;;
  esac

  if [[ "$PATH_UPDATE_MODE" == "added" || "$PATH_UPDATE_MODE" == "configured" ]]; then
    log_info "If the current shell still does not see hodexctl, reopen it or run: source \"$PATH_PROFILE\""
  fi
  log_info "Next: run 'hodexctl' for help"
  log_info "Install release: 'hodexctl install'"
  log_info "List versions: 'hodexctl list'"
  log_info "Download source and prepare toolchain: 'hodexctl source install --repo stellarlinkco/codex --ref main'"
}

perform_uninstall() {
  local state_file="$STATE_DIR/state.json"
  [[ -f "$state_file" ]] || die "No hodex installation detected; nothing to uninstall."

  if [[ -z "$(json_get_field "$state_file" "binary_path")" ]]; then
    if [[ "$(state_count_source_profiles "$state_file")" != "0" ]]; then
      die "No release install found; to remove source profiles use: hodexctl source uninstall."
    fi

    load_state_env "$state_file"
    log_step "Uninstall hodexctl manager"
    cleanup_path_blocks_for_uninstall "$(select_profile_file)"
    rm -f "$STATE_COMMAND_DIR/hodexctl" 2>/dev/null || true
    rm -f "$STATE_CONTROLLER_PATH" 2>/dev/null || true
    rm -f "$state_file" 2>/dev/null || true
    rm -f "$STATE_DIR/list-ui-state.json" 2>/dev/null || true
    rmdir "$STATE_COMMAND_DIR" 2>/dev/null || true
    rmdir "$STATE_DIR/libexec" 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    log_info "hodexctl manager uninstalled."
    return
  fi

  load_state_env "$state_file"

  log_step "Uninstall Hodex release"
  rm -f "$STATE_BINARY_PATH"
  remove_managed_runtime_wrappers_from_dir "$STATE_COMMAND_DIR" "$state_file"
  clear_release_state_file "$state_file"
  sync_runtime_wrappers_from_state "$state_file" "$STATE_COMMAND_DIR" "$STATE_CONTROLLER_PATH"

  if [[ "$(state_count_source_profiles "$state_file")" == "0" ]]; then
    cleanup_path_blocks_for_uninstall "$(select_profile_file)"
  fi

  if [[ "$(state_count_source_profiles "$state_file")" == "0" ]]; then
    rm -f "$STATE_CONTROLLER_PATH"
    rm -f "$state_file"
    rm -f "$STATE_DIR/list-ui-state.json"
    rm -f "$STATE_COMMAND_DIR/hodexctl" 2>/dev/null || true
    rmdir "$STATE_COMMAND_DIR" 2>/dev/null || true
    rmdir "$STATE_DIR/libexec" 2>/dev/null || true
    rmdir "$STATE_DIR/bin" 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    log_info "Removed release binary, wrappers, and install state."
  else
    log_info "Removed release binary; source profiles and manager script kept."
  fi
}

perform_status() {
  local state_file="$STATE_DIR/state.json"
  local repair_needed=0

  printf 'Platform: %s\n' "$PLATFORM_LABEL"
  printf 'State dir: %s\n' "$STATE_DIR"
  if ((IS_WSL)); then
    printf 'WSL: yes\n'
  else
    printf 'WSL: no\n'
  fi

  if [[ -f "$state_file" ]]; then
    load_state_env "$state_file"
    if [[ -n "$STATE_BINARY_PATH" ]]; then
      printf 'Release install status: installed\n'
      printf 'Version: %s\n' "$STATE_INSTALLED_VERSION"
      printf 'Release: %s (%s)\n' "$STATE_RELEASE_NAME" "$STATE_RELEASE_TAG"
      printf 'Asset: %s\n' "$STATE_ASSET_NAME"
      printf 'Binary: %s\n' "$STATE_BINARY_PATH"
    else
      printf 'Release install status: not installed\n'
      if [[ -n "$STATE_CONTROLLER_PATH" && -f "$STATE_CONTROLLER_PATH" ]]; then
        printf 'Manager status: installed\n'
        printf 'Hint: run hodexctl install to install release\n'
      fi
    fi
    printf 'Command dir: %s\n' "$STATE_COMMAND_DIR"
    printf 'Manager script copy: %s\n' "$STATE_CONTROLLER_PATH"
    printf 'PATH update mode: %s\n' "$STATE_PATH_UPDATE_MODE"
    printf 'PATH managed by hodexctl: %s\n' "$STATE_PATH_MANAGED_BY_HODEXCTL"
    printf 'PATH source: %s\n' "${STATE_PATH_DETECTED_SOURCE:-<unknown>}"
    if [[ -n "$STATE_PATH_PROFILE" ]]; then
      printf 'PATH profile: %s\n' "$STATE_PATH_PROFILE"
    fi
    printf 'Node setup choice: %s\n' "$STATE_NODE_SETUP_CHOICE"
    printf 'Installed at: %s\n' "$STATE_INSTALLED_AT"
    if [[ -x "$STATE_COMMAND_DIR/hodex" ]]; then
      printf 'hodex wrapper: %s\n' "$STATE_COMMAND_DIR/hodex"
    fi
    if [[ -x "$STATE_COMMAND_DIR/hodexctl" ]]; then
      printf 'hodexctl wrapper: %s\n' "$STATE_COMMAND_DIR/hodexctl"
    fi
    local active_alias
    active_alias="$(state_get_active_hodex_alias "$state_file")"
    printf 'Managed hodex target: %s\n' "${active_alias:-<unset>}"
    printf 'Source profiles: %s\n' "$(state_count_source_profiles "$state_file")"
    while IFS=$'\t' read -r profile_name repo_input remote_url checkout_dir workspace_mode current_ref ref_kind build_workspace_root binary_path wrapper_path installed_at last_synced_at _; do
      [[ -n "$profile_name" ]] || continue
      printf 'Source profile: %s | %s | %s | source-only management\n' "$profile_name" "${repo_input:-<unknown>}" "${current_ref:-<unknown>}"
    done < <(state_emit_source_profiles "$state_file")

    if [[ -n "$STATE_CONTROLLER_PATH" && ! -f "$STATE_CONTROLLER_PATH" ]]; then
      printf 'Diagnostics: manager script copy missing\n'
      repair_needed=1
    fi
    if [[ -n "$STATE_COMMAND_DIR" && ! -x "$STATE_COMMAND_DIR/hodexctl" ]]; then
      printf 'Diagnostics: hodexctl wrapper missing\n'
      repair_needed=1
    fi
    if [[ -n "$STATE_BINARY_PATH" && ! -f "$STATE_BINARY_PATH" ]]; then
      printf 'Diagnostics: hodex release binary missing\n'
      repair_needed=1
    fi
    if [[ -n "$STATE_BINARY_PATH" && -f "$STATE_BINARY_PATH" && -n "$STATE_COMMAND_DIR" && ! -x "$STATE_COMMAND_DIR/hodex" ]]; then
      printf 'Diagnostics: hodex wrapper missing\n'
      repair_needed=1
    fi
    if [[ "$STATE_PATH_DETECTED_SOURCE" == "current-process-only" ]]; then
      printf 'Diagnostics: PATH is only visible in this shell; new shells may not work\n'
      repair_needed=1
    fi
  else
    printf 'Release install status: not installed\n'
    printf 'Source profiles: 0\n'
  fi

  if command_exists hodex; then
    printf 'hodex in PATH: %s\n' "$(command -v hodex)"
  else
    printf 'hodex in PATH: not found\n'
    if [[ -f "$state_file" && -n "$STATE_BINARY_PATH" ]]; then
      repair_needed=1
    fi
  fi

  if command_exists codex; then
    printf 'codex in PATH: %s\n' "$(command -v codex)"
  else
    printf 'codex in PATH: not found\n'
  fi

  if command_exists node; then
    printf 'Node.js: %s\n' "$(node -v 2>/dev/null || printf 'installed')"
  else
    printf 'Node.js: not installed\n'
  fi

  if ((repair_needed)); then
    printf 'Recommended: run hodexctl repair\n'
  fi
}

perform_relink() {
  local state_file="$STATE_DIR/state.json"
  [[ -f "$state_file" ]] || die "No hodex install state found; cannot relink."

  load_state_env "$state_file"

  if [[ -z "$COMMAND_DIR" ]]; then
    COMMAND_DIR="$STATE_COMMAND_DIR"
  else
    ensure_dir_writable "$COMMAND_DIR"
  fi

  remove_old_wrappers_if_needed "$COMMAND_DIR"
  sync_controller_copy "$STATE_CONTROLLER_PATH"
  sync_runtime_wrappers_from_state "$state_file" "$COMMAND_DIR" "$STATE_CONTROLLER_PATH"
  update_path_if_needed
  write_state_file \
    "$state_file" \
    "$STATE_INSTALLED_VERSION" \
    "$STATE_RELEASE_TAG" \
    "$STATE_RELEASE_NAME" \
    "$STATE_ASSET_NAME" \
    "$STATE_BINARY_PATH" \
    "$STATE_CONTROLLER_PATH" \
    "$COMMAND_DIR" \
    "$COMMAND_DIR/hodex" \
    "$COMMAND_DIR/hodexctl" \
    "$PATH_UPDATE_MODE" \
    "$PATH_PROFILE" \
    "$PATH_MANAGED_BY_HODEXCTL" \
    "$PATH_DETECTED_SOURCE" \
    "$STATE_NODE_SETUP_CHOICE" \
    "$STATE_INSTALLED_AT"
  log_info "Rebuilt release and manager wrappers in: $COMMAND_DIR"
}

perform_repair() {
  local state_file="$STATE_DIR/state.json"
  [[ -f "$state_file" ]] || die "No hodex install state found; cannot repair."

  log_step "Repair hodexctl local state"
  perform_relink

  load_state_env "$state_file"
  if [[ -n "$STATE_BINARY_PATH" && ! -f "$STATE_BINARY_PATH" ]]; then
    log_warn "Release binary missing; manager script, wrappers, and PATH were repaired, but the binary cannot be restored offline."
    log_info "Next: run 'hodexctl install' or 'hodexctl upgrade <version>' to restore the release."
    return
  fi

  log_info "Repair completed."
}

main() {
  if [[ -t 1 ]]; then
    ORIGINAL_STDOUT_IS_TTY=1
  else
    ORIGINAL_STDOUT_IS_TTY=0
  fi
  parse_args "$@"
  ensure_local_tool_paths
  TEE_COMMAND="$(find_command_path tee || true)"
  require_base_commands
  detect_platform
  init_color_theme
  init_json_backend_if_available

  case "$COMMAND" in
    install)
      perform_install_like "$REQUESTED_VERSION" "Install"
      ;;
    upgrade)
      perform_install_like "$REQUESTED_VERSION" "Upgrade"
      ;;
    download)
      perform_download "$REQUESTED_VERSION"
      ;;
    downgrade)
      perform_install_like "$REQUESTED_VERSION" "Downgrade"
      ;;
    source)
      if [[ "$SOURCE_ACTION" != "help" ]]; then
        require_json_backend "source mode"
      fi
      case "$SOURCE_ACTION" in
        install) perform_source_install ;;
        update) perform_source_update ;;
        rebuild) perform_source_rebuild ;;
        switch) perform_source_switch ;;
        status) perform_source_status ;;
        uninstall) perform_source_uninstall ;;
        list) perform_source_list ;;
        help) source_usage ;;
      esac
      ;;
    uninstall)
      perform_uninstall
      ;;
    status)
      perform_status
      ;;
    list)
      perform_list
      ;;
    relink)
      perform_relink
      ;;
    repair)
      perform_repair
      ;;
    manager-install)
      perform_manager_install
      ;;
    *)
      die "Unknown command: $COMMAND"
      ;;
  esac
}

if [[ "${HODEXCTL_SKIP_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
