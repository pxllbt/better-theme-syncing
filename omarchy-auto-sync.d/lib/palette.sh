#!/usr/bin/env bash
# Palette resolution for omarchy-auto-sync.
#
# Two independent color sources reach the handlers:
#
#   THEME_*     The active Omarchy theme, via omarchy-theme-color reading
#               ~/.local/state/omarchy/current/theme/colors.toml. This is the
#               palette every other part of the desktop already uses.
#
#   WALL_*      A palette derived from the current wallpaper, read from Better
#               Bar's cache. Better Bar already runs matugen/magick over the
#               wallpaper on every change and publishes the result, so this
#               reuses that instead of extracting colors a second time. Two
#               extractors over the same image would drift, and the wallpaper
#               is expensive to analyze.
#
# The Better Bar cache is read-only here. It is another program's output, and
# writing to it would fight the wallpaper script that owns it.

# Where Better Bar publishes the wallpaper palette. Overridable so the plugin
# can be pointed at a copy during testing.
AUTOSYNC_BETTER_COLORS="${AUTOSYNC_BETTER_COLORS:-${XDG_CACHE_HOME:-$HOME/.cache}/better/colors.json}"

# Resolve one key from the active theme.
#
# omarchy-theme-color is the canonical resolver: it applies the same alias and
# fallback cascade the shell and every omarchy-theme-set-* script use, so a color
# read here is byte-identical to the one the bar is drawing with. Re-parsing
# colors.toml here would mean a second implementation of that cascade.
theme_color() {
  local key="$1" fallback="${2:-}"
  omarchy-theme-color --file "$AUTOSYNC_THEME_COLORS" "$key" "$fallback" 2>/dev/null
}

