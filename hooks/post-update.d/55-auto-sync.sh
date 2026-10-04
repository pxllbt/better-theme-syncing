#!/usr/bin/env bash
# omarchy-auto-sync: catch applications installed since the last sync.
#
# Installed by omarchy-auto-sync's install.sh; edit that, not this.
#
# A full theme change also syncs, so this exists for the case where an app is
# installed and used without the theme ever changing: it would keep its stock
# colors until the next theme switch. post-update is the one hook that runs
# reliably after a pacman transaction, which is when a new app appears.
#
# The sync also records the package inventory, so the next run can report what
# changed rather than redoing the whole scan blind.
set -uo pipefail

command -v omarchy-auto-sync >/dev/null 2>&1 || exit 0
omarchy-auto-sync || true
