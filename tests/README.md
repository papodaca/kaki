# Kaki tests

Pytest suites registered under `meson test`. They automate the recipes in
[`docs/testing.md`](../docs/testing.md) without live mic capture, GPU
inference, or real OpenAI / HuggingFace downloads (except the optional
`network` suite, which only HEADs catalog URLs).

## Host packages

| Need | Arch | Debian / Ubuntu | Fedora |
| --- | --- | --- | --- |
| pytest + Pillow + requests | `python-pytest python-pillow python-requests` | `python3-pytest python3-pil python3-requests` | `python3-pytest python3-pillow python3-requests` |
| UI suite | `xorg-server-xvfb xdotool imagemagick` | `xvfb xdotool imagemagick` | `xorg-x11-server-Xvfb xdotool ImageMagick` |
| Secret suite | `gnome-keyring libsecret` | `gnome-keyring libsecret-tools` | `gnome-keyring libsecret` |
| Metadata (already used by `data/`) | `desktop-file-utils appstream glib2` | same idea | same idea |

Alternatively, use a local venv (gitignored):

```bash
python3 -m venv tests/.venv
tests/.venv/bin/pip install -r tests/requirements.txt
```

`tests/meson.build` looks for `pytest` in `tests/.venv/bin` first.

## Run

```bash
meson setup build -Dgpu_backend=cpu
ninja -C build

# PR gate when deps are present
meson test -C build --print-errorlogs

# By suite
meson test -C build --suite unit
meson test -C build --suite integration
meson test -C build --suite ui
meson test -C build --suite network

# Direct pytest during development
tests/.venv/bin/pytest -q tests/unit
KAKI_BIN=build/src/kaki tests/.venv/bin/pytest -q tests/ui -m ui
```

Missing optional tools (Xvfb, keyring) make the corresponding tests **skip**,
not fail. The `network` suite is opt-in (outbound HTTP) and excluded from the
default CI job.
