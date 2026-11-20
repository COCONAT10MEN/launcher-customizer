#!/usr/bin/env python3
"""KDE application menu bridge for the Launcher Customizer plugin.

Reads the application menu the way Plasma builds it (freedesktop.org menu
spec: the system menu, applications-merged/, KDE Menu Editor's
applications-kmenuedit.menu, .directory files) and edits it the way KDE's Menu
Editor does, so Kickoff, the KDE Menu Editor and the Caelestia launcher always
show the same categories.

Every command prints one JSON object on stdout.

    dump                                 the menu as Caelestia should show it
    move    APP TO [FROM...]             move APP into TO (out of FROM, or of every menu it is in)
    add     APP TO                       also list APP in TO
    remove  APP FROM                     take APP out of FROM
    reset-app APP                        drop every manual placement of APP
    set     PATH [name=..] [icon=..] [hidden=0|1] [caelestia-icon=..]
    reset-dir PATH                       drop the local name/icon/hidden override
    new     NAME [ICON]                  create a top-level category
    delete  PATH                         delete a category (custom: removed, built-in: marked Deleted)
    order   PATH...                      order of the top-level categories
    undo                                 revert the last change made through this script
    icons                                icon names of the current icon theme (apps, categories, places)
    material-svg NAME OUT                write a Material Symbols glyph as a KDE-recolourable SVG
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
CACHE_HOME = os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache")
DATA_DIRS = [d for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]
CONFIG_DIRS = [d for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":") if d]
MENU_PREFIX = os.environ.get("XDG_MENU_PREFIX", "plasma-")
DESKTOPS = [d for d in (os.environ.get("XDG_CURRENT_DESKTOP") or "KDE").split(":") if d]

USER_MENU = os.path.join(CONFIG_HOME, "menus", "applications-kmenuedit.menu")
USER_DIRS = os.path.join(DATA_HOME, "desktop-directories")
UNDO_DIR = os.path.join(CACHE_HOME, "caelestia", "launcher-customizer", "undo")
UNDO_KEEP = 40
OWN_PREFIX = "caelestia-"

# Highest priority first.
DATA_PRIO = [DATA_HOME] + DATA_DIRS
CONFIG_PRIO = [CONFIG_HOME] + CONFIG_DIRS


def locale_keys():
    raw = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANG") or ""
    raw = raw.split(".")[0].split("@")[0]
    keys = []
    if raw and raw not in ("C", "POSIX"):
        keys.append(raw)
        if "_" in raw:
            keys.append(raw.split("_")[0])
    return keys


LOCALES = locale_keys()


# ------------------------------------------------------------------ key files

def read_keyfile(path, group="Desktop Entry"):
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            cur = None
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    cur = line[1:-1]
                    continue
                if cur != group or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out.setdefault(k.strip(), v.strip())
    except OSError:
        pass
    return out


def localized(entry, key):
    for loc in LOCALES:
        v = entry.get(f"{key}[{loc}]")
        if v:
            return v
    return entry.get(key, "")


def truthy(v):
    return str(v).strip().lower() == "true"


def write_keyfile(path, keys, group="Desktop Entry"):
    """Rewrite one group of a key file, keeping every other line and group."""
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    out, in_group, seen_group, written = [], False, False, set()
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if in_group:
                out += [f"{k}={v}" for k, v in keys.items() if k not in written and v is not None]
                written.update(keys)
            in_group = s[1:-1] == group
            seen_group = seen_group or in_group
            out.append(line)
            continue
        if in_group and "=" in s and not s.startswith("#"):
            k = s.split("=", 1)[0].strip()
            if k in keys:
                if k not in written and keys[k] is not None:
                    out.append(f"{k}={keys[k]}")
                written.add(k)
                continue
        out.append(line)
    if in_group:
        out += [f"{k}={v}" for k, v in keys.items() if k not in written and v is not None]
        written.update(keys)
    if not seen_group:
        out = [f"[{group}]"] + [f"{k}={v}" for k, v in keys.items() if v is not None] + ([""] + out if out else [])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out).rstrip("\n") + "\n")
    os.replace(tmp, path)


# -------------------------------------------------------------- desktop files

class App:
    __slots__ = ("id", "path", "categories", "visible", "name")


_dir_cache = {}


def scan_app_dir(base):
    """desktop-file id -> App for one applications directory."""
    if base in _dir_cache:
        return _dir_cache[base]
    found = {}
    if os.path.isdir(base):
        for root, _dirs, files in os.walk(base, followlinks=True):
            for fn in files:
                if not fn.endswith(".desktop"):
                    continue
                path = os.path.join(root, fn)
                rel = os.path.relpath(path, base)
                did = rel.replace(os.sep, "-")
                e = read_keyfile(path)
                a = App()
                a.id = did
                a.path = path
                a.name = localized(e, "Name")
                a.categories = set(c for c in e.get("Categories", "").split(";") if c)
                only = [d for d in e.get("OnlyShowIn", "").split(";") if d]
                nots = [d for d in e.get("NotShowIn", "").split(";") if d]
                ok = e.get("Type", "Application") == "Application" and not truthy(e.get("NoDisplay")) and not truthy(e.get("Hidden"))
                if only and not any(d in only for d in DESKTOPS):
                    ok = False
                if any(d in nots for d in DESKTOPS):
                    ok = False
                tryexec = e.get("TryExec")
                if ok and tryexec and not (shutil.which(tryexec) or os.path.exists(tryexec)):
                    ok = False
                a.visible = ok
                found[did] = a
    _dir_cache[base] = found
    return found


# ------------------------------------------------------------------ menu tree

def locate_menu_file(name, current_dir=None):
    if os.path.isabs(name):
        return name if os.path.exists(name) else None
    # KDE looks relative names up in the menus/ config dirs, user first.
    for d in CONFIG_PRIO:
        p = os.path.join(d, "menus", name)
        if os.path.exists(p):
            return p
    if current_dir:
        p = os.path.join(current_dir, name)
        if os.path.exists(p):
            return p
    return None


def parse_xml(path):
    try:
        return ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return None


def resolve_merges(elem, basedir, seen, depth=0):
    """Replace MergeFile/MergeDir/DefaultMergeDirs with the merged menus' contents."""
    if depth > 20:
        return
    i = 0
    while i < len(elem):
        child = elem[i]
        tag = child.tag
        merged_roots = []
        if tag == "MergeFile":
            name = (child.text or "").strip()
            path = None
            if child.get("type") == "parent":
                # The same file one priority level down.
                pass
            elif name:
                path = locate_menu_file(name, basedir)
            if path and path not in seen:
                r = parse_xml(path)
                if r is not None:
                    merged_roots.append((r, os.path.dirname(path), path))
        elif tag in ("MergeDir", "DefaultMergeDirs"):
            dirs = []
            if tag == "MergeDir":
                d = (child.text or "").strip()
                dirs = [d if os.path.isabs(d) else os.path.join(basedir, d)]
            else:
                # Lowest priority first, so the user's files are merged last and win.
                dirs = [os.path.join(c, "menus", "applications-merged") for c in reversed(CONFIG_PRIO)]
            for d in dirs:
                for p in sorted(glob.glob(os.path.join(d, "*.menu"))):
                    if p not in seen:
                        r = parse_xml(p)
                        if r is not None:
                            merged_roots.append((r, os.path.dirname(p), p))
        if tag in ("MergeFile", "MergeDir", "DefaultMergeDirs"):
            elem.remove(child)
            insert_at = i
            for r, rdir, rpath in merged_roots:
                seen2 = seen | {rpath}
                resolve_merges(r, rdir, seen2, depth + 1)
                for sub in list(r):
                    if sub.tag == "Name":
                        continue
                    sub.set("_basedir", rdir)
                    sub.set("_source", rpath)
                    elem.insert(insert_at, sub)
                    insert_at += 1
            continue
        if tag == "Menu":
            child.set("_basedir", child.get("_basedir", basedir))
            resolve_merges(child, child.get("_basedir"), seen, depth + 1)
        i += 1


