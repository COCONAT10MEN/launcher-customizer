pragma Singleton
// launcher-customizer:managed
// Installed into the shell by the Launcher Customizer plugin
// (https://github.com/COCONAT10MEN/launcher-customizer) and removed by its
// revert. Everything here is inert while the plugin is not running, so
// disabling the plugin restores stock behaviour.
//
// The launcher's categories are the KDE application menu, read by the
// plugin's kdemenu.py and kept in sync both ways.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/caelestia/launcher-customizer.json"

    // Set by the plugin while it is loaded.
    property bool pluginActive: false
    // The parsed config file. The plugin also assigns it directly when saving.
    property var data: ({})
    // The KDE menu as kdemenu.py reports it. Set by the plugin.
    property var kde: ({})

    readonly property bool useKde: root.pluginActive && root.kde?.ok === true
    readonly property string iconStyle: root.data?.iconStyle === "theme" ? "theme" : "material"
    // "stack": subcategory sections one under another; "flow": side by side when they fit.
    readonly property string sectionLayout: root.data?.sectionLayout === "flow" ? "flow" : "stack"
    // A dot by the name of apps installed or updated in the last `newDays` days, until launched.
    readonly property bool newDot: root.data?.newDot !== false
    readonly property int newDays: Math.max(1, Number(root.data?.newDays ?? 7) || 7)
    // The category the launcher's app menu was opened in (for "Pin to top").
    property string contextCategory: ""
    property real nowSec: Date.now() / 1000

    onKdeChanged: root.nowSec = Date.now() / 1000

    // "kde:<menu path>" -> { appId: true }, top-level categories including their subcategories.
    readonly property var kdeMembers: {
        const map = {};
        for (const c of (root.kde?.categories ?? [])) {
            const set = {};
            for (const a of c.allApps)
                set[a] = true;
            map["kde:" + c.path] = set;
        }
        return map;
    }

    // The plugin's editor, shown as a page in Settings (Panels & Interface ->
    // Launcher -> Launcher Customizer). Set by the plugin while it runs.
    property var store: null
    property url editorUrl: ""
    // App the editor should show when its page opens (App info).
    property string focusRequest: ""
    property int focusSerial: 0

    /// Settings asks before leaving the page with unsaved changes. Returns
    /// true when it is asking (the navigation then waits for the answer).
    function blockLeave(proceed: var): bool {
        if (!root.pluginActive || !root.store || !root.store.pageOpen || !root.store.dirty)
            return false;
        root.store.askLeave(proceed);
        return true;
    }

    signal editRequested(string appId)
    signal reorderRequested(string categoryId, var ids)
    signal pinRequested(string categoryId, string appId, bool pin)
    signal seenRequested(string appId)

    function requestEdit(appId: string): void {
        root.editRequested(appId);
    }

    /// The launcher's custom order changed (drag and drop): the plugin saves it.
    function requestReorder(categoryId: string, ids: var): void {
        root.reorderRequested(categoryId, ids);
    }

    function requestPin(categoryId: string, appId: string, pin: bool): void {
        root.pinRequested(categoryId, appId, pin);
    }

    // ---------------------------------------------- pins, new apps, looks

    function pinnedIn(categoryId: string, appId: string): bool {
        return root.pluginActive && !!appId && (root.data?.pinned?.[categoryId] ?? []).includes(appId);
    }

    /// Pinned apps first (in the order they were pinned), the rest as they were.
    function pinFirst(list: var, categoryId: string): var {
        const pins = root.data?.pinned?.[categoryId] ?? [];
        if (!pins.length)
            return list;
        const rank = {};
        pins.forEach((id, i) => rank[id] = i);
        const top = list.filter(a => rank[a.id] !== undefined).sort((a, b) => rank[a.id] - rank[b.id]);
        return top.concat(list.filter(a => rank[a.id] === undefined));
    }

    /// When this machine installed or last updated the app (seconds), 0 if unknown.
    function installedAt(appId: string): real {
        return root.kde?.apps?.[appId]?.installed ?? 0;
    }

    function isNew(appId: string): bool {
        if (!root.pluginActive || !root.newDot || !appId)
            return false;
        const t = root.installedAt(appId);
        // Only what came after the feature was turned on, and not opened since.
        return t > root.nowSec - root.newDays * 86400 && t > (root.data?.seenSince ?? root.nowSec) && t > (root.data?.seen?.[appId] ?? 0);
    }

    /// Launching an app clears its dot.
    function markSeen(appId: string): void {
        if (root.isNew(appId))
            root.seenRequested(appId);
    }

    /// Readable text colour on top of a category background ("transparent": keep the theme's).
    function labelOn(c: string): color {
        const col = Qt.color(c);
        if (col.a < 0.45)
            return "transparent";
        const lum = 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
        return lum > 0.55 ? "#1c1b1f" : "#f4eff4";
    }

    /// { enabled, color, label } of a category's background.
    function lookFor(categoryId: string): var {
        const l = root.data?.looks?.[categoryId];
        if (!root.pluginActive || !l?.enabled || !l?.color)
            return { enabled: false, color: "transparent", label: "transparent" };
        return { enabled: true, color: l.color, label: root.labelOn(l.color) };
    }

    // ------------------------------------------------- sections and order

    // "kde:<path>" -> node, every level.
    readonly property var kdeNodes: {
        const m = {};
        const walk = list => {
            for (const n of list) {
                m["kde:" + n.path] = n;
                walk(n.children);
            }
        };
        walk(root.kde?.categories ?? []);
        return m;
    }

    /// App ids of a KDE menu in its own order, subcategories flattened in place.
    function flatOrder(node: var): var {
        const out = [];
        for (const it of (node?.items ?? [])) {
            if (it.kind === "app")
                out.push(it.id);
            else if (it.kind === "menu")
                out.push(...root.flatOrder(root.kdeNodes["kde:" + it.path]));
        }
        return out;
    }

    function orderBy(apps: var, categoryId: string, mode: string, sortFn: var): var {
        if (!root.pluginActive)
            return sortFn(apps);
        const byName = (a, b) => String(a.name).localeCompare(String(b.name));
        let out;
        if (mode === "custom") {
            const node = root.kdeNodes[categoryId];
            const list = node ? root.flatOrder(node) : (root.data?.order?.[categoryId] ?? []);
            const idx = {};
            list.forEach((id, i) => idx[id] = i);
            out = apps.slice().sort((a, b) => ((idx[a.id] ?? 1e9) - (idx[b.id] ?? 1e9)) || byName(a, b));
        } else if (mode === "newest" || mode === "oldest") {
            const dir = mode === "newest" ? -1 : 1;
            out = apps.slice().sort((a, b) => dir * (root.installedAt(a.id) - root.installedAt(b.id)) || byName(a, b));
        } else {
            out = sortFn(apps);
        }
        return root.pinFirst(out, categoryId);
    }

    /// What the launcher grid shows for a category: { top, sections }.
    /// A KDE category with subcategories keeps its own apps on top and shows
    /// each subcategory as a section below them.
    function arrange(categoryId: string, apps: var, all: var, mode: string, sortFn: var): var {
        const node = root.useKde ? root.kdeNodes[categoryId] : null;
        const subs = (node?.children ?? []).filter(c => !c.hidden && c.allApps.length > 0);
        if (!node || subs.length === 0)
            return { top: root.orderBy(apps, categoryId, mode, sortFn), sections: [] };
        const byId = {};
        for (const a of all)
            byId[a.id] = a;
        const direct = {};
        for (const id of node.apps)
            direct[id] = true;
        const sections = subs.map(c => Object.assign({ id: "kde:" + c.path, name: c.name, apps: root.orderBy(c.allApps.map(id => byId[id]).filter(Boolean), "kde:" + c.path, mode, sortFn) }, root.kdeIcon(c))).filter(sec => sec.apps.length > 0);
        return { top: root.orderBy(apps.filter(a => direct[a.id]), categoryId, mode, sortFn), sections: sections };
    }

    // ------------------------------------------------------------- icons

    // KDE's stock category icons, in Caelestia's Material Symbols style.
    readonly property var kdeMaterial: ({
            "kf5-development.directory": "code",
            "kf5-education.directory": "school",
            "kf5-games.directory": "sports_esports",
            "kf5-graphics.directory": "palette",
            "kf5-internet.directory": "public",
            "kf5-multimedia.directory": "movie",
            "kf5-office.directory": "description",
            "kf5-science.directory": "science",
            "kf5-settingsmenu.directory": "settings",
            "kf5-system.directory": "computer",
            "kf5-utilities.directory": "build",
            "kf5-unknown.directory": "category",
            "kf5-help.directory": "help",
            "kf5-toys.directory": "toys",
            "kf5-main.directory": "apps"
        })

    function materialGuess(icon: string): string {
        const i = (icon || "").toLowerCase();
        const table = [["game", "sports_esports"], ["internet", "public"], ["network", "public"], ["multimedia", "movie"], ["development", "code"], ["graphics", "palette"], ["office", "description"], ["science", "science"], ["education", "school"], ["system", "computer"], ["utilities", "build"], ["help", "help"], ["settings", "settings"], ["preferences", "settings"]];
        for (const [k, v] of table)
            if (i.startsWith("applications-" + k) || i.startsWith("preferences-" + k))
                return v;
        return "";
    }

    /// Image for an icon string: an absolute path, a file URL or an icon theme name.
    function imageFor(icon: string): string {
        if (!icon)
            return "";
        if (icon.startsWith("file://"))
            return icon;
        if (icon.startsWith("/"))
            return "file://" + icon;
        return Quickshell.iconPath(icon, true) || "";
    }

    /// { icon: Material name or "", iconSource: image or "" } for a KDE category.
    function kdeIcon(c: var): var {
        if (c.caelestiaIcon)
            return { icon: c.caelestiaIcon, iconSource: "" };
        const changedInKde = c.hasOverride && c.icon !== c.systemIcon;
        if (root.iconStyle === "material" && !changedInKde) {
            const m = root.kdeMaterial[c.directory] || root.materialGuess(c.icon);
            if (m)
                return { icon: m, iconSource: "" };
        }
        const img = root.imageFor(c.icon);
        return img ? { icon: "", iconSource: img } : { icon: "folder", iconSource: "" };
    }


    // -------------------------------------------------------- definitions

    function kdeDefinitions(base: var): var {
        const out = base.filter(d => d.id === "favorites" || d.id === "all");
        for (const c of (root.kde?.categories ?? [])) {
            if (c.hidden)
                continue;
            out.push(Object.assign({ id: "kde:" + c.path, name: c.name, kdePath: c.path }, root.kdeIcon(c)));
        }
        return out;
    }

    function kdeHas(categoryId: string, appId: string): bool {
        return !!root.kdeMembers[categoryId]?.[appId];
    }

    /// The first visible KDE category an app is in (KDE allows several).
    function kdeFirst(defs: var, appId: string): string {
        for (const d of defs)
            if (d.kdePath !== undefined && root.kdeHas(d.id, appId))
                return d.id;
        return "all";
    }

    /// The category list the launcher shows.
    function definitionsFor(base: var): var {
        return root.useKde ? root.kdeDefinitions(base) : base;
    }


    Timer {
        interval: 600000
        running: root.pluginActive && root.newDot
        repeat: true
        onTriggered: root.nowSec = Date.now() / 1000
    }

    FileView {
        path: root.path
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                root.data = parsed && typeof parsed === "object" ? parsed : ({});
            } catch (e) {
                console.warn("[launcher-customizer] ignoring unreadable " + root.path + ": " + e);
            }
        }
        onLoadFailed: root.data = ({})
    }
}
