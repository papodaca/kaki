# Phase 4 — Preferences UI

## Goal

Replace the placeholder `app.preferences` handler with a real
`Adw.PreferencesDialog` containing four pages: **General**, **Models**,
**Shortcuts**, **API**.

## Files to create

- `src/ui/preferences.vala` — subclass of `Adw.PreferencesDialog`
- `src/ui/preferences.ui` — GtkBuilder XML describing the four pages
- `src/services/model-downloader.vala` — libsoup-3.0 downloader for
  HuggingFace GGUF files
- `src/services/secret-store.vala` — libsecret wrapper for the API key

## `src/ui/preferences.vala`

```vala
[GtkTemplate (ui = "/org/kaki/app/preferences.ui")]
public class Kaki.PreferencesDialog : Adw.PreferencesDialog {
    public Kaki.Settings? settings { get; construct; }

    public PreferencesDialog (Kaki.Settings settings) {
        Object (settings: settings);
    }

    construct {
        populate_general_page ();
        populate_models_page ();
        populate_shortcuts_page ();
        populate_api_page ();
    }
}
```

(Or just use `Gio.Settings` directly; a thin `Kaki.Settings` wrapper is
optional.)

## General page

| Row | Type | Bound setting |
| --- | --- | --- |
| Backend | Adw.ComboRow (Auto / HIP / Vulkan / CPU) | `gpu-backend` (read-only at runtime; reflects build-time choice unless we add a runtime backend selector) |
| Default model | Adw.ComboRow (scanned `*.gguf`) | `model-path` |
| Language | Adw.ComboRow (Auto-detect / en / es / fr / …) | `language` |
| CPU threads | Adw.SpinRow (1–32) | `cpu-threads` |
| Flash attention | Adw.SwitchRow | `flash-attention` |
| Streaming | Adw.SwitchRow | `use-streaming` |

> Backend ComboRow: the build-time choice is in `meson.build`. We expose
> it read-only via `Config.GPU_BACKEND` (add to `config.h` /
> `config.vapi` in Phase 1). A "not in this build" subtitle marks
> backends the binary was not built with.

## Models page

- `Adw.PreferencesGroup` listing every `*.gguf` under
  `~/.local/share/kaki/models/` with size (recompute on `page-visible`).
- `Adw.ButtonRow`: "Download Whisper Tiny (English, Q8_0)" → triggers
  `model-downloader.download_async(url, dest_path)`.
- Same for Whisper Base, Small (English).
- `Adw.ButtonRow`: "Open Models Directory" →
  ```vala
  var file = File.new_for_path(models_dir);
  var launcher = new Gtk.FileLauncher (file);
  yield launcher.open_async (this, null);
  ```
- Active download row swaps into a `Adw.Bin` showing an `Adw.Spinner`
  + progress label ("4.2 MB / 77 MB"). On completion, refresh the list
  and select the new model.

### `src/services/model-downloader.vala`

```vala
public class Kaki.ModelDownloader : GLib.Object {
    public signal void progress (int64 downloaded, int64 total);
    public signal void completed (string local_path);
    public signal void failed (string message);

    public async void download_async (string url, string dest_path,
                                      Cancellable? cancellable = null);
}
```

Implementation uses `libsoup-3.0`:

```vala
var session = new Soup.Session ();
var msg = new Soup.Message.from_uri ("GET", Uri.parse(url));
input_stream = yield session.send_async (msg, cancellable,
                                          Priority.DEFAULT);
total = msg.response_headers.get_content_length();
// read in 64 KB chunks, write to file, emit progress
```

Initial catalog (hardcoded in a small `ModelCatalog` struct):

| Label | URL |
| --- | --- |
| Whisper Tiny (English, Q8_0) | `https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf` |
| Whisper Base (English, Q8_0) | `https://huggingface.co/handy-computer/whisper-base.en-gguf/resolve/main/whisper-base.en-Q8_0.gguf` |
| Whisper Small (English, Q8_0) | `https://huggingface.co/handy-computer/whisper-small.en-gguf/resolve/main/whisper-small.en-Q8_0.gguf` |

Verify URLs against the live HuggingFace repo at implementation time;
the org may rename repos.

## Shortcuts page

Rows for each customizable action:

| Action | Default accel | Setting key |
| --- | --- | --- |
| Record / Pause | `<Control>R` | `shortcut-record` |
| Stop | `<Control>S` | `shortcut-stop` |
| Insert text (copy + type) | `<Control>I` | `shortcut-insert` |
| Toggle dictation | `<Control>D` | `shortcut-dictate` |
| Show preferences | `<Control>comma` | `shortcut-prefs` |
| Show shortcuts | `<Control>question` | `shortcut-shortcuts` |
| Quit | `<Control>Q` | `shortcut-quit` |

Each row uses a custom shortcut-capture widget (a `Gtk.ShortcutLabel`
with a "Set…" button that opens a `Gtk.KeyvalRange` capture — or
manually captures `Gtk.EventControllerKey` until a valid combo is
pressed).

