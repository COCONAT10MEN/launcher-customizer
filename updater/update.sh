#!/usr/bin/env bash
# Opt-in updates for a Caelestia plugin published on GitHub.
#
# Nothing here changes the plugin on its own. When a newer release exists it
# asks with a notification (Update / What's new / Skip this version), and only
# acts on a click. Commits pushed without a release are never offered.
# Updating keeps the previous version, so it can be undone.
#
# It offers the newest release that works with the Caelestia you have: a
# release can say which Caelestia it needs (caelestiaMinimum in its
# metadata.json) and which one it was tested on (caelestiaTested). When
# Caelestia itself updates, it checks right away instead of waiting a day.
#
# Usage:
#   update.sh check    <plugin dir> <shell dir> [now]   run by Updater.qml
#   update.sh install  <plugin dir> <shell dir>         install the update found (Settings -> Plugins button)
#   update.sh rollback <plugin dir> <shell dir>         go back to the previous version
#
# State (per plugin): ${XDG_STATE_HOME:-~/.local/state}/caelestia/plugin-updates/<id>/
#   off       if this file exists, never check (touch it to turn updates off)
#   skip      a version the user skipped (or undid); newer versions are still offered
#   asked     "<version> <time>" of a prompt closed without choosing
#   previous/ the version before the last update, for undo
#   updated   "<from> <to>" right after an update, to offer undo once
#   available "<version> <tested on> <needs>" of the update to offer, read by Settings -> Plugins
#   caelestia-seen  the Caelestia version at the last check
#   blocked   a release already announced as needing a newer Caelestia
set -uo pipefail

CMD=${1:-}
DIR=${2:-}
SHELL_DIR=${3:-}
NOW=${4:-}
[ -n "$DIR" ] && [ -f "$DIR/metadata.json" ] || exit 0
for tool in jq git curl notify-send; do command -v "$tool" >/dev/null || exit 0; done

meta() { jq -r "$1 // empty" "$DIR/metadata.json" 2>/dev/null; }
ID=$(meta .id)
NAME=$(meta .name)
NAME=${NAME:-$ID}
CURRENT=$(meta .version)
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 0

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/plugin-updates/$ID"
mkdir -p "$STATE"
[ -e "$STATE/off" ] && [ "$CMD" = check ] && exit 0
if [ "$CMD" = check ]; then
    # One prompt at a time: a check that finds a prompt still open does nothing.
    exec 9>"$STATE/lock"
    flock -n 9 || exit 0
fi
# Installing and undoing take turns, whoever asked (notification or Settings).
apply_lock() { exec 8>"$STATE/apply.lock"; flock -w 60 8; }

# The GitHub repository: metadata's "repository", else the clone's origin.
REPO_URL=$(meta .repository)
[ -n "$REPO_URL" ] || REPO_URL=$(git -C "$DIR" remote get-url origin 2>/dev/null)
SLUG=$(printf '%s' "$REPO_URL" | sed -nE 's#^(https://github\.com/|git@github\.com:)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$#\2#p' | sed 's/\.git$//')