class Menu:
    def __init__(self, name, parent=None):
        self.name = name
        self.parent = parent
        self.directories = []
        self.app_dirs = []        # own, lowest priority first
        self.dir_dirs = []
        self.rules = []           # ("include"|"exclude", element)
        self.only_unallocated = False
        self.deleted = False
        self.layout = None
        self.default_layout = None
        self.subs = {}            # name -> Menu, insertion ordered
        self.moves = []
        self.sources = set()      # menu files that define this menu
        self.entries = set()

    @property
    def path(self):
        parts, m = [], self
        while m.parent is not None:
            parts.append(m.name)
            m = m.parent
        return "/".join(reversed(parts))


def build(menu, elem, basedir):
    src = elem.get("_source", "")
    if src:
        menu.sources.add(src)
    for child in elem:
        tag = child.tag
        bdir = child.get("_basedir", basedir)
        text = (child.text or "").strip()
        if tag == "Directory" and text:
            menu.directories.append(text)
        elif tag == "AppDir" and text:
            menu.app_dirs.append(text if os.path.isabs(text) else os.path.join(bdir, text))
        elif tag == "DefaultAppDirs":
            menu.app_dirs += [os.path.join(d, "applications") for d in reversed(DATA_PRIO)]
        elif tag == "DirectoryDir" and text:
            menu.dir_dirs.append(text if os.path.isabs(text) else os.path.join(bdir, text))
        elif tag == "DefaultDirectoryDirs":
            menu.dir_dirs += [os.path.join(d, "desktop-directories") for d in reversed(DATA_PRIO)]
        elif tag in ("Include", "Exclude"):
            menu.rules.append((tag.lower(), child))
        elif tag == "OnlyUnallocated":
            menu.only_unallocated = True
        elif tag == "NotOnlyUnallocated":
            menu.only_unallocated = False
        elif tag == "Deleted":
            menu.deleted = True
        elif tag == "NotDeleted":
            menu.deleted = False
        elif tag == "Layout":
            menu.layout = child
        elif tag == "DefaultLayout":
            menu.default_layout = child
        elif tag == "Move":
            old = child.findtext("Old")
            new = child.findtext("New")
            if old and new:
                menu.moves.append((old.strip(), new.strip()))
        elif tag == "Menu":
            name = (child.findtext("Name") or "").strip()
            if not name:
                continue
            sub = menu.subs.get(name)
            if sub is None:
                sub = Menu(name, menu)
                menu.subs[name] = sub
            if child.get("_source"):
                sub.sources.add(child.get("_source"))
            build(sub, child, bdir)