Storage: each shortcut as `s` in GSettings. At startup, `Kaki.Application`
reads all `shortcut-*` keys and calls `set_accels_for_action` per
action. Saving in the dialog updates GSettings AND calls
`set_accels_for_action` live (no restart required).

## API page (OpenAI-compatible)

| Row | Type | Bound setting |
| --- | --- | --- |
| Transcription source | Adw.ComboRow (Local model / OpenAI-compatible API) | `transcription-source` |
| Endpoint URL | Adw.EntryRow | `api-endpoint` (default `https://api.openai.com/v1/audio/transcriptions`) |
| Model name | Adw.EntryRow | `api-model` (default `whisper-1`) |
| API key | Adw.PasswordEntryRow | libsecret (not GSettings) |
| Test connection | Adw.ButtonRow | n/a — runs test |
| Response format | Adw.ComboRow (json / text / verbose_json) | `api-response-format` |
| Temperature | Adw.SpinRow (0.0–1.0, step 0.1) | `api-temperature` |
| Translate to English | Adw.SwitchRow | `api-translate` |

### `src/services/secret-store.vala`

```vala
public class Kaki.SecretStore : GLib.Object {
    private static Secret.Schema _schema = new Secret.Schema (
        "org.kaki.app", Secret.SchemaFlags.NONE,
        {"type", Secret.SchemaAttributeType.STRING}
    );

    public static async string? get_api_key ();
    public static async void set_api_key (string? key);
    public static async void clear_api_key ();
}
```

Test connection: send a POST with a 100 ms silent WAV sample (kept in
`/org/kaki/app/test-sample.wav` gresource) and the configured
endpoint/key/model. Show an `Adw.Toast` with the result ("200 OK — 42
bytes" vs. error).

## Wire-up in `application.vala`

```vala
private void on_preferences_action () {
    var prefs = new Kaki.PreferencesDialog (settings);
    prefs.present (this.active_window);
}
```

## GSchema additions (consolidated for Phase 4)

```xml
<key name="gpu-backend" type="s"><default>"auto"</default></key>
<key name="transcription-source" type="s"><default>"local"</default></key>
<key name="api-endpoint" type="s"><default>"https://api.openai.com/v1/audio/transcriptions"</default></key>
<key name="api-model" type="s"><default>"whisper-1"</default></key>
<key name="api-response-format" type="s"><default>"json"</default></key>
<key name="api-temperature" type="d"><default>0.0</default></key>
<key name="api-translate" type="b"><default>false</default></key>
<key name="shortcut-record" type="s"><default>"&lt;Control&gt;R"</default></key>
<key name="shortcut-stop" type="s"><default>"&lt;Control&gt;S"</default></key>
<key name="shortcut-insert" type="s"><default>"&lt;Control&gt;I"</default></key>
<key name="shortcut-dictate" type="s"><default>"&lt;Control&gt;D"</default></key>
<key name="shortcut-prefs" type="s"><default>"&lt;Control&gt;comma"</default></key>
<key name="shortcut-shortcuts" type="s"><default>"&lt;Control&gt;question"</default></key>
<key name="shortcut-quit" type="s"><default>"&lt;Control&gt;Q"</default></key>
```

## New meson deps

```meson
dependency('libsecret-1'),
dependency('libsoup-3.0'),
```

Add `preferences.ui` to `kaki.gresource.xml`.

## Verification

1. Open Preferences → General: change language, confirm `GSettings get
   language` reflects the new value and that a fresh transcription
   respects it.
2. Models page: download Whisper Tiny → progress bar moves → list
   refreshes with the new file → Default model row picks it.
3. Open Models Directory button → Nautilus opens
   `~/.local/share/kaki/models/`.
4. Shortcuts page: rebind Record to `<Control><Shift>R` → close dialog
   → confirm `<Control><Shift>R` starts recording and `<Control>R`
   no longer does.
5. API page: enter a real key → Test connection → toast shows OK.
   Switch transcription-source to `api` → record a clip → confirm
   remote response lands in the transcript view (backend added in
   Phase 6; for Phase 4 the source switch is just persisted).
6. `secret-tool lookup type api-key` returns the stored key after
   saving; `secret-tool search --all 'type=api-key'` lists it under
   `org.kaki.app`.

## Commit

```
Phase 4: preferences dialog (General / Models / Shortcuts / API)

- src/ui/preferences.vala + preferences.ui: Adw.PreferencesDialog with 4 pages
- src/services/model-downloader.vala: libsoup-3.0 download from HF GGUF repos
- src/services/secret-store.vala: libsecret schema 'org.kaki.app' attribute type=api-key
- Shortcuts page: per-action GSettings strings, live rebind via set_accels_for_action
- Open Models Directory via Gtk.FileLauncher
- Test Connection POSTs a sample WAV to the configured endpoint
- meson: add libsecret-1, libsoup-3.0 deps
```
