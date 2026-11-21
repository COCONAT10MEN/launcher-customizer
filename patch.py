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
VERSION = "16"
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
        '            root.lcDrag = { id: tile.modelData.id, icon: tile.modelData.icon, cat: g.cat, ids: g.ids };\n'
        '    }\n'
        '\n'
        '    function lcDragMove(scenePos: point): void {\n'
        '        if (!root.lcDrag)\n'
        '            return;\n'
        '        root.lcDragPos = grid.mapFromItem(null, scenePos.x, scenePos.y);\n'
        '        const t = root.lcTileAt(scenePos);\n'
        '        if (t && t.id !== root.lcDrag.id && root.lcDrag.ids.includes(t.id)) {\n'
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
        '        root.lcDropId = "";\n'
        '    }\n',
    ),
    (
        'modules/launcher/AppBrowserGrid.qml',
        '        const nextApps = root.sortedApps(Categories.appsFor(root.currentCategory, all));\n',
        '        // Launcher Customizer: sections for KDE subcategories, and the custom order.\n'
        '        const lcArr = LauncherCustomizer.arrange(root.currentCategory, Categories.appsFor(root.currentCategory, all), all, sortSettings.sortMode, l => root.sortedApps(l));\n'
        '        const nextApps = lcArr.top;\n'
        '        root.lcSections = lcArr.sections;\n',
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
        '                                                selected: false\n'
        '                                                browser: root\n'
        '                                                lcCategory: lcSec.modelData.id\n'
        '                                                lcLabel: lcSec.look.label\n'
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
        '\n'
        '    MaterialIcon {\n'
        '        z: 6\n'
        '        anchors.top: parent.top\n'
        '        anchors.left: parent.left\n'
        '        anchors.topMargin: Tokens.spacing.extraSmall\n'
        '        anchors.leftMargin: Tokens.spacing.extraSmall\n'
        '        visible: LauncherCustomizer.pinnedIn(root.lcCat, root.modelData?.id ?? "")\n'
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
        '        enabled: !!root.browser?.lcCustom && !!root.modelData\n'
        '        acceptedButtons: Qt.LeftButton | Qt.RightButton\n'
        '        preventStealing: true\n'
        '        cursorShape: moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor\n'
        '\n'
        '        onPressed: mouse => {\n'
        '            // Leave the heart to the favourite button underneath.\n'
        '            const h = mapToItem(favIcon, mouse.x, mouse.y);\n'
        '            if (h.x > -6 && h.y > -6 && h.x < favIcon.width + 6 && h.y < favIcon.height + 6) {\n'
        '                mouse.accepted = false;\n'
        '                return;\n'
        '            }\n'
        '            start = Qt.point(mouse.x, mouse.y);\n'
        '            moved = false;\n'
        '        }\n'
        '        onPositionChanged: mouse => {\n'
        '            if (!pressed || !(mouse.buttons & Qt.LeftButton))\n'
        '                return;\n'
        '            if (!moved && Math.hypot(mouse.x - start.x, mouse.y - start.y) > 8) {\n'
        '                moved = true;\n'
        '                root.browser.lcDragBegin(root);\n'
        '            }\n'
        '            if (moved)\n'
        '                root.browser.lcDragMove(mapToItem(null, mouse.x, mouse.y));\n'
        '        }\n'
        '        onReleased: {\n'
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
        '                        visible: LauncherCustomizer.isNew(root.modelData?.id ?? "")\n'
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
        '            visible: LauncherCustomizer.pluginActive && LauncherCustomizer.contextCategory !== ""\n'
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
