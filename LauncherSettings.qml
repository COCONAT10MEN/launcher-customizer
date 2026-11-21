pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.launcher.services

// Full-window overlay with how the launcher looks and behaves, plus backup.
Item {
    id: dlg

    required property var store
    property bool shown: false

    function open(): void {
        dlg.shown = true;
        card.forceActiveFocus();
    }

    function close(): void {
        dlg.shown = false;
    }

    visible: dlg.shown || scrim.opacity > 0
    z: 100
    anchors.fill: parent

    Rectangle {
        id: scrim

        anchors.fill: parent
        color: Qt.alpha(Colours.palette.m3scrim, 0.45)
        opacity: dlg.shown ? 1 : 0

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: dlg.shown
            onClicked: dlg.close()
        }
    }

    StyledRect {
        id: card

        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 560)
        height: Math.min(parent.height - 48, content.implicitHeight + Tokens.padding.large * 2)
        radius: Tokens.rounding.extraLarge
        color: Colours.palette.m3surfaceContainerHigh
        opacity: dlg.shown ? 1 : 0
        scale: dlg.shown ? 1 : 0.92
        Keys.onEscapePressed: dlg.close()

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

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: content

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.medium

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("Launcher settings")
                    font: Tokens.font.title.medium
                }

                IconButton {
                    icon: "close"
                    type: IconButton.Text
                    onClicked: dlg.close()
                }
            }

            // ------------------------------------------------ subcategories
            Heading {
                text: qsTr("Subcategories")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                Choice {
                    icon: "view_agenda"
                    title: qsTr("Stacked")
                    hint: qsTr("One under another")
                    chosen: LauncherCustomizer.sectionLayout === "stack"
                    onPicked: dlg.store.setSetting("sectionLayout", "stack")
                }

                Choice {
                    icon: "view_quilt"
                    title: qsTr("Flowing")
                    hint: qsTr("Side by side when they fit")
                    chosen: LauncherCustomizer.sectionLayout === "flow"
                    onPicked: dlg.store.setSetting("sectionLayout", "flow")
                }
            }

            // ------------------------------------------------ category icons
            Heading {
                text: qsTr("Category icons")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                Choice {
                    icon: "interests"
                    title: qsTr("Material")
                    hint: qsTr("Caelestia's icon style")
                    chosen: LauncherCustomizer.iconStyle === "material"
                    onPicked: dlg.store.setIconStyle("material")
                }

                Choice {
                    icon: "image"
                    title: qsTr("Icon theme")
                    hint: qsTr("Your KDE icon theme")
                    chosen: LauncherCustomizer.iconStyle === "theme"
                    onPicked: dlg.store.setIconStyle("theme")
                }
            }

            // ------------------------------------------------ new apps
            Heading {
                text: qsTr("New apps")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                Rectangle {
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 4
                    color: Colours.palette.m3primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("Mark apps installed or updated in the last %n day(s)", "", LauncherCustomizer.newDays)
                    wrapMode: Text.WordWrap
                    font: Tokens.font.body.medium
                }

                IconButton {
                    icon: "remove"
                    type: IconButton.Text
                    disabled: LauncherCustomizer.newDays <= 1
                    onClicked: dlg.store.setSetting("newDays", LauncherCustomizer.newDays - 1)
                }

                IconButton {
                    icon: "add"
                    type: IconButton.Text
                    disabled: LauncherCustomizer.newDays >= 60
                    onClicked: dlg.store.setSetting("newDays", LauncherCustomizer.newDays + 1)
                }

                StyledSwitch {
                    checked: LauncherCustomizer.newDot
                    onToggled: dlg.store.setSetting("newDot", checked)
                }
            }

            // ------------------------------------------------ backup
            Heading {
                text: qsTr("Backup and share")
            }

            StyledText {
                Layout.fillWidth: true
                text: qsTr("Categories, order, icons, pins, backgrounds, hidden apps and app shortcuts, in one file.")
                wrapMode: Text.WordWrap
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                TextButton {
                    text: qsTr("Export…")
                    onClicked: {
                        dlg.close();
                        dlg.store.exportLayout();
                    }
                }

                TextButton {
                    text: qsTr("Import…")
                    type: TextButton.Tonal
                    onClicked: {
                        dlg.close();
                        dlg.store.importLayout();
                    }
                }
            }
        }
    }

    component Heading: StyledText {
        Layout.topMargin: Tokens.spacing.small
        color: Colours.palette.m3primary
        font: Tokens.font.label.large
    }

    // A selectable card: icon, title and a one-line hint.
    component Choice: StyledRect {
        id: choice

        property string icon
        property string title
        property string hint
        property bool chosen

        signal picked

        Layout.fillWidth: true
        implicitHeight: 64
        radius: Tokens.rounding.large
        color: choice.chosen ? Colours.palette.m3secondaryContainer : (choiceMouse.containsMouse ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainer)

        Behavior on color {
            CAnim {}
        }

        MouseArea {
            id: choiceMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: choice.picked()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Tokens.padding.medium
            anchors.rightMargin: Tokens.padding.medium
            spacing: Tokens.spacing.medium

            MaterialIcon {
                text: choice.icon
                fill: choice.chosen ? 1 : 0
                color: choice.chosen ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: choice.title
                    elide: Text.ElideRight
                    color: choice.chosen ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                    font: Tokens.font.label.large
                }

                StyledText {
                    Layout.fillWidth: true
                    text: choice.hint
                    elide: Text.ElideRight
                    color: choice.chosen ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                }
            }
        }
    }
}
