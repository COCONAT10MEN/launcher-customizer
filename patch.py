#!/usr/bin/env python3
"""Launcher Customizer patcher for the Caelestia shell.

Caelestia's plugin API has no hooks for launcher categories, so this script
wires the plugin into the shell:

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
VERSION = "32"
HERE = os.path.dirname(os.path.abspath(__file__))
MANAGED = f"// {TAG}:managed"
CREATED = {
    "modules/launcher/services/LauncherCustomizer.qml": os.path.join(HERE, "shell", "LauncherCustomizer.qml"),
    "modules/nexus/pages/panels/LauncherCustomizerPage.qml": os.path.join(HERE, "shell", "LauncherCustomizerPage.qml"),
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
        '        const lcId = String(app?.id ?? "");\n'
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
        "import qs.services\nimport Quickshell.Widgets\nimport qs.modules.launcher.services\n",
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
        "                                // Launcher Customizer has no Nexus settings, but a full editor behind this button.\n"
        '                                visible: userDelegate.settingsCount > 0 || ((userDelegate.id || userDelegate.name) === "launcher-customizer" && LauncherCustomizer.pluginActive)\n'
        "                                onClicked: {\n"
        "                                    // Launcher Customizer has a full editor instead of the settings popup.\n"
        '                                    if ((userDelegate.id || userDelegate.name) === "launcher-customizer" && LauncherCustomizer.pluginActive) {\n'
        '                                        LauncherCustomizer.requestEdit("");\n'
        "                                        return;\n"
        "                                    }\n",
    ),
    (
        'modules/launcher/items/AppContextMenu.qml',
        '                Launch.exec(["kmenuedit", desktopFile]);\n',
        '                // Launcher Customizer: app details open in its editor.\n'
        '                if (LauncherCustomizer.pluginActive)\n'
        '                    LauncherCustomizer.requestEdit(root.app.id);\n'
        '                else\n'
        '                    Launch.exec(["kmenuedit", desktopFile]);\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        'import qs.modules.launcher.services\n',
        'import qs.modules.launcher.services\n'
        'import Quickshell.Widgets\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '    property var visibleCategories: []\n',
        '    property var visibleCategories: []\n'
        '\n'
        '    // Launcher Customizer: KDE subcategories as sections, and the custom\n'
        '    // order you set by dragging tiles.\n'
        '    property var lcSections: []\n'
        '    readonly property bool lcCustom: sortSettings.sortMode === "custom" && LauncherCustomizer.pluginActive\n'
        '    property var lcDrag: null\n'
        '    property string lcDropId: ""\n'
        '    property bool lcDropAfter: false\n'
        '    property point lcDragPos: Qt.point(0, 0)\n'
        '    property point lcDragScene: Qt.point(0, 0)\n'
        '    property bool lcOverDock: false\n'
        '    property var lcDockItem: null\n'
        '\n'
        "    /// The bar's dock, found once: the item that keeps launching apps.\n"
        '    function lcFindDock(item: var): var {\n'
        '        if (!item)\n'
        '            return null;\n'
        '        if (item.launchingApps !== undefined && item.isDragging !== undefined)\n'
        '            return item;\n'
        '        for (let i = 0; i < item.children.length; i++) {\n'
        '            const r = root.lcFindDock(item.children[i]);\n'
        '            if (r)\n'
        '                return r;\n'
        '        }\n'
        '        return null;\n'
        '    }\n'
        '\n'
        '    function lcDockAt(scenePos: point): bool {\n'
        '        if (!root.lcDockItem) {\n'
        '            for (const bar of Visibilities.bars.values()) {\n'
        '                root.lcDockItem = root.lcFindDock(bar);\n'
        '                if (root.lcDockItem)\n'
        '                    break;\n'
        '            }\n'
        '        }\n'
        '        const dock = root.lcDockItem;\n'
        '        if (!dock || !dock.visible || dock.Window.window !== root.Window.window)\n'
        '            return false;\n'
        '        const p = dock.mapFromItem(null, scenePos.x, scenePos.y);\n'
        '        return p.x >= -8 && p.y >= -8 && p.x <= dock.width + 8 && p.y <= dock.height + 8;\n'
        '    }\n'

        '    // "Open on last tab": remember the tab you were on; with it off, the\n'
        '    // launcher always starts on Favorites.\n'
        '    onCurrentCategoryChanged: {\n'
        '        LauncherCustomizer.lastCategory = root.currentCategory;\n'
        '        // Switching category: the apps slide in from the side of the new one\n'
        "        // (further down the list: from below), like Settings' page switches.\n"
        '        const from = root.visibleCategories.findIndex(d => d.id === root.lcPrevCategory);\n'
        '        const to = root.visibleCategories.findIndex(d => d.id === root.currentCategory);\n'
        '        root.lcPrevCategory = root.currentCategory;\n'
        '        if (!root.lcIntro && LauncherCustomizer.pluginActive)\n'
        '            root.lcSwapIn(from >= 0 && to >= 0 && from !== to ? (to > from ? 1 : -1) : 0);\n'
        '    }\n'
        '\n'
        '    property string lcPrevCategory: root.currentCategory\n'
        '    // The category refresh() last built (cleared by anything else that rebuilds).\n'
        '    property string lcShown: ""\n'
        '    // True while the launcher is opening (no category slide then).\n'
        '    property bool lcIntro: LauncherCustomizer.pluginActive\n'
        '    // While the whole grid is replaced, its per-tile transitions stay off.\n'
        '    property bool lcSwitching: true\n'
        '    readonly property int lcMovement: Tokens.padding.extraExtraLarge * 2\n'
        '\n'
        '    function lcSwapIn(dir: int): void {\n'
        '        root.lcSwitching = true;\n'
        '        lcSwitchEnd.restart();\n'
        '        lcSwap.stop();\n'
        '        lcGridShift.y = dir * root.lcMovement / 2;\n'
        '        grid.opacity = 0;\n'
        '        lcSwap.start();\n'
        '    }\n'
        '\n'
        '    ParallelAnimation {\n'
        '        id: lcSwap\n'
        '\n'
        '        Anim {\n'
        '            target: grid\n'
        '            property: "opacity"\n'
        '            to: 1\n'
        '            type: Anim.SlowEffects\n'
        '        }\n'
        '        Anim {\n'
        '            target: lcGridShift\n'
        '            property: "y"\n'
        '            to: 0\n'
        '            type: Anim.SlowEffects\n'
        '        }\n'
        '    }\n'
        '\n'
        '    Timer {\n'
        '        id: lcSwitchEnd\n'
        '\n'
        '        interval: 450\n'
        '        onTriggered: root.lcSwitching = false\n'
        '    }\n'
        '\n'

        '    Timer {\n'
        '        id: lcIntroEnd\n'
        '\n'
        '        running: root.lcIntro\n'
        '        interval: 700\n'
        '        onTriggered: {\n'
        '            root.lcIntro = false;\n'
        '            root.lcSwitching = false;\n'
        '        }\n'
        '    }\n'

        '\n'
        '    function lcStartCategory(): void {\n'
        '        if (!LauncherCustomizer.pluginActive)\n'
        '            return;\n'
        '        const want = LauncherCustomizer.openLastTab ? LauncherCustomizer.lastCategory : "favorites";\n'
        '        if (want && want !== root.currentCategory && root.visibleCategories.some(d => d.id === want))\n'
        '            root.selectCategory(want);\n'
        '    }\n'
        '\n'
        '    Connections {\n'
        '        function onLauncherChanged(): void {\n'
        '            if (root.visibilities.launcher) {\n'
        '                root.lcIntro = LauncherCustomizer.pluginActive;\n'
        '                // Each open starts in the apps, not in the category list.\n'
        '                root.sidebarFocused = false;\n'
        '                root.lcSwitching = true;\n'
        '                root.lcStartCategory();\n'
        '                lcIntroEnd.restart();\n'
        '            }\n'
        '        }\n'
        '\n'
        '        target: root.visibilities\n'
        '    }\n'
        '\n'
        '    function lcSameSections(a: var, b: var): bool {\n'
        '        if (a.length !== b.length)\n'
        '            return false;\n'
        '        for (let i = 0; i < a.length; i++) {\n'
        '            const x = a[i], y = b[i];\n'
        '            if (x.id !== y.id || x.name !== y.name || x.icon !== y.icon || x.iconSource !== y.iconSource || x.apps.length !== y.apps.length)\n'
        '                return false;\n'
        '            for (let j = 0; j < x.apps.length; j++)\n'
        '                if (x.apps[j] !== y.apps[j])\n'
        '                    return false;\n'
        '        }\n'
        '        return true;\n'
        '    }\n'
        '\n'
        '    // Keyboard selection inside the subcategory sections: { sec, idx } or null.\n'
        '    property var lcSecSel: null\n'
        '\n'
        '    function lcColsOf(sec: int): int {\n'
        '        const s = root.lcSections[sec];\n'
        '        if (!s)\n'
        '            return 1;\n'
        '        const flowing = LauncherCustomizer.sectionLayout === "flow";\n'
        '        const pad = LauncherCustomizer.lookFor(s.id).enabled || flowing ? Tokens.padding.medium : 0;\n'
        '        const tileW = Tokens.sizes.launcher.browseTileWidth;\n'
        '        const gap = Tokens.spacing.medium;\n'
        '        const perRow = Math.max(1, Math.floor((grid.width - pad * 2 + gap) / (tileW + gap)));\n'
        '        return Math.max(1, Math.min(perRow, s.apps.length));\n'
        '    }\n'
        '\n'
        '    function lcGridCols(): int {\n'
        '        return Math.max(1, Math.floor(grid.width / grid.cellWidth));\n'
        '    }\n'
        '\n'
        '    function lcSelectSection(sec: int, idx: int): void {\n'
        '        const s = root.lcSections[sec];\n'
        '        if (!s || s.apps.length === 0)\n'
        '            return;\n'
        '        root.lcSecSel = { sec: sec, idx: Math.max(0, Math.min(idx, s.apps.length - 1)) };\n'
        '        grid.currentIndex = -1;\n'
        '        Qt.callLater(root.lcRevealSel);\n'
        '    }\n'
        '\n'
        '    function lcFindTile(item: var, name: string): var {\n'
        '        if (!item)\n'
        '            return null;\n'
        '        if (item.objectName === name)\n'
        '            return item;\n'
        '        for (let i = 0; i < item.children.length; i++) {\n'
        '            const r = root.lcFindTile(item.children[i], name);\n'
        '            if (r)\n'
        '                return r;\n'
        '        }\n'
        '        return null;\n'
        '    }\n'
        '\n'
        '    /// Scroll so the selected section tile is in view.\n'
        '    function lcRevealSel(): void {\n'
        '        const sel = root.lcSecSel;\n'
        '        const s = sel ? root.lcSections[sel.sec] : null;\n'
        '        const tile = s ? root.lcFindTile(grid.footerItem, "lcTile:" + s.apps[sel.idx]?.id) : null;\n'
        '        if (!tile)\n'
        '            return;\n'
        '        const y = tile.mapToItem(grid.contentItem, 0, 0).y;\n'
        '        const pad = Tokens.padding.small;\n'
        '        if (y < grid.contentY + pad)\n'
        '            grid.contentY = Math.max(grid.originY, y - pad);\n'
        '        else if (y + tile.height > grid.contentY + grid.height - pad)\n'
        '            grid.contentY = y + tile.height - grid.height + pad;\n'
        '    }\n'
        '\n'
        '    /// In the tab list, Up/Down show each category right away.\n'
        '    // Arrowing through the list loads a category once you pause on it, so\n'
        '    // passing through several does not build each one.\n'
        '    function lcPeekCategory(id: string): void {\n'
        '        lcPeekTimer.target = id;\n'
        '        lcPeekTimer.restart();\n'
        '    }\n'
        '\n'
        '    Timer {\n'
        '        id: lcPeekTimer\n'
        '\n'
        '        property string target: ""\n'
        '\n'
        '        interval: 120\n'
        '        onTriggered: root.lcShowCategory(lcPeekTimer.target)\n'
        '    }\n'
        '\n'
        '    function lcShowCategory(id: string): void {\n'
        '        if (!id || id === root.currentCategory)\n'
        '            return;\n'
        '        root.currentCategory = id;\n'
        '        root.refresh();\n'
        '        root.lcShown = id;\n'
        '        root.lcSecSel = null;\n'
        '        Qt.callLater(() => grid.currentIndex = -1);\n'
        '    }\n'
        '\n'
        '    function lcDown(): void {\n'
        '        const sel = root.lcSecSel;\n'
        '        if (sel) {\n'
        '            const n = root.lcSections[sel.sec].apps.length;\n'
        '            const cols = root.lcColsOf(sel.sec);\n'
        '            const col = sel.idx % cols;\n'
        '            if (sel.idx + cols < n)\n'
        '                root.lcSelectSection(sel.sec, sel.idx + cols);\n'
        '            else if (Math.floor(sel.idx / cols) < Math.floor((n - 1) / cols))\n'
        '                root.lcSelectSection(sel.sec, n - 1);\n'
        '            else if (sel.sec + 1 < root.lcSections.length)\n'
        '                root.lcSelectSection(sel.sec + 1, Math.min(col, root.lcColsOf(sel.sec + 1) - 1));\n'
        '            return;\n'
        '        }\n'
        '        if (grid.currentIndex < 0) {\n'
        '            if (grid.count > 0)\n'
        '                grid.currentIndex = 0;\n'
        '            else if (root.lcSections.length > 0)\n'
        '                root.lcSelectSection(0, 0);\n'
        '            return;\n'
        '        }\n'
        '        const before = grid.currentIndex;\n'
        '        grid.moveCurrentIndexDown();\n'
        '        if (grid.currentIndex === before && root.lcSections.length > 0)\n'
        '            root.lcSelectSection(0, Math.min(before % root.lcGridCols(), root.lcColsOf(0) - 1));\n'
        '    }\n'
        '\n'
        '    function lcUp(): void {\n'
        '        const sel = root.lcSecSel;\n'
        '        if (!sel) {\n'
        '            grid.moveCurrentIndexUp();\n'
        '            return;\n'
        '        }\n'
        '        const cols = root.lcColsOf(sel.sec);\n'
        '        const col = sel.idx % cols;\n'
        '        if (sel.idx - cols >= 0) {\n'
        '            root.lcSelectSection(sel.sec, sel.idx - cols);\n'
        '        } else if (sel.sec > 0) {\n'
        '            const n = root.lcSections[sel.sec - 1].apps.length;\n'
        '            const c = root.lcColsOf(sel.sec - 1);\n'
        '            root.lcSelectSection(sel.sec - 1, Math.min(Math.floor((n - 1) / c) * c + Math.min(col, c - 1), n - 1));\n'
        '        } else if (grid.count > 0) {\n'
        '            const gc = root.lcGridCols();\n'
        '            root.lcSecSel = null;\n'
        '            grid.currentIndex = Math.min(Math.floor((grid.count - 1) / gc) * gc + Math.min(col, gc - 1), grid.count - 1);\n'
        '        }\n'
        '    }\n'

        '\n'
        '    function lcGroupOf(id: string): var {\n'
        '        if (gridModel.values.some(a => a.id === id))\n'
        '            return { cat: root.currentCategory, ids: gridModel.values.map(a => a.id) };\n'
        '        for (const sec of root.lcSections)\n'
        '            if (sec.apps.some(a => a.id === id))\n'
        '                return { cat: sec.id, ids: sec.apps.map(a => a.id) };\n'
        '        return null;\n'
        '    }\n'
        '\n'
        '    function lcTileAt(scenePos: point): var {\n'
        '        const gp = grid.mapFromItem(null, scenePos.x, scenePos.y);\n'
        '        const i = grid.indexAt(gp.x + grid.contentX, gp.y + grid.contentY);\n'
        '        if (i >= 0 && i < gridModel.values.length) {\n'
        '            const cell = grid.itemAtIndex(i);\n'
        '            const local = cell ? cell.mapFromItem(null, scenePos.x, scenePos.y) : Qt.point(0, 0);\n'
        '            return { id: gridModel.values[i].id, after: cell ? local.x > cell.width / 2 : false };\n'
        '        }\n'
        '        let item = grid.footerItem;\n'
        '        let p = item ? item.mapFromItem(null, scenePos.x, scenePos.y) : null;\n'
        '        while (item) {\n'
        '            if (String(item.objectName).startsWith("lcTile:"))\n'
        '                return { id: String(item.objectName).slice(7), after: p.x > item.width / 2 };\n'
        '            const c = item.childAt(p.x, p.y);\n'
        '            if (!c)\n'
        '                break;\n'
        '            p = c.mapFromItem(item, p.x, p.y);\n'
        '            item = c;\n'
        '        }\n'
        '        return null;\n'
        '    }\n'
        '\n'
        '    function lcDragBegin(tile: var): void {\n'
        '        const g = root.lcGroupOf(tile.modelData.id);\n'
        '        if (g)\n'
        '            root.lcDrag = { id: tile.modelData.id, name: tile.modelData.name, icon: tile.modelData.icon, cat: g.cat, ids: g.ids };\n'
        '    }\n'
        '\n'
        '    function lcDragMove(scenePos: point): void {\n'
        '        if (!root.lcDrag)\n'
        '            return;\n'
        '        root.lcDragPos = grid.mapFromItem(null, scenePos.x, scenePos.y);\n'
        '        root.lcDragScene = scenePos;\n'
        '        root.lcOverDock = root.lcDockAt(scenePos);\n'
        '        // Reordering by drag is the Custom order; any order can drop on the dock.\n'
        '        const t = root.lcCustom && !root.lcOverDock ? root.lcTileAt(scenePos) : null;\n'
        '        if (!root.lcCustom || root.lcOverDock) {\n'
        '            root.lcDropId = "";\n'
        '        } else if (t && t.id !== root.lcDrag.id && root.lcDrag.ids.includes(t.id)) {\n'
        '            root.lcDropId = t.id;\n'
        '            root.lcDropAfter = t.after;\n'
        '        } else if (t) {\n'
        '            // Over itself or another group: no drop. Over empty space (the gap\n'
        '            // after a row) the last spot stays, so letting go there still works.\n'
        '            root.lcDropId = "";\n'
        '        }\n'
        '    }\n'
        '\n'
        '    function lcDragEnd(): void {\n'
        '        const d = root.lcDrag;\n'
        '        // Dropped on the dock: pin it there.\n'
        '        if (d && root.lcOverDock) {\n'
        '            const pinned = (GlobalConfig.bar.dock.pinnedApps ?? []).slice();\n'
        '            if (!Strings.testRegexList(pinned, d.id)) {\n'
        '                GlobalConfig.bar.dock.pinnedApps = pinned.concat([d.id]);\n'
        '                Toaster.toast(qsTr("Pinned to dock"), d.name ?? d.id, "push_pin");\n'
        '            }\n'
        '            root.lcDropId = "";\n'
        '        }\n'
        '        if (d && root.lcDropId) {\n'
        '            const ids = d.ids.filter(x => x !== d.id);\n'
        '            let at = ids.indexOf(root.lcDropId);\n'
        '            if (root.lcDropAfter)\n'
        '                at++;\n'
        '            ids.splice(at, 0, d.id);\n'
        '            LauncherCustomizer.requestReorder(d.cat, ids);\n'
        '            // Show the new order at once; the saved one takes over on the next refresh.\n'
        '            if (d.cat === root.currentCategory) {\n'
        '                const byId = {};\n'
        '                for (const a of gridModel.values)\n'
        '                    byId[a.id] = a;\n'
        '                gridModel.values = ids.map(x => byId[x]).filter(Boolean);\n'
        '            } else {\n'
        '                root.lcSections = root.lcSections.map(sec => {\n'
        '                    if (sec.id !== d.cat)\n'
        '                        return sec;\n'
        '                    const byId = {};\n'
        '                    for (const a of sec.apps)\n'
        '                        byId[a.id] = a;\n'
        '                    return Object.assign({}, sec, { apps: ids.map(x => byId[x]).filter(Boolean) });\n'
        '                });\n'
        '            }\n'
        '        }\n'
        '        root.lcDrag = null;\n'
        '        root.lcOverDock = false;\n'
        '        root.lcDropId = "";\n'
        '    }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        const nextApps = root.sortedApps(Categories.appsFor(root.currentCategory, all));\n',
        '        // Launcher Customizer: sections for KDE subcategories, and the custom order.\n'
        '        const lcArr = LauncherCustomizer.arrange(root.currentCategory, Categories.appsFor(root.currentCategory, all), all, sortSettings.sortMode, l => root.sortedApps(l));\n'
        '        const nextApps = lcArr.top;\n'
        '        root.lcShown = root.currentCategory;\n'
        '        // Same sections as before: keep them (and their tiles) as they are.\n'
        '        if (!root.lcSameSections(root.lcSections, lcArr.sections))\n'
        '            root.lcSections = lcArr.sections;\n'
        '        if (root.lcSecSel && !root.lcSections[root.lcSecSel.sec])\n'
        '            root.lcSecSel = null;\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '    implicitHeight: root.padding * 2 + (root.count === 0 ? root.tileCellHeight * 2 : root.rows * root.tileCellHeight)\n',
        '    implicitHeight: root.padding * 2 + (root.count === 0 ? (root.lcSections.length > 0 ? 0 : root.tileCellHeight * 2) : root.rows * root.tileCellHeight) + (grid.footerItem?.height ?? 0)\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '                StyledScrollBar.vertical: StyledScrollBar {\n'
        '                    flickable: grid\n'
        '                }\n',
        '                StyledScrollBar.vertical: StyledScrollBar {\n'
        '                    flickable: grid\n'
        '                }\n'
        '\n'
        '                // Launcher Customizer: one block per KDE subcategory, stacked or\n'
        '                // flowing side by side.\n'
        '                footer: Flow {\n'
        '                    readonly property bool flowing: LauncherCustomizer.sectionLayout === "flow"\n'
        '\n'
        '                    width: grid.width\n'
        '                    topPadding: root.lcSections.length > 0 ? (grid.count > 0 ? Tokens.spacing.extraLarge : Tokens.spacing.small) : 0\n'
        '                    bottomPadding: root.lcSections.length > 0 ? Tokens.spacing.medium : 0\n'
        '                    spacing: flowing ? Tokens.spacing.large : Tokens.spacing.extraLarge + Tokens.spacing.small\n'
        '\n'
        '                    Repeater {\n'
        '                        model: root.lcSections\n'
        '\n'
        '                        delegate: Item {\n'
        '                            id: lcSec\n'
        '\n'
        '                            required property var modelData\n'
        '                            required property int index\n'
        '                            readonly property var look: LauncherCustomizer.lookFor(lcSec.modelData.id)\n'
        '                            readonly property bool flowing: LauncherCustomizer.sectionLayout === "flow"\n'
        '                            // Flowing blocks all get the same inner padding, so titles line up.\n'
        '                            readonly property int pad: lcSec.look.enabled || lcSec.flowing ? Tokens.padding.medium : 0\n'
        '                            readonly property int tileW: Tokens.sizes.launcher.browseTileWidth\n'
        '                            readonly property int gap: Tokens.spacing.medium\n'
        '                            readonly property int perRow: Math.max(1, Math.floor((grid.width - lcSec.pad * 2 + lcSec.gap) / (lcSec.tileW + lcSec.gap)))\n'
        '                            readonly property int cols: Math.max(1, Math.min(lcSec.perRow, lcSec.modelData.apps.length))\n'
        '\n'
        '                            // Just big enough for its tiles and title.\n'
        '                            readonly property int fitW: Math.max(lcSec.cols * lcSec.tileW + (lcSec.cols - 1) * lcSec.gap, lcHead.implicitWidth + (lcSec.flowing ? 0 : Tokens.padding.small * 2)) + lcSec.pad * 2\n'
        '\n'
        '                            // Stacked blocks keep a full row each, so the next one starts below.\n'
        '                            width: lcSec.flowing ? lcSec.fitW : grid.width\n'
        '                            height: lcBody.implicitHeight + lcSec.pad * 2\n'
        '\n'
        '                            StyledRect {\n'
        '                                width: lcSec.fitW\n'
        '                                height: parent.height\n'
        '                                visible: lcSec.look.enabled\n'
        '                                radius: Tokens.rounding.large\n'
        '                                color: lcSec.look.color\n'
        '                            }\n'
        '\n'
        '                            Column {\n'
        '                                id: lcBody\n'
        '\n'
        '                                x: lcSec.pad\n'
        '                                y: lcSec.pad\n'
        '                                width: lcSec.fitW - lcSec.pad * 2\n'
        '                                spacing: Tokens.spacing.small\n'
        '\n'
        '                                Row {\n'
        '                                    id: lcHead\n'
        '\n'
        '                                    // Flowing blocks centre their title; stacked ones keep it on the left.\n'
        '                                    x: lcSec.flowing ? (lcBody.width - width) / 2 : Tokens.padding.small\n'
        '                                    spacing: Tokens.spacing.small\n'
        '\n'
        '                                    MaterialIcon {\n'
        '                                        anchors.verticalCenter: parent.verticalCenter\n'
        '                                        visible: !!lcSec.modelData.icon\n'
        '                                        text: lcSec.modelData.icon ?? ""\n'
        '                                        color: lcSec.look.label.a > 0 ? lcSec.look.label : Colours.palette.m3primary\n'
        '                                        fontStyle: Tokens.font.icon.small\n'
        '                                    }\n'
        '\n'
        '                                    IconImage {\n'
        '                                        anchors.verticalCenter: parent.verticalCenter\n'
        '                                        visible: !lcSec.modelData.icon && !!lcSec.modelData.iconSource\n'
        '                                        implicitSize: visible ? 18 : 0\n'
        '                                        source: lcSec.modelData.iconSource ?? ""\n'
        '                                    }\n'
        '\n'
        '                                    StyledText {\n'
        '                                        anchors.verticalCenter: parent.verticalCenter\n'
        '                                        text: lcSec.modelData.name\n'
        '                                        color: lcSec.look.label.a > 0 ? lcSec.look.label : Colours.palette.m3onSurfaceVariant\n'
        '                                        font: Tokens.font.label.large\n'
        '                                    }\n'
        '                                }\n'
        '\n'
        '                                Flow {\n'
        '                                    width: lcBody.width\n'
        '                                    spacing: lcSec.gap\n'
        '\n'
        '                                    Repeater {\n'
        '                                        model: lcSec.modelData.apps\n'
        '\n'
        '                                        delegate: Item {\n'
        '                                            id: lcCell\n'
        '\n'
        '                                            required property var modelData\n'
        '                                            required property int index\n'
        '\n'
        '                                            objectName: "lcTile:" + lcCell.modelData.id\n'
        '                                            implicitWidth: lcTile.implicitWidth\n'
        '                                            implicitHeight: lcTile.implicitHeight\n'
        '\n'
        '                                            AppTile {\n'
        '                                                id: lcTile\n'
        '\n'
        '                                                modelData: lcCell.modelData\n'
        '                                                index: -1\n'
        '                                                selected: !root.sidebarFocused && !!root.lcSecSel && root.lcSecSel.sec === lcSec.index && root.lcSecSel.idx === lcCell.index\n'
        '                                                browser: root\n'
        '                                                lcCategory: lcSec.modelData.id\n'
        '                                                lcLabel: lcSec.look.label\n'
        '                                            }\n'
        '\n'
        '                                            HoverHandler {\n'
        '                                                onHoveredChanged: {\n'
        '                                                    if (hovered && !root.lcDrag) {\n'
        '                                                        root.lcSecSel = { sec: lcSec.index, idx: lcCell.index };\n'
        '                                                        grid.currentIndex = -1;\n'
        '                                                    }\n'
        '                                                }\n'
        '                                            }\n'
        '                                        }\n'
        '                                    }\n'
        '                                }\n'
        '                            }\n'
        '                        }\n'
        '                    }\n'
        '                }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '            Column {\n'
        '                anchors.centerIn: parent\n'
        '                spacing: Tokens.spacing.medium\n'
        '                visible: grid.count === 0\n',
        '            // Launcher Customizer: the tile being dragged.\n'
        '            StyledRect {\n'
        '                visible: !!root.lcDrag\n'
        '                z: 20\n'
        '                x: root.lcDragPos.x - width / 2\n'
        '                y: root.lcDragPos.y - height / 2\n'
        '                implicitWidth: 64\n'
        '                implicitHeight: 64\n'
        '                radius: Tokens.rounding.large\n'
        '                color: Colours.palette.m3secondaryContainer\n'
        '                scale: visible ? 1.08 : 0.8\n'
        '\n'
        '                IconImage {\n'
        '                    anchors.centerIn: parent\n'
        '                    implicitSize: 44\n'
        '                    source: root.lcDrag ? Quickshell.iconPath(root.lcDrag.icon, "application-x-executable") : ""\n'
        '                }\n'
        '\n'
        '                // Over the dock: a pin says what letting go does.\n'
        '                StyledRect {\n'
        '                    anchors.right: parent.right\n'
        '                    anchors.top: parent.top\n'
        '                    anchors.margins: -4\n'
        '                    implicitWidth: 24\n'
        '                    implicitHeight: 24\n'
        '                    radius: 12\n'
        '                    color: Colours.palette.m3primary\n'
        '                    scale: root.lcOverDock ? 1 : 0\n'
        '\n'
        '                    MaterialIcon {\n'
        '                        anchors.centerIn: parent\n'
        '                        text: "push_pin"\n'
        '                        fill: 1\n'
        '                        color: Colours.palette.m3onPrimary\n'
        '                        fontStyle: Tokens.font.icon.small\n'
        '                    }\n'
        '\n'
        '                    Behavior on scale {\n'
        '                        Anim {\n'
        '                            type: Anim.FastSpatial\n'
        '                        }\n'
        '                    }\n'
        '                }\n'
        '\n'
        '                Behavior on scale {\n'
        '                    Anim {\n'
        '                        type: Anim.FastSpatial\n'
        '                    }\n'
        '                }\n'
        '            }\n'
        '\n'
        '            Column {\n'
        '                anchors.centerIn: parent\n'
        '                spacing: Tokens.spacing.medium\n'
        '                visible: grid.count === 0 && root.lcSections.length === 0\n',
    ),
    (
        'modules/launcher/items/AppTile.qml',
        '    Item {\n'
        '        id: page\n',
        '    // Launcher Customizer: the category this tile is shown in (sections set it),\n'
        '    // and the label colour on a coloured category background.\n'
        '    property string lcCategory: ""\n'
        '    property color lcLabel: "transparent"\n'
        '    readonly property string lcCat: root.lcCategory || (root.browser?.currentCategory ?? "")\n'
        '    // Only the categories browser (Default layout) gets the plugin\'s extras.\n'
        '    readonly property bool lcOn: root.browser?.lcSections !== undefined\n'
        '    // "No hearts in Favorites": everything there is a favourite already.\n'
        '    readonly property bool lcHideHeart: root.lcOn && LauncherCustomizer.noFavHearts && root.lcCat === "favorites"\n'
        '\n'
        '    MaterialIcon {\n'
        '        z: 6\n'
        '        anchors.top: parent.top\n'
        '        anchors.left: parent.left\n'
        '        anchors.topMargin: Tokens.spacing.extraSmall\n'
        '        anchors.leftMargin: Tokens.spacing.extraSmall\n'
        '        visible: root.lcOn && LauncherCustomizer.pinnedIn(root.lcCat, root.modelData?.id ?? "")\n'
        '        text: "push_pin"\n'
        '        fill: 1\n'
        '        color: root.lcLabel.a > 0 ? root.lcLabel : Colours.palette.m3primary\n'
        '        fontStyle: Tokens.font.icon.small\n'
        '    }\n'
        '\n'
        '    // Launcher Customizer: in the custom order, drag a tile to move it. This\n'
        '    // area keeps the grid from taking the drag over (it would scroll instead),\n'
        "    // so it also handles the tile's clicks while the custom order is on.\n"
        '    MouseArea {\n'
        '        id: lcDragArea\n'
        '\n'
        '        property point start\n'
        '        property bool moved: false\n'
        '\n'
        '        anchors.fill: parent\n'
        '        z: 50\n'
        '        enabled: root.lcOn && LauncherCustomizer.pluginActive && !!root.modelData\n'
        '        acceptedButtons: Qt.LeftButton | Qt.RightButton\n'
        '        // Custom order: any direction drags. Otherwise only a sideways pull does\n'
        '        // (to the dock), so the grid still scrolls with a vertical drag.\n'
        '        preventStealing: !!root.browser?.lcCustom || moved\n'
        '        cursorShape: moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor\n'
        '\n'
        '        onPressed: mouse => {\n'
        '            // Leave the heart to the favourite button underneath.\n'
        '            const h = mapToItem(favIcon, mouse.x, mouse.y);\n'
        '            if (favIcon.visible && h.x > -6 && h.y > -6 && h.x < favIcon.width + 6 && h.y < favIcon.height + 6) {\n'
        '                mouse.accepted = false;\n'
        '                return;\n'
        '            }\n'
        '            start = Qt.point(mouse.x, mouse.y);\n'
        '            moved = false;\n'
        '            // Keep the tile\'s own press ripple.\n'
        '            tileArea.press(mouse.x, mouse.y);\n'
        '            tileArea.manualPressOverride = true;\n'
        '        }\n'
        '        onCanceled: {\n'
        '            tileArea.manualPressOverride = false;\n'
        '            if (moved)\n'
        '                root.browser.lcDragEnd();\n'
        '            moved = false;\n'
        '        }\n'
        '        onPositionChanged: mouse => {\n'
        '            if (!pressed || !(mouse.buttons & Qt.LeftButton))\n'
        '                return;\n'
        '            const dx = mouse.x - start.x, dy = mouse.y - start.y;\n'
        '            if (!moved && Math.hypot(dx, dy) > 8 && (root.browser.lcCustom || Math.abs(dx) > Math.abs(dy))) {\n'
        '                moved = true;\n'
        '                root.browser.lcDragBegin(root);\n'
        '            }\n'
        '            if (moved)\n'
        '                root.browser.lcDragMove(mapToItem(null, mouse.x, mouse.y));\n'
        '        }\n'
        '        onReleased: {\n'
        '            tileArea.manualPressOverride = false;\n'
        '            if (moved)\n'
        '                root.browser.lcDragEnd();\n'
        '        }\n'
        '        onClicked: mouse => {\n'
        '            if (moved)\n'
        '                return;\n'
        '            if (mouse.button === Qt.RightButton)\n'
        '                root.browser.openContextMenu(root.modelData, root);\n'
        '            else\n'
        '                root.browser.launch(root.modelData);\n'
        '        }\n'
        '    }\n'
        '\n'
        '    Rectangle {\n'
        '        visible: !!root.browser?.lcDrag && root.browser?.lcDropId === (root.modelData?.id ?? "")\n'
        '        z: 5\n'
        '        width: 3\n'
        '        radius: 2\n'
        '        height: parent.height * 0.7\n'
        '        anchors.verticalCenter: parent.verticalCenter\n'
        '        x: root.browser?.lcDropAfter ? parent.width - 1 : -2\n'
        '        color: Colours.palette.m3primary\n'
        '    }\n'
        '\n'
        '    Item {\n'
        '        id: page\n',
    ),
    (
        'modules/launcher/Content.qml',
        '            icon: list.currentList?.sortMode === "alpha" ? "sort_by_alpha" : "trending_up"\n',
        '            icon: ({ alpha: "sort_by_alpha", custom: "drag_indicator", newest: "new_releases", oldest: "history" })[list.currentList?.sortMode] ?? "trending_up"\n',
    ),
    (
        'modules/launcher/Content.qml',
        '                trailingIcon: list.currentList?.sortMode === "alpha" ? "" : "check"\n',
        '                trailingIcon: ["alpha", "custom", "newest", "oldest"].includes(list.currentList?.sortMode) ? "" : "check"\n',
    ),
    (
        'modules/launcher/Content.qml',
        '                    list.currentList?.setSortMode("alpha");\n'
        '                }\n'
        '            }\n'
        '        ]\n',
        '                    list.currentList?.setSortMode("alpha");\n'
        '                }\n'
        '            },\n'
        '            // Launcher Customizer: your own order; drag tiles to arrange them.\n'
        '            MenuItem {\n'
        '                text: qsTr("Custom")\n'
        '                icon: "drag_indicator"\n'
        '                visible: LauncherCustomizer.pluginActive\n'
        '                trailingIcon: list.currentList?.sortMode === "custom" ? "check" : ""\n'
        '\n'
        '                onClicked: {\n'
        '                    sortMenu.expanded = false;\n'
        '                    list.currentList?.setSortMode("custom");\n'
        '                }\n'
        '            },\n'
        '            // Launcher Customizer: by when the app was installed or last updated.\n'
        '            MenuItem {\n'
        '                text: qsTr("Newest first")\n'
        '                icon: "new_releases"\n'
        '                visible: LauncherCustomizer.pluginActive\n'
        '                trailingIcon: list.currentList?.sortMode === "newest" ? "check" : ""\n'
        '\n'
        '                onClicked: {\n'
        '                    sortMenu.expanded = false;\n'
        '                    list.currentList?.setSortMode("newest");\n'
        '                }\n'
        '            },\n'
        '            MenuItem {\n'
        '                text: qsTr("Oldest first")\n'
        '                icon: "history"\n'
        '                visible: LauncherCustomizer.pluginActive\n'
        '                trailingIcon: list.currentList?.sortMode === "oldest" ? "check" : ""\n'
        '\n'
        '                onClicked: {\n'
        '                    sortMenu.expanded = false;\n'
        '                    list.currentList?.setSortMode("oldest");\n'
        '                }\n'
        '            }\n'
        '        ]\n',
    ),
    (
        'modules/launcher/items/AppTile.qml',
        'import qs.utils\n',
        'import qs.utils\n'
        'import qs.modules.launcher.services\n',
    ),
    (
        'modules/launcher/items/AppTile.qml',
        '                    NameLabel {\n'
        '                        id: name\n'
        '\n'
        '                        anchors.top: parent.top\n'
        '                        anchors.horizontalCenter: parent.horizontalCenter\n'
        '                        maxLines: root.labelLines\n'
        '                    }\n',
        '                    NameLabel {\n'
        '                        id: name\n'
        '\n'
        '                        anchors.top: parent.top\n'
        '                        anchors.horizontalCenter: parent.horizontalCenter\n'
        '                        maxLines: root.labelLines\n'
        '                        // Launcher Customizer: room for the "new" dot before the name.\n'
        '                        leftPadding: lcNewDot.visible ? 10 : 0\n'
        '                    }\n'
        '\n'
        '                    // Launcher Customizer: installed or updated recently, not opened yet.\n'
        '                    Rectangle {\n'
        '                        id: lcNewDot\n'
        '\n'
        '                        visible: root.lcOn && LauncherCustomizer.isNew(root.modelData?.id ?? "")\n'
        '                        width: 7\n'
        '                        height: 7\n'
        '                        radius: 4\n'
        '                        color: root.lcLabel.a > 0 ? root.lcLabel : Colours.palette.m3primary\n'
        '                        x: name.x + name.leftPadding + Math.max(0, (name.width - name.leftPadding - name.contentWidth) / 2) - width - 3\n'
        '                        y: name.y + (root.lineHeight - height) / 2\n'
        '                    }\n',
    ),
    (
        'modules/launcher/items/AppTile.qml',
        '        color: root.selected ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant\n',
        '        color: root.lcLabel.a > 0 ? root.lcLabel : (root.selected ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant)\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        Apps.launch(app);\n',
        '        LauncherCustomizer.markSeen(app?.id ?? "");\n'
        '        Apps.launch(app);\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        contextMenu.openFor(app, targetItem);\n',
        '        // Launcher Customizer: "Pin to top" acts on the category the tile is shown in.\n'
        '        LauncherCustomizer.contextCategory = targetItem?.lcCat ?? root.currentCategory;\n'
        '        LauncherCustomizer.contextApp = app?.id ?? "";\n'
        '        contextMenu.openFor(app, targetItem);\n',
    ),
    (
        'modules/launcher/items/AppContextMenu.qml',
        '        Controls.MenuItem {\n'
        '            text: qsTr("App info")\n',
        '        // Launcher Customizer: keep this app first in the category it was opened in.\n'
        '        Controls.MenuItem {\n'
        '            readonly property bool lcPinned: LauncherCustomizer.pinnedIn(LauncherCustomizer.contextCategory, root.app?.id ?? "")\n'
        '\n'
        '            visible: LauncherCustomizer.pluginActive && LauncherCustomizer.contextCategory !== "" && LauncherCustomizer.contextApp === (root.app?.id ?? "")\n'
        '            text: lcPinned ? qsTr("Unpin from top") : qsTr("Pin to top")\n'
        '            icon: "vertical_align_top"\n'
        '            onClicked: {\n'
        '                if (root.app?.id)\n'
        '                    LauncherCustomizer.requestPin(LauncherCustomizer.contextCategory, root.app.id, !lcPinned);\n'
        '            }\n'
        '        },\n'
        '        Controls.MenuItem {\n'
        '            text: qsTr("App info")\n',
    ),
    (
        'modules/nexus/NexusState.qml',
        'import Quickshell.Bluetooth\n',
        'import Quickshell.Bluetooth\n'
        'import qs.modules.launcher.services\n',
    ),
    (
        'modules/nexus/NexusState.qml',
        '    function selectSubCategory(key: string): void {\n',
        '    function selectSubCategory(key: string): void {\n'
        '        // Launcher Customizer: ask first when leaving its page with unsaved changes.\n'
        '        if (LauncherCustomizer.blockLeave(() => selectSubCategory(key)))\n'
        '            return;\n',
    ),
    (
        'modules/nexus/NexusState.qml',
        '    function goToPage(pageIdx: int): void {\n',
        '    function goToPage(pageIdx: int): void {\n'
        '        if (LauncherCustomizer.blockLeave(() => goToPage(pageIdx)))\n'
        '            return;\n',
    ),
    (
        'modules/nexus/NexusState.qml',
        '    function goToSubPage(pageIdx: int, subPageKey: string): void {\n',
        '    function goToSubPage(pageIdx: int, subPageKey: string): void {\n'
        '        if (subPageKey !== "launcherCustomizer" && LauncherCustomizer.blockLeave(() => goToSubPage(pageIdx, subPageKey)))\n'
        '            return;\n',
    ),
    (
        'modules/nexus/NexusState.qml',
        '    function closeSubPage(): void {\n',
        '    function closeSubPage(): void {\n'
        '        if (LauncherCustomizer.blockLeave(() => closeSubPage()))\n'
        '            return;\n',
    ),
    (
        'modules/nexus/PageCompRegistry.qml',
        '                component: Component { LauncherPanel {} }\n',
        '                component: Component { LauncherPanel {} }\n'
        '\n'
        '                // Launcher Customizer: the editor, as a page of its own.\n'
        '                SubPage { key: "launcherCustomizer"; label: qsTr("Launcher Customizer"); keywords: ["categories", "subcategories", "menu editor", "kmenuedit", "pin", "order", "launcher customizer"]; Component { LauncherCustomizerPage {} } }\n',
    ),
    (
        'modules/nexus/pages/panels/LauncherPanel.qml',
        '        SectionHeader {\n'
        '            text: qsTr("Display")\n'
        '        }\n',
        '        // Launcher Customizer: categories, order and app details.\n'
        '        SectionHeader {\n'
        '            visible: LauncherCustomizer.pluginActive\n'
        '            text: qsTr("Categories & apps")\n'
        '        }\n'
        '\n'
        '        NavRow {\n'
        '            visible: LauncherCustomizer.pluginActive\n'
        '            first: true\n'
        '            last: true\n'
        '            icon: "dashboard_customize"\n'
        '            label: qsTr("Launcher Customizer")\n'
        '            status: qsTr("Categories, subcategories, order, icons and app details")\n'
        '            onClicked: root.nState.openSubPage("launcherCustomizer")\n'
        '        }\n'
        '\n'
        '        SectionHeader {\n'
        '            text: qsTr("Display")\n'
        '        }\n',
    ),
    (
        'modules/launcher/Content.qml',
        '            anchors.right: commandsBtn.left\n',
        '            anchors.right: lcSortBtn.left\n',
    ),
    (
        'modules/launcher/Content.qml',
        '        IconButton {\n'
        '            id: commandsBtn\n',
        '        // Launcher Customizer: the classic style has no header, so its sort\n'
        '        // menu opens from here, next to the commands button.\n'
        '        IconButton {\n'
        '            id: lcSortBtn\n'
        '\n'
        '            readonly property bool shown: !root.modernStyle && LauncherCustomizer.pluginActive && root.isBrowsing && Boolean(list.currentList?.sortMode)\n'
        '\n'
        '            visible: lcSortBtn.shown\n'
        '            type: IconButton.Text\n'
        '            implicitWidth: lcSortBtn.shown ? 32 : 0\n'
        '            implicitHeight: 32\n'
        '            radius: Tokens.rounding.full\n'
        '            radiusMorph: false\n'
        '            icon: ({ alpha: "sort_by_alpha", custom: "drag_indicator", newest: "new_releases", oldest: "history" })[list.currentList?.sortMode] ?? "trending_up"\n'
        '\n'
        '            anchors.verticalCenter: parent.verticalCenter\n'
        '            anchors.right: commandsBtn.left\n'
        '            anchors.rightMargin: lcSortBtn.shown ? Tokens.spacing.small : 0\n'
        '\n'
        '            onClicked: sortMenu.expanded = !sortMenu.expanded\n'
        '        }\n'
        '\n'
        '        IconButton {\n'
        '            id: commandsBtn\n',
    ),
    (
        'modules/launcher/Content.qml',
        '        attachTo: sortBtn\n'
        '        attachSideX: Menu.Right\n'
        '        thisSideX: Menu.Right\n'
        '        attachSideY: Menu.Bottom\n'
        '        thisSideY: Menu.Top\n'
        '        marginY: Tokens.spacing.extraSmall\n',
        '        // Launcher Customizer: in the classic style it opens upwards from the\n'
        '        // sort button beside the search field.\n'
        '        attachTo: root.modernStyle ? sortBtn : lcSortBtn\n'
        '        attachSideX: Menu.Right\n'
        '        thisSideX: Menu.Right\n'
        '        attachSideY: root.modernStyle ? Menu.Bottom : Menu.Top\n'
        '        thisSideY: root.modernStyle ? Menu.Top : Menu.Bottom\n'
        '        marginY: Tokens.spacing.extraSmall * (root.modernStyle ? 1 : -1)\n',
    ),
    (
        'modules/launcher/Content.qml',
        '    readonly property bool modernStyle: Style.launcherStyle === "modern"\n',
        '    readonly property bool modernStyle: Style.launcherStyle === "modern"\n'
        '\n'
        '    // Launcher Customizer: "Typing always searches". On: whatever has focus,\n'
        '    // typing goes into search, and search takes focus back when it loses it\n'
        '    // to nothing. Off: search opens with "/" or a click; until then letters\n'
        '    // are ignored (arrows and Enter still work).\n'
        '    property bool lcSearchOpen: false\n'
        '    readonly property bool lcTypeAnywhere: LauncherCustomizer.pluginActive && LauncherCustomizer.typeToSearch\n'
        '    readonly property bool lcSearchGated: LauncherCustomizer.pluginActive && !LauncherCustomizer.typeToSearch\n'
        '\n'
        '    function lcPrintable(event: var): bool {\n'
        '        return !!event.text && event.text.length === 1 && event.text >= " " && event.text !== "\\x7f" && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));\n'
        '    }\n'
        '\n'
        '    Keys.onPressed: event => {\n'
        '        if (!root.lcTypeAnywhere || search.activeFocus || !root.lcPrintable(event))\n'
        '            return;\n'
        '        search.forceActiveFocus();\n'
        '        search.insert(search.cursorPosition, event.text);\n'
        '        event.accepted = true;\n'
        '    }\n'
        '\n'
        '    Connections {\n'
        '        function onActiveFocusChanged(): void {\n'
        '            if (!search.activeFocus && root.lcTypeAnywhere && root.visibilities.launcher)\n'
        '                lcRefocus.restart();\n'
        '        }\n'
        '\n'
        '        target: search\n'
        '    }\n'
        '\n'
        '    Timer {\n'
        '        id: lcRefocus\n'
        '\n'
        '        interval: 60\n'
        '        onTriggered: {\n'
        '            const f = root.Window.activeFocusItem;\n'
        '            const typing = !!f && f.selectedText !== undefined;\n'
        '            if (root.visibilities.launcher && root.lcTypeAnywhere && !search.activeFocus && !typing && !clearClipboardConfirmPopup.opened)\n'
        '                search.forceActiveFocus();\n'
        '        }\n'
        '    }\n',
    ),
    (
        'modules/launcher/Content.qml',
        '            placeholderText: qsTr("Type \\"%1\\" for commands").arg(GlobalConfig.launcher.actionPrefix)\n',
        '            placeholderText: root.lcSearchGated && !root.lcSearchOpen ? qsTr("Press / to search") : qsTr("Type \\"%1\\" for commands").arg(GlobalConfig.launcher.actionPrefix)\n'
        '            // Launcher Customizer: clicking the field opens search.\n'
        '            onPressed: root.lcSearchOpen = true\n',
    ),
    (
        'modules/launcher/Content.qml',
        '            Keys.onPressed: event => {\n'
        '                if (Windows.isSwitching && text.startsWith(`${GlobalConfig.launcher.actionPrefix}windows `)) {\n',
        '            Keys.onPressed: event => {\n'
        '                // Launcher Customizer: search is closed until "/" (or a click).\n'
        '                if (root.lcSearchGated && !root.lcSearchOpen && search.text === "" && root.lcPrintable(event)) {\n'
        '                    if (event.text === "/")\n'
        '                        root.lcSearchOpen = true;\n'
        '                    event.accepted = true;\n'
        '                    return;\n'
        '                }\n'
        '                if (Windows.isSwitching && text.startsWith(`${GlobalConfig.launcher.actionPrefix}windows `)) {\n',
    ),
    (
        'modules/launcher/Content.qml',
        '                    if (root.visibilities.launcher) {\n'
        '                        search.text = root.searchTextForMode(Visibilities.launcherMode);\n'
        '                        search.forceActiveFocus();\n',
        '                    if (root.visibilities.launcher) {\n'
        '                        search.text = root.searchTextForMode(Visibilities.launcherMode);\n'
        '                        search.forceActiveFocus();\n'
        '                        root.lcSearchOpen = false;\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '    function selectTile(index: int): void {\n'
        '        grid.currentIndex = index;\n'
        '    }\n',
        '    function selectTile(index: int): void {\n'
        '        // Launcher Customizer: section tiles (index -1) select themselves.\n'
        '        if (index < 0)\n'
        '            return;\n'
        '        root.lcSecSel = null;\n'
        '        grid.currentIndex = index;\n'
        '    }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '    function incrementCurrentIndex(): void {\n'
        '        if (root.sidebarFocused)\n'
        '            sidebar.incrementCurrentIndex();\n'
        '        else\n'
        '            grid.moveCurrentIndexDown();\n'
        '    }\n'
        '\n'
        '    function decrementCurrentIndex(): void {\n'
        '        if (root.sidebarFocused)\n'
        '            sidebar.decrementCurrentIndex();\n'
        '        else\n'
        '            grid.moveCurrentIndexUp();\n'
        '    }\n'
        '\n'
        '    function moveLeft(): void {\n'
        '        if (root.sidebarFocused)\n'
        '            return;\n'
        '        const before = grid.currentIndex;\n'
        '        grid.moveCurrentIndexLeft();\n'
        '        if (grid.currentIndex === before)\n'
        '            root.sidebarFocused = true;\n'
        '    }\n'
        '\n'
        '    function moveRight(): void {\n'
        '        if (root.sidebarFocused)\n'
        '            root.selectCategory(sidebar.currentItem?.modelData?.id ?? "favorites");\n'
        '        else\n'
        '            grid.moveCurrentIndexRight();\n'
        '    }\n',
        '    // Launcher Customizer: in the category list Up/Down switch categories as\n'
        '    // you go; in the apps, the arrows also reach the subcategory sections.\n'
        '    function incrementCurrentIndex(): void {\n'
        '        if (root.sidebarFocused) {\n'
        '            sidebar.incrementCurrentIndex();\n'
        '            if (LauncherCustomizer.pluginActive)\n'
        '                root.lcPeekCategory(sidebar.currentItem?.modelData?.id ?? "");\n'
        '        } else if (LauncherCustomizer.pluginActive) {\n'
        '            root.lcDown();\n'
        '        } else {\n'
        '            grid.moveCurrentIndexDown();\n'
        '        }\n'
        '    }\n'
        '\n'
        '    function decrementCurrentIndex(): void {\n'
        '        if (root.sidebarFocused) {\n'
        '            sidebar.decrementCurrentIndex();\n'
        '            if (LauncherCustomizer.pluginActive)\n'
        '                root.lcPeekCategory(sidebar.currentItem?.modelData?.id ?? "");\n'
        '        } else if (LauncherCustomizer.pluginActive) {\n'
        '            root.lcUp();\n'
        '        } else {\n'
        '            grid.moveCurrentIndexUp();\n'
        '        }\n'
        '    }\n'
        '\n'
        '    function moveLeft(): void {\n'
        '        if (root.sidebarFocused)\n'
        '            return;\n'
        '        const sel = root.lcSecSel;\n'
        '        if (sel) {\n'
        '            if (sel.idx % root.lcColsOf(sel.sec) === 0)\n'
        '                root.sidebarFocused = true;\n'
        '            else\n'
        '                root.lcSelectSection(sel.sec, sel.idx - 1);\n'
        '            return;\n'
        '        }\n'
        '        const before = grid.currentIndex;\n'
        '        grid.moveCurrentIndexLeft();\n'
        '        if (grid.currentIndex === before)\n'
        '            root.sidebarFocused = true;\n'
        '    }\n'
        '\n'
        '    function moveRight(): void {\n'
        '        if (root.sidebarFocused) {\n'
        '            root.selectCategory(sidebar.currentItem?.modelData?.id ?? "favorites");\n'
        '            return;\n'
        '        }\n'
        '        const sel = root.lcSecSel;\n'
        '        if (sel) {\n'
        '            if (sel.idx + 1 < root.lcSections[sel.sec].apps.length)\n'
        '                root.lcSelectSection(sel.sec, sel.idx + 1);\n'
        '            else if (sel.sec + 1 < root.lcSections.length)\n'
        '                root.lcSelectSection(sel.sec + 1, 0);\n'
        '            return;\n'
        '        }\n'
        '        grid.moveCurrentIndexRight();\n'
        '    }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        else if (grid.currentItem?.modelData)\n'
        '            root.launch(grid.currentItem.modelData);\n',
        '        else if (root.lcSecSel && root.lcSections[root.lcSecSel.sec])\n'
        '            root.launch(root.lcSections[root.lcSecSel.sec].apps[root.lcSecSel.idx]);\n'
        '        else if (grid.currentItem?.modelData)\n'
        '            root.launch(grid.currentItem.modelData);\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        sidebar.currentIndex = Math.max(0, idx);\n'
        '        root.refresh();\n'
        '        grid.currentIndex = grid.count > 0 ? 0 : -1;\n',
        '        sidebar.currentIndex = Math.max(0, idx);\n'
        '        // Launcher Customizer: already showing it (Up/Down shows categories as\n'
        '        // you go): no need to build it again.\n'
        '        lcPeekTimer.stop();\n'
        '        if (!(LauncherCustomizer.pluginActive && root.lcShown === id))\n'
        '            root.refresh();\n'
        '        root.lcShown = id;\n'
        '        grid.currentIndex = grid.count > 0 ? 0 : -1;\n'
        '        // Launcher Customizer: only sections here: start on the first one.\n'
        '        root.lcSecSel = null;\n'
        '        if (grid.count === 0 && root.lcSections.length > 0)\n'
        '            root.lcSelectSection(0, 0);\n',
    ),
    (
        'modules/launcher/items/AppTile.qml',
        '        opacity: ((root.simple ? tileArea.containsMouse : root.isFavourite) || favArea.containsMouse) ? 1 : 0\n',
        '        // Launcher Customizer: hidden in Favorites when "No hearts in Favorites" is on.\n'
        '        visible: !root.lcHideHeart\n'
        '        opacity: ((root.simple ? tileArea.containsMouse : root.isFavourite) || favArea.containsMouse) ? 1 : 0\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '    Component.onCompleted: {\n'
        '        root.refresh();\n'
        '        grid.currentIndex = grid.count > 0 ? 0 : -1;\n'
        '        sidebar.currentIndex = 0;\n',
        '    Component.onCompleted: {\n'
        '        root.refresh();\n'
        '        grid.currentIndex = grid.count > 0 ? 0 : -1;\n'
        '        sidebar.currentIndex = 0;\n'
        '        // Launcher Customizer: start on the last tab when that is switched on.\n'
        '        root.lcStartCategory();\n',
    ),
    (
        'modules/launcher/Content.qml',
        '        visible: root.modernStyle\n'
        '        anchors.left: parent.left\n'
        '        // Line the greeting up with the category labels: the browser adds its\n',
        '        // Launcher Customizer: the greeting can be hidden or reworded.\n'
        '        visible: root.modernStyle && !(LauncherCustomizer.pluginActive && !LauncherCustomizer.showGreeting)\n'
        '        anchors.left: parent.left\n'
        '        // Line the greeting up with the category labels: the browser adds its\n',
    ),
    (
        'modules/launcher/Content.qml',
        '        text: qsTr("Hello, %1").arg(root.userName)\n',
        '        text: LauncherCustomizer.pluginActive && LauncherCustomizer.greeting ? LauncherCustomizer.greeting.replace(/\\{name\\}/g, root.userName) : qsTr("Hello, %1").arg(root.userName)\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        sortSettings.sortMode = mode;\n'
        '        root.refresh();\n',
        '        sortSettings.sortMode = mode;\n'
        '        // Launcher Customizer: the new order fades in.\n'
        '        if (LauncherCustomizer.pluginActive)\n'
        '            root.lcSwapIn(0);\n'
        '        root.refresh();\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '                id: grid\n'
        '\n'
        '                anchors.fill: parent\n',
        '                id: grid\n'
        '\n'
        '                anchors.fill: parent\n'
        '\n'
        '                // Launcher Customizer: category switches slide the apps in;\n'
        '                // in-place changes (pins, favourites, sorting) move the tiles.\n'
        '                transform: Translate {\n'
        '                    id: lcGridShift\n'
        '                }\n'
        '\n'
        '                add: Transition {\n'
        '                    enabled: LauncherCustomizer.pluginActive && !root.lcSwitching\n'
        '\n'
        '                    Anim {\n'
        '                        property: "opacity"\n'
        '                        from: 0\n'
        '                        to: 1\n'
        '                        type: Anim.DefaultEffects\n'
        '                    }\n'
        '                    Anim {\n'
        '                        property: "scale"\n'
        '                        from: 0.85\n'
        '                        to: 1\n'
        '                        type: Anim.FastSpatial\n'
        '                    }\n'
        '                }\n'
        '\n'
        '                remove: Transition {\n'
        '                    enabled: LauncherCustomizer.pluginActive && !root.lcSwitching\n'
        '\n'
        '                    Anim {\n'
        '                        property: "opacity"\n'
        '                        to: 0\n'
        '                        type: Anim.FastEffects\n'
        '                    }\n'
        '                    Anim {\n'
        '                        property: "scale"\n'
        '                        to: 0.85\n'
        '                        type: Anim.FastEffects\n'
        '                    }\n'
        '                }\n'
        '\n'
        '                move: Transition {\n'
        '                    enabled: LauncherCustomizer.pluginActive && !root.lcSwitching\n'
        '\n'
        '                    Anim {\n'
        '                        properties: "x,y"\n'
        '                        type: Anim.DefaultSpatial\n'
        '                    }\n'
        '                }\n'
        '\n'
        '                displaced: Transition {\n'
        '                    enabled: LauncherCustomizer.pluginActive && !root.lcSwitching\n'
        '\n'
        '                    Anim {\n'
        '                        properties: "x,y"\n'
        '                        type: Anim.DefaultSpatial\n'
        '                    }\n'
        '                    Anim {\n'
        '                        properties: "opacity,scale"\n'
        '                        to: 1\n'
        '                        type: Anim.FastEffects\n'
        '                    }\n'
        '                }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '                currentIndex: 0\n'
        '                highlightFollowsCurrentItem: false\n'
        '                highlight: Item {}\n',
        '                currentIndex: 0\n'
        '                highlightFollowsCurrentItem: false\n'
        '                // Launcher Customizer: one highlight that slides between categories.\n'
        '                highlight: StyledRect {\n'
        '                    visible: LauncherCustomizer.pluginActive && !!sidebar.currentItem\n'
        '                    width: sidebar.width\n'
        '                    height: sidebar.currentItem?.height ?? 40\n'
        '                    y: sidebar.currentItem?.y ?? 0\n'
        '                    radius: Tokens.rounding.medium\n'
        '                    // Brighter while the arrow keys are in the category list.\n'
        '                    color: root.sidebarFocused ? Qt.alpha(Colours.palette.m3primary, 0.22) : Qt.alpha(Colours.palette.m3onSurface, 0.10)\n'
        '\n'
        '                    Behavior on color {\n'
        '                        CAnim {}\n'
        '                    }\n'
        '\n'
        '                    Behavior on y {\n'
        '                        Anim {\n'
        '                            type: Anim.DefaultSpatial\n'
        '                        }\n'
        '                    }\n'
        '                }\n',
    ),
    (
        'modules/launcher/items/CategoryButton.qml',
        '        color: Colours.palette.m3onSurface\n'
        '        opacity: catRoot.selected ? 0.10 : 0\n',
        '        color: Colours.palette.m3onSurface\n'
        '        // Launcher Customizer draws one sliding highlight for the list instead.\n'
        '        opacity: catRoot.selected && !LauncherCustomizer.pluginActive ? 0.10 : 0\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '                delegate: AppTile {\n'
        '                    browser: root\n'
        '                    selected: grid.currentIndex === index\n',
        '                delegate: AppTile {\n'
        '                    browser: root\n'
        '                    // Launcher Customizer: no app highlight while the keys are in the category list.\n'
        '                    selected: grid.currentIndex === index && !(LauncherCustomizer.pluginActive && root.sidebarFocused)\n',
    ),
    (
        'modules/launcher/items/AppContextMenu.qml',
        '                if (root.visibilities)\n'
        '                    root.visibilities.launcher = false;\n'
        '            }\n'
        '        }\n'
        '    ]\n',
        '                if (root.visibilities)\n'
        '                    root.visibilities.launcher = false;\n'
        '            }\n'
        '        },\n'
        '        // Launcher Customizer: uninstall the app with whatever installed it\n'
        '        // (in a terminal, which shows what runs and asks first).\n'
        '        Controls.MenuItem {\n'
        '            // Default layout (its grid and its search results); Simple and Compact stay stock.\n'
        '            visible: LauncherCustomizer.pluginActive && Config.launcher.browseLayout === LauncherBrowseLayout.Default\n'
        '            text: qsTr("Uninstall…")\n'
        '            icon: "delete"\n'
        '            onClicked: {\n'
        '                if (!root.app?.id)\n'
        '                    return;\n'
        '                LauncherCustomizer.requestUninstall(root.app.id);\n'
        '                if (root.visibilities)\n'
        '                    root.visibilities.launcher = false;\n'
        '            }\n'
        '        }\n'
        '    ]\n',
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


# Files older versions patched and this one no longer does: always cleaned
# (blocks stripped back to stock), so upgrading leaves nothing behind.
RETIRED_FILES = [
    "modules/launcher/Wrapper.qml",
    "modules/drawers/Panels.qml",
    "modules/drawers/Regions.qml",
    "modules/drawers/Interactions.qml",
]


def plan(shell: str):
    """Current, stock and patched text of every touched file."""
    files = sorted({op[0] for op in OPS} | {f for f in RETIRED_FILES if os.path.exists(os.path.join(shell, f))})
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
