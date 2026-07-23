# Phase 7 — Testing / integration framework

## Goal

Replace the manual Phase 4 playbook in [`docs/testing.md`](../testing.md)
with an automated test suite registered under `meson test`, so
regressions in schemas, gresources, secrets, HTTP contracts, and the
preferences UI are caught without re-running bash snippets by hand.

Kaki currently ships **three** meson tests (desktop / schema /
appstream validators in `data/meson.build`) and **no** app-level suite.
This phase adds the suite; it does not attempt live mic capture, GPU
inference, portal UI binding, or real OpenAI / HuggingFace downloads.

## Approach

**Hybrid, pytest-first:**

| Layer | Tool | Role |
| --- | --- | --- |
| Metadata (existing) | meson + CLI validators | Static install files |
| Unit / contract | pytest | WAV, gresource, GSettings round-trip, multipart field shape |
| Integration | pytest + real daemons | libsecret via `secret-tool`, local HTTP for download / API |
| UI smoke | pytest + Xvfb + xdotool | Launch app, open preferences, no CRITICAL; pixel sample |
| Network (opt-in) | pytest marker `network` | HuggingFace HEAD checks |

Register each layer as a meson `test()` (or suite) so
`meson test -C build` remains the single entry point. Prefer exercising
**real** subprocesses and wire formats (same spirit as
`docs/testing.md`) over mocking GTK.

Optional follow-up (not required for this phase): Vala/GLib unit tests
for extracted pure helpers (WAV encode, multipart field list) once those
helpers are shared between `preferences.vala` and
`remote-openai-source.vala`.

## Files to create

```
tests/
  conftest.py                 # fixtures: kaki_bin, schema_dir, tmp XDG_*, http mock, xvfb, keyring
  requirements.txt            # pytest, pillow, requests
  README.md                   # local deps + how to run
  unit/
    test_gsettings.py         # docs/testing.md §1
    test_wav_sample.py        # §7
    test_gresource.py         # §9
  integration/
    test_secret_store.py      # §6
    test_multipart_shape.py   # §8 (Python contract of expected wire format)
    test_model_downloader.py  # local HTTP tiny payload; .part → rename
    test_remote_openai_mock.py# mock /v1/audio/transcriptions response shape
  ui/
    test_app_smoke.py         # §3 launch + Ctrl+, no CRITICAL
    test_preferences_render.py# §4 screenshot + unique-color / pixel sample
  network/
    test_hf_urls.py           # §5 HEAD — @pytest.mark.network
tests/meson.build
```

## Files to modify

- `meson.build` — `subdir('tests')` after `data` / `src` (binary must
  exist for UI / gresource tests that inspect `build/src/kaki`).
- `docs/testing.md` — lead with automated suite; keep the numbered
  recipes as the human-readable source of truth for what each test
  asserts; update “What is NOT tested” and “Re-running”.
- `docs/plans/README.md` — add Phase 7 to the phase table and commit
  sequence.
- `README.md` (project root) — document `meson test` suites and the
  extra host packages for UI / secret tests.

## Architecture

```
meson test -C build
├── Validate desktop / schema / appstream     (existing, data/meson.build)
├── suite: unit         → pytest tests/unit
├── suite: integration  → pytest tests/integration
├── suite: ui           → pytest tests/ui          (serial, long timeout)
└── suite: network      → pytest tests/network     (optional / CI nightly)
```

### Fixtures (`tests/conftest.py`)

| Fixture | Behavior |
| --- | --- |
| `kaki_bin` | Path to `build/src/kaki` (from meson env or `MESON_BUILD_ROOT`) |
| `schema_dir` | Throwaway dir: copy `data/org.kaki.app.gschema.xml`, `glib-compile-schemas`; set `GSETTINGS_SCHEMA_DIR` |
| `xdg_home` | Temp `HOME` / `XDG_DATA_HOME` / `XDG_CONFIG_HOME` so models and dconf stay isolated |
| `http_server` | Threaded `http.server` (or pytest-httpserver) on `127.0.0.1`; yield base URL + request log |
| `keyring` | Session-scoped: start `gnome-keyring-daemon --components=secrets` when available; skip otherwise |
| `xvfb` | Wrap UI tests; set `GDK_BACKEND=x11` |

