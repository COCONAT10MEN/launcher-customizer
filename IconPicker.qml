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

// Full-window overlay: pick a Material Symbol, an icon-theme icon, an image
// file, or go back to the default. Emits picked({ kind, value }).
Item {
    id: picker

    required property var store
    property bool allowDefault: true
    property string tab: "material"
    property string query: ""
    property var choice: null
    property string filePath: ""

    signal picked(var choice)

    function open(currentKind: string): void {
        picker.tab = currentKind === "theme" ? "theme" : (currentKind === "file" ? "file" : "material");
        picker.query = "";
        searchField.text = "";
        picker.choice = null;
        picker.shown = true;
        if (picker.tab === "theme")
            picker.store.loadThemeIcons();
        searchField.forceActiveFocus();
    }

    function close(): void {
        picker.shown = false;
    }

    readonly property var materialNames: materialFile.loaded ? materialFile.text().split("\n").filter(n => n.length > 0) : []
    readonly property var shownMaterial: {
        const q = picker.query.trim().toLowerCase().replace(/[\s-]+/g, "_");
        if (!q)
            return picker.materialNames;
        const starts = [], has = [];
        for (const n of picker.materialNames) {
            if (n.startsWith(q))
                starts.push(n);
            else if (n.includes(q))
                has.push(n);
        }
        return starts.concat(has);
    }
    readonly property var shownTheme: {
        const q = picker.query.trim().toLowerCase();
        const all = picker.store.themeIcons;
        if (!q)
            return all;
        return all.filter(n => n.includes(q));
    }

    property bool shown: false

    visible: picker.shown || scrim.opacity > 0
    z: 100
    anchors.fill: parent

    FileView {
        id: materialFile

        path: picker.store.pluginDir + "/material-symbols.txt"
        blockLoading: true
        printErrors: false
    }

    Process {
        id: browse

        command: ["kdialog", "--title", qsTr("Choose an icon image"), "--getopenfilename", Quickshell.env("HOME"), "Images (*.svg *.svgz *.png *.jpg *.jpeg *.webp)"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim();
                if (p) {
                    picker.filePath = p;
                    fileField.text = p;
                    picker.choice = { kind: "file", value: p };
                }
            }
        }
    }

    // Dim the editor behind; a click outside the card cancels.
    Rectangle {
        id: scrim

        anchors.fill: parent
        color: Qt.alpha(Colours.palette.m3scrim, 0.45)
        opacity: picker.shown ? 1 : 0

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: picker.shown
            onClicked: picker.close()
        }
    }

    StyledRect {
        id: card

        anchors.centerIn: parent
        opacity: picker.shown ? 1 : 0
        scale: picker.shown ? 1 : 0.92

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
        width: Math.min(parent.width - 48, 760)
        height: Math.min(parent.height - 48, 600)
        radius: Tokens.rounding.extraLarge
        color: Colours.palette.m3surfaceContainerHigh

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.medium

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("Choose an icon")
                    font: Tokens.font.title.medium
                }

                Repeater {
                    model: [
                        { key: "material", label: qsTr("Material"), hint: qsTr("Caelestia's icon style") },
                        { key: "theme", label: qsTr("Icon theme"), hint: qsTr("Icons from your KDE icon theme") },
                        { key: "file", label: qsTr("Image file"), hint: qsTr("Any SVG or PNG") }
                    ]

                    delegate: TextButton {
                        required property var modelData

                        text: modelData.label
                        type: picker.tab === modelData.key ? TextButton.Filled : TextButton.Tonal
                        onClicked: {
                            picker.tab = modelData.key;
                            picker.choice = null;
                            if (modelData.key === "theme")
                                picker.store.loadThemeIcons();
                        }
                    }
                }
            }

            StyledTextField {
                id: searchField

                Layout.fillWidth: true
                visible: picker.tab !== "file"
                leadingIcon: "search"
                placeholderText: picker.tab === "material" ? qsTr("Search %1 Material Symbols").arg(picker.materialNames.length) : qsTr("Search %1 theme icons").arg(picker.store.themeIcons.length)
                onTextChanged: picker.query = text
                Keys.onEscapePressed: picker.close()
            }

            // ------------------------------------------------- Material grid
            GridView {
                id: materialGrid

                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: picker.tab === "material"
                clip: true
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 92)))
                cellHeight: 84
                model: picker.tab === "material" ? picker.shownMaterial : []
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar {
                    flickable: materialGrid
                }

                delegate: Item {
                    id: mCell

                    required property string modelData
                    readonly property bool chosen: picker.choice?.kind === "material" && picker.choice?.value === modelData

                    width: materialGrid.cellWidth
                    height: materialGrid.cellHeight

                    StyledRect {
                        anchors.fill: parent
                        anchors.margins: 3
                        radius: Tokens.rounding.medium
                        color: mCell.chosen ? Colours.palette.m3secondaryContainer : (mMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : "transparent")

                        MouseArea {
                            id: mMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: picker.choice = { kind: "material", value: mCell.modelData }
                            onDoubleClicked: picker.picked({ kind: "material", value: mCell.modelData })
                        }

                        ColumnLayout {
                            anchors.centerIn: parent
                            width: parent.width - 8
                            spacing: 2

                            MaterialIcon {
                                Layout.alignment: Qt.AlignHCenter
                                text: mCell.modelData
                                color: mCell.chosen ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                                fontStyle: Tokens.font.icon.large
                            }

                            StyledText {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: mCell.modelData
                                elide: Text.ElideRight
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }
                    }
                }
            }

            // --------------------------------------------- icon-theme grid
            StyledText {
                Layout.fillWidth: true
                visible: picker.tab === "theme" && picker.store.themeIconsLoading
                text: qsTr("Loading your icon theme…")
                color: Colours.palette.m3onSurfaceVariant
            }

            GridView {
                id: themeGrid

                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: picker.tab === "theme"
                clip: true
                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 92)))
                cellHeight: 96
                model: picker.tab === "theme" ? picker.shownTheme : []
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar {
                    flickable: themeGrid
                }

                delegate: Item {
                    id: tCell

                    required property string modelData
                    readonly property bool chosen: picker.choice?.kind === "theme" && picker.choice?.value === modelData

                    width: themeGrid.cellWidth
                    height: themeGrid.cellHeight

                    StyledRect {
                        anchors.fill: parent
                        anchors.margins: 3
                        radius: Tokens.rounding.medium
                        color: tCell.chosen ? Colours.palette.m3secondaryContainer : (tMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : "transparent")

                        MouseArea {
                            id: tMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: picker.choice = { kind: "theme", value: tCell.modelData }
                            onDoubleClicked: picker.picked({ kind: "theme", value: tCell.modelData })
                        }

                        ColumnLayout {
                            anchors.centerIn: parent
                            width: parent.width - 8
                            spacing: 2

                            IconImage {
                                Layout.alignment: Qt.AlignHCenter
                                implicitSize: 32
                                asynchronous: true
                                source: Quickshell.iconPath(tCell.modelData, true)
                            }

                            StyledText {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: tCell.modelData.replace(/-/g, "-\u200b")
                                wrapMode: Text.WrapAnywhere
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }
                    }
                }
            }

            // ------------------------------------------------- image file
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: picker.tab === "file"
                spacing: Tokens.spacing.medium

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledTextField {
                        id: fileField

                        Layout.fillWidth: true
                        placeholderText: qsTr("Path to an SVG or PNG")
                        text: picker.filePath
                        onTextChanged: {
                            picker.filePath = text;
                            picker.choice = text.trim().startsWith("/") ? { kind: "file", value: text.trim() } : null;
                        }
                    }

                    TextButton {
                        text: qsTr("Browse…")
                        type: TextButton.Tonal
                        onClicked: browse.running = true
                    }
                }

                StyledRect {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: 128
                    implicitHeight: 128
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainerHighest

                    Image {
                        anchors.centerIn: parent
                        width: 72
                        height: 72
                        fillMode: Image.PreserveAspectFit
                        sourceSize: Qt.size(144, 144)
                        source: picker.filePath.trim().startsWith("/") ? "file://" + picker.filePath.trim() : ""
                        visible: status === Image.Ready
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("The image is used as-is by both KDE and the launcher. Keep it somewhere it will not be deleted.")
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                }

                Item {
                    Layout.fillHeight: true
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                TextButton {
                    visible: picker.allowDefault
                    text: qsTr("Use default icon")
                    type: TextButton.Text
                    onClicked: picker.picked({ kind: "default", value: "" })
                }

                StyledText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    text: picker.choice ? picker.choice.value : ""
                    elide: Text.ElideMiddle
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.medium
                }

                TextButton {
                    text: qsTr("Cancel")
                    type: TextButton.Text
                    onClicked: picker.close()
                }

                TextButton {
                    text: qsTr("Use icon")
                    type: TextButton.Filled
                    disabled: !picker.choice
                    onClicked: picker.picked(picker.choice)
                }
            }
        }
    }
}
