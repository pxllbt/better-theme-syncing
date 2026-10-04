#!/usr/bin/env bash
# better-theme-sync: pick up applications installed while the session was down.
#
# Installed by better-theme-sync's install.sh; edit that, not this.
#
# Covers the install-then-reboot case, which post-update cannot see because no
# pacman transaction ran inside this session.
set -uo pipefail

command -v better-theme-sync >/dev/null 2>&1 || exit 0
better-theme-sync || true
