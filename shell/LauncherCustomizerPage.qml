pragma ComponentBehavior: Bound
// launcher-customizer:managed
// Installed into the shell by the Launcher Customizer plugin
// (https://github.com/COCONAT10MEN/launcher-customizer) and removed by its
// revert. Settings -> Panels & Interface -> Launcher -> Launcher Customizer:
// hosts the plugin's editor, which lives in the plugin's own folder.

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common
import qs.modules.launcher.services

PageBase {
    id: root

    title: qsTr("Launcher Customizer")
    isSubPage: true
    scrollable: false

    Item {
        anchors.fill: parent

        Loader {
            id: editor

            anchors.fill: parent

            function load(): void {
                if (LauncherCustomizer.pluginActive && LauncherCustomizer.store && String(LauncherCustomizer.editorUrl) !== "")
                    editor.setSource(LauncherCustomizer.editorUrl, { store: LauncherCustomizer.store });
                else
                    editor.source = "";
            }

            Component.onCompleted: load()

            Connections {
                function onPluginActiveChanged(): void {
                    editor.load();
                }

                function onStoreChanged(): void {
                    editor.load();
                }

                target: LauncherCustomizer
            }
        }

        ColumnLayout {
            anchors.centerIn: parent
            visible: editor.status !== Loader.Ready
            spacing: Tokens.spacing.medium

            MaterialIcon {
                Layout.alignment: Qt.AlignHCenter
                text: "dashboard_customize"
                color: Colours.palette.m3outline
                fontStyle: Tokens.font.icon.extraLarge
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: editor.status === Loader.Error ? qsTr("The editor could not be loaded") : qsTr("Launcher Customizer is not running")
                color: Colours.palette.m3onSurfaceVariant
            }
        }
    }
}