# $1 is a newer version than $2.
newer() { [ -n "$1" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
caelestia_version() { caelestia version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1; }
icon() { local i; i=$(meta .icon); [ -n "$i" ] && [ -f "$DIR/$i" ] && printf '%s' "$DIR/$i" || printf 'system-software-update'; }
say() { notify-send -a "$NAME" -i "$(icon)" "$@" >/dev/null 2>&1 || true; }
# Shows a notification with buttons; prints the chosen button, or nothing if closed.
ask() { notify-send -a "$NAME" -i "$(icon)" --wait "$@" 2>/dev/null; }
open_url() { command -v xdg-open >/dev/null && setsid -f xdg-open "$1" >/dev/null 2>&1 9>&- 8>&-; }
release_url() { printf 'https://github.com/%s/releases/tag/v%s' "$SLUG" "$1"; }

restart_shell() {
    local script="$DIR/restart-shell.sh"
    [ -f "$script" ] || script="$STATE/previous/restart-shell.sh"
    [ -f "$script" ] && setsid -f sh "$script" "$SHELL_DIR/shell.qml" >/dev/null 2>&1 9>&- 8>&-
}

# Puts the shell's own files back to stock with the version that edited them,
# so the version taking over patches clean files.
revert_patches() {
    [ -f "$1/patch.py" ] && [ -n "$SHELL_DIR" ] && python3 -I "$1/patch.py" revert "$SHELL_DIR" >/dev/null 2>&1
    return 0
}

update_to() { # $1 = version
    local version=$1 tmp
    apply_lock || return 1
    # Already there (the other way of updating got to it first).
    [ "$(jq -r .version "$DIR/metadata.json" 2>/dev/null)" = "$version" ] && return 0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/$ID-update.XXXXXX") || return 1
    say -t 4000 "Updating $NAME" "Grabbing $version..."
    if ! git clone -q --depth 1 --branch "v$version" "https://github.com/$SLUG.git" "$tmp/new" 2>"$tmp/err"; then
        say "Couldn't update $NAME" "The download failed, so nothing changed. $(tail -n1 "$tmp/err")"
        rm -rf "$tmp"; return 1
    fi
    if [ "$(jq -r .id "$tmp/new/metadata.json" 2>/dev/null)" != "$ID" ]; then
        say "Couldn't update $NAME" "That download wasn't this plugin, so nothing changed."
        rm -rf "$tmp"; return 1
    fi
    # From here on the folder is being swapped: finish even if the shell stops.
    trap '' TERM HUP INT
    revert_patches "$DIR"
    rm -rf "$STATE/previous"
    if ! mv "$DIR" "$STATE/previous"; then
        say "Couldn't update $NAME" "Couldn't move the plugin folder, so nothing changed."
        rm -rf "$tmp"; return 1
    fi
    if ! mv "$tmp/new" "$DIR"; then
        mv "$STATE/previous" "$DIR"
        say "Couldn't update $NAME" "Couldn't put the new version in place, so nothing changed."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    printf '%s %s\n' "$CURRENT" "$version" >"$STATE/updated"
    rm -f "$STATE/skip" "$STATE/asked" "$STATE/available"
    say -t 5000 "$NAME $version is in" "Restarting Caelestia to load it."
    restart_shell
}

rollback() {
    if [ ! -f "$STATE/previous/metadata.json" ]; then
        say "$NAME" "There's no older version to go back to."
        return 1
    fi
    local back tmp
    apply_lock || return 1
    back=$(jq -r .version "$STATE/previous/metadata.json")
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/$ID-undo.XXXXXX") || return 1
    trap '' TERM HUP INT
    revert_patches "$DIR"
    mv "$DIR" "$tmp/undone" && mv "$STATE/previous" "$DIR" || {
        [ -d "$DIR" ] || mv "$tmp/undone" "$DIR"
        say "Couldn't go back" "$NAME is still on $CURRENT."
        rm -rf "$tmp"; return 1
    }
    rm -rf "$tmp"
    # The version just undone is not offered again; newer ones still are.
    printf '%s\n' "$CURRENT" >"$STATE/skip"
    rm -f "$STATE/updated"
    say -t 6000 "$NAME is back on $back" "Restarting Caelestia. You won't be asked about $CURRENT again."
    restart_shell
}

just_updated() {
    local from="" to="" choice
    { read -r from to <"$STATE/updated"; } 2>/dev/null || true
    rm -f "$STATE/updated"
    [ "$to" = "$CURRENT" ] && [ -d "$STATE/previous" ] || return 0
    while :; do
        choice=$(ask -A notes="What's new" -A undo="Undo" \
            "$NAME is now on $to" "Something broken? Undo puts $from back.")
        case "$choice" in
        notes) open_url "$(release_url "$to")" ;;
        undo) rollback; return ;;
        *) return ;;
        esac
    done
}

