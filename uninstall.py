#!/usr/bin/env python3
"""Uninstall the app behind a desktop entry, in a terminal, with confirmation.

Run by the launcher's "Uninstall…" item inside the user's terminal:

    uninstall.py DESKTOP_FILE APP_ID NAME

It works out what owns the app and uses that owner's own removal:
pacman (repo and AUR), Flatpak, Waydroid, portal web apps (Spider and other
apps using the dynamic launcher portal), Chrome/Chromium web apps, AppImages,
or a plain launcher file. Package managers ask their own question; for the
rest this script asks before touching anything. Nothing runs without a yes.
"""

import glob
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")

BOLD, DIM, RED, GREEN, RESET = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[0m"


def read_entry(path):
    out, group = {}, None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    group = line[1:-1]
                elif group == "Desktop Entry" and "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    out.setdefault(k.strip(), v.strip())
    except OSError:
        pass
    return out


def program_of(entry):
    exe = entry.get("Exec", "").split()
    while exe and "=" in exe[0] and not exe[0].startswith("/"):
        exe = exe[1:]  # env VAR=... prefixes
    if exe and exe[0] == "env":
        exe = [x for x in exe[1:] if "=" not in x]
    return exe[0].strip('"') if exe else ""


def pacman_owner(path):
    for p in (path, os.path.realpath(path)):
        try:
            r = subprocess.run(["pacman", "-Qqo", p], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().splitlines()[0]
    return None


def plan(path, app_id, name):
    """(what it is, steps) — steps are commands, or ("rm", [files]) for plain removals."""
    entry = read_entry(path)
    real = os.path.realpath(path)

    flatpak = entry.get("X-Flatpak", "")
    if flatpak and "/flatpak/exports/" in real:
        scope = "--user" if real.startswith(os.path.join(DATA_HOME, "flatpak")) else "--system"
        return f"the Flatpak {flatpak}", [["flatpak", "uninstall", scope, flatpak]], False

    if app_id.startswith("waydroid."):
        pkg = app_id[len("waydroid."):]
        return f"the Android app {pkg} (Waydroid)", [["waydroid", "app", "remove", pkg]], True

    # Web apps made through the dynamic launcher portal (Spider, GNOME Web…):
    # the entry and its icon live with the portal.
    portal_dir = os.path.join(DATA_HOME, "xdg-desktop-portal")
    if real.startswith(portal_dir + os.sep):
        files = [path, real]
        stem = os.path.splitext(os.path.basename(real))[0]
        files += glob.glob(os.path.join(portal_dir, "icons", "*", stem + ".*"))
        return "a web app", [("rm", files)], True

    m = re.fullmatch(r"(chrome|chromium|brave|msedge)-([a-p]{32})-(.+)", app_id)
    if m:
        browser = program_of(entry) or shutil.which("google-chrome-stable") or "google-chrome-stable"
        return (f"a web app installed by {os.path.basename(browser)}",
                [[browser, f"--uninstall-app-id={m.group(2)}", f"--profile-directory={m.group(3)}"]], True)

    owner = pacman_owner(path)
    if owner:
        return f"the package {owner}", [["sudo", "pacman", "-Rns", owner]], False

    program = program_of(entry)
    if program.lower().endswith(".appimage") or app_id.startswith("appimagekit_"):
        files = [path]
        if program.startswith("/") and os.path.exists(program):
            files.insert(0, program)
        if shutil.which("ail-cli") and program.startswith("/"):
            return "an AppImage", [["ail-cli", "unintegrate", program], ("rm", [f for f in files if f != path])], True
        return "an AppImage", [("rm", files)], True

    if os.path.realpath(path).startswith(os.path.join(DATA_HOME, "applications") + os.sep) or path.startswith(HOME):
        return "a launcher (its file only; the program it starts stays)", [("rm", [path])], True

    return None, [], True


def show(step):
    if isinstance(step, tuple):
        return "\n".join(f"  remove {f}" for f in step[1])
    return "  " + " ".join(step)


def run(step):
    if isinstance(step, tuple):
        ok = True
        for f in step[1]:
            try:
                if os.path.lexists(f):
                    os.unlink(f)
            except OSError as e:
                print(f"{RED}Could not remove {f}: {e}{RESET}")
                ok = False
        return ok
    try:
        return subprocess.run(step).returncode == 0
    except OSError as e:
        print(f"{RED}{e}{RESET}")
        return False


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip())
        return 2
    dry = "--dry" in argv
    argv = [a for a in argv if a != "--dry"]
    path, app_id = argv[1], argv[2]
    name = argv[3] if len(argv) > 3 else app_id
    print(f"{BOLD}Uninstall {name}{RESET}\n")
    what, steps, ask = plan(path, app_id, name)
    if not steps:
        print(f"Couldn't tell what installed {name}, so nothing was changed.\nRemove it the way you installed it.")
        return 1
    print(f"This is {what}. It will run:\n")
    for st in steps:
        print(DIM + show(st) + RESET)
    print()
    if dry:
        return 0
    if ask:
        try:
            answer = input(f"Uninstall {name}? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Nothing was changed.")
            return 0
    ok = all(run(st) for st in steps)
    print()
    if ok and os.path.lexists(path) and not any(isinstance(st, tuple) for st in steps):
        # The owner finished but its launcher is still here (a browser that
        # ignored the request, say): say so rather than claim success.
        print(f"The launcher for {name} is still there. Remove it from the app that made it.")
        ok = False
    print(f"{GREEN}{name} was uninstalled.{RESET}" if ok else f"{RED}Uninstalling {name} did not finish.{RESET}")
    return 0 if ok else 1


if __name__ == "__main__":
    code = main(sys.argv)
    if "--dry" in sys.argv:
        sys.exit(code)
    try:
        input(f"\n{DIM}Press Enter to close.{RESET}")
    except EOFError:
        pass
    sys.exit(code)
