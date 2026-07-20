# Kaki — Porting Report: Windows and macOS

Assessment of what it would take to port Kaki (currently a
GNOME/GTK4/libadwaita Vala app targeting Linux) to **Windows** and
**macOS**, measured against the seven-phase implementation plan in
[`README.md`](README.md) and the per-phase docs in this directory.

The report is **analysis + recommended architecture changes** — it does
not prescribe a work sequence. Effort ratings and open questions are at
the end.

## 1. Scope & method

We assessed:

- The 7 implementation phases (0–6) as written in
  `docs/plans/phase-*.md`.
- The 11 runtime/build dependencies listed in
  [`README.md`](README.md) §"Final dependencies".
- The current scaffold state in `meson.build`, `src/meson.build`,
  `src/application.vala`.

Sources consulted (grounding):

- GTK4 / libadwaita portability — [GNOME Discourse: libadwaita
  multiplatform](https://discourse.gnome.org/t/is-libadwaita-suitable-for-multiplatform-apps/18497),
  [GTK4 macOS docs](https://docs.gtk.org/gtk4/osx.html),
  [MSYS2 libadwaita package](https://packages.msys2.org/packages/mingw-w64-x86_64-libadwaita),
  [swift-adwaita macOS example](https://github.com/makoni/swift-adwaita/commit/7c5d86da0bbf8f83817944d0f53ed4819afa537f).
- transcribe.cpp / ggml backends —
  [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp/),
  [whisper.cpp cross-platform](https://deepwiki.com/ggml-org/whisper.cpp/4.2-cross-platform-support),
  [whisper.cpp README](https://github.com/ggml-org/whisper.cpp).
- Audio capture —
  [wasapi2src](https://gstreamer.freedesktop.org/documentation/wasapi2/wasapi2src.html),
  [osxaudiosrc](https://gstreamer.freedesktop.org/documentation/osxaudio/osxaudiosrc.html),
  [Centicular audio device switching](https://centricular.com/devlog/2025-08/Perfect-Audio-Device-Switching/).
- Secret storage —
  [libsecret NEWS 0.20.0 "file backend"](https://github.com/GNOME/libsecret/blob/main/NEWS),
  [hrantzsch/keychain](https://github.com/hrantzsch/keychain/),
  [jgaa/SafeKeeping](https://github.com/jgaa/SafeKeeping),
  [MSYS2 libsecret](https://packages.msys2.org/packages/mingw-w64-ucrt-x86_64-libsecret).
- Global shortcuts & keystroke injection —
  [global-hotkey Rust crate](https://crates.io/crates/global-hotkey),
  [Nucleus hotkey matrix](https://nucleusframework.dev/runtime/global-hotkey/),
  [golang-design/hotkey](https://github.com/golang-design/hotkey),
  [Win32 SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
  [macOS TCC / CGEventPost](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html),
  [Apple Developer Forums: CGEventTap](https://origin-devforums.apple.com/forums/thread/707680).
- xdg-desktop-portal & libei —
  [flatpak/xdg-desktop-portal](https://github.com/flatpak/xdg-desktop-portal),
  [libei](https://chromium.googlesource.com/external/gitlab.freedesktop.org/libinput/libei/+/refs/heads/main).
- Build toolchain —
  [Vala Windows cross-build](https://docs.vala.dev/sample-code/other/win32-cross-build.html),
  [meson Cross-compilation](https://mesonbuild.com/Cross-compilation.html),
  [meson Vala compiler source](https://github.com/mesonbuild/meson/blob/98f58024/mesonbuild/compilers/vala.py).
- macOS app distribution —
  [swift-adwaita DemoApp Xcode example](https://github.com/makoni/swift-adwaita/commit/7c5d86da0bbf8f83817944d0f53ed4819afa537f).

## 2. Dependency portability matrix

| Component | Linux | Windows | macOS | Notes / source |
|---|---|---|---|---|
| `gtk4` | Yes | Yes (MSYS2 MinGW, or MSVC via gvsbuild) | Yes (Homebrew, Quartz backend) | [GTK4 macOS docs](https://docs.gtk.org/gtk4/osx.html); [GNOME Discourse](https://discourse.gnome.org/t/is-gtk-4-cross-platform/6144/2) |
| `libadwaita-1 >= 1.4` | Yes | Yes (MSYS2 1.9.x) | Yes (Homebrew) | [MSYS2 libadwaita](https://packages.msys2.org/packages/mingw-w64-x86_64-libadwaita). libadwaita has *native* (non-portal) dark-mode on Win/macOS per [Discourse](https://discourse.gnome.org/t/is-libadwaita-suitable-for-multiplatform-apps/18497). Visual style is GNOME HIG on every platform — not native Cocoa/Win32 chrome. |
| Vala + meson | Yes | Yes (MSYS2 native; MinGW cross-file from Linux) | Yes (Homebrew) | [docs.vala.dev/win32-cross-build](https://docs.vala.dev/sample-code/other/win32-cross-build.html); [meson Cross-compilation](https://mesonbuild.com/Cross-compilation.html). valac emits C, so cross-compilation is just a MinGW cross-file + Windows-side pkg-config tree. |
| `gstreamer-1.0` + base/app/audio | Yes | Yes (MSYS2) | Yes (Homebrew) | Pure GLib, fully portable. |
| `gstreamer` audio src element | `pulsesrc` / `pipewiresrc` | `wasapi2src` | `osxaudiosrc` | [wasapi2src](https://gstreamer.freedesktop.org/documentation/wasapi2/wasapi2src.html), [osxaudiosrc](https://gstreamer.freedesktop.org/documentation/osxaudio/osxaudiosrc.html). The rest of the pipeline (`audioconvert`/`audioresample`/`capsfilter`/`appsink`) is portable as-is. |
| `libsoup-3.0` | Yes | Yes | Yes | Pure GLib. |
| `libsecret-1` | Yes (Secret Service via D-Bus) | Partial — file backend only (no Secret Service on Win) | Partial — file backend only (no Keychain backend) | [libsecret NEWS 0.20.0 "local-storage backend"](https://github.com/GNOME/libsecret/blob/main/NEWS). MSYS2 builds libsecret, but at runtime only the file backend is usable on Win/macOS — **not** Windows Credential Manager or macOS Keychain. Native backends require a separate library (see §6). |
| `libei-1.0` | Yes (optional) | **No** | **No** | libei is Linux-only, gated through `xdg-desktop-portal` RemoteDesktop on Wayland. [libei docs](https://chromium.googlesource.com/external/gitlab.freedesktop.org/libinput/libei/+/refs/heads/main). |
| `ydotool` / `xdotool` (runtime) | Yes | **No** | **No** | Linux-only CLI tools. |
| `xdg-desktop-portal` GlobalShortcuts | Yes | **No** | **No** | [flatpak/xdg-desktop-portal](https://github.com/flatpak/xdg-desktop-portal) is Linux-desktop-only. |
| `rocminfo` / HIP | Yes | **No** (ROCm is Linux-only) | **No** | [transcribe.cpp README](https://github.com/handy-computer/transcribe.cpp/). |
| transcribe.cpp / ggml GPU backend | HIP / Vulkan / CPU | **CUDA / Vulkan / CPU** | **Metal** (auto on Apple Silicon) / Vulkan-via-MoltenVK / CPU | [transcribe.cpp README](https://github.com/handy-computer/transcribe.cpp/), [whisper.cpp cross-platform](https://deepwiki.com/ggml-org/whisper.cpp/4.2-cross-platform-support). Metal is auto-enabled on Apple Silicon. CUDA requires the CUDA toolkit on Windows. Vulkan on macOS needs `brew install vulkan-loader shaderc molten-vk`. |
| `Unix.signal_add` / `kaki-signal.sh` (Phase 5 fallback) | Yes | **No** (no POSIX signals) | Partial (POSIX exists, but not idiomatic and no `XDG_RUNTIME_DIR` convention) | Phase 5 plan; needs a Windows-specific IPC path. |
| `.desktop` / `gnome.post_install` | Yes | N/A (.app / .lnk / installer) | N/A (.app bundle + Info.plist) | `meson.build` line 30. |

## 3. Per-phase porting analysis

### Phase 0 — Scaffold fix ✅ portable as-is

`src/application.vala` uses `Adw.Application`, `Adw.AboutDialog`,
`Adw.ShortcutsDialog`, accelerators — all portable. The empty-state
`AdwStatusPage` works on every GTK4 backend. **No porting work.**

Caveat: `meson.build` line 30 calls `gnome.post_install(...)` with
`glib_compile_schemas`, `gtk_update_icon_cache`,
`update_desktop_database` — these are Linux-distribution helpers and
should be gated to Linux only (they no-op or fail elsewhere).

### Phase 1 — transcribe.cpp + GPU backends ⚠️ needs abstraction

The plan hardcodes `hip | vulkan | cpu | auto` and auto-detects via
`rocminfo`/`hipconfig`. This is Linux-only:

- `hip` and `rocminfo` do not exist on Windows or macOS.
- macOS needs a **`metal`** option (auto-enabled on Apple Silicon per
  the transcribe.cpp README).
- Windows needs a **`cuda`** option (CUDA toolkit on PATH).
- `vulkan` works on Windows natively and on macOS via MoltenVK
  (`brew install vulkan-loader shaderc molten-vk`).

Recommended `meson_options.txt`:

```
choices: ['auto', 'hip', 'cuda', 'vulkan', 'metal', 'cpu']
```

The `auto` branch needs platform-aware logic: check `host_machine.system()`
and probe the appropriate toolchain (`rocminfo` on Linux+AMD, `nvcc` on
Linux/Windows+NVIDIA, Metal SDK on macOS, Vulkan everywhere). The
VAPI (`src/vapi/transcribe.vapi`) is platform-independent — only the
meson glue changes.

### Phase 2 — GStreamer recorder + transcriber ⚠️ needs src-element switch

Only the GStreamer source element is platform-specific:

- Linux: `pulsesrc` or `pipewiresrc`
- Windows: `wasapi2src` (Windows 10+, GStreamer Bad Plugins)
- macOS: `osxaudiosrc` (GStreamer Good Plugins)

The rest of the pipeline (`audioconvert` → `audioresample` →
`capsfilter` 16 kHz mono F32LE → `appsink`) is portable. The
`Recorder.vala` class needs to pick the src element at construction
time, either by `host_machine.system()` at build time or by runtime
probe (`Gst.Registry` feature lookup).

The `Transcriber` Vala class is a pure async wrapper over the VAPI —
fully portable.

The models directory path (`~/.local/share/kaki/models/`) is
**hardcoded Linux** and should be
`GLib.Environment.get_user_data_dir() + "/kaki/models/"`. This is also
a latent bug on Linux (it ignores `XDG_DATA_HOME`). On Windows that
resolves to `%LOCALAPPDATA%`; on macOS to `~/Library/Application Support`.

### Phase 3 — Dictation mode (keystroke injection) ❌ major blocker

The entire `libei → ydotool → xdotool` fallback chain is Linux-only.
On Windows and macOS this phase needs platform-native backends:

- **Windows**: `SendInput()` from `user32.dll`. No permission
  required for normal user sessions (UIPI blocks injection into
  higher-integrity windows only). UTF-16 keystrokes via
  `KEYEVENTF_UNICODE`. ([Win32 SendInput docs](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput))
- **macOS**: `CGEventCreateKeyboardEvent` +
  `CGEventPost(kCGSessionEventTap, ...)`. Requires both
  **Accessibility** and **Input Monitoring** TCC grants — the app
  must be signed and notarized, and the user must approve it in
  System Settings → Privacy & Security. ([macOS TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html))

The `Backend` enum in `src/services/keystroke.vala` needs `SENDINPUT`
(Win) and `CGEVENT` (mac) cases. The current `AUTO → LIBEI → YDOTOOL
→ XDOTOOL → NONE` ladder becomes platform-conditional.

The `window.minimize()` + 250 ms timeout + focus-previous-window flow
in Phase 3 is also Linux-WM-specific. On macOS we can use
`NSApplication.hideOtherApplications` or simply `window.minimize()`
(GTK4 Quartz maps it to `NSWindow.minimize`). On Windows,
`gtk_window_minimize` maps to `ShowWindow(SW_MINIMIZE)`. Focus
restoration should be tested per-platform.

### Phase 4 — Preferences UI ⚠️ secret store is the issue

The `Adw.PreferencesDialog` UI itself is portable. The four pages:

- **General**: portable, except `gpu-backend` ComboRow needs the new
  `cuda`/`metal` choices from §3 Phase 1.
- **Models**: `~/.local/share/kaki/models/` needs the
  `get_user_data_dir()` fix. `Gtk.FileLauncher` → Nautilus is
  Linux-specific; on Windows it opens Explorer, on macOS it opens
  Finder via the same `Gtk.FileLauncher` API (portable).
- **Shortcuts**: default accelerators use `<Control>...` everywhere.
  macOS convention is `<Meta>...` (Cmd). The defaults table in
  `phase-4-preferences-ui.md` should switch on platform at first
  run, or hardcode per-platform defaults.
- **API**: **`SecretStore` is the blocker.** libsecret has no
  native backend for Windows Credential Manager or macOS Keychain
  — only its file backend, which is *not* what users expect.
  Recommended: replace `SecretStore` with a thin interface and
  three backends:
  - Linux: `libsecret` (as today)
  - Windows: `Advapi32` `CredWrite`/`CredRead` (Credential Manager)
  - macOS: Security framework `SecItemAdd`/`SecItemCopyMatching`
    (Keychain)
  - Cross-platform references: [hrantzsch/keychain](https://github.com/hrantzsch/keychain/),
    [jgaa/SafeKeeping](https://github.com/jgaa/SafeKeeping) — both
    do exactly this in C++.

  Note: Windows Credential Manager has a 512-byte per-item limit
  ([SafeKeeping README](https://github.com/jgaa/SafeKeeping)) — an
  OpenAI API key (≤200 chars) is fine, but document the limit.

The `model-downloader.vala` libsoup-3 code is portable as-is.

### Phase 5 — Global shortcuts ❌ major blocker

Two paths, both Linux-only:

1. **`org.freedesktop.portal.GlobalShortcuts`** — Linux-only (see
   §2). Windows and macOS need native equivalents:
   - **Windows**: `RegisterHotKey`/`UnregisterHotKey` on a dedicated
     message-loop thread, with `MOD_NOREPEAT`. ([Nucleus hotkey
     matrix](https://nucleusframework.dev/runtime/global-hotkey/))
   - **macOS**: Carbon `RegisterEventHotKey`/
     `UnregisterEventHotKey`, handler on the main run loop. Note:
     Carbon is technically deprecated but this is still the only
     supported API for system-wide hotkeys; media keys are not
     exposed. ([global-hotkey](https://crates.io/crates/global-hotkey),
     [golang-design/hotkey](https://github.com/golang-design/hotkey))
   - macOS hotkey delivery requires Accessibility permission
     (same TCC grant as Phase 3).

2. **`kaki-signal` shell script + SIGUSR1**:
   - Linux: works as written.
   - macOS: POSIX signals work, but `XDG_RUNTIME_DIR` is not a
     macOS convention. Use `/tmp/kaki.pid` directly, or better a
     per-user `~/Library/Application Support/kaki/kaki.pid`.
   - Windows: **no POSIX signals.** Replace with a **named pipe**
     (`\\.\pipe\kaki`) or a local TCP socket the app listens on,
     and a small `kaki-signal.exe` that writes a single byte.

The `Unix.signal_add` calls in `application.vala` (Phase 5 plan)
need to be gated to non-Windows builds, with the Windows path using
`Gio.SocketListener` or a `Gio.Win32InputStream` over a named pipe.

### Phase 6 — OpenAI-compatible remote backend ✅ portable as-is

Pure `libsoup-3.0` + a hand-written RIFF/WAV encoder. No
platform-specific code. The `TranscriptionSource` interface and
`RemoteOpenAISource` class port unchanged. **No porting work.**

## 4. Windows deep-dive

### Build: MSVC vs MinGW

GTK4 upstream actively supports both MSVC and MinGW. Tradeoff:

| | MSVC | MinGW-w64 (MSYS2 UCRT64) |
|---|---|---|
| GTK4 / libadwaita | Yes via [gvsbuild](https://github.com/wingtk/gvsbuild) | Yes via MSYS2 packages |
| Vala compiler | Yes (valac runs under MSYS2 even when targeting MSVC) | Yes (native) |
| transcribe.cpp / ggml | Yes (ggml has MSVC build matrix) | Yes (ggml has MinGW build) |
| meson + Ninja | Yes | Yes |
| VAPI toolchain ergonomics | Awkward — valac expects pkg-config + .vapi files in standard dirs; MSVC toolchain discovery is fiddly | Excellent — pkg-config and .vapi "just work" |
| Linking C++ static lib (transcribe.cpp) | Yes, but `/MT` vs `/MD` runtime must match | Yes, libstdc++ just works |
| End-user redistributables | MSVC runtime redistributable needed | MinGW runtime DLLs (or static-link them) |
| Installer tooling | WiX / MSIX / NSIS — all support MSVC | WiX / MSIX / NSIS — all support MinGW |

**Recommendation for first port**: MSYS2 UCRT64 MinGW. The Vala +
VAPI + pkg-config story is identical to Linux, so the porting
diff stays minimal. MSVC is a viable stretch goal for users who
want to embed Kaki into an existing MSVC-based product, but it
doubles the build-maintenance burden.

### Windows ARM64

ggml has ARM NEON kernels; transcribe.cpp's CPU path works on
ARM64. CUDA is unavailable on ARM64 Windows. Vulkan support on
ARM64 Windows depends on the GPU driver (Qualcomm Adreno has a
Vulkan driver; the Surface Pro X line is the main target).

Recommendation: ship **CPU-only** ARM64 builds initially; add
Vulkan later if there is demand and a test device. Add a CI
matrix row for `windows-arm64` building with
`-Dgpu_backend=cpu`.

### Platform services on Windows

- **Audio capture**: `wasapi2src` (GStreamer Bad). Set
  `low-latency=true` for dictation. Device switching via
  `GstDeviceMonitor` works as of recent GStreamer
  ([Centicular devlog](https://centricular.com/devlog/2025-08/Perfect-Audio-Device-Switching/)).
- **Keystroke injection**: `SendInput` with `INPUT_KEYBOARD`
  structures, `KEYEVENTF_UNICODE` for non-ASCII. No permission
  for normal user sessions. UIPI blocks injection into elevated
  windows — document this.
- **Global shortcuts**: `RegisterHotKey` on a dedicated
  message-loop thread, `MOD_NOREPEAT` default. Window handle
  needed; a hidden `GtkWindow` works.
- **Secret store**: `Advapi32` `CredWrite`/`CredRead` with
  `CRED_TYPE_GENERIC`. 512-byte payload limit per item.
- **IPC (replacing SIGUSR1)**: named pipe
  `\\.\pipe\kaki\control` with a 1-byte command protocol. Or a
  local TCP listener on 127.0.0.1 with an ephemeral port written
  to `%LOCALAPPDATA%\kaki\port`.
- **Models dir**: `%LOCALAPPDATA%\kaki\models\` via
  `g_get_user_data_dir()`.

### Distribution & packaging on Windows

- **MSYS2 is not user-friendly.** Ship a self-contained installer.
- Build with MinGW, then bundle:
  - `kaki.exe`
  - GTK4, libadwaita, GLib, Pango, HarfBuzz, cairo, gdk-pixbuf,
    librsvg, graphene, fribidi, ICU, libffi, gettext-runtime
    DLLs (≈50–80 MB)
  - GStreamer runtime DLLs + the `wasapi2`, `audioconvert`,
    `audioresample`, `appsink` plugins (the `gstreamer` runtime
    + a curated plugin set)
  - libsoup-3 + libpsl + nghttp2 DLLs
  - transcribe.cpp static lib is already linked in; the ggml
    backend (CUDA/Vulkan) needs `cudart.dll` / `vulkan-1.dll`
    shipped or expected from the GPU driver
  - Adwaita icon theme (curated subset: `scalable/actions` +
    `symbolic`)
  - `gschemas.compiled` for Kaki's own GSchema
- Installer options: **NSIS** (script-based, lightweight),
  **MSIX** (modern, sandboxed, Store-compatible but Store is
  optional), **WiX** (enterprise-friendly). MSIX is the
  recommended target for Windows 10/11; NSIS for older systems.
- `meson --wrap-db` or `gvsbuild` produces the DLL tree; the
  installer script copies it next to `kaki.exe`.

## 5. macOS deep-dive

### Build: Homebrew

```bash
brew install gtk4 libadwaita meson vala gstreamer \
  libsoup pkgconf
# Optional backends:
brew install vulkan-loader shaderc molten-vk   # for Vulkan-via-MoltenVK
# CUDA is not available on Apple Silicon; Metal is auto-detected
```

`meson setup build && ninja -C build` works the same as on Linux.
The GTK4 Quartz backend is used (not native Cocoa); HeaderBar /
Toast / Adwaita chrome will look like libadwaita on macOS, not
native Mac windows. This is acceptable for a developer-oriented
tool but is a UX caveat worth documenting to users.

### App Store vs Developer ID tradeoff

This is the most consequential macOS decision:

| | Mac App Store (sandboxed) | Developer ID + notarize |
|---|---|---|
| Distribution | App Store | Direct download / DMG |
| App Sandbox | **Required** | Optional (recommended off) |
| Library validation | Required (Hardened Runtime) | Optional |
| Accessibility (Phase 3 keystroke injection) | **Blocked by sandbox** — sandboxed apps cannot get `kTCCServiceAccessibility` | Allowed; user must grant in System Settings |
| Input Monitoring (Phase 5 CGEventTap) | Allowed in sandbox per Apple Developer Forums, but requires entitlement + app review | Allowed; user must grant |
| Global hotkeys (Carbon `RegisterEventHotKey`) | Allowed in sandbox | Allowed |
| Bundling Homebrew dylibs | Blocked by library validation | Works after re-signing |
| GStreamer dynamic plugins | Works if bundled inside the app container | Works if bundled in `Contents/Frameworks` |
| Notarization | Required (handled by App Store) | Required (manual via `notarytool`) |
| User experience | One-click install | DMG drag-to-Applications |

**Conclusion: the Mac App Store is not viable for the full Kaki
feature set.** Dictation mode (Phase 3) requires Accessibility,
which the sandbox blocks. The minimum-viable Mac App Store build
would have to disable dictation mode entirely — leaving only
batch transcription + OpenAI remote + global hotkeys (which are
sandbox-allowed). Recommended path:

- **Primary**: Developer ID + notarization + **disable App
  Sandbox** (full feature set). Distribute as a DMG.
- **Optional future**: a separate App Store build with dictation
  disabled, gated by a `macos_app_store` meson option that
  removes the `CGEvent` keystroke path at compile time.

### .app bundle construction

GTK provides no packaging facility on macOS
([GTK4 macOS docs](https://docs.gtk.org/gtk4/osx.html)). The
recommended recipe, following the [swift-adwaita Xcode
example](https://github.com/makoni/swift-adwaita/commit/7c5d86da0bbf8f83817944d0f53ed4819afa537f):

1. **Build the binary** with meson + Homebrew deps.
2. **Vendor the dylibs** into `Kaki.app/Contents/Frameworks/`
   and rewrite install names:
   ```bash
   brew install dylibbundler
   dylibbundler -od -b -x Kaki.app/Contents/MacOS/kaki \
     -d Kaki.app/Contents/Frameworks/ -p @rpath/
   ```
3. **Bundle GSettings schemas**: copy
   `/opt/homebrew/share/glib-2.0/schemas/gschemas.compiled` and
   Kaki's own compiled schema into
   `Kaki.app/Contents/Resources/glib-2.0/schemas/`. Set
   `XDG_DATA_DIRS` via `Info.plist` `LSEnvironment` to
   `@executable_path/../Resources` so libadwaita finds the
   schemas when launched via Finder/Launch Services (direct
   `./Kaki.app/Contents/MacOS/kaki` exec from a terminal will
   not pick up `LSEnvironment` — document this).
4. **Bundle GdkPixbuf loaders, Pango modules, GTK media
   backends** + set `GDK_PIXBUF_MODULE_FILE`, `GTK_PATH` via
   `LSEnvironment` at bundle-relative paths.
5. **Bundle Adwaita icon theme** into
   `Contents/Resources/share/icons/Adwaita`.
6. **Bundle GStreamer plugins** into `Contents/Frameworks` and
   set `GST_PLUGIN_PATH` via `LSEnvironment`.
7. **Code-sign + notarize**:
   ```bash
   codesign --deep --options runtime \
     --sign "Developer ID Application: <you>" Kaki.app
   xcrun notarytool submit Kaki.zip --apple-id <you> \
     --team-id <id> --wait
   xcrun stapler staple Kaki.app
   ```
8. **Wrap in a DMG** with `hdiutil create -volname Kaki
   -srcfolder Kaki.app -ov -format UDZO Kaki.dmg`.

Bundle size: **~80–100 MB** (GTK4 alone is ~78 MB).

### Platform services on macOS

- **Audio capture**: `osxaudiosrc` (GStreamer Good). CoreAudio.
- **GPU backend**: `metal` is the default and auto-enabled on
  Apple Silicon per the transcribe.cpp README. CPU fallback
  works on Intel Macs. Vulkan-via-MoltenVK is optional and
  rarely worth it over Metal.
- **Keystroke injection**: `CGEventCreateKeyboardEvent` +
  `CGEventPost(kCGSessionEventTap, ...)`. Requires
  **Accessibility** (for `AXUIElement`) and **Input Monitoring**
  (for `CGEventTap` listen) TCC grants. Use
  `CGPreflightListenEventAccess` / `CGRequestListenEventAccess`
  to prompt. ([Apple Developer Forums](https://origin-devforums.apple.com/forums/thread/707680))
- **Global shortcuts**: Carbon `RegisterEventHotKey`. Main-run-loop
  handler. Requires Accessibility TCC grant.
- **Secret store**: Security framework `SecItemAdd` /
  `SecItemCopyMatching` with `kSecClassGenericPassword`. Item
  access controlled by ACL; signed apps can be added to the
  ACL automatically on first use.
- **IPC (Phase 5 fallback)**: keep `kaki-signal` as a shell
  script, but use `~/Library/Application Support/kaki/kaki.pid`
  instead of `XDG_RUNTIME_DIR`. POSIX signals work on macOS.
- **Models dir**: `~/Library/Application Support/kaki/models/`
  via `g_get_user_data_dir()`.

## 6. Recommended architecture changes

These are the structural changes that make the per-phase ports
tractable. They are analysis, not a sequenced plan.

### 6.1 Platform abstraction in `src/services/`

Introduce interfaces and platform backends for the four
Linux-specific services. The Vala pattern is one interface file
plus per-platform implementations, gated in `meson.build` by
`host_machine.system()`.

```
src/services/
  keystroke.vala          # interface + Backend enum
  keystroke-linux.vala    # libei / ydotool / xdotool
  keystroke-windows.vala  # SendInput
  keystroke-macos.vala    # CGEvent
  global-shortcuts.vala   # interface
  global-shortcuts-linux.vala   # xdg-desktop-portal + SIGUSR1
  global-shortcuts-windows.vala # RegisterHotKey + named pipe
  global-shortcuts-macos.vala   # Carbon + SIGUSR1 (~/Library/...)
  secret-store.vala       # interface
  secret-store-libsecret.vala
  secret-store-wincred.vala
  secret-store-keychain.vala
  recorder.vala           # src element picked by host_machine.system()
```

The existing `phase-3-dictation-mode.md` and
`phase-5-global-shortcuts.md` plans are written as if Linux is
the only platform; they should be refactored to call through
the interfaces and leave the backend selection to meson.

### 6.2 Meson changes

- `meson_options.txt`: extend `gpu_backend` choices to
  `['auto', 'hip', 'cuda', 'vulkan', 'metal', 'cpu']`.
- `meson.build`: gate Linux-only deps with
  `if host_machine.system() == 'linux'`:
  - `libei-1.0` (optional)
  - `rocminfo` / `hipconfig` lookups
  - `xdg-desktop-portal` DBus interface (compile-time only)
- Add Windows deps (guarded by `os == 'windows'`):
  - `advapi32`, `user32` (Win32 libs — no pkg-config needed)
- Add macOS deps (guarded by `os == 'darwin'`):
  - `Security`, `CoreFoundation`, `Carbon`, `Cocoa` frameworks
    via meson's `dependency('...')` with the Apple SDK or
    direct `-framework` link args
- `gnome.post_install(...)` in `meson.build:30` should be
  guarded to Linux only — the three post-install hooks are
  meaningless on Win/macOS.

### 6.3 Models directory path

Replace every hardcoded `~/.local/share/kaki/models/` with:

```vala
string models_dir = Path.build_path (
    Path.DIR_SEPARATOR_S,
    Environment.get_user_data_dir (),
    "kaki", "models"
);
```

This is a latent bug on Linux (ignores `XDG_DATA_HOME`) and a
hard bug on Windows/macOS. Fix it in `phase-2-basic-transcription.md`
and `phase-4-preferences-ui.md` before porting.

### 6.4 Platform-aware shortcut defaults

The Phase 4 shortcuts table hardcodes `<Control>...` defaults.
On macOS the convention is `<Meta>...` (Cmd). Either:

- Ship per-platform defaults selected at first run, or
- Use `<Primary>...` in Gtk accelerator strings, which GTK4
  maps to Cmd on macOS and Ctrl elsewhere. (This is the
  zero-cost option and should be preferred.)

Verify by checking the existing
`set_accels_for_action("app.quit", {"<control>q"})` in
`src/application.vala:39` — replace `<control>` with `<primary>`
throughout to get correct macOS behavior for free.

### 6.5 Phase 5 IPC abstraction

The `kaki-signal` SIGUSR1 fallback should be abstracted:

- **Linux**: `XDG_RUNTIME_DIR/kaki.pid` + SIGUSR1/USR2/RTMIN+1
  (as written).
- **macOS**: `~/Library/Application Support/kaki/kaki.pid` +
  SIGUSR1/USR2 (RT signals may behave differently; test).
- **Windows**: named pipe `\\.\pipe\kaki\control` with a
  1-byte command, no signals. The `kaki-signal` script becomes
  `kaki-signal.exe` (or a PowerShell script).

## 7. Distribution & packaging summary

| | Linux | Windows | macOS |
|---|---|---|---|
| Build deps source | distro packages | MSYS2 (build only) | Homebrew (build only) |
| Binary format | ELF executable | `.exe` + DLLs | `.app` bundle |
| Installer | meson install / distro packaging | NSIS / MSIX / WiX | DMG (drag-to-Applications) |
| Runtime bundling | none (system libs) | ~80 MB DLL tree vendored next to `kaki.exe` | ~80–100 MB dylibs + schemas + icons vendored in `.app` |
| Code signing | optional | optional (SmartScreen warning otherwise) | **required** (notarization for Gatekeeper) |
| Sandboxing | none | MSIX optional | App Sandbox blocks dictation — **do not sandbox** |
| Auto-update | distro packager | MSIX handles it; Sparkle for NSIS | Sparkle (de-facto for non-App-Store Mac apps) |
| CI matrix | `ubuntu-latest` (gcc + vala) | `windows-latest` (MSYS2 UCRT64) + `windows-arm64` (CPU-only) | `macos-14` (Apple Silicon, Metal) + `macos-13` (Intel, CPU) |

## 8. Effort estimate

Per-phase porting effort, assuming the §6 architecture changes
are done first:

| Phase | Linux (done in plan) | Windows effort | macOS effort |
|---|---|---|---|
| 0 Scaffold | done | trivial | trivial |
| 1 transcribe.cpp + GPU | done | medium (add `cuda`, MSYS2 build of ggml) | medium (add `metal`, Homebrew build of ggml) |
| 2 Recorder + transcriber | done | medium (src-element switch, `get_user_data_dir` fix) | medium (same) |
| 3 Dictation (keystroke) | done | **high** (new `SendInput` backend) | **high** (new `CGEvent` backend + TCC grants + signing) |
| 4 Preferences UI | done | medium (`SecretStore` backend split, shortcut-default fix) | medium (same + Keychain backend) |
| 5 Global shortcuts | done | **high** (`RegisterHotKey` + named-pipe IPC) | **high** (Carbon hotkey + TCC grant + IPC path) |
| 6 Remote OpenAI | done | trivial (portable) | trivial (portable) |
| Packaging/installer | n/a | **high** (NSIS/MSIX + DLL bundling) | **high** (`.app` bundling + notarization + DMG) |

Rough total: **2–3 weeks** of focused work per platform once the
§6 abstraction layer is in place; the §6 layer itself is roughly
1 week. A realistic single-developer estimate for a working
beta-quality Windows + macOS port is **6–8 weeks**, dominated by
Phase 3 + Phase 5 + packaging on each platform.

## 9. Open questions

1. **Metal-only macOS, or also Vulkan-via-MoltenVK?** Metal is
   auto-enabled on Apple Silicon and is the lower-friction
   choice. MoltenVK adds a dependency and rarely beats Metal on
   macOS. Recommend shipping Metal-only on macOS unless there is
   a specific reason (e.g. sharing a Vulkan code path with
   Windows).

2. **MSVC build as a stretch goal?** MinGW via MSYS2 is the
   recommended first Windows target. MSVC doubles the build
   maintenance and is only worth it if Kaki needs to embed in
   an MSVC product. Defer indefinitely unless requested.

3. **Mac App Store "lite" build?** A sandboxed App Store
   variant with dictation disabled is technically possible.
   Worth the maintenance cost of a second build matrix row?
   Recommend not, until there is user demand.

4. **Windows ARM64 priority?** Surface Pro X and Snapdragon
   laptops are the audience. CPU-only is straightforward; is
   that enough, or do we want Vulkan-on-Adreno?

5. **Auto-update on Windows/macOS?** Sparkle is the de-facto
   Mac solution; MSIX handles Windows. Do we want auto-update
   in v1 or defer to a later release?

6. **Global-shortcut TCC prompt UX on macOS.** Both Phase 3
   (keystroke injection) and Phase 5 (global hotkeys) need
   Accessibility. Should we prompt once at first use or up-front
   on a "Permissions" page in Preferences? The latter is more
   discoverable; the former is less annoying.

7. **libsecret file backend as a fallback on Win/macOS?** If
   we ship native Credential Manager / Keychain backends, do
   we keep the libsecret file backend as a last-resort
   fallback, or drop libsecret entirely on non-Linux? Dropping
   it removes a dep and a code path; keeping it gives users a
   no-permission-required escape hatch. Recommend dropping on
   non-Linux.
