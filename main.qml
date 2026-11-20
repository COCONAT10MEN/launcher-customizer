import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import qs.services
import qs.modules.launcher.services
import "."

// Launcher Customizer: everything KDE's Menu Editor does, inside Caelestia,
// synced both ways with the KDE application menu. The shell side lives in
// modules/launcher/services/LauncherCustomizer.qml, which patch.py installs
// (and re-installs after Caelestia updates).
Scope {
    id: root

    readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")
    readonly property string dataPath: root.configHome + "/caelestia/launcher-customizer.json"
    readonly property string kdeMenuFile: root.configHome + "/menus/applications-kmenuedit.menu"
    readonly property string iconDir: root.dataHome + "/caelestia/category-icons"

    // False only on the first start after install or a Caelestia update,
    // before patch.py has added the shell side; the shell restarts right after.
    readonly property bool shellReady: typeof LauncherCustomizer !== "undefined"


    // ===================================================== config file (JSON)

    function current(): var {
        const d = root.shellReady ? LauncherCustomizer.data : null;
        return d && typeof d === "object" ? d : ({});
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



    function setIconStyle(style: string): void {
        root.update(d => d.iconStyle = style);
    }

    // ===================================================== KDE menu bridge

    property bool kdeBusy: false
    property string kdeError: ""
    property var kdeQueue: []
    property double kdeUpdated: 0
    property var themeIcons: []
    property bool themeIconsLoading: false

    signal kdeChanged(var result)

    /// Run kdemenu.py; commands are queued so edits never race.
    function kdeRun(args: var, done: var): void {
        const q = root.kdeQueue.slice();
        q.push({ args: args, done: done });
        root.kdeQueue = q;
        root.kdeNext();
    }

    function kdeNext(): void {
        if (kdeProc.running || root.kdeQueue.length === 0)
            return;
        const q = root.kdeQueue.slice();
        const job = q.shift();
        root.kdeQueue = q;
        kdeProc.job = job;
        root.kdeBusy = true;
        kdeProc.command = ["python3", "-I", root.pluginDir + "/kdemenu.py"].concat(job.args);
        kdeProc.running = true;
    }

    function kdeResult(text: string): void {
        const job = kdeProc.job;
        let res = null;
        try {
            res = JSON.parse(text);
        } catch (e) {
            res = { ok: false, error: "kdemenu.py: " + (text || "no output").slice(0, 200) };
        }
        if (res.ok && res.categories) {
            LauncherCustomizer.kde = res;
            root.kdeUpdated = Date.now();
            root.kdeError = "";
            root.kdeChanged(res);
        } else if (!res.ok) {
            root.kdeError = res.error ?? "unknown error";
            console.warn("[launcher-customizer] " + root.kdeError);
            if (job?.args?.[0] !== "dump")
                Toaster.toast(qsTr("Launcher Customizer"), qsTr("KDE menu change failed: %1").arg(root.kdeError), "warning");
        }
        if (job?.done)
            job.done(res);
        root.kdeBusy = root.kdeQueue.length > 0;
        root.kdeNext();
    }

    function refreshKde(): void {
        if (!root.shellReady)
            return;
        // One pending refresh is enough.
        if (root.kdeQueue.some(j => j.args[0] === "dump"))
            return;
        root.kdeRun(["dump"], null);
    }

    function kdeMove(appId: string, toPath: string, fromPaths: var): void {
        root.kdeRun(["move", appId, toPath].concat(fromPaths ?? []), null);
    }

    function kdeAdd(appId: string, toPath: string): void {
        root.kdeRun(["add", appId, toPath], null);
    }

    function kdeRemove(appId: string, fromPath: string): void {
        root.kdeRun(["remove", appId, fromPath], null);
    }

    function kdeResetApp(appId: string): void {
        root.kdeRun(["reset-app", appId], null);
    }

    function kdeSet(path: string, kv: var): void {
        const args = ["set", path];
        for (const k of Object.keys(kv))
            args.push(k + "=" + kv[k]);
        root.kdeRun(args, null);
    }

    function kdeResetDir(path: string): void {
        root.kdeRun(["reset-dir", path], null);
    }

    function kdeNew(name: string, icon: string, done: var): void {
        root.kdeRun(["new", name, icon ?? ""], res => {
            if (done && res?.ok)
                done(res.created);
        });
    }

    function kdeDelete(path: string): void {
        root.kdeRun(["delete", path], null);
    }

    function kdeOrder(paths: var): void {
        root.kdeRun(["order"].concat(paths), null);
    }

    function kdeUndo(): void {
        root.kdeRun(["undo"], null);
    }

    /// Icon choice from the picker: { kind: "material"|"theme"|"file"|"default", value }.
    function kdeSetIcon(path: string, choice: var): void {
        if (choice.kind === "default") {
            root.kdeSet(path, { "caelestia-icon": "" });
            root.kdeRun(["reset-dir", path], null);
            return;
        }
        if (choice.kind === "material") {
            // KDE gets the same glyph as a colour-scheme aware SVG.
            const out = root.iconDir + "/" + choice.value + ".svg";
            root.kdeRun(["material-svg", choice.value, out], res => {
                const kv = { "caelestia-icon": choice.value };
                if (res?.ok)
                    kv.icon = res.path;
                root.kdeSet(path, kv);
            });
            return;
        }
        root.kdeSet(path, { icon: choice.value, "caelestia-icon": "" });
    }

    // ---- entries, layout and the rest of KDE Menu Editor's actions

    /// Edit an app entry; kv uses kdemenu.py's field names (name, program, terminal…).
    function appSet(appId: string, kv: var): void {
        const args = ["app-set", appId];
        for (const k of Object.keys(kv))
            args.push(k + "=" + (typeof kv[k] === "boolean" ? (kv[k] ? "1" : "0") : kv[k]));
        root.kdeRun(args, null);
    }

    function appReset(appId: string): void {
        root.kdeRun(["app-reset", appId], null);
    }

    function appNew(name: string, menuPath: string, done: var): void {
        root.kdeRun(["app-new", name, menuPath], res => {
            if (done && res?.ok)
                done(res.created);
        });
    }

    function appDelete(appId: string): void {
        root.kdeRun(["app-delete", appId], null);
    }

    function menuNew(name: string, icon: string, parentPath: string, done: var): void {
        root.kdeRun(["new", name, icon ?? "", parentPath ?? ""], res => {
            if (done && res?.ok)
                done(res.created);
        });
    }

    /// Full order of one category: tokens are menu:<Name>, app:<id> or sep.
    function setLayout(path: string, tokens: var): void {
        root.kdeRun(["layout", path].concat(tokens), null);
    }

    function sort(path: string, by: string, all: bool): void {
        root.kdeRun(["sort", path, by].concat(all ? ["all"] : []), null);
    }

    /// Icon choice from the picker for an app: { kind: "material"|"theme"|"file", value }.
    function appSetIcon(appId: string, choice: var): void {
        if (choice.kind === "material") {
            const out = root.iconDir + "/" + choice.value + ".svg";
            root.kdeRun(["material-svg", choice.value, out], res => {
                if (res?.ok)
                    root.appSet(appId, { icon: res.path });
            });
            return;
        }
        root.appSet(appId, { icon: choice.value });
    }

    function menuMove(path: string, newParent: string): void {
        root.kdeRun(["menu-move", path, newParent], null);
    }

    function restorePreview(done: var): void {
        root.kdeRun(["restore-preview"], res => done(res?.files ?? []));
    }

    function restoreSystem(): void {
        root.kdeRun(["restore-system"], null);
    }

    /// key: Qt key combination as an int, 0 clears.
    function setShortcut(appId: string, key: int, label: string): void {
        root.kdeRun(["shortcut", appId, String(key), label], null);
    }

    function launch(app: var): void {
        Quickshell.execDetached(["kioclient", "exec", app.file]);
    }

    function openFolder(app: var): void {
        Quickshell.execDetached(["xdg-open", app.file.replace(/\/[^/]*$/, "")]);
    }

    function copyLocation(app: var): void {
        Quickshell.clipboardText = app.file;
    }

    function loadThemeIcons(): void {
        if (root.themeIcons.length > 0 || root.themeIconsLoading)
            return;
        root.themeIconsLoading = true;
        root.kdeRun(["icons"], res => {
            root.themeIconsLoading = false;
            if (res?.ok)
                root.themeIcons = res.icons.map(i => i.name);
        });
    }

    function openKMenuEdit(): void {
        Quickshell.execDetached(["kmenuedit"]);
    }

    Process {
        id: kdeProc

        property var job: null

        stdout: StdioCollector {
            onStreamFinished: root.kdeResult(text)
        }
    }

    // Live sync: KDE Menu Editor saves, installed/removed apps, opening the
    // launcher, and (while the editor is open) a light poll for .directory edits.
    FileView {
        path: root.kdeMenuFile
        watchChanges: true
        printErrors: false
        onFileChanged: syncDebounce.restart()
    }

    Connections {
        function onValuesChanged(): void {
            syncDebounce.restart();
        }

        target: DesktopEntries.applications
    }

    Connections {
        function onLauncherOpenChanged(): void {
            if (Visibilities.launcherOpen)
                root.refreshKde();
        }

        target: Visibilities
    }

    Timer {
        id: syncDebounce

        interval: 400
        onTriggered: root.refreshKde()
    }

    Timer {
        interval: 3000
        repeat: true
        running: root.shellReady && (editorLoader.item?.visible ?? false)
        onTriggered: root.kdeRun(["stamp"], res => {
            if (res?.ok && res.stamp !== LauncherCustomizer.kde?.stamp)
                root.refreshKde();
        })
    }

    // ============================================================ editor

    function openEditor(appId: string): void {
        editorLoader.active = true;
        const w = editorLoader.item;
        if (!w)
            return;
        w.visible = true;
        root.refreshKde();
        if (appId)
            w.focusApp(appId);
    }

    LazyLoader {
        id: editorLoader

        active: false

        Editor {
            store: root
        }
    }

    // ========================================================== wiring


    FileView {
        id: dataFile

        path: root.dataPath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        iconFile.setText(root.iconSvg);
        if (!root.shellReady)
            return;
        // Drop settings older versions used (launcher placement, the
        // Caelestia-list mode and its edits).
        let cur = {};
        try {
            cur = JSON.parse(dataFile.text() || "{}") || {};
        } catch (e) {}
        const stale = ["placement", "source", "categories", "assignments"].filter(k => cur[k] !== undefined);
        if (stale.length > 0) {
            for (const k of stale)
                delete cur[k];
            root.write(cur);
        }
        LauncherCustomizer.pluginActive = true;
        root.refreshKde();
    }

    Component.onDestruction: {
        Quickshell.execDetached(["rm", "-f", root.pluginDir + "/icon.svg"]);
        if (root.shellReady)
            LauncherCustomizer.pluginActive = false;
    }

    /// The launcher's custom order after a drag: KDE categories keep it in
    /// their own KDE order, Favorites and All Applications in our config.
    function saveOrder(categoryId: string, ids: var): void {
        if (categoryId.startsWith("kde:")) {
            const node = LauncherCustomizer.kdeNodes[categoryId];
            if (!node)
                return;
            const items = node.items;
            const direct = items.filter(it => it.kind === "app").map(it => it.id);
            const wanted = ids.filter(id => direct.includes(id));
            const seq = wanted.concat(direct.filter(id => !wanted.includes(id)));
            let k = 0;
            const tokens = items.map(it => it.kind === "sep" ? "sep" : (it.kind === "menu" ? "menu:" + it.path.split("/").pop() : "app:" + seq[k++]));
            root.setLayout(categoryId.slice(4), tokens);
        } else {
            root.update(d => {
                d.order = d.order && typeof d.order === "object" ? d.order : {};
                d.order[categoryId] = ids;
            });
        }
    }

    Connections {
        function onEditRequested(appId: string): void {
            root.openEditor(appId);
        }

        function onReorderRequested(categoryId: string, ids: var): void {
            root.saveOrder(categoryId, ids);
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


        function sync(): void {
            root.refreshKde();
        }



        target: "launcherCustomizer"
    }

    // ============================================================== icon

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

    // ========================================================== patching

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
