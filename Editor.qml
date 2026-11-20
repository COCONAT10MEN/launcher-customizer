pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.launcher.services
import "."

// Launcher Customizer editor. In KDE mode every change is written to the KDE
// application menu (exactly like KDE's Menu Editor) and read back, so Kickoff,
// the KDE Menu Editor and this launcher always agree.
FloatingWindow {
    id: win

    required property var store

    readonly property bool kde: LauncherCustomizer.source === "kde"

    property string selectedKey: ""
    property string search: ""
    property string filter: "category"     // category | all | uncategorized
    property var expanded: ({})
    property var selection: ({})            // appId -> true
    property string pickerAction: ""        // move | add | bulk-move | bulk-add
    property string pickerApp: ""
    property bool creating: false
    property var newIcon: ({ kind: "material", value: "label" })

    // --------------------------------------------------------------- model

    function kdeRow(n: var, depth: int): var {
        const ic = LauncherCustomizer.kdeIcon(n);
        return { key: "kde:" + n.path, path: n.path, name: n.name, icon: ic.icon, iconSource: ic.iconSource, depth: depth, hidden: n.hidden, custom: n.custom, hasOverride: n.hasOverride, count: n.allApps.length, hasChildren: n.children.length > 0, kdeNode: n, raw: null };
    }

    // Visible category rows (collapsed subcategories left out).
    readonly property var rows: {
        void LauncherCustomizer.data;
        const out = [];
        if (win.kde) {
            const walk = (nodes, depth) => {
                for (const n of nodes) {
                    out.push(win.kdeRow(n, depth));
                    if (n.children.length > 0 && win.expanded[n.path])
                        walk(n.children, depth + 1);
                }
            };
            walk(LauncherCustomizer.kde?.categories ?? [], 0);
        } else {
            for (const c of win.store.fullList()) {
                if (c.id === "favorites" || c.id === "all")
                    continue;
                const ic = LauncherCustomizer.caelestiaIcon(c.icon || "label");
                out.push({ key: c.id, path: "", name: c.name, icon: ic.icon, iconSource: ic.iconSource, depth: 0, hidden: c.hidden, custom: c.custom, hasOverride: false, count: win.caelestiaCounts[c.id] ?? 0, hasChildren: false, kdeNode: null, raw: c });
            }
        }
        return out;
    }
    // Every category including collapsed subcategories.
    readonly property var allRows: {
        void LauncherCustomizer.data;
        if (!win.kde)
            return win.rows;
        const out = [];
        const walk = (nodes, depth) => {
            for (const n of nodes) {
                out.push(win.kdeRow(n, depth));
                walk(n.children, depth + 1);
            }
        };
        walk(LauncherCustomizer.kde?.categories ?? [], 0);
        return out;
    }
    readonly property var nameOf: {
        const m = {};
        for (const r of win.allRows)
            m[r.key] = r.name;
        return m;
    }
    readonly property var selected: win.allRows.find(r => r.key === win.selectedKey) ?? null

    readonly property var apps: (LauncherCustomizer.data, Apps.allApps().slice().sort((a, b) => String(a.name).localeCompare(String(b.name))))

    // KDE: appId -> [category keys the app is listed in directly]
    readonly property var kdeMembership: {
        const m = {};
        const walk = nodes => {
            for (const n of nodes) {
                for (const a of n.apps)
                    (m[a] = m[a] || []).push("kde:" + n.path);
                walk(n.children);
            }
        };
        walk(LauncherCustomizer.kde?.categories ?? []);
        return m;
    }
    readonly property var manualSet: {
        const s = {};
        if (win.kde)
            for (const a of (LauncherCustomizer.kde?.manualApps ?? []))
                s[a] = true;
        else
            for (const a of Object.keys(LauncherCustomizer.assignments))
                s[a] = true;
        return s;
    }
    readonly property var caelestiaCategory: {
        void LauncherCustomizer.data;
        const m = {};
        if (!win.kde)
            for (const a of win.apps)
                m[a.id] = Categories.categoryForApp(a);
        return m;
    }
    readonly property var caelestiaCounts: {
        const c = {};
        for (const id of Object.values(win.caelestiaCategory))
            c[id] = (c[id] ?? 0) + 1;
        return c;
    }

    function membershipsOf(appId: string): var {
        if (win.kde)
            return (win.kdeMembership[appId] ?? []).filter(k => k !== "kde:Applications");
        const c = win.caelestiaCategory[appId];
        return c && c !== "other" ? [c] : [];
    }

    function inSelected(app): bool {
        const s = win.selected;
        if (!s)
            return false;
        if (win.kde)
            return s.kdeNode?.allApps.includes(app.id) ?? false;
        return win.caelestiaCategory[app.id] === win.selectedKey;
    }

    readonly property var shownApps: {
        const q = win.search.trim().toLowerCase();
        let list = win.apps;
        if (q.length > 0)
            list = list.filter(a => String(a.name).toLowerCase().includes(q) || String(a.id).toLowerCase().includes(q) || String(a.genericName ?? "").toLowerCase().includes(q));
        else if (win.filter === "category")
            list = list.filter(a => win.inSelected(a));
        if (win.filter === "uncategorized")
            list = list.filter(a => win.membershipsOf(a.id).length === 0);
        return list;
    }
    readonly property var selectedIds: Object.keys(win.selection).filter(k => win.selection[k])

    // ------------------------------------------------------------- actions

    function focusApp(appId: string): void {
        const app = win.apps.find(a => a.id === appId);
        if (!app)
            return;
        const m = win.membershipsOf(appId);
        if (m.length > 0)
            win.selectedKey = m[0];
        win.search = app.name;
        searchField.text = app.name;
        win.openPicker("move", appId);
    }

    function selectCategory(key: string): void {
        win.selectedKey = key;
        win.search = "";
        searchField.text = "";
        win.filter = "category";
    }

    function toggleSelect(appId: string): void {
        const s = Object.assign({}, win.selection);
        s[appId] = !s[appId];
        win.selection = s;
    }

    function openPicker(action: string, appId: string): void {
        win.pickerAction = action;
        win.pickerApp = appId;
        const many = action.startsWith("bulk");
        const what = many ? qsTr("%n app(s)", "", win.selectedIds.length) : (win.apps.find(a => a.id === appId)?.name ?? appId);
        const adding = action.endsWith("add");
        const exclude = many ? [] : (adding ? win.membershipsOf(appId) : []);
        catPicker.open(adding ? qsTr("Also show %1 in…").arg(what) : qsTr("Move %1 to…").arg(what),
            adding ? qsTr("It stays in its current categories too.") : (win.kde ? qsTr("It is taken out of every category it is in now.") : ""), exclude);
    }

    function pickerChose(key: string): void {
        catPicker.close();
        const ids = win.pickerAction.startsWith("bulk") ? win.selectedIds : [win.pickerApp];
        for (const id of ids) {
            if (win.kde) {
                const path = key.slice(4);
                if (win.pickerAction.endsWith("add"))
                    win.store.kdeAdd(id, path);
                else
                    win.store.kdeMove(id, path, []);
            } else {
                win.store.assign(id, key);
            }
        }
        if (win.pickerAction.startsWith("bulk"))
            win.selection = ({});
    }

    function resetApps(ids: var): void {
        for (const id of ids) {
            if (win.kde)
                win.store.kdeResetApp(id);
            else
                win.store.unassign(id);
        }
        win.selection = ({});
    }

    function undo(): void {
        if (win.kde)
            win.store.kdeUndo();
        else
            win.store.undoJson();
    }

    readonly property bool canUndo: win.kde ? (LauncherCustomizer.kde?.canUndo ?? false) : win.store.history.length > 0

    function rename(name: string): void {
        const s = win.selected;
        if (!s || !name.trim() || name.trim() === s.name)
            return;
        if (win.kde)
            win.store.kdeSet(s.path, { name: name.trim() });
        else
            win.editCaelestia(list => list.find(c => c.id === s.key).name = name.trim());
    }

    function setHidden(hidden: bool): void {
        const s = win.selected;
        if (!s)
            return;
        if (win.kde)
            win.store.kdeSet(s.path, { hidden: hidden ? "1" : "0" });
        else
            win.editCaelestia(list => list.find(c => c.id === s.key).hidden = hidden);
    }

    function iconPicked(choice: var): void {
        iconPicker.close();
        if (win.creating) {
            win.newIcon = choice;
            return;
        }
        const s = win.selected;
        if (!s)
            return;
        if (win.kde) {
            win.store.kdeSetIcon(s.path, choice);
        } else {
            const v = choice.kind === "default" ? "" : (choice.kind === "theme" ? "theme:" + choice.value : choice.value);
            win.editCaelestia(list => list.find(c => c.id === s.key).icon = v || "label");
        }
    }

    function editCaelestia(mutator: var): void {
        const list = win.store.fullList();
        mutator(list);
        win.store.saveCategories(list);
    }

    function moveCategory(delta: int): void {
        const s = win.selected;
        if (!s)
            return;
        if (win.kde) {
            if (s.path.includes("/"))
                return;
            const order = (LauncherCustomizer.kde?.categories ?? []).map(c => c.path);
            const i = order.indexOf(s.path);
            const j = i + delta;
            if (i < 0 || j < 0 || j >= order.length)
                return;
            order.splice(i, 1);
            order.splice(j, 0, s.path);
            win.store.kdeOrder(order);
        } else {
            win.editCaelestia(list => {
                const i = list.findIndex(c => c.id === s.key);
                let j = i + delta;
                while (j >= 0 && j < list.length && (list[j].id === "favorites" || list[j].id === "all"))
                    j += delta;
                if (i < 0 || j < 0 || j >= list.length)
                    return;
                const [item] = list.splice(i, 1);
                list.splice(j, 0, item);
            });
        }
    }

    function deleteCategory(): void {
        const s = win.selected;
        if (!s)
            return;
        if (win.kde) {
            win.store.kdeDelete(s.path);
        } else {
            win.store.snapshotJson();
            const rest = win.store.fullList().filter(c => c.id !== s.key);
            win.store.update(d => {
                d.categories = rest;
                if (d.assignments)
                    for (const k of Object.keys(d.assignments))
                        if (d.assignments[k] === s.key)
                            delete d.assignments[k];
            });
        }
        win.selectedKey = "";
    }

    function createCategory(name: string): void {
        const n = name.trim();
        if (!n)
            return;
        const ic = win.newIcon;
        if (win.kde) {
            win.store.kdeNew(n, ic.kind === "theme" || ic.kind === "file" ? ic.value : "folder", created => {
                win.selectedKey = "kde:" + created;
                if (ic.kind === "material")
                    win.store.kdeSetIcon(created, ic);
            });
        } else {
            const id = "custom-" + Date.now().toString(36);
            const icon = ic.kind === "theme" ? "theme:" + ic.value : ic.value;
            win.editCaelestia(list => {
                const at = list.findIndex(c => c.id === "other");
                list.splice(at < 0 ? list.length : at, 0, { id: id, name: n, icon: icon || "label", xdg: [], hidden: false, custom: true });
            });
            win.selectedKey = id;
        }
        win.creating = false;
        newName.text = "";
        win.newIcon = { kind: "material", value: "label" };
    }

    // --------------------------------------------------------------- window

    title: qsTr("Launcher Categories")
    color: Colours.palette.m3surface
    implicitWidth: 1280
    implicitHeight: 800
    minimumSize.width: 980
    minimumSize.height: 560

    onRowsChanged: {
        if (!win.selectedKey || !win.allRows.some(r => r.key === win.selectedKey))
            win.selectedKey = win.rows.length > 0 ? win.rows[0].key : "";
    }

    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (iconPicker.visible)
                iconPicker.close();
            else if (catPicker.visible)
                catPicker.close();
            else if (win.creating)
                win.creating = false;
            else if (win.selectedIds.length > 0)
                win.selection = ({});
            else
                win.visible = false;
        }
    }

    Shortcut {
        sequences: [StandardKey.Find]
        onActivated: searchField.forceActiveFocus()
    }

    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: win.canUndo
        onActivated: win.undo()
    }

    Shortcut {
        sequences: [StandardKey.New]
        onActivated: {
            win.creating = true;
            newName.forceActiveFocus();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        // ======================================================== header
        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                spacing: 0

                StyledText {
                    text: qsTr("Launcher Categories")
                    font: Tokens.font.title.large
                }

                StyledText {
                    text: !win.kde ? qsTr("Using Caelestia's own category list (not shared with KDE)") : (win.store.kdeError ? qsTr("KDE menu error: %1").arg(win.store.kdeError) : (win.store.kdeBusy ? qsTr("Syncing with the KDE menu…") : qsTr("Synced both ways with the KDE application menu")))
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: win.store.kdeError && win.kde ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                }
            }

            StyledText {
                text: qsTr("Categories from")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.medium
            }

            TextButton {
                text: qsTr("KDE menu")
                type: win.kde ? TextButton.Filled : TextButton.Tonal
                onClicked: win.store.setSource("kde")
            }

            TextButton {
                text: qsTr("Caelestia")
                type: !win.kde ? TextButton.Filled : TextButton.Tonal
                onClicked: win.store.setSource("caelestia")
            }

            Item {
                implicitWidth: Tokens.spacing.medium
            }

            IconButton {
                icon: "undo"
                type: IconButton.Tonal
                disabled: !win.canUndo
                onClicked: win.undo()
            }

            IconButton {
                icon: "sync"
                type: IconButton.Tonal
                visible: win.kde
                onClicked: win.store.refreshKde()
            }

            TextButton {
                visible: win.kde
                text: qsTr("KDE Menu Editor")
                type: TextButton.Tonal
                onClicked: win.store.openKMenuEdit()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Tokens.spacing.large

            // ================================================ left column
            ColumnLayout {
                Layout.preferredWidth: 340
                Layout.maximumWidth: 340
                Layout.fillHeight: true
                spacing: Tokens.spacing.medium

                StyledRect {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Tokens.padding.small

                            StyledText {
                                Layout.fillWidth: true
                                text: qsTr("Categories")
                                font: Tokens.font.title.medium
                            }

                            IconButton {
                                icon: win.creating ? "close" : "add"
                                type: IconButton.Tonal
                                onClicked: {
                                    win.creating = !win.creating;
                                    if (win.creating)
                                        newName.forceActiveFocus();
                                }
                            }
                        }

                        // New category form
                        StyledRect {
                            Layout.fillWidth: true
                            visible: win.creating
                            implicitHeight: newForm.implicitHeight + Tokens.padding.medium * 2
                            radius: Tokens.rounding.medium
                            color: Colours.palette.m3surfaceContainerHigh

                            RowLayout {
                                id: newForm

                                anchors.fill: parent
                                anchors.margins: Tokens.padding.medium
                                spacing: Tokens.spacing.small

                                StyledRect {
                                    implicitWidth: 40
                                    implicitHeight: 40
                                    radius: Tokens.rounding.full
                                    color: Colours.palette.m3secondaryContainer

                                    CategoryIcon {
                                        anchors.centerIn: parent
                                        icon: win.newIcon.kind === "material" ? win.newIcon.value : ""
                                        iconSource: win.newIcon.kind === "material" ? "" : LauncherCustomizer.imageFor(win.newIcon.value)
                                        size: 22
                                        color: Colours.palette.m3onSecondaryContainer
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            iconPicker.allowDefault = false;
                                            iconPicker.open(win.newIcon.kind);
                                        }
                                    }
                                }

                                StyledTextField {
                                    id: newName

                                    Layout.fillWidth: true
                                    placeholderText: qsTr("New category name")
                                    onAccepted: win.createCategory(text)
                                }

                                IconButton {
                                    icon: "check"
                                    type: IconButton.Filled
                                    disabled: newName.text.trim().length === 0
                                    onClicked: win.createCategory(newName.text)
                                }
                            }
                        }

                        ListView {
                            id: catList

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 2
                            model: win.rows
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar {
                                flickable: catList
                            }

                            delegate: StyledRect {
                                id: catRow

                                required property var modelData
                                readonly property bool isSelected: win.selectedKey === modelData.key

                                width: catList.width
                                implicitHeight: modelData.depth > 0 ? 40 : 46
                                radius: Tokens.rounding.medium
                                color: isSelected ? Colours.palette.m3secondaryContainer : (catMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : "transparent")
                                opacity: modelData.hidden || modelData.count === 0 ? 0.6 : 1

                                MouseArea {
                                    id: catMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: win.selectCategory(catRow.modelData.key)
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Tokens.padding.small + catRow.modelData.depth * 22
                                    anchors.rightMargin: Tokens.padding.medium
                                    spacing: Tokens.spacing.small

                                    IconButton {
                                        icon: win.expanded[catRow.modelData.path] ? "expand_more" : "chevron_right"
                                        type: IconButton.Text
                                        visible: win.kde
                                        opacity: catRow.modelData.hasChildren ? 1 : 0
                                        disabled: !catRow.modelData.hasChildren
                                        onClicked: {
                                            const e = Object.assign({}, win.expanded);
                                            e[catRow.modelData.path] = !e[catRow.modelData.path];
                                            win.expanded = e;
                                        }
                                    }

                                    CategoryIcon {
                                        icon: catRow.modelData.icon
                                        iconSource: catRow.modelData.iconSource
                                        size: 22
                                        color: catRow.isSelected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: catRow.modelData.name
                                        elide: Text.ElideRight
                                        color: catRow.isSelected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                                        font: catRow.modelData.depth > 0 ? Tokens.font.body.medium : Tokens.font.label.large
                                    }

                                    MaterialIcon {
                                        visible: catRow.modelData.custom
                                        text: "person"
                                        color: Colours.palette.m3primary
                                        fontStyle: Tokens.font.icon.small
                                    }

                                    StyledText {
                                        text: catRow.modelData.hidden ? qsTr("hidden") : (catRow.modelData.count === 0 ? qsTr("empty") : String(catRow.modelData.count))
                                        color: Colours.palette.m3onSurfaceVariant
                                        font: Tokens.font.label.medium
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: Tokens.padding.small
                            visible: win.kde
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                text: "person"
                                color: Colours.palette.m3primary
                                fontStyle: Tokens.font.icon.small
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: qsTr("made by you. Empty categories stay out of the launcher and KDE.")
                                wrapMode: Text.WordWrap
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.small
                            }
                        }

                        TextButton {
                            visible: !win.kde
                            text: qsTr("Reset everything")
                            type: TextButton.Text
                            onClicked: win.store.resetCaelestia()
                        }
                    }
                }

            }

            // ================================================ right column
            ColumnLayout {
                Layout.fillWidth: true
                // Take the remaining width instead of growing to fit content.
                Layout.preferredWidth: 1
                Layout.minimumWidth: 0
                Layout.fillHeight: true
                spacing: Tokens.spacing.medium

                // Category details
                StyledRect {
                    Layout.fillWidth: true
                    visible: win.selected !== null
                    implicitHeight: details.implicitHeight + Tokens.padding.large * 2
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer

                    ColumnLayout {
                        id: details

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.large
                        spacing: Tokens.spacing.medium

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.medium

                            // Icon: click to change
                            StyledRect {
                                implicitWidth: 56
                                implicitHeight: 56
                                radius: Tokens.rounding.full
                                color: iconMouse.containsMouse ? Colours.palette.m3primaryContainer : Colours.palette.m3secondaryContainer

                                CategoryIcon {
                                    anchors.centerIn: parent
                                    icon: win.selected?.icon ?? ""
                                    iconSource: win.selected?.iconSource ?? ""
                                    size: 30
                                    color: Colours.palette.m3onSecondaryContainer
                                }

                                StyledRect {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    implicitWidth: 22
                                    implicitHeight: 22
                                    radius: Tokens.rounding.full
                                    color: Colours.palette.m3primary

                                    MaterialIcon {
                                        anchors.centerIn: parent
                                        text: "edit"
                                        color: Colours.palette.m3onPrimary
                                        fontStyle: Tokens.font.icon.small
                                    }
                                }

                                MouseArea {
                                    id: iconMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        iconPicker.allowDefault = true;
                                        iconPicker.open(win.selected?.icon ? "material" : "theme");
                                    }
                                }
                            }

                            StyledTextField {
                                id: nameField

                                Layout.fillWidth: true
                                placeholderText: qsTr("Name")
                                text: win.selected?.name ?? ""
                                onEditingFinished: win.rename(text)
                            }

                            IconButton {
                                icon: "arrow_upward"
                                type: IconButton.Tonal
                                disabled: win.kde && (win.selected?.path ?? "").includes("/")
                                onClicked: win.moveCategory(-1)
                            }

                            IconButton {
                                icon: "arrow_downward"
                                type: IconButton.Tonal
                                disabled: win.kde && (win.selected?.path ?? "").includes("/")
                                onClicked: win.moveCategory(1)
                            }

                            IconButton {
                                icon: win.selected?.hidden ? "visibility_off" : "visibility"
                                type: IconButton.Tonal
                                onClicked: win.setHidden(!win.selected?.hidden)
                            }

                            IconButton {
                                icon: "settings_backup_restore"
                                type: IconButton.Tonal
                                visible: win.kde && (win.selected?.hasOverride ?? false)
                                onClicked: win.store.kdeResetDir(win.selected.path)
                            }

                            IconButton {
                                icon: "delete"
                                type: IconButton.Tonal
                                visible: win.selected?.custom ?? false
                                onClicked: win.deleteCategory()
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                const s = win.selected;
                                if (!s)
                                    return "";
                                const parts = [];
                                if (s.hidden)
                                    parts.push(win.kde ? qsTr("Hidden in KDE and the launcher; its apps stay in All Applications and search.") : qsTr("Hidden: its apps go to the next matching category, or Other."));
                                if (win.kde && s.hasOverride)
                                    parts.push(qsTr("Renamed or re-iconed by you; the reset button restores KDE's default."));
                                if (win.kde && s.custom)
                                    parts.push(qsTr("Made by you. Deleting it sends its apps back to where KDE puts them."));
                                if (win.kde && !s.custom)
                                    parts.push(qsTr("Built-in KDE category: apps join it automatically by their tags."));
                                return parts.join(" ");
                            }
                            visible: text.length > 0
                            wrapMode: Text.WordWrap
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.body.small
                        }

                        StyledTextField {
                            Layout.fillWidth: true
                            visible: !win.kde && (win.selected?.key ?? "") !== "other"
                            placeholderText: qsTr("Auto-include apps tagged")
                            supportingText: qsTr("Comma-separated XDG tags, e.g. Game, Emulator. Empty: only apps you move here.")
                            text: (win.selected?.raw?.xdg ?? []).join(", ")
                            onEditingFinished: {
                                const key = win.selectedKey;
                                const tags = text.split(",").map(t => t.trim()).filter(t => t.length > 0);
                                if (tags.join(",") !== (win.selected?.raw?.xdg ?? []).join(","))
                                    win.editCaelestia(list => list.find(c => c.id === key).xdg = tags);
                            }
                        }
                    }
                }

                // Search + filters
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledTextField {
                        id: searchField

                        Layout.fillWidth: true
                        Layout.minimumWidth: 160
                        Layout.preferredWidth: 1
                        leadingIcon: "search"
                        placeholderText: qsTr("Search all apps  (Ctrl+F)")
                        onTextChanged: win.search = text
                    }

                    Repeater {
                        model: [
                            { key: "category", label: qsTr("This category") },
                            { key: "all", label: qsTr("All apps") },
                            { key: "uncategorized", label: win.kde ? qsTr("Lost & Found") : qsTr("Uncategorised") }
                        ]

                        delegate: TextButton {
                            required property var modelData

                            text: modelData.label
                            type: win.filter === modelData.key ? TextButton.Filled : TextButton.Tonal
                            onClicked: win.filter = modelData.key
                        }
                    }
                }

                // Bulk bar
                StyledRect {
                    Layout.fillWidth: true
                    visible: win.selectedIds.length > 0
                    implicitHeight: bulkRow.implicitHeight + Tokens.padding.small * 2
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3primaryContainer

                    RowLayout {
                        id: bulkRow

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.small
                        anchors.leftMargin: Tokens.padding.large
                        spacing: Tokens.spacing.small

                        StyledText {
                            Layout.fillWidth: true
                            text: qsTr("%n app(s) selected", "", win.selectedIds.length)
                            color: Colours.palette.m3onPrimaryContainer
                            font: Tokens.font.label.large
                        }

                        TextButton {
                            text: qsTr("Move to…")
                            onClicked: win.openPicker("bulk-move", "")
                        }

                        TextButton {
                            visible: win.kde
                            text: qsTr("Also add to…")
                            type: TextButton.Tonal
                            onClicked: win.openPicker("bulk-add", "")
                        }

                        TextButton {
                            text: qsTr("Reset")
                            type: TextButton.Tonal
                            onClicked: win.resetApps(win.selectedIds)
                        }

                        TextButton {
                            text: qsTr("Select all shown")
                            type: TextButton.Text
                            onClicked: {
                                const s = {};
                                for (const a of win.shownApps)
                                    s[a.id] = true;
                                win.selection = s;
                            }
                        }

                        IconButton {
                            icon: "close"
                            type: IconButton.Text
                            onClicked: win.selection = ({})
                        }
                    }
                }

                StyledText {
                    Layout.leftMargin: Tokens.padding.small
                    text: {
                        const n = win.shownApps.length;
                        if (win.search.trim().length > 0)
                            return qsTr("%n app(s) matching", "", n);
                        if (win.filter === "all")
                            return qsTr("All %n app(s)", "", n);
                        if (win.filter === "uncategorized")
                            return qsTr("%n app(s) without a category", "", n);
                        return qsTr("%n app(s) in %1", "", n).arg(win.selected?.name ?? "");
                    }
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.medium
                }

                // App list
                ListView {
                    id: appList

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: win.shownApps
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: StyledScrollBar {
                        flickable: appList
                    }

                    delegate: StyledRect {
                        id: appRow

                        required property var modelData
                        readonly property string appId: modelData.id
                        readonly property bool checked: !!win.selection[appId]
                        readonly property var member: win.membershipsOf(appId)
                        readonly property bool manual: !!win.manualSet[appId]

                        width: appList.width
                        implicitHeight: appLine.implicitHeight + Tokens.padding.small * 2
                        radius: Tokens.rounding.medium
                        color: checked ? Colours.palette.m3secondaryContainer : (appMouse.containsMouse ? Colours.palette.m3surfaceContainer : "transparent")

                        MouseArea {
                            id: appMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: mouse => {
                                if (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier) || win.selectedIds.length > 0)
                                    win.toggleSelect(appRow.appId);
                            }
                        }

                        RowLayout {
                            id: appLine

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Tokens.padding.small
                            anchors.rightMargin: Tokens.padding.medium
                            spacing: Tokens.spacing.small

                            IconButton {
                                icon: appRow.checked ? "check_box" : "check_box_outline_blank"
                                type: IconButton.Text
                                onClicked: win.toggleSelect(appRow.appId)
                            }

                            IconImage {
                                implicitSize: 32
                                asynchronous: true
                                source: Quickshell.iconPath(appRow.modelData.icon, "application-x-executable")
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Tokens.spacing.small

                                    StyledText {
                                        Layout.maximumWidth: 280
                                        text: appRow.modelData.name
                                        elide: Text.ElideRight
                                        font: Tokens.font.label.large
                                    }

                                    StyledText {
                                        visible: appRow.manual
                                        text: qsTr("· placed by you")
                                        color: Colours.palette.m3primary
                                        font: Tokens.font.body.small
                                    }
                                }

                                // Category chips
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 4

                                    StyledText {
                                        visible: appRow.member.length === 0
                                        text: win.kde ? qsTr("Lost & Found") : qsTr("Other")
                                        color: Colours.palette.m3onSurfaceVariant
                                        font: Tokens.font.body.small
                                    }

                                    Repeater {
                                        model: appRow.member

                                        delegate: StyledRect {
                                            id: chip

                                            required property string modelData

                                            implicitWidth: chipRow.implicitWidth + Tokens.padding.medium * 2
                                            implicitHeight: chipRow.implicitHeight + 4
                                            radius: Tokens.rounding.full
                                            color: Colours.palette.m3surfaceContainerHighest

                                            RowLayout {
                                                id: chipRow

                                                anchors.centerIn: parent
                                                spacing: 2

                                                StyledText {
                                                    text: win.nameOf[chip.modelData] ?? chip.modelData.replace(/^kde:/, "")
                                                    color: Colours.palette.m3onSurfaceVariant
                                                    font: Tokens.font.label.small
                                                }

                                                MaterialIcon {
                                                    visible: win.kde
                                                    text: "close"
                                                    color: chipX.containsMouse ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                                                    fontStyle: Tokens.font.icon.small

                                                    MouseArea {
                                                        id: chipX

                                                        anchors.fill: parent
                                                        anchors.margins: -4
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: win.store.kdeRemove(appRow.appId, chip.modelData.slice(4))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            IconButton {
                                icon: "undo"
                                type: IconButton.Text
                                visible: appRow.manual
                                onClicked: win.resetApps([appRow.appId])
                            }

                            TextButton {
                                visible: win.kde
                                text: qsTr("Also add to…")
                                type: TextButton.Text
                                onClicked: win.openPicker("add", appRow.appId)
                            }

                            TextButton {
                                text: qsTr("Move to…")
                                type: TextButton.Tonal
                                onClicked: win.openPicker("move", appRow.appId)
                            }
                        }
                    }
                }
            }
        }

        // ================================================= footer options
        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.large

            StyledRect {
                visible: win.kde
                implicitWidth: styleRow.implicitWidth + Tokens.padding.large * 2
                implicitHeight: styleRow.implicitHeight + Tokens.padding.small * 2
                radius: Tokens.rounding.large
                color: Colours.palette.m3surfaceContainer

                RowLayout {
                    id: styleRow

                    anchors.centerIn: parent
                    spacing: Tokens.spacing.small

                    StyledText {
                        text: qsTr("Launcher icons")
                        font: Tokens.font.label.large
                    }

                    TextButton {
                        text: qsTr("Material")
                        type: LauncherCustomizer.iconStyle === "material" ? TextButton.Filled : TextButton.Tonal
                        onClicked: win.store.setIconStyle("material")
                    }

                    TextButton {
                        text: qsTr("KDE theme")
                        type: LauncherCustomizer.iconStyle === "theme" ? TextButton.Filled : TextButton.Tonal
                        onClicked: win.store.setIconStyle("theme")
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }
    }

    // ============================================================ overlays

    CategoryPicker {
        id: catPicker

        rows: win.allRows
        onPicked: key => win.pickerChose(key)
    }

    IconPicker {
        id: iconPicker

        store: win.store
        onPicked: choice => win.iconPicked(choice)
    }
}
