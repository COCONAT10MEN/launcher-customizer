<div align="center">

<img src="assets/icon.svg" width="80" alt="Launcher Customizer icon" />

# launcher-customizer

[![Caelestia KDE](https://img.shields.io/badge/Caelestia_KDE-2.7.5_tested-9bd0cc?style=for-the-badge&labelColor=101418)](https://github.com/caelestia-kde/caelestia)
[![KDE Plasma](https://img.shields.io/badge/Plasma_6-1D99F3?logo=kde&logoColor=white&style=for-the-badge&labelColor=101418)](https://kde.org/plasma-desktop)
[![Version](https://img.shields.io/badge/Version-3.0.0-9bd0cc?style=for-the-badge&labelColor=101418)](metadata.json)
[![License: MIT](https://img.shields.io/badge/License-MIT-9bd0cc?style=for-the-badge&labelColor=101418)](LICENSE)

</div>

> [!NOTE]
> **Tested and working on Caelestia KDE 2.7.5.** Other versions may work too: if an
> update changes the code this plugin hooks into, it switches itself off safely and a
> notification tells you.

A plugin for [Caelestia KDE](https://github.com/caelestia-kde/caelestia) that brings
**everything KDE's Menu Editor does** into Caelestia. The launcher's categories are the
KDE application menu, and every change syncs both ways: edit here or in KDE, and both
always match.

> [!TIP]
> Right-click any app in the launcher and choose *Move to category…* to jump straight to
> it in the editor.

## Installation

**Requirements:** Caelestia KDE (tested on 2.7.5), `python3`. Optional: `python-fonttools`
(Material icons in KDE) and `kdialog` (file pickers).

Open *Settings*, go to *Plugins*, and install from this URL:

```
https://github.com/COCONAT10MEN/launcher-customizer
```

On first start the plugin hooks into the shell and restarts it once.

### Updating

Install from the same URL again. Your menu lives in KDE's own files, so it is kept.

### Uninstalling

```bash
python3 ~/.config/caelestia/plugins/launcher-customizer/patch.py revert ~/.config/quickshell/caelestia
```

Then remove the plugin in *Settings -> Plugins* and restart the shell. Your menu edits
stay (they are normal KDE menu edits); use *Restore to system menu* first if you want
them gone. With the plugin off, the launcher shows Caelestia's stock categories.

## Opening the editor

- *Settings -> Plugins -> Launcher Customizer -> ⚙*
- Right-click an app in the launcher -> *Move to category…*
- From a script or keybind:

```bash
quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer open
```

## Everything KDE's Menu Editor does

| KDE Menu Editor | Here |
| --- | --- |
| New Item / New Submenu / New Separator | *New* button, right-click menus, `Ctrl+N`, `Ctrl+Shift+N` |
| Cut / Copy / Paste / Delete | toolbar, right-click, `Ctrl+X` `Ctrl+C` `Ctrl+V` `Del`, plus drag and drop |
| Move Up / Move Down | toolbar, right-click, `Alt+Up` `Alt+Down`, or drag to reorder |
| Sort selection / all, by name or description | sort button, right-click on a category, *⋮* menu |
| Show hidden entries | *Show hidden* switch |
| Search | search box (name, description, comment, keywords) |
| Restore to System Menu | *⋮ -> Restore to system menu…* |
| Name, Generic name, Comment | *Name*, *Description*, *Comment* |
| Program, Command-line arguments, Environment variables | *Program* (with file picker), *Arguments*, *Environment variables* |
| Icon | click the icon: Material Symbols, your icon theme, or any SVG/PNG |
| Hidden entry, Only show when logged into Plasma | *Hidden*, *Only show in Plasma* |
| Work path | *Work folder* (with folder picker) |
| Run in terminal + Terminal options | *Run in terminal* + *Terminal options* |
| Run as a different user + Username | *Run as a different user* + *Username* |
| Current shortcut key | *Shortcut*: click and press the keys |
| Run using dedicated graphics card | *Use dedicated graphics card* |
| Enable launch feedback | *Launch feedback* |
| Launch, Open Containing Folder, Copy Location | right-click menu and the buttons under the properties |
| Submenu name, comment, icon, hidden | the same fields when a category is selected |

Extras: subcategories, multi-select (`Ctrl`/`Shift`-click), add an app to several
categories at once (*Also show in…*), undo for every change (`Ctrl+Z`, 40 steps), and a
button that opens KDE's Menu Editor if you ever want it.

## How it stays in sync

Changes are written exactly where KDE's Menu Editor writes them, and KDE's menu cache is
rebuilt after each one:

| Change | KDE file |
| --- | --- |
| Moving, adding, removing apps; categories; order and separators | `~/.config/menus/applications-kmenuedit.menu` |
| Category name, comment, icon, hidden | `~/.local/share/desktop-directories/*.directory` |
| Launcher fields | a local copy in `~/.local/share/applications/` |
| Shortcuts | KDE's global shortcut service |

The other way round, edits made in KDE's Menu Editor, newly installed apps and renamed
categories show up in Caelestia by themselves. The menu is read with a built-in
implementation of the freedesktop.org menu spec, checked entry for entry against KDE's
own `kbuildsycoca6 --menutest`.

## Configuring

- **Launcher icons** (*⋮* menu) - *Material* shows KDE's categories in Caelestia's style,
  *icon theme* uses your KDE icon theme. Icons you pick yourself always show as-is.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| A change made in KDE's Menu Editor doesn't show | Open the launcher once; it re-reads the menu |
| A Material icon doesn't show in KDE | Install `python-fonttools`, then pick the icon again |
| Made a mistake | `Ctrl+Z`, or *Undo* on the bar that appears after a change |
| "Could not hook into the launcher after an update" notification | Caelestia changed the hooked code; everything was put back to stock. Check for a plugin update |
| Want to see what it is doing | Run `caelestia shell -l` and look for `[launcher-customizer]` lines |

## How it hooks in

- Caelestia's plugin API has no hooks for the launcher, so on every shell start
  `patch.py` adds `modules/launcher/services/LauncherCustomizer.qml` and replaces a few
  exact snippets (launcher categories, the category button and app menu, the Plugins
  page). Each change sits between `// launcher-customizer:begin` and `:end` markers that
  hold the original text, so a revert is byte for byte.
- After a Caelestia update it patches again and restarts the shell once, through its
  `caelestia-shell` systemd service. If an update changed the code so a snippet no longer
  matches, every file goes back to stock (never half-patched).

## Repository layout

```
main.qml              plugin entry: KDE sync, editor actions, patching
Editor.qml            the editor window: category tree and contents
Properties.qml        properties of the selected launcher, category or separator
MenuPopup.qml         right-click and toolbar menus
ShortcutField.qml     records a global shortcut
IconPicker.qml        Material / icon theme / image file picker
CategoryPicker.qml    category chooser for Move to / Also show in
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
- [KDE](https://kde.org) - the application menu and Menu Editor this mirrors
- [Material Symbols](https://fonts.google.com/icons) by Google - icon set (Apache-2.0)
- [COCONAT10MEN](https://github.com/COCONAT10MEN) - this plugin

## License

MIT - see [LICENSE](LICENSE). Free for anyone to use, modify and redistribute, including
in other plugins or commercial projects. If you use this as a base, please credit
[COCONAT10MEN](https://github.com/COCONAT10MEN) (keeping the LICENSE file's copyright
line does that).
