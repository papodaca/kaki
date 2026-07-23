# Phase 9 — Internationalization (gettext / `po/`)

## Goal

Finish the GNOME gettext pipeline so all user-visible English is
extracted into `po/kaki.pot`, runtime locale binding works, broken
Vala string-template `_()` calls are fixed, and contributors know how
to mark strings and add locales. Non-English translations are
**out of scope** — English is the source language; other locales land
later via `LINGUAS` + `.po` files.

Kaki already has most of the scaffold from the GNOME Builder template:

- `Intl.bindtextdomain` / `bind_textdomain_codeset` / `textdomain` in
  `src/main.vala`
- `Config.GETTEXT_PACKAGE` / `LOCALEDIR` via `config.h` + `config.vapi`
- `i18n.gettext('kaki', preset: 'glib')` in `po/meson.build`
- `i18n.merge_file` for desktop + metainfo in `data/meson.build`
- Many UI strings already `translatable="yes"`; many Vala toasts already
  use `_()`

What is missing or broken: incomplete `POTFILES.in`, empty catalog
(no `kaki.pot`), no `Intl.setlocale`, ~24 `_(@"…$var…")` sites that
break gettext, unwrapped user-facing service errors, and no README
guidance for translators.

## Approach

Standard Meson + GNU gettext (glib preset). Do **not** introduce
i18next, gettext-rs wrappers, or a second catalog format.

| Piece | Role |
| --- | --- |
| `po/POTFILES.in` | Paths xgettext scans |
| `po/LINGUAS` | Locale codes to build/install (stay empty this phase) |
| `po/kaki.pot` | Generated template of English msgids (commit it) |
| `xx.po` | Per-locale translations (contributed later) |
| `ninja kaki-pot` / `kaki-update-po` | Maintainer targets from the build dir |

## Files to modify

### Runtime / extraction

- `src/main.vala` — add `Intl.setlocale (LocaleCategory.ALL, "");`
  before `bindtextdomain`.
- `po/POTFILES.in` — expand (sorted alphabetically) to cover every
  file with user-facing strings. Target list:

  ```
  data/org.kaki.app.desktop.in
  data/org.kaki.app.gschema.xml
  data/org.kaki.app.metainfo.xml.in
  src/application.vala
  src/services/local-source.vala
  src/services/model-downloader.vala
  src/services/recorder.vala
  src/services/remote-openai-source.vala
  src/services/secret-store.vala
  src/shortcuts-dialog.ui
  src/ui/preferences.ui
  src/ui/preferences.vala
  src/window.ui
  src/window.vala
  ```

  Drop `src/main.vala` if it still has no msgids after setlocale.
  Keep gschema/desktop/metainfo **as-is** (extract placeholder English;
  do not rewrite marketing copy in this phase).

- `po/LINGUAS` — leave empty aside from the existing sort comment;
  add a one-line note that contributors append locale codes here.

### String audit (Vala)

**Critical — rewrite all `_(@"…")` to static printf formats.** Vala
string templates interpolate before gettext, so msgids are unstable
and xgettext cannot extract them. Example:

```vala
// Bad
_("Set default model to $name")

// Good
_("Set default model to %s").printf (name)
```

Known hotspots (all in `src/ui/preferences.vala` today): default-model
toast, download progress/subtitle, download success/failure, models-dir
errors, kaki-signal install notes, API key / test-connection toasts,
and the custom `format_size` helpers.

Also:

- Wrap remaining **user-visible** service errors with `_()` /
  `_("%s").printf (…)` where they reach toasts or prepare failures,
  including at least:
  - `local-source.vala` — “No model configured…”
  - `remote-openai-source.vala` — missing endpoint/model messages
  - `recorder.vala` — missing pulsesrc/pipewiresrc, pipeline failures
  - `model-downloader.vala` — failures that surface via
    `_("Download failed: %s")`
  - `secret-store.vala` — libsecret item label `"Kaki API key"`
- Leave developer-only `warning()` / internal status codes untranslated
  unless they appear in UI.
- Replace custom `format_size` gettext unit strings with
  `GLib.format_size()` (already localized by glibc/GLib).
- Keep AboutDialog `translator-credits = _("translator-credits")`.
  Brand name “Kaki” stays as the English msgid (translators may leave
  it unchanged).

### UI / metadata

- Audit `.ui` files for any user-visible property missing
  `translatable="yes"` (`window.ui`, `preferences.ui`,
  `shortcuts-dialog.ui`). Most are already marked.
- Do **not** polish AppStream/desktop placeholder copy; only ensure
  extractable strings are listed in `POTFILES.in`.

### Docs

- `README.md` — add a **Translations** section covering:
  - Mark UI with `translatable="yes"`; Vala with `_("…")`,
    `C_("ctx", "…")`, `ngettext` when needed.
  - Never use `_(@"$x")` — use `_("%s").printf (x)`.
  - After string changes: `ninja -C build kaki-pot` (and
    `kaki-update-po` when locales exist).
  - Adding a language: append code to `po/LINGUAS`, run
    `ninja kaki-update-po`, translate `xx.po`, commit.
  - Testing: install to a prefix or use `meson devenv -C build` so
    `LOCALEDIR` resolves; run with `LANGUAGE=xx ./src/kaki`.
- `docs/plans/README.md` — add Phase 9 to the phase table and commit
  sequence.

## Files to create

- `po/kaki.pot` — generated via `ninja -C build kaki-pot` and committed.
- No `xx.po` files in this phase.

## Out of scope

- Writing non-English translations or filling `LINGUAS`.
- Rewriting placeholder AppStream / desktop marketing text.
- Weblate / Damned Lies / CI translation sync.
- Translating developer `warning()` logs.

## Verification

```bash
meson setup build   # or reuse existing
ninja -C build
ninja -C build kaki-pot

# Catalog exists and is non-empty
test -s po/kaki.pot
grep -q 'msgid "Preferences"' po/kaki.pot
grep -q 'msgid "No Model Loaded"' po/kaki.pot

# No broken template wrappers remain
! rg '_\(@"' src --glob '*.vala'

# Still builds / runs
./build/src/kaki
```

Optional runtime check after `ninja install` into a prefix (or
`meson devenv`): with a future `xx.po`, `LANGUAGE=xx` shows translated
UI. This phase only proves English extraction + setlocale + clean
`_()` patterns.

## Acceptance criteria

1. `Intl.setlocale` runs before textdomain bind in `main.vala`.
2. `POTFILES.in` lists every file that carries user-facing strings
   (UI, Vala toasts/dialogs, services that surface errors, gschema,
   desktop, metainfo).
3. Zero `_(@"…")` remaining in the tree.
4. `po/kaki.pot` exists, is committed, and contains UI + Vala +
   metadata strings.
5. `LINGUAS` has no locale codes yet.
6. README has a Translations section for contributors.
7. App still builds and runs.

## Commit sketch

Single focused commit (or split infra vs string-audit if the diff is
large):

1. `po/POTFILES.in` + `main.vala` setlocale + string-audit fixes +
   `po/kaki.pot` + README / plans README.
