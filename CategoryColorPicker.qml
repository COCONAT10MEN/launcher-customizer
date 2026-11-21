pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// Full-window overlay: pick a colour by saturation/brightness square, hue and
// opacity bars, a hex code, or a swatch from the current theme.
// Emits picked("#rrggbb" or "#aarrggbb").
Item {
    id: picker

    property string title: qsTr("Background colour")
    property real hue: 0
    property real sat: 0.5
    property real val: 0.5
    property real alpha: 1
    property bool shown: false

    readonly property color value: Qt.hsva(picker.hue, picker.sat, picker.val, picker.alpha)
    readonly property string hex: picker.toHex(picker.value)

    signal picked(string hex)

    function toHex(c: color): string {
        const h = v => Math.round(v * 255).toString(16).padStart(2, "0");
        return "#" + (c.a < 0.999 ? h(c.a) : "") + h(c.r) + h(c.g) + h(c.b);
    }

    function setColor(text: string): bool {
        const t = text.trim();
        if (!/^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(t))
            return false;
        const c = Qt.color(t.startsWith("#") ? t : "#" + t);
        if (c.hsvHue >= 0)
            picker.hue = c.hsvHue;
        picker.sat = c.hsvSaturation;
        picker.val = c.hsvValue;
        picker.alpha = c.a;
        return true;
    }

    function open(title: string, current: string): void {
        picker.title = title;
        if (!picker.setColor(current || ""))
            picker.setColor(picker.toHex(Colours.palette.m3secondaryContainer));
        hexField.text = picker.hex;
        picker.shown = true;
    }

    function close(): void {
        picker.shown = false;
    }

    onHexChanged: {
        if (!hexField.activeFocus)
            hexField.text = picker.hex;
    }

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
        width: 380
        height: content.implicitHeight + Tokens.padding.large * 2
        radius: Tokens.rounding.extraLarge
        color: Colours.palette.m3surfaceContainerHigh
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

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: content

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            spacing: Tokens.spacing.medium

            StyledText {
                text: picker.title
                font: Tokens.font.title.medium
            }

            // Saturation (left to right) and brightness (bottom to top).
            Rectangle {
                id: square

                Layout.fillWidth: true
                Layout.preferredHeight: 190
                radius: Tokens.rounding.medium
                color: Qt.hsva(picker.hue, 1, 1, 1)

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        orientation: Gradient.Horizontal

                        GradientStop {
                            position: 0
                            color: "white"
                        }

                        GradientStop {
                            position: 1
                            color: "#00ffffff"
                        }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        GradientStop {
                            position: 0
                            color: "#00000000"
                        }

                        GradientStop {
                            position: 1
                            color: "black"
                        }
                    }
                }

                Rectangle {
                    x: picker.sat * square.width - width / 2
                    y: (1 - picker.val) * square.height - height / 2
                    width: 18
                    height: 18
                    radius: 9
                    color: Qt.hsva(picker.hue, picker.sat, picker.val, 1)
                    border.width: 3
                    border.color: "white"
                }

                MouseArea {
                    anchors.fill: parent
                    preventStealing: true
                    cursorShape: Qt.CrossCursor

                    function pick(mouse: var): void {
                        picker.sat = Math.max(0, Math.min(1, mouse.x / width));
                        picker.val = Math.max(0, Math.min(1, 1 - mouse.y / height));
                    }

                    onPressed: mouse => pick(mouse)
                    onPositionChanged: mouse => pick(mouse)
                }
            }

            Bar {
                id: hueBar

                value: picker.hue
                knob: Qt.hsva(picker.hue, 1, 1, 1)
                onMoved: v => picker.hue = Math.min(0.999, v)

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal

                        GradientStop { position: 0.0; color: "#ff0000" }
                        GradientStop { position: 0.167; color: "#ffff00" }
                        GradientStop { position: 0.333; color: "#00ff00" }
                        GradientStop { position: 0.5; color: "#00ffff" }
                        GradientStop { position: 0.667; color: "#0000ff" }
                        GradientStop { position: 0.833; color: "#ff00ff" }
                        GradientStop { position: 1.0; color: "#ff0000" }
                    }
                }
            }

            Bar {
                value: picker.alpha
                knob: Qt.hsva(picker.hue, picker.sat, picker.val, 1)
                onMoved: v => picker.alpha = v

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: Colours.palette.m3surfaceContainerHighest
                }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal

                        GradientStop {
                            position: 0
                            color: Qt.hsva(picker.hue, picker.sat, picker.val, 0)
                        }

                        GradientStop {
                            position: 1
                            color: Qt.hsva(picker.hue, picker.sat, picker.val, 1)
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.medium

                StyledRect {
                    implicitWidth: 44
                    implicitHeight: 44
                    radius: Tokens.rounding.medium
                    color: Colours.palette.m3surfaceContainerHighest

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: picker.value
                        border.width: 1
                        border.color: Colours.palette.m3outlineVariant
                    }
                }

                StyledTextField {
                    id: hexField

                    Layout.fillWidth: true
                    leadingIcon: "tag"
                    placeholderText: "#RRGGBB"
                    onTextEdited: picker.setColor(text)
                    onEditingFinished: text = picker.hex
                    Keys.onReturnPressed: picker.picked(picker.hex)
                    Keys.onEscapePressed: picker.close()
                }
            }

            // From the current theme, so a background can match it.
            Flow {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                Repeater {
                    model: [Colours.palette.m3primaryContainer, Colours.palette.m3secondaryContainer, Colours.palette.m3tertiaryContainer, Colours.palette.m3surfaceContainerHighest, Colours.palette.m3primary, Colours.palette.m3secondary, Colours.palette.m3tertiary, Colours.palette.m3errorContainer, Qt.alpha(Colours.palette.m3primary, 0.18), Qt.alpha(Colours.palette.m3tertiary, 0.18)]

                    delegate: Rectangle {
                        required property color modelData

                        width: 28
                        height: 28
                        radius: 14
                        color: modelData
                        border.width: picker.hex === picker.toHex(modelData) ? 3 : 1
                        border.color: picker.hex === picker.toHex(modelData) ? Colours.palette.m3onSurface : Colours.palette.m3outlineVariant

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                picker.setColor(picker.toHex(parent.modelData));
                                hexField.text = picker.hex;
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Tokens.spacing.small

                TextButton {
                    text: qsTr("Cancel")
                    type: TextButton.Text
                    onClicked: picker.close()
                }

                TextButton {
                    text: qsTr("Use colour")
                    onClicked: picker.picked(picker.hex)
                }
            }
        }
    }

    // A horizontal bar with a round knob; children draw the track.
    component Bar: Item {
        id: bar

        default property alias track: trackItem.data
        property real value
        property color knob

        signal moved(real v)

        Layout.fillWidth: true
        implicitHeight: 22

        Item {
            id: trackItem

            anchors.fill: parent
            anchors.topMargin: 3
            anchors.bottomMargin: 3
        }

        Rectangle {
            x: bar.value * (bar.width - width)
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: 22
            radius: 11
            color: bar.knob
            border.width: 3
            border.color: "white"
        }

        MouseArea {
            anchors.fill: parent
            preventStealing: true

            function pick(mouse: var): void {
                bar.moved(Math.max(0, Math.min(1, (mouse.x - 11) / (width - 22))));
            }

            onPressed: mouse => pick(mouse)
            onPositionChanged: mouse => pick(mouse)
        }
    }
}
