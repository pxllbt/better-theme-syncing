#!/usr/bin/env bash
# omarchy-auto-sync: apply the new theme to every installed application.
#
# Installed by omarchy-auto-sync's install.sh; edit that, not this.
#
# omarchy-hook runs this with bash and prints a failure without aborting the
# theme change, so a broken app config here can never block a theme switch.
#
# `--theme`, not a full sync, and the distinction is load-bearing. omarchy-theme-set
# swaps the background symlink and then better-sync regenerates Better Bar's
# wallpaper palette for it, which takes a couple of seconds because it shells out
# to magick over the image. A full sync here would read the *previous* wallpaper's
# palette and write it into every application config, and the wallpaper pass a
# moment later would have to correct all of it -- a visible double write, and a
# GTK app watching gtk.css would reload twice for one theme switch.
#
# So this establishes the theme palette, and omarchy-auto-sync-wallpaper.path --
# which fires on the same directory change -- layers the wallpaper tint on top
# once the palette has settled. One write each, in a known order.
#
# The 55- prefix runs this after Omarchy's own theme-set hooks, so the theme state
# is fully swapped before anything is read.
set -uo pipefail

command -v omarchy-auto-sync >/dev/null 2>&1 || exit 0
omarchy-auto-sync --theme || true