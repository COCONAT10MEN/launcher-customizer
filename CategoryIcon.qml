import QtQuick
import Quickshell.Widgets
import Caelestia.Config
import qs.components

// A category icon: a Material Symbol, or an image (icon theme / file).
Item {
    id: ci

    property string icon: ""
    property string iconSource: ""
    property real size: 24
    property color color: "white"

    implicitWidth: size
    implicitHeight: size

    MaterialIcon {
        anchors.centerIn: parent
        visible: !!ci.icon || !ci.iconSource
        text: ci.icon || "label"
        color: ci.color
        fontStyle: ci.size >= 30 ? Tokens.font.icon.large : Tokens.font.icon.medium
    }

    IconImage {
        anchors.centerIn: parent
        visible: !ci.icon && !!ci.iconSource
        implicitSize: ci.size
        asynchronous: true
        source: ci.iconSource
    }
}
