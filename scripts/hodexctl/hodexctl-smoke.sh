#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER_PATH="$SCRIPT_DIR/hodexctl.sh"
INSTALLER_PATH="$SCRIPT_DIR/../install-hodexctl.sh"

log_step() {
  printf '==> %s\n' "$1"
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

stop_background_process() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
}

assert_contains() {
  local file_path="$1"
  local expected="$2"
  grep -F -- "$expected" "$file_path" >/dev/null 2>&1 || die "Expected content not found in ${file_path}: ${expected}"
}

assert_not_contains() {
  local file_path="$1"
  local unexpected="$2"
  if grep -F -- "$unexpected" "$file_path" >/dev/null 2>&1; then
    die "Should not appear in ${file_path}: ${unexpected}"
  fi
}

assert_not_exists() {
  local file_path="$1"
  [[ ! -e "$file_path" ]] || die "Should not exist: ${file_path}"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
original_home="$HOME"

help_output="$tmp_dir/help.txt"
source_help_output="$tmp_dir/source-help.txt"
source_install_help_output="$tmp_dir/source-install-help.txt"
list_help_output="$tmp_dir/list-help.txt"
status_output="$tmp_dir/status.txt"
source_status_output="$tmp_dir/source-status.txt"
source_list_output="$tmp_dir/source-list.txt"
list_output="$tmp_dir/list.txt"
release_summary_output="$tmp_dir/release-summary.txt"
release_summary_args="$tmp_dir/release-summary-args.txt"
release_summary_prompt="$tmp_dir/release-summary-prompt.txt"
release_summary_fallback_output="$tmp_dir/release-summary-fallback.txt"
release_summary_fallback_args="$tmp_dir/release-summary-fallback-args.txt"
choice_stdout="$tmp_dir/choice-stdout.txt"
choice_stderr="$tmp_dir/choice-stderr.txt"
nojson_status_output="$tmp_dir/nojson-status.txt"
activate_error_output="$tmp_dir/activate-error.txt"
release_install_output="$tmp_dir/release-install.txt"
release_uninstall_output="$tmp_dir/release-uninstall.txt"
path_fix_install_output="$tmp_dir/path-fix-install.txt"
repair_install_output="$tmp_dir/repair-install.txt"
repair_status_output="$tmp_dir/repair-status.txt"
repair_output="$tmp_dir/repair-output.txt"
installer_output="$tmp_dir/installer-output.txt"
installer_no_path_output="$tmp_dir/installer-no-path-output.txt"
download_summary_output="$tmp_dir/download-summary.txt"
gh_fallback_output="$tmp_dir/gh-fallback.txt"
gh_missing_output="$tmp_dir/gh-missing.txt"
gh_auth_output="$tmp_dir/gh-auth.txt"
source_install_output="$tmp_dir/source-install.txt"
source_status_after_install_output="$tmp_dir/source-status-after-install.txt"
source_update_output="$tmp_dir/source-update.txt"
source_rebuild_output="$tmp_dir/source-rebuild.txt"
source_ref_candidates_output="$tmp_dir/source-ref-candidates.txt"
path_targets_output="$tmp_dir/path-targets.txt"
source_uninstall_output="$tmp_dir/source-uninstall.txt"
state_dir="$tmp_dir/state"
command_dir="$tmp_dir/commands"
release_state_dir="$tmp_dir/release-state"
release_command_dir="$tmp_dir/release-commands"
path_fix_home_dir="$tmp_dir/path-fix-home"
path_fix_state_dir="$tmp_dir/path-fix-state"
path_fix_command_dir="$tmp_dir/path-fix-command"
repair_home_dir="$tmp_dir/repair-home"
repair_state_dir="$tmp_dir/repair-state"
repair_command_dir="$tmp_dir/repair-command"
source_checkout_dir="$tmp_dir/source-checkout"
source_repo_dir="$tmp_dir/source-repo"
source_home_dir="$tmp_dir/source-home"
source_profile_file="$source_home_dir/.zshrc"
source_bin="$tmp_dir/source-bin"
release_server_root="$tmp_dir/release-server"
release_server_pid=""
ghbin="$tmp_dir/gh-bin"

log_step "Check Bash syntax"
bash -n "$CONTROLLER_PATH"

log_step "Check help output with no args"
"$CONTROLLER_PATH" >"$help_output"
assert_contains "$help_output" "Usage:"
assert_contains "$help_output" "hodexctl list"
assert_contains "$help_output" "./hodexctl.sh install"

log_step "Check source mode help output"
"$CONTROLLER_PATH" source help >"$source_help_output"
assert_contains "$source_help_output" "Source mode usage:"
assert_contains "$source_help_output" "install                Download source and prepare toolchain (does not take over hodex)"
assert_contains "$source_help_output" "Source profile name (default: codex-source)"

log_step "Check source/list help semantics"
"$CONTROLLER_PATH" source install --help >"$source_install_help_output"
"$CONTROLLER_PATH" list --help >"$list_help_output"
assert_contains "$source_install_help_output" "Source mode usage:"
assert_contains "$list_help_output" "Release list usage:"
assert_contains "$list_help_output" "Changelog view:"

log_step "Check zsh PATH target selection"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" HOME="$tmp_dir/home-path-test" SHELL="/bin/zsh" \
bash -lc '
  set -euo pipefail
  mkdir -p "$HOME"
  export HODEXCTL_SKIP_MAIN=1
  source "$CONTROLLER_PATH_ENV"
  path_profile_targets "$(select_profile_file)"
' >"$path_targets_output"
assert_contains "$path_targets_output" "$tmp_dir/home-path-test/.zprofile"
assert_contains "$path_targets_output" "$tmp_dir/home-path-test/.zshrc"

current_platform_asset="$(
  CONTROLLER_PATH_ENV="$CONTROLLER_PATH" bash -lc '
    set -euo pipefail
    export HODEXCTL_SKIP_MAIN=1
    source "$CONTROLLER_PATH_ENV"
    detect_platform
    get_asset_candidates | head -n 1
  '
)"
[[ -n "$current_platform_asset" ]] || die "Failed to parse current platform release asset name"

