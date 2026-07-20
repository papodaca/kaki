# Phase 5 — Global shortcuts (portal + fallback)

## Goal

Toggle recording from anywhere on the desktop — not just when Kaki has
focus. Two paths:

1. **Preferred**: `org.freedesktop.portal.GlobalShortcuts` via
   `xdg-desktop-portal` (Wayland-friendly, no extra daemon).
2. **Fallback**: a tiny shell script `kaki-signal` that sends SIGUSR1
   to the running Kaki instance. The user binds it to a custom
   keyboard shortcut in their DE settings (GNOME Settings → Keyboard →
   Custom Shortcuts). The user offered to share an example from
   another app — incorporate the reference when received.

## Files to create

### `src/services/global-shortcuts.vala`

```vala
public class Kaki.GlobalShortcuts : GLib.Object {
    public bool available { get; private set; }

    public signal void shortcut_activated (string id);

    public async bool init ();
    public async void bind (string id, string description);
    public async void unbind (string id);
}
```

Uses `org.freedesktop.portal.GlobalShortcuts` DBus interface on the
session bus (`org.freedesktop.portal.Desktop` →
`/org/freedesktop/portal/desktop`). Methods: `CreateSession`,
`BindShortcuts`, `ListShortcuts`. Signals: `Activated`, `Deactivated`.

Pin a single shortcut `id="toggle-recording"` with description
"Toggle voice recording". On `Activated` for that id → emit
`shortcut_activated("toggle-recording")`. The application wires it to
the existing `win.record` / `win.stop` toggle.

### `data/kaki-signal.sh` (fallback script)

```sh
#!/bin/sh
# kaki-signal — send a signal to the running Kaki instance.
# Usage:
#   kaki-signal toggle     # SIGUSR1 — toggle recording
#   kaki-signal stop       # SIGUSR2 — stop recording
#   kaki-signal insert     # SIGRTMIN+1 — copy + type last transcript
#
# Bind in GNOME: Settings → Keyboard → Custom Shortcuts →
#   Command: kaki-signal toggle
set -eu

PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/kaki.pid"

if [ "$#" -lt 1 ]; then
  echo "usage: kaki-signal <toggle|stop|insert>" >&2
  exit 2
fi

if [ ! -r "$PIDFILE" ]; then
  echo "kaki not running (no $PIDFILE)" >&2
  notify-send -a kaki "Kaki is not running" "Start Kaki first."
  exit 1
fi

PID="$(cat "$PIDFILE")"
case "$1" in
  toggle) kill -USR1 "$PID" ;;
  stop)   kill -USR2 "$PID" ;;
  insert) kill -RTMIN+1 "$PID" ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
```

Install to `$(bindir)/kaki-signal` via meson:

```meson
install_data('kaki-signal.sh',
  install_dir: get_option('bindir'),
  install_mode: 'rwxr-xr-x',
  rename: 'kaki-signal')
```

### `src/application.vala` signal handlers

```vala
construct {
    // ...
    Unix.signal_add (Posix.Signal.USR1, () => { on_global_toggle (); return GLib.Source.CONTINUE; });
    Unix.signal_add (Posix.Signal.USR2, () => { on_global_stop ();   return GLib.Source.CONTINUE; });
    Unix.signal_add (Posix.Signal.RTMIN + 1, () => { on_global_insert (); return GLib.Source.CONTINUE; });

    // Write pidfile for kaki-signal
    var pidfile = GLib.Environment.get_variable ("XDG_RUNTIME_DIR") ?? "/tmp";
    pidfile = pidfile + "/kaki.pid";
    FileUtils.set_contents (pidfile, Posix.getpid ().to_string ());
}

private void on_global_toggle () {
    var win = this.active_window as Kaki.Window;
    if (win == null) return;
    if (win.is_recording) win.stop ();
    else win.record ();
}

private void on_global_stop ()   { (this.active_window as Kaki.Window)?.stop (); }
private void on_global_insert (){ (this.active_window as Kaki.Window)?.insert (); }
```

(Delete the pidfile on `shutdown`.)

## Preferences page update (Shortcuts)

Add a row at the top of the Shortcuts page:

- Adw.ActionRow: "Global shortcut (toggle recording)"
  - Subtitle: portal state ("Active via xdg-desktop-portal" / "Portal
    unavailable — install kaki-signal as a custom shortcut")
  - Button "Bind via portal" if available
  - Button "Install helper script" → copies `kaki-signal` to
    `~/.local/bin/` if not installed system-wide; shows a dialog with
    GNOME custom-shortcut instructions:
    ```
    Open Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts
    Name: Kaki Toggle Recording
    Command: kaki-signal toggle
    Shortcut: (press your combo)
    ```

## Verification

1. **Portal available** (modern GNOME, xdg-desktop-portal-gnome):
   - Open Preferences → Shortcuts → click "Bind via portal" → GNOME
     shows the binding prompt → assign a combo (e.g. Super+R).
   - Focus another app → press combo → Kaki toggles recording.
2. **Portal unavailable** (no `GlobalShortcuts` support):
   - The Shortcuts page shows "Install helper script" path.
   - Install script → bind in GNOME custom shortcuts → combo fires →
     Kaki toggles recording.
3. `~/.local/bin/kaki-signal` exists and `kaki-signal toggle` from a
   shell toggles recording in the running Kaki.
4. `$XDG_RUNTIME_DIR/kaki.pid` exists while Kaki runs and disappears
   after quit.
5. Kaki quit cleanly removes the pidfile.

## Open follow-up

User offered to share a shell-script fallback example from another
app. Once received, fold the patterns (pidfile location, signal
choice, notify-send wording) into `kaki-signal.sh` for consistency.

## Commit

```
Phase 5: global shortcuts via xdg-desktop-portal + shell-script fallback

- src/services/global-shortcuts.vala: org.freedesktop.portal.GlobalShortcuts
  DBus binding for 'toggle-recording'
- data/kaki-signal.sh: SIGUSR1/USR2/RTMIN+1 fallback script
- application.vala: Unix.signal_add handlers; pidfile in XDG_RUNTIME_DIR
- Preferences Shortcuts page: bind via portal, install helper script,
  GNOME custom-shortcut instructions
```