Markers:

- `@pytest.mark.network` — needs outbound HTTP; excluded from default CI.
- `@pytest.mark.ui` — needs Xvfb + xdotool (+ ImageMagick/`import` or
  Pillow grab via `import` dump).
- `@pytest.mark.secret` — needs keyring + `secret-tool`.

### `tests/meson.build` sketch

```meson
pytest = find_program('pytest', required: false, disabler: true)
tests_dir = meson.current_source_dir()

test_env = environment()
test_env.set('KAKI_BIN', kaki.full_path())   # executable from src/meson.build
test_env.set('KAKI_SOURCE_ROOT', meson.project_source_root())

pytest_args = ['-q', '--tb=short']

test('pytest-unit', pytest,
  args: pytest_args + [tests_dir / 'unit'],
  env: test_env,
  suite: 'unit',
  workdir: meson.project_source_root(),
  depends: [kaki],
)

test('pytest-integration', pytest,
  args: pytest_args + [tests_dir / 'integration'],
  env: test_env,
  suite: 'integration',
  workdir: meson.project_source_root(),
  depends: [kaki],
  is_parallel: false,
  timeout: 120,
)

test('pytest-ui', pytest,
  args: pytest_args + ['-m', 'ui', tests_dir / 'ui'],
  env: test_env,
  suite: 'ui',
  workdir: meson.project_source_root(),
  depends: [kaki],
  is_parallel: false,
  timeout: 180,
)

test('pytest-network', pytest,
  args: pytest_args + ['-m', 'network', tests_dir / 'network'],
  env: test_env,
  suite: 'network',
  workdir: meson.project_source_root(),
  timeout: 60,
)
```

Expose the `kaki` executable target from `src/meson.build` (assign to a
variable the root/`tests` subdir can see), or pass the binary path via
`meson.project_build_root() / 'src' / 'kaki'`.

## Test inventory (milestone mapping)

### A — Scaffold + unit (automate docs §1, §7, §9)

1. **GSettings** — compile schema into temp dir; `gsettings
   list-recursively org.kaki.app` contains expected keys/defaults;
   set / get / reset `shortcut-record`.
2. **WAV sample** — `src/ui/test-sample.wav` is mono, 16 kHz, 1600
   frames, 16-bit, all-zero PCM.
3. **gresource** — `gresource list` on the compiled resource (or
   `strings` on the binary) includes
   `/org/kaki/app/{preferences,shortcuts-dialog,window}.ui` and
   `test-sample.wav`.

### B — Integration (docs §6, §8 + service seams)

4. **libsecret** — store / lookup / search / clear with
   `type=api-key` under a fresh keyring (same schema as
   `secret-store.vala`).
5. **Multipart contract** — local HTTP server asserts body contains
   `name="file"`, `name="model"`, `name="response_format"`,
   `name="temperature"`, `filename="sample.wav"`, `audio/wav`, and
   `Authorization: Bearer …` (as in docs §8).
6. **ModelDownloader** — serve a tiny file over loopback; run the
   downloader (subprocess helper or Vala test binary if needed) and
   assert destination exists, no leftover `.part`, size matches.
7. **Remote OpenAI mock** — mock endpoint returns `{"text":"hello"}`;
   assert client accepts 200 and parses text (drive
   `RemoteOpenAISource` or preferences Test connection once a
   libsoup path is available — see note below).

**Wire-format note:** docs §8 validates the expected multipart with
Python `requests`, not libsoup. Milestone A/B keep that as a
**contract** test. Prefer adding a libsoup-backed check in the same
phase when practical: either (a) Xvfb-driven “Test connection” against
the mock server, or (b) extract shared multipart construction into a
helper and call it from a small Vala test executable. Do not stop at
Python-only if the Vala path is easy to reach.

### C — UI smoke (docs §3, §4)

