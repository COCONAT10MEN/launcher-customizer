#!/usr/bin/env bash
# Opt-in updates for a Caelestia plugin published on GitHub.
#
# Nothing here changes the plugin on its own. When a newer release exists it
# asks with a notification (Update / What's new / Skip this version), and only
# acts on a click. Commits pushed without a release are never offered.
# Updating keeps the previous version, so it can be undone.
#
# Usage:
#   update.sh check    <plugin dir> <shell dir> [now]   run by Updater.qml
#   update.sh rollback <plugin dir> <shell dir>         go back to the previous version
#
# State (per plugin): ${XDG_STATE_HOME:-~/.local/state}/caelestia/plugin-updates/<id>/
#   off       if this file exists, never check (touch it to turn updates off)
#   skip      a version the user skipped (or undid); newer versions are still offered
#   asked     "<version> <time>" of a prompt closed without choosing
#   previous/ the version before the last update, for undo
#   updated   "<from> <to>" right after an update, to offer undo once
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
# One prompt at a time: a check that finds a prompt still open does nothing.
exec 9>"$STATE/lock"
flock -n 9 || exit 0

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
open_url() { command -v xdg-open >/dev/null && setsid -f xdg-open "$1" >/dev/null 2>&1 9>&-; }
release_url() { printf 'https://github.com/%s/releases/tag/v%s' "$SLUG" "$1"; }

restart_shell() {
    local script="$DIR/restart-shell.sh"
    [ -f "$script" ] || script="$STATE/previous/restart-shell.sh"
    [ -f "$script" ] && setsid -f sh "$script" "$SHELL_DIR/shell.qml" >/dev/null 2>&1 9>&-
}

# Puts the shell's own files back to stock with the version that edited them,
# so the version taking over patches clean files.
revert_patches() {
    [ -f "$1/patch.py" ] && [ -n "$SHELL_DIR" ] && python3 -I "$1/patch.py" revert "$SHELL_DIR" >/dev/null 2>&1
    return 0
}

update_to() { # $1 = version
    local version=$1 tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/$ID-update.XXXXXX") || return 1
    say -t 4000 "Updating $NAME" "Downloading $version..."
    if ! git clone -q --depth 1 --branch "v$version" "https://github.com/$SLUG.git" "$tmp/new" 2>"$tmp/err"; then
        say "Could not update $NAME" "The download failed, so nothing was changed. $(tail -n1 "$tmp/err")"
        rm -rf "$tmp"; return 1
    fi
    if [ "$(jq -r .id "$tmp/new/metadata.json" 2>/dev/null)" != "$ID" ]; then
        say "Could not update $NAME" "The download is not this plugin, so nothing was changed."
        rm -rf "$tmp"; return 1
    fi
    # From here on the folder is being swapped: finish even if the shell stops.
    trap '' TERM HUP INT
    revert_patches "$DIR"
    rm -rf "$STATE/previous"
    if ! mv "$DIR" "$STATE/previous"; then
        say "Could not update $NAME" "The plugin folder could not be moved, so nothing was changed."
        rm -rf "$tmp"; return 1
    fi
    if ! mv "$tmp/new" "$DIR"; then
        mv "$STATE/previous" "$DIR"
        say "Could not update $NAME" "The new version could not be put in place, so nothing was changed."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    printf '%s %s\n' "$CURRENT" "$version" >"$STATE/updated"
    rm -f "$STATE/skip" "$STATE/asked"
    say -t 5000 "$NAME updated to $version" "Caelestia restarts now to load it."
    restart_shell
}

rollback() {
    if [ ! -f "$STATE/previous/metadata.json" ]; then
        say "$NAME" "There is no earlier version to go back to."
        return 1
    fi
    local back tmp
    back=$(jq -r .version "$STATE/previous/metadata.json")
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/$ID-undo.XXXXXX") || return 1
    trap '' TERM HUP INT
    revert_patches "$DIR"
    mv "$DIR" "$tmp/undone" && mv "$STATE/previous" "$DIR" || {
        [ -d "$DIR" ] || mv "$tmp/undone" "$DIR"
        say "Could not go back" "$NAME was left as it was."
        rm -rf "$tmp"; return 1
    }
    rm -rf "$tmp"
    # The version just undone is not offered again; newer ones still are.
    printf '%s\n' "$CURRENT" >"$STATE/skip"
    rm -f "$STATE/updated"
    say -t 6000 "$NAME is back to $back" "Caelestia restarts now. Version $CURRENT will not be offered again; newer ones will."
    restart_shell
}

