# Testing

Kaki's automated suite is registered under `meson test`. It covers schemas,
gresources, secrets, HTTP contracts, and a headless preferences smoke —
without live mic capture, GPU inference, portal UI binding, or real OpenAI /
HuggingFace downloads (except the optional `network` suite).

## Automated entry point

```bash
meson setup build -Dgpu_backend=cpu
ninja -C build
meson test -C build --print-errorlogs
```

| Suite | Meson | Role |
| --- | --- | --- |
| Metadata | `data/meson.build` | desktop / schema / appstream validators |
| `unit` | `pytest tests/unit` | GSettings, WAV, gresource (§1, §7, §9 below) |
| `integration` | `pytest tests/integration` | secret-tool, multipart, mock download + remote (§6, §8) |
| `ui` | `pytest tests/ui` | Xvfb launch + preferences pixel smoke (§3, §4) |
| `network` | `pytest tests/network` | HuggingFace HEAD (§5) — opt-in |

```bash
meson test -C build --suite unit
meson test -C build --suite integration
meson test -C build --suite ui
meson test -C build --suite network
```

Host packages and a local venv recipe: [`tests/README.md`](../tests/README.md).
Missing Xvfb / keyring tools make the matching tests **skip**, not fail.

The numbered sections below are the human-readable source of truth for what
each automated check asserts (and how to re-run a single recipe by hand).

## Built-in meson metadata tests

Three tests in `data/meson.build` always run with `meson test`:

| Test | Tool | What it catches |
| --- | --- | --- |
| `Validate desktop file` | `desktop-file-validate` | Malformed `org.kaki.app.desktop.in` |
| `Validate schema file`  | `glib-compile-schemas --strict --dry-run` | Bad GSettings keys/types/defaults |
| `Validate appstream file` | `appstreamcli validate --no-net --explain` | Malformed metainfo XML |

## Manual recipes (Phase 4 origins)

Everything below was originally verified by hand under Xvfb / CLI tools.
Prefer `meson test` first; use these blocks when debugging a single failure.

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

All Phase 4+ keys appear with the right defaults
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

### 3. App launches + preferences dialog opens (no criticals)

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

Stderr must not contain `Gtk-CRITICAL` / `Adwaita-CRITICAL` / `GLib-CRITICAL`.

### 4. Dialog actually renders (pixel sampling)

```python
from PIL import Image
img = Image.open('/tmp/kaki-shots/02-preferences.png').convert('RGB')
print(img.size, len(set(img.getdata())))  # unique colors
for x, y, name in [(50,50,'header'), (640,200,'title'), (640,400,'content')]:
    print(name, img.getpixel((x, y)))
```

Expect a non-trivial unique-color count and a content-area pixel that is not
plain uninitialized black.

### 5. HuggingFace URLs still resolve

```bash
for url in \
  https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf \
  https://huggingface.co/handy-computer/whisper-base.en-gguf/resolve/main/whisper-base.en-Q8_0.gguf \
  https://huggingface.co/handy-computer/whisper-small.en-gguf/resolve/main/whisper-small.en-Q8_0.gguf
do
  curl -sI -L -o /dev/null -w "%{http_code} %{url_effective}\n" "$url"
done
```

### 6. libsecret round-trip via `secret-tool`

Schema name `org.kaki.app`, attribute `type=api-key` (see `secret-store.vala`):

```bash
eval $(echo 'password' | gnome-keyring-daemon --start --components=secrets)
echo 'password123' | secret-tool store --label='Kaki test' type api-key
secret-tool lookup type api-key                  # → password123
secret-tool search --all type api-key
secret-tool clear  type api-key
secret-tool lookup type api-key                  # → empty
```

### 7. Test-sample.wav is a valid silent WAV

```python
import wave
wf = wave.open('src/ui/test-sample.wav')
print(wf.getnchannels(), wf.getframerate(), wf.getnframes(),
      wf.getsampwidth() * 8)
# → 1 16000 1600 16
frames = wf.readframes(wf.getnframes())
print(sum(1 for b in frames if b != 0))   # → 0
```

### 8. Multipart POST construction is correct

Contract test (Python `requests` mirrors Preferences `on_test_connection`).
The integration suite also drives `RemoteOpenAISource` via
`kaki-remote-cli` against a mock server for the libsoup path.

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

### 9. gresource bundle contents

```bash
strings build/src/kaki | grep -E '^/org/kaki/app/'
```

Must include:

```
/org/kaki/app/preferences.ui
/org/kaki/app/shortcuts-dialog.ui
/org/kaki/app/test-sample.wav
/org/kaki/app/window.ui
```

## What is NOT tested

- **Live shortcut rebind**: needs interactive focus to confirm the accelerator
  starts recording. GSettings round-trip + `apply_shortcuts` are covered;
  end-to-end keypress → recorder still needs a human session.
- **Actual HuggingFace GGUF download**: the suite uses a tiny loopback payload
  and exercises `.part` → rename via `kaki-download-cli`. Full ~77 MB pulls
  stay manual / opt-in.
- **Real OpenAI API call**: needs a live key. Multipart contract + mock
  `{"text":"hello"}` parsing cover the fragile bits.
- **GStreamer mic / PipeWire capture**, **keystroke injection into a real
  editor**, **interactive portal GlobalShortcuts bind**.
- **Preferences visual polish** beyond pixel smoke ("Models page with N
  installed models looks right").
- **`subprojects/transcribe.cpp`** (has its own CI).

## Re-running

Prefer:

```bash
meson test -C build --suite unit --print-errorlogs
```

For a single manual recipe, the throwaway schema dir is still:

```bash
mkdir -p /tmp/kaki-schemas
cp data/org.kaki.app.gschema.xml /tmp/kaki-schemas/
glib-compile-schemas /tmp/kaki-schemas
```

UI checks need `xvfb-run` + `xdotool` + ImageMagick `import`; libsecret needs
`gnome-keyring-daemon` + `secret-tool`; multipart needs Python `requests`.
Distro package names: [`tests/README.md`](../tests/README.md).
