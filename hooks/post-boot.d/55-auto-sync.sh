#!/usr/bin/env bash
# omarchy-auto-sync: pick up applications installed while the session was down.
#
# Installed by omarchy-auto-sync's install.sh; edit that, not this.
#
# Covers the install-then-reboot case, which post-update cannot see because no
# pacman transaction ran inside this session.
set -uo pipefail

command -v omarchy-auto-sync >/dev/null 2>&1 || exit 0
omarchy-auto-sync || true
