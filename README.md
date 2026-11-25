<div align="center">

<img src="assets/icon.svg" width="80" alt="Launcher Customizer icon" />

# launcher-customizer

[![Caelestia KDE](https://img.shields.io/badge/Caelestia_KDE-2.7.6_tested-9bd0cc?style=for-the-badge&labelColor=101418)](https://github.com/caelestia-kde/caelestia)
[![KDE Plasma](https://img.shields.io/badge/Plasma_6-1D99F3?logo=kde&logoColor=white&style=for-the-badge&labelColor=101418)](https://kde.org/plasma-desktop)
[![Version](https://img.shields.io/badge/Version-3.7.0-9bd0cc?style=for-the-badge&labelColor=101418)](metadata.json)
[![License: MIT](https://img.shields.io/badge/License-MIT-9bd0cc?style=for-the-badge&labelColor=101418)](LICENSE)

</div>

> [!NOTE]
> **Tested and working on Caelestia KDE 2.7.6 (and 2.7.5).** Other versions usually work too. When a
> Caelestia update moves things around a little, the plugin adapts on its own. If it can't
> do that safely, it switches itself off, Caelestia keeps working as stock, and it looks for a
> fixed version right away.

**Make Caelestia's app launcher yours.** Out of the box, the launcher sorts your apps
into a fixed set of categories that you can't rename, reorder or add to. Launcher
Customizer, a plugin for [Caelestia KDE](https://github.com/caelestia-kde/caelestia),
replaces that with a full editor for your launcher: your own categories, apps exactly
where you want them, custom launchers for your own commands and scripts, global
shortcuts, and the app details themselves. It lives right inside Settings, under
*Panels & Interface -> Launcher*, styled like the rest of Caelestia.

## What it offers

- **Categories that fit how you work.** Create, rename, nest into subcategories,
  reorder, hide and delete them. Give each one an icon from ~3,800 Material Symbols, your
  icon theme, or any SVG or PNG.
- **Every app exactly where you want it.** Move apps between categories, show one app in
  several, drag and drop, select many at once, set your own order, or
  sort with one click.
- **Subcategories as sections.** Open a category in the launcher and its subcategories
  appear inside it as their own titled sections, right below the category's own apps. No
  extra tabs. Pick *Stacked* (one under another) or *Flowing*, where sections sit side
  by side when they fit, each just big enough for what it holds.
- **Colour your subcategories.** Give any subcategory a background in the launcher, picked
  with a full colour picker, a hex code or a swatch from your current theme. Text on it
  stays readable by itself.
- **Arrange the launcher like your desktop.** Switch the launcher's sort button to
  *Custom* and drag tiles into any order you like. The order sticks, per category.
- **Pin to top.** Right-click an app in the launcher and pin it to the front of its
  category. It stays there whatever the sort order.
- **Spot what's new.** Sort by *Newest first* or *Oldest first*, by when each app was
  installed or last updated (real package dates for pacman and Flatpak). Apps that are
  new or just updated get a small dot in your theme's colour until you open them.
- **Edit the apps themselves.** Change any app's name, description, icon, command,
  arguments, environment variables, work folder or keywords, and choose whether it runs
  in a terminal, as another user, on the dedicated graphics card, or with launch
  feedback.
- **A shortcut for any app.** Click, press the keys, done: it works system-wide.
- **Your own launchers.** Turn any command or script into a launcher with its own name
  and icon.
- **Hide anything in one click.** Hover any app or category in the editor and click the
  eye to take it out of the launcher; click again to bring it back. Hidden apps are the
  same list as *Settings -> Applications & Shortcuts* and the launcher's *Hide app*, so
  hiding or showing an app anywhere shows up everywhere.
- **Hidden apps, found.** Show the entries apps hide by default, and bring back the ones
  you want.
- **Nothing changes until you save.** Edit as much as you like: the *Save* button lights
  up when there is something to save, and nothing reaches the launcher or KDE before you
  press it. Leave the page with unsaved changes and Settings asks whether to save them.
- **Safe to experiment.** Every unsaved change can be undone, and *Restore to system
  menu* puts everything back in one click.
- **Back up and share your layout.** Export categories, order, icons, pins, backgrounds,
  hidden apps and app shortcuts to one file, and import it on another machine (or after a
  reinstall). Importing can be undone too.
- **One menu everywhere.** Your layout is shared with KDE: Kickoff, KDE's Menu Editor and
  Caelestia's launcher always show the same thing, and changes made in either place sync
  to the other.
- **Looks like Caelestia.** Categories use Caelestia's Material icon style, or your KDE
  icon theme if you prefer.
- **Moves like it was built in.** The category highlight slides from one category to the
  next, switching category slides the apps in from that side, and pinning or re-sorting
  glides tiles to their new places.
- **All keyboard.** Left from the first column takes you to the category list, where
  Up/Down switch categories as you go; Right or Enter goes back into the apps, and the
  arrows walk through every subcategory section too.
- **Pin to the dock by dragging.** Drag a tile onto the dock to pin it there.
- **Uninstall from the launcher.** Right-click an app -> *Uninstall…*. A Caelestia dialog
  says in plain words what the app is (a pacman or AUR package, a Flatpak, an Android app
  in Waydroid, a browser or portal web app, an AppImage, or just a launcher), what will
  be removed and what stays, and the exact command. Nothing happens until you confirm;
  packages use KDE's own password prompt. If other software still needs a package, it
  tells you instead of breaking anything.
- **Your launcher, your rules.** Typing can always go straight into search (or wait for
  `/`), Favorites can skip the hearts, the launcher can reopen on the tab you used last,
  and the "Hello" greeting can say anything you like, or nothing.
- **Modern and Classic.** Works with both launcher styles; Classic gets its sort menu
  next to the search field. The Simple and Compact layouts are left exactly as they are.

> [!TIP]
> Right-click any app in the launcher and choose *App info* to jump straight to
> it in the editor.

## Installation

**Requirements:** Caelestia KDE (tested on 2.7.5 and 2.7.6), `python3`. Optional: `python-fonttools`
(Material icons in KDE) and `kdialog` (file pickers).

Grab the zip from the [latest release](https://github.com/COCONAT10MEN/launcher-customizer/releases/latest), unzip it and double-click
**Install** inside. That's it. Older versions are on the [Releases](https://github.com/COCONAT10MEN/launcher-customizer/releases) page too.

Or paste this into Caelestia's *Settings → Plugins*:

```
https://github.com/COCONAT10MEN/launcher-customizer
```

On first start the plugin hooks into the shell and restarts it once.

### Updating

It checks for new releases about once a day, and right away after Caelestia updates. When
one's out you get a notification saying what's new and which Caelestia it was made for next
to yours: hit **Update**, or **Skip this one**. There's also an update badge on its row in
*Settings → Plugins*, so you can update from there whenever you like. It never updates by
itself, and right after an update there's an **Undo** in case something breaks.

It only offers versions that work with your Caelestia. If the newest one needs a newer
Caelestia, you get the newest one that fits, or a heads-up to update Caelestia first.

On a version older than 3.5.0? Reinstall it once to get this. Your menu lives in KDE's own files, so it stays.

Don't want the checks?

```bash
mkdir -p ~/.local/state/caelestia/plugin-updates/launcher-customizer && touch ~/.local/state/caelestia/plugin-updates/launcher-customizer/off
```

Want the previous version back later?

```bash
bash ~/.config/caelestia/plugins/launcher-customizer/updater/update.sh rollback ~/.config/caelestia/plugins/launcher-customizer ~/.config/quickshell/caelestia
```

### Uninstalling

```bash
python3 ~/.config/caelestia/plugins/launcher-customizer/patch.py revert ~/.config/quickshell/caelestia
```

Then remove the plugin in *Settings -> Plugins* and restart the shell. Your menu edits
stay (they are normal KDE menu edits); use *Restore to system menu* first if you want
them gone. With the plugin off, the launcher shows Caelestia's stock categories.

## Opening the editor

- *Settings -> Panels & Interface -> Launcher -> Launcher Customizer*
- *Settings -> Plugins -> Launcher Customizer -> ⚙* (takes you to the same page)
- Right-click an app in the launcher -> *App info*: opens the app's category tab, with its
  subcategory unfolded and the app selected
- From a script or keybind:

```bash
quickshell ipc -p ~/.config/quickshell/caelestia/shell.qml call launcherCustomizer open
```

## Where everything is

| What | Where |
| --- | --- |
| Save your changes | *Save* (the split button with *⋮*) · `Ctrl+S` |
| Switch category | the tabs along the top (drag, or scroll with the mouse wheel); subcategories unfold inside their category |
| Rename a category, change its icon or comment | the pencil next to its name above the list |
| Add a launcher, category or subcategory | *New* button or right-click · `Ctrl+N`, `Ctrl+Shift+N`. New launchers and subcategories go into the category you are in, new categories become the last tab |
| Move, copy or remove apps | toolbar or right-click · `Ctrl+X` `Ctrl+C` `Ctrl+V` `Del` · drag onto a category tab or subcategory |
| Change the order | arrows or right-click · `Alt+Up` `Alt+Down` · drag within the list · or drag tiles in the launcher with *Custom* sort |
| Sort a category, or everything | sort button · right-click a category · *⋮* menu |
| Look inside a subcategory | the arrow next to it in the list (or double-click it) |
| Hide or show an app or category | hover it and click the eye · right-click -> *Hide* · *Hidden* switch (shared with *Settings -> Applications & Shortcuts*) |
| Pin an app to the top of a category | right-click it in the launcher or the editor -> *Pin to top* · *Pin to top of…* switch |
| Subcategory background in the launcher | select the subcategory -> *Background in the launcher*, click the swatch to change the colour |
| Stacked or flowing subcategories, category icon style, new-app dots | *Launcher settings* (the sliders button) |
| Export or import your layout | *Launcher settings -> Backup and share* · *⋮ -> Export / Import layout…* |
| See hidden apps | the eye button next to the search box |
| Find an app | search box (name, description, comment, keywords) |
| Start over | *⋮ -> Restore to system menu…* |
| Name, description, comment | the fields at the top of an app |
| Command, arguments, environment variables | *Program* (with file picker), *Arguments*, *Environment variables* |
| Icon | click the icon: Material Symbols, your icon theme, or any SVG/PNG |
| Hide an app, or show it only in Plasma | *Hidden*, *Only show in Plasma* |
| Folder it starts in | *Work folder* (with folder picker) |
| Run in a terminal | *Run in terminal* + *Terminal options* |
| Run as another user | *Run as a different user* + *Username* |
| Global shortcut | *Shortcut*: click it and press the keys |
| Dedicated graphics card | *Use dedicated graphics card* |
| Busy cursor while it starts | *Launch feedback* |
| Launch it, open its folder, copy its file path | right-click, or the buttons under an app's details |
| Category name, comment, icon, hidden | the same fields when a category is selected (new launchers and subcategories: *New*) |

Also: multi-select with `Ctrl`/`Shift`-click, *Also show in…* to put an app in several
categories, undo for every unsaved change (`Ctrl+Z`, 40 steps), and a button that opens
KDE's own Menu Editor if you ever want it. Anything KDE's Menu Editor can do, you can do
here. On a narrow Settings window the details of what you select open in place of the
list (the arrow takes you back); on a wider one they sit beside it.

## How it stays in sync

Until you save, your edits go to a private working copy of the menu files (in
`~/.cache/caelestia/launcher-customizer/stage`), so the launcher and KDE keep showing your
saved layout. *Save* writes only the files that changed, exactly where KDE's Menu Editor
writes them, and rebuilds KDE's menu cache:

| Change | KDE file |
| --- | --- |
| Moving, adding, removing apps; categories; order | `~/.config/menus/applications-kmenuedit.menu` |
| Category name, comment, icon, hidden | `~/.local/share/desktop-directories/*.directory` |
| Launcher fields | a local copy in `~/.local/share/applications/` |
| Shortcuts | KDE's global shortcut service |

The other way round, edits made in KDE's Menu Editor, newly installed apps and renamed
categories show up in Caelestia by themselves (while you have unsaved changes, the editor
keeps showing your working copy until you save or discard). The menu is read with a built-in
implementation of the freedesktop.org menu spec, checked entry for entry against KDE's
own `kbuildsycoca6 --menutest`.

## Configuring

- **Sort orders** (the launcher's sort button; in the Classic style it sits next to the
  search field) - *Custom*, *Newest first* and *Oldest first* join *Most used* and *A-Z*. *Custom* follows the category's order (the same one
  you set in the editor and that KDE uses); *Favorites* and *All Applications* keep their
  own. Pinned apps always come first.

Everything else is in the editor's *Launcher settings* (the sliders button), and like any
other edit it applies when you press *Save*:

- **Subcategories** - *Stacked*: sections one under another, titles on the left.
  *Flowing*: sections side by side when there is room, titles centred.
- **Category icons** - *Material* shows KDE's categories in Caelestia's style, *Icon
  theme* uses your KDE icon theme. Icons you pick yourself always show as-is.
- **New apps** - the dot for apps installed or updated in the last few days (7 by
  default, 1 to 60). It only marks what arrives after you turn it on, and goes away once
  you open the app.
- **Behaviour**
  - *Typing always searches* (on by default) - typing anywhere in the launcher goes
    into search. Off: press `/` or click the search field first.
  - *No hearts in Favorites* - tiles in Favorites skip the heart; other tabs keep it.
  - *Open on last tab* - reopen on the tab you used last instead of Favorites.
- **Greeting** (Modern style) - show or hide "Hello, {name}", or write your own;
  `{name}` becomes your name.
- **Backup and share** - export to or import from a `.tar.gz` layout file.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| A change made in KDE's Menu Editor doesn't show | Open the launcher once; it re-reads the menu |
| A Material icon doesn't show in KDE | Install `python-fonttools`, then pick the icon again |
| Made a mistake | `Ctrl+Z`, or *Undo* on the bar that appears after a change |
| "Could not hook into the launcher after an update" notification | Caelestia changed the hooked code; everything was put back to stock. Check for a plugin update |
| Too many or too few apps marked new | *Launcher settings -> New apps*: change the days or switch the dots off |
| Want to see what it is doing | Run `caelestia shell -l` and look for `[launcher-customizer]` lines |

## How it hooks in

- **Costs nothing you can feel.** Measured against stock Caelestia with the same scripted
  workload: idle CPU and launcher opening are the same as stock, and arrowing through
  categories costs less than stock. It reads the menu only when something actually
  changed, keeps tiles that did not change, and creates dialogs only when needed.

- Caelestia's plugin API has no hooks for the launcher, so on every shell start
  `patch.py` adds `modules/launcher/services/LauncherCustomizer.qml` and replaces a few
  exact snippets (launcher categories, the category button and app menu, the Settings
  page that hosts the editor, the Launcher and Plugins pages, and the check that asks
  before leaving the editor with unsaved changes). Each change sits between `// launcher-customizer:begin` and `:end` markers that
  hold the original text, so a revert is byte for byte.
- After a Caelestia update it patches again and restarts the shell once, through its
  `caelestia-shell` systemd service. If an update changed the code so a snippet no longer
  matches, every file goes back to stock (never half-patched).

## Repository layout

```
main.qml              plugin entry: KDE sync, unsaved changes, saving, patching
UninstallDialog.qml   the uninstall confirmation dialog
uninstall.py          works out what installed an app, describes it, removes it
EditorView.qml        the editor page: category tabs, contents, Save
Properties.qml        properties of the selected launcher or category
LauncherSettings.qml  layout, icon style, new-app dots, backup
CategoryColorPicker.qml  colour picker for category backgrounds
MenuPopup.qml         right-click and toolbar menus
ShortcutField.qml     records a global shortcut
IconPicker.qml        Material / icon theme / image file picker
CategoryPicker.qml    category chooser for Move to / Also show in
CategoryIcon.qml      category icon (Material glyph or image)
kdemenu.py            freedesktop menu reader and KDE Menu Editor style writer
patch.py              idempotent, revertible shell patcher
shell/                LauncherCustomizer.qml (singleton) and LauncherCustomizerPage.qml
                      (the Settings page), installed by patch.py
material-symbols.txt  icon names for the picker
restart-shell.sh      restarts the shell through its systemd service
assets/               README artwork
updater/              update checks (always asks first) and the Update badge in Settings → Plugins
heal.py               adapts the patch to small Caelestia changes, and undoes it if anything breaks
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
