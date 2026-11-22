pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.modules.launcher.services

// "Uninstall…" from the launcher: shows what will be removed and how, asks,
// runs it (packages through KDE's own password prompt) and shows the result.
Scope {
    id: dlg

    required property string pluginDir

    // loading | confirm | unknown | working | done | failed
    property string state: ""
    property bool shown: false
    property string appId: ""
    property string file: ""
    property string name: ""
    property string icon: ""
    property var info: ({})
    property string error: ""

    signal finished(bool removed)

    function open(app: var, id: string): void {
        dlg.appId = id;
        dlg.file = app.file;
        dlg.name = app.name || id;
        dlg.icon = app.icon || "";
        dlg.info = ({});
        dlg.error = "";
        dlg.state = "loading";
        dlg.shown = true;
        planProc.command = ["python3", "-I", dlg.pluginDir + "/uninstall.py", "plan", dlg.file, dlg.appId, dlg.name];
        planProc.running = true;
    }

    function close(): void {
        if (dlg.state !== "working")
            dlg.shown = false;
    }

    function confirm(): void {
        dlg.state = "working";
        runProc.command = ["python3", "-I", dlg.pluginDir + "/uninstall.py", "run", dlg.file, dlg.appId];
        runProc.running = true;
    }

    Process {
        id: planProc

        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try {
                    r = JSON.parse(text);
                } catch (e) {}
                if (r?.ok) {
                    dlg.info = r;
                    dlg.state = "confirm";
                } else {
                    dlg.error = r?.error ?? qsTr("Couldn't work out how this app was installed.");
                    dlg.state = "unknown";
                }
            }
        }
    }

    Process {
        id: runProc

        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try {
                    r = JSON.parse(text);
                } catch (e) {}
                if (r?.ok) {
                    dlg.state = "done";
                    dlg.finished(true);
                } else {
                    dlg.error = r?.error || qsTr("It did not finish.");
                    dlg.state = "failed";
                }
            }
        }
    }

    StyledWindow {
        id: win

        screen: Screens.activeScreen ?? Quickshell.screens[0]
        name: "launcher-customizer-uninstall"
        WlrLayershell.namespace: "caelestia-dialog"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: dlg.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        visible: dlg.shown || scrim.opacity > 0.01

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        Item {
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: dlg.close()
            Keys.onReturnPressed: {
                if (dlg.state === "confirm")
                    dlg.confirm();
                else if (dlg.state !== "working" && dlg.state !== "loading")
                    dlg.close();
            }

            Rectangle {
                id: scrim

                anchors.fill: parent
                color: Qt.alpha(Colours.palette.m3scrim, 0.5)
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
                width: 480
                height: body.implicitHeight + Tokens.padding.large * 2
                radius: Tokens.rounding.extraLarge
                color: Colours.palette.m3surfaceContainerHigh
                opacity: dlg.shown ? 1 : 0
                scale: dlg.shown ? 1 : 0.92

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

                Behavior on height {
                    Anim {
                        type: Anim.DefaultSpatial
                    }
                }

                MouseArea {
                    anchors.fill: parent
                }

                ColumnLayout {
                    id: body

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Tokens.padding.large
                    spacing: Tokens.spacing.medium

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Tokens.spacing.medium

                        Item {
                            implicitWidth: 48
                            implicitHeight: 48

                            IconImage {
                                anchors.fill: parent
                                asynchronous: true
                                source: LauncherCustomizer.imageFor(dlg.icon) || Quickshell.iconPath("application-x-executable")
                            }

                            // Result badge on the app's icon.
                            StyledRect {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: -4
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: 11
                                color: dlg.state === "done" ? Colours.palette.m3primary : Colours.palette.m3error
                                scale: dlg.state === "done" || dlg.state === "failed" ? 1 : 0

                                MaterialIcon {
                                    anchors.centerIn: parent
                                    text: dlg.state === "done" ? "check" : "priority_high"
                                    color: dlg.state === "done" ? Colours.palette.m3onPrimary : Colours.palette.m3onError
                                    fontStyle: Tokens.font.icon.small
                                }

                                Behavior on scale {
                                    Anim {
                                        type: Anim.FastSpatial
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            StyledText {
                                Layout.fillWidth: true
                                text: ({
                                        loading: qsTr("Uninstall %1?"),
                                        confirm: qsTr("Uninstall %1?"),
                                        unknown: qsTr("Can't uninstall %1"),
                                        working: qsTr("Uninstalling %1…"),
                                        done: qsTr("%1 was uninstalled"),
                                        failed: qsTr("%1 wasn't uninstalled")
                                    })[dlg.state]?.arg(dlg.name) ?? ""
                                animate: true
                                wrapMode: Text.WordWrap
                                font: Tokens.font.title.medium
                            }

                            StyledText {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                text: {
                                    if (dlg.state === "loading")
                                        return qsTr("Checking how it was installed…");
                                    if (dlg.state === "unknown" || dlg.state === "failed")
                                        return dlg.error;
                                    if (dlg.state === "working")
                                        return dlg.info.needsAuth ? qsTr("Enter your password when asked.") : qsTr("This can take a moment.");
                                    if (dlg.state === "done")
                                        return dlg.info.keeps ? qsTr("Its launcher is gone; the program it started is still there.") : "";
                                    return dlg.info.summary ?? "";
                                }
                                wrapMode: Text.WordWrap
                                color: dlg.state === "failed" || dlg.state === "unknown" ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.medium
                            }
                        }
                    }

                    // In plain words: what goes and what stays.
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: dlg.state === "confirm"
                        spacing: Tokens.spacing.small

                        Repeater {
                            model: dlg.info.details ?? []

                            RowLayout {
                                id: detail

                                required property string modelData
                                required property int index

                                Layout.fillWidth: true
                                spacing: Tokens.spacing.small

                                MaterialIcon {
                                    Layout.alignment: Qt.AlignTop
                                    readonly property bool warn: detail.modelData.indexOf("stop working") >= 0
                                    text: detail.index === 0 ? "delete" : (warn ? "warning" : (detail.modelData.indexOf("kept") >= 0 || detail.modelData.indexOf("stay") >= 0 ? "check_circle" : "remove_circle"))
                                    color: detail.index === 0 || warn ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                                    fontStyle: Tokens.font.icon.small
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: detail.modelData
                                    wrapMode: Text.WordWrap
                                    font: Tokens.font.body.medium
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: dlg.state === "confirm"
                        Layout.topMargin: Tokens.spacing.small
                        text: qsTr("What runs")
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.medium
                    }

                    // The exact command, for those who want to know.
                    StyledRect {
                        Layout.fillWidth: true
                        visible: dlg.state === "confirm"
                        implicitHeight: stepsCol.implicitHeight + Tokens.padding.medium * 2
                        radius: Tokens.rounding.medium
                        color: Colours.palette.m3surfaceContainerHighest

                        ColumnLayout {
                            id: stepsCol

                            anchors.fill: parent
                            anchors.margins: Tokens.padding.medium
                            spacing: 2

                            Repeater {
                                model: dlg.info.steps ?? []

                                StyledText {
                                    required property string modelData

                                    Layout.fillWidth: true
                                    text: modelData
                                    wrapMode: Text.WrapAnywhere
                                    color: Colours.palette.m3onSurfaceVariant
                                    font.family: "monospace"
                                    font.pointSize: Tokens.font.body.small.pointSize
                                }
                            }
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: dlg.state === "confirm" && !!dlg.info.needsAuth
                        text: qsTr("This is installed for everyone on this PC, so you may be asked for your password.")
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                    }

                    // Busy while it runs.
                    MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        visible: dlg.state === "working" || dlg.state === "loading"
                        text: "progress_activity"
                        color: Colours.palette.m3primary
                        fontStyle: Tokens.font.icon.large

                        RotationAnimation on rotation {
                            running: dlg.state === "working" || dlg.state === "loading"
                            from: 0
                            to: 360
                            duration: 1000
                            loops: Animation.Infinite
                        }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignRight
                        visible: dlg.state !== "working" && dlg.state !== "loading"
                        spacing: Tokens.spacing.small

                        TextButton {
                            text: dlg.state === "confirm" ? qsTr("Cancel") : qsTr("Close")
                            type: TextButton.Text
                            onClicked: dlg.close()
                        }

                        TextButton {
                            visible: dlg.state === "confirm"
                            text: qsTr("Uninstall")
                            type: TextButton.Tonal
                            inactiveColour: Colours.palette.m3errorContainer
                            inactiveOnColour: Colours.palette.m3onErrorContainer
                            onClicked: dlg.confirm()
                        }
                    }
                }
            }
        }
    }
}