log_step "Check WSL detection helper"
printf 'Linux version 6.6.0-microsoft-standard-WSL2\n' >"$tmp_dir/proc-version-wsl"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" HODEXCTL_TEST_PROC_VERSION_FILE="$tmp_dir/proc-version-wsl" \
bash -lc '
  set -euo pipefail
  export HODEXCTL_SKIP_MAIN=1
  source "$CONTROLLER_PATH_ENV"
  if is_wsl_platform; then
    printf "WSL\n"
  else
    printf "NOPE\n"
  fi
' >"$tmp_dir/wsl-detect.txt"
assert_contains "$tmp_dir/wsl-detect.txt" "WSL"

log_step "Check Linux asset candidate order prefers gnu before musl"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" \
bash -lc '
  set -euo pipefail
  export HODEXCTL_SKIP_MAIN=1
  source "$CONTROLLER_PATH_ENV"
  OS_NAME="linux"
  ARCH_NAME="x86_64"
  get_asset_candidates
' >"$tmp_dir/linux-candidates.txt"
if [[ "$(head -n 1 "$tmp_dir/linux-candidates.txt")" != "codex-x86_64-unknown-linux-gnu" ]]; then
  die "Expected gnu asset candidate to be preferred first on Linux"
fi
assert_contains "$tmp_dir/linux-candidates.txt" "codex-x86_64-unknown-linux-musl"
assert_contains "$tmp_dir/linux-candidates.txt" "codex-x86_64-unknown-linux-gnu"

log_step "Check status output when not installed"
"$CONTROLLER_PATH" status --state-dir "$state_dir" >"$status_output"
assert_contains "$status_output" "Release install status: not installed"
assert_contains "$status_output" "State dir: $state_dir"

log_step "Check manager-install wrapper keeps custom state dir"
manager_state_dir="$tmp_dir/manager-state"
manager_home_dir="$tmp_dir/manager-home"
manager_status_output="$tmp_dir/manager-status.txt"
HOME="$manager_home_dir" "$CONTROLLER_PATH" manager-install --state-dir "$manager_state_dir" --yes --no-path-update >"$tmp_dir/manager-install.txt"
unset HODEX_STATE_DIR HODEXCTL_REPO HODEX_CONTROLLER_URL_BASE || true
"$manager_state_dir/commands/hodexctl" status >"$manager_status_output"
assert_contains "$manager_status_output" "State dir: $manager_state_dir"

