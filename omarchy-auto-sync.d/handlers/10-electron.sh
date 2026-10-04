#!/usr/bin/env bash
# Electron and Chromium-based applications.
#
# These apps paint their own chrome and ignore the GTK/Qt theme, so on a themed
# desktop they are the most visible remaining mismatch: a white-framed window
# sitting on a dark desktop. The fix is a pair of Chromium switches on the
# launch line:
#
#   --force-dark-mode                 dark chrome and a dark UI
#   --enable-features=WebContentsForceDark   auto-dark for web content
#
# The second is the one that matters for a client like Discord or Slack, where
# the content is a web page that ships its own light stylesheet.
#
# Desktop entries are edited copy-on-write. /usr/share/applications is never
# touched -- it belongs to the package that installed the file and the next
# update would overwrite it anyway -- so the modified entry is written to
# ~/.local/share/applications, which the XDG lookup order consults first and
# which shadows the system copy without replacing it.
#
# This is opt-out via config.json, because force-dark inverts page colors and can
# look wrong on sites with their own dark design. It is on by default because the
# alternative is a desktop where one window does not match.

# Apps that take a theme from Omarchy already, or that break under force-dark.
#
# The first group is skipped so this handler cannot compete with the tool that
# owns them: omarchy-theme-set-vscode installs a generated color theme into
# code/codium/cursor, and omarchy-rice-sync writes a full userChrome.css and
# Vencord theme for firefox and equibop. Adding force-dark on top of a real
# generated theme double-applies it, and the generated theme is strictly better
# than an auto-inversion.
#
# Sober is here for a different reason: it is a Flatpak whose renderer draws its
# own theme, and its maintainers ship a dark mode that force-dark only fights.
skip_ids=(
  "code.desktop"
  "code-insiders.desktop"
  "codium.desktop"
  "cursor.desktop"
  "vscodium.desktop"
  "firefox.desktop"
  "firefox-esr.desktop"
  "librewolf.desktop"
  "equibop.desktop"
  "vesktop.desktop"
  "org.vinegarhq.Sober.desktop"
)

skip_id() {
  local id="$1" skip
  for skip in "${skip_ids[@]}"; do
    [[ $id == "$skip" ]] && return 0
  done
  return 1
}

# Emit the desktop entry with the dark-mode switches applied to the main Exec.
#
# The switches go on the Exec line only. A [Desktop Action ...] block has its own
# Exec, and rewriting those would change what "New Window" or "Open in Terminal"
# do -- including the terminal one, which must keep its own colors.
#
# Any switches a previous run added are stripped first, so re-running after a
# theme change rewrites the same file rather than stacking duplicates. Stripping
# is by exact-token match on the two switches, not by substring: `--force-dark-mode`
# is a prefix of nothing, but a naive grep for "dark" would also match
# `--disable-features=DarkMode` if a packager ever added it.
render_desktop_entry() {
  local source="$1"

  awk -v force_dark="$AUTOSYNC_ELECTRON_FORCE_DARK" '
    # Track sections so only the [Desktop Entry] header is rewritten.
    /^\[/ {
      section = $0
      sub(/[[:space:]]*\[.*\][[:space:]]*$/, "", section)
      print
      next
    }

    section != "Desktop Entry" { print; next }

    /^Exec=/ {
      line = $0
      sub(/^Exec=/, "", line)

      if (force_dark == "true") {
        # Drop previously-added switches, then append the current pair.
        gsub(/[[:space:]]+--force-dark-mode/, "", line)
        gsub(/--force-dark-mode/, "", line)
        gsub(/[[:space:]]+--enable-features=WebContentsForceDark/, "", line)
        gsub(/--enable-features=WebContentsForceDark/, "", line)

        sub(/[[:space:]]+$/, "", line)
        line = line " --force-dark-mode --enable-features=WebContentsForceDark"
      } else {
        gsub(/[[:space:]]+--force-dark-mode/, "", line)
        gsub(/--force-dark-mode/, "", line)
        gsub(/[[:space:]]+--enable-features=WebContentsForceDark/, "", line)
        gsub(/--enable-features=WebContentsForceDark/, "", line)
        sub(/[[:space:]]+$/, "", line)
      }

      print "Exec=" line
      next
    }

    { print }
  ' "$source"
}

apply_electron() {
  $AUTOSYNC_ELECTRON_FORCE_DARK || {
    log "electron force-dark disabled in config; leaving launchers alone"
    return 0
  }

  local user_dir="$HOME/.local/share/applications"
  mkdir -p "$user_dir" || {
    log "cannot create $user_dir; skipping Electron apps"
    return 0
  }

  local id name exec source target changed=0 skipped=0

  while IFS=$'\t' read -r id name exec source; do
    autosync_is_electron "$exec" || continue

    if skip_id "$id"; then
      ((skipped++))
      continue
    fi

    autosync_is_excluded "$id" && {
      log "$name excluded by config"
      continue
    }

    target="$user_dir/$id"

    # Only a system entry gets copied. Rewriting the user's own copy would
    # rewrite a file the user may have edited, and the marker comment below is
    # the only record of what we changed.
    if [[ $source == "$user_dir/"* ]]; then
      [[ -f $target ]] || continue
    fi

    if render_desktop_entry "$source" | write_if_changed "$target"; then
      $AUTOSYNC_WROTE && {
        ((changed++))
        log "themed $name"
      }
    else
      log "could not write $target"
    fi
  done < <(autosync_desktop_entries)

  ((skipped > 0)) && log "left $skipped app(s) to their own theming (code, firefox, equibop, sober)"

  if ((changed > 0)); then
    notify "Themed $changed app launcher(s)" \
      "Electron and Chromium apps now launch with dark mode. New windows pick it up."
  fi
  return 0
}
