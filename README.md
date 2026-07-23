# kaki

Speech-to-text GNOME app built with GTK4 + libadwaita in Vala. Uses
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for
local inference (HIP / Vulkan / CPU) and supports OpenAI-compatible
remote transcription APIs.

## Build & run

```bash
git submodule update --init --recursive
meson setup build                 # or -Dgpu_backend=cpu
ninja -C build
./build/src/kaki
```

Uninstalled runs need a compiled schema dir (see `AGENTS.md`).

## Tests

```bash
meson test -C build --print-errorlogs
```

Suites (see [`tests/README.md`](tests/README.md)):

| Suite | What |
| --- | --- |
| *(default metadata)* | desktop / schema / appstream validators |
| `unit` | GSettings, WAV sample, gresource paths |
| `integration` | libsecret, multipart contract, mock download + remote API |
| `ui` | Xvfb launch + preferences smoke (needs `xvfb-run`, `xdotool`) |
| `network` | HuggingFace catalog HEAD checks (opt-in / outbound) |

```bash
meson test -C build --suite unit
meson test -C build --suite integration
meson test -C build --suite ui
meson test -C build --suite network
```

Extra host packages for UI / secret tests are listed in `tests/README.md`.
Manual recipes that remain human-only (live rebind, real mic, etc.) are in
[`docs/testing.md`](docs/testing.md).
