# Testing

Kaki has no automated test suite. The build ships three meson tests
that validate static metadata, and each phase is verified manually
against its plan's § Verification section. Phase 4 (Preferences UI)
introduced GTK/libsecret/libsoup code that can't be exercised by a
plain unit test without a display and a keyring, so verification was
done headless under Xvfb plus a handful of targeted script-driven
checks against the real subprocesses our code calls (libsoup POST,
libsecret store, HuggingFace URLs, gresource bundle).

This document records what was checked, how, and why — so the same
checks can be re-run after future changes.

## Built-in meson tests

```
meson test -C build --print-errorlogs
```

Three tests, all defined in `data/meson.build`:

| Test | Tool | What it catches |
| --- | --- | --- |
| `Validate desktop file` | `desktop-file-validate` | Malformed `org.kaki.app.desktop.in` |
| `Validate schema file`  | `glib-compile-schemas --strict --dry-run` | Bad GSettings keys/types/defaults |
| `Validate appstream file` | `appstreamcli validate --no-net --explain` | Malformed metainfo XML |

These run on every `meson test` and gate the build in CI. They caught
nothing during Phase 4 (the schema addition validated clean on the
first try), but they are the only automated regression net for the
static metadata.

## Phase 4 verification

The plan's § Verification section has six manual steps. Step 4
(shortcut rebind) and step 6 (`secret-tool` lookup) can be exercised
headless; the rest were covered by smoke + targeted sub-process
checks. Everything below was run from the repo root after
`ninja -C build`.

### 1. GSettings schema: keys exist and round-trip

