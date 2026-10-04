#!/usr/bin/env bash
# Installed-application inventory for omarchy-auto-sync.
#
# Two jobs:
#
#   * inventory    Which applications exist right now, so handlers can decide
#                  whether they have anything to do. A handler must never write
#                  a config for an app that is not installed; a directory full
#                  of theme configs for software you do not have is litter that
#                  the user has to clean up by hand.
#
#   * delta        Which applications appeared since the last run. This is how
#                  "theme what I install next" works without a daemon: the
#                  previous inventory is stored and diffed on the next run.
#
# Desktop entries are the inventory source, not the package database, because a
# package name says nothing about how to theme the app and a desktop entry
# carries the Exec line that Electron handling actually needs. Packages are
# only consulted for the delta, where "something new appeared" is the whole
# question and a name is enough.

# Directories holding installable desktop entries, most specific first.
autosync_desktop_dirs() {
  printf '%s\n' \
    "$HOME/.local/share/applications" \
    "/usr/share/applications" \
    "/var/lib/flatpak/exports/share/applications" \
    "$HOME/.local/share/flatpak/exports/share/applications"
}

# Print "id<TAB>name<TAB>exec<TAB>source" for every installable desktop entry.
#
# Skips entries that are not applications: MIME type handlers (MimeType= lines
# with no useful Exec), autostart entries, and the deprecated NoDisplay marker
# when it coexists with an entry that does display. Hidden entries are still
# listed -- several real apps (Steam's controller service, Flatpak internals)
# are NoDisplay, and a config written for them is still correct -- but the
# caller decides what to act on.
autosync_desktop_entries() {
  local dir file id name exec

  while IFS= read -r dir; do
    [[ -d $dir ]] || continue

    for file in "$dir"/*.desktop; do
      [[ -f $file ]] || continue

      id=${file##*/}
      id=${id%.desktop}

      # One awk pass over the [Desktop Entry] header only.
      #
      # The first section line is [Desktop Entry] itself, so the header ends at
      # the *second* one. Stopping at the first would read nothing at all, and
      # reading the whole file would pull in [Desktop Action ...] blocks, whose
      # own Name= and Exec= would register "New Window" and "Open Terminal" as
      # if they were applications.
      #
      # Name[^=]*= rather than Name= so a localized Name[de]= still resolves when
      # the untranslated default is absent. The unsuffixed key comes first in
      # practice, so first-match-wins lands on the default.
      IFS=$'\t' read -r name exec < <(
        awk '
          /^\[/ { sections++; if (sections > 1) exit; next }
          /^Name[^=]*=/ { if (name == "") { sub(/^Name[^=]*=/, ""); name = $0 } }
          /^Exec=/    { if (exec == "") { sub(/^Exec=/, ""); exec = $0 } }
          END { printf "%s\t%s\n", name, exec }
        ' "$file" 2>/dev/null
      )

      # Fall back to the id when the entry is localized and the default
      # translation is missing, so an app is never invisible because of locale.
      [[ -n $name ]] || name=$id
      [[ -n $exec ]] || continue

      printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$exec" "$file"
    done
  done < <(autosync_desktop_dirs) | sort -u -t$'\t' -k1,1
}

# True when $1 is an Electron or Chromium-embedded application.
#
# Matched on the Exec line rather than on a package list, because there is no
# reliable package name for "is Electron" (Electron apps ship under their own
# names, sometimes via AUR wrappers, sometimes as flatpaks) while the Exec line
# names the binary, and an Electron app's binary is the give-away.
#
# Chromium itself and its forks are included on purpose: they take the same
# --force-dark-mode switch, and a browser left unthemed is the most visible gap
# on the desktop.
autosync_is_electron() {
  local exec_line="$1" token

  local -a markers=(
    electron
    chromium
    google-chrome
    chrome
    microsoft-edge
    msedge
    brave
    vivaldi
    discord
    slack
    teams
    skype
    element
    signal
    obsidian
    notion
    logseq
    postman
    insomnia
    bitwarden
    zettlr
    mihomo
    vesktop
    equibop
    sober
    revolt
    roam
    ferdium
    webcord
    hepta
    breez
    tidal-hifi
    spotify
  )

  exec_line=${exec_line,,}
  for token in "${markers[@]}"; do
    [[ $exec_line == *"$token"* ]] && return 0
  done
  return 1
}

# The current package inventory, one identifier per line, sorted.
#
# pacman and flatpak are both included because an app installed as a flatpak and
# the same app installed as a package are different things on this system, and a
# delta has to notice either. Runtime/dependency packages are included too: this
# list answers "did anything change", not "is this app interesting", and
# filtering per-package here would need the same knowledge the handlers have.
autosync_package_inventory() {
  {
    pacman -Qq 2>/dev/null | sed 's/^/pacman:/'
    flatpak list --app --columns=application 2>/dev/null | sed 's/^/flatpak:/'
  } | sort -u
}

# Compare the current inventory against the stored one.
#
# Prints only additions. Removals are deliberately ignored: an app being
# uninstalled should not cause a sync run, and its stale config is the user's to
# delete if they want it gone -- deleting config for an app that might be
# reinstalled tomorrow is not a decision this plugin should make.
autosync_new_packages() {
  local stored="$AUTOSYNC_STATE_DIR/auto-sync/inventory"

  local -A seen_before=()
  if [[ -f $stored ]]; then
    local line
    while IFS= read -r line; do
      [[ -n $line ]] && seen_before["$line"]=1
    done <"$stored"
  fi

  local current
  current=$(autosync_package_inventory)

  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ -n ${seen_before[$line]:-} ]] || printf '%s\n' "$line"
  done <<<"$current"
}

# Persist the current inventory. Written atomically so an interrupted run cannot
# leave a truncated list that would make every package look new next time.
autosync_save_inventory() {
  local dir="$AUTOSYNC_STATE_DIR/auto-sync"
  mkdir -p "$dir" || return 1
  autosync_package_inventory | write_if_changed "$dir/inventory"
}

# True when $1 appears in the user's exclusion list.
#
# An exclusion is a substring match on the desktop entry id, so "discord" covers
# org.discordapp.Discord without the user having to learn the reverse-DNS name.
autosync_is_excluded() {
  local id="$1" pattern

  [[ -n ${AUTOSYNC_EXCLUDES[*]:-} ]] || return 1

  for pattern in "${AUTOSYNC_EXCLUDES[@]}"; do
    [[ -n $pattern ]] || continue
    [[ $id == *"$pattern"* ]] && return 0
  done
  return 1
}