log_step "Check one-liner installer output (zsh)"
installer_repo="smoke-repo"
installer_mirror_root="$tmp_dir/installer-mirror"
installer_home_dir="$tmp_dir/installer-home"
installer_state_dir="$tmp_dir/installer-state"
mkdir -p "$installer_mirror_root/$installer_repo/main/scripts/hodexctl"
cp "$CONTROLLER_PATH" "$installer_mirror_root/$installer_repo/main/scripts/hodexctl/hodexctl.sh"
chmod +x "$installer_mirror_root/$installer_repo/main/scripts/hodexctl/hodexctl.sh"
mkdir -p "$installer_home_dir"
touch "$installer_home_dir/.zshrc"
HOME="$installer_home_dir" SHELL="/bin/zsh" HODEX_CONTROLLER_URL_BASE="file://$installer_mirror_root" \
  HODEXCTL_REPO="$installer_repo" HODEX_STATE_DIR="$installer_state_dir" \
  bash "$INSTALLER_PATH" >"$installer_output" 2>&1
assert_contains "$installer_output" "==> Install complete"
assert_contains "$installer_output" "$installer_state_dir/commands/hodexctl status"
assert_contains "$installer_output" "source \"$installer_home_dir/.zshrc\""

log_step "Check installer skip PATH update doesn't print source"
installer_state_dir_no_path="$tmp_dir/installer-state-no-path"
HOME="$installer_home_dir" SHELL="/bin/zsh" HODEXCTL_NO_PATH_UPDATE=1 HODEX_CONTROLLER_URL_BASE="file://$installer_mirror_root" \
  HODEXCTL_REPO="$installer_repo" HODEX_STATE_DIR="$installer_state_dir_no_path" \
  bash "$INSTALLER_PATH" >"$installer_no_path_output" 2>&1
assert_contains "$installer_no_path_output" "==> Install complete"
assert_contains "$installer_no_path_output" "$installer_state_dir_no_path/commands/hodexctl status"
assert_not_contains "$installer_no_path_output" "source \""

log_step "Check installer download failure stays concise"
missing_installer_root="$tmp_dir/missing-installer-root"
HOME="$installer_home_dir" SHELL="/bin/zsh" HODEX_CONTROLLER_URL_BASE="file://$missing_installer_root" \
  HODEXCTL_REPO="$installer_repo" HODEX_STATE_DIR="$tmp_dir/installer-state-missing" \
  bash "$INSTALLER_PATH" >"$tmp_dir/installer-failure-stdout.txt" 2>"$tmp_dir/installer-failure-stderr.txt" && die "Installer should fail when controller download is unavailable"
assert_contains "$tmp_dir/installer-failure-stdout.txt" "==> Download hodexctl manager script"
assert_contains "$tmp_dir/installer-failure-stderr.txt" "Failed to download hodexctl manager script"
if [[ "$(wc -l <"$tmp_dir/installer-failure-stderr.txt")" -ne 1 ]]; then
  die "Installer download failure should stay on a single stderr line"
fi

log_step "Check legacy state.json uninstall still clears PATH block"
legacy_home_dir="$tmp_dir/legacy-home"
legacy_state_dir="$tmp_dir/legacy-state"
legacy_command_dir="$legacy_state_dir/commands"
legacy_controller_path="$legacy_state_dir/libexec/hodexctl.sh"
mkdir -p "$legacy_home_dir" "$legacy_command_dir" "$(dirname "$legacy_controller_path")"
legacy_profile_file="$legacy_home_dir/.zshrc"
{
  printf 'export HODEX_SMOKE_SENTINEL=1\n'
  printf '%s\n' "# >>> hodexctl >>>"
  printf 'export PATH="%s:$PATH"\n' "$legacy_command_dir"
  printf '%s\n' "# <<< hodexctl <<<"
  printf 'export HODEX_SMOKE_SENTINEL_END=1\n'
} >"$legacy_profile_file"
touch "$legacy_command_dir/hodexctl"
touch "$legacy_controller_path"
cat >"$legacy_state_dir/state.json" <<JSON
{
  "schema_version": 2,
  "repo": "stellarlinkco/codex",
  "installed_version": "",
  "release_tag": "",
  "release_name": "",
  "asset_name": "",
  "binary_path": "",
  "controller_path": "$legacy_controller_path",
  "command_dir": "$legacy_command_dir",
  "wrappers_created": [],
  "path_update_mode": "added",
  "path_profile": "$legacy_profile_file",
  "node_setup_choice": "",
  "installed_at": "2026-03-09T00:00:00Z",
  "source_profiles": {},
  "active_runtime_aliases": {}
}
JSON
HOME="$legacy_home_dir" SHELL="/bin/zsh" "$CONTROLLER_PATH" uninstall --state-dir "$legacy_state_dir" >"$tmp_dir/legacy-uninstall.txt" 2>&1
assert_contains "$legacy_profile_file" "export HODEX_SMOKE_SENTINEL=1"
assert_contains "$legacy_profile_file" "export HODEX_SMOKE_SENTINEL_END=1"
assert_not_contains "$legacy_profile_file" "# >>> hodexctl >>>"

