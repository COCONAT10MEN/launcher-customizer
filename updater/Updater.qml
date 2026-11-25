import QtQuick
import Quickshell
import Quickshell.Io

// Opt-in updates. Looks for a newer GitHub release at most once a day (and right
// after Caelestia updates) and asks with a notification, or the Update button in
// Settings -> Plugins; nothing changes unless the user clicks Update. All the
// work is in update.sh, which only runs for a moment: a short check after the
// shell starts, then every six hours (it skips the network for 20 hours after
// a check).
Scope {
    id: updater

    required property string pluginDir
    property bool now: false

    function check(): void {
        if (!proc.running)
            proc.running = true;
    }

    // Right away, ignoring the once-a-day limit: used when a Caelestia update
    // broke the plugin's patch, so a fixed version shows up as soon as it exists.
    function checkNow(): void {
        updater.now = true;
        check();
    }

    Process {
        id: proc

        command: ["bash", updater.pluginDir + "/updater/update.sh", "check", updater.pluginDir, Quickshell.shellDir, updater.now ? "now" : ""]
        onExited: updater.now = false
    }

    // The Update button in Settings -> Plugins (shared with the other plugins
    // that ship this updater; whichever starts first adds it).
    Process {
        running: true
        command: ["python3", "-I", updater.pluginDir + "/updater/pagehook.py", "apply", Quickshell.shellDir]
        // Settings loads its pages with the shell, before plugins run: a page
        // that was just patched needs one restart to show the button.
        stdout: StdioCollector {
            onStreamFinished: {
                const r = text.trim();
                if (r === "PATCHED" || r.startsWith("FAILED+RELOAD"))
                    Quickshell.execDetached(["sh", updater.pluginDir + "/restart-shell.sh", Quickshell.shellPath("shell.qml")]);
            }
        }
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
