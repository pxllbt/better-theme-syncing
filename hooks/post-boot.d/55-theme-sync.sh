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

# Announce a pending update, once per published version. This hook runs on
# every login, so the checker keeps its own stamp to stay quiet until there is
# something new.
#
# Resolved from the engine rather than a fixed path, because the plugin does not
# have to live in ~/.config/omarchy/plugins.
engine=$(readlink -f "$(command -v better-theme-sync)" 2>/dev/null) || engine=""
if [[ -n "$engine" && -x ${engine%/*}/check-update.sh ]]; then
  "${engine%/*}/check-update.sh" --notify >/dev/null 2>&1 || true
fi
