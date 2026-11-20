# Launcher Customizer

A [Caelestia](https://github.com/caelestia-kde) plugin that gives you control
over the app launcher: organise its categories the way KDE's menu editor
would, and choose which screen edge it opens from.

## Features

**Categories**

- Rename any category and change its icon (any
  [Material Symbols](https://fonts.google.com/icons) name).
- Hide categories you don't use.
- Reorder them. The order is also the priority when an app has several XDG
  tags, so moving "Games" above "Utilities" pulls tagged games into Games.
- Add your own categories. Give them XDG tags to fill them automatically
  (e.g. `Game, Emulator`), or leave the tags empty and move apps in by hand.
- Move any app into any category, overriding its `.desktop` tags, and undo
  that again with one click.

**Placement** — the launcher can open from:

| Option | What it does |
| --- | --- |
| Bottom | Stock behaviour. |
| Top / Left / Right | Opens from that edge. If your bar is on that edge, the launcher grows out of the bar. |
| Follow dock | Opens out of the bar, lined up with your dock, like a Start menu. It stays fully on screen. |

## Use

- **Right-click any app in the launcher → Move to category…** opens the
  editor on that app.
- Placement: **Nexus → Plugins → Launcher Customizer → settings**, or the row
  at the top of the editor.
- From a script or keybind:

  ```bash
  quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer open
  quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer setPlacement dock
  ```

Your layout is saved in `~/.config/caelestia/launcher-customizer.json`, outside
the plugin folder, so reinstalling or updating the plugin keeps it.

## Install

Nexus → Plugins → install from URL, paste:

```
https://github.com/COCONAT10MEN/launcher-customizer
```

Requires `python3`. On first start the plugin hooks into the shell and
restarts it once by itself.

## How it works

Caelestia's plugin API has no hooks for launcher categories or placement, so
on every shell start the plugin runs `patch.py`, which:

- adds `modules/launcher/services/LauncherCustomizer.qml` to the shell, and
- replaces a few exact snippets in the launcher and drawer files.

Every change is wrapped in `// launcher-customizer:begin` … `:end` markers that
also store the original text, so a revert restores the files byte for byte.

- Already patched → nothing happens.
- A Caelestia update replaced the files → they are patched again and the shell
  restarts once.
- An update changed the code so a snippet no longer matches → **every** file
  is put back to stock (never half-patched) and a toast says the plugin needs
  updating.

While the plugin is disabled, the hooks do nothing, and the launcher behaves
exactly like stock.

The shell is restarted through its `caelestia-shell` systemd user service.
Quickshell's in-process reload is avoided: on current Caelestia it can
deadlock and does not start plugins again.

## Uninstall

Disabling the plugin already restores stock behaviour. To remove the hooks
from the shell files as well:

```bash
python3 ~/.config/caelestia/plugins/launcher-customizer/patch.py revert ~/.config/quickshell/caelestia
```

Then remove the plugin in Nexus and restart the shell. Delete
`~/.config/caelestia/launcher-customizer.json` if you don't want to keep your
layout.

## License

[MIT](LICENSE): free for anyone to use, modify and redistribute, including in
other plugins or commercial projects. The only ask: if you use this as a base,
credit **[COCONAT10MEN](https://github.com/COCONAT10MEN)** (keeping the
LICENSE file's copyright line does that).
