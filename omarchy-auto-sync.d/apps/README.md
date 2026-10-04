# Your handlers

Drop a script here defining `apply_<name>` and it runs on every sync, after the
built-in handlers. The full palette is exported into the environment, plus these
helpers:

    autosync_is_electron <exec-line>     true for Electron/Chromium apps
    autosync_is_excluded <desktop-id>    true if config.json excludes it
    autosync_desktop_entries             id, name, exec, path (tab separated)
    autosync_new_packages                packages added since the last run

    mix_hex <a> <b> <0-1|0-100%>         blend two hex colors
    contrast_ratio <a> <b>               WCAG ratio, 1.0 to 21.0
    best_contrast_on <bg> <cand>...      the candidate that reads best on bg
    harmonize_accent <theme> <wall>      the desktop's single accent
    gnome_accent_name <hex>              nearest name in GNOME's accent enum
    hue_distance <a> <b>                 0 to 180 degrees
    luminance <hex>                      0 to 1
    hsl_hue <hex> / hsl_sat <hex>        0-360 degrees / 0-1
    write_if_changed <path>              atomic write, skips if unchanged
    write_marked_block <path> <marker>   replace only this plugin's block
    log <message>                        to stderr

Example:

    #!/usr/bin/env bash
    apply_myapp() {
      local config="$HOME/.config/myapp/config.json"
      command -v myapp >/dev/null 2>&1 || return 0
      autosync_is_excluded "myapp" && return 0

      jq --arg bg "$BACKGROUND" --arg fg "$FOREGROUND" \
            --arg accent "$ACCENT_UNIFIED" \
         '.theme.background = $bg | .theme.foreground = $fg
          | .theme.accent = $accent' "$config" | write_if_changed "$config"
    }

Use `$ACCENT_UNIFIED`, not `$ACCENT`. The unified value is the theme's accent
reconciled with the wallpaper, and it is what keeps the desktop to one accent.

Name the function `apply_<name>_wallpaper` to also run on a wallpaper-only change.

Then run `omarchy-auto-sync` to see it work. `--list` shows the handlers it found.
