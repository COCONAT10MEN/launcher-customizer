"""Self-repair for Caelestia plugin patches.

A plugin patch is a list of edits: "replace this exact original snippet with
this replacement". When Caelestia updates, the original snippet can change a
little (re-indented, a line added nearby, a condition appended), and an exact
match fails. This module tries to adapt the edit on its own, but only when the
result is clearly safe:

  1. exact match, found once                        -> used as is
  2. same lines ignoring whitespace, found once     -> adapted
  3. a clearly best similar region, found once, and a clean three-way merge of
     "what Caelestia changed" with "what the plugin changes"   -> adapted

Anything ambiguous or conflicting is refused, so the plugin falls back to
switching itself off (stock Caelestia) as before. Adapted files must still
parse (qmlformat), and after the shell restarts a watchdog reverts everything
if the shell does not come back or logs an error on an adapted line.

Usage from a patcher:
    import heal
    region = heal.adapt(text, original, replacement)  # None, or (start, end, found, merged)
"""

import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

STATE_ROOT = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "caelestia", "plugin-heal")
TRUST_AFTER = 2 * 24 * 3600  # an adapted patch with no errors for two days is trusted
WATCHDOG_DELAY = 30  # seconds after a restart before the watchdog checks


def norm(line: str) -> str:
    return " ".join(line.split())


def lines(text: str) -> list:
    return text.splitlines(keepends=True)


def indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip(" \t"))]


# ----------------------------------------------------------------- locating

def _find_normalized(tl, nt, ol):
    """Line index of the one place where the normalized lines match, else None."""
    n = len(ol)
    hits = [i for i in range(len(tl) - n + 1) if nt[i : i + n] == ol]
    return hits[0] if len(hits) == 1 else None


def _find_similar(tl, nt, ol):
    """(start, end) of the one clearly most similar region, else None."""
    n = len(ol)
    distinctive = {l for l in ol if len(l) >= 12}
    if not distinctive:
        return None
    anchors = [i for i, l in enumerate(nt) if l in distinctive]
    if not anchors:
        return None
    candidates = set()
    for a in anchors:
        for start in range(max(0, a - n - 3), a + 1):
            for size in range(max(1, n - 3), n + 4):
                if start + size <= len(tl):
                    candidates.add((start, start + size))
    scored = []
    for s, e in candidates:
        r = difflib.SequenceMatcher(None, ol, nt[s:e], autojunk=False).ratio()
        scored.append((r, s, e))
    if not scored:
        return None
    scored.sort(reverse=True)
    best, bs, be = scored[0]
    if best < 0.6:
        return None
    # The runner-up that does not overlap the best must be clearly worse.
    for r, s, e in scored[1:]:
        if e <= bs or s >= be:
            if r > best - 0.15:
                return None
            break
    # A changed first or last line scores nothing, so the best window can stop
    # short of it: stretch the window until every original line has a place.
    def matched():
        return [b for b in difflib.SequenceMatcher(None, ol, nt[bs:be], autojunk=False).get_matching_blocks() if b.size]

    blocks = matched()
    if blocks and blocks[0].a > blocks[0].b:
        bs = max(0, bs - (blocks[0].a - blocks[0].b))
        blocks = matched()
    if blocks:
        last = blocks[-1]
        tail_base = n - (last.a + last.size)
        tail_win = (be - bs) - (last.b + last.size)
        if tail_base > tail_win:
            be = min(len(tl), be + (tail_base - tail_win))
    return bs, be


# ------------------------------------------------------------------ merging

def _merge_line(base: str, ours: str, theirs: str):
    """Both sides only appended a condition to the same line: keep both."""
    core = base.rstrip()
    o, t = ours.rstrip(), theirs.rstrip()
    if not (o.startswith(core) and t.startswith(core)):
        return None
    so, st = o[len(core) :], t[len(core) :]
    if not (so.lstrip().startswith("&&") and st.lstrip().startswith("&&")):
        return None
    return t + so + ours[len(o) :]


