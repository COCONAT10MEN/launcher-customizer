pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.launcher.services
import "."

// Launcher Customizer: everything KDE's Menu Editor does, synced with KDE.
FloatingWindow {
    id: win

    required property var store

    // ------------------------------------------------------------- state

    property string cat: ""                 // category open in the middle pane
    property string active: "list"          // pane keyboard actions apply to: tree | list
    property var picked: ({})               // selected rows in the middle pane
    property string focusKey: ""            // item in the properties pane: app:<id> | menu:<path> | sep:<n>
    property string anchorKey: ""
    property bool showHidden: false
    property string search: ""
    property var expanded: ({})
    property var clip: null                 // { mode: cut|copy, keys, from }
    property string pendingFocus: ""
    property bool focusName: false
    property string snack: ""
    property bool dragging: false

    readonly property var kd: LauncherCustomizer.kde ?? ({})
    readonly property var apps: win.kd.apps ?? ({})
    readonly property var nodes: {
        const m = {};
        const walk = list => {
            for (const n of list) {
                m[n.path] = n;
                walk(n.children);
            }
        };
        walk(win.kd.categories ?? []);
        return m;
    }
    readonly property var membership: {
        const m = {};
        for (const path of Object.keys(win.nodes)) {
            const n = win.nodes[path];
            for (const a of n.apps.concat(n.hiddenApps))
                (m[a] = m[a] || []).push(path);
        }
        return m;
    }
    readonly property bool typing: !!(win.activeFocusItem && win.activeFocusItem.selectedText !== undefined)

    function nodeName(path: string): string {
        return win.nodes[path]?.name ?? path.split("/").pop();
    }

    function appVisible(id: string): bool {
        const a = win.apps[id];
        return !!a && (win.showHidden || !a.noDisplay);
    }

    function menuVisible(path: string): bool {
        const n = win.nodes[path];
        return !!n && (win.showHidden || !n.hidden);
    }

    // ------------------------------------------------------------ tree

    readonly property var treeRows: {
        const out = [];
        const walk = (list, depth) => {
            for (const n of list) {
                if (!win.showHidden && n.hidden)
                    continue;
                out.push({ path: n.path, depth: depth, node: n, open: !!win.expanded[n.path] });
                if (win.expanded[n.path])
                    walk(n.children, depth + 1);
            }
        };
        walk(win.kd.categories ?? [], 0);
        return out;
    }

    function openCategory(path: string): void {
        const e = Object.assign({}, win.expanded);
        const parts = path.split("/");
        for (let i = 1; i < parts.length; i++)
            e[parts.slice(0, i).join("/")] = true;
        win.expanded = e;
        win.cat = path;
        win.search = "";
        searchField.text = "";
        win.picked = ({});
        win.focusKey = "menu:" + path;
        win.active = "tree";
    }

    // ----------------------------------------------------- list (middle)

    function itemsOf(path: string): var {
        return path ? (win.nodes[path]?.items ?? []) : (win.kd.rootItems ?? []);
    }

    function keyOf(it: var, i: int): string {
        return it.kind === "app" ? "app:" + it.id : (it.kind === "menu" ? "menu:" + it.path : "sep:" + i);
    }

    readonly property var rows: {
        const q = win.search.trim().toLowerCase();
        if (q.length > 0) {
            const out = [];
            for (const id of Object.keys(win.apps)) {
                const a = win.apps[id];
                if (!win.appVisible(id))
                    continue;
                const hay = [a.name, a.genericName, a.comment, a.keywords, id].join(" ").toLowerCase();
                if (hay.includes(q))
                    out.push({ kind: "app", id: id, key: "app:" + id });
            }
            out.sort((x, y) => String(win.apps[x.id].name).localeCompare(String(win.apps[y.id].name)));
            return out;
        }
        const out = [];
        const items = win.itemsOf(win.cat);
        for (let i = 0; i < items.length; i++) {
            const it = items[i];
            if (it.kind === "app" && !win.appVisible(it.id))
                continue;
            if (it.kind === "menu" && !win.menuVisible(it.path))
                continue;
            out.push(Object.assign({ key: win.keyOf(it, i), index: i }, it));
        }
        return out;
    }
    readonly property var pickedKeys: Object.keys(win.picked).filter(k => win.picked[k])

    function select(key: string, mods: int): void {
        win.active = "list";
        if (mods & Qt.ControlModifier) {
            const p = Object.assign({}, win.picked);
            p[key] = !p[key];
            win.picked = p;
        } else if ((mods & Qt.ShiftModifier) && win.anchorKey) {
            const keys = win.rows.map(r => r.key);
            const a = keys.indexOf(win.anchorKey), b = keys.indexOf(key);
            const p = {};
            for (let i = Math.min(a, b); i <= Math.max(a, b); i++)
                p[keys[i]] = true;
            win.picked = p;
        } else {
            win.picked = { [key]: true };
            win.anchorKey = key;
        }
        win.focusKey = key;
    }

    // ------------------------------------------------- order and layout

    function tokensOf(path: string): var {
        return win.itemsOf(path).map(it => it.kind === "sep" ? "sep" : (it.kind === "menu" ? "menu:" + it.path.split("/").pop() : "app:" + it.id));
    }

    /// Move a token from one position to another in a category's order.
    function moveToken(path: string, from: int, to: int): void {
        const t = win.tokensOf(path);
        if (from < 0 || to < 0 || from >= t.length || to >= t.length || from === to)
            return;
        const [x] = t.splice(from, 1);
        t.splice(to, 0, x);
        win.store.setLayout(path, t);
    }

    // Up/down past the next item you can see (hidden entries are skipped
    // unless "Show hidden" is on).
    function moveRow(delta: int): void {
        if (win.active === "tree") {
            const path = win.cat;
            if (!path)
                return;
            const parent = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
            const items = win.itemsOf(parent);
            const vis = items.map((it, i) => ({ it: it, i: i })).filter(x => x.it.kind === "menu" && win.menuVisible(x.it.path));
            const p = vis.findIndex(x => x.it.path === path);
            const q = p + delta;
            if (p < 0 || q < 0 || q >= vis.length)
                return;
            win.moveToken(parent, vis[p].i, vis[q].i);
            return;
        }
        if (win.search)
            return;
        const p = win.rows.findIndex(r => r.key === win.focusKey);
        const q = p + delta;
        if (p < 0 || q < 0 || q >= win.rows.length)
            return;
        const r = win.rows[p];
        win.moveToken(win.cat, r.index, win.rows[q].index);
        if (r.kind === "sep")
            win.focusKey = "sep:" + win.rows[q].index;
        win.picked = { [win.focusKey]: true };
    }

    function reorderTo(dragKeys: var, targetKey: string): void {
        const items = win.itemsOf(win.cat);
        const t = win.tokensOf(win.cat);
        const keys = items.map((it, i) => win.keyOf(it, i));
        const moving = keys.map((k, i) => dragKeys.includes(k) ? i : -1).filter(i => i >= 0);
        if (moving.length === 0)
            return;
        const target = keys.indexOf(targetKey);
        const take = moving.map(i => t[i]);
        const rest = t.filter((_, i) => !moving.includes(i));
        const before = target < 0 ? rest.length : rest.indexOf(t[target]);
        rest.splice(before < 0 ? rest.length : before, 0, ...take);
        win.store.setLayout(win.cat, rest);
    }

    function addSeparator(): void {
        if (!win.cat && win.active !== "tree")
            return;
        const t = win.tokensOf(win.cat);
        const r = win.rows.find(r => r.key === win.focusKey);
        t.splice(r ? r.index + 1 : t.length, 0, "sep");
        win.store.setLayout(win.cat, t);
    }

    // --------------------------------------------- clipboard, remove, dnd

    function selectionKeys(): var {
        if (win.active === "tree")
            return win.cat ? ["menu:" + win.cat] : [];
        return win.pickedKeys.length > 0 ? win.pickedKeys : (win.focusKey ? [win.focusKey] : []);
    }

    function cutCopy(mode: string): void {
        const keys = win.selectionKeys().filter(k => !k.startsWith("sep:") && !(mode === "copy" && k.startsWith("menu:")));
        if (keys.length === 0)
            return;
        win.clip = { mode: mode, keys: keys, from: win.active === "tree" ? "" : win.cat };
        win.toast(mode === "cut" ? qsTr("Cut %n item(s)", "", keys.length) : qsTr("Copied %n item(s)", "", keys.length), false);
    }

    function paste(): void {
        if (!win.clip)
            return;
        win.dropInto(win.cat, win.clip.keys, win.clip.mode === "copy", win.clip.from);
        if (win.clip.mode === "cut")
            win.clip = null;
    }

    function dropInto(path: string, keys: var, copy: bool, from: string): void {
        let n = 0;
        for (const k of keys) {
            if (k.startsWith("app:")) {
                const id = k.slice(4);
                if (copy)
                    win.store.kdeAdd(id, path);
                else
                    win.store.kdeMove(id, path, from ? [from] : []);
                n++;
            } else if (k.startsWith("menu:") && !copy) {
                const p = k.slice(5);
                if (p !== path && !path.startsWith(p + "/")) {
                    win.store.menuMove(p, path);
                    n++;
                }
            }
        }
        if (n > 0)
            win.toast((copy ? qsTr("Added %n item(s) to %1", "", n) : qsTr("Moved %n item(s) to %1", "", n)).arg(path ? win.nodeName(path) : qsTr("the top level")), true);
    }

    function removeSelected(): void {
        const keys = win.selectionKeys();
        if (keys.length === 0)
            return;
        const seps = [];
        for (const k of keys) {
            if (k.startsWith("app:"))
                win.store.kdeRemove(k.slice(4), win.cat);
            else if (k.startsWith("menu:"))
                win.store.kdeDelete(k.slice(5));
            else if (k.startsWith("sep:"))
                seps.push(parseInt(k.slice(4)));
        }
        if (seps.length > 0)
            win.store.setLayout(win.cat, win.tokensOf(win.cat).filter((_, i) => !seps.includes(i)));
        win.picked = ({});
        win.focusKey = "";
        win.toast(qsTr("Removed %n item(s)", "", keys.length), true);
    }

    // ------------------------------------------------------- creation

    function newLauncher(): void {
        win.store.appNew(qsTr("New launcher"), win.cat, id => {
            win.pendingFocus = "app:" + id;
        });
    }

    function newCategory(inside: bool): void {
        const parent = inside ? win.cat : "";
        win.store.menuNew(qsTr("New category"), "folder", parent, path => {
            win.pendingFocus = "menu:" + path;
        });
    }

    Connections {
        function onKdeChanged(): void {
            if (!win.pendingFocus)
                return;
            const key = win.pendingFocus;
            win.pendingFocus = "";
            if (key.startsWith("menu:"))
                win.openCategory(key.slice(5));
            else
                win.select(key, 0);
            win.focusName = true;
        }

        target: win.store
    }

    // ---------------------------------------------------------- toast

    function toast(text: string, undoable: bool): void {
        win.snack = text;
        snackUndo.visible = undoable;
        snackTimer.restart();
    }

    Timer {
        id: snackTimer

        interval: 5000
        onTriggered: win.snack = ""
    }

    // ------------------------------------------------- context menus

    function rowMenu(r: var, x: real, y: real): void {
        if (!win.picked[r.key])
            win.select(r.key, 0);
        const many = win.pickedKeys.length > 1;
        const app = r.kind === "app" ? win.apps[r.id] : null;
        const acts = [];
        if (app && !many) {
            acts.push({ text: qsTr("Launch"), icon: "play_arrow", action: () => win.store.launch(app) });
            acts.push({ separator: true });
        }
        acts.push({ text: qsTr("Cut"), icon: "content_cut", shortcut: "Ctrl+X", enabled: r.kind !== "sep", action: () => win.cutCopy("cut") });
        acts.push({ text: qsTr("Copy"), icon: "content_copy", shortcut: "Ctrl+C", enabled: r.kind === "app", action: () => win.cutCopy("copy") });
        acts.push({ text: qsTr("Paste"), icon: "content_paste", shortcut: "Ctrl+V", enabled: !!win.clip && !win.search, action: () => win.paste() });
        acts.push({ separator: true });
        if (r.kind === "app") {
            acts.push({ text: qsTr("Move to…"), icon: "drive_file_move", action: () => win.pickCategory("move") });
            acts.push({ text: qsTr("Also show in…"), icon: "library_add", action: () => win.pickCategory("add") });
        }
        if (!win.search && !many) {
            acts.push({ text: qsTr("Move up"), icon: "arrow_upward", shortcut: "Alt+Up", action: () => win.moveRow(-1) });
            acts.push({ text: qsTr("Move down"), icon: "arrow_downward", shortcut: "Alt+Down", action: () => win.moveRow(1) });
            acts.push({ text: qsTr("Add separator below"), icon: "horizontal_rule", action: () => win.addSeparator() });
        }
        if (app && !many) {
            acts.push({ separator: true });
            acts.push({ text: app.noDisplay ? qsTr("Show") : qsTr("Hide"), icon: app.noDisplay ? "visibility" : "visibility_off", action: () => win.store.appSet(app.id, { noDisplay: !app.noDisplay }) });
            acts.push({ text: qsTr("Open containing folder"), icon: "folder_open", action: () => win.store.openFolder(app) });
            acts.push({ text: qsTr("Copy location"), icon: "link", action: () => win.store.copyLocation(app) });
            acts.push({ text: qsTr("Restore to default"), icon: "settings_backup_restore", visible: app.local && app.hasSystem, action: () => win.store.appReset(app.id) });
        }
        acts.push({ separator: true });
        if (app && !many && app.created)
            acts.push({ text: qsTr("Delete launcher"), icon: "delete_forever", danger: true, action: () => { win.store.appDelete(app.id); win.focusKey = ""; win.toast(qsTr("Deleted %1").arg(app.name), true); } });
        if (!win.search)
            acts.push({ text: r.kind === "menu" ? qsTr("Delete") : qsTr("Remove from %1").arg(win.cat ? win.nodeName(win.cat) : qsTr("menu")), icon: "delete", shortcut: "Del", danger: true, action: () => win.removeSelected() });
        popup.open(x, y, acts);
    }

    function treeMenu(path: string, x: real, y: real): void {
        win.openCategory(path);
        const n = win.nodes[path];
        popup.open(x, y, [
            { text: qsTr("New launcher here"), icon: "add_box", action: () => win.newLauncher() },
            { text: qsTr("New subcategory"), icon: "create_new_folder", action: () => win.newCategory(true) },
            { separator: true },
            { text: qsTr("Cut"), icon: "content_cut", shortcut: "Ctrl+X", action: () => win.cutCopy("cut") },
            { text: qsTr("Paste"), icon: "content_paste", shortcut: "Ctrl+V", enabled: !!win.clip, action: () => win.paste() },
            { separator: true },
            { text: qsTr("Move up"), icon: "arrow_upward", shortcut: "Alt+Up", action: () => win.moveRow(-1) },
            { text: qsTr("Move down"), icon: "arrow_downward", shortcut: "Alt+Down", action: () => win.moveRow(1) },
            { text: qsTr("Sort by name"), icon: "sort_by_alpha", action: () => win.store.sort(path, "name", false) },
            { text: qsTr("Sort by description"), icon: "sort", action: () => win.store.sort(path, "description", false) },
            { separator: true },
            { text: n?.hidden ? qsTr("Show") : qsTr("Hide"), icon: n?.hidden ? "visibility" : "visibility_off", action: () => win.store.kdeSet(path, { hidden: n?.hidden ? "0" : "1" }) },
            { text: qsTr("Restore to default"), icon: "settings_backup_restore", visible: !!n?.hasOverride, action: () => win.store.kdeResetDir(path) },
            { text: qsTr("Delete"), icon: "delete", danger: true, shortcut: "Del", action: () => win.removeSelected() }
        ]);
    }

    function newMenu(x: real, y: real): void {
        popup.open(x, y, [
            { text: qsTr("New launcher"), icon: "add_box", shortcut: "Ctrl+N", action: () => win.newLauncher() },
            { text: qsTr("New category"), icon: "create_new_folder", shortcut: "Ctrl+Shift+N", action: () => win.newCategory(false) },
            { text: qsTr("New subcategory"), icon: "subdirectory_arrow_right", enabled: !!win.cat, action: () => win.newCategory(true) },
            { text: qsTr("New separator"), icon: "horizontal_rule", enabled: !win.search, action: () => win.addSeparator() }
        ]);
    }

    function moreMenu(x: real, y: real): void {
        popup.open(x, y, [
            { text: qsTr("Sort all by name"), icon: "sort_by_alpha", action: () => win.store.sort("", "name", true) },
            { text: qsTr("Sort all by description"), icon: "sort", action: () => win.store.sort("", "description", true) },
            { separator: true },
            { text: qsTr("Launcher icons: Material"), icon: LauncherCustomizer.iconStyle === "material" ? "radio_button_checked" : "radio_button_unchecked", action: () => win.store.setIconStyle("material") },
            { text: qsTr("Launcher icons: icon theme"), icon: LauncherCustomizer.iconStyle === "theme" ? "radio_button_checked" : "radio_button_unchecked", action: () => win.store.setIconStyle("theme") },
            { separator: true },
            { text: qsTr("Open KDE Menu Editor"), icon: "open_in_new", action: () => win.store.openKMenuEdit() },
            { text: qsTr("Restore to system menu…"), icon: "restart_alt", danger: true, action: () => win.store.restorePreview(files => {
                    confirm.count = files.length;
                    confirm.visible = true;
                }) }
        ]);
    }

    property string pickMode: ""

    function pickCategory(mode: string): void {
        win.pickMode = mode;
        const rows = [];
        const walk = (list, depth) => {
            for (const n of list) {
                const ic = LauncherCustomizer.kdeIcon(n);
                rows.push({ key: n.path, name: n.name, icon: ic.icon, iconSource: ic.iconSource, depth: depth, hidden: n.hidden });
                walk(n.children, depth + 1);
            }
        };
        walk(win.kd.categories ?? [], 0);
        catPicker.rows = rows;
        const n = win.selectionKeys().filter(k => k.startsWith("app:")).length;
        catPicker.open(mode === "move" ? qsTr("Move %n item(s) to", "", n) : qsTr("Also show %n item(s) in", "", n), "", []);
    }

    // ---------------------------------------------------------- window

    title: qsTr("Launcher Customizer")
    color: Colours.palette.m3surface
    implicitWidth: 1360
    implicitHeight: 860
    minimumSize.width: 1100
    minimumSize.height: 640

    onTreeRowsChanged: {
        if (win.cat && !win.nodes[win.cat])
            win.cat = "";
        if (!win.cat && win.treeRows.length > 0 && !win.search)
            win.cat = win.treeRows[0].path;
    }

    function focusApp(appId: string): void {
        const m = win.membership[appId] ?? [];
        if (m.length > 0)
            win.openCategory(m[0]);
        win.select("app:" + appId, 0);
    }

    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (popup.visible)
                popup.close();
            else if (iconPicker.visible)
                iconPicker.close();
            else if (catPicker.visible)
                catPicker.close();
            else if (confirm.visible)
                confirm.visible = false;
            else if (win.search) {
                searchField.text = "";
                win.search = "";
            } else
                win.visible = false;
        }
    }
    Shortcut { sequences: [StandardKey.Find]; onActivated: searchField.forceActiveFocus() }
    Shortcut { sequences: [StandardKey.Undo]; enabled: !win.typing; onActivated: win.store.kdeUndo() }
    Shortcut { sequence: "Ctrl+N"; onActivated: win.newLauncher() }
    Shortcut { sequence: "Ctrl+Shift+N"; onActivated: win.newCategory(false) }
    Shortcut { sequences: [StandardKey.Cut]; enabled: !win.typing; onActivated: win.cutCopy("cut") }
    Shortcut { sequences: [StandardKey.Copy]; enabled: !win.typing; onActivated: win.cutCopy("copy") }
    Shortcut { sequences: [StandardKey.Paste]; enabled: !win.typing; onActivated: win.paste() }
    Shortcut { sequence: "Delete"; enabled: !win.typing; onActivated: win.removeSelected() }
    Shortcut { sequence: "Alt+Up"; onActivated: win.moveRow(-1) }
    Shortcut { sequence: "Alt+Down"; onActivated: win.moveRow(1) }
    Shortcut { sequence: "F2"; onActivated: win.focusName = true }

    // ================================================================ UI

    Item {
        id: rootItem

        anchors.fill: parent

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.medium

            // ------------------------------------------------------ header
            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                StyledText {
                    text: qsTr("Launcher Customizer")
                    font: Tokens.font.title.large
                }

                Item {
                    Layout.fillWidth: true
                }

                StyledTextField {
                    id: searchField

                    Layout.preferredWidth: 360
                    leadingIcon: "search"
                    placeholderText: qsTr("Search apps")
                    onTextChanged: {
                        win.search = text;
                        win.picked = ({});
                    }
                }

                StyledText {
                    text: qsTr("Show hidden")
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.large
                }

                StyledSwitch {
                    checked: win.showHidden
                    onToggled: win.showHidden = checked
                }

                IconButton {
                    icon: "undo"
                    type: IconButton.Tonal
                    disabled: !(win.kd.canUndo ?? false)
                    onClicked: win.store.kdeUndo()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Undo (Ctrl+Z)")
                }

                IconButton {
                    id: moreBtn

                    icon: "more_vert"
                    type: IconButton.Tonal
                    onClicked: {
                        const p = moreBtn.mapToItem(rootItem, moreBtn.width, moreBtn.height + 4);
                        win.moreMenu(p.x - 260, p.y);
                    }
                }
            }

            // ------------------------------------------------------- panes
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Tokens.spacing.medium

                // ============================================== tree
                StyledRect {
                    Layout.preferredWidth: 290
                    Layout.fillHeight: true
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.small

                            TextButton {
                                id: newBtn

                                Layout.fillWidth: true
                                text: qsTr("New")
                                onClicked: {
                                    const p = newBtn.mapToItem(rootItem, 0, newBtn.height + 4);
                                    win.newMenu(p.x, p.y);
                                }
                            }

                            IconButton {
                                icon: "arrow_upward"
                                type: IconButton.Text
                                disabled: !win.cat
                                onClicked: {
                                    win.active = "tree";
                                    win.moveRow(-1);
                                }
                            }

                            IconButton {
                                icon: "arrow_downward"
                                type: IconButton.Text
                                disabled: !win.cat
                                onClicked: {
                                    win.active = "tree";
                                    win.moveRow(1);
                                }
                            }
                        }

                        ListView {
                            id: tree

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 2
                            model: win.treeRows
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar {
                                flickable: tree
                            }

                            delegate: StyledRect {
                                id: tRow

                                required property var modelData
                                readonly property var n: modelData.node
                                readonly property bool sel: win.cat === n.path && !win.search
                                readonly property var ic: LauncherCustomizer.kdeIcon(n)

                                width: tree.width
                                implicitHeight: 40
                                radius: Tokens.rounding.medium
                                color: tDrop.containsDrag ? Colours.palette.m3primaryContainer : (sel ? Colours.palette.m3secondaryContainer : (tMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : "transparent"))
                                opacity: n.hidden ? 0.55 : 1

                                DropArea {
                                    id: tDrop

                                    anchors.fill: parent
                                    keys: ["lc-items"]
                                    onDropped: drop => {
                                        win.dropInto(tRow.n.path, ghost.keys, (drop.modifiers & Qt.ControlModifier) !== 0, win.cat);
                                        drop.accept();
                                    }
                                }

                                MouseArea {
                                    id: tMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) {
                                            const p = mapToItem(rootItem, mouse.x, mouse.y);
                                            win.treeMenu(tRow.n.path, p.x, p.y);
                                        } else {
                                            win.openCategory(tRow.n.path);
                                        }
                                    }
                                    onDoubleClicked: {
                                        const e = Object.assign({}, win.expanded);
                                        e[tRow.n.path] = !e[tRow.n.path];
                                        win.expanded = e;
                                    }
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 4 + tRow.modelData.depth * 18
                                    anchors.rightMargin: Tokens.padding.medium
                                    spacing: Tokens.spacing.small

                                    MaterialIcon {
                                        text: tRow.modelData.open ? "expand_more" : "chevron_right"
                                        opacity: tRow.n.children.length > 0 ? 1 : 0
                                        color: Colours.palette.m3onSurfaceVariant
                                        fontStyle: Tokens.font.icon.small

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            enabled: tRow.n.children.length > 0
                                            onClicked: {
                                                const e = Object.assign({}, win.expanded);
                                                e[tRow.n.path] = !e[tRow.n.path];
                                                win.expanded = e;
                                            }
                                        }
                                    }

                                    CategoryIcon {
                                        icon: tRow.ic.icon
                                        iconSource: tRow.ic.iconSource
                                        size: 20
                                        color: tRow.sel ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: tRow.n.name
                                        elide: Text.ElideRight
                                        color: tRow.sel ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                                        font: Tokens.font.label.large
                                    }

                                    StyledText {
                                        text: String(tRow.n.allApps.length)
                                        visible: tRow.n.allApps.length > 0
                                        color: Colours.palette.m3onSurfaceVariant
                                        font: Tokens.font.label.medium
                                    }
                                }
                            }
                        }
                    }
                }

                // ============================================== contents
                StyledRect {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Tokens.padding.small
                            spacing: Tokens.spacing.small

                            StyledText {
                                Layout.fillWidth: true
                                text: win.search ? qsTr("Results") : (win.cat ? win.nodeName(win.cat) : qsTr("Menu"))
                                elide: Text.ElideRight
                                font: Tokens.font.title.medium
                            }

                            StyledText {
                                text: String(win.rows.filter(r => r.kind === "app").length)
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.large
                            }

                            Item {
                                implicitWidth: Tokens.spacing.small
                            }

                            IconButton {
                                id: sortBtn

                                icon: "sort_by_alpha"
                                type: IconButton.Text
                                disabled: !win.cat || !!win.search
                                onClicked: {
                                    const p = sortBtn.mapToItem(rootItem, 0, sortBtn.height + 4);
                                    popup.open(p.x - 160, p.y, [
                                        { text: qsTr("Sort by name"), icon: "sort_by_alpha", action: () => win.store.sort(win.cat, "name", false) },
                                        { text: qsTr("Sort by description"), icon: "sort", action: () => win.store.sort(win.cat, "description", false) }
                                    ]);
                                }
                                ToolTip.visible: hovered
                                ToolTip.delay: 600
                                ToolTip.text: qsTr("Sort")
                            }

                            IconButton {
                                icon: "arrow_upward"
                                type: IconButton.Text
                                disabled: !win.focusKey || !!win.search || win.active !== "list"
                                onClicked: win.moveRow(-1)
                            }

                            IconButton {
                                icon: "arrow_downward"
                                type: IconButton.Text
                                disabled: !win.focusKey || !!win.search || win.active !== "list"
                                onClicked: win.moveRow(1)
                            }

                            IconButton {
                                icon: "content_cut"
                                type: IconButton.Text
                                disabled: win.pickedKeys.length === 0 && !win.focusKey
                                onClicked: win.cutCopy("cut")
                            }

                            IconButton {
                                icon: "content_copy"
                                type: IconButton.Text
                                disabled: win.pickedKeys.length === 0 && !win.focusKey
                                onClicked: win.cutCopy("copy")
                            }

                            IconButton {
                                icon: "content_paste"
                                type: IconButton.Text
                                disabled: !win.clip || !!win.search
                                onClicked: win.paste()
                            }
                        }

                        ListView {
                            id: list

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 2
                            model: win.rows
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar {
                                flickable: list
                            }

                            StyledText {
                                anchors.centerIn: parent
                                visible: win.rows.length === 0
                                text: win.search ? qsTr("No apps found") : qsTr("Empty")
                                color: Colours.palette.m3onSurfaceVariant
                            }

                            delegate: StyledRect {
                                id: row

                                required property var modelData
                                readonly property string kind: modelData.kind
                                readonly property var app: kind === "app" ? win.apps[modelData.id] : null
                                readonly property var menuNode: kind === "menu" ? win.nodes[modelData.path] : null
                                readonly property bool sel: !!win.picked[modelData.key]
                                readonly property bool isFocus: win.focusKey === modelData.key

                                width: list.width
                                implicitHeight: kind === "sep" ? 22 : 54
                                radius: Tokens.rounding.medium
                                color: rDrop.containsDrag && kind === "menu" ? Colours.palette.m3primaryContainer : (sel ? Colours.palette.m3secondaryContainer : (rMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : "transparent"))
                                opacity: (row.app?.noDisplay || row.menuNode?.hidden) ? 0.55 : 1

                                Rectangle {
                                    visible: rDrop.containsDrag && row.kind !== "menu"
                                    anchors.top: parent.top
                                    width: parent.width
                                    height: 2
                                    color: Colours.palette.m3primary
                                }

                                DropArea {
                                    id: rDrop

                                    anchors.fill: parent
                                    keys: ["lc-items"]
                                    enabled: !win.search
                                    onDropped: drop => {
                                        if (row.kind === "menu" && !ghost.keys.includes(row.modelData.key))
                                            win.dropInto(row.modelData.path, ghost.keys, (drop.modifiers & Qt.ControlModifier) !== 0, win.cat);
                                        else
                                            win.reorderTo(ghost.keys, row.modelData.key);
                                        drop.accept();
                                    }
                                }

                                MouseArea {
                                    id: rMouse

                                    property point pressAt

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    drag.target: row.kind === "sep" && win.search ? null : ghost
                                    drag.threshold: 8

                                    onPressed: mouse => {
                                        pressAt = Qt.point(mouse.x, mouse.y);
                                        const p = mapToItem(rootItem, mouse.x, mouse.y);
                                        ghost.x = p.x + 12;
                                        ghost.y = p.y + 8;
                                    }
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton) {
                                            const p = mapToItem(rootItem, mouse.x, mouse.y);
                                            win.rowMenu(row.modelData, p.x, p.y);
                                        } else {
                                            win.select(row.modelData.key, mouse.modifiers);
                                        }
                                    }
                                    onDoubleClicked: {
                                        if (row.kind === "menu")
                                            win.openCategory(row.modelData.path);
                                        else if (row.kind === "app")
                                            win.focusName = true;
                                    }
                                    drag.onActiveChanged: {
                                        if (drag.active) {
                                            if (!win.picked[row.modelData.key])
                                                win.select(row.modelData.key, 0);
                                            ghost.keys = win.pickedKeys.slice();
                                            ghost.label = ghost.keys.length > 1 ? qsTr("%n items", "", ghost.keys.length) : (row.app?.name ?? row.menuNode?.name ?? qsTr("Separator"));
                                            win.dragging = true;
                                        } else {
                                            ghost.Drag.drop();
                                            win.dragging = false;
                                        }
                                    }
                                }

                                // separator
                                Rectangle {
                                    visible: row.kind === "sep"
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.margins: Tokens.padding.large
                                    height: row.isFocus ? 2 : 1
                                    color: row.isFocus ? Colours.palette.m3primary : Colours.palette.m3outlineVariant
                                }

                                RowLayout {
                                    visible: row.kind !== "sep"
                                    anchors.fill: parent
                                    anchors.leftMargin: Tokens.padding.medium
                                    anchors.rightMargin: Tokens.padding.medium
                                    spacing: Tokens.spacing.medium

                                    Item {
                                        implicitWidth: 32
                                        implicitHeight: 32

                                        IconImage {
                                            anchors.fill: parent
                                            visible: row.kind === "app"
                                            asynchronous: true
                                            source: row.app ? (LauncherCustomizer.imageFor(row.app.icon) || Quickshell.iconPath("application-x-executable")) : ""
                                        }

                                        CategoryIcon {
                                            anchors.centerIn: parent
                                            visible: row.kind === "menu"
                                            readonly property var ic: row.menuNode ? LauncherCustomizer.kdeIcon(row.menuNode) : ({ icon: "folder", iconSource: "" })
                                            icon: ic.icon
                                            iconSource: ic.iconSource
                                            size: 26
                                            color: Colours.palette.m3primary
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: row.app?.name ?? row.menuNode?.name ?? ""
                                            elide: Text.ElideRight
                                            font: Tokens.font.label.large
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: {
                                                if (row.kind === "menu")
                                                    return qsTr("%n app(s)", "", row.menuNode?.allApps.length ?? 0);
                                                if (win.search)
                                                    return (win.membership[row.modelData.id] ?? []).map(p => win.nodeName(p)).join(" · ") || qsTr("Lost & Found");
                                                return row.app?.genericName || row.app?.comment || "";
                                            }
                                            visible: text.length > 0
                                            elide: Text.ElideRight
                                            color: Colours.palette.m3onSurfaceVariant
                                            font: Tokens.font.body.small
                                        }
                                    }

                                    Chip {
                                        visible: !!row.app?.shortcut
                                        text: row.app?.shortcut ?? ""
                                        icon: "keyboard"
                                    }

                                    Chip {
                                        visible: !!(row.app?.noDisplay || row.menuNode?.hidden)
                                        text: qsTr("Hidden")
                                        icon: "visibility_off"
                                    }

                                    Chip {
                                        visible: !!(win.clip && win.clip.mode === "cut" && win.clip.keys.includes(row.modelData.key))
                                        text: qsTr("Cut")
                                        icon: "content_cut"
                                    }
                                }
                            }
                        }
                    }
                }

                // ============================================== properties
                StyledRect {
                    Layout.preferredWidth: 420
                    Layout.fillHeight: true
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    Properties {
                        anchors.fill: parent
                        editor: win
                        store: win.store
                    }
                }
            }
        }

        // drag ghost
        StyledRect {
            id: ghost

            property var keys: []
            property string label: ""

            visible: win.dragging
            width: ghostText.implicitWidth + Tokens.padding.large * 2
            height: 34
            radius: Tokens.rounding.full
            color: Colours.palette.m3primary
            z: 150
            Drag.active: win.dragging
            Drag.keys: ["lc-items"]
            Drag.hotSpot: Qt.point(0, 0)

            StyledText {
                id: ghostText

                anchors.centerIn: parent
                text: ghost.label
                color: Colours.palette.m3onPrimary
                font: Tokens.font.label.large
            }
        }

        // undo toast
        StyledRect {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Tokens.padding.large * 2
            visible: win.snack.length > 0
            width: snackRow.implicitWidth + Tokens.padding.large * 2
            height: 48
            radius: Tokens.rounding.full
            color: Colours.palette.m3inverseSurface
            z: 120

            RowLayout {
                id: snackRow

                anchors.centerIn: parent
                spacing: Tokens.spacing.medium

                StyledText {
                    text: win.snack
                    color: Colours.palette.m3inverseOnSurface
                    font: Tokens.font.body.medium
                }

                TextButton {
                    id: snackUndo

                    text: qsTr("Undo")
                    type: TextButton.Text
                    label.color: Colours.palette.m3inversePrimary
                    onClicked: {
                        win.store.kdeUndo();
                        win.snack = "";
                    }
                }
            }
        }

        // restore confirmation
        Item {
            id: confirm

            property int count: 0

            anchors.fill: parent
            visible: false
            z: 180

            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(Colours.palette.m3scrim, 0.45)

                MouseArea {
                    anchors.fill: parent
                    onClicked: confirm.visible = false
                }
            }

            StyledRect {
                anchors.centerIn: parent
                width: 440
                height: confirmCol.implicitHeight + Tokens.padding.large * 2
                radius: Tokens.rounding.extraLarge
                color: Colours.palette.m3surfaceContainerHigh

                ColumnLayout {
                    id: confirmCol

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.large
                    spacing: Tokens.spacing.medium

                    StyledText {
                        text: qsTr("Restore the system menu?")
                        font: Tokens.font.title.medium
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: qsTr("Removes your custom categories, launchers and changes (%n file(s)). You can still undo it.", "", confirm.count)
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignRight

                        TextButton {
                            text: qsTr("Cancel")
                            type: TextButton.Text
                            onClicked: confirm.visible = false
                        }

                        TextButton {
                            text: qsTr("Restore")
                            onClicked: {
                                confirm.visible = false;
                                win.store.restoreSystem();
                                win.cat = "";
                                win.focusKey = "";
                                win.toast(qsTr("System menu restored"), true);
                            }
                        }
                    }
                }
            }
        }

        MenuPopup {
            id: popup
        }

        CategoryPicker {
            id: catPicker

            onPicked: key => {
                catPicker.close();
                const keys = win.selectionKeys().filter(k => k.startsWith("app:"));
                win.dropInto(key, keys, win.pickMode === "add", win.search ? "" : win.cat);
            }
        }

        IconPicker {
            id: iconPicker

            property string target: ""

            store: win.store
            allowDefault: false
            onPicked: choice => {
                iconPicker.close();
                if (iconPicker.target.startsWith("app:"))
                    win.store.appSetIcon(iconPicker.target.slice(4), choice);
                else if (iconPicker.target.startsWith("menu:"))
                    win.store.kdeSetIcon(iconPicker.target.slice(5), choice);
            }
        }
    }

    function pickIcon(key: string, kind: string): void {
        iconPicker.target = key;
        iconPicker.allowDefault = key.startsWith("menu:");
        iconPicker.open(kind);
    }

    component Chip: StyledRect {
        id: chipRoot

        property string text
        property string icon

        implicitWidth: chipRow.implicitWidth + Tokens.padding.medium * 2
        implicitHeight: 26
        radius: Tokens.rounding.full
        color: Colours.palette.m3surfaceContainerHighest

        RowLayout {
            id: chipRow

            anchors.centerIn: parent
            spacing: 4

            MaterialIcon {
                text: chipRoot.icon
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.small
            }

            StyledText {
                text: chipRoot.text
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
            }
        }
    }
}
