# Better Theme Syncing

![Omarchy](https://img.shields.io/badge/Omarchy-4.x-1e66f5?style=flat-square)
![Shell](https://img.shields.io/badge/Shell-bash-1e66f5?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-1e66f5?style=flat-square)

> **id:** `pix.themesync`

Theme every application installed on an [Omarchy](https://omarchy.org/) system from the active
theme and the current wallpaper — including applications installed later.

Omarchy themes a fixed list of about fifteen programs. Install a GTK app, a Qt dialog, an Electron
client, and the desktop stops looking like one desktop. This closes that gap, and keeps it closed
as you install more.

Works with [Better Bar](https://github.com/amanhex/Better)'s wallpaper palette, and does not
compete with `omarchy-rice-sync`, the `better-sync` hook, or the Omarchy shell's own theming.

> **Naming notes.** Better Bar installs a hook of its own called `better-sync`; it is unrelated to
> this project and nothing here reads, writes, or replaces it. This tool has also been renamed —
> it was `omarchy-auto-sync`, and briefly `better-sync`. Both old commands still run through a
> shim that warns and forwards.

---

## Install

```bash
git clone <this-repo> ~/.config/omarchy/plugins/better-theme-syncing
~/.config/omarchy/plugins/better-theme-syncing/install.sh
```

Installed by symlink, so `git pull` updates it. No root, no system files touched.

To remove:

```bash
~/.config/omarchy/plugins/better-theme-syncing/uninstall.sh            # keep generated configs
~/.config/omarchy/plugins/better-theme-syncing/uninstall.sh --purge    # also strip them
```

Uninstall deliberately leaves generated configs alone. `gtk.css` may hold rules you wrote
yourself, and a desktop that suddenly loses its accent color because a plugin was removed is worse
than a leftover file.

## Commands

| Command | What it does |
| --- | --- |
| `better-theme-sync` | Sync every application. Same as the hooks run. |
| `better-theme-sync --theme` | Theme colors only, ignoring the wallpaper |
| `better-theme-sync --wallpaper` | Wallpaper palette only |
| `better-theme-sync --list` | Every application found, and what would be themed |
| `better-theme-sync --check` | Dependencies, paths, counts. Changes nothing. |

All are idempotent. Nothing is written unless the content actually changed.

## Not an Omarchy *shell* plugin

[plugins.omarchy.org](https://plugins.omarchy.org/) lists Quickshell plugins, and it lists
those specifically. Its validator recognises exactly six kinds:

```
bar  bar-widget  menu  overlay  panel  service
```

Each one names a QML file that `omarchy-shell` loads. There is no `hook` or `cli` kind, because a
bash script is not something the shell can load.

This is a set of bash hooks plus a CLI, so there is no honest `manifest.json` to add:

- **Without one**, `omarchy plugin add` refuses the repo — correctly, since it is not a shell plugin.
- **With a fabricated one**, the kind would be rejected outright; and an entry point pointed at a
  `.sh` file would pass the validator's file-existence check and then fail when the shell tried to
  load it as QML. That is worse than being absent: it looks installed and does nothing.

So this ships as a normal GitHub tool rather than a marketplace listing. Everything else the
publishing guide asks for is here: public repository, `manifest.json`-free root layout, README,
MIT license, and an install script that only creates symlinks and systemd user units.

Installing it is one command either way — `git clone` plus `./install.sh` — which is what the
marketplace would have printed anyway.

## What it themes

| Target | How |
| --- | --- |
| **GTK 3 / GTK 4 / libadwaita** | `gtk.css` `@define-color` palette, plus `color-scheme` and `accent-color` in gsettings |
| **Electron & Chromium apps** | `--force-dark-mode --enable-features=WebContentsForceDark` on a copy-on-write `.desktop` launcher |
| **Qt 5 / Qt 6** | A `qt5ct`/`qt6ct` color scheme, when either tool is installed |
| **Flatpaks** | Per-app `flatpak override --user` for Qt runtime theme selection |
| **Steam** | `theme.vdf` for every Steam profile found |
| **Omarchy shell plugins** | Audited, not configured — see below |

### Shell plugins need no configuration

The shell reads `colors.toml` and `shell.toml` through its `Color` singleton, so a plugin that uses
`Color.*` or `Style.*` already follows every theme change. That covers all stock plugins and most
third-party ones.

What the singleton *cannot* do is tell you about the plugin that hardcodes `#rrggbb` and never reads
it. That plugin keeps its own colors through every theme switch, and it is invisible until you
change the theme and notice one widget did not move. So this audits instead of configuring:

```bash
cat ~/.local/state/omarchy/auto-sync/shell-plugins.md
```

It lists every installed plugin — stock and yours — and flags the ones that will not follow the
theme. It re-scans on every run, so a plugin installed later, or synced in from another machine, is
picked up on the next theme change. You are notified when that set changes, and not otherwise.

Nothing here rewrites a plugin's QML. A recolored plugin is silently undone by `omarchy plugin
clone` or any plugin update.

## One accent, not two

The desktop's accent comes from `colors.toml` — the bar, the terminals and the launcher all draw
with it. If applications took their highlight color from the wallpaper instead, you would get two
palettes on one screen, which is the exact half-themed look this plugin exists to remove.

So the wallpaper **tints** the theme's accent; it never replaces it, and only when the two hues are
close enough to still read as one color family:

| Theme accent vs wallpaper | Result |
| --- | --- |
| Same or nearby hue | Blended, weighted by how close they are |
| Distant hues | Theme accent, untouched |
| Grey or near-grey wallpaper | Theme accent — a grey has no hue to contribute |

A warm theme with a cool wallpaper is a combination you chose; averaging it into a muddy midpoint
would override your theme with your wallpaper. So it is left alone.

Everything else — surfaces, text, borders — stays on the theme. Legibility of body text never
depends on which picture happens to be loaded. On-accent text is picked by measured WCAG contrast
against the accent actually being written, not by theme mode: theme mode is not a proxy for surface
lightness, and a dark wallpaper can still publish a pale accent.

Verified across all 22 stock themes in both modes: body text and selection text clear WCAG AA.

## Better Bar compatibility

Structural, not a promise:

- **Better Bar's palette is read, never written.** `~/.cache/better/colors.json` belongs to the
  wallpaper script that generates it.
- **Better Bar's `flags.json` is never touched.**
- **Better Bar's apps are skipped by id** — Firefox, Equibop, Vesktop and Sober are left to
  `omarchy-rice-sync` and `omarchy-theme-set-vscode`, which theme them properly. Adding force-dark
  on top of a generated theme double-applies it, and the generated theme is strictly better than an
  auto-inversion.
- **No file is written twice.** Every generated config is written to a path Omarchy and
  `omarchy-rice-sync` do not use.

### The ordering problem, and why it is handled this way

A wallpaper change fires no Omarchy hook — `omarchy-theme-bg-set` never calls `omarchy-hook`. And
`omarchy theme set` swaps the background symlink *before* `better-sync` regenerates Better Bar's
palette for it, which takes a couple of seconds because it shells out to `magick`.

So a naive full sync during a theme change reads the **previous** wallpaper's palette, writes it
into every config, and then has to be corrected. That produced a visible double write, and a GTK app
watching `gtk.css` reloaded twice for one theme switch.

Rather than sleeping and hoping to win that race, the work is split so there is no race to win:

| Trigger | Pass | Reads the wallpaper? |
| --- | --- | --- |
| `theme-set.d` hook | `--theme` | No |
| `colors.json` or wallpaper symlink changes | `--wallpaper` | Yes, after it settles |

The theme pass establishes the theme palette immediately — that is what you see first. The
wallpaper pass layers the wallpaper tint on top once the palette has actually been generated. One
write each, in a known order.

The systemd unit watches **both** the wallpaper symlink and `colors.json`. Watching only the
symlink is the bug: the palette finishes later, and nothing would ever correct the run that read it
too early.

## Configuration

`better-theme-sync.d/config.json`:

```json
{
  "exclude": [],
  "electron": { "forceDark": true },
  "qt":       { "enabled": true },
  "flatpak":  { "enabled": true },
  "steam":    { "enabled": true },
  "wallpaper":{ "enabled": true }
}
```

`exclude` is a list of substrings matched against a desktop entry's **id**, so `"discord"` covers
`com.discordapp.Discord` without needing the reverse-DNS name.

A malformed config logs a warning and falls back to the defaults. It never blocks a sync.

## Adding your own handler

Drop a script into `better-theme-sync.d/apps/` defining `apply_<name>`. It runs on every sync, after
the built-in handlers.

```bash
#!/usr/bin/env bash
apply_myapp() {
  local config="$HOME/.config/myapp/config.json"

  # Already installed?
  command -v myapp >/dev/null 2>&1 || return 0

  # Skip if the user's exclusion list matches
  autosync_is_excluded "myapp" && return 0

  jq --arg bg "$BACKGROUND" --arg fg "$FOREGROUND" --arg accent "$ACCENT_UNIFIED" \
     '.theme.background = $bg | .theme.foreground = $fg | .theme.accent = $accent' \
     "$config" | write_if_changed "$config"
}
```

Available as shell functions: `autosync_is_electron`, `autosync_is_excluded`,
`autosync_desktop_entries`, `autosync_new_packages`, and the color helpers `mix_hex`,
`contrast_ratio`, `best_contrast_on`, `harmonize_accent`, `gnome_accent_name`, `hue_distance`,
`write_if_changed`, `write_marked_block`.

Name it `apply_<name>_wallpaper` to also run on a wallpaper-only change.

Exported palette:

```
THEME_NAME MODE BACKGROUND FOREGROUND ACCENT ACCENT_UNIFIED ACCENT_HOVER
DARK_BACKGROUND DARKER_BACKGROUND LIGHTER_BACKGROUND
SELECTION SELECTION_FOREGROUND MUTED
RED YELLOW GREEN BLUE MAGENTA CYAN

WALL_SOURCE WALL_MODE WALL_PRIMARY WALL_BACKGROUND
WALL_SURFACE WALL_SURFACE_LOW WALL_SURFACE_HIGH
WALL_FOREGROUND WALL_MUTED WALL_OUTLINE
BACKGROUND_NAME
```

`ACCENT` is the theme's. `ACCENT_UNIFIED` is the accent to use — the theme's reconciled with the
wallpaper. Prefer `ACCENT_UNIFIED`, or the desktop ends up with two accents again.

## Safety

- Never writes under `/usr/share` — verified.
- Never writes to `/usr/share/omarchy`.
- Never deletes a config. Only `uninstall.sh --purge` does, and only files it can attribute to itself.
- `gtk.css` is edited as a marked block; your own rules keep their position.
- gsettings keys are compared before writing, so a theme change does not invalidate dconf caches
  across every open window for nothing.
- Every write is staged and atomically renamed, so a half-written config is never visible.
- A failing handler is reported and the run continues. One app with an unreadable config cannot
  block a theme switch.

## Requirements

`bash` 4.4+, `gawk`, `jq`, `gsettings`. All present on Omarchy.

`magick` and `python3` are needed to *produce* the wallpaper palette, which Better Bar already does.
Without it the theme pass works unchanged and the wallpaper pass becomes a no-op.

## Layout

```
better-theme-sync                         engine
better-theme-sync.d/
  config.json
  lib/{common,palette,detect}.sh
  handlers/00-gtk.sh                     gsettings + gtk.css
  handlers/10-electron.sh                copy-on-write launchers
  handlers/20-qt.sh                      qt5ct / qt6ct scheme
  handlers/30-flatpak.sh                 flatpak override
  handlers/40-steam.sh                   Steam theme.vdf
  handlers/50-shell-plugins.sh           plugin theme audit
  apps/                                  your handlers
hooks/
  theme-set.d/55-auto-sync.sh            -> --theme
  post-update.d/55-auto-sync.sh          -> sync
  post-boot.d/55-auto-sync.sh            -> sync
install.sh  uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
