pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

// A small in-window menu. open(x, y, actions) with actions like
// { text, icon, shortcut, enabled, danger, action } or { separator: true }.
Item {
    id: menu

    property var actions: []
    property real menuX: 0
    property real menuY: 0
    property bool shown: false

    function open(x: real, y: real, actions: var): void {
        menu.actions = actions;
        menu.menuX = x;
        menu.menuY = y;
        menu.shown = true;
        list.forceActiveFocus();
    }

    function close(): void {
        menu.shown = false;
    }

    visible: menu.shown || card.opacity > 0
    z: 200
    anchors.fill: parent

    MouseArea {
        anchors.fill: parent
        enabled: menu.shown
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
    }

    StyledRect {
        id: card

        x: Math.max(8, Math.min(menu.menuX, menu.width - width - 8))
        y: Math.max(8, Math.min(menu.menuY, menu.height - height - 8))
        width: Math.max(220, list.implicitWidth + Tokens.padding.small * 2)
        height: list.implicitHeight + Tokens.padding.small * 2
        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceContainerHighest
        // Material 3 Expressive: grows out of where it was opened.
        transformOrigin: Item.TopLeft
        opacity: menu.shown ? 1 : 0
        scale: menu.shown ? 1 : 0.9

        Behavior on opacity {
            Anim {
                type: Anim.FastEffects
            }
        }

        Behavior on scale {
            Anim {
                type: Anim.FastSpatial
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: list

            anchors.fill: parent
            anchors.margins: Tokens.padding.small
            spacing: 0
            focus: true

            Keys.onEscapePressed: menu.close()

            Repeater {
                model: menu.actions

                delegate: Item {
                    id: row

                    required property var modelData
                    readonly property bool sep: !!modelData.separator
                    readonly property bool on: modelData.enabled !== false

                    Layout.fillWidth: true
                    implicitWidth: rowLine.implicitWidth + Tokens.padding.medium * 2
                    implicitHeight: sep ? 9 : 36
                    visible: modelData.visible !== false

                    Rectangle {
                        visible: row.sep
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 1
                        color: Colours.palette.m3outlineVariant
                    }

                    StyledRect {
                        visible: !row.sep
                        anchors.fill: parent
                        radius: Tokens.rounding.small
                        color: rowMouse.containsMouse && row.on ? Colours.palette.m3surfaceContainerHigh : Qt.alpha(Colours.palette.m3surfaceContainerHigh, 0)

                        Behavior on color {
                            CAnim {}
                        }

                        MouseArea {
                            id: rowMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: row.on
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                menu.close();
                                if (row.modelData.action)
                                    row.modelData.action();
                            }
                        }

                        RowLayout {
                            id: rowLine

                            anchors.fill: parent
                            anchors.leftMargin: Tokens.padding.medium
                            anchors.rightMargin: Tokens.padding.medium
                            spacing: Tokens.spacing.medium
                            opacity: row.on ? 1 : 0.4

                            MaterialIcon {
                                text: row.modelData.icon ?? ""
                                visible: !!row.modelData.icon
                                color: row.modelData.danger ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                                fontStyle: Tokens.font.icon.small
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: row.modelData.text ?? ""
                                color: row.modelData.danger ? Colours.palette.m3error : Colours.palette.m3onSurface
                                font: Tokens.font.body.medium
                            }

                            StyledText {
                                visible: !!row.modelData.shortcut
                                text: row.modelData.shortcut ?? ""
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }
                    }
                }
            }
        }
    }
}
