<div align="center">

<img src="assets/icon.svg" width="80" alt="Launcher Customizer icon" />

# launcher-customizer

[![Caelestia KDE](https://img.shields.io/badge/Caelestia_KDE-2.7.5_tested-9bd0cc?style=for-the-badge&labelColor=101418)](https://github.com/caelestia-kde/caelestia)
[![KDE Plasma](https://img.shields.io/badge/Plasma_6-1D99F3?logo=kde&logoColor=white&style=for-the-badge&labelColor=101418)](https://kde.org/plasma-desktop)
[![Version](https://img.shields.io/badge/Version-2.1.0-9bd0cc?style=for-the-badge&labelColor=101418)](metadata.json)
[![License: MIT](https://img.shields.io/badge/License-MIT-9bd0cc?style=for-the-badge&labelColor=101418)](LICENSE)

</div>

> [!NOTE]
> **Tested and working on Caelestia KDE 2.7.5.** Other versions may work too: if an
> update changes the code this plugin hooks into, it switches itself off safely and a
> notification tells you.

A plugin for [Caelestia KDE](https://github.com/caelestia-kde/caelestia) that puts you in
charge of the app launcher's categories, **synced both ways with the KDE application
menu**.

> [!TIP]
> Right-click any app in the launcher and choose *Move to category…* to jump straight to
> it in the editor.

## Installation

**Requirements:** Caelestia KDE (tested on 2.7.5), `python3`. Optional: `python-fonttools`
(exports Material icons to KDE) and `kdialog` (file picker for image icons).

Open *Settings*, go to *Plugins*, and install from this URL:

```
https://github.com/COCONAT10MEN/launcher-customizer
```

On first start the plugin hooks into the shell and restarts it once.

### Updating

Install from the same URL again. Your layout lives in
`~/.config/caelestia/launcher-customizer.json` and in KDE's own menu files, so it is
kept.

### Uninstalling

```bash
python3 ~/.config/caelestia/plugins/launcher-customizer/patch.py revert ~/.config/quickshell/caelestia
```

Then remove the plugin in *Settings -> Plugins* and restart the shell. Your KDE menu
edits stay (they are normal KDE menu edits); undo them in the KDE Menu Editor with
*Restore to system menu* if you want.

## Opening the editor

- *Settings -> Plugins -> Launcher Customizer -> ⚙*
- Right-click an app in the launcher -> *Move to category…*
- From a script or keybind:

```bash
quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer open
```

## Categories, synced with KDE

The launcher shows exactly the categories KDE's own menu has, so Kickoff, the KDE Menu
Editor and the launcher always agree. Everything you do in the editor is written back to
KDE the way KDE's Menu Editor writes it:

| In the editor | Written to KDE as |
| --- | --- |
| Move an app to a category | `Include`/`Exclude` rules in `~/.config/menus/applications-kmenuedit.menu` |
| Also show an app in another category, or remove it from one | the same, without taking it out elsewhere |
| Create a category | a new menu + `~/.local/share/desktop-directories/caelestia-*.directory` |
| Rename, change the icon of, or hide a category | a `.directory` override in `~/.local/share/desktop-directories` |
| Reorder categories | the menu's `Layout` |
| Delete a category you made | removed; its apps go back to where KDE puts them |

After each change KDE's menu cache is rebuilt (`kbuildsycoca6`). The other way round
works too: edits made in the KDE Menu Editor, newly installed apps and renamed
categories show up in the launcher by themselves.

The menu is read with a built-in implementation of the freedesktop.org menu spec
(system menu, `applications-merged/`, the Menu Editor's overrides, `.directory` files,
`OnlyShowIn`/`NoDisplay`/`TryExec`), checked entry for entry against KDE's own
`kbuildsycoca6 --menutest`.

## Configuring

- **Categories from** - *KDE menu* (default, synced) or *Caelestia* (Caelestia's own
  fixed list; edits stored in `~/.config/caelestia/launcher-customizer.json`, not shared
  with KDE)
- **Launcher icons** - *Material* shows KDE's categories in Caelestia's style, *KDE
  theme* uses your icon theme. Icons you change in KDE always show as-is
- **Icon picker** - ~3,800 searchable Material Symbols, every icon of your KDE icon
  theme, or any SVG/PNG file. Material icons are exported as colour-scheme-aware SVGs
  so KDE shows the same glyph
- **Categories** - rename, hide, reorder, reset to KDE's default, delete; subcategories,
  app counts and markers for hidden, empty and your own categories
- **Apps** - search everything, filter by *this category / all apps / Lost & Found*,
  see every category an app is in, move, also-add, reset to automatic
- **Bulk edit** - tick several apps (or Ctrl-click) and move, add or reset them at once
- **Undo** - up to 40 steps, KDE side included

| Shortcut | Action |
| --- | --- |
| `Ctrl + F` | Search apps |
| `Ctrl + Z` | Undo |
| `Ctrl + N` | New category |
| `Esc` | Close the picker or the editor |

## Troubleshooting

| Problem | Fix |
| --- | --- |
| A change in KDE's Menu Editor doesn't show | Open the launcher once (it re-reads the menu), or press the sync button in the editor |
| Launcher shows Caelestia's list instead of KDE's | Switch *Categories from* back to *KDE menu* in the editor |
| Material icon doesn't show in KDE | Install `python-fonttools`, then pick the icon again |
| "Could not hook into the launcher after an update" notification | Caelestia changed the hooked code; everything was put back to stock. Check for a plugin update |
| Want to see what it is doing | Run `caelestia shell -l` and look for `[launcher-customizer]` lines |

## How it works

- Caelestia's plugin API has no hooks for the launcher, so on every shell start
  `patch.py` adds `modules/launcher/services/LauncherCustomizer.qml` and replaces a few
  exact snippets (launcher categories, the category button and app menu, the Plugins
  page). Each change sits between `// launcher-customizer:begin` and `:end` markers that
  hold the original text, so a revert is byte for byte.
- After a Caelestia update it patches again and restarts the shell once, through its
  `caelestia-shell` systemd service. If an update changed the code so a snippet no longer
  matches, every file goes back to stock (never half-patched).
- While the plugin is disabled the hooks do nothing and the launcher is stock.

## Repository layout

```
main.qml              plugin entry: KDE sync, editor wiring, patching
Editor.qml            the category editor window
IconPicker.qml        Material / icon theme / image file picker
CategoryPicker.qml    category chooser used by Move to / Also add to
CategoryIcon.qml      category icon (Material glyph or image)
kdemenu.py            freedesktop menu reader and KDE Menu Editor style writer
patch.py              idempotent, revertible shell patcher
shell/                LauncherCustomizer.qml, the singleton patch.py installs
material-symbols.txt  icon names for the picker
restart-shell.sh      restarts the shell through its systemd service
assets/               README artwork
metadata.json         plugin manifest
```

## Credits

- [caelestia-kde](https://github.com/caelestia-kde/caelestia) by [ladybug-me](https://github.com/ladybug-me) and [0xSolanaceae](https://github.com/0xSolanaceae) - the shell and plugin system this builds on
- [Material Symbols](https://fonts.google.com/icons) by Google - icon set (Apache-2.0)
- [KDE](https://kde.org) - the application menu and Menu Editor this stays in sync with
- [COCONAT10MEN](https://github.com/COCONAT10MEN) - this plugin

## License

MIT - see [LICENSE](LICENSE). Free for anyone to use, modify and redistribute, including
in other plugins or commercial projects. If you use this as a base, please credit
[COCONAT10MEN](https://github.com/COCONAT10MEN) (keeping the LICENSE file's copyright
line does that).
