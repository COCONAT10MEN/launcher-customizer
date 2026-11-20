#!/usr/bin/env python3
"""Launcher Customizer patcher for the Caelestia shell.

Caelestia's plugin API has no hooks for launcher categories or launcher
placement, so this script wires the plugin into the shell:

* copies shell/LauncherCustomizer.qml into modules/launcher/services/
* replaces a few exact snippets in the launcher and drawers files

Every change is wrapped in marker comments that also store the original text
(base64), so `revert` restores the files byte for byte. The plugin runs
`apply` on every shell start: after a Caelestia update replaces the files, it
patches them again. It is all-or-nothing: if any snippet no longer matches
(the update changed that code), every file is put back to stock instead of
leaving a half-patched shell.

Usage:
    patch.py apply  <shell dir>  -> OK | PATCHED | FAILED[+RELOAD]: <reason>
    patch.py revert <shell dir>  -> REVERTED | NOTHING
    patch.py status <shell dir>  -> APPLIED | PARTIAL | MISSING
"""

import base64
import os
import re
import sys
import tempfile

TAG = "launcher-customizer"
VERSION = "5"
HERE = os.path.dirname(os.path.abspath(__file__))
MANAGED = f"// {TAG}:managed"
CREATED = {
    "modules/launcher/services/LauncherCustomizer.qml": os.path.join(HERE, "shell", "LauncherCustomizer.qml"),
}
BLOCK_RE = re.compile(
    r"^// " + TAG + r":begin[^\n]*\n.*?^// " + TAG + r":orig ([A-Za-z0-9+/=]*)\n// " + TAG + r":end\n",
    re.S | re.M,
)