log_step "Check empty source status output"
"$CONTROLLER_PATH" source status --state-dir "$state_dir" >"$source_status_output"
"$CONTROLLER_PATH" source list --state-dir "$state_dir" >"$source_list_output"
assert_contains "$source_status_output" "No source profiles installed"
assert_contains "$source_list_output" "No source profiles recorded"

log_step "Check list top source entry"
listbin="$tmp_dir/list-bin"
mkdir -p "$listbin"
for cmd in bash basename dirname mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$listbin/$cmd"
  fi
done
cat >"$listbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
write_format=""
url=""
while (($# > 0)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -w)
      write_format="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output" || -z "$url" ]]; then
  exit 1
fi

case "$url" in
  *"/releases?per_page=100&page=1")
    cat >"$output" <<JSON
[
  {
    "tag_name": "v9.9.9",
    "name": "9.9.9",
    "published_at": "2026-03-08T00:00:00Z",
    "html_url": "https://example.invalid/releases/v9.9.9",
    "body": "smoke",
    "assets": [
      {
        "name": "${CURRENT_PLATFORM_ASSET}",
        "browser_download_url": "https://example.invalid/download/${CURRENT_PLATFORM_ASSET}",
        "digest": ""
      }
    ]
  }
]
JSON
    ;;
  *"/releases?per_page=100&page="*)
    printf '[]\n' >"$output"
    ;;
  *)
    exit 1
    ;;
esac

if [[ "$write_format" == *"%{http_code}"* ]]; then
  printf '200'
fi
EOF
chmod +x "$listbin/curl"
PATH="$listbin" CURRENT_PLATFORM_ASSET="$current_platform_asset" "$CONTROLLER_PATH" list --state-dir "$state_dir" >"$list_output"
assert_contains "$list_output" "0. Source mode"

log_step "Check Bash download summary"
downloadbin="$tmp_dir/download-bin"
mkdir -p "$downloadbin"
for cmd in bash basename dirname mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$downloadbin/$cmd"
  fi
done
cat >"$downloadbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
write_out=""
range_mode=0
while (($# > 0)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    --range)
      range_mode=1
      shift 2
      ;;
    --progress-bar|-fL|-sS|--fail|-L)
      shift
      ;;
    http*)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if ((range_mode)); then
  exit 0
fi
[[ -n "$output" ]] || exit 0
printf 'fake-binary' >"$output"
if [[ -n "$write_out" ]]; then
  printf '1048576\t524288\t2.0\n'
fi
EOF
chmod +x "$downloadbin/curl"
PATH="$downloadbin" HODEX_RELEASE_BASE_URL="https://example.invalid/releases" "$CONTROLLER_PATH" download latest --download-dir "$tmp_dir/downloads" >"$download_summary_output"
assert_contains "$download_summary_output" "Download complete:"
assert_contains "$download_summary_output" "avg"

log_step "Check choice prompt does not pollute return value"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" \
bash -lc '
  set -euo pipefail
  export HODEXCTL_SKIP_MAIN=1
  source "$CONTROLLER_PATH_ENV"
  reset_choice_candidates
  append_choice_candidate "alpha"
  append_choice_candidate "beta"
  printf "2\n" | prompt_value_with_choice_candidates "Test field" "default" "Test note"
' >"$choice_stdout" 2>"$choice_stderr"
assert_contains "$choice_stdout" "beta"
assert_contains "$choice_stderr" "Test field"
assert_contains "$choice_stderr" "Candidates:"

log_step "Check release changelog summary prefers hodex"
summary_bin="$tmp_dir/summary-bin"
mkdir -p "$summary_bin"
cat >"$summary_bin/hodex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  exit 0
fi
printf '%s\n' "$*" >"$TRACE_ARGS_FILE"
cat >"$TRACE_PROMPT_FILE"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"This is the hodex summary result"}}'
EOF
chmod +x "$summary_bin/hodex"
cat >"$summary_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "codex should not be called" >&2
exit 1
EOF
chmod +x "$summary_bin/codex"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" \
TRACE_ARGS_FILE="$release_summary_args" \
TRACE_PROMPT_FILE="$release_summary_prompt" \
SUMMARY_OUTPUT_FILE="$release_summary_output" \
SUMMARY_BIN_DIR="$summary_bin" \
CURRENT_PLATFORM_ASSET="$current_platform_asset" \
bash -lc '
  set -euo pipefail
  export HODEXCTL_SKIP_MAIN=1
  export PATH="$SUMMARY_BIN_DIR:$PATH"
  source "$CONTROLLER_PATH_ENV"
  detect_platform
  init_color_theme
  init_json_backend_if_available
  release_file="$(mktemp)"
  cat >"$release_file" <<JSON
{
  "tag_name": "v1.2.3",
  "name": "1.2.3",
  "published_at": "2026-03-09T00:00:00Z",
  "html_url": "https://example.invalid/releases/v1.2.3",
  "body": "- add feature A\n- fix bug B",
  "assets": [
    {
      "name": "${CURRENT_PLATFORM_ASSET}",
      "browser_download_url": "https://example.invalid/download/${CURRENT_PLATFORM_ASSET}",
      "digest": ""
    }
  ]
}
JSON
  summarize_release_changelog "$release_file" "1.2.3" >"$SUMMARY_OUTPUT_FILE" 2>&1