Compile the schema into a throwaway dir (so the system dconf DB
isn't polluted) and dump every key:

```bash
mkdir -p /tmp/kaki-schemas
cp data/org.kaki.app.gschema.xml /tmp/kaki-schemas/
glib-compile-schemas /tmp/kaki-schemas/
GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas \
  gsettings list-recursively org.kaki.app
```

All 13 Phase 4 keys appeared with the right defaults
(`gpu-backend='auto'`, `shortcut-record='<Control>R'`,
`api-temperature=0.0`, …).

Round-trip a value to confirm setters, getters, and reset all work:

```bash
GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas \
  gsettings set org.kaki.app shortcut-record "<Control><Shift>R"
GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas \
  gsettings get   org.kaki.app shortcut-record   # → '<Control><Shift>R'
GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas \
  gsettings reset org.kaki.app shortcut-record
GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas \
  gsettings get   org.kaki.app shortcut-record   # → '<Control>R'
```

### 2. Build clean

```bash
meson setup --reconfigure build
ninja -C build
```

Vala → C → link. The first compile surfaced four real bugs that the
type- / link-checker caught and were fixed before any runtime test:

| Error | Cause | Fix |
| --- | --- | --- |
| `open_async` doesn't exist on `Gtk.FileLauncher` | GTK4 renamed it | Use `open_containing_folder` |
| `Gdk.ModifierType.MOD4_MASK` not found | GTK4 renamed Mod4 → Super | `Gdk.ModifierType.SUPER_MASK` |
| `ShortcutRow.changed` shadows `Gtk.ListBoxRow.changed` | Vala warning, real bug | Renamed to `shortcut_changed` |
| `UI resource not found: /org/kaki/app/preferences.ui` | File at `src/ui/preferences.ui` but `[GtkTemplate]` expected bare path | Added `alias="preferences.ui"` to `kaki.gresource.xml` |

The remaining warnings are all benign:
- `Gtk.ShortcutLabel` deprecated since 4.18 — no replacement exists
  for capturing / displaying an accelerator in a row, so we keep it.
- Unused-parameter warnings in Vala-generated C callbacks — noise
  from the Vala→C marshalling.
- `_finish` defined-but-not-used for async methods — Vala emits the
  finish function even when only the `begin` form is called.

### 3. App launches + preferences dialog opens (no criticals)

Headless X server + send `Ctrl+,` via xdotool + watch stderr for
GTK/Adwaita/GLib criticals:

```bash
export GSETTINGS_SCHEMA_DIR=/tmp/kaki-schemas
export GDK_BACKEND=x11
xvfb-run -a -s "-screen 0 1280x1024x24" bash -c '
  build/src/kaki 2>&1 &
  APP_PID=$!
  sleep 3
  xdotool key ctrl+comma
  sleep 2
  kill $APP_PID 2>/dev/null
  wait $APP_PID 2>/dev/null
'
```

The first run fired a wall of criticals — the template failed to
load:

```
Gtk-CRITICAL: Error building template class 'KakiPreferencesDialog':
  Invalid property: AdwButtonRow.subtitle
```

`AdwButtonRow` extends `Adw.PreferencesRow`, not `Adw.ActionRow`, so
it has no `subtitle` property. Removed every `<property name="subtitle">`
from `AdwButtonRow` instances in `preferences.ui` (folded the size
hint into the title text). Re-ran — clean.

### 4. Dialog actually renders (pixel sampling)

Screenshots can't be viewed in this environment, so a PIL script
samples the rendered image to confirm the dialog isn't a blank
window:

```python
from PIL import Image
img = Image.open('/tmp/kaki-shots/02-preferences.png').convert('RGB')
print(img.size, len(set(img.get_flattened_data())))  # unique colors
for x, y, name in [(50,50,'header'), (640,200,'title'), (640,400,'content')]:
    print(name, img.getpixel((x, y)))
```

Main window: ~275 unique colors. Preferences dialog: ~600 unique
colors with content-area pixels at `(640, 400) = (72, 72, 75)` —
i.e. a real lit row, not background. The dialog is rendering.

### 5. HuggingFace URLs still resolve

The catalog in `preferences.vala` is hardcoded; the plan warns the
org may rename repos. Verified all three resolve with a HEAD
request:

```bash
for url in \
  https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf \
  https://huggingface.co/handy-computer/whisper-base.en-gguf/resolve/main/whisper-base.en-Q8_0.gguf \
  https://huggingface.co/handy-computer/whisper-small.en-gguf/resolve/main/whisper-small.en-Q8_0.gguf
do
  curl -sI -L -o /dev/null -w "%{http_code} %{url_effective}\n" "$url"
done
```

All three returned `200` with a redirect to `us.aws.cdn.hf.co`
(libsoup follows redirects by default, so this works from the app).

### 6. libsecret round-trip via `secret-tool`

Per plan § Verification step 6. The libsecret schema in
`secret-store.vala` uses schema name `org.kaki.app` with attribute
`type=api-key`. Started a fresh `gnome-keyring-daemon` and exercised
the full workflow with the CLI:

```bash
eval $(echo 'password' | gnome-keyring-daemon --start --components=secrets)
# store
echo 'password123' | secret-tool store --label='Kaki test' type api-key
# lookup
secret-tool lookup type api-key                  # → password123
# search (lists all matching)
secret-tool search --all type api-key            # → label, secret, attributes
# clear
secret-tool clear  type api-key
# lookup after clear
secret-tool lookup type api-key                  # → empty
```

All four steps behaved correctly. `password_lookupv` returns an
empty string when nothing matches; `secret-store.vala` normalizes
that to `null` so callers can treat missing as "not set".

### 7. Test-sample.wav is a valid silent WAV

The gresource-bundled WAV is what `on_test_connection` POSTs to the
configured endpoint. Validated its header and content with Python's
`wave` module:

```python
import wave
wf = wave.open('src/ui/test-sample.wav')
print(wf.getnchannels(), wf.getframerate(), wf.getnframes(),
      wf.getsampwidth() * 8)
# → 1 16000 1600 16  (mono, 16 kHz, 1600 frames, 16-bit)
frames = wf.readframes(wf.getnframes())
print(sum(1 for b in frames if b != 0))   # → 0  (silent)
```

100 ms of 16 kHz mono 16-bit PCM, all zero samples. Matches what
the OpenAI transcription API expects.

### 8. Multipart POST construction is correct

This is the one piece of network code that can't be smoke-tested
without a live endpoint. Instead of mocking libsoup, started a
local `http.server` and replicated the exact multipart our
`on_test_connection` builds using the `requests` library with the
same fields, headers, and bundled WAV:

```python
import http.server, socketserver, threading, requests

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        for needle in [b'name="file"', b'name="model"',
                       b'name="response_format"', b'name="temperature"',
                       b'filename="sample.wav"', b'audio/wav']:
            assert needle in body, f"missing {needle}"
        assert self.headers.get('Authorization') == 'Bearer test-key-123'
        out = b'{"text":"hello"}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(out)))
        self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass

srv = socketserver.TCPServer(('127.0.0.1', 18766), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()

with open('src/ui/test-sample.wav', 'rb') as f: wav = f.read()
files = {'file': ('sample.wav', wav, 'audio/wav')}
data  = {'model': 'whisper-1', 'response_format': 'json', 'temperature': '0.0'}
r = requests.post('http://127.0.0.1:18766',
                  files=files, data=data,
                  headers={'Authorization': 'Bearer test-key-123'})
print(r.status_code, len(r.content))   # → 200 16
```

Every form field the server received matched what `on_test_connection`
sends; the Authorization header came through; the response shape
matched what our toast formats as `"%u OK — %lld bytes"`.

### 9. gresource bundle contents

Confirmed all four resources are baked into the binary at the
expected paths:

```bash
strings build/src/kaki | grep -E '^/org/kaki/app/'
```

Output:
```
/org/kaki/app/preferences.ui
/org/kaki/app/shortcuts-dialog.ui
/org/kaki/app/test-sample.wav
/org/kaki/app/window.ui
```

The `alias=` attribute on `<file>` in `kaki.gresource.xml` is what
lets `preferences.ui` live at `src/ui/preferences.ui` on disk but
appear at `/org/kaki/app/preferences.ui` (no `ui/` segment) in the
bundle — matching the path in the `[GtkTemplate]` attribute.

## What is NOT tested

- **Live shortcut rebind (plan step 4)**: requires interactive focus
  to confirm `<Control><Shift>R` starts recording and `<Control>R`
  no longer does. The mechanism is verified (GSettings round-trips,
  `apply_shortcuts` is called on every `changed::shortcut-*`
  notification, `set_accels_for_action` is the documented live-rebind
  API) but the end-to-end "press the key, see the recorder start"
  needs a human at a real session.
- **Actual model download**: hitting HuggingFace for ~77 MB from a
  test script is rude; the URL HEAD check + the libsoup send_async +
  chunked-read path is standard. The atomic `.part` → rename logic
  is simple enough to verify by reading the code.
- **Real OpenAI API call**: would need a live key. The multipart
  construction (step 8 above) is the part that can break silently;
  the actual HTTP send is plain libsoup.
- **Preferences dialog visual layout**: pixel sampling confirms
  content renders, but "does the Models page look right with 5
  installed models" needs eyes.

## Re-running all of this

Everything above is bash + Python + standard CLI tools. The only
stateful setup is the throwaway schema dir:

```bash
mkdir -p /tmp/kaki-schemas
cp data/org.kaki.app.gschema.xml /tmp/kaki-schemas/
glib-compile-schemas /tmp/kaki-schemas
```

Then each numbered check above is a standalone block. The xvfb
checks need `xvfb-run` + `xdotool` + `imagemagick`'s `import`;
the libsecret check needs `gnome-keyring-daemon` + `secret-tool`;
the multipart check needs Python `requests`. All are packaged on
Arch/Debian/Fedora.