# Finds the newest release that works with Caelestia $1. Sets PICK (empty if
# none fits), PICK_TESTED, PICK_NEEDS, PICK_URL, PICK_NOTES, and NEWEST /
# NEWEST_NEEDS for the newest release of all. Returns 1 when nothing is newer
# than what's installed, 2 when GitHub can't be reached.
find_update() {
    local have=$1 releases v meta needs tested tries=0
    PICK="" PICK_TESTED="" PICK_NEEDS="" PICK_URL="" PICK_NOTES="" NEWEST="" NEWEST_NEEDS=""
    releases=$(curl -sfL --max-time 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$SLUG/releases?per_page=30") || return 2
    for v in $(jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name' <<<"$releases" | sed 's/^v//' | sort -Vr); do
        newer "$v" "$CURRENT" || break
        tries=$((tries + 1))
        [ "$tries" -gt 6 ] && break
        meta=$(curl -sfL --max-time 20 "https://raw.githubusercontent.com/$SLUG/v$v/metadata.json") || continue
        needs=$(jq -r '.caelestiaMinimum // empty' <<<"$meta" 2>/dev/null)
        tested=$(jq -r '.caelestiaTested // empty' <<<"$meta" 2>/dev/null)
        [ -z "$NEWEST" ] && NEWEST=$v NEWEST_NEEDS=$needs
        if [ -z "$needs" ] || [ -z "$have" ] || ! newer "$needs" "$have"; then
            PICK=$v PICK_TESTED=$tested PICK_NEEDS=$needs
            PICK_URL=$(jq -r --arg t "v$v" '.[] | select(.tag_name == $t) | .html_url // empty' <<<"$releases")
            # First line of the release notes is its one-line summary.
            PICK_NOTES=$(jq -r --arg t "v$v" '.[] | select(.tag_name == $t) | .body // empty' <<<"$releases" |
                sed -E 's/\r//; s/^[#>*-]+ *//; s/\*\*//g; s/`//g' | grep -m1 -v '^\s*$')
            break
        fi
    done
    [ -n "$NEWEST" ] || return 1
    return 0
}

check() {
    [ -f "$STATE/updated" ] && { just_updated; return; }
    [ -n "$SLUG" ] || return 0
    local have force=0
    [ "$NOW" = now ] && force=1
    have=$(caelestia_version)
    # Caelestia updated since the last look: check now, not tomorrow.
    if [ "$force" = 0 ] && [ -f "$STATE/last-check" ] &&
        [ "$(cat "$STATE/caelestia-seen" 2>/dev/null)" = "$have" ] &&
        [ $(($(date +%s) - $(stat -c %Y "$STATE/last-check"))) -lt 72000 ]; then
        return 0
    fi
    # A plugin folder with edits of its own (a developer's checkout) is never touched.
    if [ -d "$DIR/.git" ] && [ -n "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        return 0
    fi

    find_update "$have"
    case $? in
    2) return 0 ;;
    1) touch "$STATE/last-check"; printf '%s\n' "$have" >"$STATE/caelestia-seen"; rm -f "$STATE/available"; return 0 ;;
    esac
    touch "$STATE/last-check"
    printf '%s\n' "$have" >"$STATE/caelestia-seen"

    # Newer versions exist, but all of them need a newer Caelestia: say so once.
    if [ -z "$PICK" ]; then
        rm -f "$STATE/available"
        [ "$(cat "$STATE/blocked" 2>/dev/null)" = "$NEWEST" ] && [ "$force" = 0 ] && return 0
        printf '%s\n' "$NEWEST" >"$STATE/blocked"
        local choice
        choice=$(ask -A notes="What's new" "$NAME $NEWEST is out" \
            "It needs Caelestia $NEWEST_NEEDS and you're on ${have:-an older one}. Update Caelestia and it'll show up.")
        [ "$choice" = notes ] && open_url "$(release_url "$NEWEST")"
        return 0
    fi
    printf '%s %s %s\n' "$PICK" "${PICK_TESTED:--}" "${PICK_NEEDS:--}" >"$STATE/available"

    if [ "$force" = 0 ]; then
        [ "$(cat "$STATE/skip" 2>/dev/null)" = "$PICK" ] && return 0
        local asked_version="" asked_at=""
        { read -r asked_version asked_at <"$STATE/asked"; } 2>/dev/null || true
        # Closed without choosing: ask again after three days.
        [ "$asked_version" = "$PICK" ] && [ $(($(date +%s) - ${asked_at:-0})) -lt 259200 ] && return 0
    fi

    # Which Caelestia it was made for, next to the one you have.
    local compat=""
    if [ -n "$PICK_TESTED" ] && [ -n "$have" ]; then
        if newer "$PICK_TESTED" "$have"; then
            compat="Made for Caelestia $PICK_TESTED, you're on $have. Should still work, but update Caelestia if anything looks off."
        elif [ "$PICK_TESTED" = "$have" ]; then
            compat="Made for Caelestia $PICK_TESTED, same as yours."
        else
            compat="Made for Caelestia $PICK_TESTED, you're on $have."
        fi
    elif [ -n "$PICK_TESTED" ]; then
        compat="Made for Caelestia $PICK_TESTED."
    fi
    [ "$NEWEST" != "$PICK" ] && compat="$compat ($NEWEST needs Caelestia $NEWEST_NEEDS, so this is the newest one for you.)"

    local body choice
    body="You're on $CURRENT. ${PICK_NOTES:+$PICK_NOTES }$compat"
    while :; do
        choice=$(ask -A update=Update -A notes="What's new" -A skip="Skip this one" \
            "$NAME $PICK is out" "$body")
        case "$choice" in
        update) update_to "$PICK"; return ;;
        notes) open_url "${PICK_URL:-$(release_url "$PICK")}" ;;
        skip) printf '%s\n' "$PICK" >"$STATE/skip"; return ;;
        *) printf '%s %s\n' "$PICK" "$(date +%s)" >"$STATE/asked"; return ;;
        esac
    done
}

# The update Settings -> Plugins shows a button for.
install_available() {
    local version
    { read -r version _ <"$STATE/available"; } 2>/dev/null || return 0
    newer "$version" "$CURRENT" || { rm -f "$STATE/available"; return 0; }
    [ -n "$SLUG" ] || return 1
    update_to "$version"
}

case "$CMD" in
check) check ;;
install) install_available ;;
rollback) rollback ;;
*) echo "usage: $0 check|install|rollback <plugin dir> <shell dir> [now]" >&2; exit 2 ;;
esac