'
assert_contains "$release_summary_output" "This is the hodex summary result"
assert_contains "$release_summary_args" "exec --skip-git-repo-check --color never --json -"
assert_contains "$release_summary_prompt" "Version: 1.2.3"
assert_contains "$release_summary_prompt" "Full changelog:"
assert_contains "$release_summary_prompt" "New features"
assert_contains "$release_summary_prompt" "Improvements"
assert_contains "$release_summary_prompt" "Fixes"
assert_contains "$release_summary_prompt" "Breaking changes / migration"
assert_contains "$release_summary_prompt" "- add feature A"

log_step "Check release changelog summary falls back to codex"
fallback_bin="$tmp_dir/summary-fallback-bin"
mkdir -p "$fallback_bin"
cat >"$fallback_bin/hodex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  exit 1
fi
exit 1
EOF
chmod +x "$fallback_bin/hodex"
cat >"$fallback_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  exit 0
fi
printf '%s\n' "$*" >"$TRACE_ARGS_FILE"
cat >/dev/null
printf '%s\n' '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"This is the codex fallback summary"}}'
EOF
chmod +x "$fallback_bin/codex"
CONTROLLER_PATH_ENV="$CONTROLLER_PATH" \
TRACE_ARGS_FILE="$release_summary_fallback_args" \
SUMMARY_OUTPUT_FILE="$release_summary_fallback_output" \
SUMMARY_BIN_DIR="$fallback_bin" \
CURRENT_PLATFORM_ASSET="$current_platform_asset" \
bash -lc '
  set -euo pipefail
  export HODEXCTL_SKIP_MAIN=1
  export PATH="$SUMMARY_BIN_DIR:$PATH"
  source "$CONTROLLER_PATH_ENV"
  detect_platform
  init_color_theme
  init_json_backend_if_available
  release_file="$(mktemp)"
  cat >"$release_file" <<JSON
{
  "tag_name": "v2.0.0",
  "name": "2.0.0",
  "published_at": "2026-03-09T00:00:00Z",
  "html_url": "https://example.invalid/releases/v2.0.0",
  "body": "fallback smoke",
  "assets": [
    {
      "name": "${CURRENT_PLATFORM_ASSET}",
      "browser_download_url": "https://example.invalid/download/${CURRENT_PLATFORM_ASSET}",
      "digest": ""
    }
  ]
}
JSON
  summarize_release_changelog "$release_file" "2.0.0" >"$SUMMARY_OUTPUT_FILE" 2>&1
'
assert_contains "$release_summary_fallback_output" "This is the codex fallback summary"
assert_contains "$release_summary_fallback_output" "Preferred command unavailable; switched to codex."
assert_contains "$release_summary_fallback_args" "exec --skip-git-repo-check --color never --json -"

log_step "Check gh fallback on GitHub API 403"
mkdir -p "$ghbin"
for cmd in bash basename dirname mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$ghbin/$cmd"
  fi
