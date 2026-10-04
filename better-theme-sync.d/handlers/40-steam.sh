#!/usr/bin/env bash
# The Steam client.
#
# Steam has no theme API. It reads a VDF file from its own config directory and
# otherwise uses a hardcoded palette, so the only lever is that file. This writes
# theme.vdf for every Steam user profile found, which is what makes the client's
# title bar, menu and store match the desktop.
#
# Scoped to real profiles only. userdata/<id> directories are created for any
# account that has ever logged in, including ones with no config subdirectory, so
# the presence of a directory is not proof of a profile.

steam_root() {
  local candidate
  for candidate in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
    [[ -d $candidate ]] && {
      printf '%s' "$candidate"
      return 0
    }
  done
  return 1
}

apply_steam() {
  [[ $AUTOSYNC_STEAM == true ]] || return 0

  local root
  if ! root=$(steam_root); then
    log "Steam not installed; skipping"
    return 0
  fi

  local userdata="$root/userdata"
  [[ -d $userdata ]] || {
    log "Steam has no user profiles yet; skipping"
    return 0
  }

  local -a profiles=()
  local profile
  for profile in "$userdata"/*/; do
    [[ -d ${profile}config ]] || continue
    profiles+=("${profile%/}")
  done

  ((${#profiles[@]} > 0)) || {
    log "no Steam profile with a config directory; skipping"
    return 0
  }

  local dir
  for dir in "${profiles[@]}"; do
    # theme.vdf is read at client start, so a running Steam keeps its colors.
    # Written whole rather than edited: it is a single Steam-owned key with no
    # user content to preserve.
    {
      printf '"ThemeConfig"\n'
      printf '{\n'
      printf '\t"title_bar"\t\t\t"hidden"\n'
      printf '\t"title_bar_bg"\t\t"%s"\n' "$BACKGROUND"
      printf '\t"title_bar_fg"\t\t"%s"\n' "$FOREGROUND"
      printf '\t"title_bar_reserved"\t"none"\n'
      printf '\t"title_bar_selected_bg"\t"%s"\n' "$ACCENT_UNIFIED"
      printf '\t"title_bar_selected_fg"\t"%s"\n' \
        "$(best_contrast_on "$ACCENT_UNIFIED" "$FOREGROUND" '#000000' '#ffffff')"
      printf '\t"button_color"\t\t"%s"\n' "$ACCENT_UNIFIED"
      printf '\t"button_label_color"\t"%s"\n' "$FOREGROUND"
      printf '\t"body_text"\t\t\t"%s"\n' "$FOREGROUND"
      printf '\t"body_bg"\t\t\t"%s"\n' "$BACKGROUND"
      printf '\t"popup_bg"\t\t\t"%s"\n' "$DARK_BACKGROUND"
      printf '\t"popup_text"\t\t\t"%s"\n' "$FOREGROUND"
      printf '\t"popup_border"\t\t"%s"\n' "$LIGHTER_BACKGROUND"
      printf '\t"tab_bg"\t\t\t"%s"\n' "$DARKER_BACKGROUND"
      printf '\t"tab_text"\t\t\t"%s"\n' "$MUTED"
      printf '\t"tab_selected_bg"\t\t"%s"\n' "$ACCENT_UNIFIED"
      printf '\t"tab_selected_text"\t"%s"\n' \
        "$(best_contrast_on "$ACCENT_UNIFIED" "$FOREGROUND" '#000000' '#ffffff')"
      printf '}\n'
    } | write_if_changed "$dir/config/theme.vdf" || continue

    $AUTOSYNC_WROTE && log "themed Steam profile $(basename -- "$dir")"
  done

  command -v pgrep >/dev/null 2>&1 && pgrep -x steam >/dev/null 2>&1 &&
    log "Steam is running; it will pick the theme up on next start"
  return 0
}