# Populate THEME_* from colors.toml.
#
# Every key is resolved to a concrete value up front so handlers can read them
# as plain variables and never have to know that omarchy-theme-color exists. A
# handler that shells out per color would fork 15+ times per run.
load_theme_palette() {

  # `$(< file)` is bash's read-the-file shorthand, but it only works as the
  # whole word; adding a redirect turns it back into an ordinary (and empty)
  # command substitution. A plain read with the redirect outside it is the
  # form that survives a missing file.
  AUTOSYNC_THEME_NAME=$(cat "$AUTOSYNC_STATE_DIR/current/theme.name" 2>/dev/null) || AUTOSYNC_THEME_NAME=""
  AUTOSYNC_THEME_NAME=${AUTOSYNC_THEME_NAME//$'\n'/}

  if [[ ! -f $AUTOSYNC_THEME_COLORS ]]; then
    log "no active theme at $AUTOSYNC_THEME_COLORS"
    return 1
  fi

  # mode decides which end of every ramp is the accent and which is the text.
  # omarchy-theme-color derives it from colors.toml, a light.mode marker, or
  # background luminance, so a user theme with no mode key still classifies.
  MODE=$(theme_color mode dark) || MODE=dark

  BACKGROUND=$(theme_color background "#000000")
  FOREGROUND=$(theme_color foreground "#ffffff")
  ACCENT=$(theme_color accent "$FOREGROUND")

  # The four-step background ramp. colors.toml does not always define all of
  # it -- last-horizon ships a lighter_background equal to its background --
  # so each is derived from the one below it when absent. Handlers want a
  # genuinely stepped ramp for surfaces, and a flat one makes every hover
  # state invisible.
  DARK_BACKGROUND=$(theme_color dark_background "")
  DARKER_BACKGROUND=$(theme_color darker_background "")
  LIGHTER_BACKGROUND=$(theme_color lighter_background "")
  SELECTION=$(theme_color selection "")
  MUTED=$(theme_color muted "$FOREGROUND")
  RED=$(theme_color red "#cc0000")
  YELLOW=$(theme_color yellow "#d0b000")
  GREEN=$(theme_color green "#4e9a06")
  BLUE=$(theme_color blue "#3465a4")
  MAGENTA=$(theme_color magenta "#75507b")
  CYAN=$(theme_color cyan "#06989a")

  [[ -n $DARK_BACKGROUND ]]   || DARK_BACKGROUND=$(mix_hex "$BACKGROUND" "#000000" 25%)
  [[ -n $DARKER_BACKGROUND ]] || DARKER_BACKGROUND=$(mix_hex "$BACKGROUND" "#000000" 50%)
  [[ -n $LIGHTER_BACKGROUND && ${LIGHTER_BACKGROUND,,} != "${BACKGROUND,,}" ]] ||
    LIGHTER_BACKGROUND=$(mix_hex "$BACKGROUND" "#ffffff" 8%)
  [[ -n $SELECTION ]] || SELECTION=$LIGHTER_BACKGROUND

  # Text that stays readable on SELECTION. Generated configs need an
  # on-selection color and no theme ships one, so it is measured rather than
  # assumed: the theme's own text first (keeping its hue when it is good
  # enough), then black and white. Deriving it from the theme's mode instead
  # fails whenever a theme pairs a dark mode with a light selection color, which
  # is common -- lumon's selection is a pale blue against a near-black surface.
  SELECTION_FOREGROUND=$(best_contrast_on "$SELECTION" "$FOREGROUND" '#000000' '#ffffff')

  # A hover shade for the accent, for configs that have a slot for one. Toward
  # white on both modes: on a dark theme it lightens the accent, and on a light
  # theme a dark accent lightened on hover still separates from the surface,
  # where darkening it would move it toward the background.
  ACCENT_HOVER=$(mix_hex "$ACCENT" "#ffffff" 18%)

  # The wallpaper has not been read yet, so the unified accent starts as the
  # theme's and is reconciled at the end of load_wallpaper_palette.
  ACCENT_UNIFIED=$ACCENT

  return 0
}

# Populate WALL_* from Better Bar's wallpaper palette.
#
# Best-effort by design. Better Bar is a separate program that may not be
# installed, may not have run yet, or may be configured not to derive a palette
# at all, and none of that should stop the theme half of the sync. Every WALL_*
# var falls back to the theme's equivalent so a handler can use them
# unconditionally.
load_wallpaper_palette() {
  local background

  WALL_SOURCE="none"

  # A theme-only pass does not read the wallpaper at all. See the engine's
  # comment on AUTOSYNC_THEME_ONLY for why: during a theme change the palette on
  # disk still describes the previous wallpaper, so reading it would write stale
  # colors that the wallpaper pass then has to undo.
  #
  # The config switch lands here too, and deliberately in the same place. Offering
  # a documented option and not honouring it is worse than not offering it at all:
  # both config.json and the README list this key, so a user who sets it and
  # watches their tint stay has been told a lie.
  if [[ ${AUTOSYNC_THEME_ONLY:-false} == true || ${AUTOSYNC_WALLPAPER:-true} != true ]]; then
    wall_fallback_to_theme
    return 0
  fi

  if [[ ! -f $AUTOSYNC_BETTER_COLORS ]] || ! command -v jq >/dev/null 2>&1; then
    wall_fallback_to_theme
    return 0
  fi

  # Better Bar's palette is Material 3: primary is the accent, the
  # surface_container_* ramp is the background ladder, and cream/dim/faint are
  # the text tiers. Read defensively -- a truncated or hand-edited cache must
  # degrade to the theme, not emit empty strings into a config file.
  WALL_PRIMARY=$(jq -r '.primary // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  [[ $WALL_PRIMARY =~ ^#[0-9A-Fa-f]{6}$ ]] || {
    wall_fallback_to_theme
    return 0
  }

  WALL_BACKGROUND=$(jq -r '.surface // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_SURFACE=$(jq -r '.surface_container // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_SURFACE_LOW=$(jq -r '.surface_container_low // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_SURFACE_HIGH=$(jq -r '.surface_container_high // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_FOREGROUND=$(jq -r '.cream // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_MUTED=$(jq -r '.dim // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  WALL_OUTLINE=$(jq -r '.outline_variant // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)

  # Better Bar decides light vs dark from the wallpaper's mean lightness, which
  # can disagree with the theme: a dark theme is often paired with a bright
  # wallpaper. Wallpaper-derived mode wins for wallpaper-derived colors, since
  # those colors are unreadable against the other palette's mode.
  background=$(jq -r '.surface // empty' "$AUTOSYNC_BETTER_COLORS" 2>/dev/null)
  if [[ -n $background && $background =~ ^#[0-9A-Fa-f]{6}$ ]]; then
    if awk -v l="$(luminance "$background")" 'BEGIN { exit !(l >= 0.40) }'; then
      WALL_MODE=light
    else
      WALL_MODE=dark
    fi
  else
    WALL_MODE=$MODE
  fi

  WALL_SOURCE="better-bar"

  # Reconcile the accent now that the wallpaper's is known. This is the single
  # place it happens: every handler reads ACCENT_UNIFIED, so the bar, the
  # terminals and every app agree on one accent no matter which palette it came
  # from. The wallpaper may tint the theme's accent, never replace it, and only
  # when the two hues are close enough to read as one family -- see
  # harmonize_accent for the rules and the reasoning.
  ACCENT_UNIFIED=$(harmonize_accent "$ACCENT" "$WALL_PRIMARY")

  # Which wallpaper the palette came from, so a handler writing wallpaper-derived
  # colors can record it in its output and a reader can tell which picture the
  # colors came from. The basename, not the full path: this ends up in a comment
  # in a config file the user may read.
  #
  # The -e test is not paranoia. readlink -f resolves as far as it can and still
  # exits 0 when only the final component is missing, so on a machine whose
  # background symlink is absent it cheerfully returns ".../current/background"
  # and the generated config would claim the wallpaper is named "background".
  AUTOSYNC_BACKGROUND=""
  AUTOSYNC_BACKPAPER_NAME=""
  local resolved
  resolved=$(readlink -f "$AUTOSYNC_STATE_DIR/current/background" 2>/dev/null) || resolved=""
  if [[ -n $resolved && -f $resolved ]]; then
    AUTOSYNC_BACKGROUND=$resolved
    AUTOSYNC_BACKPAPER_NAME=$(basename -- "$resolved")
  fi
  return 0
}

# WALL_* mirror the theme when no wallpaper palette is available.
wall_fallback_to_theme() {
  WALL_SOURCE="theme-fallback"
  WALL_PRIMARY=$ACCENT
  WALL_BACKGROUND=$BACKGROUND
  WALL_SURFACE=$LIGHTER_BACKGROUND
  WALL_SURFACE_LOW=$BACKGROUND
  WALL_SURFACE_HIGH=$SELECTION
  WALL_FOREGROUND=$FOREGROUND
  WALL_MUTED=$MUTED
  WALL_OUTLINE=$MUTED
  WALL_MODE=$MODE
  ACCENT_UNIFIED=$ACCENT

  AUTOSYNC_BACKGROUND=""
  AUTOSYNC_BACKPAPER_NAME=""
  local resolved
  resolved=$(readlink -f "$AUTOSYNC_STATE_DIR/current/background" 2>/dev/null) || resolved=""
  if [[ -n $resolved && -f $resolved ]]; then
    AUTOSYNC_BACKGROUND=$resolved
    AUTOSYNC_BACKPAPER_NAME=$(basename -- "$resolved")
  fi
  return 0
}
