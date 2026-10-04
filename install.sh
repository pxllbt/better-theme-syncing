#!/usr/bin/env bash
# Installer for better-theme-sync.
#
# Installs by symlink rather than by copy, so the git checkout in
# ~/.config/omarchy/plugins/better-theme-syncing stays the single source of truth and
# `git pull` updates the plugin with no reinstall step. A copy would drift
# silently and leave the user editing a file that is no longer the one running.
#
# Everything written by the plugin itself (theme configs, state, reports) is left
# alone by uninstall.sh; only the links this script created are removed.

set -euo pipefail

PLUGIN_SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PLUGIN_SRC
readonly LOCAL_BIN="$HOME/.local/bin"
readonly HOOKS_DIR="$HOME/.config/omarchy/hooks"
readonly HOOK_SRC_DIR="$PLUGIN_SRC/hooks"

log() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() {
  printf 'better-theme-sync: %s\n' "$*" >&2
  exit 1
}

command -v omarchy-theme-color >/dev/null 2>&1 ||
  fail "omarchy-theme-color not found. This plugin themes an Omarchy system; it will not work elsewhere."

printf '\nbetter-theme-sync\n\n'

# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------

mkdir -p "$LOCAL_BIN" || fail "cannot create $LOCAL_BIN"

for dir in theme-set.d post-update.d post-boot.d; do
  mkdir -p "$HOOKS_DIR/$dir"
done

# The engine, as `better-theme-sync` on PATH so it can be run by hand and by the
# wallpaper systemd unit.
ln -sfn "$PLUGIN_SRC/better-theme-sync" "$LOCAL_BIN/better-theme-sync" ||
  fail "cannot link $LOCAL_BIN/better-theme-sync"
log "linked ~/.local/bin/better-theme-sync"

# Shims for the two earlier names, so an existing script or habit keeps working.
# Both print a warning and exec the engine rather than failing.
#
# `better-sync` warns on every run instead of forwarding silently. Better Bar
# installs a hook of its own by that name, and a quiet shim would make the two
# indistinguishable at the point where someone is trying to tell them apart.
for old_name in omarchy-auto-sync better-sync; do
  ln -sfn "$PLUGIN_SRC/shims/$old_name" "$LOCAL_BIN/$old_name" ||
    warn "could not link the $old_name shim"
done
log "linked shims: omarchy-auto-sync, better-sync"