def merge(base: list, ours: list, theirs: list):
    """Three-way merge of line lists; None on any conflict it can't settle."""
    nb = [norm(x) for x in base]
    oo = difflib.SequenceMatcher(None, nb, [norm(x) for x in ours], autojunk=False).get_opcodes()
    tt = difflib.SequenceMatcher(None, nb, [norm(x) for x in theirs], autojunk=False).get_opcodes()
    our_changes = [(i1, i2, ours[j1:j2]) for tag, i1, i2, j1, j2 in oo if tag != "equal"]
    their_changes = [(i1, i2, theirs[j1:j2]) for tag, i1, i2, j1, j2 in tt if tag != "equal"]
    # base line -> theirs line, for lines Caelestia left alone
    keep = {}
    for tag, i1, i2, j1, j2 in tt:
        if tag == "equal":
            for k in range(i2 - i1):
                keep[i1 + k] = theirs[j1 + k]

    # Re-indent our new lines by however much Caelestia re-indented the block.
    delta = None
    for i, t in keep.items():
        if base[i].strip():
            delta = (len(indent(base[i])), len(indent(t)))
            break

    def reindent(block):
        if not delta or delta[0] == delta[1]:
            return block
        out = []
        for l in block:
            ind = indent(l)
            if delta[1] > delta[0]:
                out.append(" " * (delta[1] - delta[0]) + l)
            else:
                cut = min(len(ind), delta[0] - delta[1])
                out.append(l[cut:])
        return out

    def overlaps(a, b):
        (a1, a2), (b1, b2) = a, b
        if a1 == a2 and b1 == b2:
            return a1 == b1
        if a1 == a2:
            return b1 < a1 < b2
        if b1 == b2:
            return a1 < b1 < a2
        return a1 < b2 and b1 < a2

    resolved = []  # (i1, i2, lines)
    for o in our_changes:
        clash = [t for t in their_changes if overlaps(o[:2], t[:2])]
        if not clash:
            resolved.append((o[0], o[1], reindent(o[2])))
            continue
        # Settle one case: both changed the same single line by appending a condition.
        if len(clash) != 1:
            return None
        t = clash[0]
        if (o[0], o[1]) != (t[0], t[1]) or o[1] - o[0] != 1 or len(t[2]) != 1:
            return None
        b = base[o[0]]
        target = max(range(len(o[2])), key=lambda k: difflib.SequenceMatcher(None, norm(b), norm(o[2][k])).ratio())
        merged = _merge_line(b, reindent([o[2][target]])[0], t[2][0])
        if merged is None:
            return None
        block = reindent(o[2])
        block[target] = merged
        resolved.append((o[0], o[1], block))
        their_changes.remove(t)
    for t in their_changes:
        resolved.append((t[0], t[1], t[2]))
    resolved.sort(key=lambda c: (c[0], c[1]))

    out, i = [], 0
    for i1, i2, block in resolved:
        while i < i1:
            if i not in keep:
                return None
            out.append(keep[i])
            i += 1
        out.extend(block)
        i = max(i, i2)
    while i < len(base):
        if i not in keep:
            return None
        out.append(keep[i])
        i += 1
    return out


# ------------------------------------------------------------------- public

def adapt(text: str, original: str, replacement: str, avoid=()):
    """Where and how to apply an edit whose exact original is not found once.

    Returns (start, end, found, new) as character offsets into text, the stock
    text found there, and what goes in its place, or None if it is not safe.
    """
    tl, ol = lines(text), lines(original)
    nt, no = [norm(l) for l in tl], [norm(l) for l in ol]
    if not any(no):
        return None
    # Never match inside the plugin's own blocks: blank them out of the search.
    nt = list(nt)
    for a, b in avoid:
        for i in range(a, min(b, len(nt))):
            nt[i] = "\0"
    start = _find_normalized(tl, nt, no)
    if start is not None:
        span = (start, start + len(ol))
    else:
        span = _find_similar(tl, nt, no)
        if span is None:
            return None
    if any(s < span[1] and span[0] < e for s, e in avoid):
        return None
    found = tl[span[0] : span[1]]
    new = merge(ol, lines(replacement), found)
    if new is None:
        return None
    cs = sum(len(l) for l in tl[: span[0]])
    ce = cs + sum(len(l) for l in found)
    return cs, ce, "".join(found), "".join(new)


def _tool(name):
    for t in (f"/usr/lib/qt6/bin/{name}", f"/usr/lib64/qt6/bin/{name}", shutil.which(name + "6") or ""):
        if t and os.path.exists(t):
            return t
    return None


