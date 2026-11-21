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
REAL_DATA_PRIO = list(DATA_PRIO)
CONFIG_PRIO = [CONFIG_HOME] + CONFIG_DIRS
USER_APPS = os.path.join(DATA_HOME, "applications")
# ------------------------------------------------------------ staging
# The editor works on a private copy of the user's menu files (LC_STAGE) and
# only "commit" writes them back, so KDE and the launcher see nothing until
# the user saves. Without LC_STAGE, or before the first edit, the real files
# are used.

STAGE = os.environ.get("LC_STAGE") or ""
STAGE_ACTIVE = False
REAL_PATHS = {"menu": USER_MENU, "dirs": USER_DIRS, "apps": USER_APPS}


def stage_paths(base):
    return {
        "menu": os.path.join(base, "config", "menus", "applications-kmenuedit.menu"),
        "dirs": os.path.join(base, "data", "desktop-directories"),
        "apps": os.path.join(base, "data", "applications"),
    }


def file_map(paths):
    """{"menu" | "dirs/<name>" | "apps/<rel>": content hash} for one set of paths."""
    import hashlib

    def h(path):
        if os.path.islink(path):
            # By where it points, so a copy of a relative link compares equal.
            return "L:" + os.path.realpath(path)
        with open(path, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()

    out = {}
    if os.path.isfile(paths["menu"]):
        out["menu"] = h(paths["menu"])
    for key in ("dirs", "apps"):
        base = paths[key]
        for root_dir, _subdirs, files in os.walk(base):
            for name in files:
                full = os.path.join(root_dir, name)
                try:
                    out[key + "/" + os.path.relpath(full, base)] = h(full)
                except OSError:
                    pass
    return out


def key_path(paths, key):
    if key == "menu":
        return paths["menu"]
    kind, rel = key.split("/", 1)
    return os.path.join(paths[kind], rel)


def stage_begin():
    sp = stage_paths(STAGE)
    os.makedirs(os.path.dirname(sp["menu"]), exist_ok=True)
    if os.path.isfile(REAL_PATHS["menu"]):
        shutil.copyfile(REAL_PATHS["menu"], sp["menu"])
    for key in ("dirs", "apps"):
        if os.path.isdir(REAL_PATHS[key]):
            shutil.copytree(REAL_PATHS[key], sp[key], symlinks=True, dirs_exist_ok=True)
            # Relative links would point nowhere from the copy: make them absolute.
            for root_dir, _subdirs, files in os.walk(sp[key]):
                for name in files:
                    link = os.path.join(root_dir, name)
                    if os.path.islink(link) and not os.path.isabs(os.readlink(link)):
                        real = os.path.join(REAL_PATHS[key], os.path.relpath(link, sp[key]))
                        target = os.path.realpath(real)
                        os.unlink(link)
                        os.symlink(target, link)
        else:
            os.makedirs(sp[key], exist_ok=True)
    with open(os.path.join(STAGE, "manifest.json"), "w") as f:
        json.dump(file_map(REAL_PATHS), f)


def use_stage():
    global USER_MENU, USER_DIRS, USER_APPS, UNDO_DIR, DATA_PRIO, STAGE_ACTIVE
    sp = stage_paths(STAGE)
    USER_MENU, USER_DIRS, USER_APPS = sp["menu"], sp["dirs"], sp["apps"]
    UNDO_DIR = os.path.join(STAGE, "undo")
    DATA_PRIO = [os.path.join(STAGE, "data")] + DATA_DIRS
    STAGE_ACTIVE = True


def stage_changes():
    """Keys that differ between the working copy and the files it was taken from."""
    try:
        with open(os.path.join(STAGE, "manifest.json")) as f:
            before = json.load(f)
    except (OSError, ValueError):
        return []
    now = file_map(stage_paths(STAGE))
    return sorted(k for k in set(before) | set(now) if before.get(k) != now.get(k))


def cmd_commit():
    """Write the working copy's changes to the real files (undoable as one step)."""
    if not STAGE or not os.path.isdir(STAGE):
        return 0
    changes = stage_changes()
    sp = stage_paths(STAGE)
    if changes:
        snapshot([key_path(REAL_PATHS, k) for k in changes])
        for k in changes:
            src, dst = key_path(sp, k), key_path(REAL_PATHS, k)
            if os.path.lexists(src):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    os.unlink(dst)
                if os.path.islink(src):
                    os.symlink(os.readlink(src), dst)
                else:
                    shutil.copyfile(src, dst)
            elif os.path.lexists(dst):
                os.unlink(dst)
    shutil.rmtree(STAGE, ignore_errors=True)
    return len(changes)


def cmd_discard():
    if STAGE:
        shutil.rmtree(STAGE, ignore_errors=True)


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
    __slots__ = ("id", "path", "categories", "visible", "name", "entry", "base", "nodisplay", "showable")


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
                a.entry = e
                a.base = base
                a.nodisplay = truthy(e.get("NoDisplay"))
                only = [d for d in e.get("OnlyShowIn", "").split(";") if d]
                nots = [d for d in e.get("NotShowIn", "").split(";") if d]
                ok = e.get("Type", "Application") == "Application" and not truthy(e.get("Hidden"))
                if only and not any(d in only for d in DESKTOPS):
                    ok = False
                if any(d in nots for d in DESKTOPS):
                    ok = False
                tryexec = e.get("TryExec")
                if ok and tryexec and not (shutil.which(tryexec) or os.path.exists(tryexec)):
                    ok = False
                # "Show hidden entries": NoDisplay apps that would otherwise be listed.
                a.showable = ok
                a.visible = ok and not a.nodisplay
                found[did] = a
    _dir_cache[base] = found
    return found


# ------------------------------------------------------------------ menu tree

def locate_menu_file(name, current_dir=None):
    # The user's menu file is wherever USER_MENU points: the working copy
    # while editing, so the menu shows unsaved changes too.
    if os.path.basename(name) == os.path.basename(USER_MENU):
        if os.path.isabs(name) and os.path.realpath(name) != os.path.realpath(REAL_PATHS["menu"]):
            return name if os.path.exists(name) else None
        return USER_MENU if os.path.exists(USER_MENU) else None
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
        self.hidden_entries = set()

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
        hidden = {a for a in chosen if pool[a].showable and not pool[a].visible}
        chosen = {a for a in chosen if pool[a].visible}
        if second_pass:
            chosen -= allocated
            hidden -= allocated
        menu.entries = chosen
        menu.hidden_entries = hidden
        menu.pool = pool
        if not second_pass:
            # Hidden (NoDisplay) entries still count as placed, as in KDE.
            allocated |= chosen | hidden
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


def strip_id(a):
    return a[:-8] if a.endswith(".desktop") else a


def effective_layout(menu):
    """The menu's Layout, else the nearest DefaultLayout up the tree."""
    if menu.layout is not None:
        return menu.layout
    m = menu
    while m is not None:
        if m.default_layout is not None:
            return m.default_layout
        m = m.parent
    return None


def ordered_items(menu, pool):
    """Submenus, apps and separators of one menu in the order KDE shows them."""
    subs = [x for x in menu.subs.values() if not x.deleted and not x.name.startswith(".")]
    apps = sorted(menu.entries | menu.hidden_entries)
    sub_by = {x.name: x for x in subs}
    app_name = lambda aid: (pool.get(aid).name if pool.get(aid) else aid).lower()
    out, used_m, used_a = [], set(), set()
    lay = effective_layout(menu)
    explicit_m = set()
    explicit_a = set()
    if lay is not None:
        explicit_m = {(c.text or "").strip() for c in lay if c.tag == "Menuname"}
        explicit_a = {(c.text or "").strip() for c in lay if c.tag == "Filename"}

    def rest_menus():
        r = sorted([x for x in subs if x.name not in used_m and x.name not in explicit_m], key=lambda x: display_name(x).lower())
        used_m.update(x.name for x in r)
        return [{"kind": "menu", "path": x.path} for x in r]

    def rest_apps():
        r = sorted([x for x in apps if x not in used_a and x not in explicit_a], key=app_name)
        used_a.update(r)
        return [{"kind": "app", "id": strip_id(x)} for x in r]

    if lay is None:
        out = rest_menus() + rest_apps()
    else:
        for c in lay:
            t = (c.text or "").strip()
            if c.tag == "Menuname" and t in sub_by and t not in used_m:
                out.append({"kind": "menu", "path": sub_by[t].path})
                used_m.add(t)
            elif c.tag == "Filename" and t in apps and t not in used_a:
                out.append({"kind": "app", "id": strip_id(t)})
                used_a.add(t)
            elif c.tag == "Separator":
                out.append({"kind": "sep"})
            elif c.tag == "Merge":
                kind = c.get("type")
                if kind == "menus":
                    out += rest_menus()
                elif kind == "files":
                    out += rest_apps()
                elif kind == "all":
                    out += sorted(rest_menus() + rest_apps(), key=lambda it: (display_name(find_path(menu, it["path"])).lower() if it["kind"] == "menu" else app_name(it["id"] + ".desktop")))
        # Anything a hand-written Layout forgot still shows in the editor.
        out += rest_menus() + rest_apps()
    # Tidy separators: no leading, trailing or doubled ones.
    tidy = []
    for it in out:
        if it["kind"] == "sep" and (not tidy or tidy[-1]["kind"] == "sep"):
            continue
        tidy.append(it)
    while tidy and tidy[-1]["kind"] == "sep":
        tidy.pop()
    return tidy


def find_path(root_or_menu, path):
    m = root_or_menu
    while m.parent is not None:
        m = m.parent
    return find(m, path) or root_or_menu


def node(menu, system_paths, pool):
    subs = layout_order(menu, effective_layout(menu))
    children = [node(x, system_paths, pool) for x in subs if not x.deleted and not x.name.startswith(".")]
    all_apps = set(menu.entries)
    for c in children:
        all_apps |= set(c["allApps"])
    info = menu.dir_info
    sysinfo = menu.dir_system or {}
    icon = info.get("Icon", "")
    return {
        "path": menu.path,
        "name": display_name(menu),
        "comment": localized(info, "Comment"),
        "icon": icon,
        "systemIcon": sysinfo.get("Icon", icon if not menu.dir_user else ""),
        "systemName": localized(sysinfo, "Name") if sysinfo else (display_name(menu) if not menu.dir_user else ""),
        "caelestiaIcon": info.get("X-Caelestia-Icon", ""),
        "directory": menu.dir_file or "",
        "hasOverride": bool(menu.dir_user and sysinfo),
        "hidden": truthy(info.get("NoDisplay")),
        "custom": owner_is_user(menu, system_paths),
        "apps": sorted(strip_id(a) for a in menu.entries),
        "hiddenApps": sorted(strip_id(a) for a in menu.hidden_entries),
        "allApps": sorted(strip_id(a) if a.endswith(".desktop") else a for a in all_apps),
        "items": ordered_items(menu, pool),
        "children": children,
    }


def all_apps_pool():
    pool = {}
    for d in [os.path.join(x, "applications") for x in reversed(DATA_PRIO)]:
        pool.update(scan_app_dir(d))
    return pool


def read_shortcuts():
    """desktop id -> shortcut text, from KDE's global shortcut config."""
    out = {}
    path = os.path.join(CONFIG_HOME, "kglobalshortcutsrc")
    try:
        cur = None
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                m = re.match(r"^\[services\]\[(.+)\]$", line)
                if m:
                    cur = m.group(1)
                    continue
                if line.startswith("["):
                    cur = None
                    continue
                if cur and line.startswith("_launch="):
                    keys = [k for k in line.split("=", 1)[1].split("\t") if k and k != "none"]
                    if keys:
                        out[strip_id(cur)] = ", ".join(keys)
    except OSError:
        pass
    return out


def split_exec(cmd):
    """Exec -> (environment, program, arguments) the way KDE's Menu Editor shows it."""
    import shlex
    try:
        toks = shlex.split(cmd)
    except ValueError:
        return "", cmd, ""
    env = []
    if toks and toks[0] == "env":
        toks = toks[1:]
        while toks and "=" in toks[0] and not toks[0].startswith("-"):
            env.append(toks.pop(0))
    if not toks:
        return " ".join(env), "", ""
    return " ".join(env), toks[0], " ".join(shlex.quote(t) if (" " in t or not t) else t for t in toks[1:])


def app_info(app, shortcuts):
    e = app.entry or {}
    local = os.path.realpath(app.base) == os.path.realpath(USER_APPS)
    system = None
    if local:
        for d in DATA_DIRS:
            p2 = os.path.join(d, "applications", app.id)
            if os.path.exists(p2):
                system = p2
                break
    env, prog, args = split_exec(e.get("Exec", ""))
    only = [x for x in e.get("OnlyShowIn", "").split(";") if x]
    return {
        "id": strip_id(app.id),
        "file": app.path,
        "name": localized(e, "Name") or strip_id(app.id),
        "genericName": localized(e, "GenericName"),
        "comment": localized(e, "Comment"),
        "keywords": localized(e, "Keywords"),
        "icon": e.get("Icon", ""),
        "exec": e.get("Exec", ""),
        "env": env,
        "program": prog,
        "args": args,
        "path": e.get("Path", ""),
        "terminal": truthy(e.get("Terminal")),
        "terminalOptions": e.get("TerminalOptions", "") or e.get("X-KDE-TerminalOptions", ""),
        "otherUser": truthy(e.get("X-KDE-SubstituteUID")),
        "username": e.get("X-KDE-Username", ""),
        "startupNotify": e.get("StartupNotify", "true").strip().lower() != "false",
        "gpu": truthy(e.get("PrefersNonDefaultGPU")) or truthy(e.get("X-KDE-RunOnDiscreteGpu")),
        "noDisplay": app.nodisplay,
        "onlyPlasma": only == ["KDE"],
        "visible": app.visible,
        "showable": app.showable,
        "local": local,
        "hasSystem": system is not None,
        "created": truthy(e.get("X-Caelestia-Created")),
        "shortcut": shortcuts.get(strip_id(app.id), ""),
        # An edited copy keeps the original's date: editing is not an update.
        "installed": 0,
        "_timePath": system if (local and system) else app.path,
    }


APP_STATE = os.path.join(CACHE_HOME, "caelestia", "launcher-customizer", "apps.json")
PACMAN_LOCAL = "/var/lib/pacman/local"
PACMAN_STATE = os.path.join(CACHE_HOME, "caelestia", "launcher-customizer", "pacman.json")


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except OSError:
        pass


def pacman_dates():
    """desktop file -> when its package was installed or last upgraded (pacman)."""
    try:
        mtime = os.stat(PACMAN_LOCAL).st_mtime
    except OSError:
        return {}
    cached = _read_json(PACMAN_STATE)
    if cached and cached.get("mtime") == mtime:
        return cached.get("files", {})
    out = {}
    for pkg in os.listdir(PACMAN_LOCAL):
        d = os.path.join(PACMAN_LOCAL, pkg)
        try:
            with open(os.path.join(d, "files"), encoding="utf-8", errors="replace") as f:
                files = [l for l in f.read().splitlines() if l.endswith(".desktop") and "/applications/" in l]
            if not files:
                continue
            with open(os.path.join(d, "desc"), encoding="utf-8", errors="replace") as f:
                m = re.search(r"%INSTALLDATE%\n(\d+)", f.read())
        except OSError:
            continue
        t = int(m.group(1)) if m else 0
        for rel in files:
            out["/" + rel] = t
    _write_json(PACMAN_STATE, {"mtime": mtime, "files": out})
    return out


def installed_times(paths):
    """app id -> when it was installed or last updated (seconds since the epoch).

    Packages report their real install or upgrade date and Flatpaks their
    deploy date. Anything else counts as updated only when its desktop file's
    content changes: Waydroid and browser web apps rewrite theirs on every
    start without anything new in them."""
    import hashlib
    pac = pacman_dates()
    state = _read_json(APP_STATE) or {}
    now = int(time.time())
    out, changed = {}, False
    for aid, path in paths.items():
        real = os.path.realpath(path)
        if real in pac or path in pac:
            out[aid] = pac.get(real) or pac.get(path)
            continue
        if "/flatpak/" in real and "/export/" in real:
            try:
                out[aid] = int(os.stat(real.split("/export/")[0]).st_mtime)
                continue
            except OSError:
                pass
        try:
            with open(path, "rb") as f:
                h = hashlib.sha1(f.read()).hexdigest()
            seed = int(os.stat(path).st_mtime)
        except OSError:
            out[aid] = 0
            continue
        rec = state.get(aid)
        t = seed if rec is None else (rec["t"] if rec.get("h") == h else now)
        if rec != {"h": h, "t": t}:
            state[aid] = {"h": h, "t": t}
            changed = True
        out[aid] = t
    if changed and not STAGE_ACTIVE:
        _write_json(APP_STATE, state)
    return out


def dump():
    root, root_file = load()
    system_paths = system_menu_paths()
    pool = all_apps_pool()
    hidden = root.subs.get(".hidden")
    hidden_ids = sorted(strip_id(a) for a in (hidden.entries if hidden else set()))
    order = layout_order(root, effective_layout(root))
    cats = [node(x, system_paths, pool) for x in order if not x.deleted and not x.name.startswith(".")]
    shortcuts = read_shortcuts()
    apps = {strip_id(aid): app_info(a, shortcuts) for aid, a in pool.items() if (a.entry or {}).get("Type", "Application") == "Application" and a.showable}
    times = installed_times({k: v.pop("_timePath") for k, v in apps.items()})
    for k, v in apps.items():
        v["installed"] = times.get(k, 0)
    return {
        "ok": True,
        "rootFile": root_file,
        "userFile": USER_MENU,
        "categories": cats,
        "rootItems": ordered_items(root, pool),
        "apps": apps,
        "hiddenApps": hidden_ids,
        "manualApps": manual_apps(),
        "canUndo": bool(undo_entries()),
        "staged": STAGE_ACTIVE,
        "stageDirty": bool(stage_changes()) if STAGE_ACTIVE else False,
        "stamp": stamp(),
    }


def stamp():
    """Changes whenever anything that shapes the menu changes."""
    parts = []
    for p in [USER_MENU, os.path.join(CONFIG_HOME, "kglobalshortcutsrc")] + glob.glob(os.path.join(USER_DIRS, "*.directory")) + glob.glob(os.path.join(CONFIG_HOME, "menus", "applications-merged", "*.menu")):
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
    if os.environ.get("LAUNCHER_CUSTOMIZER_NO_SYCOCA") or STAGE_ACTIVE:
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
    if "comment" in kv:
        keys["Comment"] = kv["comment"] or None
        for loc in LOCALES:
            keys[f"Comment[{loc}]"] = kv["comment"] or None
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


def cmd_new(name, icon, parent=""):
    root, _ = load()
    base = name.strip() or "New category"
    holder = find(root, parent) if parent else root
    if holder is None:
        raise RuntimeError(f"no such category: {parent}")
    leaf, n = base.replace("/", "-"), 2
    while leaf in holder.subs:
        leaf = f"{base} {n}".replace("/", "-")
        n += 1
    path = f"{parent}/{leaf}" if parent else leaf
    dirname = OWN_PREFIX + slug(path.replace("/", "-")) + ".directory"
    tree = load_user_tree()
    um = user_menu(tree, path)
    if um.find("Directory") is None:
        ET.SubElement(um, "Directory").text = dirname
    # A parent with its own order lists it last among its categories, not
    # wherever that order merges in the ones it does not name.
    holder_el = user_menu(tree, parent, create=False) if parent else tree
    lay = holder_el.find("Layout") if holder_el is not None else None
    if lay is not None:
        kids = list(lay)
        names = [i for i, c in enumerate(kids) if c.tag == "Menuname"]
        at = names[-1] + 1 if names else next((i + 1 for i, c in enumerate(kids) if c.tag == "Merge" and c.get("type") == "menus"), len(kids))
        el = ET.Element("Menuname")
        el.text = leaf
        lay.insert(at, el)
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


# ------------------------------------------------------------- app entries

APP_KEYS = {
    "name": "Name", "genericName": "GenericName", "comment": "Comment", "keywords": "Keywords",
    "icon": "Icon", "path": "Path", "terminalOptions": "TerminalOptions", "username": "X-KDE-Username",
}
LOCALIZED = {"Name", "GenericName", "Comment", "Keywords"}


def app_paths(app_id):
    aid = fid(app_id)
    pool = all_apps_pool()
    return aid, pool.get(aid), os.path.join(USER_APPS, aid)


def cmd_app_set(app_id, kv):
    """Edit an app entry like KDE's Menu Editor: a local copy that overrides the system one."""
    import shlex
    aid, app, target = app_paths(app_id)
    if app is None and not os.path.exists(target):
        raise RuntimeError(f"no such app: {app_id}")
    if not os.path.exists(target):
        os.makedirs(USER_APPS, exist_ok=True)
        shutil.copyfile(app.path, target)
        write_keyfile(target, {"X-Caelestia-Edited": "true"})
    keys = {}
    for k, v in kv.items():
        if k in APP_KEYS:
            key = APP_KEYS[k]
            keys[key] = v or None
            if key in LOCALIZED:
                for loc in LOCALES:
                    keys[f"{key}[{loc}]"] = v or None
        elif k in ("terminal", "otherUser", "startupNotify", "gpu", "noDisplay"):
            on = v in ("1", "true")
            key = {"terminal": "Terminal", "otherUser": "X-KDE-SubstituteUID", "startupNotify": "StartupNotify",
                   "gpu": "PrefersNonDefaultGPU", "noDisplay": "NoDisplay"}[k]
            keys[key] = "true" if on else ("false" if k == "startupNotify" else None)
        elif k == "onlyPlasma":
            keys["OnlyShowIn"] = "KDE;" if v in ("1", "true") else None
    if any(k in kv for k in ("env", "program", "args")):
        cur = read_keyfile(target)
        env0, prog0, args0 = split_exec(cur.get("Exec", ""))
        env = kv.get("env", env0).strip()
        prog = kv.get("program", prog0).strip()
        args = kv.get("args", args0).strip()
        parts = []
        if env:
            parts += ["env"] + env.split()
        if prog:
            parts.append(shlex.quote(prog) if " " in prog else prog)
        cmd = " ".join(parts) + (" " + args if args else "")
        keys["Exec"] = cmd.strip() or None
    write_keyfile(target, keys)


def cmd_app_reset(app_id):
    """Back to the system's version of the entry (drops the local copy)."""
    aid, _app, target = app_paths(app_id)
    has_system = any(os.path.exists(os.path.join(d, "applications", aid)) for d in DATA_DIRS)
    if os.path.exists(target) and has_system:
        os.unlink(target)


def cmd_app_new(name, menu_path):
    base = "caelestia-" + slug(name or "launcher")
    aid, n = base + ".desktop", 2
    while os.path.exists(os.path.join(USER_APPS, aid)) or any(os.path.exists(os.path.join(d, "applications", aid)) for d in DATA_DIRS):
        aid = f"{base}-{n}.desktop"
        n += 1
    os.makedirs(USER_APPS, exist_ok=True)
    write_keyfile(os.path.join(USER_APPS, aid), {"Type": "Application", "Name": name or "New launcher", "Exec": "", "Icon": "application-x-executable", "X-Caelestia-Created": "true"})
    if menu_path:
        tree = load_user_tree()
        add_filename_rule(user_menu(tree, menu_path), "Include", aid)
        save_user_tree(tree)
    return strip_id(aid)


def cmd_app_delete(app_id):
    """Delete a launcher the user made (local only) and every rule naming it."""
    aid, _app, target = app_paths(app_id)
    if any(os.path.exists(os.path.join(d, "applications", aid)) for d in DATA_DIRS):
        raise RuntimeError("only launchers you made can be deleted; hide or remove this one instead")
    if os.path.exists(target):
        os.unlink(target)
    cmd_reset_app(app_id)


# ------------------------------------------------------------ layout, sort

def cmd_layout(path, tokens):
    """Explicit order of one menu: tokens are menu:<Name>, app:<id> or sep."""
    tree = load_user_tree()
    um = user_menu(tree, path) if path else tree
    for e in um.findall("Layout"):
        um.remove(e)
    lay = ET.SubElement(um, "Layout")
    for t in tokens:
        if t == "sep":
            ET.SubElement(lay, "Separator")
        elif t.startswith("menu:"):
            ET.SubElement(lay, "Menuname").text = t[5:]
        elif t.startswith("app:"):
            ET.SubElement(lay, "Filename").text = fid(t[4:])
    ET.SubElement(lay, "Merge", {"type": "menus"})
    ET.SubElement(lay, "Merge", {"type": "files"})
    save_user_tree(tree)


def cmd_sort(path, by, recursive):
    root, _ = load()
    pool = all_apps_pool()
    start = find(root, path) if path else root
    if start is None:
        raise RuntimeError(f"no such category: {path}")
    targets = []

    def walk(m):
        targets.append(m)
        if recursive:
            for x in m.subs.values():
                if not x.deleted and not x.name.startswith("."):
                    walk(x)
    walk(start)

    def app_key(aid):
        a = pool.get(aid)
        e = (a.entry if a else None) or {}
        if by == "description":
            return (localized(e, "GenericName") or localized(e, "Comment") or localized(e, "Name")).lower()
        return (localized(e, "Name") or aid).lower()

    def menu_key(m):
        if by == "description":
            return (localized(m.dir_info, "Comment") or display_name(m)).lower()
        return display_name(m).lower()

    tree = load_user_tree()
    for m in targets:
        subs = sorted([x for x in m.subs.values() if not x.deleted and not x.name.startswith(".")], key=menu_key)
        apps = sorted(m.entries | m.hidden_entries, key=app_key)
        um = user_menu(tree, m.path) if m.path else tree
        for e in um.findall("Layout"):
            um.remove(e)
        lay = ET.SubElement(um, "Layout")
        for x in subs:
            ET.SubElement(lay, "Menuname").text = x.name
        for a in apps:
            ET.SubElement(lay, "Filename").text = a
        ET.SubElement(lay, "Merge", {"type": "menus"})
        ET.SubElement(lay, "Merge", {"type": "files"})
    save_user_tree(tree)



def cmd_menu_move(path, new_parent):
    """Move a submenu under another menu (KDE Menu Editor's cut + paste of a submenu)."""
    leaf = path.split("/")[-1]
    new = f"{new_parent}/{leaf}" if new_parent else leaf
    if new == path or new.startswith(path + "/"):
        raise RuntimeError("cannot move a category into itself")
    root, _ = load()
    if find(root, new) is not None:
        raise RuntimeError(f"{new} already exists")
    tree = load_user_tree()
    mv = ET.SubElement(tree, "Move")
    ET.SubElement(mv, "Old").text = path
    ET.SubElement(mv, "New").text = new
    save_user_tree(tree)
    return new

# ------------------------------------------------------------ restore, keys

def restore_targets():
    files = [USER_MENU] if os.path.exists(USER_MENU) else []
    for p in glob.glob(os.path.join(USER_DIRS, "*.directory")):
        name = os.path.basename(p)
        overrides = any(os.path.exists(os.path.join(d, "desktop-directories", name)) for d in DATA_DIRS)
        if overrides or name.startswith(OWN_PREFIX):
            files.append(p)
    for p in glob.glob(os.path.join(USER_APPS, "*.desktop")):
        e = read_keyfile(p)
        if truthy(e.get("X-Caelestia-Edited")) or truthy(e.get("X-Caelestia-Created")):
            files.append(p)
    return files


def cmd_restore():
    for p in restore_targets():
        if os.path.exists(p):
            os.unlink(p)


def cmd_shortcut(app_id, key, label):
    """Set (or clear, key 0) an app's global shortcut through KDE's shortcut service."""
    comp = fid(app_id)
    action = ["4", comp, "_launch", label or strip_id(app_id), label or strip_id(app_id)]
    base = ["busctl", "--user", "call", "org.kde.kglobalaccel", "/kglobalaccel", "org.kde.KGlobalAccel"]
    subprocess.run(base + ["doRegister", "as"] + action, check=True, capture_output=True, timeout=5)
    keys = ["1", str(int(key))] if int(key) else ["0"]
    subprocess.run(base + ["setForeignShortcut", "asai"] + action + keys, check=True, capture_output=True, timeout=5)



# ------------------------------------------------------- backup and share

import tarfile
import io
import datetime

LAYOUT_FORMAT = "caelestia-launcher-layout"
PLUGIN_CONFIG = os.path.join(CONFIG_HOME, "caelestia", "launcher-customizer.json")
ICON_DIR = os.path.join(DATA_HOME, "caelestia", "category-icons")
QT_MODS = {"meta": 0x10000000, "ctrl": 0x04000000, "alt": 0x08000000, "shift": 0x02000000}
QT_KEYS = {"space": 0x20, "return": 0x01000004, "enter": 0x01000005, "tab": 0x01000001, "backspace": 0x01000003,
           "del": 0x01000007, "delete": 0x01000007, "ins": 0x01000006, "home": 0x01000010, "end": 0x01000011,
           "pgup": 0x01000016, "pgdown": 0x01000017, "left": 0x01000012, "up": 0x01000013, "right": 0x01000014,
           "down": 0x01000015, "print": 0x01000009, "esc": 0x01000000}


def shortcut_to_int(text):
    parts = text.split("+")
    key, mods = parts[-1], parts[:-1]
    if text.endswith("++"):
        key, mods = "+", parts[:-2]
    v = 0
    for m in mods:
        v |= QT_MODS.get(m.strip().lower(), 0)
    k = key.strip()
    if k.lower() in QT_KEYS:
        v |= QT_KEYS[k.lower()]
    elif re.fullmatch(r"[Ff]([1-9]|[12][0-9]|3[0-5])", k):
        v |= 0x01000030 + int(k[1:]) - 1
    elif len(k) == 1:
        v |= ord(k.upper())
    else:
        return 0
    return v


def layout_files():
    """Every file that makes up the user's launcher layout."""
    files = []
    if os.path.exists(USER_MENU):
        files.append(USER_MENU)
    files += sorted(glob.glob(os.path.join(USER_DIRS, "*.directory")))
    for p in sorted(glob.glob(os.path.join(USER_APPS, "*.desktop"))):
        e = read_keyfile(p)
        if truthy(e.get("X-Caelestia-Edited")) or truthy(e.get("X-Caelestia-Created")):
            files.append(p)
    files += sorted(glob.glob(os.path.join(ICON_DIR, "*")))
    return files


def tokenise(path):
    for tok, base in (("{config}", CONFIG_HOME), ("{data}", DATA_HOME)):
        if path.startswith(base + os.sep):
            return tok + path[len(base):]
    return None


def detokenise(path):
    return path.replace("{config}", CONFIG_HOME, 1).replace("{data}", DATA_HOME, 1)


def cmd_export(out, hidden_json="[]"):
    shortcuts = {}
    sc = read_shortcuts()
    apps = all_apps_pool()
    for aid in apps:
        sid = strip_id(aid)
        if sc.get(sid):
            shortcuts[aid] = sc[sid].split(", ")[0]
    plugin = {}
    try:
        with open(PLUGIN_CONFIG) as fh:
            plugin = json.load(fh)
        plugin.pop("seen", None)
        plugin.pop("seenSince", None)
    except (OSError, ValueError):
        pass
    manifest = {"format": LAYOUT_FORMAT, "version": 1, "created": datetime.datetime.now().isoformat(timespec="seconds"),
                "home": HOME, "files": [], "shortcuts": shortcuts, "plugin": plugin,
                "hiddenApps": [x for x in json.loads(hidden_json or "[]") if isinstance(x, str)]}
    with tarfile.open(out, "w:gz") as tar:
        for i, f in enumerate(layout_files()):
            tok = tokenise(f)
            if not tok:
                continue
            arc = f"files/{i}"
            tar.add(f, arcname=arc)
            manifest["files"].append({"arc": arc, "target": tok})
        data = json.dumps(manifest, indent=2).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return {"ok": True, "path": out, "files": len(manifest["files"]), "shortcuts": len(shortcuts)}


def read_layout(path):
    tar = tarfile.open(path, "r:gz")
    manifest = json.load(tar.extractfile("manifest.json"))
    if manifest.get("format") != LAYOUT_FORMAT:
        raise RuntimeError("not a Launcher Customizer layout file")
    return tar, manifest


def import_targets(manifest):
    out = []
    for f in manifest.get("files", []):
        t = f.get("target", "")
        if not (t.startswith("{config}/") or t.startswith("{data}/")) or ".." in t.split("/"):
            raise RuntimeError(f"unsafe path in layout: {t}")
        out.append(detokenise(t))
    return out


def cmd_import(path):
    tar, manifest = read_layout(path)
    targets = import_targets(manifest)
    cmd_restore()
    old_home = manifest.get("home", "")
    for f, target in zip(manifest.get("files", []), targets):
        data = tar.extractfile(f["arc"]).read()
        if old_home and old_home != HOME:
            try:
                data = data.decode("utf-8").replace(old_home, HOME).encode("utf-8")
            except UnicodeDecodeError:
                pass
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as fh:
            fh.write(data)
    applied = 0
    for aid, text in manifest.get("shortcuts", {}).items():
        key = shortcut_to_int(text)
        if key:
            try:
                cmd_shortcut(aid, key, strip_id(aid))
                applied += 1
            except Exception:
                pass
    return {"plugin": manifest.get("plugin", {}), "hiddenApps": manifest.get("hiddenApps", []),
            "shortcuts": applied, "files": len(targets)}

def cmd_icons():
    theme = "hicolor"
    for d in CONFIG_PRIO:
        v = read_keyfile(os.path.join(d, "kdeglobals"), "Icons").get("Theme")
        if v:
            theme = v
            break
    themes, queue, seen = [], [theme, "breeze", "hicolor"], set()
    bases = [os.path.join(HOME, ".icons")] + [os.path.join(d, "icons") for d in REAL_DATA_PRIO]
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
    # KDE recolours this to the active scheme; anything else shows the base
    # colour, so start from the scheme's own text colour.
    fg = "#232629"
    rgb = read_keyfile(os.path.join(CONFIG_HOME, "kdeglobals"), "Colors:Window").get("ForegroundNormal", "")
    if re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?", rgb.strip()):
        fg = rgb.strip()[:7]
    else:
        try:
            r, g, b = [int(x) for x in rgb.split(",")[:3]]
            fg = f"#{r:02x}{g:02x}{b:02x}"
        except ValueError:
            pass
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
           f'<style id="current-color-scheme">.ColorScheme-Text{{color:{fg};}}</style>'
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
        if cmd == "commit":
            n = cmd_commit()
            rebuild_kde_cache()
            _dir_cache.clear()
            out = dump()
            out["command"] = cmd
            out["created"] = n
            print(json.dumps(out))
            return 0
        if cmd == "discard":
            cmd_discard()
            print(json.dumps(dict(dump(), command=cmd)))
            return 0
        if STAGE:
            reading = cmd in ("dump", "stamp", "icons", "material-svg", "export", "restore-preview", "undo")
            if not os.path.isdir(STAGE) and not reading:
                stage_begin()
            if os.path.isdir(STAGE):
                use_stage()
            elif cmd == "undo":
                print(json.dumps(dict(dump(), command=cmd)))
                return 0
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
        if cmd == "export":
            print(json.dumps(cmd_export(args[0], args[1] if len(args) > 1 else "[]")))
            return 0
        if cmd == "restore-preview":
            print(json.dumps({"ok": True, "files": restore_targets()}))
            return 0
        result = None
        if cmd == "undo":
            undo()
        elif cmd == "shortcut":
            cmd_shortcut(args[0], args[1], args[2] if len(args) > 2 else "")
        else:
            extra = []
            if cmd in ("app-set", "app-reset", "app-delete") and args:
                extra.append(os.path.join(USER_APPS, fid(args[0])))
            if cmd == "restore-system":
                extra += restore_targets()
            if cmd == "import":
                _tar, _man = read_layout(args[0])
                extra += restore_targets() + import_targets(_man)
            snapshot([USER_MENU] + all_user_dir_files() + extra)
            kv = lambda rest: dict(a.split("=", 1) for a in rest if "=" in a)
            if cmd == "move":
                cmd_move(args[0], args[1], args[2:])
            elif cmd == "add":
                cmd_add(args[0], args[1])
            elif cmd == "remove":
                cmd_remove(args[0], args[1])
            elif cmd == "reset-app":
                cmd_reset_app(args[0])
            elif cmd == "set":
                cmd_set(args[0], kv(args[1:]))
            elif cmd == "reset-dir":
                cmd_reset_dir(args[0])
            elif cmd == "new":
                result = cmd_new(args[0], args[1] if len(args) > 1 else "", args[2] if len(args) > 2 else "")
                snapshot_add(os.path.join(USER_DIRS, OWN_PREFIX + slug(result.replace("/", "-")) + ".directory"))
            elif cmd == "delete":
                cmd_delete(args[0])
            elif cmd == "order":
                cmd_order(args)
            elif cmd == "layout":
                cmd_layout(args[0], args[1:])
            elif cmd == "sort":
                cmd_sort(args[0], args[1] if len(args) > 1 else "name", len(args) > 2 and args[2] == "all")
            elif cmd == "app-set":
                cmd_app_set(args[0], kv(args[1:]))
            elif cmd == "app-reset":
                cmd_app_reset(args[0])
            elif cmd == "app-new":
                result = cmd_app_new(args[0], args[1] if len(args) > 1 else "")
                snapshot_add(os.path.join(USER_APPS, fid(result)))
            elif cmd == "app-delete":
                cmd_app_delete(args[0])
            elif cmd == "restore-system":
                cmd_restore()
            elif cmd == "import":
                result = cmd_import(args[0])
            elif cmd == "menu-move":
                result = cmd_menu_move(args[0], args[1] if len(args) > 1 else "")
            else:
                raise RuntimeError(f"unknown command {cmd}")
        rebuild_kde_cache()
        _dir_cache.clear()
        out = dump()
        out["command"] = cmd
        if result is not None:
            out["created"] = result
        print(json.dumps(out))
        return 0
    except Exception as e:  # report, never traceback into the shell log
        print(json.dumps({"ok": False, "command": cmd, "error": f"{type(e).__name__}: {e}"}))
        return 1


def snapshot_add(path):
    """Record a file the command just created, so undo removes it."""
    entries = undo_entries()
    if not entries:
        return
    d = os.path.join(UNDO_DIR, entries[-1])
    mpath = os.path.join(d, "manifest.json")
    with open(mpath) as f:
        manifest = json.load(f)
    manifest.append({"path": path, "saved": None})
    with open(mpath, "w") as f:
        json.dump(manifest, f)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