done
cat >"$ghbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
write_format=""
while (($# > 0)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"message":"rate limited"}\n' >"$output"
if [[ "$write_format" == *"%{http_code}"* ]]; then
  printf '403'
fi
EOF
chmod +x "$ghbin/curl"
cat >"$ghbin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
  cat <<JSON
[
  {
    "tag_name": "v9.9.8",
    "name": "9.9.8",
    "published_at": "2026-03-07T00:00:00Z",
    "html_url": "https://example.invalid/releases/v9.9.8",
    "body": "gh fallback",
    "assets": [
      {
        "name": "${CURRENT_PLATFORM_ASSET}",
        "browser_download_url": "https://example.invalid/download/${CURRENT_PLATFORM_ASSET}",
        "digest": ""
      }
    ]
  }
]
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$ghbin/gh"
PATH="$ghbin" CURRENT_PLATFORM_ASSET="$current_platform_asset" "$CONTROLLER_PATH" list --state-dir "$state_dir" >"$gh_fallback_output"
assert_contains "$gh_fallback_output" "0. Source mode"
assert_contains "$gh_fallback_output" "Automatically switched to gh api for GitHub data."

log_step "Check message when GitHub API 403 and gh is missing"
mkdir -p "$tmp_dir/gh-missing-bin"
for cmd in bash basename dirname mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$tmp_dir/gh-missing-bin/$cmd"
  fi
done
cat >"$tmp_dir/gh-missing-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
write_format=""
while (($# > 0)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"message":"rate limited"}\n' >"$output"
if [[ "$write_format" == *"%{http_code}"* ]]; then
  printf '403'
fi
EOF
chmod +x "$tmp_dir/gh-missing-bin/curl"
if PATH="$tmp_dir/gh-missing-bin" "$CONTROLLER_PATH" list --state-dir "$state_dir" >"$gh_missing_output" 2>&1; then
  die "403 scenario should not succeed when gh is missing"
fi
assert_contains "$gh_missing_output" "gh is not available"

log_step "Check message when GitHub API 403 and gh is not authenticated"
mkdir -p "$tmp_dir/gh-auth-bin"
for cmd in bash basename dirname mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less python3 jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$tmp_dir/gh-auth-bin/$cmd"
  fi
done
cp "$tmp_dir/gh-missing-bin/curl" "$tmp_dir/gh-auth-bin/curl"
cat >"$tmp_dir/gh-auth-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "not logged in to any hosts" >&2
exit 1
EOF
chmod +x "$tmp_dir/gh-auth-bin/gh"
if PATH="$tmp_dir/gh-auth-bin" "$CONTROLLER_PATH" list --state-dir "$state_dir" >"$gh_auth_output" 2>&1; then
  die "403 scenario should not succeed when gh is not authenticated"
fi
assert_contains "$gh_auth_output" "gh is not authenticated"
assert_contains "$gh_auth_output" "gh auth login"

log_step "Check release-only status output without python3/jq"
tmpbin="$tmp_dir/minimal-bin"
mkdir -p "$tmpbin"
for cmd in bash basename dirname curl mktemp chmod mkdir cp install awk grep date sleep uname sed head wc tr cat rm mv tput shasum sha256sum openssl git perl less; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$tmpbin/$cmd"
  fi
done
PATH="$tmpbin" "$CONTROLLER_PATH" status --state-dir "$state_dir" >"$nojson_status_output"
assert_contains "$nojson_status_output" "Release install status: not installed"

log_step "Check source mode refuses to take over hodex"
if "$CONTROLLER_PATH" source install --activate --state-dir "$state_dir" >"$activate_error_output" 2>&1; then
  die "Source mode should not accept --activate"
fi
assert_contains "$activate_error_output" "Source mode will not take over hodex"

log_step "Check source menu copy"
assert_contains "$list_output" "Source download/management"
assert_contains "$source_help_output" "Source profile name (default: codex-source)"

log_step "Check release-only install and uninstall cleanup"
mkdir -p "$release_server_root/latest/download"
cat >"$release_server_root/latest/download/${current_platform_asset}" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli 9.9.9"
  exit 0
fi
echo "dummy"
EOF
chmod +x "$release_server_root/latest/download/${current_platform_asset}"
release_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$release_port" --bind 127.0.0.1 --directory "$release_server_root" >/dev/null 2>&1 &
release_server_pid=$!
trap 'stop_background_process "${release_server_pid:-}"; rm -rf "$tmp_dir"' EXIT
for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:$release_port/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
HODEX_RELEASE_BASE_URL="http://127.0.0.1:$release_port" "$CONTROLLER_PATH" install \
  --yes \
  --no-path-update \
  --state-dir "$release_state_dir" \
  --command-dir "$release_command_dir" >"$release_install_output" 2>&1
assert_contains "$release_install_output" "Install complete:"
test -x "$release_command_dir/hodex"
test -x "$release_command_dir/hodexctl"
HODEX_RELEASE_BASE_URL="http://127.0.0.1:$release_port" "$CONTROLLER_PATH" uninstall \
  --state-dir "$release_state_dir" >"$release_uninstall_output" 2>&1
assert_contains "$release_uninstall_output" "Removed release binary, wrappers, and install state."
assert_not_exists "$release_command_dir/hodex"
assert_not_exists "$release_command_dir/hodexctl"
assert_not_exists "$release_state_dir/state.json"

log_step "Check current-process-only install auto persists PATH"
mkdir -p "$path_fix_home_dir" "$path_fix_command_dir"
HOME="$path_fix_home_dir" PATH="$path_fix_command_dir:/usr/bin:/bin:/usr/sbin:/sbin" SHELL="/bin/zsh" \
HODEX_RELEASE_BASE_URL="http://127.0.0.1:$release_port" "$CONTROLLER_PATH" install \
  --yes \
  --state-dir "$path_fix_state_dir" \
  --command-dir "$path_fix_command_dir" >"$path_fix_install_output" 2>&1
assert_contains "$path_fix_state_dir/state.json" "\"path_detected_source\": \"managed-profile-block\""
assert_contains "$path_fix_home_dir/.zshrc" "# >>> hodexctl >>>"
assert_contains "$path_fix_home_dir/.zprofile" "# >>> hodexctl >>>"
env -i HOME="$path_fix_home_dir" USER="$USER" SHELL=/bin/zsh TERM=xterm-256color PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash -lc 'source ~/.zprofile >/dev/null 2>&1 || true; source ~/.zshrc >/dev/null 2>&1 || true; command -v hodex; hodex --version' >"$tmp_dir/path-fix-shell.txt"
assert_contains "$tmp_dir/path-fix-shell.txt" "$path_fix_command_dir/hodex"
assert_contains "$tmp_dir/path-fix-shell.txt" "codex-cli 9.9.9"

log_step "Check repair fixes install without persisted PATH"
mkdir -p "$repair_home_dir" "$repair_command_dir"
HOME="$repair_home_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin" SHELL="/bin/zsh" \
HODEX_RELEASE_BASE_URL="http://127.0.0.1:$release_port" "$CONTROLLER_PATH" install \
  --yes \
  --no-path-update \
  --state-dir "$repair_state_dir" \
  --command-dir "$repair_command_dir" >"$repair_install_output" 2>&1
HOME="$repair_home_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin" SHELL="/bin/zsh" \
"$CONTROLLER_PATH" status --state-dir "$repair_state_dir" --command-dir "$repair_command_dir" >"$repair_status_output"
assert_contains "$repair_status_output" "Recommended: run hodexctl repair"
HOME="$repair_home_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin" SHELL="/bin/zsh" \
"$CONTROLLER_PATH" repair --yes --state-dir "$repair_state_dir" --command-dir "$repair_command_dir" >"$repair_output" 2>&1
assert_contains "$repair_output" "Repair completed."
assert_contains "$repair_home_dir/.zshrc" "# >>> hodexctl >>>"
env -i HOME="$repair_home_dir" USER="$USER" SHELL=/bin/zsh TERM=xterm-256color PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  bash -lc 'source ~/.zprofile >/dev/null 2>&1 || true; source ~/.zshrc >/dev/null 2>&1 || true; command -v hodex; hodex --version' >"$tmp_dir/repair-shell.txt"
assert_contains "$tmp_dir/repair-shell.txt" "$repair_command_dir/hodex"
assert_contains "$tmp_dir/repair-shell.txt" "codex-cli 9.9.9"

stop_background_process "$release_server_pid"
release_server_pid=""
trap 'rm -rf "$tmp_dir"' EXIT

log_step "Check source mode local loopback sync"
if ! command -v git >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1 || { ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; }; then
  log_step "Missing git/cargo/rustc/python3|jq; skip source loopback integration test"
else
  mkdir -p "$source_repo_dir/src" "$command_dir" "$source_home_dir"
  mkdir -p "$source_bin"
  : >"$source_profile_file"
  if command -v just >/dev/null 2>&1; then
    ln -sf "$(command -v just)" "$source_bin/just"
  else
    cat >"$source_bin/just" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$source_bin/just"
  fi
  cat >"$source_repo_dir/Cargo.toml" <<'EOF'
[package]
name = "codex-cli"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "codex"
path = "src/main.rs"
EOF
  cat >"$source_repo_dir/src/main.rs" <<'EOF'
fn main() {
    println!("smoke-build 0.1.0");
}
EOF

  git -C "$source_repo_dir" init -b main >/dev/null
  git -C "$source_repo_dir" config user.name "hodexctl-smoke" >/dev/null
  git -C "$source_repo_dir" config user.email "hodexctl-smoke@example.com" >/dev/null
  git -C "$source_repo_dir" add Cargo.toml src/main.rs >/dev/null
  git -C "$source_repo_dir" commit -m "init smoke repo" >/dev/null
  git -C "$source_repo_dir" tag smoke-tag >/dev/null

  PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source install \
    --yes \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" \
    --git-url "$source_repo_dir" \
    --profile smoke-source \
    --ref main \
    --checkout-dir "$source_checkout_dir" >"$source_install_output" 2>&1
  assert_contains "$source_install_output" "Result summary"
  assert_contains "$source_install_output" "Source profile: smoke-source"
  assert_contains "$source_install_output" "Current ref: main"
  test -d "$source_checkout_dir/.git"
  test -x "$command_dir/hodexctl"
  assert_contains "$source_profile_file" "# >>> hodexctl >>>"
  install_head="$(git -C "$source_checkout_dir" rev-parse HEAD)"
  repo_head="$(git -C "$source_repo_dir" rev-parse HEAD)"
  [[ "$install_head" == "$repo_head" ]] || die "Source install checkout HEAD mismatch"

  PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source status \
    --yes \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" >"$source_status_after_install_output" 2>&1
  assert_contains "$source_status_after_install_output" "Name: smoke-source"
  assert_contains "$source_status_after_install_output" "Mode: manage checkout and toolchain only; no source command wrappers generated"

  cat >"$source_repo_dir/src/main.rs" <<'EOF'
fn main() {
    println!("smoke-build 0.2.0");
}
EOF
  git -C "$source_repo_dir" add src/main.rs >/dev/null
  git -C "$source_repo_dir" commit -m "update smoke repo" >/dev/null

  PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source update \
    --yes \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" >"$source_update_output" 2>&1
  assert_contains "$source_update_output" "Action: Update source"
  update_head="$(git -C "$source_checkout_dir" rev-parse HEAD)"
  repo_head="$(git -C "$source_repo_dir" rev-parse HEAD)"
  [[ "$update_head" == "$repo_head" ]] || die "Source update checkout HEAD mismatch"

  git -C "$source_repo_dir" checkout -b feature-smoke-switch >/dev/null
  CONTROLLER_PATH_ENV="$CONTROLLER_PATH" STATE_FILE_ENV="$state_dir/state.json" REPO_ENV="$source_repo_dir" PROFILE_ENV="smoke-source" CHECKOUT_ENV="$source_checkout_dir" \
    bash -lc '
      set -euo pipefail
      export HODEXCTL_SKIP_MAIN=1
      source "$CONTROLLER_PATH_ENV"
      init_json_backend_if_available
      emit_source_ref_candidates "$REPO_ENV" "$STATE_FILE_ENV" "$PROFILE_ENV" "$CHECKOUT_ENV"
    ' >"$source_ref_candidates_output"
  assert_contains "$source_ref_candidates_output" "feature-smoke-switch"
  if grep -F -- "smoke-tag" "$source_ref_candidates_output" >/dev/null 2>&1; then
    die "Branch candidates should not include tags by default"
  fi

  PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source switch \
    --yes \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" \
    --ref feature-smoke-switch >"$source_rebuild_output" 2>&1
  assert_contains "$source_rebuild_output" "Action: Switch ref and sync source"
  switch_head="$(git -C "$source_checkout_dir" rev-parse --abbrev-ref HEAD)"
  [[ "$switch_head" == "feature-smoke-switch" ]] || die "Source switch ref branch mismatch"

  if PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source rebuild \
    --yes \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" >"$source_rebuild_output" 2>&1; then
    die "source rebuild was removed; should not succeed"
  fi
  assert_contains "$source_rebuild_output" "source rebuild has been removed"

  PATH="$source_bin:$PATH" HOME="$source_home_dir" SHELL="/bin/zsh" RUSTUP_HOME="${RUSTUP_HOME:-$original_home/.rustup}" CARGO_HOME="${CARGO_HOME:-$original_home/.cargo}" "$CONTROLLER_PATH" source uninstall \
    --yes \
    --keep-checkout \
    --state-dir "$state_dir" \
    --command-dir "$command_dir" >"$source_uninstall_output" 2>&1
  assert_contains "$source_uninstall_output" "Source profile uninstalled"
  test -d "$source_checkout_dir"
  assert_not_exists "$command_dir/smoke-source"
  assert_not_exists "$command_dir/hodexctl"
  if grep -F "# >>> hodexctl >>>" "$source_profile_file" >/dev/null 2>&1; then
    die "PATH block should not remain after all source profiles are uninstalled"
  fi
fi

log_step "Smoke test passed"
