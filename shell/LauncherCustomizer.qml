pragma Singleton
// launcher-customizer:managed
// Installed into the shell by the Launcher Customizer plugin
// (https://github.com/COCONAT10MEN/launcher-customizer) and removed by its
// revert. Everything here is inert while the plugin is not running, so
// disabling the plugin restores stock behaviour.
//
// Category sources:
//   "kde"        (default) the KDE application menu, read by the plugin's
//                kdemenu.py and kept in sync both ways
//   "caelestia"  Caelestia's built-in list plus the edits saved in
//                ~/.config/caelestia/launcher-customizer.json

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

    readonly property var validPlacements: ["bottom", "top", "left", "right", "dock"]
    readonly property string placement: root.pluginActive && root.validPlacements.includes(root.data?.placement) ? root.data.placement : "bottom"
    readonly property string source: root.data?.source === "caelestia" ? "caelestia" : "kde"
    readonly property bool useKde: root.pluginActive && root.source === "kde" && root.kde?.ok === true
    readonly property string iconStyle: root.data?.iconStyle === "theme" ? "theme" : "material"
    readonly property var assignments: root.pluginActive && !root.useKde && root.data?.assignments && typeof root.data.assignments === "object" ? root.data.assignments : ({})
    readonly property var userCategories: root.pluginActive && !root.useKde && Array.isArray(root.data?.categories) ? root.data.categories : []

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

    signal editRequested(string appId)

    function requestEdit(appId: string): void {
        root.editRequested(appId);
    }

    /// The screen edge the launcher opens from. "dock" uses the bar's edge,
    /// since the dock lives in the bar.
    function edgeFor(barPosition: string): string {
        if (root.placement === "dock")
            return ["top", "bottom", "left", "right"].includes(barPosition) ? barPosition : "bottom";
        return root.placement;
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

    /// Caelestia-mode icon strings: a Material name, "theme:<name>" or a file path.
    function caelestiaIcon(icon: string): var {
        if (icon.startsWith("theme:"))
            return { icon: "", iconSource: root.imageFor(icon.slice(6)) };
        if (icon.startsWith("/") || icon.startsWith("file://"))
            return { icon: "", iconSource: root.imageFor(icon) };
        return { icon: icon, iconSource: "" };
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
        return root.useKde ? root.kdeDefinitions(base) : root.merge(base);
    }

    /// Caelestia mode: the built-in list with the user's order, names, icons,
    /// XDG tags, hidden flags and custom categories applied.
    function merge(base: var): var {
        const user = root.userCategories;
        if (user.length === 0)
            return base;

        const byId = {};
        for (const def of base)
            byId[def.id] = def;

        const out = [];
        const seen = {};
        for (const u of user) {
            if (!u || typeof u.id !== "string" || seen[u.id])
                continue;
            seen[u.id] = true;
            const b = byId[u.id];
            if (!b && !u.custom)
                continue; // a built-in a newer shell no longer has
            if (u.hidden && u.id !== "all" && u.id !== "favorites")
                continue;
            const def = Object.assign({}, b ?? {}, { id: u.id });
            if (typeof u.name === "string" && u.name.trim().length > 0)
                def.name = u.name.trim();
            if (typeof u.icon === "string" && u.icon.trim().length > 0)
                Object.assign(def, root.caelestiaIcon(u.icon.trim()));
            if (Array.isArray(u.xdg) && u.id !== "favorites" && u.id !== "all" && u.id !== "other")
                def.xdg = u.xdg.filter(x => typeof x === "string" && x.length > 0);
            if (!def.name)
                def.name = u.id;
            if (!def.icon && !def.iconSource)
                def.icon = "label";
            out.push(def);
        }
        // Built-ins added by a shell update after the user saved keep their
        // default position.
        for (let i = 0; i < base.length; i++) {
            if (!seen[base[i].id])
                out.splice(Math.min(i, out.length), 0, base[i]);
        }
        return out;
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
