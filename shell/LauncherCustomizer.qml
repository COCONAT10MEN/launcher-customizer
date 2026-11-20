pragma Singleton
// launcher-customizer:managed
// Installed into the shell by the Launcher Customizer plugin
// (https://github.com/COCONAT10MEN/launcher-customizer) and removed by its
// revert. Reads the user's launcher layout from
// ~/.config/caelestia/launcher-customizer.json. Everything here is inert
// while the plugin is not running, so disabling it restores stock behaviour.

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/caelestia/launcher-customizer.json"

    // Set by the plugin while it is loaded.
    property bool pluginActive: false
    // The parsed config file. The plugin also assigns it directly when saving,
    // so edits show up without waiting for the file watcher.
    property var data: ({})

    readonly property var validPlacements: ["bottom", "top", "left", "right", "dock"]
    readonly property string placement: root.pluginActive && root.validPlacements.includes(root.data?.placement) ? root.data.placement : "bottom"
    readonly property var assignments: root.pluginActive && root.data?.assignments && typeof root.data.assignments === "object" ? root.data.assignments : ({})
    readonly property var userCategories: root.pluginActive && Array.isArray(root.data?.categories) ? root.data.categories : []

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

    /// The built-in category list with the user's order, names, icons, XDG
    /// tags, hidden flags and custom categories applied.
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
                def.icon = u.icon.trim();
            if (Array.isArray(u.xdg) && u.id !== "favorites" && u.id !== "all" && u.id !== "other")
                def.xdg = u.xdg.filter(x => typeof x === "string" && x.length > 0);
            if (!def.name)
                def.name = u.id;
            if (!def.icon)
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
