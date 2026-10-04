#!/usr/bin/env bash
# Shared helpers for omarchy-auto-sync. Sourced by the engine; never run directly.

# Where the engine keeps state that must survive an `omarchy update`. Omarchy
# owns everything under /usr/share/omarchy, so a plugin's own bookkeeping goes
# in the user state dir alongside the theme state it describes.
#
# Assigned only when unset: the engine declares this readonly before sourcing
# the libraries, so an unconditional assignment here would warn on every run.
if [[ -z ${AUTOSYNC_STATE_DIR:-} ]]; then
  AUTOSYNC_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
fi


# Log to stderr. Handlers run under `set -uo pipefail` in the engine and a
# non-zero exit from a handler must never abort a theme switch, so every failure
# path in here ends in `return` rather than `exit`.
log() {
  printf 'auto-sync: %s\n' "$*" >&2
}

# Announce a change the user should know about, but only when it matters: a
# running app that cannot pick the new colors up without a restart is worth a
# notification, "wrote gtk.css" is not.
notify() {
  local title="$1" body="${2:-}"
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a "Omarchy" -u low "$title" "$body" >/dev/null 2>&1 || true
}

# Write stdin to $1 only when the content differs from what is already there.
#
# Every generated config goes through this. Three reasons, all of which have
# bitten hand-rolled writers before:
#
#   * Idempotence. The wallpaper path unit fires in bursts (a theme switch
#     touches current/ several times), so a handler that rewrites an identical
#     file churns mtimes and re-triggers every app that watches its own config.
#   * No torn writes. An app reading a half-written config treats it as
#     invalid and may fall back to defaults, or refuse to start.
#   * No clobbering on failure. If generation fails mid-way the destination is
#     never touched, because the staging file is what fails.
#
# Staged in the destination directory so the final step is a same-filesystem
# rename. Preserves the existing file's mode when there is one.
# Whether the last write_if_changed actually wrote anything.
#
# A separate flag rather than a distinct exit status because these functions are
# called under `set -uo pipefail` in ordinary statement position, where a
# non-zero return would be indistinguishable from a real failure. Handlers that
# need to warn about a running app asking for a restart read this.
AUTOSYNC_WROTE=false

