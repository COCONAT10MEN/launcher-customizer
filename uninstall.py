#!/usr/bin/env python3
"""Uninstall the app behind a desktop entry. No terminal: Caelestia's
uninstall dialog shows the plan, asks, and then runs it.

    uninstall.py plan DESKTOP_FILE APP_ID [NAME] -> JSON {ok, what, summary, details, steps, needsAuth, keeps}
    uninstall.py run  DESKTOP_FILE APP_ID        -> JSON {ok, error, output}

It works out what owns the app and uses that owner's own removal:
pacman (repo and AUR; root through KDE's password prompt via pkexec),
Flatpak, Waydroid, portal web apps (Spider and other apps using the dynamic
launcher portal), Chrome/Chromium web apps, AppImages, or a plain launcher
file. "run" only ever does what "plan" showed.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")



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
    import shlex
    try:
        exe = shlex.split(re.sub(r"%[fFuUdDnNickvm]", "", entry.get("Exec", "")))
    except ValueError:
        exe = entry.get("Exec", "").split()
    if exe and exe[0] == "env":
        exe = exe[1:]
    while exe and "=" in exe[0] and not exe[0].startswith("/"):
        exe = exe[1:]  # VAR=value prefixes
    # A script run by an interpreter: the script is the program.
    if exe and os.path.basename(exe[0]) in ("bash", "sh", "zsh", "fish", "python", "python3", "node") and len(exe) > 1:
        rest = [x for x in exe[1:] if not x.startswith("-")]
        if rest:
            return rest[0]
    return exe[0] if exe else ""


def pacman_owner(path):
    for p in (path, os.path.realpath(path)):
        try:
            r = subprocess.run(["pacman", "-Qqo", p], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip().splitlines()[0]
    return None


def human_size(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return ""


def pacman_preview(pkg):
    """(packages it would remove, error) without needing root."""
    r = subprocess.run(["pacman", "-Rsp", "--print-format", "%n", pkg], capture_output=True, text=True, timeout=20)
    if r.returncode != 0 or "error" in r.stderr.lower():
        needed = re.findall(r"required by (\S+)", r.stderr)
        return None, needed
    return [l for l in r.stdout.split() if l], []


def pacman_info(pkg):
    r = subprocess.run(["pacman", "-Qi", pkg], capture_output=True, text=True, timeout=10, env=dict(os.environ, LC_ALL="C"))
    info = {}
    for line in r.stdout.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip()] = v.strip()
    return info


def flatpak_name(app):
    r = subprocess.run(["flatpak", "info", app], capture_output=True, text=True, timeout=10)
    first = (r.stdout.strip().splitlines() or [""])[0]
    return first.split(" - ")[0].strip() or app.split(".")[-1].capitalize()


def made_by(flatpak):
    """Names of launchers that run through this flatpak (web apps it made)."""
    names = []
    for d in (os.path.join(DATA_HOME, "applications"), os.path.join(DATA_HOME, "xdg-desktop-portal", "applications")):
        for f in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            e = read_entry(f)
            if e.get("X-Flatpak") == flatpak and os.path.basename(f) != flatpak + ".desktop" and f"'{flatpak}'" in e.get("Exec", "") + "'":
                n = e.get("Name", "")
                if n and n not in names:
                    names.append(n)
    return names


def plan(path, app_id, name):
    """(info, steps). info: what, summary, details, keeps, error; steps are
    commands, or ("rm", [files]) for plain removals."""
    entry = read_entry(path)
    real = os.path.realpath(path)
    nice = lambda f: f.replace(HOME, "~", 1)

    flatpak = entry.get("X-Flatpak", "")
    # The flatpak's own app (not a web app another flatpak made for it):
    # its entry lives in a flatpak exports folder.
    if flatpak and ("/flatpak/" in path or "/flatpak/" in real) and not real.startswith(os.path.join(DATA_HOME, "xdg-desktop-portal")):
        user = path.startswith(os.path.join(DATA_HOME, "flatpak")) or real.startswith(os.path.join(DATA_HOME, "flatpak"))
        data = os.path.join(HOME, ".var", "app", flatpak)
        details = ["Removes the app" + (" (installed just for you)." if user else " (installed for everyone on this PC).")]
        if os.path.isdir(data):
            details.append(f"Its settings and files in {nice(data)} are kept, so reinstalling brings them back.")
        made = made_by(flatpak)
        if made:
            details.append(f"The {len(made)} app{'s' if len(made) != 1 else ''} it made will stop working: " + ", ".join(made[:5]) + ("…" if len(made) > 5 else "."))
        details.append("Shared runtimes that other Flatpak apps use are kept.")
        return ({"what": "a Flatpak app", "summary": f"{name} is a Flatpak app ({flatpak}).", "details": details},
                [["flatpak", "uninstall", "-y", "--noninteractive", "--user" if user else "--system", flatpak]])

    if app_id.startswith("waydroid."):
        pkg = app_id[len("waydroid."):]
        return ({"what": "an Android app", "summary": f"{name} is an Android app running in Waydroid ({pkg}).",
                 "details": ["Removes the app from Waydroid's Android, together with its data inside Android.",
                             "Waydroid itself and your other Android apps stay.",
                             "Waydroid has to be running for this."]},
                [["waydroid", "app", "remove", pkg]])

    # Web apps made through the dynamic launcher portal (Spider, GNOME Web…).
    portal_dir = os.path.join(DATA_HOME, "xdg-desktop-portal")
    if real.startswith(portal_dir + os.sep):
        files = [path, real]
        stem = os.path.splitext(os.path.basename(real))[0]
        files += glob.glob(os.path.join(portal_dir, "icons", "*", stem + ".*"))
        maker = flatpak_name(flatpak) if flatpak else "another app"
        return ({"what": "a web app", "summary": f"{name} is a web app made with {maker}.",
                 "details": ["Removes its launcher and icon, so it is gone from your app menu.",
                             f"{maker} and the website itself stay; you can make the web app again from {maker}."]},
                [("rm", files)])

    m = re.fullmatch(r"(chrome|chromium|brave|msedge)-([a-p]{32})-(.+)", app_id)
    if m:
        browser = program_of(entry) or shutil.which("google-chrome-stable") or "google-chrome-stable"
        bname = {"chrome": "Google Chrome", "chromium": "Chromium", "brave": "Brave", "msedge": "Microsoft Edge"}[m.group(1)]
        return ({"what": "a web app", "summary": f"{name} is a web app installed through {bname}.",
                 "details": [f"Removes the web app from {bname}, along with its launcher.",
                             f"{bname} itself stays, and so does what you saved in it (logins, history)."]},
                [[browser, f"--uninstall-app-id={m.group(2)}", f"--profile-directory={m.group(3)}"]])

    owner = pacman_owner(path)
    if owner:
        info = pacman_info(owner)
        foreign = subprocess.run(["pacman", "-Qqm", owner], capture_output=True).returncode == 0
        source = "the AUR (built on this PC)" if foreign else "your system's software repositories (pacman)"
        removed, needed = pacman_preview(owner)
        if removed is None:
            who = ", ".join(sorted(set(needed))[:4]) + ("…" if len(set(needed)) > 4 else "")
            return ({"error": f"Other software still needs {owner} ({who}), so it can't be removed on its own."}, [])
        details = [f"Removes the program {owner} from the system" + (f" ({info['Installed Size']})." if info.get("Installed Size") else ".")]
        extra = [x for x in removed if x != owner]
        if extra:
            details.append(f"Also removes {len(extra)} package{'s' if len(extra) != 1 else ''} only it needed: " + ", ".join(extra[:6]) + ("…" if len(extra) > 6 else "."))
        else:
            details.append("Nothing else is removed with it.")
        details.append("Your own settings for it in your home folder are kept.")
        return ({"what": "a package", "summary": f"{name} is the package {owner}, installed from {source}.", "details": details},
                [["pkexec", "pacman", "-Rns", "--noconfirm", owner]])

    program = program_of(entry)
    if program.lower().endswith(".appimage") or app_id.startswith("appimagekit_"):
        files = [path]
        details = []
        if program.startswith("/") and os.path.exists(program):
            files.insert(0, program)
            size = os.path.getsize(program)
            details.append(f"Deletes the AppImage file {nice(program)} ({human_size(size)}).")
        details += ["Removes its entry from your app menu.", "Settings it saved in your home folder are kept."]
        info = {"what": "an AppImage", "summary": f"{name} is an AppImage: the whole program is one file.", "details": details}
        if shutil.which("ail-cli") and program.startswith("/"):
            return info, [["ail-cli", "unintegrate", program], ("rm", [f for f in files if f != path])]
        return info, [("rm", files)]

    if real.startswith(os.path.join(DATA_HOME, "applications") + os.sep) or path.startswith(HOME):
        target = f" ({nice(program)})" if program else ""
        return ({"what": "a launcher", "keeps": True, "summary": f"{name} is a launcher (a shortcut) in your app menu.",
                 "details": ["Only the launcher is removed, so it disappears from your app menu.",
                             f"The program it starts{target} stays installed."]},
                [("rm", [path])])

    return {"error": "Couldn't tell what installed this app. Remove it the way you installed it."}, []


def show(step):
    if isinstance(step, tuple):
        return [f"remove {f.replace(HOME, '~', 1)}" for f in step[1]]
    return [" ".join(x.replace(HOME, "~", 1) for x in step)]


def run(step):
    """(ok, output)"""
    if isinstance(step, tuple):
        errs = []
        for f in step[1]:
            try:
                if os.path.lexists(f):
                    os.unlink(f)
            except OSError as e:
                errs.append(f"{f}: {e.strerror}")
        return not errs, "\n".join(errs)
    try:
        r = subprocess.run(step, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    out = (r.stdout + r.stderr).strip()
    if step[0] == "pkexec" and r.returncode in (126, 127):
        return False, "The password prompt was cancelled."
    return r.returncode == 0, out


def main(argv):
    if len(argv) < 4 or argv[1] not in ("plan", "run"):
        print(__doc__.strip())
        return 2
    mode, path, app_id = argv[1], argv[2], argv[3]
    name = argv[4] if len(argv) > 4 else app_id
    info, steps = plan(path, app_id, name)
    if mode == "plan":
        if not steps:
            print(json.dumps({"ok": False, "error": info.get("error", "Nothing to do")}))
            return 0
        print(json.dumps(dict(info, ok=True, keeps=bool(info.get("keeps")),
                              steps=[line for st in steps for line in show(st)],
                              needsAuth=any(not isinstance(st, tuple) and (st[0] == "pkexec" or "--system" in st) for st in steps))))
        return 0
    if not steps:
        print(json.dumps({"ok": False, "error": "Nothing to do"}))
        return 0
    outputs = []
    for st in steps:
        ok, out = run(st)
        if out:
            outputs.append(out)
        if not ok:
            print(json.dumps({"ok": False, "error": (out.splitlines() or ["It did not finish."])[-1][:300], "output": "\n".join(outputs)[-2000:]}))
            return 0
    if os.path.lexists(path) and not any(isinstance(st, tuple) for st in steps):
        print(json.dumps({"ok": False, "error": "It ran, but the app's launcher is still there. Remove it from the app that made it.", "output": "\n".join(outputs)[-2000:]}))
        return 0
    print(json.dumps({"ok": True, "output": "\n".join(outputs)[-2000:]}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
