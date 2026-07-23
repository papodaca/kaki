# Kaki — Implementation Plan

Speech-to-text GNOME app built with GTK4 + libadwaita in Vala, using
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) as the
local inference engine and supporting OpenAI-compatible remote APIs.

## Scope summary

- In-app text view **and** keystroke-simulated dictation mode.
- User-selectable GPU backend: HIP (ROCm) / Vulkan / CPU / auto.
- No flatpak — system builds only.
- API key stored in libsecret.
- Global shortcuts via `xdg-desktop-portal` `GlobalShortcuts`, with a
  shell-script fallback the user binds to a custom keyboard shortcut.

## Phases

| # | File | Goal |
| --- | --- | --- |
| 0 | [`phase-0-scaffold-fix.md`](phase-0-scaffold-fix.md) | Fix scaffold bugs, drop flatpak, confirm build/run |
| 1 | [`phase-1-transcribe-submodule.md`](phase-1-transcribe-submodule.md) | Add transcribe.cpp submodule, wire HIP/Vulkan/CPU build, hand-write VAPI |
| 2 | [`phase-2-basic-transcription.md`](phase-2-basic-transcription.md) | GStreamer recorder + transcriber + main window |
| 3 | [`phase-3-dictation-mode.md`](phase-3-dictation-mode.md) | Keystroke injection (libei → ydotool → xdotool) + dictation toggle |
| 4 | [`phase-4-preferences-ui.md`](phase-4-preferences-ui.md) | Adw.PreferencesDialog with 4 pages (General / Models / Shortcuts / API) |
| 5 | [`phase-5-global-shortcuts.md`](phase-5-global-shortcuts.md) | xdg-desktop-portal GlobalShortcuts + shell-script fallback |
| 6 | [`phase-6-remote-openai-backend.md`](phase-6-remote-openai-backend.md) | OpenAI-compatible remote transcription backend |
| 7 | [`phase-7-testing-framework.md`](phase-7-testing-framework.md) | pytest + meson integration suite (automate `docs/testing.md`) |
| 8 | [`phase-8-shortcuts-dialog-sync.md`](phase-8-shortcuts-dialog-sync.md) | Expand Shortcuts dialog to match Preferences (+ Copy / Clear) |
| 9 | [`phase-9-i18n.md`](phase-9-i18n.md) | Finish gettext/`po/` pipeline, string audit, commit `kaki.pot` |

## Architectural decisions

- **Linking transcribe.cpp**: A1 — cmake subproject via meson `cmake.subproject()`
  + hand-written `src/vapi/transcribe.vapi` covering the subset of
  `include/transcribe.h` we use.
- **Audio capture**: B1 — GStreamer `pulsesrc`/`pipewiresrc` → `audioconvert`
  → `audioresample` → capsfilter (16 kHz mono F32LE) → `appsink`.
- **Keystroke injection**: C1 — libei → ydotool → xdotool fallback chain,
  picked at startup, overridable in settings.
- **API key**: libsecret (`Secret.Schema` named `kaki`, attribute
  `type=api-key`).
- **Models dir**: `~/.local/share/kaki/models/` (XDG_DATA_HOME), opened via
  `Gtk.FileLauncher` → Nautilus.

## Final dependencies

Existing: `gtk4`, `libadwaita-1 >= 1.4`, `glib-2.0`, `gobject-2.0`

New:
- `gstreamer-1.0`, `gstreamer-base-1.0`, `gstreamer-app-1.0`,
  `gstreamer-audio-1.0`
- `libsecret-1`
- `libsoup-3.0`
- `libei-1.0` (optional; falls back to `ydotool` / `xdotool`)

Subproject: `transcribe.cpp` (git submodule) — cmake static lib pulling
ggml (HIP/Vulkan/CPU).

External (runtime, optional): `rocminfo` (auto-detect), `ydotool`,
`xdotool`, `xdg-desktop-portal`.

## Build/run

```
meson setup build                                       # auto backend
ninja -C build && ./build/src/kaki

meson setup build -Dgpu_backend=hip -Damd_targets=gfx1100   # ROCm/HIP
meson setup build -Dgpu_backend=vulkan                     # Vulkan
meson setup build -Dgpu_backend=cpu                        # CPU
```

## Commit sequence

1. Phase 0 — scaffold fix + drop flatpak
2. Phase 1 — submodule + ROCm/HIP/Vulkan build + VAPI
3. Phase 2 — recorder + transcriber + window
4. Phase 3 — dictation mode (keystroke)
5. Phase 4 — preferences UI (General / Models / Shortcuts / API)
6. Phase 5 — global shortcuts + shell-script fallback
7. Phase 6 — OpenAI-compatible remote backend
8. Phase 7 — testing / integration framework (`meson test` + pytest)
9. Phase 8 — Shortcuts dialog coverage sync with Preferences
10. Phase 9 — gettext i18n (`po/kaki.pot`, string audit, contributor docs)

## Open follow-ups

1. Phase 5 shell-script fallback: user offered to share an example from
   another app.
2. Phase 4 "Test connection" — keep as a stub or wire to a real POST in
   the same phase.
3. Default GGUF download list — Whisper Tiny/Base/Small (English) only,
   or also include multilingual variants and Parakeet.
4. Phase 7 follow-ups: Vala unit tests for extracted WAV/multipart
   helpers; live shortcut-rebind / mic / portal E2E remain manual
   (see [`docs/testing.md`](../testing.md)).
5. Phase 8: expand `shortcuts-dialog.ui` so it lists all Preferences
   accelerators plus Copy / Clear (GSettings store already correct).
6. Phase 9: non-English `.po` locales (Weblate / Damned Lies optional);
   polish placeholder AppStream/desktop marketing copy separately.