# Hooks. theme-set runs the full sync; the other two catch installations that
# happened without a theme change, which is the case that otherwise leaves a
# newly installed app on its stock colors until the next theme switch.
#
# The source layout is hooks/<event>.d/<script>, mirroring the directory
# omarchy-hook reads. Iterating hooks/*/ would walk the .d directories themselves
# and install nothing, which is exactly what an earlier version of this script
# did.
#
# The theme-set hook sorts after Omarchy's own hooks by filename, so it runs once
# the theme is settled and Better Bar's wallpaper palette is fresh. Reading that
# palette before it is regenerated would theme every app against the previous
# wallpaper.
installed_hooks=0
for event_dir in "$HOOK_SRC_DIR"/*.d/; do
  [[ -d $event_dir ]] || continue
  event=${event_dir%/}
  event=${event##*/}
  event=${event%.d}

  mkdir -p "$HOOKS_DIR/$event.d" || continue

  for hook in "$event_dir"*.sh; do
    [[ -f $hook ]] || continue
    name=${hook##*/}

    ln -sfn "$hook" "$HOOKS_DIR/$event.d/$name" || {
      warn "could not link $HOOKS_DIR/$event.d/$name"
      continue
    }
    installed_hooks=$((installed_hooks + 1))
  done
done

if ((installed_hooks == 0)); then
  fail "no hooks were installed; check that $HOOK_SRC_DIR contains <event>.d/*.sh"
fi
log "installed $installed_hooks hook(s)"

# ---------------------------------------------------------------------------
# wallpaper trigger
# ---------------------------------------------------------------------------
#
# A wallpaper change fires no Omarchy hook -- omarchy-theme-bg-set does not call
# omarchy-hook -- so the wallpaper palette has to be picked up some other way.
#
# Omarchy already ships a path unit that watches the theme state directory and
# runs omarchy-rice-sync on any change, which is exactly the trigger needed. This
# installs a sibling unit rather than modifying Omarchy's, so an `omarchy update`
# that replaces the rice-sync unit leaves this one working.
#
# The unit is user-level and written to the user's own systemd directory. No root,
# no system file, and it is enabled for the current user only.

readonly UNIT_DIR="$HOME/.config/systemd/user"
readonly WATCH_PATH_UNIT="$UNIT_DIR/better-theme-sync-wallpaper.path"
readonly WATCH_SERVICE_UNIT="$UNIT_DIR/better-theme-sync-wallpaper.service"

if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"

  cat >"$WATCH_SERVICE_UNIT" <<UNIT
[Unit]
Description=Sync application colors from the Omarchy wallpaper palette
After=graphical-session.target

[Service]
Type=oneshot
# The sleep is not cosmetic. omarchy-theme-set replaces current/theme with
# rm -rf + mv and writes theme.name only afterwards, so a run that starts inside
# that window would read the outgoing theme's colors.toml against the incoming
# wallpaper's palette. Omarchy's own wallpaper-watch unit waits the same way.
#
# Safe to do this in ExecStartPre because Type=oneshot does not report the unit
# as started until the whole thing exits, so the path unit cannot retrigger on
# the writes this run is waiting out.
# The delay covers only the mid-theme-swap window, where current/theme is
# replaced with rm -rf + mv and theme.name is written afterwards, so a run
# starting inside it would read the outgoing theme. The palette ordering is not
# handled here at all -- the path unit watches the palette file for that.
ExecStartPre=/bin/sleep 2
ExecStart=$LOCAL_BIN/better-theme-sync --wallpaper
UNIT

  cat >"$WATCH_PATH_UNIT" <<UNIT
[Unit]
Description=Watch Omarchy wallpaper state for palette changes

[Path]
# Both inputs the wallpaper palette depends on, watched as events rather than
# waited on with a timer.
#
# %h/.local/state/omarchy/current -- the wallpaper symlink is swapped here, by
# either \`omarchy theme set\` or \`omarchy theme bg\`. Modified rather than Changed,
# because a symlink swap is a directory-level mtime change, not a change to one
# inode.
#
# %h/.cache/better/colors.json -- Better Bar's palette. This second watch is what
# makes the ordering safe. wallpaper.sh regenerates the palette a couple of
# seconds after the symlink moves, because it shells out to magick over the
# image, so a unit watching only the symlink reads the *previous* wallpaper's
# colors and nothing ever corrects it. Watching the palette means the run that
# matters is triggered by the palette actually changing.
#
# A missing colors.json simply never fires, which is the correct behaviour on a
# machine without Better Bar: there is no palette to wait for, and the theme pass
# does not read one anyway.

PathModified=%h/.local/state/omarchy/current
PathModified=%h/.cache/better/colors.json

[Install]
WantedBy=default.target
UNIT

  systemctl --user daemon-reload >/dev/null 2>&1 || warn "systemd --user daemon-reload failed"
  systemctl --user enable --now better-theme-sync-wallpaper.path >/dev/null 2>&1 ||
    warn "could not enable the wallpaper watcher; run: systemctl --user enable --now better-theme-sync-wallpaper.path"
  log "enabled the wallpaper watcher (systemd --user)"
else
  warn "systemctl not found; wallpaper-only changes will sync on the next theme change"
fi

# ---------------------------------------------------------------------------
# first run
# ---------------------------------------------------------------------------

printf '\n'
if "$LOCAL_BIN/better-theme-sync" --check; then
  printf '\nInstalled.\n\n'
else
  printf '\nInstalled, with warnings above.\n\n'
fi

cat <<'NEXT'
Next steps
----------
  better-theme-sync --check      what is detected and what is missing
  better-theme-sync --list       every app found, and what would be themed
  better-theme-sync              run a sync by hand at any time
  omarchy theme set <name>       a theme change runs the full sync
  omarchy theme bg next          a wallpaper change runs the wallpaper half

Options live in better-theme-sync.d/config.json -- see the README.
To add your own app, drop a script defining apply_<name>() into
better-theme-sync.d/apps/ and give it to Omarchy with `better-theme-sync`.

To uninstall: ./uninstall.sh
NEXT
