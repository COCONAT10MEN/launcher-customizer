#!/usr/bin/env python3
"""Update button in Settings -> Plugins for plugins that update from GitHub.

Caelestia's Plugins page already draws an Update button on a plugin's row, but
only for plugins from its own store. This adds the same button for plugins
whose updater/update.sh found a newer release (it leaves a note in
~/.local/state/caelestia/plugin-updates/<id>/available), and pressing it runs
that plugin's `update.sh install`.

Every plugin that ships this file runs it; they share one marked block, the
newest version of this script wins, and `revert` puts the page back to stock.

Usage:
    pagehook.py apply    <shell dir>   -> OK | PATCHED | FAILED: <reason>
    pagehook.py revert   <shell dir>   -> REVERTED | NOTHING
    pagehook.py watchdog <shell dir>   -> OK | REVERTED | NOTHING (run by systemd after a patch)

Like the plugins' own patches it is watched: if Caelestia doesn't come back
right after adding the button, the page goes back to stock on its own and this
Caelestia build is left alone.
"""

import base64
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import heal  # noqa: E402

TAG = "caelestia-plugin-updates"
VERSION = 2
REL = "modules/nexus/pages/PluginsPage.qml"
BLOCK_RE = re.compile(r"^// " + TAG + r":begin v(\d+)\n.*?^// " + TAG + r":orig ([A-Za-z0-9+/=]*)\n// " + TAG + r":end\n", re.S | re.M)

HELPERS = r'''    // Plugins that update from their own GitHub releases get the same Update
    // button (their updater leaves a note in plugin-updates/<id>/available).
    property var cpuAvailable: ({})
    property string cpuBusy: ""
    function cpuVersion(pluginId) {
        const v = root.cpuAvailable[pluginId];
        return v ? v.version : "";
    }
    function cpuHasUpdate(pluginId, installedVersion) {
        const v = root.cpuVersion(pluginId);
        return v !== "" && !!installedVersion && PluginStore.compareVersions(installedVersion, v) < 0;
    }
    function cpuRefresh() {
        root.cpuProc.running = true;
    }
    function cpuUpdate(pluginId, path) {
        root.cpuBusy = pluginId;
        Quickshell.execDetached(["bash", path + "/updater/update.sh", "install", path, Quickshell.shellDir]);
    }
    // A property, not a child: the page only takes visual items as children.
    readonly property Process cpuProc: Process {
        command: ["sh", "-c", 'd="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/plugin-updates"; for f in "$d"/*/available; do [ -f "$f" ] && printf "%s %s\\n" "$(basename "$(dirname "$f")")" "$(cat "$f")"; done; true']
        stdout: StdioCollector {
            onStreamFinished: {
                const found = {};
                for (const line of text.split("\n")) {
                    const p = line.trim().split(/\s+/);
                    if (p.length >= 2)
                        found[p[0]] = { version: p[1] };
                }
                root.cpuAvailable = found;
            }
        }
    }

'''

ID = "(userDelegate.id || userDelegate.name)"
OPS = [
    (REL, '    title: qsTr("Plugins")\n', HELPERS + '    title: qsTr("Plugins")\n'),
    (REL,
     "    Component.onCompleted: {\n        if (PluginStore.storePlugins.count === 0) {\n",
     "    Component.onCompleted: {\n        root.cpuRefresh();\n        if (PluginStore.storePlugins.count === 0) {\n"),
    (REL,
     "                    isUpdateAvailable: root.isUpdateAvailableFor(userDelegate.id || userDelegate.name, userDelegate.version)\n",
     f"                    isUpdateAvailable: root.isUpdateAvailableFor(userDelegate.id || userDelegate.name, userDelegate.version) || root.cpuHasUpdate({ID}, userDelegate.version)\n"),
    (REL,
     "                    updateVersionText: root.storeVersionFor(userDelegate.id || userDelegate.name)\n",
     f"                    updateVersionText: root.storeVersionFor(userDelegate.id || userDelegate.name) || root.cpuVersion({ID})\n"),
    (REL,
     "                    updateBusy: PluginStore.installing && PluginStore.installingId === (userDelegate.id || userDelegate.name)\n",
     f"                    updateBusy: (PluginStore.installing && PluginStore.installingId === (userDelegate.id || userDelegate.name)) || root.cpuBusy === {ID}\n"),
    (REL,
     "                    onUpdateRequested: PluginStore.installPlugin(userDelegate.id || userDelegate.name, userDelegate.path, root.storeBranch, userDelegate.restart)\n",
     f"                    onUpdateRequested: root.cpuHasUpdate({ID}, userDelegate.version) ? root.cpuUpdate({ID}, userDelegate.path) : PluginStore.installPlugin(userDelegate.id || userDelegate.name, userDelegate.path, root.storeBranch, userDelegate.restart)\n"),
]


def block(original: str, replacement: str) -> str:
    b64 = base64.b64encode(original.encode()).decode()
    return f"// {TAG}:begin v{VERSION}\n{replacement}// {TAG}:orig {b64}\n// {TAG}:end\n"


def strip(text: str) -> str:
    return BLOCK_RE.sub(lambda m: base64.b64decode(m.group(2)).decode(), text)


def write_atomic(path: str, text: str) -> None:
    st = os.stat(path)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".PluginsPage.qml.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("apply", "revert", "watchdog"):
        print(__doc__.strip())
        return 2
    action, shell = sys.argv[1], sys.argv[2]
    path = os.path.join(shell, REL)
    heal.hold_shell_lock()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        print("FAILED: Plugins page not found")
        return 1
    stock = strip(text)

    def write_stock():
        with open(path, encoding="utf-8") as f:
            now = f.read()
        if strip(now) != now:
            write_atomic(path, strip(now))

    guard = heal.Guard(TAG, os.path.abspath(__file__), shell, "Plugin updates")
    if action == "watchdog":
        print(guard.watchdog(write_stock))
        return 0
    if action == "revert":
        if stock != text:
            write_atomic(path, stock)
            print("REVERTED")
        else:
            print("NOTHING")
        return 0
    # A newer copy of this script (from another plugin) already did it.
    versions = [int(v) for v, _ in BLOCK_RE.findall(text)]
    if versions and max(versions) > VERSION:
        print("OK")
        return 0
    try:
        want, _healed = heal.patch_ops(OPS, {REL: stock}, block, TAG)
        if guard.refused({REL: stock}, [REL]):
            raise ValueError("adding the button broke this Caelestia before, so it's left alone")
    except ValueError as e:
        # Leave the page as Caelestia ships it; the notification still works.
        if stock != text:
            write_atomic(path, stock)
        print(f"FAILED: {e}")
        return 1
    if want[REL] == text:
        failed = guard.check(write_stock)
        print(f"FAILED{failed[len('FAILED'):]}" if failed else "OK")
        return 1 if failed else 0
    write_atomic(path, want[REL])
    guard.record({REL: stock}, [REL])
    print("PATCHED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