def parses(text: str) -> bool:
    """True unless Qt 6's QML tools find a syntax error (or none are installed).

    qmllint is used for this: qmlformat also rejects some valid files. Only
    syntax errors count, not lint warnings (imports it can't resolve etc.).
    """
    fd, path = tempfile.mkstemp(suffix=".qml")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        lint = _tool("qmllint")
        if lint:
            res = subprocess.run([lint, "--json", "-", path], capture_output=True, text=True, timeout=30)
            try:
                data = json.loads(res.stdout)
            except ValueError:
                return False
            for f in data.get("files", []):
                if not f.get("success", True) and not f.get("warnings"):
                    return False
                if any(w.get("id") == "syntax" for w in f.get("warnings", [])):
                    return False
            return True
        fmt = _tool("qmlformat")
        if fmt:
            return subprocess.run([fmt, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20).returncode == 0
        return True
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        os.unlink(path)


# ------------------------------------------------------------ safety net state

class State:
    """What a plugin adapted, so a watchdog can undo it if the shell breaks."""

    def __init__(self, tag: str):
        os.makedirs(STATE_ROOT, exist_ok=True)
        self.path = os.path.join(STATE_ROOT, tag + ".json")
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}

    def save(self):
        fd, tmp = tempfile.mkstemp(dir=STATE_ROOT)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(self.data, f)
        os.replace(tmp, self.path)

    @staticmethod
    def fingerprint(stock: dict) -> str:
        h = hashlib.sha256()
        for rel in sorted(stock):
            h.update(rel.encode() + b"\0" + stock[rel].encode() + b"\0")
        return h.hexdigest()

    def refused(self, fp: str) -> bool:
        return fp in self.data.get("failed", [])

    def refuse(self, fp: str):
        self.data.setdefault("failed", []).append(fp)
        self.data.pop("healed", None)
        self.save()


def block_lines(text: str, begin_marker: str, end_marker: str):
    """Line ranges (1-based, inclusive) of every plugin block in a file."""
    out, start = [], None
    for n, l in enumerate(text.splitlines(), 1):
        if begin_marker in l:
            start = n
        elif end_marker in l and start is not None:
            out.append((start, n))
            start = None
    return out


_ERR = re.compile(r"(?:@|/)(?P<rel>[\w./-]+\.qml)(?:\[|:)(?P<line>\d+)")
_WORDS = ("rror", "is not a type", "Unable to assign", "Cannot assign", "not defined", "Expected", "Invalid", "is not a function", "Cannot read property")


