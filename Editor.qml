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

// The category editor. Every change is saved straight away; the launcher
// picks it up the next time it rebuilds (immediately if it is open).
FloatingWindow {
    id: win

    required property var store

    property string selectedId: ""
    property string pickerFor: ""
    property string search: ""

    // Re-evaluated whenever the saved data changes.
    readonly property var allCats: (LauncherCustomizer.data, store.fullList())
    readonly property var cats: allCats.filter(c => c.id !== "favorites" && c.id !== "all")
    readonly property var selected: cats.find(c => c.id === selectedId) ?? null
    readonly property var apps: (LauncherCustomizer.data, Apps.allApps().slice().sort((a, b) => String(a.name).localeCompare(String(b.name))))
    readonly property var appCategory: {
        void LauncherCustomizer.data;
        const map = {};
        for (const a of win.apps)
            map[a.id] = Categories.categoryForApp(a);
        return map;
    }
    readonly property var counts: {
        const c = {};
        for (const id of Object.values(win.appCategory))
            c[id] = (c[id] ?? 0) + 1;
        return c;
    }
    readonly property var shownApps: {
        const q = win.search.trim().toLowerCase();
        if (q.length > 0)
            return win.apps.filter(a => String(a.name).toLowerCase().includes(q) || String(a.id).toLowerCase().includes(q));
        return win.apps.filter(a => win.appCategory[a.id] === win.selectedId);
    }
    readonly property string placement: LauncherCustomizer.placement

    function nameOf(id: string): string {
        return win.allCats.find(c => c.id === id)?.name ?? id;
    }

    function isManual(appId: string): bool {
        return LauncherCustomizer.assignments[appId] !== undefined;
    }

    function focusApp(appId: string): void {
        const app = win.apps.find(a => a.id === appId);
        if (!app)
            return;
        win.selectedId = win.appCategory[appId] ?? win.selectedId;
        win.search = app.name;
        searchField.text = app.name;
        win.pickerFor = appId;
    }

    function edit(mutator: var): void {
        const list = win.allCats.map(c => Object.assign({}, c));
        mutator(list);
        win.store.saveCategories(list);
    }

    function move(id: string, delta: int): void {
        win.edit(list => {
            // Favourites and All stay pinned on top.
            const i = list.findIndex(c => c.id === id);
            let j = i + delta;
            while (j >= 0 && j < list.length && (list[j].id === "favorites" || list[j].id === "all"))
                j += delta;
            if (i < 0 || j < 0 || j >= list.length)
                return;
            const [item] = list.splice(i, 1);
            list.splice(j, 0, item);
        });
    }

    function addCategory(): void {
        const id = "custom-" + Date.now().toString(36);
        win.edit(list => {
            const at = list.findIndex(c => c.id === "other");
            list.splice(at < 0 ? list.length : at, 0, { id: id, name: qsTr("New category"), icon: "label", xdg: [], hidden: false, custom: true });
        });
        win.selectedId = id;
        win.search = "";
        searchField.text = "";
    }

    function removeCategory(id: string): void {
        win.store.update(d => {
            d.categories = win.allCats.filter(c => c.id !== id);
            if (d.assignments)
                for (const k of Object.keys(d.assignments))
                    if (d.assignments[k] === id)
                        delete d.assignments[k];
        });
        win.selectedId = win.cats.find(c => c.id !== id)?.id ?? "";
    }

    title: qsTr("Launcher Categories")
    color: Colours.palette.m3surface
    implicitWidth: 1000
    implicitHeight: 680
    minimumSize.width: 780
    minimumSize.height: 500

    Component.onCompleted: {
        if (!win.selectedId && win.cats.length > 0)
            win.selectedId = win.cats[0].id;
    }

    Shortcut {
        sequence: "Escape"
        onActivated: win.visible = false
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.large

        // ---------------------------------------------------- category list
        StyledRect {
            Layout.preferredWidth: 330
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
                        icon: "add"
                        type: IconButton.Tonal
                        onClicked: win.addCategory()
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.leftMargin: Tokens.padding.small
                    Layout.bottomMargin: Tokens.spacing.small
                    text: qsTr("Order sets the launcher's sidebar and which category wins when an app has several tags.")
                    wrapMode: Text.WordWrap
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                }

                ListView {
                    id: catList

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: win.cats
                    boundsBehavior: Flickable.StopAtBounds

                    ScrollBar.vertical: StyledScrollBar {
                        flickable: catList
                    }

                    delegate: StyledRect {
                        id: catRow

                        required property var modelData
                        required property int index
                        readonly property bool isSelected: win.selectedId === modelData.id

                        width: catList.width
                        implicitHeight: 48
                        radius: Tokens.rounding.medium
                        color: isSelected ? Colours.palette.m3secondaryContainer : (catMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : "transparent")
                        opacity: modelData.hidden ? 0.55 : 1

                        MouseArea {
                            id: catMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                win.selectedId = catRow.modelData.id;
                                win.search = "";
                                searchField.text = "";
                                win.pickerFor = "";
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Tokens.padding.medium
                            anchors.rightMargin: Tokens.padding.small
                            spacing: Tokens.spacing.medium

                            MaterialIcon {
                                text: catRow.modelData.icon || "label"
                                color: catRow.isSelected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                                fontStyle: Tokens.font.icon.medium
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: catRow.modelData.name
                                elide: Text.ElideRight
                                color: catRow.isSelected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                                font: Tokens.font.label.large
                            }

                            StyledText {
                                text: catRow.modelData.hidden ? qsTr("hidden") : String(win.counts[catRow.modelData.id] ?? 0)
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.medium
                            }

                            IconButton {
                                icon: "arrow_upward"
                                type: IconButton.Text
                                visible: catMouse.containsMouse || catRow.isSelected
                                disabled: catRow.index === 0
                                onClicked: win.move(catRow.modelData.id, -1)
                            }

                            IconButton {
                                icon: "arrow_downward"
                                type: IconButton.Text
                                visible: catMouse.containsMouse || catRow.isSelected
                                disabled: catRow.index === win.cats.length - 1
                                onClicked: win.move(catRow.modelData.id, 1)
                            }
                        }
                    }
                }

                TextButton {
                    Layout.alignment: Qt.AlignLeft
                    text: qsTr("Reset everything")
                    type: TextButton.Text
                    onClicked: win.store.resetAll()
                }
            }
        }

        // ------------------------------------------------------- right side
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Tokens.spacing.medium

            // Placement
            StyledRect {
                Layout.fillWidth: true
                implicitHeight: placementCol.implicitHeight + Tokens.padding.medium * 2
                radius: Tokens.rounding.large
                color: Colours.palette.m3surfaceContainer

                ColumnLayout {
                    id: placementCol

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Tokens.padding.medium
                    anchors.leftMargin: Tokens.padding.large
                    spacing: Tokens.spacing.small

                    RowLayout {
                        spacing: Tokens.spacing.small

                        MaterialIcon {
                            text: "open_in_full"
                            color: Colours.palette.m3onSurfaceVariant
                            fontStyle: Tokens.font.icon.medium
                        }

                        StyledText {
                            text: qsTr("Launcher opens from")
                            font: Tokens.font.label.large
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Tokens.spacing.small

                        Repeater {
                            model: [
                                { key: "bottom", label: qsTr("Bottom") },
                                { key: "top", label: qsTr("Top") },
                                { key: "left", label: qsTr("Left") },
                                { key: "right", label: qsTr("Right") },
                                { key: "dock", label: qsTr("Follow dock") }
                            ]

                            delegate: TextButton {
                                required property var modelData

                                text: modelData.label
                                type: win.placement === modelData.key ? TextButton.Filled : TextButton.Tonal
                                onClicked: win.store.setPlacement(modelData.key)
                            }
                        }
                    }
                }
            }

            // Selected category details
            StyledRect {
                Layout.fillWidth: true
                visible: win.selected !== null && win.search.trim().length === 0
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

                        StyledRect {
                            implicitWidth: 48
                            implicitHeight: 48
                            radius: Tokens.rounding.full
                            color: Colours.palette.m3secondaryContainer

                            MaterialIcon {
                                anchors.centerIn: parent
                                text: win.selected?.icon || "label"
                                color: Colours.palette.m3onSecondaryContainer
                                fontStyle: Tokens.font.icon.medium
                            }
                        }

                        StyledTextField {
                            id: nameField

                            Layout.fillWidth: true
                            placeholderText: qsTr("Name")
                            text: win.selected?.name ?? ""
                            onEditingFinished: {
                                const id = win.selectedId;
                                const v = text.trim();
                                if (v && v !== win.selected?.name)
                                    win.edit(list => list.find(c => c.id === id).name = v);
                            }
                        }

                        StyledTextField {
                            Layout.preferredWidth: 190
                            placeholderText: qsTr("Icon")
                            supportingText: qsTr("Material Symbols name")
                            text: win.selected?.icon ?? ""
                            onEditingFinished: {
                                const id = win.selectedId;
                                const v = text.trim();
                                if (v && v !== win.selected?.icon)
                                    win.edit(list => list.find(c => c.id === id).icon = v);
                            }
                        }

                        IconButton {
                            icon: win.selected?.hidden ? "visibility_off" : "visibility"
                            type: IconButton.Tonal
                            onClicked: {
                                const id = win.selectedId;
                                win.edit(list => {
                                    const c = list.find(x => x.id === id);
                                    c.hidden = !c.hidden;
                                });
                            }
                        }

                        IconButton {
                            icon: "delete"
                            type: IconButton.Tonal
                            visible: win.selected?.custom ?? false
                            onClicked: win.removeCategory(win.selectedId)
                        }
                    }

                    StyledTextField {
                        Layout.fillWidth: true
                        visible: win.selectedId !== "other"
                        placeholderText: qsTr("Auto-include apps tagged")
                        supportingText: qsTr("Comma-separated XDG tags, e.g. Game, Emulator. Empty: only apps you move here.")
                        text: (win.selected?.xdg ?? []).join(", ")
                        onEditingFinished: {
                            const id = win.selectedId;
                            const tags = text.split(",").map(t => t.trim()).filter(t => t.length > 0);
                            if (tags.join(",") !== (win.selected?.xdg ?? []).join(","))
                                win.edit(list => list.find(c => c.id === id).xdg = tags);
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: win.selected?.hidden ?? false
                        text: qsTr("Hidden: this category is not shown, and its apps go to the next category that matches them, or Other.")
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                    }
                }
            }

            StyledTextField {
                id: searchField

                Layout.fillWidth: true
                leadingIcon: "search"
                placeholderText: qsTr("Search all apps")
                onTextChanged: win.search = text
            }

            StyledText {
                Layout.leftMargin: Tokens.padding.small
                text: win.search.trim().length > 0 ? qsTr("%n app(s) matching", "", win.shownApps.length) : qsTr("%n app(s) in %1", "", win.shownApps.length).arg(win.nameOf(win.selectedId))
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.medium
            }

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
                    readonly property bool pickerOpen: win.pickerFor === appId

                    width: appList.width
                    implicitHeight: appCol.implicitHeight + Tokens.padding.small * 2
                    radius: Tokens.rounding.medium
                    color: pickerOpen ? Colours.palette.m3surfaceContainerHigh : (appMouse.containsMouse ? Colours.palette.m3surfaceContainer : "transparent")

                    MouseArea {
                        id: appMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }

                    ColumnLayout {
                        id: appCol

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Tokens.padding.medium
                        anchors.rightMargin: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.medium

                            IconImage {
                                implicitSize: 32
                                asynchronous: true
                                source: Quickshell.iconPath(appRow.modelData.icon, "application-x-executable")
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    text: appRow.modelData.name
                                    elide: Text.ElideRight
                                    font: Tokens.font.label.large
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: win.nameOf(win.appCategory[appRow.appId]) + (win.isManual(appRow.appId) ? qsTr(" · moved by you") : "")
                                    elide: Text.ElideRight
                                    color: win.isManual(appRow.appId) ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                                    font: Tokens.font.body.small
                                }
                            }

                            IconButton {
                                icon: "undo"
                                type: IconButton.Text
                                visible: win.isManual(appRow.appId)
                                onClicked: win.store.unassign(appRow.appId)
                            }

                            TextButton {
                                text: appRow.pickerOpen ? qsTr("Cancel") : qsTr("Move to…")
                                type: TextButton.Tonal
                                onClicked: win.pickerFor = appRow.pickerOpen ? "" : appRow.appId
                            }
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.bottomMargin: Tokens.padding.small
                            visible: appRow.pickerOpen
                            spacing: Tokens.spacing.small

                            Repeater {
                                model: appRow.pickerOpen ? win.cats.filter(c => !c.hidden) : []

                                delegate: TextButton {
                                    required property var modelData

                                    text: modelData.name
                                    type: win.appCategory[appRow.appId] === modelData.id ? TextButton.Filled : TextButton.Tonal
                                    onClicked: {
                                        win.store.assign(appRow.appId, modelData.id);
                                        win.pickerFor = "";
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
