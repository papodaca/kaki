#!/bin/sh
# kaki-signal — send a signal to the running Kaki instance.
#
# Usage:
#   kaki-signal toggle     # SIGUSR1 — toggle dictation (record + stream
#                                   # into the focused window; stop +
#                                   # type the final text)
#   kaki-signal stop       # SIGUSR2 — stop recording (finalizes + types
#                                   # the final text if dictating)
#   kaki-signal insert     # SIGRTMIN+1 — copy + type the transcript into
#                                   # the focused window (refused while
#                                   # dictation is active)
#
# Bind in GNOME: Settings → Keyboard → View and Customize Shortcuts →
# Custom Shortcuts →
#   Name:    Kaki Toggle Recording
#   Command: kaki-signal toggle
#   Shortcut: (press your combo)
#
# This is the fallback path for environments without the
# org.freedesktop.portal.GlobalShortcuts portal (see Preferences →
# Shortcuts → "Install helper script"). The running Kaki writes its PID
# to $XDG_RUNTIME_DIR/kaki.pid (or /tmp/kaki.pid) at startup.
set -eu

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/kaki.pid"

notify() {
    # notify-send is optional; degrade silently when absent.
    command -v notify-send >/dev/null 2>&1 \
        && notify-send -a kaki -i org.kaki.app "$1" "$2" || true
}

if [ "$#" -lt 1 ]; then
    echo "usage: kaki-signal <toggle|stop|insert>" >&2
    exit 2
fi

if [ ! -r "$PIDFILE" ]; then
    echo "kaki not running (no $PIDFILE)" >&2
    notify "Kaki is not running" "Start Kaki first."
    exit 1
fi

PID="$(cat "$PIDFILE")"
# Reject non-numeric, empty, zero, or negative "pids" before touching
# kill — `kill -USR1 -1` would signal every process the caller owns
# (default action: terminate), and `kill -USR1 0` the caller's process
# group. A world-writable fallback /tmp/kaki.pid makes this plantable.
case "$PID" in
    ''|*[!0-9]*)
        echo "kaki-signal: invalid pid in $PIDFILE" >&2
        notify "Kaki pidfile is corrupt" "Start Kaki again."
        exit 1
        ;;
esac
[ "$PID" -gt 0 ] 2>/dev/null || {
    echo "kaki-signal: invalid pid in $PIDFILE" >&2
    notify "Kaki pidfile is corrupt" "Start Kaki again."
    exit 1
}

if ! kill -0 "$PID" 2>/dev/null; then
    echo "kaki not running (stale pid $PID in $PIDFILE)" >&2
    notify "Kaki is not running" "Start Kaki first."
    exit 1
fi

# Stale pidfile + PID reuse: kill -0 only proves *some* process owns the
# PID. SIGUSR1/USR2/RTMIN+1 default to termination, so signalling a
# reused PID would kill an unrelated process. Confirm the target is
# actually Kaki. /proc is Linux-only (Kaki targets GNOME/Linux); if it
# is unavailable we fall through to the kill -0 check above.
if [ -r "/proc/$PID/comm" ]; then
    comm="$(cat "/proc/$PID/comm")"
    if [ "$comm" != "kaki" ]; then
        echo "kaki-signal: pid $PID is not kaki (stale $PIDFILE, comm=$comm)" >&2
        notify "Kaki is not running" "pid $PID is not kaki (stale pidfile)"
        exit 1
    fi
fi

case "$1" in
    toggle) kill -USR1 "$PID" ;;
    stop)   kill -USR2 "$PID" ;;
    insert) kill -RTMIN+1 "$PID" ;;
    *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
