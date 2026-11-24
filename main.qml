import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import qs.services
import qs.utils
import qs.modules.launcher.services
import qs.modules.nexus
import "."
import "updater"

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
    readonly property string stageDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/caelestia/launcher-customizer/stage"

    // ================================================= unsaved changes
    //
    // The editor never changes anything directly. KDE menu edits go to a
    // working copy of the menu files (kdemenu.py's LC_STAGE); shortcuts,
    // hidden apps and launcher settings wait here. Save writes it all,
    // Don't save drops it. The launcher and KDE only ever see saved state.

    // The working copy as kdemenu.py reports it, null while there is none.
    property var stageView: null
    property bool kdeDirty: false
    property var pendingOps: []          // mutators for the plugin's config
    property var pendingHidden: null     // Caelestia's hidden apps list, edited
    property var pendingShortcuts: ({})  // appId -> { key, label, text }
    // The Settings page with the editor is showing. Counted, because when
    // Settings rebuilds the page the old one closes after the new one opened.
    property int pagesOpen: 0
    readonly property bool pageOpen: root.pagesOpen > 0
    property bool saving: false

    readonly property bool dirty: root.kdeDirty || root.pendingOps.length > 0 || root.pendingHidden !== null || Object.keys(root.pendingShortcuts).length > 0
    /// What the editor shows: the working copy, or the saved menu.
    readonly property var view: root.stageView ?? (root.shellReady ? LauncherCustomizer.kde : ({}))
    /// The plugin's config with unsaved setting changes applied.
    readonly property var cfg: {
        const d = JSON.parse(JSON.stringify(root.shellReady ? (LauncherCustomizer.data ?? {}) : {}));
        for (const op of root.pendingOps)
            op(d);
        return d;
    }

    signal leaveRequested(var proceed)

    function askLeave(proceed: var): void {
        root.leaveRequested(proceed);
    }

    /// Write every unsaved change, then run done().
    function save(done: var): void {
        if (root.saving)
            return;
        root.saving = true;
        const finish = () => {
            for (const id of Object.keys(root.pendingShortcuts)) {
                const p = root.pendingShortcuts[id];
                root.kdeRun(["shortcut", id, String(p.key), p.label], null, true);
            }
            if (root.pendingHidden !== null)
                GlobalConfig.launcher.hiddenApps = root.pendingHidden;
            if (root.pendingOps.length > 0) {
                const ops = root.pendingOps;
                root.update(d => {
                    for (const op of ops)
                        op(d);
                });
            }
            root.pendingOps = [];
            root.pendingHidden = null;
            root.pendingShortcuts = ({});
            // Picks up the new shortcuts and the saved menu.
            root.kdeRun(["dump"], () => {
                root.saving = false;
                Toaster.toast(qsTr("Launcher Customizer"), qsTr("Changes saved"), "check_circle");
                if (done)
                    done();
            }, true);
        };
        if (root.stageView)
            root.kdeRun(["commit"], res => {
                if (res?.ok)
                    finish();
                else
                    root.saving = false;
            }, false, true);
        else
            finish();
    }

    /// Drop every unsaved change, then run done().
    function discard(done: var): void {
        root.pendingOps = [];
        root.pendingHidden = null;
        root.pendingShortcuts = ({});
        root.kdeRun(["discard"], () => {
            if (done)
                done();
        }, false, true);
    }

    /// Change the plugin's config when the user saves.
    function edit(mutator: var): void {
        root.pendingOps = root.pendingOps.concat([mutator]);
    }

    function pinned(categoryId: string, appId: string): bool {
        return !!appId && (root.cfg.pinned?.[categoryId] ?? []).includes(appId);
    }

    function shortcutOf(app: var): string {
        const p = root.pendingShortcuts[app?.id ?? ""];
        return p ? p.text : (app?.shortcut ?? "");
    }

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
        root.edit(d => d.iconStyle = style);
    }

    function setSetting(key: string, value: var): void {
        root.edit(d => d[key] = value);
    }

    /// Category background: { enabled, color } ("#rrggbb" or "#aarrggbb").
    function setLook(categoryId: string, look: var): void {
        root.edit(d => {
            d.looks = d.looks && typeof d.looks === "object" ? d.looks : {};
            d.looks[categoryId] = Object.assign({}, d.looks[categoryId] ?? {}, look);
        });
    }

    /// From the editor: waits for Save.
    function pin(categoryId: string, appId: string, on: bool): void {
        root.edit(d => root.pinIn(d, categoryId, appId, on));
    }

    /// From the launcher's own app menu: right away.
    function pinNow(categoryId: string, appId: string, on: bool): void {
        root.update(d => root.pinIn(d, categoryId, appId, on));
    }

    function pinIn(d: var, categoryId: string, appId: string, on: bool): void {
        d.pinned = d.pinned && typeof d.pinned === "object" ? d.pinned : {};
        const list = (d.pinned[categoryId] ?? []).filter(x => x !== appId);
        if (on)
            list.push(appId);
        if (list.length > 0)
            d.pinned[categoryId] = list;
        else
            delete d.pinned[categoryId];
    }

    /// "Uninstall…" from the launcher: Caelestia's own dialog shows what will
    /// be removed, asks, and runs it (uninstall.py does the work).
    function uninstall(appId: string): void {
        const app = LauncherCustomizer.kde?.apps?.[appId];
        if (!app?.file) {
            Toaster.toast(qsTr("Launcher Customizer"), qsTr("Couldn't find the app's launcher file"), "warning");
            return;
        }
        uninstallLoader.active = true;
        uninstallLoader.item.open(app, appId);
    }

    // Created the first time it is needed, so it costs nothing until then.
    LazyLoader {
        id: uninstallLoader

        active: false

        UninstallDialog {
            pluginDir: root.pluginDir
            onFinished: removed => {
                if (removed)
                    syncDebounce.restart();
            }
        }
    }

    function markSeen(appId: string): void {
        root.update(d => {
            d.seen = d.seen && typeof d.seen === "object" ? d.seen : {};
            d.seen[appId] = Math.round(Date.now() / 1000);
        });
    }

    // ============================================ hidden apps (shared with Settings)

    // One list for both: Caelestia's own hidden apps (Settings → Applications
    // & Shortcuts, and the launcher's "Hide app"). Entries KDE marks NoDisplay
    // count as hidden too, and showing one clears that flag.

    function hiddenInCaelestia(appId: string): bool {
        return !!appId && Strings.testRegexList(GlobalConfig.launcher.hiddenApps ?? [], appId);
    }

    /// Hidden by a pattern in the config file, so it cannot be toggled per app.
    function hiddenByPattern(appId: string): bool {
        return root.hiddenInCaelestia(appId) && !(GlobalConfig.launcher.hiddenApps ?? []).includes(appId);
    }

    readonly property var hiddenList: root.pendingHidden ?? (GlobalConfig.launcher.hiddenApps ?? [])

    function appHidden(app: var): bool {
        return !!app && (!!app.noDisplay || (!!app.id && Strings.testRegexList(root.hiddenList, app.id)));
    }

    function setAppHidden(app: var, hide: bool): void {
        if (!app?.id)
            return;
        const list = root.hiddenList.slice();
        if (hide) {
            if (!Strings.testRegexList(list, app.id))
                root.pendingHidden = list.concat([app.id]);
            return;
        }
        if (root.hiddenByPattern(app.id))
            Toaster.toast(qsTr("Launcher Customizer"), qsTr("%1 is hidden by a pattern in Caelestia's config file").arg(app.name ?? app.id), "warning");
        if (list.includes(app.id))
            root.pendingHidden = list.filter(x => x !== app.id);
        if (app.noDisplay)
            root.appSet(app.id, { noDisplay: false });
    }

    // =================================================== backup and share

    function exportLayout(): void {
        saveDialog.running = true;
    }

    function importLayout(): void {
        if (root.dirty) {
            Toaster.toast(qsTr("Launcher Customizer"), qsTr("Save or discard your changes before importing a layout"), "warning");
            return;
        }
        openDialog.running = true;
    }

    function doExport(path: string): void {
        if (!path.endsWith(".tar.gz"))
            path += ".tar.gz";
        const hidden = JSON.stringify((GlobalConfig.launcher.hiddenApps ?? []).slice());
        root.kdeRun(["export", path, hidden], res => {
            if (res?.ok)
                Toaster.toast(qsTr("Layout exported"), path, "check_circle");
        }, true);
    }

    function doImport(path: string): void {
        root.kdeRun(["import", path], res => {
            if (!res?.ok)
                return;
            const got = res.created ?? {};
            const cur = root.current();
            const next = got.plugin && typeof got.plugin === "object" ? got.plugin : {};
            next.seen = cur.seen ?? {};
            next.seenSince = cur.seenSince ?? Math.round(Date.now() / 1000);
            root.write(next);
            const hidden = (GlobalConfig.launcher.hiddenApps ?? []).slice();
            for (const id of (got.hiddenApps ?? []))
                if (!hidden.includes(id))
                    hidden.push(id);
            GlobalConfig.launcher.hiddenApps = hidden;
            Toaster.toast(qsTr("Layout imported"), qsTr("Undo puts your previous layout back"), "check_circle");
        }, true);
    }

    Process {
        id: saveDialog

        command: ["kdialog", "--title", qsTr("Export launcher layout"), "--getsavefilename", Quickshell.env("HOME") + "/launcher-layout.tar.gz", "Launcher layout (*.tar.gz)"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    root.doExport(text.trim());
            }
        }
    }

    Process {
        id: openDialog

        command: ["kdialog", "--title", qsTr("Import launcher layout"), "--getopenfilename", Quickshell.env("HOME"), "Launcher layout (*.tar.gz)"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim())
                    root.doImport(text.trim());
            }
        }
    }

    // ===================================================== KDE menu bridge

    property bool kdeBusy: false
    property string kdeError: ""
    property var kdeQueue: []
    property double kdeUpdated: 0
    property var themeIcons: []
    property bool themeIconsLoading: false

    signal kdeChanged(var result)

    /// Run kdemenu.py; commands are queued so edits never race. Editor
    /// commands work on the working copy; `real` ones (the launcher's own
    /// drag order, refreshes, export/import) on the saved menu.
    function kdeRun(args: var, done: var, real: bool, staging: bool): void {
        const q = root.kdeQueue.slice();
        q.push({ args: args, done: done, real: !!real, staging: !!staging || !real });
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
        kdeProc.environment = job.staging ? ({ LC_STAGE: root.stageDir }) : ({});
        kdeProc.command = ["python3", "-I", root.pluginDir + "/kdemenu.py"].concat(job.args);
        kdeProc.running = true;
    }

    property string lastKdeText: ""

    function kdeResult(text: string): void {
        const job = kdeProc.job;
        // A plain re-read that matches the last one: nothing to parse or update.
        if (job?.args?.[0] === "dump" && !job.staging && text === root.lastKdeText) {
            if (job?.done)
                job.done({ ok: true });
            root.kdeBusy = root.kdeQueue.length > 0;
            root.kdeNext();
            return;
        }
        let res = null;
        try {
            res = JSON.parse(text);
        } catch (e) {
            res = { ok: false, error: "kdemenu.py: " + (text || "no output").slice(0, 200) };
        }
        if (res.ok && res.categories) {
            if (job?.staging) {
                root.stageView = res.staged ? res : null;
                root.kdeDirty = !!res.stageDirty;
                // Undone back to the saved menu: drop the working copy, so
                // changes made in KDE show up again.
                if (res.staged && !res.stageDirty && !root.saving)
                    root.kdeRun(["discard"], null, false, true);
            }
            // An identical read changes nothing: skip it, so the launcher does
            // not recompute everything (and rebuild its tiles) for no reason.
            const same = !res.staged && text === root.lastKdeText;
            if (!res.staged && !same) {
                root.lastKdeText = text;
                LauncherCustomizer.kde = res;
            }
            root.kdeUpdated = Date.now();
            root.kdeError = "";
            if (!same)
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
        if (root.kdeQueue.some(j => j.args[0] === "dump" && j.real && !j.staging))
            return;
        root.kdeRun(["dump"], null, true);
    }

    /// The editor's view: the working copy if there is one.
    function refreshView(): void {
        root.kdeRun(["dump"], null, true, true);
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
    function setShortcut(appId: string, key: int, label: string, text: string): void {
        const p = Object.assign({}, root.pendingShortcuts);
        p[appId] = { key: key, label: label, text: key ? (text ?? "") : "" };
        root.pendingShortcuts = p;
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
        // Opening the launcher only checks whether anything changed (cheap);
        // the full read runs only then. File watchers catch the rest.
        function onLauncherOpenChanged(): void {
            if (Visibilities.launcherOpen)
                root.kdeRun(["stamp"], res => {
                    if (res?.ok && res.stamp !== LauncherCustomizer.kde?.stamp)
                        root.refreshKde();
                }, true);
        }

        target: Visibilities
    }

    Timer {
        id: syncDebounce

        interval: 400
        onTriggered: root.refreshKde()
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.shellReady && root.pageOpen && !root.dirty
        onTriggered: root.kdeRun(["stamp"], res => {
            if (res?.ok && res.stamp !== LauncherCustomizer.kde?.stamp)
                root.refreshKde();
        }, true)
    }

    // ============================================================ editor

    /// The editor is a page in Settings: Panels & Interface -> Launcher.
    function openEditor(appId: string): void {
        LauncherCustomizer.focusRequest = appId;
        WindowFactory.create(null, {
            initialPageIdx: "panels",
            initialSubPage: "launcherCustomizer"
        });
        if (appId) {
            LauncherCustomizer.focusSerial++;
            focusClear.restart();
        }
    }

    Timer {
        id: focusClear

        interval: 2500
        onTriggered: LauncherCustomizer.focusRequest = ""
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
        for (const k of stale)
            delete cur[k];
        // New-app dots start from the first run, not from everything already installed.
        const startDots = cur.seenSince === undefined;
        if (startDots)
            cur.seenSince = Math.round(Date.now() / 1000);
        if (stale.length > 0 || startDots)
            root.write(cur);
        LauncherCustomizer.editorUrl = Qt.resolvedUrl("EditorView.qml");
        LauncherCustomizer.store = root;
        LauncherCustomizer.pluginActive = true;
        root.refreshKde();
        // Unsaved edits from before a restart: the editor page loads them when
        // it opens, so nothing to read now.
    }

    Component.onDestruction: {
        Quickshell.execDetached(["rm", "-f", root.pluginDir + "/icon.svg"]);
        if (root.shellReady) {
            LauncherCustomizer.pluginActive = false;
            LauncherCustomizer.store = null;
        }
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
            // The launcher's own drag order is saved right away, not staged.
            root.kdeRun(["layout", categoryId.slice(4)].concat(tokens), null, true);
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

        function onPinRequested(categoryId: string, appId: string, on: bool): void {
            root.pinNow(categoryId, appId, on);
        }

        function onSeenRequested(appId: string): void {
            root.markSeen(appId);
        }

        function onUninstallRequested(appId: string): void {
            root.uninstall(appId);
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
            Toaster.toast(qsTr("Launcher Customizer"), qsTr("Caelestia changed in its last update, so this is off for now. Checking for a fix..."), "warning");
            updater.checkNow();
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

    // Opt-in updates: asks before changing anything (see updater/update.sh).
    Updater {
        id: updater

        pluginDir: root.pluginDir
    }
}