def merge_into(dst, src):
    dst.directories += src.directories
    dst.app_dirs += src.app_dirs
    dst.dir_dirs += src.dir_dirs
    dst.rules += src.rules
    dst.only_unallocated = src.only_unallocated or dst.only_unallocated
    dst.deleted = src.deleted
    dst.layout = src.layout or dst.layout
    dst.default_layout = src.default_layout or dst.default_layout
    dst.sources |= src.sources
    for name, s in src.subs.items():
        if name in dst.subs:
            merge_into(dst.subs[name], s)
        else:
            s.parent = dst
            dst.subs[name] = s


def apply_moves(menu):
    for old, new in menu.moves:
        src = find(menu, old)
        if src is None or src.parent is None:
            continue
        del src.parent.subs[src.name]
        parts = new.split("/")
        parent = menu
        for p in parts[:-1]:
            parent = parent.subs.setdefault(p, Menu(p, parent))
        dest = parent.subs.get(parts[-1])
        if dest is None:
            src.name, src.parent = parts[-1], parent
            parent.subs[parts[-1]] = src
        else:
            merge_into(dest, src)
    for s in list(menu.subs.values()):
        apply_moves(s)


def find(root, path):
    m = root
    for part in [p for p in path.split("/") if p]:
        m = m.subs.get(part)
        if m is None:
            return None
    return m


def matches(rule_elem, app):
    tag = rule_elem.tag
    if tag == "Filename":
        return (rule_elem.text or "").strip() == app.id
    if tag == "Category":
        return (rule_elem.text or "").strip() in app.categories
    if tag == "All":
        return True
    if tag == "And":
        return all(matches(c, app) for c in rule_elem)
    if tag == "Or":
        return any(matches(c, app) for c in rule_elem)
    if tag == "Not":
        return not any(matches(c, app) for c in rule_elem)
    return False


def pool_for(menu, inherited):
    dirs = inherited + menu.app_dirs
    pool = {}
    for d in dirs:  # lowest priority first, later overrides
        pool.update(scan_app_dir(d))
    return pool, dirs


def evaluate(menu, inherited_dirs, allocated, second_pass):
    pool, dirs = pool_for(menu, inherited_dirs)
    if menu.only_unallocated == second_pass:
        chosen = set()
        for kind, rule in menu.rules:
            hits = {aid for aid, app in pool.items() if any(matches(c, app) for c in rule)}
            if kind == "include":
                chosen |= hits
            else:
                chosen -= hits
        chosen = {a for a in chosen if pool[a].visible}
        if second_pass:
            chosen -= allocated
        menu.entries = chosen
        menu.pool = pool
        if not second_pass:
            allocated |= chosen
    for s in menu.subs.values():
        evaluate(s, dirs, allocated, second_pass)


