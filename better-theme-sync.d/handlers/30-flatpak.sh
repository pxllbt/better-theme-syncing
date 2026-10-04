#!/usr/bin/env bash
# Flatpak applications.
#
# A Flatpak is a separate sandbox with its own environment, so a host-level
# config does not reach it. Two things are worth setting per application:
#
#   * The platform theme, for a Flatpak that ships Qt or GTK4. A GTK4 Flatpak
#     follows the host's dconf color-scheme on its own -- the session bus is
#     shared -- so the only real gap is Qt, which needs the platform theme named
#     inside the sandbox.
#
#   * Nothing else. Force-dark for an Electron Flatpak is deliberately absent:
#     flatpak override --env cannot inject a command-line switch, and the
#     ELECTRON_FORCE_DARK_MODE variable is not honored consistently across
#     Electron versions. A switch that works for some apps is worse than one that
#     is absent, because it looks like coverage that is not there.
#
# Only applications that are actually installed as Flatpaks are touched, and the
# overrides are scoped per application id so nothing leaks into an unrelated app.

apply_flatpak() {
  [[ $AUTOSYNC_FLATPAK == true ]] || return 0

  command -v flatpak >/dev/null 2>&1 || {
    log "flatpak not installed; skipping Flatpak apps"
    return 0
  }

  local -a app_ids=()
  mapfile -t app_ids < <(flatpak list --app --columns=application 2>/dev/null)

  ((${#app_ids[@]} > 0)) || {
    log "no Flatpak applications installed"
    return 0
  }

  local id
  for id in "${app_ids[@]}"; do
    [[ -n $id ]] || continue

    # Which runtime the app actually uses decides the env that matters. Asking
    # flatpak is authoritative and cheap; guessing from the id is neither.
    local runtime
    runtime=$(flatpak info --show-runtime "$id" 2>/dev/null) || continue

    local -a env_args=()

    case "$runtime" in
      *freedesktop-sdk\ 6.* | *org.kde.Platform\ 6*)
        env_args+=(--env=QT_QPA_PLATFORMTHEME=qt6ct)
        ;;
      *freedesktop-sdk\ 5.* | *org.kde.Platform\ 5*)
        env_args+=(--env=QT_QPA_PLATFORMTHEME=qt5ct)
        ;;
    esac

    # GTK3 sandboxes do not always pick up the host's icon theme, which shows up
    # as missing icons rather than as wrong colors. Worth setting when it is
    # already known, and harmless when the theme is not installed.
    if flatpak info "$id" 2>/dev/null | grep -q 'runtime.*org.gtk.Gtk3theme'; then
      env_args+=(--env=GTK_THEME=Adwaita-dark)
    fi

    ((${#env_args[@]} > 0)) || continue

    autosync_is_excluded "$id" && continue

    # --user, never system-wide: a system override would need root and would
    # apply to every user on a shared machine, which is not this plugin's call.
    if flatpak override --user --nofiles "${env_args[@]}" "$id" >/dev/null 2>&1; then
      log "themed Flatpak $id (${env_args[*]})"
    else
      log "could not set overrides for Flatpak $id"
    fi
  done

  return 0
}
