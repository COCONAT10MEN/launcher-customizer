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

// Full-window overlay listing every category (subcategories indented) with a
// search box. Emits picked(key).
Item {
    id: picker

    // [{ key, name, icon, iconSource, depth, hidden }]
    property var rows: []
    property string title: ""
    property string subtitle: ""
    property var exclude: []
    property string query: ""

    signal picked(string key)

    readonly property var matches: {
        const q = picker.query.trim().toLowerCase();
        return picker.rows.filter(r => !picker.exclude.includes(r.key) && (!q || r.name.toLowerCase().includes(q)));
    }

    function open(title: string, subtitle: string, exclude: var): void {
        picker.title = title;
        picker.subtitle = subtitle;
        picker.exclude = exclude ?? [];
        picker.query = "";
        search.text = "";
        picker.shown = true;
        search.forceActiveFocus();
    }

    function close(): void {
        picker.shown = false;
    }

    property bool shown: false

    visible: picker.shown || scrim.opacity > 0
    z: 100
    anchors.fill: parent

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
        width: Math.min(parent.width - 48, 460)
        height: Math.min(parent.height - 48, 560)
        radius: Tokens.rounding.extraLarge
        color: Colours.palette.m3surfaceContainerHigh

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.medium

            StyledText {
                Layout.fillWidth: true
                text: picker.title
                font: Tokens.font.title.medium
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                visible: picker.subtitle.length > 0
                text: picker.subtitle
                wrapMode: Text.WordWrap
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledTextField {
                id: search

                Layout.fillWidth: true
                leadingIcon: "search"
                placeholderText: qsTr("Find a category")
                onTextChanged: picker.query = text
                Keys.onEscapePressed: picker.close()
                Keys.onReturnPressed: {
                    if (picker.matches.length > 0)
                        picker.picked(picker.matches[0].key);
                }
            }

            ListView {
                id: list

                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                model: picker.matches
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar {
                    flickable: list
                }

                delegate: StyledRect {
                    id: row

                    required property var modelData

                    width: list.width
                    implicitHeight: 44
                    radius: Tokens.rounding.medium
                    color: rowMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : "transparent"

                    MouseArea {
                        id: rowMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: picker.picked(row.modelData.key)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Tokens.padding.medium + row.modelData.depth * 24
                        anchors.rightMargin: Tokens.padding.medium
                        spacing: Tokens.spacing.medium

                        CategoryIcon {
                            icon: row.modelData.icon
                            iconSource: row.modelData.iconSource
                            size: 22
                            color: Colours.palette.m3onSurfaceVariant
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: row.modelData.name
                            elide: Text.ElideRight
                            font: row.modelData.depth > 0 ? Tokens.font.body.medium : Tokens.font.label.large
                        }

                        StyledText {
                            visible: row.modelData.hidden
                            text: qsTr("hidden")
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.label.small
                        }
                    }
                }
            }
        }
    }
}