def directory_info(menu, inherited_dirdirs):
    dirdirs = inherited_dirdirs + menu.dir_dirs
    menu.dirdirs = dirdirs
    info, chosen_file, user_override, system = {}, None, False, {}
    for name in reversed(menu.directories):
        for d in reversed(dirdirs):  # highest priority first
            p = os.path.join(d, name)
            if os.path.exists(p):
                chosen_file = name
                info = read_keyfile(p)
                user_override = os.path.realpath(d) == os.path.realpath(USER_DIRS)
                if user_override:
                    for d2 in reversed(dirdirs):
                        p2 = os.path.join(d2, name)
                        if os.path.realpath(d2) != os.path.realpath(USER_DIRS) and os.path.exists(p2):
                            system = read_keyfile(p2)
                            break
                break
        if chosen_file:
            break
    if not chosen_file and menu.directories:
        chosen_file = menu.directories[-1]
    menu.dir_file = chosen_file
    menu.dir_info = info
    menu.dir_user = user_override
    menu.dir_system = system
    for s in menu.subs.values():
        directory_info(s, dirdirs)


def layout_order(menu, layout_elem):
    """Submenu order from a Layout (or alphabetical where it merges)."""
    subs = [s for s in menu.subs.values()]
    by_name = {s.name: s for s in subs}
    if layout_elem is None:
        return sorted(subs, key=lambda s: display_name(s).lower())
    explicit = [ (c.text or "").strip() for c in layout_elem if c.tag == "Menuname"]
    out, used = [], set()
    for c in layout_elem:
        if c.tag == "Menuname":
            n = (c.text or "").strip()
            if n in by_name and n not in used:
                out.append(by_name[n])
                used.add(n)
        elif c.tag == "Merge" and c.get("type") in ("menus", "all"):
            rest = sorted([s for s in subs if s.name not in explicit and s.name not in used], key=lambda s: display_name(s).lower())
            out += rest
            used |= {s.name for s in rest}
    out += [s for s in subs if s.name not in used]
    return out


def display_name(menu):
    return localized(menu.dir_info, "Name") or menu.name


def load():
    root_file = None
    for d in CONFIG_PRIO:
        p = os.path.join(d, "menus", f"{MENU_PREFIX}applications.menu")
        if os.path.exists(p):
            root_file = p
            break
    if root_file is None:
        root_file = locate_menu_file("applications.menu")
    if root_file is None:
        raise RuntimeError("no applications.menu found")
    tree = parse_xml(root_file)
    resolve_merges(tree, os.path.dirname(root_file), {root_file})
    root = Menu((tree.findtext("Name") or "Applications").strip())
    build(root, tree, os.path.dirname(root_file))
    apply_moves(root)
    allocated = set()
    evaluate(root, [], allocated, False)
    evaluate(root, [], allocated, True)
    directory_info(root, [])
    return root, root_file


# ------------------------------------------------------------------- dumping

def user_menu_paths():
    """Paths of menus that exist only because of the user's own menu file."""
    r = parse_xml(USER_MENU)
    out = set()

    def walk(e, prefix):
        for m in e.findall("Menu"):
            n = (m.findtext("Name") or "").strip()
            if n:
                p = f"{prefix}/{n}" if prefix else n
                out.add(p)
                walk(m, p)
    if r is not None:
        walk(r, "")
    return out


def system_menu_paths():
    """Menus defined without the user's file (system menu + merged dirs)."""
    saved = USER_MENU
    paths = set()
    try:
        tree = parse_xml(locate_menu_file(f"{MENU_PREFIX}applications.menu") or "")
        if tree is None:
            return paths

        def strip_user(e, basedir, seen):
            resolve_merges_skip(e, basedir, seen)

        strip_user(tree, "", set())

        def walk(e, prefix):
            for m in e.findall("Menu"):
                n = (m.findtext("Name") or "").strip()
                if n:
                    p = f"{prefix}/{n}" if prefix else n
                    paths.add(p)
                    walk(m, p)
        walk(tree, "")
    finally:
        pass
    return paths


def resolve_merges_skip(elem, basedir, seen):
    """resolve_merges, minus the user's kmenuedit file."""
    for child in list(elem):
        if child.tag == "MergeFile" and os.path.basename((child.text or "").strip()) == os.path.basename(USER_MENU):
            elem.remove(child)
    resolve_merges(elem, basedir, seen)


def owner_is_user(menu, system_paths):
    return menu.path not in system_paths


