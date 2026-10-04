#!/usr/bin/env bash
# better-theme-sync update check.
#
# Reports whether the checkout is behind the published branch. This tool has no
# manifest.json -- it is bash hooks and a CLI, not a QML plugin -- so the
# version is read out of the engine script and the commit count does the rest.
#
# Always exits 0. A failed check must never block a theme change, so problems
# land in the "error" field instead of the exit status.
#
#   check-update.sh            report only, one line of JSON
#   check-update.sh --notify   also pop a desktop notification, once per version
set -uo pipefail

REPO="pxllbt/better-theme-syncing"
BRANCH="main"
RAW_ENGINE="https://raw.githubusercontent.com/${REPO}/${BRANCH}/better-theme-sync"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script sits at the root of the checkout, so the plugin home is this
# directory. watermark's copy lives in scripts/ and has to go up one level.
PLUGIN_DIR="$SCRIPT_DIR"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
NOTIFIED_FILE="$STATE_DIR/better-theme-sync-update-notified"

emit() {
  jq -nc \
    --argjson update_available "$1" \
    --arg current_version "$2" \
    --arg new_version "$3" \
    --arg current_commit "$4" \
    --arg new_commit "$5" \
    --argjson commits_behind "$6" \
    --arg error "$7" \
    '{
      update_available: $update_available,
      current_version: $current_version,
      new_version: $new_version,
      current_commit: $current_commit,
      new_commit: $new_commit,
      commits_behind: $commits_behind,
      error: $error
    }'
}

current_version="0.0.0"
current_commit=""
if [[ -f "$PLUGIN_DIR/better-theme-sync" ]]; then
  v=$(grep -m1 -oE 'AUTOSYNC_VERSION="[0-9]+\.[0-9]+\.[0-9]+[^"]*"' \
    "$PLUGIN_DIR/better-theme-sync" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^"]*' || true)
  [[ -n "$v" ]] && current_version="$v"
fi

is_git=false
if git -C "$PLUGIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  is_git=true
  current_commit=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
fi

update_available=false
new_version=""
new_commit=""
commits_behind=0
error=""

# Cap the read so a wrong URL cannot stream an unbounded response into a
# variable. The engine script is a few tens of kB.
MAX_REMOTE_SIZE=262144
remote_engine=""
remote_engine=$(curl -fsSL --max-time 10 "$RAW_ENGINE" 2>/dev/null | head -c "$((MAX_REMOTE_SIZE + 1))") || error="network"
if [[ -n "$remote_engine" && ${#remote_engine} -gt "$MAX_REMOTE_SIZE" ]]; then
  error="response too large"
  remote_engine=""
fi
if [[ -n "$remote_engine" ]]; then
  v=$(grep -m1 -oE 'AUTOSYNC_VERSION="[0-9]+\.[0-9]+\.[0-9]+[^"]*"' \
    <<<"$remote_engine" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^"]*' || true)
  # Only accept a semver-shaped string; anything else counts as no answer.
  if [[ -n "$v" && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
    new_version="$v"
  elif [[ -n "$v" ]]; then
    error="invalid version format"
  fi
fi

if [[ "$is_git" == "true" ]]; then
  if timeout 30 git -C "$PLUGIN_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    new_commit=$(git -C "$PLUGIN_DIR" rev-parse --short FETCH_HEAD 2>/dev/null || echo "")
    commits_behind=$(git -C "$PLUGIN_DIR" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)
    if [[ "$commits_behind" -gt 0 ]]; then
      update_available=true
    fi
  fi
fi

if [[ "$update_available" == "false" && -n "$new_version" && "$new_version" != "$current_version" ]]; then
  oldest=$(printf '%s\n%s\n' "$current_version" "$new_version" | sort -V | head -n1)
  if [[ "$oldest" == "$current_version" ]]; then
    update_available=true
  fi
fi

if [[ "${1:-}" == "--notify" && "$update_available" == "true" ]]; then
  # Once per published version. The post-boot hook runs this on every login, so
  # without a stamp the same update would be announced at every start.
  already=""
  [[ -f "$NOTIFIED_FILE" ]] && already=$(cat "$NOTIFIED_FILE" 2>/dev/null || echo "")
  stamp="${new_version:-$new_commit}"
  if [[ -n "$stamp" && "$stamp" != "$already" ]] && command -v omarchy-notification-send >/dev/null 2>&1; then
    if omarchy-notification-send "Better Theme Syncing update available" \
      "~/.config/omarchy/plugins/better-theme-syncing && git pull" >/dev/null 2>&1; then
      mkdir -p "$STATE_DIR" 2>/dev/null &&
        printf '%s' "$stamp" >"$NOTIFIED_FILE" 2>/dev/null
    fi
  fi
fi

emit "$update_available" "$current_version" "$new_version" "$current_commit" "$new_commit" "$commits_behind" "$error"