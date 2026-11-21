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
import qs.components.containers
import qs.services
import qs.modules.launcher.services
import "."

// Launcher Customizer: everything KDE's Menu Editor does, synced with KDE.
// Shown as a page in Settings (Panels & Interface -> Launcher). Nothing is
// written until Save; leaving with unsaved changes asks first.
Item {
    id: win

    property var store: null
    // Narrow Settings window: the list and the details take turns.
    readonly property bool narrow: win.width < 940
    property bool detailsShown: false
    // An app to show once the menu is loaded (App info from the launcher).
    property string appToFocus: ""

    // ------------------------------------------------------------- state

    property string cat: ""                 // selected category (any level)
    // The page in the middle pane: always a top-level category. Subcategories
    // never get a page of their own; they unfold inside their top-level one.
    readonly property string page: win.cat.split("/")[0]
    property string active: "list"          // pane keyboard actions apply to: tree | list
    property var picked: ({})               // selected rows in the middle pane
    property string focusKey: ""            // item in the properties pane: app:<id> | menu:<path> | sep:<n>
    property string anchorKey: ""
    property bool showHidden: false
    property string search: ""
    property var expanded: ({})
    property var listOpen: ({})             // subcategories unfolded in the middle pane
    property var clip: null                 // { mode: cut|copy, keys, from }
    property string pendingFocus: ""
    property bool focusName: false
    property string snack: ""
    property bool dragging: false
    property bool hoveringEye: false

    readonly property var kd: win.store?.view ?? ({})
    readonly property bool canUndo: !!(win.kd.staged && win.kd.canUndo)
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
    readonly property bool typing: !!(win.Window.activeFocusItem && win.Window.activeFocusItem.selectedText !== undefined)

    function nodeName(path: string): string {
        return win.nodes[path]?.name ?? path.split("/").pop();
    }

    function appVisible(id: string): bool {
        const a = win.apps[id];
        return !!a && (win.showHidden || !win.store.appHidden(a));
    }

    function menuVisible(path: string): bool {
        const n = win.nodes[path];
        return !!n && (win.showHidden || !n.hidden);
    }

    // ------------------------------------------------------------ tree

    // Categories with their subcategories and apps, in KDE's order. Each row
    // has a stable key so the list can animate what changed.
    readonly property var treeRows: {
        const out = [];
        const walk = (path, depth) => {
            for (const it of win.itemsOf(path)) {
                if (it.kind === "menu") {
                    const n = win.nodes[it.path];
                    if (!n || (!win.showHidden && n.hidden))
                        continue;
                    out.push({ key: "m:" + n.path, kind: "menu", path: n.path, depth: depth });
                    if (win.expanded[n.path])
                        walk(n.path, depth + 1);
                } else if (it.kind === "app" && path && win.appVisible(it.id)) {
                    out.push({ key: "a:" + path + "/" + it.id, kind: "app", id: it.id, parent: path, depth: depth });
                }
            }
        };
        walk("", 0);
        return out;
    }

    /// Whether a category has anything to unfold in the tree.
    function hasContent(path: string): bool {
        return win.itemsOf(path).some(it => (it.kind === "menu" && win.menuVisible(it.path)) || (it.kind === "app" && win.appVisible(it.id)));
    }

    function toggleExpand(path: string): void {
        const e = Object.assign({}, win.expanded);
        e[path] = !e[path];
        win.expanded = e;
    }

    function toggleHidden(key: string): void {
        if (key.startsWith("app:")) {
            const a = win.apps[key.slice(4)];
            if (a)
                win.store.setAppHidden(a, !win.store.appHidden(a));
        } else if (key.startsWith("menu:")) {
            const n = win.nodes[key.slice(5)];
            if (n)
                win.store.kdeSet(n.path, { hidden: n.hidden ? "0" : "1" });
        }
    }

    function openCategory(path: string): void {
        if (path.split("/")[0] !== win.page)
            win.swapList();
        const e = Object.assign({}, win.expanded);
        const o = Object.assign({}, win.listOpen);
        const parts = path.split("/");
        for (let i = 1; i < parts.length; i++)
            e[parts.slice(0, i).join("/")] = true;
        // A subcategory opens its top-level page, unfolded down to it.
        for (let i = 2; i <= parts.length; i++)
            o[parts.slice(0, i).join("/")] = true;
        win.expanded = e;
        win.listOpen = o;
        win.cat = path;
        win.search = "";
        searchField.text = "";
        win.picked = parts.length > 1 ? { ["menu:" + path]: true } : ({});
        win.focusKey = "menu:" + path;
        win.active = "tree";
    }

    // ----------------------------------------------------- list (middle)

    function itemsOf(path: string): var {
        return path ? (win.nodes[path]?.items ?? []) : (win.kd.rootItems ?? []);
    }

    function keyOf(it: var, i: int, parent: string): string {
        return it.kind === "app" ? "app:" + it.id : (it.kind === "menu" ? "menu:" + it.path : "sep:" + (parent ?? win.page) + "|" + i);
    }

    /// The category a selected row sits in (subcategories can be unfolded inline).
    function parentOf(key: string): string {
        return win.rows.find(r => r.key === key)?.parent ?? win.page;
    }

    function fromsOf(keys: var): var {
        const m = {};
        for (const k of keys)
            m[k] = win.search ? "" : win.parentOf(k);
        return m;
    }

    function toggleListOpen(path: string): void {
        const o = Object.assign({}, win.listOpen);
        o[path] = !o[path];
        win.listOpen = o;
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
                    out.push({ kind: "app", id: id, key: "app:" + id, rowKey: "app:" + id, parent: "", depth: 0 });
            }
            out.sort((x, y) => String(win.apps[x.id].name).localeCompare(String(win.apps[y.id].name)));
            return out;
        }
        // The category's items in KDE order; unfolded subcategories show
        // their own items right below them, indented.
        const out = [];
        const walk = (path, depth) => {
            const items = win.itemsOf(path);
            for (let i = 0; i < items.length; i++) {
                const it = items[i];
                // KDE's separators are kept in its files but not shown here.
                if (it.kind === "sep")
                    continue;
                if (it.kind === "app" && !win.appVisible(it.id))
                    continue;
                if (it.kind === "menu" && !win.menuVisible(it.path))
                    continue;
                const key = win.keyOf(it, i, path);
                out.push(Object.assign({ key: key, rowKey: key + "@" + path, index: i, parent: path, depth: depth }, it));
                if (it.kind === "menu" && win.listOpen[it.path])
                    walk(it.path, depth + 1);
            }
        };
        walk(win.page, 0);
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
        const r = win.rows.find(x => x.key === win.focusKey);
        if (!r)
            return;
        // Only among the items of the same (sub)category.
        const sib = win.rows.filter(x => x.parent === r.parent);
        const p = sib.indexOf(r);
        const q = p + delta;
        if (p < 0 || q < 0 || q >= sib.length)
            return;
        win.moveToken(r.parent, r.index, sib[q].index);
        if (r.kind === "sep")
            win.focusKey = "sep:" + r.parent + "|" + sib[q].index;
        win.picked = { [win.focusKey]: true };
    }

    function reorderTo(dragKeys: var, targetKey: string): void {
        const parent = win.parentOf(targetKey);
        const items = win.itemsOf(parent);
        const t = win.tokensOf(parent);
        const keys = items.map((it, i) => win.keyOf(it, i, parent));
        const moving = keys.map((k, i) => dragKeys.includes(k) ? i : -1).filter(i => i >= 0);
        if (moving.length === 0)
            return;
        const target = keys.indexOf(targetKey);
        const take = moving.map(i => t[i]);
        const rest = t.filter((_, i) => !moving.includes(i));
        const before = target < 0 ? rest.length : rest.indexOf(t[target]);
        rest.splice(before < 0 ? rest.length : before, 0, ...take);
        win.store.setLayout(parent, rest);
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
        const froms = {};
        for (const k of keys)
            froms[k] = win.active === "tree" ? "" : win.parentOf(k);
        win.clip = { mode: mode, keys: keys, from: froms };
        win.toast(mode === "cut" ? qsTr("Cut %1").arg(win.items(keys.length)) : qsTr("Copied %1").arg(win.items(keys.length)), false);
    }

    function paste(): void {
        if (!win.clip)
            return;
        win.dropInto(win.cat, win.clip.keys, win.clip.mode === "copy", win.clip.from);
        if (win.clip.mode === "cut")
            win.clip = null;
    }

    /// from: the category each key comes from ({ key: path }) or one path for all.
    function dropInto(path: string, keys: var, copy: bool, from: var): void {
        let n = 0;
        for (const k of keys) {
            const f = typeof from === "string" ? from : (from?.[k] ?? "");
            if (k.startsWith("app:")) {
                const id = k.slice(4);
                if (copy)
                    win.store.kdeAdd(id, path);
                else
                    win.store.kdeMove(id, path, f ? [f] : []);
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
            win.toast((copy ? qsTr("Added %1 to %2") : qsTr("Moved %1 to %2")).arg(win.items(n)).arg(path ? win.nodeName(path) : qsTr("the top level")), true);
    }

    function removeSelected(): void {
        const keys = win.selectionKeys();
        if (keys.length === 0)
            return;
        const seps = {};
        for (const k of keys) {
            if (k.startsWith("app:"))
                win.store.kdeRemove(k.slice(4), win.parentOf(k));
            else if (k.startsWith("menu:"))
                win.store.kdeDelete(k.slice(5));
            else if (k.startsWith("sep:")) {
                const [path, i] = k.slice(4).split("|");
                (seps[path] = seps[path] || []).push(parseInt(i));
            }
        }
        for (const path of Object.keys(seps))
            win.store.setLayout(path, win.tokensOf(path).filter((_, i) => !seps[path].includes(i)));
        win.picked = ({});
        win.focusKey = "";
        win.toast(qsTr("Removed %1").arg(win.items(keys.length)), true);
    }

    // ------------------------------------------------------- creation

    function newLauncher(): void {
        const where = win.cat;
        win.store.appNew(qsTr("New launcher"), where, id => {
            win.revealNew("app:" + id);
            win.toast(where ? qsTr("New launcher added to %1: name it and set its program").arg(win.nodeName(where)) : qsTr("New launcher added: name it and set its program"), true);
        });
    }

    function newCategory(inside: bool): void {
        const parent = inside ? win.cat : "";
        win.store.menuNew(qsTr("New category"), "folder", parent, path => {
            win.revealNew("menu:" + path);
            win.toast(parent ? qsTr("New subcategory added to %1").arg(win.nodeName(parent)) : qsTr("New category added as the last tab"), true);
        });
    }

    /// Called once the menu with the new item is loaded.
    function revealNew(key: string): void {
        win.pendingFocus = key;
        revealTimer.restart();
    }

    Timer {
        id: revealTimer

        interval: 1
        onTriggered: {
            if (!win.pendingFocus)
                return;
            const key = win.pendingFocus;
            win.pendingFocus = "";
            // Show what was made: selected, in view, its details open with the
            // name ready to type.
            if (key.startsWith("menu:")) {
                win.openCategory(key.slice(5));
                win.focusKey = key;
            } else {
                win.select(key, 0);
            }
            win.scrollToKey(key);
            win.detailsShown = true;
            // Once the details have slid in (focus cannot go to a hidden field).
            nameFocusTimer.restart();
        }
    }

    Timer {
        id: nameFocusTimer

        interval: 450
        onTriggered: win.focusName = true
    }

    // ---------------------------------------------------------- toast

    function toast(text: string, undoable: bool): void {
        win.snack = text;
        snackBar.text = text;
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
        if (r.kind === "menu" && !many) {
            acts.push({ text: win.listOpen[r.path] ? qsTr("Fold") : qsTr("Unfold"), icon: win.listOpen[r.path] ? "unfold_less" : "unfold_more", action: () => win.toggleListOpen(r.path) });
            acts.push({ text: qsTr("Open"), icon: "folder_open", action: () => win.openCategory(r.path) });
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
        }
        if (app && !many) {
            acts.push({ separator: true });
            const hid = win.store.appHidden(app);
            acts.push({ text: hid ? qsTr("Show") : qsTr("Hide"), icon: hid ? "visibility" : "visibility_off", action: () => win.store.setAppHidden(app, !hid) });
            if (r.parent) {
                const pinned = win.store.pinned("kde:" + r.parent, app.id);
                acts.push({ text: pinned ? qsTr("Unpin from top") : qsTr("Pin to top"), icon: "vertical_align_top", action: () => win.store.pin("kde:" + r.parent, app.id, !pinned) });
            }
            acts.push({ text: qsTr("Open containing folder"), icon: "folder_open", action: () => win.store.openFolder(app) });
            acts.push({ text: qsTr("Copy location"), icon: "link", action: () => win.store.copyLocation(app) });
            acts.push({ text: qsTr("Restore to default"), icon: "settings_backup_restore", visible: app.local && app.hasSystem, action: () => win.store.appReset(app.id) });
        }
        acts.push({ separator: true });
        if (app && !many && app.created)
            acts.push({ text: qsTr("Delete launcher"), icon: "delete_forever", danger: true, action: () => { win.store.appDelete(app.id); win.focusKey = ""; win.toast(qsTr("Deleted %1").arg(app.name), true); } });
        if (!win.search)
            acts.push({ text: r.kind === "menu" ? qsTr("Delete") : qsTr("Remove from %1").arg(win.parentOf(r.key) ? win.nodeName(win.parentOf(r.key)) : qsTr("menu")), icon: "delete", shortcut: "Del", danger: true, action: () => win.removeSelected() });
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
            { text: qsTr("New subcategory"), icon: "subdirectory_arrow_right", enabled: !!win.cat, action: () => win.newCategory(true) }
        ]);
    }

    function moreMenu(x: real, y: real): void {
        popup.open(x, y, [
            { text: qsTr("Sort all by name"), icon: "sort_by_alpha", action: () => win.store.sort("", "name", true) },
            { text: qsTr("Sort all by description"), icon: "sort", action: () => win.store.sort("", "description", true) },
            { separator: true },
            { text: qsTr("Export layout…"), icon: "upload", action: () => win.store.exportLayout() },
            { text: qsTr("Import layout…"), icon: "download", action: () => win.store.importLayout() },
            { separator: true },
            { text: qsTr("Open KDE Menu Editor"), icon: "open_in_new", action: () => win.store.openKMenuEdit() },
            { text: qsTr("Restore to system menu…"), icon: "restart_alt", danger: true, action: () => win.store.restorePreview(files => {
                    confirm.count = files.length;
                    confirm.shown = true;
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
        catPicker.open(mode === "move" ? qsTr("Move %1 to").arg(win.items(n)) : qsTr("Also show %1 in").arg(win.items(n)), "", []);
    }

    // ------------------------------------------------------------ page

    function plural(n: int, one: string, many: string): string {
        return n === 1 ? one : many.arg(n);
    }

    function items(n: int): string {
        return win.plural(n, qsTr("1 item"), qsTr("%1 items"));
    }

    // Switching tabs or searching swaps the whole list: no row animations then
    // (half-finished ones could leave a row behind).
    property bool switching: false

    onSearchChanged: {
        win.swapList();
        win.slideListIn(0);
    }

    // Switching tabs: the list slides in from the side of the new tab, the
    // way Settings switches its pages.
    property string lastPage: ""
    readonly property int movement: Tokens.padding.extraExtraLarge * 2

    onPageChanged: {
        win.swapList();
        const from = win.tabs.findIndex(t => t.path === win.lastPage);
        const to = win.tabs.findIndex(t => t.path === win.page);
        if (win.lastPage && from >= 0 && to >= 0 && from !== to)
            win.slideListIn(to > from ? 1 : -1);
        win.lastPage = win.page;
        Qt.callLater(() => tabStrip.reveal(win.page));
    }

    function slideListIn(dir: int): void {
        if (!win.ready)
            return;
        listIn.stop();
        listShift.x = dir * win.movement / 2;
        list.opacity = 0;
        listIn.start();
    }

    ParallelAnimation {
        id: listIn

        Anim {
            target: list
            property: "opacity"
            to: 1
            type: Anim.SlowEffects
        }
        Anim {
            target: listShift
            property: "x"
            to: 0
            type: Anim.SlowEffects
        }
    }

    // Narrow window: the details push in over the list and pop back out,
    // like a Settings sub-page.
    function settlePanes(): void {
        pushDetails.stop();
        popDetails.stop();
        listPane.shift = 0;
        propsPane.shift = 0;
        listPane.fade = !win.narrow || !win.detailsShown ? 1 : 0;
        propsPane.fade = !win.narrow || win.detailsShown ? 1 : 0;
    }

    onNarrowChanged: win.settlePanes()
    onDetailsShownChanged: {
        if (!win.narrow) {
            win.settlePanes();
            return;
        }
        pushDetails.stop();
        popDetails.stop();
        (win.detailsShown ? pushDetails : popDetails).start();
    }

    SequentialAnimation {
        id: pushDetails

        Anim {
            target: listPane
            property: "fade"
            to: 0
            type: Anim.DefaultEffects
        }
        PropertyAction {
            target: propsPane
            property: "shift"
            value: win.movement
        }
        ParallelAnimation {
            Anim {
                target: propsPane
                property: "fade"
                from: 0
                to: 1
                type: Anim.SlowEffects
            }
            Anim {
                target: propsPane
                property: "shift"
                to: 0
                type: Anim.SlowEffects
            }
        }
    }

    SequentialAnimation {
        id: popDetails

        Anim {
            target: propsPane
            property: "fade"
            to: 0
            type: Anim.DefaultEffects
        }
        PropertyAction {
            target: listPane
            property: "shift"
            value: -win.movement
        }
        ParallelAnimation {
            Anim {
                target: listPane
                property: "fade"
                from: 0
                to: 1
                type: Anim.SlowEffects
            }
            Anim {
                target: listPane
                property: "shift"
                to: 0
                type: Anim.SlowEffects
            }
        }
    }

    function swapList(): void {
        win.switching = true;
        switchTimer.restart();
    }

    Timer {
        id: switchTimer

        interval: 450
        onTriggered: win.switching = false
    }

    // Top-level categories: the tabs along the top.
    readonly property var tabs: (win.kd.rootItems ?? []).filter(it => it.kind === "menu" && win.menuVisible(it.path)).map(it => win.nodes[it.path]).filter(Boolean)

    onTreeRowsChanged: {
        if (win.cat && !win.nodes[win.cat])
            win.cat = "";
        if (!win.cat && win.tabs.length > 0 && !win.search)
            win.cat = win.tabs[0].path;
        if (win.appToFocus && win.membership[win.appToFocus]) {
            const id = win.appToFocus;
            win.appToFocus = "";
            win.focusApp(id);
        }
    }

    function takeFocusRequest(): void {
        // Not cleared here: Settings may rebuild this page right after, and
        // the new one needs it too. The plugin clears it shortly.
        const id = LauncherCustomizer.focusRequest;
        if (!id)
            return;
        if (win.membership[id])
            win.focusApp(id);
        else
            win.appToFocus = id;
    }

    Component.onCompleted: {
        win.settlePanes();
        if (win.store) {
            win.store.pageOpen = true;
            win.store.refreshView();
        }
        // After the list has built itself, or a tab switch in the same
        // instant can leave a row of the first tab behind.
        focusLater.start();
    }

    // The list fills only once the page knows which tab to show, so it is
    // built once instead of swapped while Settings is still opening.
    property bool ready: false

    Timer {
        id: focusLater

        interval: 150
        onTriggered: {
            win.takeFocusRequest();
            win.ready = true;
        }
    }

    Component.onDestruction: {
        if (win.store)
            win.store.pageOpen = false;
    }

    Connections {
        function onFocusSerialChanged(): void {
            win.takeFocusRequest();
        }

        target: LauncherCustomizer
    }

    // Settings asks before leaving with unsaved changes.
    Connections {
        function onLeaveRequested(proceed: var): void {
            leaveDlg.proceed = proceed;
            leaveDlg.shown = true;
        }

        target: win.store
    }

    // App info from the launcher: the app's top-level page, its subcategory
    // unfolded, the app selected.
    function focusApp(appId: string): void {
        const m = win.membership[appId] ?? [];
        if (m.length > 0)
            win.openCategory(m[0]);
        win.select("app:" + appId, 0);
        win.scrollToKey("app:" + appId);
    }

    function scrollToKey(key: string): void {
        scrollTimer.key = key;
        scrollTimer.restart();
    }

    // Owned by the page, so it never fires after Settings has closed it.
    Timer {
        id: scrollTimer

        property string key: ""

        interval: 1
        onTriggered: {
            const i = win.rows.findIndex(r => r.key === scrollTimer.key);
            if (i >= 0)
                list.positionViewAtIndex(i, ListView.Contain);
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (popup.shown)
                popup.close();
            else if (iconPicker.shown)
                iconPicker.close();
            else if (catPicker.shown)
                catPicker.close();
            else if (confirm.shown)
                confirm.shown = false;
            else if (settingsDlg.shown)
                settingsDlg.close();
            else if (leaveDlg.shown)
                leaveDlg.shown = false;
            else if (win.search) {
                searchField.text = "";
                win.search = "";
            } else if (win.narrow && win.detailsShown)
                win.detailsShown = false;
        }
    }
    Shortcut { sequences: [StandardKey.Find]; onActivated: searchField.forceActiveFocus() }
    Shortcut { sequences: [StandardKey.Undo]; enabled: !win.typing && win.canUndo; onActivated: win.store.kdeUndo() }
    Shortcut { sequences: [StandardKey.Save]; enabled: win.store?.dirty ?? false; onActivated: win.store.save(null) }
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
                spacing: Tokens.spacing.small

                StyledTextField {
                    id: searchField

                    Layout.fillWidth: true
                    Layout.maximumWidth: 420
                    leadingIcon: "search"
                    placeholderText: qsTr("Search apps")
                    onTextChanged: {
                        win.search = text;
                        win.picked = ({});
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                TextButton {
                    id: newBtn

                    text: qsTr("New")
                    type: TextButton.Tonal
                    onClicked: {
                        const p = newBtn.mapToItem(rootItem, 0, newBtn.height + 4);
                        win.newMenu(p.x, p.y);
                    }
                }

                IconButton {
                    icon: win.showHidden ? "visibility" : "visibility_off"
                    type: win.showHidden ? IconButton.Filled : IconButton.Tonal
                    onClicked: win.showHidden = !win.showHidden
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: win.showHidden ? qsTr("Hide hidden entries") : qsTr("Show hidden entries")
                }

                IconButton {
                    icon: "undo"
                    type: IconButton.Tonal
                    disabled: !win.canUndo
                    onClicked: win.store.kdeUndo()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Undo (Ctrl+Z)")
                }

                IconButton {
                    icon: "tune"
                    type: IconButton.Tonal
                    onClicked: settingsDlg.open()
                    ToolTip.visible: hovered
                    ToolTip.delay: 600
                    ToolTip.text: qsTr("Launcher settings")
                }

                // Save and the ⋮ menu as one split button. Nothing is written
                // until Save is pressed; it lights up when there is something to save.
                Row {
                    id: saveSplit

                    readonly property bool dirty: win.store?.dirty ?? false
                    readonly property bool busy: win.store?.saving ?? false
                    readonly property bool canSave: saveSplit.dirty && !saveSplit.busy
                    readonly property color fill: saveSplit.dirty ? Colours.palette.m3primary : Colours.palette.m3secondaryContainer
                    readonly property color ink: saveSplit.dirty ? Colours.palette.m3onPrimary : Colours.palette.m3onSecondaryContainer
                    readonly property real h: 40

                    spacing: Math.max(2, Math.floor(Tokens.spacing.extraSmall / 2))

                    StyledRect {
                        implicitWidth: saveRow.implicitWidth + Tokens.padding.large * 2
                        implicitHeight: saveSplit.h
                        radius: saveSplit.h / 2 * Math.min(1, Tokens.rounding.scale)
                        topRightRadius: Tokens.rounding.medium / 2
                        bottomRightRadius: Tokens.rounding.medium / 2
                        color: saveSplit.fill

                        StateLayer {
                            topRightRadius: parent.topRightRadius
                            bottomRightRadius: parent.bottomRightRadius
                            color: saveSplit.ink
                            disabled: !saveSplit.canSave
                            onClicked: win.store.save(null)
                        }

                        RowLayout {
                            id: saveRow

                            anchors.centerIn: parent
                            spacing: Tokens.spacing.small
                            opacity: saveSplit.canSave ? 1 : 0.45

                            Behavior on opacity {
                                Anim {
                                    type: Anim.DefaultEffects
                                }
                            }

                            MaterialIcon {
                                Layout.alignment: Qt.AlignVCenter
                                text: saveSplit.busy ? "progress_activity" : "save"
                                color: saveSplit.ink
                                fill: saveSplit.dirty ? 1 : 0
                            }

                            StyledText {
                                Layout.alignment: Qt.AlignVCenter
                                text: saveSplit.busy ? qsTr("Saving…") : qsTr("Save")
                                animate: true
                                color: saveSplit.ink
                                font: Tokens.font.label.large
                            }
                        }

                        ToolTip.visible: saveHover.hovered
                        ToolTip.delay: 600
                        ToolTip.text: saveSplit.dirty ? qsTr("Save changes (Ctrl+S)") : qsTr("No unsaved changes")

                        HoverHandler {
                            id: saveHover
                        }
                    }

                    StyledRect {
                        id: moreBtn

                        implicitWidth: saveSplit.h
                        implicitHeight: saveSplit.h
                        radius: saveSplit.h / 2 * Math.min(1, Tokens.rounding.scale)
                        topLeftRadius: Tokens.rounding.medium / 2
                        bottomLeftRadius: Tokens.rounding.medium / 2
                        color: saveSplit.fill

                        StateLayer {
                            rect.topLeftRadius: parent.topLeftRadius
                            rect.bottomLeftRadius: parent.bottomLeftRadius
                            color: saveSplit.ink
                            onClicked: {
                                const p = moreBtn.mapToItem(rootItem, moreBtn.width, moreBtn.height + 4);
                                win.moreMenu(p.x - 260, p.y);
                            }
                        }

                        MaterialIcon {
                            anchors.centerIn: parent
                            text: "more_vert"
                            color: saveSplit.ink
                        }
                    }
                }
            }

            // ------------------------------------------------- category tabs
            // Top-level categories only: subcategories unfold inside them.
            StyledListView {
                id: tabStrip

                Layout.fillWidth: true
                implicitHeight: 44
                orientation: ListView.Horizontal
                spacing: Tokens.spacing.small
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: win.tabs

                // Glides to a position instead of jumping there.
                function glideTo(x: real): void {
                    const max = tabStrip.originX + Math.max(0, tabStrip.contentWidth - tabStrip.width);
                    tabGlide.stop();
                    tabGlide.to = Math.max(tabStrip.originX, Math.min(max, x));
                    tabGlide.start();
                }

                /// Bring a tab fully into view.
                function reveal(path: string): void {
                    const i = win.tabs.findIndex(t => t.path === path);
                    if (i < 0)
                        return;
                    // Tabs off screen are not built yet: let the list work out
                    // where the tab is, then glide there from where we were.
                    tabGlide.stop();
                    const before = tabStrip.contentX;
                    tabStrip.positionViewAtIndex(i, ListView.Contain);
                    const pad = Tokens.padding.large;
                    const target = tabStrip.contentX + (tabStrip.contentX > before ? pad : tabStrip.contentX < before ? -pad : 0);
                    tabStrip.contentX = before;
                    if (Math.abs(target - before) > 1)
                        tabStrip.glideTo(target);
                }

                Anim {
                    id: tabGlide

                    target: tabStrip
                    property: "contentX"
                    type: Anim.DefaultSpatial
                }

                // A mouse wheel (with or without Shift) scrolls the tabs sideways.
                WheelHandler {
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        const d = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y;
                        const from = tabGlide.running ? tabGlide.to : tabStrip.contentX;
                        tabStrip.glideTo(from - d * 1.2);
                    }
                }

                delegate: StyledRect {
                    id: tab

                    required property var modelData
                    readonly property bool sel: !win.search && win.page === tab.modelData.path
                    readonly property var ic: LauncherCustomizer.kdeIcon(tab.modelData)

                    implicitWidth: tabRow.implicitWidth + Tokens.padding.medium * 2
                    implicitHeight: 40
                    radius: Tokens.rounding.full
                    color: tabDrop.containsDrag ? Colours.palette.m3primaryContainer : (tab.sel ? Colours.palette.m3secondaryContainer : (tabMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : Colours.palette.m3surfaceContainer))
                    opacity: tab.modelData.hidden ? 0.55 : 1

                    Behavior on color {
                        CAnim {}
                    }

                    DropArea {
                        id: tabDrop

                        anchors.fill: parent
                        keys: ["lc-items"]
                        onDropped: drop => {
                            win.dropInto(tab.modelData.path, ghost.keys, (drop.modifiers & Qt.ControlModifier) !== 0, win.fromsOf(ghost.keys));
                            drop.accept();
                        }
                    }

                    MouseArea {
                        id: tabMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            win.openCategory(tab.modelData.path);
                            win.detailsShown = false;
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(rootItem, mouse.x, mouse.y);
                                win.treeMenu(tab.modelData.path, p.x, p.y);
                            }
                        }
                    }

                    RowLayout {
                        id: tabRow

                        anchors.centerIn: parent
                        spacing: Tokens.spacing.small

                        CategoryIcon {
                            icon: tab.ic.icon
                            iconSource: tab.ic.iconSource
                            size: 20
                            color: tab.sel ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                        }

                        StyledText {
                            text: tab.modelData.name
                            color: tab.sel ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                            font: Tokens.font.label.large
                        }

                        StyledText {
                            visible: tab.modelData.allApps.length > 0
                            text: String(tab.modelData.allApps.length)
                            color: tab.sel ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.label.medium
                        }
                    }
                }
            }

            // ------------------------------------------------------- panes
            // Side by side, or on a narrow window one at a time, moving like
            // Settings' own pages.
            Item {
                id: panes

                readonly property int gap: Tokens.spacing.medium
                readonly property int propsW: 400

                Layout.fillWidth: true
                Layout.fillHeight: true

                // ============================================== contents
                StyledRect {
                    id: listPane

                    property real fade: 1
                    property real shift: 0

                    x: listPane.shift
                    width: win.narrow ? panes.width : panes.width - panes.propsW - panes.gap
                    height: panes.height
                    opacity: listPane.fade
                    visible: listPane.opacity > 0
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
                                Layout.fillWidth: !editCatBtn.visible
                                text: win.search ? qsTr("Results") : (win.page ? win.nodeName(win.page) : qsTr("Menu"))
                                animate: true
                                elide: Text.ElideRight
                                font: Tokens.font.title.medium
                            }

                            // The category's own details: name, icon, comment.
                            IconButton {
                                id: editCatBtn

                                visible: !win.search && !!win.page
                                icon: "edit"
                                type: IconButton.Text
                                onClicked: {
                                    win.picked = ({});
                                    win.focusKey = "menu:" + win.page;
                                    win.detailsShown = true;
                                }
                                ToolTip.visible: hovered
                                ToolTip.delay: 600
                                ToolTip.text: qsTr("Edit %1").arg(win.nodeName(win.page))
                            }

                            Item {
                                visible: editCatBtn.visible
                                Layout.fillWidth: true
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

                        // Nothing in this category yet.
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Tokens.padding.extraLarge
                            visible: win.ready && !win.search && win.rows.length === 0 && !!win.page
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                Layout.alignment: Qt.AlignHCenter
                                text: "inventory_2"
                                color: Colours.palette.m3outline
                                fontStyle: Tokens.font.icon.large
                            }

                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.maximumWidth: list.width - Tokens.padding.large * 2
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: qsTr("Empty for now. Drag apps onto this tab, use Move to… on an app, or add a launcher with New.")
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.medium
                            }
                        }

                        StyledListView {
                            id: list

                            transform: Translate {
                                id: listShift
                            }

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 2
                            boundsBehavior: Flickable.StopAtBounds
                            model: ScriptModel {
                                values: win.ready ? win.rows : []
                                objectProp: "rowKey"
                            }
                            ScrollBar.vertical: StyledScrollBar {
                                flickable: list
                            }

                            add: Transition {
                                enabled: !win.switching

                                Anim {
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    type: Anim.DefaultEffects
                                }
                                Anim {
                                    property: "scale"
                                    from: 0.94
                                    to: 1
                                    type: Anim.DefaultSpatial
                                }
                            }
                            remove: Transition {
                                enabled: !win.switching

                                Anim {
                                    property: "opacity"
                                    to: 0
                                    type: Anim.FastEffects
                                }
                                Anim {
                                    property: "scale"
                                    to: 0.94
                                    type: Anim.FastSpatial
                                }
                            }
                            displaced: Transition {
                                enabled: !win.switching

                                Anim {
                                    property: "y"
                                    type: Anim.DefaultSpatial
                                }
                                Anim {
                                    properties: "opacity,scale"
                                    to: 1
                                    type: Anim.FastEffects
                                }
                            }
                            move: Transition {
                                Anim {
                                    property: "y"
                                    type: Anim.DefaultSpatial
                                }
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
                                color: rDrop.containsDrag && kind === "menu" ? Colours.palette.m3primaryContainer : (sel ? Colours.palette.m3secondaryContainer : (rMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : Qt.alpha(Colours.palette.m3surfaceContainerHigh, 0)))
                                opacity: (win.store.appHidden(row.app) || row.menuNode?.hidden) ? 0.55 : 1

                                Behavior on color {
                                    CAnim {}
                                }

                                Behavior on opacity {
                                    Anim {
                                        type: Anim.DefaultEffects
                                    }
                                }

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
                                            win.dropInto(row.modelData.path, ghost.keys, (drop.modifiers & Qt.ControlModifier) !== 0, win.fromsOf(ghost.keys));
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
                                            if (!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
                                                win.detailsShown = true;
                                        }
                                    }
                                    onDoubleClicked: {
                                        if (row.kind === "menu")
                                            win.toggleListOpen(row.modelData.path);
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
                                    anchors.leftMargin: Tokens.padding.small + (row.modelData.depth ?? 0) * 28
                                    anchors.rightMargin: Tokens.padding.medium
                                    spacing: Tokens.spacing.medium

                                    // Drop-down for a subcategory: unfolds its items right here.
                                    Item {
                                        implicitWidth: 24
                                        implicitHeight: 24
                                        visible: !win.search

                                        MaterialIcon {
                                            anchors.centerIn: parent
                                            text: "chevron_right"
                                            visible: row.kind === "menu" && win.hasContent(row.modelData.path)
                                            rotation: row.kind === "menu" && win.listOpen[row.modelData.path] ? 90 : 0
                                            color: Colours.palette.m3onSurfaceVariant
                                            fontStyle: Tokens.font.icon.small

                                            Behavior on rotation {
                                                Anim {
                                                    type: Anim.FastSpatial
                                                }
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -6
                                            enabled: row.kind === "menu" && win.hasContent(row.modelData.path)
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: win.toggleListOpen(row.modelData.path)
                                        }
                                    }

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
                                                    return win.plural(row.menuNode?.allApps.length ?? 0, qsTr("1 app"), qsTr("%1 apps"));
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
                                        visible: !!win.store.shortcutOf(row.app)
                                        text: win.store.shortcutOf(row.app)
                                        icon: "keyboard"
                                    }

                                    Chip {
                                        visible: row.kind === "app" && !!row.modelData.parent && win.store.pinned("kde:" + row.modelData.parent, row.modelData.id)
                                        text: qsTr("Pinned")
                                        icon: "vertical_align_top"
                                    }

                                    Chip {
                                        visible: row.kind === "app" && LauncherCustomizer.isNew(row.modelData.id)
                                        text: qsTr("New")
                                        icon: "new_releases"
                                    }

                                    Chip {
                                        visible: !!(win.store.appHidden(row.app) || row.menuNode?.hidden)
                                        text: qsTr("Hidden")
                                        icon: "visibility_off"
                                    }

                                    Chip {
                                        visible: !!(win.clip && win.clip.mode === "cut" && win.clip.keys.includes(row.modelData.key))
                                        text: qsTr("Cut")
                                        icon: "content_cut"
                                    }

                                    // Quick hide, like in the tree.
                                    IconButton {
                                        icon: (win.store.appHidden(row.app) || row.menuNode?.hidden) ? "visibility_off" : "visibility"
                                        type: IconButton.Text
                                        visible: row.kind !== "sep" && (rMouse.containsMouse || hovered)
                                        onClicked: win.toggleHidden(row.modelData.key)
                                        ToolTip.visible: hovered
                                        ToolTip.delay: 600
                                        ToolTip.text: (win.store.appHidden(row.app) || row.menuNode?.hidden) ? qsTr("Show") : qsTr("Hide")
                                    }
                                }
                            }
                        }
                    }
                }

                // ============================================== properties
                // Beside the list, or in its place on a narrow window.
                StyledRect {
                    id: propsPane

                    property real fade: 1
                    property real shift: 0

                    x: (win.narrow ? 0 : panes.width - panes.propsW) + propsPane.shift
                    width: win.narrow ? panes.width : panes.propsW
                    height: panes.height
                    opacity: propsPane.fade
                    visible: propsPane.opacity > 0
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    IconButton {
                        id: detailsBack

                        visible: win.narrow
                        z: 5
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: Tokens.padding.small
                        icon: "arrow_back"
                        type: IconButton.Text
                        onClicked: win.detailsShown = false
                    }

                    Properties {
                        anchors.fill: parent
                        anchors.topMargin: win.narrow ? detailsBack.height + Tokens.padding.small : 0
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

        // undo toast: springs up from the bottom edge, fades away
        StyledRect {
            id: snackBar

            property real t: win.snack.length > 0 ? 1 : 0
            property string text: ""

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Tokens.padding.large * 2 * t - 40 * (1 - t)
            visible: t > 0.01
            opacity: Math.min(1, t)

            Behavior on t {
                Anim {
                    type: Anim.DefaultSpatial
                }
            }
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
                    text: snackBar.text
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
            property bool shown: false

            anchors.fill: parent
            visible: confirm.shown || confirmScrim.opacity > 0
            z: 180

            Rectangle {
                id: confirmScrim

                anchors.fill: parent
                color: Qt.alpha(Colours.palette.m3scrim, 0.45)
                opacity: confirm.shown ? 1 : 0

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: confirm.shown
                    onClicked: confirm.shown = false
                }
            }

            StyledRect {
                anchors.centerIn: parent
                opacity: confirm.shown ? 1 : 0
                scale: confirm.shown ? 1 : 0.92
                width: 440

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                Behavior on scale {
                    Anim {
                        type: Anim.DefaultSpatial
                    }
                }
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
                        text: qsTr("Removes your custom categories, launchers and changes (%1). You can still undo it.").arg(win.plural(confirm.count, qsTr("1 file"), qsTr("%1 files")))
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignRight

                        TextButton {
                            text: qsTr("Cancel")
                            type: TextButton.Text
                            onClicked: confirm.shown = false
                        }

                        TextButton {
                            text: qsTr("Restore")
                            onClicked: {
                                confirm.shown = false;
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

        // Leaving the page with unsaved changes.
        Item {
            id: leaveDlg

            property bool shown: false
            property var proceed: null

            function finish(): void {
                const go = leaveDlg.proceed;
                leaveDlg.shown = false;
                leaveDlg.proceed = null;
                if (go)
                    go();
            }

            anchors.fill: parent
            z: 120
            visible: leaveDlg.shown || leaveScrim.opacity > 0

            Rectangle {
                id: leaveScrim

                anchors.fill: parent
                color: Qt.alpha(Colours.palette.m3scrim, 0.45)
                opacity: leaveDlg.shown ? 1 : 0

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: leaveDlg.shown
                    onClicked: leaveDlg.shown = false
                }
            }

            StyledRect {
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 440)
                height: leaveCol.implicitHeight + Tokens.padding.large * 2
                radius: Tokens.rounding.extraLarge
                color: Colours.palette.m3surfaceContainerHigh
                opacity: leaveDlg.shown ? 1 : 0
                scale: leaveDlg.shown ? 1 : 0.92

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                Behavior on scale {
                    Anim {
                        type: Anim.DefaultSpatial
                    }
                }

                MouseArea {
                    anchors.fill: parent
                }

                ColumnLayout {
                    id: leaveCol

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.large
                    spacing: Tokens.spacing.medium

                    StyledText {
                        text: qsTr("Save your changes?")
                        font: Tokens.font.title.medium
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: qsTr("Your launcher changes haven't been saved yet.")
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignRight
                        spacing: Tokens.spacing.small

                        TextButton {
                            text: qsTr("Cancel")
                            type: TextButton.Text
                            onClicked: leaveDlg.shown = false
                        }

                        TextButton {
                            text: qsTr("Don't save")
                            type: TextButton.Tonal
                            onClicked: win.store.discard(() => leaveDlg.finish())
                        }

                        TextButton {
                            text: qsTr("Save")
                            onClicked: win.store.save(() => leaveDlg.finish())
                        }
                    }
                }
            }
        }

        MenuPopup {
            id: popup
        }

        LauncherSettings {
            id: settingsDlg

            store: win.store
        }

        CategoryColorPicker {
            id: colorPicker

            property string target: ""

            onPicked: hex => {
                colorPicker.close();
                win.store.setLook(colorPicker.target, { enabled: true, color: hex });
            }
        }

        CategoryPicker {
            id: catPicker

            onPicked: key => {
                catPicker.close();
                const keys = win.selectionKeys().filter(k => k.startsWith("app:"));
                win.dropInto(key, keys, win.pickMode === "add", win.fromsOf(keys));
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

    /// Background colour of a launcher category ("kde:<path>").
    function pickColor(categoryId: string, name: string): void {
        colorPicker.target = categoryId;
        colorPicker.open(qsTr("Background for %1").arg(name), win.store.cfg.looks?.[categoryId]?.color ?? "");
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