def node(menu, system_paths, hidden_ids):
    subs = layout_order(menu, menu.layout if menu.layout is not None else menu.default_layout)
    children = [node(s, system_paths, hidden_ids) for s in subs if not s.deleted and not s.name.startswith(".")]
    all_apps = set(menu.entries)
    for c in children:
        all_apps |= set(c["allApps"])
    info = menu.dir_info
    sysinfo = menu.dir_system or {}
    icon = info.get("Icon", "")
    return {
        "path": menu.path,
        "name": display_name(menu),
        "icon": icon,
        "systemIcon": sysinfo.get("Icon", icon if not menu.dir_user else ""),
        "systemName": localized(sysinfo, "Name") if sysinfo else (display_name(menu) if not menu.dir_user else ""),
        "caelestiaIcon": info.get("X-Caelestia-Icon", ""),
        "directory": menu.dir_file or "",
        "hasOverride": bool(menu.dir_user and sysinfo),
        "hidden": truthy(info.get("NoDisplay")),
        "custom": owner_is_user(menu, system_paths),
        "apps": sorted(a[:-8] if a.endswith(".desktop") else a for a in menu.entries),
        "allApps": sorted(a[:-8] if a.endswith(".desktop") else a for a in all_apps),
        "children": children,
    }


def dump():
    root, root_file = load()
    system_paths = system_menu_paths()
    hidden = root.subs.get(".hidden")
    hidden_ids = sorted(a[:-8] for a in (hidden.entries if hidden else set()) if a.endswith(".desktop"))
    order = layout_order(root, root.layout if root.layout is not None else root.default_layout)
    cats = [node(s, system_paths, hidden_ids) for s in order if not s.deleted and not s.name.startswith(".")]
    manual = manual_apps()
    return {
        "ok": True,
        "rootFile": root_file,
        "userFile": USER_MENU,
        "categories": cats,
        "hiddenApps": hidden_ids,
        "manualApps": manual,
        "canUndo": bool(undo_entries()),
        "stamp": stamp(),
    }


def stamp():
    """Changes whenever anything that shapes the menu changes."""
    parts = []
    for p in [USER_MENU] + glob.glob(os.path.join(USER_DIRS, "*.directory")) + glob.glob(os.path.join(CONFIG_HOME, "menus", "applications-merged", "*.menu")):
        try:
            parts.append(f"{p}:{os.stat(p).st_mtime_ns}")
        except OSError:
            pass
    for d in [os.path.join(x, "applications") for x in DATA_PRIO]:
        try:
            parts.append(f"{d}:{os.stat(d).st_mtime_ns}")
        except OSError:
            pass
    return str(hash("|".join(parts)) & 0xFFFFFFFF)


# ------------------------------------------------------------------- editing

def load_user_tree():
    r = parse_xml(USER_MENU)
    if r is None:
        r = ET.Element("Menu")
    return r


def prune(e):
    """Drop <Menu> stubs left with nothing but a <Name>."""
    for m in list(e.findall("Menu")):
        prune(m)
        if all(c.tag == "Name" for c in m):
            e.remove(m)


def save_user_tree(root):
    prune(root)
    for e in root.iter():
        e.tail = None
        if len(e):
            e.text = None
    indent(root)
    os.makedirs(os.path.dirname(USER_MENU), exist_ok=True)
    body = ET.tostring(root, encoding="unicode").replace(" />", "/>")
    tmp = USER_MENU + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("<!DOCTYPE Menu PUBLIC '-//freedesktop//DTD Menu 1.0//EN' 'http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd'>\n")
        f.write(body + "\n")
    os.replace(tmp, USER_MENU)


def indent(e, level=0):
    pad = "\n" + " " * level
    if len(e):
        if not (e.text or "").strip():
            e.text = pad + " "
        for c in e:
            indent(c, level + 1)
        if not (e[-1].tail or "").strip():
            e[-1].tail = pad
    if level and not (e.tail or "").strip():
        e.tail = pad


def user_menu(root, path, create=True):
    m = root
    for part in [p for p in path.split("/") if p]:
        found = None
        for c in m.findall("Menu"):
            if (c.findtext("Name") or "").strip() == part:
                found = c
                break
        if found is None:
            if not create:
                return None
            found = ET.SubElement(m, "Menu")
            ET.SubElement(found, "Name").text = part
        m = found
    return m


def fid(app):
    return app if app.endswith(".desktop") else app + ".desktop"


def drop_filename_rules(menu_elem, kind, app):
    for rule in list(menu_elem.findall(kind)):
        for f in list(rule.findall("Filename")):
            if (f.text or "").strip() == app:
                rule.remove(f)
        if len(rule) == 0:
            menu_elem.remove(rule)


