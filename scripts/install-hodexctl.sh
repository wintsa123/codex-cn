#!/usr/bin/env bash
set -euo pipefail

repo="${HODEXCTL_REPO:-${CODEX_REPO:-wintsa123/codex-cn}}"
controller_url_base="${HODEX_CONTROLLER_URL_BASE:-https://raw.githubusercontent.com}"
controller_ref="${HODEX_CONTROLLER_REF:-main}"
state_dir="${HODEX_STATE_DIR:-$HOME/.hodex}"
command_dir="${HODEX_COMMAND_DIR:-${INSTALL_DIR:-}}"
controller_url="${controller_url_base%/}/${repo}/${controller_ref}/scripts/hodexctl/hodexctl.sh"

select_profile_file() {
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

if ! command -v curl >/dev/null 2>&1; then
  echo "Missing dependency: curl" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
controller_path="$tmp_dir/hodexctl.sh"

printf '==> Download hodexctl manager script\n'
curl -fsSL "$controller_url" -o "$controller_path"
chmod +x "$controller_path"
printf '==> Start hodexctl initial install\n'

args=(manager-install --yes --state-dir "$state_dir" --repo "$repo")

if [[ -n "$command_dir" ]]; then
  args+=(--command-dir "$command_dir")
fi

if [[ "${HODEXCTL_NO_PATH_UPDATE:-0}" == "1" ]]; then
  args+=(--no-path-update)
fi

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  args+=(--github-token "$GITHUB_TOKEN")
fi

"$controller_path" "${args[@]}"

printf '==> Install complete\n'
effective_command_dir="$state_dir/commands"
if [[ -n "$command_dir" ]]; then
  effective_command_dir="$command_dir"
fi
printf '==> You can run immediately (no need to wait for PATH): %s\n' "$effective_command_dir/hodexctl status"

if [[ "${HODEXCTL_NO_PATH_UPDATE:-0}" != "1" ]]; then
  profile_file="$(select_profile_file)"
  printf '\n'
  printf '==> To make it available in the current shell, run:\n'
  printf 'source "%s"\n' "$profile_file"
  printf '\n'
  printf 'Note: `curl | bash` runs in a subshell and cannot refresh the parent shell PATH; opening a new terminal also works.\n'
fi
