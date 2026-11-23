import QtQuick
import Quickshell
import Quickshell.Io

// Opt-in updates. Looks for a newer GitHub release at most once a day and asks
// with a notification; nothing changes unless the user clicks Update. All the
// work is in update.sh, which only runs for a moment: a short check after the
// shell starts, then every six hours (it skips the network for 20 hours after
// a check).
Scope {
    id: updater

    required property string pluginDir

    function check(): void {
        if (!proc.running)
            proc.running = true;
    }

    Process {
        id: proc

        command: ["bash", updater.pluginDir + "/updater/update.sh", "check", updater.pluginDir, Quickshell.shellDir]
    }

    Timer {
        running: true
        interval: 20000
        onTriggered: updater.check()
    }

    Timer {
        running: true
        repeat: true
        interval: 6 * 60 * 60 * 1000
        onTriggered: updater.check()
    }
}