def add_filename_rule(menu_elem, kind, app):
    other = "Exclude" if kind == "Include" else "Include"
    drop_filename_rules(menu_elem, other, app)
    for rule in menu_elem.findall(kind):
        for f in rule.findall("Filename"):
            if (f.text or "").strip() == app:
                return
    rule = ET.SubElement(menu_elem, kind)
    ET.SubElement(rule, "Filename").text = app


def memberships(root_menu, app):
    out = []

    def walk(m):
        if app in m.entries and m.parent is not None:
            out.append(m.path)
        for s in m.subs.values():
            walk(s)
    walk(root_menu)
    return out


def manual_apps():
    r = parse_xml(USER_MENU)
    out = set()
    if r is not None:
        # Only Include/Exclude rules place apps; Layout entries just order them.
        for rule in list(r.iter("Include")) + list(r.iter("Exclude")):
            for f in rule.iter("Filename"):
                t = (f.text or "").strip()
                if t.endswith(".desktop"):
                    out.add(t[:-8])
    return sorted(out)


def directory_path_for(menu_path, create_name=None):
    """User-writable .directory path for a menu, creating the reference if needed."""
    root, _ = load()
    m = find(root, menu_path)
    if m is None:
        raise RuntimeError(f"no such category: {menu_path}")
    name = m.dir_file
    if not name:
        name = OWN_PREFIX + slug(create_name or m.name) + ".directory"
        tree = load_user_tree()
        um = user_menu(tree, menu_path)
        ET.SubElement(um, "Directory").text = name
        save_user_tree(tree)
    target = os.path.join(USER_DIRS, name)
    if not os.path.exists(target):
        # Start from the file currently in effect so nothing is lost.
        for d in reversed(m.dirdirs):
            p = os.path.join(d, name)
            if os.path.exists(p):
                os.makedirs(USER_DIRS, exist_ok=True)
                shutil.copyfile(p, target)
                break
        else:
            write_keyfile(target, {"Type": "Directory", "Name": m.name})
    return target, m


def slug(s):
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    return s or "category"


# --------------------------------------------------------------------- undo

def undo_entries():
    try:
        return sorted(os.listdir(UNDO_DIR))
    except OSError:
        return []


