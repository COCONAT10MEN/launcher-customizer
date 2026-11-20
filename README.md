# Launcher Customizer

A [Caelestia](https://github.com/caelestia-kde) plugin that puts you in charge
of the app launcher's categories — **synced both ways with the KDE application
menu** — plus an experimental option to open the launcher from other screen
edges.

## Open it

- **Nexus → Plugins → Launcher Customizer → ⚙** opens the editor.
- **Right-click any app in the launcher → Move to category…** opens it on that app.
- Script/keybind:

  ```bash
  quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer open
  ```

## Categories, synced with KDE (default)

The launcher shows exactly the categories KDE's own menu has (Kickoff, the KDE
Menu Editor and this launcher always agree), and everything you do in the
editor is written back to KDE the same way KDE's Menu Editor writes it:

| In the editor | Written to KDE as |
| --- | --- |
| Move an app to a category | `Include`/`Exclude` rules in `~/.config/menus/applications-kmenuedit.menu` |
| Also show an app in another category (or remove it from one) | the same, without taking it out elsewhere |
| Create a category | a new menu + `~/.local/share/desktop-directories/caelestia-*.directory` |
| Rename / change icon / hide a category | a `.directory` override in `~/.local/share/desktop-directories` |
| Reorder categories | the menu's `Layout` |
| Delete a category you made | removed; its apps go back to where KDE puts them |

After each change KDE's menu cache is rebuilt (`kbuildsycoca6`). The other way
round works too: edits made in the KDE Menu Editor, newly installed apps and
renamed categories show up in the launcher by themselves (the plugin watches
the menu file and app list, and re-reads the menu whenever the launcher or the
editor opens).

The menu is read with a built-in implementation of the freedesktop.org menu
spec (system menu, `applications-merged/`, the Menu Editor's overrides,
`.directory` files, `OnlyShowIn`/`NoDisplay`/`TryExec`), and it was checked
entry-for-entry against KDE's own `kbuildsycoca6 --menutest`.

Prefer Caelestia's own fixed category list? Switch **Categories from →
Caelestia** in the editor; those edits are stored in
`~/.config/caelestia/launcher-customizer.json` and not shared with KDE.

### Editor features

- Category list with KDE subcategories, app counts, hidden/empty markers and a
  marker for categories you made.
- **Icon picker**: all ~3,800 Material Symbols (searchable), every icon of your
  KDE icon theme, or any SVG/PNG file. A Material icon is also exported as a
  colour-scheme-aware SVG so KDE shows the same glyph.
- **Launcher icons: Material / KDE theme** — show KDE's categories in
  Caelestia's Material style, or with your icon theme's icons. Icons you change
  in KDE always show as-is.
- Rename, hide, reorder, reset to KDE's default, delete.
- Apps: search across everything, filter by *this category / all apps /
  Lost & Found*, see every category an app is in (as removable chips), move,
  also-add, reset to automatic.
- **Bulk edit**: tick several apps (or Ctrl-click) and move/add/reset them at once.
- **Undo** (up to 40 steps) for every change, KDE side included.
- Shortcuts: `Ctrl+F` search, `Ctrl+Z` undo, `Ctrl+N` new category, `Esc` close.
- Button to open KDE's own Menu Editor.

## Launcher position (experimental)

| Option | What it does |
| --- | --- |
| Bottom | Stock behaviour. |
| Top / Left / Right | Opens from that edge. If your bar is on that edge, the launcher grows out of the bar. |
| Follow dock | Opens out of the bar, lined up with your dock, like a Start menu. |

**Experimental:** anything but Bottom may look off with some bar or island
setups, hover/drag-to-open only work at Bottom, and the profile picture is
hidden at Top. Set it in the editor's footer or in Nexus.

## Install

Nexus → Plugins → install from URL:

```
https://github.com/COCONAT10MEN/launcher-customizer
```

Needs `python3`. Optional: `python-fonttools` (to export Material icons to KDE)
and `kdialog` (file picker for image icons). On first start the plugin hooks
into the shell and restarts it once.

## How it hooks in

Caelestia's plugin API has no hooks for the launcher, so on every shell start
`patch.py` adds `modules/launcher/services/LauncherCustomizer.qml` and replaces
a few exact snippets (launcher, drawers, launcher category button, Nexus
plugins page). Each change is wrapped in `// launcher-customizer:begin … :end`
markers holding the original text, so a revert is byte-for-byte.

- Already patched → nothing happens.
- A Caelestia update replaced the files → patched again, shell restarts once
  (through its `caelestia-shell` systemd service; Quickshell's in-process
  reload can deadlock and does not restart plugins).
- An update changed the code so a snippet no longer matches → **every** file
  goes back to stock (never half-patched) and a toast says so.

While the plugin is disabled the hooks do nothing and the launcher is stock.

## Uninstall

```bash
python3 ~/.config/caelestia/plugins/launcher-customizer/patch.py revert ~/.config/quickshell/caelestia
```

Then remove the plugin in Nexus and restart the shell. Your KDE menu edits
stay (they are normal KDE menu edits); undo them in the KDE Menu Editor
("Restore to system menu") if you want.

## License

[MIT](LICENSE): free for anyone to use, modify and redistribute, including in
other plugins or commercial projects. The only ask: if you use this as a base,
credit **[COCONAT10MEN](https://github.com/COCONAT10MEN)** (keeping the
LICENSE file's copyright line does that).
