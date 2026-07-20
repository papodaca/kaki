# Phase 3 — Dictation mode (keystroke simulation)

## Goal

Add a dictation toggle that, when enabled, types the streamed
transcript into whatever window has focus (like OpenAI Whisper / OS
dictation). Kaki minimizes before recording starts so the previous
focus target receives the keystrokes.

Backend chain: `libei` → `ydotool` → `xdotool`, picked at startup and
overridable in settings.

## Files to create

### `src/services/keystroke.vala`

```vala
public class Kaki.Keystroke : GLib.Object {
    public enum Backend {
        AUTO, LIBEI, YDOTOOL, XDOTOOL, NONE
    }

    public Backend backend { get; private set; default = Backend.AUTO; }

    private Secret.Schema? _schema;   // not used here, kept for parity

    public bool init (Backend preferred);     // returns false if NONE
    public async void type_text (string text, Cancellable? cancellable = null);
    public async void type_key (uint keycode, bool press, Cancellable? cancellable = null);
}
```

Selection algorithm:

1. If `preferred != AUTO`, try that one only.
2. Else if `libei-1.0` is compiled in (pkg-config at build time) → LIBEI.
3. Else if `ydotool` in `$PATH` → YDOTOOL.
4. Else if `xdotool` in `$PATH` and `$XDG_SESSION_TYPE == x11` → XDOTOOL.
5. Else NONE (dictation mode disabled with a toast).

#### libei path

Use the C API via a small VAPI `src/vapi/libei.vapi` (subset: `ei_new`,
`ei_setup_backend`, `ei_event_queue_get`, `ei_device_keyboard_key`,
`ei_device_start_emulating`, `ei_device_stop_emulating`). Verify
against the installed `libei-1.0` headers. If the binding is too much
for Phase 3, defer libei and ship ydotool-only first; revisit.

#### ydotool path

```vala
var launcher = new GLib.SubprocessLauncher (GLib.SubprocessFlags.NONE);
launcher.setenv("YDOTOOL_SLEEP_POST_TYPE", "n", true);
var sub = launcher.spawnv({"ydotool", "type", "--key-delay", delay_ms.to_string(), "--", text});
yield sub.wait_async();
```

#### xdotool path

```vala
var sub = new GLib.Subprocess(
    GLib.SubprocessFlags.NONE,
    "xdotool", "type", "--clearmodifiers", "--delay", delay_ms.to_string(), text);
yield sub.wait_async();
```

### `src/ui/window.vala` changes

- New action `win.dictate` with `<Control>D` accelerator (override via
  Phase 4 shortcuts page).
- New `Adw.ToggleButton` in the header bar (label: "Dictate") bound to
  `win.dictate`.
- `win.dictate` toggling ON:
  - `window.minimize()` after grabbing the current time (so we know
    which window had focus before minimization — record via
    `Gdk.Display.get_default().get_default_seat().get_last_event()` if
    needed; usually unnecessary because the user clicked Dictate).
  - Small timeout (250 ms) to let the WM restore the previous focus.
  - `recorder.start()` + `transcriber.stream_begin()`.
- `transcriber.partial_text` while in dictation mode:
  - Compute delta from last-typed text.
  - `keystroke.type_text(delta)` (async, fire-and-forget; coalesce
    bursts so we don't spawn 10 ydotool processes per second).
- `transcriber.final_text`:
  - Type the final delta, then a trailing newline if the user has
    enabled `dictation-trailing-newline` (default false).

### `src/ui/window.ui` changes

```xml
<child type="start">
  <object class="AdwToggleGroup"> ... </object>
</child>
<child type="start">
  <object class="GtkToggleButton" id="dictate_btn">
    <property name="icon-name">media-record-symbolic</property>
    <property name="label" translatable="yes">Dictate</property>
    <property name="action-name">win.dictate</property>
  </object>
</child>
```

## GSchema additions

```xml
<key name="dictation-auto-type" type="b">
  <default>true</default>
  <summary>Auto-type streamed text into focused window during dictation</summary>
</key>
<key name="dictation-key-delay-ms" type="i">
  <default>0</default>
  <summary>Delay between keystrokes when simulating typing (ms)</summary>
</key>
<key name="dictation-trailing-newline" type="b">
  <default>false</default>
  <summary>Append a newline after each dictation session</summary>
</key>
<key name="keystroke-backend" type="s">
  <default>"auto"</default>
  <summary>Keystroke injection backend: auto|libei|ydotool|xdotool</summary>
</key>
```

## Verification

1. Open Kaki and a text editor (gnome-text-editor) side by side.
2. Click Dictate → Kaki minimizes, editor gets focus.
3. Speak a sentence → transcript appears in the editor as you speak.
4. Toggle Dictate off (via global shortcut from Phase 5 once wired, or
   by alt-tabbing back to Kaki and clicking the button).
5. Confirm no keystrokes are dropped at the boundary.
6. With `keystroke-backend=xdotool` on X11: confirm `xdotool type`
   subprocess path works.
7. With no backend available: toggling Dictate shows a toast "No
   keystroke backend available" and does nothing.

## Commit

```
Phase 3: dictation mode with keystroke simulation

- src/services/keystroke.vala: libei → ydotool → xdotool fallback chain
- src/vapi/libei.vapi: minimal subset of libei C API (optional, gated by dep)
- window.vala: win.dictate toggle; minimize before record; type streamed text
- window.ui: Dictate toggle button in header
- GSchema: dictation-auto-type, dictation-key-delay-ms,
  dictation-trailing-newline, keystroke-backend
```