def snapshot(paths):
    stamp_dir = os.path.join(UNDO_DIR, f"{time.time_ns()}")
    os.makedirs(stamp_dir, exist_ok=True)
    manifest = []
    for i, p in enumerate(paths):
        saved = None
        if os.path.exists(p):
            saved = f"{i}.bak"
            shutil.copyfile(p, os.path.join(stamp_dir, saved))
        manifest.append({"path": p, "saved": saved})
    with open(os.path.join(stamp_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f)
    for old in undo_entries()[:-UNDO_KEEP]:
        shutil.rmtree(os.path.join(UNDO_DIR, old), ignore_errors=True)


def undo():
    entries = undo_entries()
    if not entries:
        raise RuntimeError("nothing to undo")
    d = os.path.join(UNDO_DIR, entries[-1])
    with open(os.path.join(d, "manifest.json")) as f:
        manifest = json.load(f)
    for item in manifest:
        if item["saved"]:
            os.makedirs(os.path.dirname(item["path"]), exist_ok=True)
            shutil.copyfile(os.path.join(d, item["saved"]), item["path"])
        elif os.path.exists(item["path"]):
            os.unlink(item["path"])
    shutil.rmtree(d, ignore_errors=True)


def all_user_dir_files():
    return glob.glob(os.path.join(USER_DIRS, "*.directory"))


def rebuild_kde_cache():
    if os.environ.get("LAUNCHER_CUSTOMIZER_NO_SYCOCA"):
        return
    exe = shutil.which("kbuildsycoca6") or shutil.which("kbuildsycoca5")
    if exe:
        subprocess.Popen([exe], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ------------------------------------------------------------------ commands

def cmd_move(app, to, froms):
    app = fid(app)
    root, _ = load()
    if not froms:
        froms = [p for p in memberships(root, app) if p != to]
    tree = load_user_tree()
    for p in froms:
        if p and p != to:
            add_filename_rule(user_menu(tree, p), "Exclude", app)
    hidden = user_menu(tree, ".hidden", create=False)
    if hidden is not None:
        drop_filename_rules(hidden, "Include", app)
    add_filename_rule(user_menu(tree, to), "Include", app)
    save_user_tree(tree)


def cmd_add(app, to):
    tree = load_user_tree()
    add_filename_rule(user_menu(tree, to), "Include", fid(app))
    save_user_tree(tree)


def cmd_remove(app, frm):
    tree = load_user_tree()
    add_filename_rule(user_menu(tree, frm), "Exclude", fid(app))
    save_user_tree(tree)


def cmd_reset_app(app):
    app = fid(app)
    tree = load_user_tree()
    for m in tree.iter("Menu"):
        drop_filename_rules(m, "Include", app)
        drop_filename_rules(m, "Exclude", app)
    save_user_tree(tree)


def cmd_set(path, kv):
    target, _m = directory_path_for(path)
    keys = {}
    if "name" in kv:
        keys["Name"] = kv["name"]
        for loc in LOCALES:
            keys[f"Name[{loc}]"] = kv["name"]
    if "icon" in kv:
        keys["Icon"] = kv["icon"] or None
    if "hidden" in kv:
        keys["NoDisplay"] = "true" if kv["hidden"] in ("1", "true") else None
    if "caelestia-icon" in kv:
        keys["X-Caelestia-Icon"] = kv["caelestia-icon"] or None
    keys.setdefault("Type", "Directory")
    write_keyfile(target, keys)


def cmd_reset_dir(path):
    root, _ = load()
    m = find(root, path)
    if m is None or not m.dir_file:
        return
    p = os.path.join(USER_DIRS, m.dir_file)
    if os.path.exists(p) and m.dir_system:
        os.unlink(p)
    elif os.path.exists(p):
        # No system file behind it: keep the name, drop the tweaks.
        write_keyfile(p, {"NoDisplay": None, "X-Caelestia-Icon": None})


def cmd_new(name, icon):
    root, _ = load()
    base = name.strip() or "New category"
    path, n = base.replace("/", "-"), 2
    while path in root.subs:
        path = f"{base} {n}".replace("/", "-")
        n += 1
    dirname = OWN_PREFIX + slug(path) + ".directory"
    tree = load_user_tree()
    um = user_menu(tree, path)
    if um.find("Directory") is None:
        ET.SubElement(um, "Directory").text = dirname
    save_user_tree(tree)
    write_keyfile(os.path.join(USER_DIRS, dirname), {"Type": "Directory", "Name": base, "Icon": icon or "folder"})
    return path


def cmd_delete(path):
    system_paths = system_menu_paths()
    tree = load_user_tree()
    if path not in system_paths:
        parts = path.split("/")
        parent = user_menu(tree, "/".join(parts[:-1]), create=False) if len(parts) > 1 else tree
        um = user_menu(tree, path, create=False)
        if parent is not None and um is not None:
            dfile = (um.findtext("Directory") or "").strip()
            # Apps that were moved in here go back to where they belong by default.
            moved_in = {(f.text or "").strip() for rule in um.iter("Include") for f in rule.iter("Filename")}
            parent.remove(um)
            for m in tree.iter("Menu"):
                for app in moved_in:
                    drop_filename_rules(m, "Exclude", app)
            if dfile.startswith(OWN_PREFIX):
                p = os.path.join(USER_DIRS, dfile)
                if os.path.exists(p):
                    os.unlink(p)
    else:
        um = user_menu(tree, path)
        for e in um.findall("NotDeleted"):
            um.remove(e)
        if um.find("Deleted") is None:
            ET.SubElement(um, "Deleted")
    save_user_tree(tree)


def cmd_order(paths):
    tree = load_user_tree()
    for e in tree.findall("Layout"):
        tree.remove(e)
    lay = ET.SubElement(tree, "Layout")
    for p in paths:
        if "/" not in p:
            ET.SubElement(lay, "Menuname").text = p
    ET.SubElement(lay, "Merge", {"type": "menus"})
    ET.SubElement(lay, "Merge", {"type": "files"})
    save_user_tree(tree)


def cmd_icons():
    theme = "hicolor"
    for d in CONFIG_PRIO:
        v = read_keyfile(os.path.join(d, "kdeglobals"), "Icons").get("Theme")
        if v:
            theme = v
            break
    themes, queue, seen = [], [theme, "breeze", "hicolor"], set()
    bases = [os.path.join(HOME, ".icons")] + [os.path.join(d, "icons") for d in DATA_PRIO]
    while queue:
        t = queue.pop(0)
        if t in seen:
            continue
        seen.add(t)
        for b in bases:
            idx = os.path.join(b, t, "index.theme")
            if os.path.exists(idx):
                themes.append(os.path.join(b, t))
                inh = read_keyfile(idx, "Icon Theme").get("Inherits", "")
                queue += [x for x in inh.split(",") if x]
    names = {}
    wanted = re.compile(r"/(apps|categories|places|devices|mimetypes|status|actions|emblems)(/|$)")
    for tdir in themes:
        for root, _dirs, files in os.walk(tdir):
            rel = root[len(tdir):] + "/"
            if not wanted.search(rel):
                continue
            ctx = wanted.search(rel).group(1)
            for f in files:
                if f.endswith((".svg", ".png", ".svgz")):
                    n = f.rsplit(".", 1)[0]
                    names.setdefault(n, ctx)
    order = {"categories": 0, "apps": 1, "places": 2, "devices": 3, "mimetypes": 4, "status": 5, "actions": 6, "emblems": 7}
    items = sorted(names.items(), key=lambda kv: (order.get(kv[1], 9), kv[0]))
    return {"ok": True, "theme": theme, "icons": [{"name": n, "context": c} for n, c in items]}


def cmd_material_svg(name, out):
    try:
        from fontTools.ttLib import TTFont
        from fontTools.varLib.instancer import instantiateVariableFont
        from fontTools.pens.svgPathPen import SVGPathPen
        from fontTools.pens.transformPen import TransformPen
    except ImportError:
        return {"ok": False, "error": "python fonttools is not installed"}
    font_path = None
    try:
        font_path = subprocess.run(["fc-match", "-f", "%{file}", "Material Symbols Rounded"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if not font_path or not os.path.exists(font_path):
        return {"ok": False, "error": "Material Symbols Rounded font not found"}
    f = TTFont(font_path)
    if "fvar" in f:
        axes = {a.axisTag for a in f["fvar"].axes}
        loc = {k: v for k, v in {"FILL": 1, "GRAD": 0, "wght": 400, "opsz": 24}.items() if k in axes}
        f = instantiateVariableFont(f, loc)
    gs = f.getGlyphSet()
    if name not in gs and "_" + name in gs:  # glyph names cannot start with a digit
        name = "_" + name
    if name not in gs:
        return {"ok": False, "error": f"unknown icon {name}"}
    upm = f["head"].unitsPerEm
    pen = SVGPathPen(gs)
    # Font units, y up -> 24px viewBox, y down.
    gs[name].draw(TransformPen(pen, (24 / upm, 0, 0, -24 / upm, 0, 24)))
    d = pen.getCommands()
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
           '<style id="current-color-scheme">.ColorScheme-Text{color:#232629;}</style>'
           f'<path class="ColorScheme-Text" fill="currentColor" d="{d}"/></svg>\n')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        fh.write(svg)
    return {"ok": True, "path": out}


def main(argv):
    if len(argv) < 2:
        print(json.dumps({"ok": False, "error": "usage: " + __doc__.strip().splitlines()[0]}))
        return 2
    cmd, args = argv[1], argv[2:]
    try:
        if cmd == "dump":
            print(json.dumps(dump()))
            return 0
        if cmd == "stamp":
            print(json.dumps({"ok": True, "stamp": stamp()}))
            return 0
        if cmd == "icons":
            print(json.dumps(cmd_icons()))
            return 0
        if cmd == "material-svg":
            print(json.dumps(cmd_material_svg(args[0], args[1])))
            return 0
        if cmd == "undo":
            undo()
        else:
            snapshot([USER_MENU] + all_user_dir_files() + ([os.path.join(USER_DIRS, OWN_PREFIX + slug(args[0]) + ".directory")] if cmd == "new" and args else []))
            result = None
            if cmd == "move":
                cmd_move(args[0], args[1], args[2:])
            elif cmd == "add":
                cmd_add(args[0], args[1])
            elif cmd == "remove":
                cmd_remove(args[0], args[1])
            elif cmd == "reset-app":
                cmd_reset_app(args[0])
            elif cmd == "set":
                cmd_set(args[0], dict(a.split("=", 1) for a in args[1:] if "=" in a))
            elif cmd == "reset-dir":
                cmd_reset_dir(args[0])
            elif cmd == "new":
                result = cmd_new(args[0], args[1] if len(args) > 1 else "")
            elif cmd == "delete":
                cmd_delete(args[0])
            elif cmd == "order":
                cmd_order(args)
            else:
                raise RuntimeError(f"unknown command {cmd}")
        rebuild_kde_cache()
        _dir_cache.clear()
        out = dump()
        out["command"] = cmd
        if cmd == "new":
            out["created"] = result
        print(json.dumps(out))
        return 0
    except Exception as e:  # report, never traceback into the shell log
        print(json.dumps({"ok": False, "command": cmd, "error": f"{type(e).__name__}: {e}"}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
