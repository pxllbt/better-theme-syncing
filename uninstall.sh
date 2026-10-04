#!/usr/bin/env bash
# Uninstaller for better-theme-sync.
#
# Removes only what install.sh created: the symlinks and the two systemd units.
#
# Deliberately leaves every generated config in place. A theme config is a
# user's file once it exists -- gtk.css in particular may hold hand-written rules
# outside this plugin's markers, and deleting it would take those with it. The
# generated block is left in place too, so removing the plugin cannot leave a
# desktop that suddenly loses its accent color. Pass --purge to remove the
# generated blocks as well, or delete the files listed below by hand.

set -uo pipefail

readonly PLUGIN_NAME="better-theme-syncing"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly HOOKS_DIR="$HOME/.config/omarchy/hooks"
readonly UNIT_DIR="$HOME/.config/systemd/user"

purge=false
case "${1:-}" in
  --purge) purge=true ;;
  "") ;;
  -h | --help)
    cat <<'USAGE'
better-theme-sync uninstall

  ./uninstall.sh           remove the symlinks and systemd units, keep configs
  ./uninstall.sh --purge   also strip this plugin's block from the configs it writes
USAGE
    exit 0
    ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

log() { printf '  %s\n' "$*"; }

printf '\nbetter-theme-sync uninstall\n\n'

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now better-theme-sync-wallpaper.path >/dev/null 2>&1
  systemctl --user disable --now better-theme-sync-wallpaper.service >/dev/null 2>&1
  rm -f "$UNIT_DIR/better-theme-sync-wallpaper.path" \
    "$UNIT_DIR/better-theme-sync-wallpaper.service"
  systemctl --user daemon-reload >/dev/null 2>&1
  systemctl --user reset-failed better-theme-sync-wallpaper.service >/dev/null 2>&1
  log "removed the wallpaper watcher"
fi

# ---------------------------------------------------------------------------
# hooks and the engine
# ---------------------------------------------------------------------------

removed=0
hook_dir=
emptied_dirs=()
for hook in "$HOOKS_DIR"/*/55-theme-sync.sh "$HOOKS_DIR"/*/55-better-sync.sh; do
  [[ -e $hook ]] || continue
  # Only remove links that point into this plugin. A file the user wrote at this
  # path, or a link to some other checkout, is not ours to delete.
  target=$(readlink -f "$hook" 2>/dev/null) || continue
  case "$target" in
    */"$PLUGIN_NAME"/hooks/*)
      hook_dir=$(dirname -- "$hook")
      rm -f "$hook"
      emptied_dirs+=("$hook_dir")
      removed=$((removed + 1))
      ;;
    *)
      printf '  ! left %s alone (not a link into this plugin)\n' "$hook" >&2
      ;;
  esac
done
((removed > 0)) && log "removed $removed hook(s)"

# Remove an event directory only when this plugin emptied it *and* the installer
# is the thing that created it. A blanket glob over hooks/*/ would also remove
# pre-existing empty directories the user or Omarchy put there -- Omarchy ships an
# empty background-set.d/ that install.sh never touches, and deleting it loses
# nothing today but is not this script's call to make.
for dir in "${emptied_dirs[@]:-}"; do
  [[ -n $dir && -d $dir ]] || continue
  case "${dir##*/}" in
    theme-set.d | post-update.d | post-boot.d)
      rmdir "$dir" 2>/dev/null && log "removed empty ${dir##*/}/"
      ;;
  esac
done

if [[ -L $LOCAL_BIN/better-theme-sync ]]; then
  rm -f "$LOCAL_BIN/better-theme-sync"
  log "removed ~/.local/bin/better-theme-sync"
fi

# ---------------------------------------------------------------------------
# purge
# ---------------------------------------------------------------------------

purge_configs() {
  local stripped=0 dir

  # Strip this plugin's marked block from gtk.css files, leaving everything else
  # in the file untouched.
  for dir in "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"; do
    local target="$dir/gtk.css"
    [[ -f $target ]] || continue
    grep -q 'AUTOSYNC:' "$target" || continue

    # Remove from the BEGIN marker through the END marker inclusive.
    sed -i '/^# BEGIN AUTOSYNC:/,/^# END AUTOSYNC:/d' "$target"
    stripped=$((stripped + 1))
    log "stripped this plugin's block from $target"
  done

  # These are wholly generated, so removing the file is the whole purge.
  local generated=(
    "$HOME/.config/qt5ct/colors/Omarchy.conf"
    "$HOME/.config/qt5ct/qt5ct.conf"
    "$HOME/.config/qt6ct/colors/Omarchy.conf"
    "$HOME/.config/qt6ct/qt6ct.conf"
    "$HOME/.config/environment.d/90-better-theme-sync.conf"
  )
  local file
  for file in "${generated[@]}"; do
    [[ -f $file ]] || continue
    rm -f "$file"
    stripped=$((stripped + 1))
    log "removed $file"
  done

  # Steam theme.vdf files and the copied Electron desktop entries. The desktop
  # entries are only removed where they carry this plugin's switches, so an entry
  # the user created themselves is left alone.
  local entry
  for entry in "$HOME/.local/share/applications"/*.desktop; do
    [[ -f $entry ]] || continue
    grep -q 'WebContentsForceDark' "$entry" || continue
    rm -f "$entry"
    stripped=$((stripped + 1))
    log "removed themed launcher $entry"
  done

  local steam_root
  for steam_root in "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
    [[ -d $steam_root/userdata ]] || continue
    local theme
    for theme in "$steam_root"/userdata/*/config/theme.vdf; do
      [[ -f $theme ]] || continue
      grep -q 'title_bar_bg' "$theme" || continue
      rm -f "$theme"
      stripped=$((stripped + 1))
      log "removed $theme"
    done
  done

  log "purged $stripped generated file(s)"
}

if $purge; then
  purge_configs
else
  cat <<'LEFT'

Configs were kept. This plugin's block is still marked in them, so removing it
does not strip the accent color off the desktop. To remove those too:

  ./uninstall.sh --purge

or delete by hand:
  ~/.config/gtk-4.0/gtk.css          (only the AUTOSYNC block)
  ~/.config/gtk-3.0/gtk.css          (only the AUTOSYNC block)
  ~/.config/qt5ct/ ~/.config/qt6ct/   (if qt5ct/qt6ct was installed for this)
  ~/.config/environment.d/90-better-theme-sync.conf
  ~/.local/share/applications/*.desktop   (only the ones with WebContentsForceDark)
  ~/.local/share/Steam/userdata/*/config/theme.vdf
  ~/.local/state/omarchy/better-theme-sync/      (state and reports)
LEFT
fi

printf '\nUninstalled. The plugin directory itself is still here:\n  %s\nDelete it when you are done with it.\n\n' \
  "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