just_updated() {
    local from to choice
    read -r from to <"$STATE/updated" || true
    rm -f "$STATE/updated"
    [ "$to" = "$CURRENT" ] && [ -d "$STATE/previous" ] || return 0
    while :; do
        choice=$(ask -A notes="What's new" -A undo="Undo update" \
            "$NAME updated to $to" "If something is not right, Undo update puts $from back.")
        case "$choice" in
        notes) open_url "$(release_url "$to")" ;;
        undo) rollback; return ;;
        *) return ;;
        esac
    done
}

check() {
    [ -f "$STATE/updated" ] && { just_updated; return; }
    [ -n "$SLUG" ] || return 0
    # At most once a day (unless asked to check now).
    if [ "$NOW" != now ] && [ -f "$STATE/last-check" ] &&
        [ $(($(date +%s) - $(stat -c %Y "$STATE/last-check"))) -lt 72000 ]; then
        return 0
    fi
    # A plugin folder with edits of its own (a developer's checkout) is never touched.
    if [ -d "$DIR/.git" ] && [ -n "$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        return 0
    fi

    local release tag latest url notes
    release=$(curl -sfL --max-time 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$SLUG/releases/latest") || return 0
    touch "$STATE/last-check"
    tag=$(jq -r '.tag_name // empty' <<<"$release")
    latest=${tag#v}
    newer "$latest" "$CURRENT" || return 0
    if [ "$NOW" != now ]; then
        [ "$(cat "$STATE/skip" 2>/dev/null)" = "$latest" ] && return 0
        local asked_version asked_at
        read -r asked_version asked_at <"$STATE/asked" 2>/dev/null || true
        # Closed without choosing: ask again after three days.
        [ "$asked_version" = "$latest" ] && [ $(($(date +%s) - ${asked_at:-0})) -lt 259200 ] && return 0
    fi
    url=$(jq -r '.html_url // empty' <<<"$release")
    # First line of the release notes is its one-line summary.
    notes=$(jq -r '.body // empty' <<<"$release" | sed -E 's/\r//; s/^[#>*-]+ *//; s/\*\*//g; s/`//g' | grep -m1 -v '^\s*$')

    # What the release was made and tested for, from its own metadata.json.
    local remote tested minimum have compat="" buttons=(-A update=Update)
    remote=$(curl -sfL --max-time 20 "https://raw.githubusercontent.com/$SLUG/$tag/metadata.json")
    tested=$(jq -r '.caelestiaTested // empty' <<<"$remote" 2>/dev/null)
    minimum=$(jq -r '.caelestiaMinimum // empty' <<<"$remote" 2>/dev/null)
    have=$(caelestia_version)
    if [ -n "$minimum" ] && [ -n "$have" ] && newer "$minimum" "$have"; then
        compat="It needs Caelestia KDE $minimum or newer and you have $have, so update Caelestia first."
        buttons=()
    elif [ -n "$tested" ] && [ -n "$have" ] && newer "$tested" "$have"; then
        compat="Made and tested for Caelestia KDE $tested. You have $have, so it may not work until you update Caelestia."
    elif [ -n "$tested" ]; then
        compat="Tested on Caelestia KDE $tested${have:+ (you have $have)}."
    fi

    local body choice
    body="You have $CURRENT. ${notes:+$notes }$compat
Nothing changes unless you choose Update."
    while :; do
        choice=$(ask "${buttons[@]}" -A notes="What's new" -A skip="Skip this version" \
            "$NAME $latest is available" "$body")
        case "$choice" in
        update) update_to "$latest"; return ;;
        notes) open_url "${url:-$(release_url "$latest")}" ;;
        skip) printf '%s\n' "$latest" >"$STATE/skip"; return ;;
        *) printf '%s %s\n' "$latest" "$(date +%s)" >"$STATE/asked"; return ;;
        esac
    done
}

case "$CMD" in
check) check ;;
rollback) rollback ;;
*) echo "usage: $0 check|rollback <plugin dir> <shell dir> [now]" >&2; exit 2 ;;
esac