def errors_in_blocks(since: float, blocks: dict) -> list:
    """Shell log lines since `since` that point at a line inside our blocks."""
    try:
        out = subprocess.run(["journalctl", "--user", "--since", f"@{int(since)}", "--no-pager", "-o", "cat"],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    hits = []
    for l in out.splitlines():
        if not any(w in l for w in _WORDS):
            continue
        for m in _ERR.finditer(l):
            rel, n = m.group("rel"), int(m.group("line"))
            for brel, ranges in blocks.items():
                if rel.endswith(brel) and any(a <= n <= b for a, b in ranges):
                    hits.append(l.strip())
    return hits


def start_watchdog(tag: str, patcher: str, shell: str):
    """Ask systemd to run `patcher watchdog <shell>` a little after the restart."""
    if not shutil.which("systemd-run"):
        return
    subprocess.run(["systemd-run", "--user", "--collect", "--quiet", f"--unit=caelestia-heal-{tag}-{int(time.time())}",
                    f"--on-active={WATCHDOG_DELAY}", "python3", "-I", patcher, "watchdog", shell],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def restart_shell(shell: str):
    unit = "caelestia-shell.service"
    if subprocess.run(["systemctl", "--user", "cat", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        # A crash loop can hit systemd's restart limit: clear it first.
        subprocess.run(["systemctl", "--user", "reset-failed", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "--user", "--no-block", "restart", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def notify(title: str, body: str):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", title, "-i", "dialog-warning", title, body], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ------------------------------------------------------------- patcher glue

def _block_spans(text: str, tag: str):
    """Line index spans [a, b) of this plugin's own blocks, to keep searches out of them."""
    spans, start = [], None
    for i, l in enumerate(text.splitlines()):
        if f"// {tag}:begin" in l:
            start = i
        elif f"// {tag}:end" in l and start is not None:
            spans.append((start, i + 1))
            start = None
    return spans


def patch_ops(ops, stock: dict, block, tag: str):
    """Apply (file, original, replacement) ops, or (file, [(original, replacement), ...]).

    Exact matches first; otherwise a safe adaptation. Returns (patched texts,
    files that needed adapting). Raises ValueError if any op can't be placed.
    """
    out, healed = dict(stock), set()
    for op in ops:
        rel = op[0]
        variants = op[1] if len(op) == 2 else [(op[1], op[2])]
        text = out[rel]
        for original, replacement in variants:
            if text.count(original) == 1:
                out[rel] = text.replace(original, block(original, replacement), 1)
                break
        else:
            for original, replacement in variants:
                a = adapt(text, original, replacement, avoid=_block_spans(text, tag))
                if a:
                    cs, ce, found, new = a
                    out[rel] = text[:cs] + block(found, new) + text[ce:]
                    healed.add(rel)
                    break
            else:
                original = variants[0][0]
                first = original.strip().splitlines()[0].strip()
                raise ValueError(f"{rel}: snippet found {text.count(original)} times: {first[:70]!r} (Caelestia changed; plugin needs updating)")
    for rel in healed:
        if rel.endswith(".qml") and not parses(out[rel]):
            raise ValueError(f"{rel}: could not adapt to this Caelestia safely (the result does not parse)")
    return out, sorted(healed)


class Guard:
    """Safety net around adapted patches.

    record()   after writing patched files: remember them, start the watchdog
    check()    on every plugin start: revert if a patched line logged an error
    watchdog() run by systemd ~75 s after the restart: revert if the shell did
               not come back with the plugin loaded, or logged an error there

    It covers every patch, adapted or exact: whatever stops Caelestia from
    loading (or logs an error on a patched line) is undone on its own, and that
    Caelestia build is left alone until the plugin updates.
    """

    def __init__(self, tag: str, patcher: str, shell: str, name: str):
        self.tag, self.patcher, self.shell, self.name = tag, patcher, shell, name
        self.state = State(tag)

    def _blocks(self, files):
        out = {}
        for rel in files:
            try:
                with open(os.path.join(self.shell, rel), encoding="utf-8") as f:
                    out[rel] = block_lines(f.read(), f"// {self.tag}:begin", f"// {self.tag}:end")
            except OSError:
                pass
        return out

    def refused(self, stock: dict, healed: list) -> bool:
        return bool(healed) and self.state.refused(State.fingerprint({r: stock[r] for r in healed}))

    def record(self, stock: dict, healed: list):
        """healed: the files just patched (the name is kept for old state files)."""
        if not healed:
            if "healed" in self.state.data:
                self.state.data.pop("healed")
                self.state.save()
            return
        fp = State.fingerprint({r: stock[r] for r in healed})
        self.state.data["healed"] = {"fp": fp, "at": time.time(), "files": healed, "seen": 0, "trusted": False}
        self.state.save()
        start_watchdog(self.tag, self.patcher, self.shell)

    def _fail(self, write_stock, why: str):
        h = self.state.data.get("healed", {})
        write_stock()
        self.state.refuse(h.get("fp", ""))
        notify(self.name, f"This Caelestia version doesn't work with it ({why}), so it's off for now. Caelestia is fine.")

    def check(self, write_stock):
        """Returns a FAILED message if it had to revert, else None."""
        h = self.state.data.get("healed")
        if not h or h.get("trusted"):
            return None
        errs = errors_in_blocks(h["at"], self._blocks(h["files"]))
        if errs:
            self._fail(write_stock, "it caused an error")
            return "FAILED+RELOAD: adapted patch logged an error: " + errs[0][:120]
        h["seen"] = time.time()
        if h["seen"] - h["at"] > TRUST_AFTER:
            h["trusted"] = True
        self.state.save()
        return None

    def watchdog(self, write_stock):
        h = self.state.data.get("healed")
        if not h or h.get("trusted"):
            return "NOTHING"
        active = subprocess.run(["systemctl", "--user", "is-active", "--quiet", "caelestia-shell.service"]).returncode == 0
        errs = errors_in_blocks(h["at"], self._blocks(h["files"]))
        if active and h.get("seen", 0) > h["at"] and not errs:
            return "OK"
        self._fail(write_stock, "Caelestia didn't start right with it" if not errs else "it caused an error")
        restart_shell(self.shell)
        return "REVERTED"


_LOCK = None


def hold_shell_lock():
    """Take turns with the other plugins' patchers: several run at every shell
    start and some edit the same files. Held until this process exits."""
    global _LOCK
    import fcntl
    if _LOCK is None:
        path = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir(), "caelestia-plugin-patch.lock")
        _LOCK = open(path, "w")
        fcntl.flock(_LOCK, fcntl.LOCK_EX)