# (file, exact original snippet, replacement). Snippets are whole lines.
OPS = [
    # ---------------------------------------------------------------- categories
    (
        "modules/launcher/services/Categories.qml",
        "    readonly property var definitions: [\n",
        "    // Stock list; `definitions` below layers the user's edits on top.\n"
        "    readonly property var lcBaseDefinitions: [\n",
    ),
    (
        "modules/launcher/services/Categories.qml",
        '    /// The curated category a desktop entry belongs to, or "other".\n'
        "    function categoryForApp(app): string {\n",
        "    readonly property var definitions: LauncherCustomizer.definitionsFor(root.lcBaseDefinitions)\n"
        "\n"
        '    /// The curated category a desktop entry belongs to, or "other".\n'
        "    function categoryForApp(app): string {\n"
        "        // An app the user moved by hand goes where they put it.\n"
        '        const lcId = String(app?.id ?? "");\n'
        "        const lcPick = lcId.length > 0 ? LauncherCustomizer.assignments[lcId] : undefined;\n"
        "        if (lcPick && root.definitions.some(d => d.id === lcPick))\n"
        "            return lcPick;\n"
        "        // Synced with KDE: the first KDE category the app is listed in.\n"
        "        if (LauncherCustomizer.useKde && lcId.length > 0)\n"
        "            return LauncherCustomizer.kdeFirst(root.definitions, lcId);\n",
    ),
    (
        "modules/launcher/AppBrowserGrid.qml",
        "    Connections {\n"
        "        function onLauncherStyleChanged(): void {\n",
        "    // Category edits: rebuild, and leave a category that was just hidden.\n"
        "    Connections {\n"
        "        function onDataChanged(): void {\n"
        "            Qt.callLater(root.lcRefresh);\n"
        "        }\n"
        "\n"
        "        function onPluginActiveChanged(): void {\n"
        "            Qt.callLater(root.lcRefresh);\n"
        "        }\n"
        "\n"
        "        function onKdeChanged(): void {\n"
        "            Qt.callLater(root.lcRefresh);\n"
        "        }\n"
        "\n"
        "        target: LauncherCustomizer\n"
        "    }\n"
        "\n"
        "    function lcRefresh(): void {\n"
        "        root.refresh();\n"
        "        if (root.visibleCategories.length > 0 && !root.visibleCategories.some(d => d.id === root.currentCategory))\n"
        "            root.selectCategory(root.visibleCategories[0].id);\n"
        "    }\n"
        "\n"
        "    Connections {\n"
        "        function onLauncherStyleChanged(): void {\n",
    ),
    (
        "modules/launcher/items/AppContextMenu.qml",
        "import qs.utils\n",
        "import qs.utils\nimport qs.modules.launcher.services\n",
    ),
    (
        "modules/launcher/items/AppContextMenu.qml",
        "        Controls.MenuItem {\n"
        '            text: qsTr("App info")\n',
        "        Controls.MenuItem {\n"
        '            text: qsTr("Move to category…")\n'
        '            icon: "drive_file_move"\n'
        "            visible: LauncherCustomizer.pluginActive\n"
        "            onClicked: {\n"
        "                const appId = root.app?.id;\n"
        "                if (!appId)\n"
        "                    return;\n"
        "                LauncherCustomizer.requestEdit(appId);\n"
        "                if (root.visibilities)\n"
        "                    root.visibilities.launcher = false;\n"
        "            }\n"
        "        },\n"
        "        Controls.MenuItem {\n"
        '            text: qsTr("App info")\n',
    ),
    # ----------------------------------------------------------------- placement
    (
        "modules/launcher/Wrapper.qml",
        "    property real avatarOpenScale: shouldBeActive ? 1 : 0\n",
        "    // At the top edge there is no room above the card for the profile picture.\n"
        '    property real avatarOpenScale: shouldBeActive && lcEdge !== "top" ? 1 : 0\n',
    ),
    (
        "modules/launcher/Wrapper.qml",
        "    readonly property bool avatarVisible: root.visible && (content.item?.showAvatar ?? false)\n",
        '    readonly property bool avatarVisible: root.visible && (content.item?.showAvatar ?? false) && root.lcEdge !== "top"\n',
    ),
    (
        "modules/launcher/Wrapper.qml",
        '    clip: Config.bar.position === "bottom" && !root.avatarVisible\n'
        "    visible: offsetScale < 1\n"
        '    anchors.bottomMargin: (Config.bar.position === "bottom" ? 0 : -implicitHeight - 5) * offsetScale\n'
        '    height: Config.bar.position === "bottom" ? implicitHeight * (1 - offsetScale) : implicitHeight\n',
        "    // The edge the launcher opens from. When the bar is on that edge the\n"
        "    // launcher grows out of it; otherwise it slides in from off-screen.\n"
        "    readonly property string lcPlacement: LauncherCustomizer.placement\n"
        "    readonly property string lcEdge: LauncherCustomizer.edgeFor(Config.bar.position)\n"
        "    readonly property bool lcAttached: Config.bar.position === lcEdge\n"
        '    readonly property bool lcVertical: lcEdge === "left" || lcEdge === "right"\n'
        "    // How far it is pushed off-screen while sliding (when not attached).\n"
        "    readonly property real lcSlide: lcAttached ? 0 : ((lcVertical ? implicitWidth : implicitHeight) + 5) * offsetScale\n"
        "    clip: lcAttached && !root.avatarVisible\n"
        "    visible: offsetScale < 1\n"
        "    height: !lcVertical && lcAttached ? implicitHeight * (1 - offsetScale) : implicitHeight\n"
        "    width: lcVertical && lcAttached ? implicitWidth * (1 - offsetScale) : implicitWidth\n",
    ),
    (
        "modules/launcher/Wrapper.qml",
        "        anchors.top: parent.top\n"
        "        anchors.horizontalCenter: parent.horizontalCenter\n",
        "        // Pinned to the side away from the edge, so it slides out of it.\n"
        '        anchors.top: root.lcEdge === "top" ? undefined : parent.top\n'
        '        anchors.bottom: root.lcEdge === "top" ? parent.bottom : undefined\n'
        "        anchors.horizontalCenter: root.lcVertical ? undefined : parent.horizontalCenter\n"
        '        anchors.right: root.lcEdge === "left" ? parent.right : undefined\n'
        '        anchors.left: root.lcEdge === "right" ? parent.left : undefined\n',
    ),
    (
        "modules/drawers/Panels.qml",
        '        property string vAnchor: "bottom"\n'
        '        property string hAnchor: "center"\n'
        "\n"
        "        screen: root.screen\n"
        "        visibilities: root.visibilities\n"
        "        panels: root\n"
        "        anchors.horizontalCenter: parent.horizontalCenter\n"
        "        anchors.bottom: parent.bottom\n",
        '        property string vAnchor: lcEdge === "top" ? "top" : (lcEdge === "bottom" ? "bottom" : "center")\n'
        '        property string hAnchor: lcEdge === "left" ? "left" : (lcEdge === "right" ? "right" : "center")\n'
        "        // \"Follow dock\": shift the launcher along its edge so it is centred on\n"
        "        // the dock, while keeping it fully on screen.\n"
        "        readonly property real lcAlongOffset: {\n"
        '            if (lcPlacement !== "dock")\n'
        "                return 0;\n"
        '            const dock = Visibilities.docks.get(root.screen?.name ?? "");\n'
        "            if (!dock || !dock.visible || dock.width <= 0 || dock.height <= 0)\n"
        "                return 0;\n"
        "            // Re-run when the dock, the window or the launcher moves or opens.\n"
        "            void (dock.x + dock.y + dock.width + dock.height + root.width + root.height + width + height + (shouldBeActive ? 1 : 0));\n"
        "            const p = dock.mapToItem(root, dock.width / 2, dock.height / 2);\n"
        "            const along = lcVertical ? p.y - root.height / 2 : p.x - root.width / 2;\n"
        "            const room = Math.max(0, ((lcVertical ? root.height - height : root.width - width)) / 2);\n"
        "            // Leave space above the card for the profile picture's overhang.\n"
        "            const lead = lcVertical && avatarVisible ? Math.min(room * 2, avatarSize / 2 + 4) : 0;\n"
        "            return Math.max(-room + lead, Math.min(room, along));\n"
        "        }\n"
        "\n"
        "        screen: root.screen\n"
        "        visibilities: root.visibilities\n"
        "        panels: root\n"
        "        // Positioned explicitly (no anchors) so it can sit on any edge.\n"
        '        x: lcEdge === "left" ? -lcSlide : (lcEdge === "right" ? parent.width - width + lcSlide : (parent.width - width) / 2 + lcAlongOffset)\n'
        '        y: lcEdge === "top" ? -lcSlide : (lcEdge === "bottom" ? parent.height - height + lcSlide : (parent.height - height) / 2 + lcAlongOffset)\n',
    ),
    (
        "modules/drawers/Regions.qml",
        "        panel: root.panels.launcher\n"
        "        y: root.win.height - height\n"
        "        height: root.Config.launcher.enabled ? panel.height * (1 - root.panels.launcher.offsetScale) + root.edgeExtent(root.Config.launcher.hoverThickness) + (panel.height * (1 - root.panels.launcher.offsetScale) > 0 ? root.panels.bottomMargin : 0) : 0\n",
        "        panel: root.panels.launcher\n"
        "        // Off the bottom edge the launcher's input area is simply its own rect.\n"
        '        y: root.panels.launcher.lcEdge === "bottom" ? root.win.height - height : panel.y + root.panels.topMargin\n'
        '        height: root.panels.launcher.lcEdge !== "bottom" ? (root.Config.launcher.enabled && panel.visible ? panel.height : 0) : (root.Config.launcher.enabled ? panel.height * (1 - root.panels.launcher.offsetScale) + root.edgeExtent(root.Config.launcher.hoverThickness) + (panel.height * (1 - root.panels.launcher.offsetScale) > 0 ? root.panels.bottomMargin : 0) : 0)\n',
    ),
    (
        "modules/drawers/Interactions.qml",
        "    function inLauncherAvatar(x: real, y: real): bool {\n",
        "    // Hit test for a launcher that is not on the bottom edge.\n"
        "    function lcInLauncher(x: real, y: real): bool {\n"
        "        const l = panels.launcher;\n"
        "        const lx = panels.leftMargin + l.x;\n"
        "        const ly = panels.topMargin + l.y;\n"
        "        const pad = Surface.panelRounding;\n"
        "        return l.visible && x >= lx - pad && x <= lx + l.width + pad && y >= ly - pad && y <= ly + l.height + pad;\n"
        "    }\n"
        "    function inLauncherAvatar(x: real, y: real): bool {\n",
    ),
    (
        "modules/drawers/Interactions.qml",
        "            else if (visibilities.launcher && ((inBottomPanel(panels.launcher, event.x, event.y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth) && withinPanelWidth(panels.launcher, event.x, event.y)) || inLauncherAvatar(event.x, event.y))) inside = true;\n",
        '            else if (visibilities.launcher && ((panels.launcher.lcEdge === "bottom" ? (inBottomPanel(panels.launcher, event.x, event.y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth) && withinPanelWidth(panels.launcher, event.x, event.y)) : lcInLauncher(event.x, event.y)) || inLauncherAvatar(event.x, event.y))) inside = true;\n',
    ),
    (
        "modules/drawers/Interactions.qml",
        "            if (!visibilities.launcher && inBottomPanel(panels.launcher, x, y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth))\n",
        "            // Hover-to-open only applies while the launcher is on the bottom edge.\n"
        '            if (!visibilities.launcher && panels.launcher.lcEdge === "bottom" && inBottomPanel(panels.launcher, x, y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth))\n',
    ),
    (
        "modules/drawers/Interactions.qml",
        "        } else if (Config.launcher.enabled && pressed && inBottomPanel(panels.launcher, dragStart.x, dragStart.y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth) && withinPanelWidth(panels.launcher, x, y)) {\n",
        "        // Drag-to-open also only applies on the bottom edge.\n"
        '        } else if (Config.launcher.enabled && pressed && panels.launcher.lcEdge === "bottom" && inBottomPanel(panels.launcher, dragStart.x, dragStart.y, false, Config.launcher.hoverThickness, Config.launcher.hoverWidth) && withinPanelWidth(panels.launcher, x, y)) {\n',
    ),
    (
        "modules/launcher/services/Categories.qml",
        "    function visibleCategories(all: list<var>): list<var> {\n",
        "    function visibleCategories(all: list<var>): list<var> {\n"
        "        // KDE categories can share apps, so test membership, not first match.\n"
        "        if (LauncherCustomizer.useKde)\n"
        '            return root.definitions.filter(d => d.id === "favorites" || d.id === "all" || all.some(a => LauncherCustomizer.kdeHas(d.id, a.id)));\n',
    ),
    (
        "modules/launcher/services/Categories.qml",
        "    function appsFor(categoryId: string, all: list<var>): list<var> {\n",
        "    function appsFor(categoryId: string, all: list<var>): list<var> {\n"
        '        if (LauncherCustomizer.useKde && categoryId.startsWith("kde:"))\n'
        "            return all.filter(a => LauncherCustomizer.kdeHas(categoryId, a.id));\n",
    ),
    (
        "modules/launcher/items/CategoryButton.qml",
        "import qs.services\n",
        "import qs.services\nimport Quickshell.Widgets\n",
    ),
    (
        "modules/launcher/items/CategoryButton.qml",
        "        MaterialIcon {\n"
        "            anchors.verticalCenter: parent.verticalCenter\n"
        '            text: catRoot.modelData?.icon ?? "apps"\n',
        "        // Categories can also use an icon-theme icon or an image file.\n"
        "        IconImage {\n"
        "            anchors.verticalCenter: parent.verticalCenter\n"
        '            visible: !(catRoot.modelData?.icon) && !!(catRoot.modelData?.iconSource)\n'
        "            implicitSize: visible ? 22 : 0\n"
        '            source: catRoot.modelData?.iconSource ?? ""\n'
        "            asynchronous: true\n"
        "        }\n"
        "\n"
        "        MaterialIcon {\n"
        "            anchors.verticalCenter: parent.verticalCenter\n"
        '            visible: !!(catRoot.modelData?.icon) || !(catRoot.modelData?.iconSource)\n'
        '            text: catRoot.modelData?.icon || "apps"\n',
    ),
    (
        "modules/nexus/pages/PluginsPage.qml",
        "import qs.modules.nexus.common\n",
        "import qs.modules.nexus.common\nimport qs.modules.launcher.services\n",
    ),
    (
        "modules/nexus/pages/PluginsPage.qml",
        "                                visible: userDelegate.settingsCount > 0\n"
        "                                onClicked: {\n",
        "                                visible: userDelegate.settingsCount > 0\n"
        "                                onClicked: {\n"
        "                                    // Launcher Customizer has a full editor instead of the settings popup.\n"
        '                                    if ((userDelegate.id || userDelegate.name) === "launcher-customizer" && LauncherCustomizer.pluginActive) {\n'
        '                                        LauncherCustomizer.requestEdit("");\n'
        "                                        return;\n"
        "                                    }\n",
    ),
]