8. **App launch + preferences** — under Xvfb, start `kaki`, send
   `ctrl+comma`, kill cleanly; stderr must not contain
   `Gtk-CRITICAL` / `Adwaita-CRITICAL` / `GLib-CRITICAL`.
9. **Preferences renders** — screenshot after open; unique color count
   above a floor; sample a content-area pixel that is not plain
   background (heuristic from docs §4).

### D — Network + CI (docs §5 + polish)

10. **HF HEAD** — catalog URLs return HTTP 200 after redirects;
    marked `network`, not part of default gate.
11. **GitHub Actions** — build with `-Dgpu_backend=cpu` (fast, no
    ROCm/Vulkan on runners); run meson suites `unit` + `integration`;
    run `ui` if the image has Xvfb; exclude or nightly `network`.

## Explicit non-goals (this phase)

- Downloading real GGUFs or calling a live OpenAI key.
- GStreamer mic / PipeWire capture.
- Keystroke injection into a real editor (`Keystroke` backends).
- Interactive `xdg-desktop-portal` GlobalShortcuts bind.
- “Models page with N installed models looks right” beyond pixel smoke.
- Testing `subprojects/transcribe.cpp` (it has its own CI).
- Live shortcut rebind E2E (still needs a focused human session; keep
  in docs “What is NOT tested”).

## Host dependencies

| Package | Used by |
| --- | --- |
| `pytest`, `python-pillow`, `python-requests` | all pytest suites |
| `xvfb` / `xvfb-run`, `xdotool` | UI suite |
| ImageMagick `import` (or equivalent) | preferences screenshot |
| `gnome-keyring`, `secret-tool` | secret suite |
| Existing: `desktop-file-validate`, `appstreamcli`, `glib-compile-schemas` | metadata |

Document distro package names in `tests/README.md` (Arch / Debian /
Fedora), mirroring the note at the end of `docs/testing.md`.

## How to run (target UX)

```bash
meson setup build -Dgpu_backend=cpu
ninja -C build

# everything that should gate a PR (when deps present)
meson test -C build --print-errorlogs

# by suite
meson test -C build --suite unit
meson test -C build --suite integration
meson test -C build --suite ui
meson test -C build --suite network

# or invoke pytest directly during development
pytest -q tests/unit
KAKI_BIN=build/src/kaki pytest -q tests/ui -m ui
```

## Implementation order

1. Scaffold `tests/` + `conftest.py` + `tests/meson.build` + root
   `subdir('tests')`; one trivial passing unit test to prove wiring.
2. Port docs §1, §7, §9 (unit).
3. Port §6, §8; add mock download + remote response tests
   (integration).
4. Port §3, §4 (ui); skip cleanly when Xvfb missing.
5. Port §5 with `network` marker.
6. Rewrite `docs/testing.md` intro + root `README.md` test section;
   add `.github/workflows/ci.yml` (CPU build + unit/integration).
7. Commit.

## Verification

1. Fresh clone / clean build: `ninja -C build && meson test -C build
   --suite unit` passes with only pytest + schema tools installed.
2. With keyring tools: `--suite integration` passes; without them,
   secret tests **skip** (not fail).
3. With Xvfb + xdotool: `--suite ui` passes; without them, UI tests
   skip.
4. Deliberate break: remove `alias=` for `preferences.ui` in
   `kaki.gresource.xml` → UI or gresource test fails.
5. Deliberate break: change a GSettings default → gsettings unit test
   fails.
6. `docs/testing.md` describes the automated path first; manual gaps
   section still lists live rebind / real download / real API / visual
   polish.

## Commit

```
Phase 7: testing / integration framework

- tests/: pytest suites (unit, integration, ui, network)
- tests/meson.build: register suites under meson test
- Automate docs/testing.md checks (GSettings, WAV, gresource,
  secret-tool, multipart contract, Xvfb preferences smoke)
- Add mock HTTP coverage for model download + remote transcription shape
- docs/testing.md + README: automated entry point; CI workflow (CPU)
```
