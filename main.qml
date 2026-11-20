import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import Caelestia
import qs.services
import qs.modules.launcher.services
import "."

// Launcher Customizer: edit launcher categories and choose where the launcher
// opens. The shell side lives in modules/launcher/services/LauncherCustomizer.qml,
// which patch.py installs (and re-installs after Caelestia updates).
Scope {
    id: root

    readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
    readonly property string dataPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/caelestia/launcher-customizer.json"

    // Nexus → Plugins → settings shows these labels; the shell wants the keys.
    readonly property var placementKeys: ({ "Bottom": "bottom", "Top": "top", "Left": "left", "Right": "right", "Follow dock": "dock" })
    readonly property var placementLabels: ["Bottom", "Top", "Left", "Right", "Follow dock"]

    function placementLabel(key: string): string {
        for (const label of root.placementLabels)
            if (root.placementKeys[label] === key)
                return label;
        return "Bottom";
    }

    // ------------------------------------------------------------ data model

    // False only on the first start after install or a Caelestia update,
    // before patch.py has added the shell side; the shell restarts right after.
    readonly property bool shellReady: typeof LauncherCustomizer !== "undefined"

    function current(): var {
        const d = LauncherCustomizer.data;
        return d && typeof d === "object" ? d : ({});
    }

    /// Every category with the user's edits, hidden ones included.
    function fullList(): var {
        const base = Categories.lcBaseDefinitions ?? [];
        const user = Array.isArray(root.current().categories) ? root.current().categories : [];
        const fromBase = b => ({ id: b.id, name: b.name, icon: b.icon, xdg: (b.xdg ?? []).slice(), hidden: false, custom: false });
        if (user.length === 0)
            return base.map(fromBase);

        const byId = {};
        for (const b of base)
            byId[b.id] = b;
        const out = [];
        const seen = {};
        for (const u of user) {
            if (!u || typeof u.id !== "string" || seen[u.id])
                continue;
            const b = byId[u.id];
            if (!b && !u.custom)
                continue;
            seen[u.id] = true;
            out.push({
                id: u.id,
                name: (typeof u.name === "string" && u.name.trim()) ? u.name.trim() : (b?.name ?? u.id),
                icon: (typeof u.icon === "string" && u.icon.trim()) ? u.icon.trim() : (b?.icon ?? "label"),
                xdg: Array.isArray(u.xdg) ? u.xdg.slice() : (b?.xdg ?? []).slice(),
                hidden: !!u.hidden,
                custom: !b
            });
        }
        for (let i = 0; i < base.length; i++)
            if (!seen[base[i].id])
                out.splice(Math.min(i, out.length), 0, fromBase(base[i]));
        return out;
    }

    function write(next: var): void {
        next.version = 1;
        LauncherCustomizer.data = next;
        dataFile.setText(JSON.stringify(next, null, 2) + "\n");
    }

    function update(mutator: var): void {
        const next = JSON.parse(JSON.stringify(root.current()));
        mutator(next);
        root.write(next);
    }

    function saveCategories(list: var): void {
        root.update(d => {
            d.categories = list.map(c => ({ id: c.id, name: c.name, icon: c.icon, xdg: c.xdg ?? [], hidden: !!c.hidden, custom: !!c.custom }));
        });
    }

    function assign(appId: string, categoryId: string): void {
        root.update(d => {
            d.assignments = d.assignments && typeof d.assignments === "object" ? d.assignments : {};
            d.assignments[appId] = categoryId;
        });
    }

    function unassign(appId: string): void {
        root.update(d => {
            if (d.assignments)
                delete d.assignments[appId];
        });
    }

    function setPlacement(key: string): void {
        settings.placement = root.placementLabel(key);
        // Flush now: the shell is restarted with SIGTERM, which skips the
        // automatic save, and the next start would restore the old value.
        settings.sync();
        root.update(d => d.placement = key);
    }

    function resetAll(): void {
        root.write({ placement: root.placementKeys[settings.placement] ?? "bottom" });
    }

    function openEditor(appId: string): void {
        editorLoader.active = true;
        const w = editorLoader.item;
        if (!w)
            return;
        w.visible = true;
        if (appId)
            w.focusApp(appId);
    }

    // ------------------------------------------------------------- wiring

    Settings {
        id: settings

        property string placement: "Bottom"

        category: "Plugin_launcher-customizer"
    }

    FileView {
        id: dataFile

        path: root.dataPath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        // Mirror the Nexus placement setting into the config file the shell reads.
        let cur = {};
        try {
            cur = JSON.parse(dataFile.text() || "{}") || {};
        } catch (e) {}
        const key = root.placementKeys[settings.placement] ?? "bottom";
        if (root.shellReady && cur.placement !== key) {
            cur.placement = key;
            root.write(cur);
        }
        iconFile.setText(root.iconSvg);
        if (root.shellReady)
            LauncherCustomizer.pluginActive = true;
    }
    Component.onDestruction: {
        Quickshell.execDetached(["rm", "-f", root.pluginDir + "/icon.svg"]);
        if (root.shellReady)
            LauncherCustomizer.pluginActive = false;
    }

    Connections {
        function onEditRequested(appId: string): void {
            root.openEditor(appId);
        }

        target: root.shellReady ? LauncherCustomizer : null
        ignoreUnknownSignals: true
    }

    IpcHandler {
        function open(): void {
            root.openEditor("");
        }

        function edit(appId: string): void {
            root.openEditor(appId);
        }

        /// bottom | top | left | right | dock
        function setPlacement(key: string): void {
            if (LauncherCustomizer.validPlacements.includes(key))
                root.setPlacement(key);
        }

        target: "launcherCustomizer"
    }

    LazyLoader {
        id: editorLoader

        active: false

        Editor {
            store: root
        }
    }

    // ------------------------------------------------------------- icon

    // Nexus draws font icons about 2px above centre, so the plugin's icon is an
    // SVG of the same Material Symbols glyph, centred by geometry. It is made
    // on each machine from that user's live palette (transparent background,
    // so Nexus's own circle shows through), rewritten on palette changes, and
    // removed while the plugin is not running so it can never go stale.
    readonly property string glyphPath: "M150.5 517Q130.8 517 117.3 530.5Q103.7 544.1 103.7 563.8V809.7Q103.7 829.4 117.3 843Q130.8 856.5 150.5 856.5H396.4Q416.1 856.5 429.7 843Q443.2 829.4 443.2 809.7V563.8Q443.2 544.1 429.7 530.5Q416.1 517 396.4 517ZM197.5 762.7H349.9V610.8H197.5ZM563.8 517Q544.1 517 530.5 530.5Q517 544.1 517 563.8V809.7Q517 829.4 530.5 843Q544.1 856.5 563.8 856.5H809.7Q829.4 856.5 843 843Q856.5 829.4 856.5 809.7V563.8Q856.5 544.1 843 530.5Q829.4 517 809.7 517ZM610.8 762.7H763.2V610.8H610.8ZM150.5 103.7Q130.8 103.7 117.3 117.3Q103.7 130.8 103.7 150.5V396.4Q103.7 416.1 117.3 429.7Q130.8 443.2 150.5 443.2H396.4Q416.1 443.2 429.7 429.7Q443.2 416.1 443.2 396.4V150.5Q443.2 130.8 429.7 117.3Q416.1 103.7 396.4 103.7ZM197.5 349.4H349.9V197.5H197.5ZM686.8 103.7Q667 103.7 653.5 117.3Q639.9 130.9 639.9 150.6V226.6H562.9Q543.2 226.6 530.1 240.1Q517 253.7 517 273.4Q517 293.2 530.6 306.8Q544.2 320.4 563.9 320.4H639.9V397.3Q639.9 417 653.4 430.1Q667 443.2 686.7 443.2Q706.4 443.2 720 429.6Q733.6 416 733.6 396.3V320.4H810.6Q830.3 320.4 843.4 306.8Q856.5 293.2 856.5 273.5Q856.5 253.7 842.9 240.2Q829.3 226.6 809.6 226.6H733.6V149.6Q733.6 129.9 720.1 116.8Q706.5 103.7 686.8 103.7ZM610.8 762.7V610.8H762.7V762.7ZM197.5 762.7V610.8H349.4V762.7ZM197.5 349.4V197.5H349.4V349.4Z"

    function hex(c: color): string {
        const h = v => Math.round(v * 255).toString(16).padStart(2, "0");
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }

    readonly property string iconSvg: '<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192" viewBox="0 0 48 48">'
        + '<path transform="translate(12.3698 35.6302) scale(0.024224 -0.024224)" fill="' + hex(Colours.palette.m3onSecondaryContainer) + '" d="' + glyphPath + '"/>'
        + '</svg>\n'

    onIconSvgChanged: iconFile.setText(iconSvg)

    FileView {
        id: iconFile

        path: root.pluginDir + "/icon.svg"
        printErrors: false
    }

    // ------------------------------------------------------------- patching

    // Restart the shell process (via its systemd service) instead of an
    // in-process reload, which can deadlock and does not restart plugins.
    function restartShell(): void {
        Quickshell.execDetached(["sh", root.pluginDir + "/restart-shell.sh", Quickshell.shellPath("shell.qml")]);
    }

    function handle(output: string): void {
        const result = output.trim();
        if (result === "PATCHED") {
            console.info("[launcher-customizer] patched the shell, restarting it");
            root.restartShell();
        } else if (result === "OK") {
            console.info("[launcher-customizer] patch already in place");
        } else {
            console.warn("[launcher-customizer] " + result);
            Toaster.toast(qsTr("Launcher Customizer"), qsTr("Could not hook into the launcher after an update, so it is back to stock: %1").arg(result), "warning");
            if (result.startsWith("FAILED+RELOAD"))
                root.restartShell();
        }
    }

    Process {
        running: true
        command: ["python3", "-I", root.pluginDir + "/patch.py", "apply", Quickshell.shellDir]
        stdout: StdioCollector {
            onStreamFinished: root.handle(text)
        }
    }
}