def block(original: str, replacement: str) -> str:
    b64 = base64.b64encode(original.encode()).decode()
    return f"// {TAG}:begin v{VERSION}\n{replacement}// {TAG}:orig {b64}\n// {TAG}:end\n"


def strip(text: str) -> str:
    return BLOCK_RE.sub(lambda m: base64.b64decode(m.group(1)).decode(), text)


def read(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None


def write_atomic(path: str, text: str) -> None:
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def plan(shell: str):
    """Current, stock and patched text of every touched file."""
    files = sorted({op[0] for op in OPS})
    current = {}
    for rel in files:
        text = read(os.path.join(shell, rel))
        if text is None:
            raise FileNotFoundError(rel)
        current[rel] = text
    stock = {rel: strip(text) for rel, text in current.items()}
    return current, stock


def patched(stock: dict) -> dict:
    out = dict(stock)
    for rel, original, replacement in OPS:
        text = out[rel]
        count = text.count(original)
        if count != 1:
            first = original.strip().splitlines()[0].strip()
            raise ValueError(f"{rel}: snippet found {count} times: {first[:70]!r} (Caelestia changed; plugin needs updating)")
        out[rel] = text.replace(original, block(original, replacement), 1)
    return out


def created_state(shell: str):
    """[(dest, wanted text, current text or None, ours?)]"""
    res = []
    for rel, src in CREATED.items():
        with open(src, encoding="utf-8") as f:
            want = f.read()
        dest = os.path.join(shell, rel)
        cur = read(dest)
        res.append((dest, want, cur, cur is None or MANAGED in cur))
    return res


def remove_created(shell: str) -> bool:
    changed = False
    for dest, _want, cur, ours in created_state(shell):
        if cur is not None and ours:
            os.unlink(dest)
            changed = True
    return changed


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("apply", "revert", "status"):
        print(__doc__.strip())
        return 2
    action, shell = sys.argv[1], sys.argv[2]

    try:
        current, stock = plan(shell)
    except FileNotFoundError as e:
        print(f"FAILED: shell file missing: {e}")
        return 1

    if action == "status":
        n = sum(len(BLOCK_RE.findall(t)) for t in current.values())
        made = all(cur is not None and ours for _d, _w, cur, ours in created_state(shell))
        print("APPLIED" if n == len(OPS) and made else ("MISSING" if n == 0 and not made else "PARTIAL"))
        return 0

    if action == "revert":
        changed = False
        for rel, text in stock.items():
            if text != current[rel]:
                write_atomic(os.path.join(shell, rel), text)
                changed = True
        changed = remove_created(shell) or changed
        print("REVERTED" if changed else "NOTHING")
        return 0

    # apply
    try:
        want = patched(stock)
    except ValueError as e:
        # All-or-nothing: put everything back to stock so the shell stays sane.
        changed = False
        for rel, text in stock.items():
            if text != current[rel]:
                write_atomic(os.path.join(shell, rel), text)
                changed = True
        changed = remove_created(shell) or changed
        print(f"FAILED{'+RELOAD' if changed else ''}: {e}")
        return 1

    for dest, _w, cur, ours in created_state(shell):
        if cur is not None and not ours:
            print(f"FAILED: {dest} exists and is not ours; not touching it")
            return 1

    changed = False
    for dest, wanted, cur, _ours in created_state(shell):
        if cur != wanted:
            write_atomic(dest, wanted)
            changed = True
    for rel, text in want.items():
        if text != current[rel]:
            write_atomic(os.path.join(shell, rel), text)
            changed = True
    print("PATCHED" if changed else "OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
