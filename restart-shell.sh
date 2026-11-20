#!/bin/sh
# Restart the Caelestia shell so freshly patched files take effect.
# Quickshell's in-process reload is not used: on this shell it can deadlock and
# it does not start plugins again. Prefer the systemd user service, which gives
# the shell its proper environment and logging.
# $1 = path to the shell's shell.qml
sleep 0.5
UNIT=caelestia-shell.service
if systemctl --user cat "$UNIT" >/dev/null 2>&1; then
    if systemctl --user is-active -q "$UNIT"; then
        exec systemctl --user --no-block restart "$UNIT"
    fi
    quickshell kill -p "$1" >/dev/null 2>&1
    sleep 1
    exec systemctl --user --no-block start "$UNIT"
fi
quickshell kill -p "$1" >/dev/null 2>&1
sleep 1
exec setsid -f quickshell -n -p "$1" >/dev/null 2>&1
