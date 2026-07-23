# kaki

Speech-to-text GNOME app built with GTK4 + libadwaita in Vala. Uses
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for
local inference (HIP / Vulkan / CPU) and supports OpenAI-compatible
remote transcription APIs.

## Build & run

```bash
meson setup build
ninja -C build
./build/src/kaki
```

Tests:

```bash
meson test -C build
```

## Translations

Kaki uses GNU gettext via Meson's `i18n` module (`po/`). English is the
source language; other locales are contributed later.

- **UI files** (`.ui`): mark user-visible properties with
  `translatable="yes"`.
- **Vala**: wrap user-facing strings with `_("…")`, `C_("ctx", "…")`, or
  `ngettext` when needed.
- **Never** use `_(@"$x")` — Vala interpolates before gettext, so the
  msgid is unstable. Use `_("%s").printf (x)` instead.
- After changing strings, regenerate the template from the build dir:

  ```bash
  ninja -C build kaki-pot
  # when locales exist:
  ninja -C build kaki-update-po
  ```

- **Adding a language**: append the locale code to `po/LINGUAS`, run
  `ninja -C build kaki-update-po`, translate `po/xx.po`, and commit.
- **Testing a locale**: install to a prefix or use `meson devenv -C build`
  so `LOCALEDIR` resolves, then run with `LANGUAGE=xx ./src/kaki`.