write_if_changed() {
  local target="$1" tmp mode

  AUTOSYNC_WROTE=false

  mkdir -p "$(dirname "$target")" || {
    log "cannot create $(dirname "$target")"
    return 1
  }

  tmp=$(mktemp "$target.XXXXXX" 2>/dev/null) || {
    log "cannot stage a write for $target"
    return 1
  }

  cat >"$tmp" || {
    rm -f "$tmp"
    log "failed generating $target"
    return 1
  }

  if [[ -f $target ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi

  # Keep the permissions the file already had. A generated config replacing a
  # 0600 file should not silently widen it to the umask default.
  mode=""
  [[ -f $target ]] && mode=$(stat -c '%a' "$target" 2>/dev/null)
  [[ -n $mode ]] && chmod "$mode" "$tmp" 2>/dev/null

  mv -f "$tmp" "$target" || {
    rm -f "$tmp"
    log "failed writing $target"
    return 1
  }

  AUTOSYNC_WROTE=true
  return 0
}

# Write stdin into $1 as a marked block, preserving anything outside the markers.
#
# Some config files belong to the user and have to be edited rather than
# replaced: gtk.css is the obvious one, where a hand-written rule is common and
# silently overwriting the file would destroy it. For those, the block between
# BEGIN/END markers is this plugin's and everything around it is not.
#
# On the first run the block is appended to whatever is already there; on later
# runs the previous block is found by its markers and replaced in place, so the
# user's own lines keep their position and the file does not grow without bound.
#
# The rewrite is done in awk rather than with bash parameter expansion. Slicing
# the file with ${var%%"$begin"*} looks equivalent and is not: command
# substitution strips trailing newlines, so every run appends one more blank line
# and the file never converges. awk reads and writes a line stream, so the output
# is byte-stable.
#
# $2 is the marker name. It becomes BEGIN/END AUTOSYNC:$2 in the output.
write_marked_block() {
  local target="$1" marker="$2" begin end block tmp rc

  begin="# BEGIN AUTOSYNC:$marker"
  end="# END AUTOSYNC:$marker"

  block=$(mktemp) || {
    log "cannot stage a write for $target"
    return 1
  }
  cat >"$block" || {
    rm -f "$block"
    log "failed generating the block for $target"
    return 1
  }

  # A target that already carries this marker is rewritten; anything else (a
  # missing file, or one holding only the user's own rules) is appended to, so
  # their lines stay above ours and keep winning in a CSS cascade.
  if [[ -f $target ]] && grep -qxF "$begin" "$target" 2>/dev/null; then
    tmp=$(mktemp) || {
      rm -f "$block"
      log "cannot stage a rewrite of $target"
      return 1
    }

    if awk -v begin="$begin" -v end="$end" -v blockfile="$block" '
      BEGIN {
        while ((getline line < blockfile) > 0) block = block line "\n"
        close(blockfile)
      }
      # The markers are re-emitted around the new block rather than dropped:
      # both lines are consumed by `next` on their way in, so without this they
      # would vanish and the next run would append a second block instead of
      # replacing the first.
      $0 == begin && !emitted { printf "%s\n", begin; printf "%s", block; inside = 1; emitted = 1; next }
      $0 == end && inside { printf "%s\n", end; inside = 0; next }
      !inside { print }
    ' "$target" >"$tmp"; then
      write_if_changed "$target" <"$tmp"
      rc=$?
    else
      log "failed rewriting $target"
      rc=1
    fi
    rm -f "$tmp"
  else
    {
      [[ -f $target ]] && cat -- "$target"
      printf '%s\n' "$begin"
      cat "$block"
      printf '%s\n' "$end"
    } | write_if_changed "$target"
    rc=$?
  fi

  rm -f "$block"
  return $rc
}

# The awk prelude every color helper below shares: a hex-digit reader that works
# on any awk, and an sRGB->HSL converter that returns hue/saturation/lightness in
# one pass.
#
# Deliberately not gawk's strtonum(). Omarchy ships gawk, so it would work here,
# but the helpers are the kind of thing that gets copied into a script run under
# busybox awk, and a hand-rolled hex reader costs three lines to stay portable.
read -r -d '' AWK_COLOR_PRELUDE <<'AWK_EOF' || true
function hexval(c,   i) {
  i = index("0123456789abcdef", tolower(c))
  return (i > 0) ? i - 1 : 0
}
function hexbyte(h, idx) {
  return hexval(substr(h, idx, 1)) * 16 + hexval(substr(h, idx + 1, 1))
}
# Sets the globals R, G, B from a hex string. Globals rather than a return
# value because awk has no way to return three values without an array, and
# every caller wants all three.
function hex_rgb(h) {
  R = hexbyte(h, 1) / 255
  G = hexbyte(h, 3) / 255
  B = hexbyte(h, 5) / 255
}
function rgb_hsl(r, g, b,   mx, mn, l, d, s, h) {
  mx = (r > g) ? r : g; if (b > mx) mx = b
  mn = (r < g) ? r : g; if (b < mn) mn = b
  l = (mx + mn) / 2
  if (mx == mn) { HSL_H = 0; HSL_S = 0; HSL_L = l; return }
  d = mx - mn
  s = (l > 0.5) ? d / (2 - mx - mn) : d / (mx + mn)
  if (mx == r)      h = ((g - b) / d) % 6
  else if (mx == g) h = (b - r) / d + 2
  else              h = (r - g) / d + 4
  h *= 60; if (h < 0) h += 360
  HSL_H = h; HSL_S = s; HSL_L = l
}
function hsl_hue(hex,   r, g, b) {
  hex_rgb(hex); rgb_hsl(R, G, B); return HSL_H
}
function hsl_sat(hex,   r, g, b) {
  hex_rgb(hex); rgb_hsl(R, G, B); return HSL_S
}
function srgb_channel(v) {
  return (v <= 0.03928) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4
}
AWK_EOF

# Mix two hex colors. $3 is a fraction (0.3) or a percentage (30%).
#
# The engine needs a handful of derived shades -- an accent hover, a wallpaper
# accent that clears contrast on the wallpaper's own surface -- and neither
# colors.toml nor Better Bar's palette publishes those directly. Same
# implementation shape as Omarchy's own mix_color, so a value derived here
# matches one derived there.
mix_hex() {
  local start="${1#\#}" end="${2#\#}" amount="$3"

  [[ $start =~ ^[0-9A-Fa-f]{6}$ && $end =~ ^[0-9A-Fa-f]{6}$ ]] || return 1

  awk -v start="$start" -v end="$end" -v amount="$amount" "
    $AWK_COLOR_PRELUDE
    BEGIN {
      if (amount ~ /%\$/) { sub(/%\$/, \"\", amount); amount = amount / 100 }
      else { amount += 0; if (amount > 1) amount = amount / 100 }
      if (amount < 0) amount = 0
      if (amount > 1) amount = 1

      printf \"#%02x%02x%02x\\n\",
        int(hexbyte(start,1) * (1-amount) + hexbyte(end,1) * amount + 0.5),
        int(hexbyte(start,3) * (1-amount) + hexbyte(end,3) * amount + 0.5),
        int(hexbyte(start,5) * (1-amount) + hexbyte(end,5) * amount + 0.5)
    }
  "
}

# WCAG relative luminance of a hex color, 0 (black) to 1 (white).
luminance() {
  local hex="${1#\#}"

  [[ $hex =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf '0'
    return 1
  }

  awk -v hex="$hex" "
    $AWK_COLOR_PRELUDE
    BEGIN {
      hex_rgb(hex); r = R; g = G; b = B
      printf \"%.6f\", 0.2126 * srgb_channel(r) + 0.7152 * srgb_channel(g) + 0.0722 * srgb_channel(b)
    }
  "
}

# WCAG contrast ratio between two hex colors, 1.0 to 21.0.
contrast_ratio() {
  local a="${1#\#}" b="${2#\#}"

  [[ $a =~ ^[0-9A-Fa-f]{6}$ && $b =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf '1'
    return 1
  }

  awk -v a="$a" -v b="$b" "
    $AWK_COLOR_PRELUDE
    function lum(h) {
      hex_rgb(h)
      return 0.2126 * srgb_channel(R) + 0.7152 * srgb_channel(G) + 0.0722 * srgb_channel(B)
    }
    BEGIN {
      la = lum(a); lb = lum(b)
      hi = (la > lb) ? la : lb
      lo = (la > lb) ? lb : la
      printf \"%.2f\", (hi + 0.05) / (lo + 0.05)
    }
  "
}

# Of any number of candidates, return the one with the best contrast on $1.
#
# Takes the whole candidate list and measures, so the caller supplies the theme's
# own text first -- keeping its hue when that is good enough -- and falls back to
# black and white, letting the numbers decide instead of a mode flag.
#
# A two-candidate version of this was tried first and it is a trap: passing the
# theme's foreground and white looks safe and is not, because on a dark theme
# both candidates are light and neither can work on a light surface. That is not
# hypothetical -- a dark theme with a pale wallpaper accent produces exactly that
# pair, and the generated selection text came out at 2.09:1.
#
# Theme mode is not a proxy for surface lightness either: Better Bar derives its
# mode from a wallpaper's mean lightness while the accent it publishes is a
# separate value, and the two disagree often enough to matter.
best_contrast_on() {
  local bg="$1" candidate best="" best_ratio=0 ratio

  shift
  for candidate in "$@"; do
    ratio=$(contrast_ratio "$candidate" "$bg") || ratio=1
    if awk -v r="$ratio" -v b="$best_ratio" 'BEGIN { exit !(r > b) }'; then
      best=$candidate
      best_ratio=$ratio
    fi
  done

  # Every candidate failed to parse. Black is the safer of the two extremes on
  # the light surfaces that would produce this, and a wrong-but-present value
  # beats an empty one in a generated config.
  printf '%s' "${best:-#000000}"
}

# Nearest name in GNOME's accent palette, for
# org.gnome.desktop.interface accent-color. GNOME accepts only these nine names
# and silently ignores anything else, leaving the previous accent in place, so
# an unmatched accent is the one failure mode that looks like it worked.
#
# Nearest circular hue distance to the real accents rather than hand-written
# buckets. GNOME's own palette puts orange (#ed8b3a, HSL hue 27) and yellow
# (#c88800, hue 41) fourteen degrees apart, and blue (#1c71d8, 213) and slate
# (#6f8396, 209) four apart: any fixed bucket edge has to be tuned by hand
# against those pairs and silently misplaces colors in between. Measuring
# against the references instead makes the boundaries correct by construction
# and keeps them correct when GNOME re-tunes an accent.
#
# The references are hues alone, so they are stated as the numbers they are and
# not as hex values that would then need re-deriving. Desaturation is what
# separates slate from blue, so saturation is checked before hue: slate is the
# palette's one low-chroma entry, and blue is GNOME's own default, so an accent
# too grey to place stays on the default instead of jumping to a random hue.
gnome_accent_name() {
  local hex="${1#\#}"

  [[ $hex =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf 'blue'
    return 0
  }

  awk -v hex="$hex" "
    $AWK_COLOR_PRELUDE
    BEGIN {
      hex_rgb(hex)
      rgb_hsl(R, G, B)

      # Below this the color is grey rather than a tinted color, and the only
      # grey name in the palette is slate.
      if (HSL_S < 0.25) { print \"slate\"; exit }

      # name, hue. Order is palette order, not hue order, to match the enum.
      name[1]=\"blue\";   hue[1]=213
      name[2]=\"teal\";   hue[2]=180
      name[3]=\"green\";  hue[3]=131
      name[4]=\"yellow\"; hue[4]=41
      name[5]=\"orange\"; hue[5]=27
      name[6]=\"red\";    hue[6]=353
      name[7]=\"pink\";   hue[7]=331
      name[8]=\"purple\"; hue[8]=285

      h = HSL_H
      best = 1; bestd = 1e9
      for (i = 1; i <= 8; i++) {
        d = h - hue[i]
        if (d < 0) d = -d
        if (d > 180) d = 360 - d
        if (d < bestd) { bestd = d; best = i }
      }
      print name[best]
    }
  "
}

# Saturation of a hex color, 0 (grey) to 1. Used to decide whether a color can
# contribute a hue at all.
#
# A shell wrapper rather than a bare awk call so callers do not each re-inline the
# prelude. Prints 0 and fails on an unparseable color, which is also the correct
# answer for "this has no hue to give".
hsl_sat() {
  local hex="${1#\#}"

  [[ $hex =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf '0'
    return 1
  }

  awk -v hex="$hex" "
    $AWK_COLOR_PRELUDE
    BEGIN { hex_rgb(hex); rgb_hsl(R, G, B); printf \"%.4f\", HSL_S }
  "
}

# Hue of a hex color in degrees, 0 to 360. Meaningless for a grey, so callers
# must gate on hsl_sat first.
hsl_hue() {
  local hex="${1#\#}"

  [[ $hex =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf '0'
    return 1
  }

  awk -v hex="$hex" "
    $AWK_COLOR_PRELUDE
    BEGIN { hex_rgb(hex); rgb_hsl(R, G, B); printf \"%.1f\", HSL_H }
  "
}

# Circular distance between the hues of two hex colors, 0 to 180 degrees.
hue_distance() {
  local a="${1#\#}" b="${2#\#}"

  [[ $a =~ ^[0-9A-Fa-f]{6}$ && $b =~ ^[0-9A-Fa-f]{6}$ ]] || {
    printf '180'
    return 1
  }

  awk -v a="$a" -v b="$b" "
    $AWK_COLOR_PRELUDE
    BEGIN {
      d = hsl_hue(a) - hsl_hue(b)
      if (d < 0) d = -d
      if (d > 180) d = 360 - d
      printf \"%.1f\", d
    }
  "
}

# Reconcile the theme's accent with the wallpaper's into one accent.
#
# The problem this solves: the desktop's accent (bar, terminals, launcher) comes
# from colors.toml, so an app that took its selection color from the wallpaper
# instead would show a beige highlight under a blue desktop. Both palettes on
# screen at once is exactly the half-themed look this plugin exists to remove, and
# it is worst in the most common case -- any theme with a wallpaper whose hue has
# nothing to do with the theme's.
#
# So the wallpaper is allowed to tint the theme's accent, never to replace it,
# and only when the two hues are close enough that the result still reads as one
# color family:
#
#   * Hues far apart      -> theme accent unchanged. A warm theme with a cool
#                            wallpaper is a legitimate combination the user
#                            chose; silently averaging it into a muddy midpoint
#                            would override their theme with their wallpaper.
#   * Hues close          -> blend toward the wallpaper, weighted by how close
#                            they are, so a matching wallpaper shifts the accent
#                            slightly and a near-miss barely moves it.
#   * Wallpaper achromatic-> theme accent unchanged. A grey wallpaper has no hue
#                            to contribute, and blending toward grey would only
#                            desaturate the accent.
#
# Prints the resolved accent on stdout. The result is what every app uses, so the
# whole desktop shares one accent no matter which wallpaper is loaded.
harmonize_accent() {
  local theme_accent="$1" wallpaper_accent="${2:-}" threshold="${3:-45}"
  local distance sat weight blended

  # No wallpaper palette, or an unusable one: the theme accent is the answer.
  [[ -n $wallpaper_accent && $wallpaper_accent =~ ^#[0-9A-Fa-f]{6}$ ]] || {
    printf '%s' "$theme_accent"
    return 0
  }

  # An achromatic wallpaper color cannot contribute a hue.
  sat=$(hsl_sat "$wallpaper_accent") || sat=0
  if awk -v s="$sat" 'BEGIN { exit !(s < 0.15) }'; then
    printf '%s' "$theme_accent"
    return 0
  fi

  distance=$(hue_distance "$theme_accent" "$wallpaper_accent") || distance=180
  if awk -v d="$distance" -v t="$threshold" 'BEGIN { exit !(d > t) }'; then
    printf '%s' "$theme_accent"
    return 0
  fi

  # Linear falloff: 0 degrees apart blends most, the threshold blends not at all.
  weight=$(awk -v d="$distance" -v t="$threshold" 'BEGIN { printf "%.3f", 0.40 * (1 - d / t) }')

  blended=$(mix_hex "$theme_accent" "$wallpaper_accent" "$weight") || blended=$theme_accent
  printf '%s' "$blended"
}
