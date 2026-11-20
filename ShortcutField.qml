import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// Shows an app's global shortcut; click it and press keys to record a new one.
RowLayout {
    id: field

    property string current: ""
    property bool recording: false

    signal captured(int key, string label)
    signal cleared

    function label(key: int, mods: int, text: string): string {
        const names = {
            [Qt.Key_Space]: "Space", [Qt.Key_Return]: "Return", [Qt.Key_Enter]: "Enter", [Qt.Key_Tab]: "Tab",
            [Qt.Key_Backspace]: "Backspace", [Qt.Key_Delete]: "Del", [Qt.Key_Insert]: "Ins", [Qt.Key_Home]: "Home",
            [Qt.Key_End]: "End", [Qt.Key_PageUp]: "PgUp", [Qt.Key_PageDown]: "PgDown", [Qt.Key_Left]: "Left",
            [Qt.Key_Right]: "Right", [Qt.Key_Up]: "Up", [Qt.Key_Down]: "Down", [Qt.Key_Print]: "Print"
        };
        let k = names[key];
        if (!k && key >= Qt.Key_F1 && key <= Qt.Key_F35)
            k = "F" + (key - Qt.Key_F1 + 1);
        if (!k && key >= 0x20 && key <= 0x7e)
            k = String.fromCharCode(key).toUpperCase();
        if (!k)
            k = text ? text.toUpperCase() : "?";
        let s = "";
        if (mods & Qt.MetaModifier)
            s += "Meta+";
        if (mods & Qt.ControlModifier)
            s += "Ctrl+";
        if (mods & Qt.AltModifier)
            s += "Alt+";
        if (mods & Qt.ShiftModifier)
            s += "Shift+";
        return s + k;
    }

    spacing: Tokens.spacing.small

    StyledRect {
        id: box

        Layout.fillWidth: true
        implicitHeight: 44
        radius: Tokens.rounding.small
        color: "transparent"
        border.width: field.recording ? 2 : 1
        border.color: field.recording ? Colours.palette.m3primary : Colours.palette.m3outline

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Tokens.padding.large
            text: field.recording ? qsTr("Press keys…") : (field.current || qsTr("None"))
            color: field.recording || !field.current ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3onSurface
            font: Tokens.font.body.medium
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                field.recording = true;
                catcher.forceActiveFocus();
            }
        }

        Item {
            id: catcher

            focus: field.recording
            onActiveFocusChanged: if (!activeFocus) field.recording = false

            Keys.onPressed: event => {
                event.accepted = true;
                const k = event.key;
                if (k === Qt.Key_Escape) {
                    field.recording = false;
                    return;
                }
                if ([Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_AltGr].includes(k))
                    return;
                const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
                field.recording = false;
                field.captured(k | mods, field.label(k, mods, event.text));
            }
        }
    }

    IconButton {
        icon: "backspace"
        type: IconButton.Text
        visible: !!field.current && !field.recording
        onClicked: field.cleared()
    }
}
