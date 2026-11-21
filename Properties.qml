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

// Properties of the selected launcher, category or separator. Every field
// saves when you leave it; toggles save at once.
Item {
    id: props

    required property var editor
    required property var store

    readonly property string key: props.editor.focusKey
    readonly property var app: props.key.startsWith("app:") ? (props.editor.apps[props.key.slice(4)] ?? null) : null
    readonly property var menuNode: props.key.startsWith("menu:") ? (props.editor.nodes[props.key.slice(5)] ?? null) : null
    readonly property bool isSep: props.key.startsWith("sep:")

    // Nothing selected
    ColumnLayout {
        anchors.centerIn: parent
        visible: !props.app && !props.menuNode && !props.isSep
        spacing: Tokens.spacing.small

        MaterialIcon {
            Layout.alignment: Qt.AlignHCenter
            text: "info"
            color: Colours.palette.m3outline
            fontStyle: Tokens.font.icon.large
        }

        StyledText {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Nothing selected")
            color: Colours.palette.m3outline
        }
    }

    // One form per selected item; recreated when the selection changes.
    Repeater {
        model: props.app ? [props.key] : []

        delegate: Loader {
            required property var modelData

            anchors.fill: parent
            sourceComponent: appFormComp
        }
    }

    Repeater {
        model: props.menuNode ? [props.key] : []

        delegate: Loader {
            required property var modelData

            anchors.fill: parent
            sourceComponent: menuFormComp
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        visible: props.isSep
        spacing: Tokens.spacing.medium

        StyledText {
            text: qsTr("Separator")
            font: Tokens.font.title.medium
        }

        RowLayout {
            spacing: Tokens.spacing.small

            TextButton {
                text: qsTr("Move up")
                type: TextButton.Tonal
                onClicked: props.editor.moveRow(-1)
            }

            TextButton {
                text: qsTr("Move down")
                type: TextButton.Tonal
                onClicked: props.editor.moveRow(1)
            }

            TextButton {
                text: qsTr("Remove")
                type: TextButton.Tonal
                onClicked: props.editor.removeSelected()
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }

    // ================================================================ app
    Component {
        id: appFormComp

        Flickable {
        id: af

        readonly property var a: props.app
        readonly property string id_: props.key.slice(4)

        function save(field: string, value: var): void {
            const cur = af.a ? af.a[field] : undefined;
            if (value === cur || (value === "" && !cur))
                return;
            props.store.appSet(af.id_, { [field]: value });
        }

        contentHeight: form.implicitHeight + Tokens.padding.large * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: StyledScrollBar {
            flickable: af
        }

        Connections {
            function onFocusNameChanged(): void {
                if (props.editor.focusName) {
                    props.editor.focusName = false;
                    nameField.forceActiveFocus();
                    nameField.selectAll();
                }
            }

            target: props.editor
        }

        // Material 3 Expressive: the details rise in when the selection changes.
        opacity: 0

        ParallelAnimation {
            id: afAppear

            Anim {
                target: af
                property: "opacity"
                from: 0
                to: 1
                type: Anim.DefaultEffects
            }
            Anim {
                target: af
                property: "y"
                from: 16
                to: 0
                type: Anim.DefaultSpatial
            }
        }

        Component.onCompleted: {
            afAppear.start();
            if (props.editor.focusName) {
                props.editor.focusName = false;
                nameField.forceActiveFocus();
                nameField.selectAll();
            }
        }

        Process {
            id: browseProgram

            command: ["kdialog", "--getopenfilename", "/usr/bin"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const p = text.trim();
                    if (p) {
                        programField.text = p;
                        af.save("program", p);
                    }
                }
            }
        }

        Process {
            id: browseDir

            command: ["kdialog", "--getexistingdirectory", Quickshell.env("HOME")]
            stdout: StdioCollector {
                onStreamFinished: {
                    const p = text.trim();
                    if (p) {
                        pathField.text = p;
                        af.save("path", p);
                    }
                }
            }
        }

        ColumnLayout {
            id: form

            x: Tokens.padding.large
            y: Tokens.padding.large
            width: af.width - Tokens.padding.large * 2
            spacing: Tokens.spacing.medium

            // header: icon + name + description
            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                StyledRect {
                    implicitWidth: 72
                    implicitHeight: 72
                    radius: Tokens.rounding.large
                    color: iconMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainerHigh

                    IconImage {
                        anchors.centerIn: parent
                        implicitSize: 48
                        asynchronous: true
                        source: LauncherCustomizer.imageFor(af.a?.icon ?? "") || Quickshell.iconPath("application-x-executable")
                    }

                    MaterialIcon {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 4
                        text: "edit"
                        visible: iconMouse.containsMouse
                        color: Colours.palette.m3primary
                        fontStyle: Tokens.font.icon.small
                    }

                    MouseArea {
                        id: iconMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: props.editor.pickIcon(props.key, "theme")
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledTextField {
                        id: nameField

                        Layout.fillWidth: true
                        placeholderText: qsTr("Name")
                        text: af.a?.name ?? ""
                        onEditingFinished: af.save("name", text.trim())
                    }

                    StyledTextField {
                        Layout.fillWidth: true
                        placeholderText: qsTr("Description")
                        text: af.a?.genericName ?? ""
                        onEditingFinished: af.save("genericName", text.trim())
                    }
                }
            }

            StyledTextField {
                Layout.fillWidth: true
                placeholderText: qsTr("Comment")
                text: af.a?.comment ?? ""
                onEditingFinished: af.save("comment", text.trim())
            }

            Section {
                text: qsTr("Launch")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                StyledTextField {
                    id: programField

                    Layout.fillWidth: true
                    placeholderText: qsTr("Program")
                    text: af.a?.program ?? ""
                    onEditingFinished: af.save("program", text.trim())
                }

                IconButton {
                    icon: "folder_open"
                    type: IconButton.Tonal
                    onClicked: browseProgram.running = true
                }
            }

            StyledTextField {
                Layout.fillWidth: true
                placeholderText: qsTr("Arguments")
                text: af.a?.args ?? ""
                onEditingFinished: af.save("args", text.trim())
                ToolTip.visible: activeFocus
                ToolTip.text: "%f %F file(s) · %u %U URL(s) · %d %D folder(s) · %i icon · %c name"
            }

            StyledTextField {
                Layout.fillWidth: true
                placeholderText: qsTr("Environment variables")
                text: af.a?.env ?? ""
                onEditingFinished: af.save("env", text.trim())
                ToolTip.visible: activeFocus && text.length === 0
                ToolTip.text: "NAME=value NAME2=value"
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                StyledTextField {
                    id: pathField

                    Layout.fillWidth: true
                    placeholderText: qsTr("Work folder")
                    text: af.a?.path ?? ""
                    onEditingFinished: af.save("path", text.trim())
                }

                IconButton {
                    icon: "folder_open"
                    type: IconButton.Tonal
                    onClicked: browseDir.running = true
                }
            }

            SwitchRow {
                text: qsTr("Run in terminal")
                on: af.a?.terminal ?? false
                onToggledTo: v => af.save("terminal", v)
            }

            StyledTextField {
                Layout.fillWidth: true
                visible: af.a?.terminal ?? false
                placeholderText: qsTr("Terminal options")
                text: af.a?.terminalOptions ?? ""
                onEditingFinished: af.save("terminalOptions", text.trim())
            }

            SwitchRow {
                text: qsTr("Run as a different user")
                on: af.a?.otherUser ?? false
                onToggledTo: v => af.save("otherUser", v)
            }

            StyledTextField {
                Layout.fillWidth: true
                visible: af.a?.otherUser ?? false
                placeholderText: qsTr("Username")
                text: af.a?.username ?? ""
                onEditingFinished: af.save("username", text.trim())
            }

            SwitchRow {
                text: qsTr("Use dedicated graphics card")
                on: af.a?.gpu ?? false
                onToggledTo: v => af.save("gpu", v)
            }

            SwitchRow {
                text: qsTr("Launch feedback")
                on: af.a?.startupNotify ?? true
                onToggledTo: v => af.save("startupNotify", v)
            }

            Section {
                text: qsTr("Menu")
            }

            StyledText {
                text: qsTr("Shortcut")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.medium
            }

            ShortcutField {
                Layout.fillWidth: true
                current: af.a?.shortcut ?? ""
                onCaptured: (key, label) => props.store.setShortcut(af.id_, key, af.a?.name ?? af.id_)
                onCleared: props.store.setShortcut(af.id_, 0, af.a?.name ?? af.id_)
            }

            StyledTextField {
                Layout.fillWidth: true
                placeholderText: qsTr("Keywords")
                text: af.a?.keywords ?? ""
                onEditingFinished: af.save("keywords", text.trim())
            }

            SwitchRow {
                text: qsTr("Hidden")
                on: props.store.appHidden(af.a)
                onToggledTo: v => props.store.setAppHidden(af.a, v)
            }

            SwitchRow {
                visible: !!props.editor.cat
                text: qsTr("Pin to top of %1").arg(props.editor.nodeName(props.editor.cat))
                on: LauncherCustomizer.pinnedIn("kde:" + props.editor.cat, af.id_)
                onToggledTo: v => props.store.pin("kde:" + props.editor.cat, af.id_, v)
            }

            SwitchRow {
                text: qsTr("Only show in Plasma")
                on: af.a?.onlyPlasma ?? false
                onToggledTo: v => af.save("onlyPlasma", v)
            }

            // actions
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.spacing.medium
                spacing: Tokens.spacing.small

                TextButton {
                    text: qsTr("Launch")
                    onClicked: props.store.launch(af.a)
                }

                TextButton {
                    text: qsTr("Open folder")
                    type: TextButton.Tonal
                    onClicked: props.store.openFolder(af.a)
                }

                TextButton {
                    text: qsTr("Copy location")
                    type: TextButton.Tonal
                    onClicked: props.store.copyLocation(af.a)
                }

                TextButton {
                    visible: (af.a?.local ?? false) && (af.a?.hasSystem ?? false)
                    text: qsTr("Restore default")
                    type: TextButton.Tonal
                    onClicked: props.store.appReset(af.id_)
                }

                TextButton {
                    visible: af.a?.created ?? false
                    text: qsTr("Delete")
                    type: TextButton.Tonal
                    label.color: Colours.palette.m3error
                    onClicked: {
                        props.store.appDelete(af.id_);
                        props.editor.focusKey = "";
                        props.editor.toast(qsTr("Deleted %1").arg(af.a?.name ?? ""), true);
                    }
                }
            }
        }
    }
    }

    // ============================================================ category
    Component {
        id: menuFormComp

        Flickable {
        id: mf

        readonly property var n: props.menuNode
        readonly property string path: props.key.slice(5)
        readonly property var ic: mf.n ? LauncherCustomizer.kdeIcon(mf.n) : ({ icon: "folder", iconSource: "" })

        contentHeight: mform.implicitHeight + Tokens.padding.large * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Connections {
            function onFocusNameChanged(): void {
                if (props.editor.focusName) {
                    props.editor.focusName = false;
                    mName.forceActiveFocus();
                    mName.selectAll();
                }
            }

            target: props.editor
        }

        // Material 3 Expressive: the details rise in when the selection changes.
        opacity: 0

        ParallelAnimation {
            id: mfAppear

            Anim {
                target: mf
                property: "opacity"
                from: 0
                to: 1
                type: Anim.DefaultEffects
            }
            Anim {
                target: mf
                property: "y"
                from: 16
                to: 0
                type: Anim.DefaultSpatial
            }
        }

        Component.onCompleted: {
            mfAppear.start();
            if (props.editor.focusName) {
                props.editor.focusName = false;
                mName.forceActiveFocus();
                mName.selectAll();
            }
        }

        ColumnLayout {
            id: mform

            x: Tokens.padding.large
            y: Tokens.padding.large
            width: mf.width - Tokens.padding.large * 2
            spacing: Tokens.spacing.medium

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                StyledRect {
                    implicitWidth: 72
                    implicitHeight: 72
                    radius: Tokens.rounding.full
                    color: mIconMouse.containsMouse ? Colours.palette.m3primaryContainer : Colours.palette.m3secondaryContainer

                    CategoryIcon {
                        anchors.centerIn: parent
                        icon: mf.ic.icon
                        iconSource: mf.ic.iconSource
                        size: 34
                        color: Colours.palette.m3onSecondaryContainer
                    }

                    MaterialIcon {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 4
                        text: "edit"
                        visible: mIconMouse.containsMouse
                        color: Colours.palette.m3primary
                        fontStyle: Tokens.font.icon.small
                    }

                    MouseArea {
                        id: mIconMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: props.editor.pickIcon(props.key, mf.ic.icon ? "material" : "theme")
                    }
                }

                StyledTextField {
                    id: mName

                    Layout.fillWidth: true
                    placeholderText: qsTr("Name")
                    text: mf.n?.name ?? ""
                    onEditingFinished: {
                        const v = text.trim();
                        if (v && v !== mf.n?.name)
                            props.store.kdeSet(mf.path, { name: v });
                    }
                }
            }

            StyledTextField {
                Layout.fillWidth: true
                placeholderText: qsTr("Comment")
                text: mf.n?.comment ?? ""
                onEditingFinished: {
                    if (text.trim() !== (mf.n?.comment ?? ""))
                        props.store.kdeSet(mf.path, { comment: text.trim() });
                }
            }

            SwitchRow {
                text: qsTr("Hidden")
                on: mf.n?.hidden ?? false
                onToggledTo: v => props.store.kdeSet(mf.path, { hidden: v ? "1" : "0" })
            }

            // Launcher look: an optional background behind this category's apps.
            RowLayout {
                id: lookRow

                readonly property var look: LauncherCustomizer.data?.looks?.["kde:" + mf.path] ?? ({})

                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("Background in the launcher")
                    font: Tokens.font.body.medium
                }

                StyledRect {
                    visible: !!lookRow.look.enabled
                    implicitWidth: 52
                    implicitHeight: 30
                    radius: Tokens.rounding.full
                    color: Colours.palette.m3surfaceContainerHighest

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: lookRow.look.color || "transparent"
                        border.width: 1
                        border.color: Colours.palette.m3outlineVariant
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: props.editor.pickColor("kde:" + mf.path, mf.n?.name ?? "")
                    }
                }

                StyledSwitch {
                    checked: !!lookRow.look.enabled
                    onToggled: {
                        if (checked && !lookRow.look.color)
                            props.editor.pickColor("kde:" + mf.path, mf.n?.name ?? "");
                        else
                            props.store.setLook("kde:" + mf.path, { enabled: checked });
                        // The saved setting decides (picking a colour can be cancelled).
                        checked = Qt.binding(() => !!lookRow.look.enabled);
                    }
                }
            }

            Flow {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.spacing.medium
                spacing: Tokens.spacing.small

                TextButton {
                    text: qsTr("New launcher here")
                    onClicked: {
                        props.editor.cat = mf.path;
                        props.editor.newLauncher();
                    }
                }

                TextButton {
                    text: qsTr("New subcategory")
                    type: TextButton.Tonal
                    onClicked: {
                        props.editor.cat = mf.path;
                        props.editor.newCategory(true);
                    }
                }

                TextButton {
                    visible: mf.n?.hasOverride ?? false
                    text: qsTr("Restore default")
                    type: TextButton.Tonal
                    onClicked: props.store.kdeResetDir(mf.path)
                }

                TextButton {
                    text: qsTr("Delete")
                    type: TextButton.Tonal
                    label.color: Colours.palette.m3error
                    onClicked: {
                        props.store.kdeDelete(mf.path);
                        props.editor.focusKey = "";
                        props.editor.toast(qsTr("Deleted %1").arg(mf.n?.name ?? ""), true);
                    }
                }
            }
        }
    }
    }

    // ============================================================= pieces
    component Section: StyledText {
        Layout.topMargin: Tokens.spacing.medium
        color: Colours.palette.m3primary
        font: Tokens.font.label.large
    }

    component SwitchRow: RowLayout {
        id: sr

        property string text
        property bool on

        signal toggledTo(bool value)

        Layout.fillWidth: true
        spacing: Tokens.spacing.medium

        StyledText {
            Layout.fillWidth: true
            text: sr.text
            font: Tokens.font.body.medium
        }

        StyledSwitch {
            checked: sr.on
            onToggled: sr.toggledTo(checked)
        }
    }
}
