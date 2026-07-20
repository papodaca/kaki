# Phase 2 — Basic transcription app

## Goal

Capture microphone audio via GStreamer, feed it to transcribe.cpp, and
show the transcript in the main window. Two paths:

- **Batch**: record → stop → transcribe whole clip → show in text view.
- **Streaming**: record → emit partial text as you speak → finalize on
  stop. (Used by dictation mode in Phase 3.)

Default model is read from settings; if none, the empty-state from
Phase 0 stays.

## New meson deps

```meson
kaki_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  transcribe_dep,
  meson.get_compiler('vala').find_library('transcribe', dirs: meson.current_source_dir() / 'vapi'),
  dependency('gstreamer-1.0'),
  dependency('gstreamer-base-1.0'),
  dependency('gstreamer-app-1.0'),
  dependency('gstreamer-audio-1.0'),
]
```

## Files to create

### `src/services/recorder.vala`

GStreamer pipeline (B1):

```
pulsesrc (or pipewiresrc) ! audioconvert ! audioresample !
  capsfilter (audio/x-raw, rate=16000, channels=1, format=F32LE) !
  appsink (emit-signals=true, sync=false, drop=true, max-buffers=4)
```

Public API:

```vala
public class Kaki.Recorder : GLib.Object {
    public bool is_recording { get; private set; }

    public signal void chunk_ready (Bytes samples);
    public signal void recording_started ();
    public signal void recording_stopped ();
    public signal void error_occurred (string message);

    public void start ()    throws Error;
    public void stop ();
    public void cancel ();
}
```

- `appsink` `new-sample` callback pulls a `Gst.Sample`, maps the buffer,
  copies into a `Bytes`, emits `chunk_ready`.
- `stop()` sends EOS, drains, emits `recording_stopped`.
- 100 ms chunks (1600 frames at 16 kHz mono F32LE = 6.4 KB per chunk).

### `src/services/transcriber.vala`

Async wrapper over the VAPI from Phase 1.

```vala
public class Kaki.Transcriber : GLib.Object {
    public Transcribe.Model? model { get; private set; }

    public signal void partial_text (string text);
    public signal void final_text (string text);
    public signal void load_failed (string message);

    public async bool load_model (string path, Cancellable? cancellable = null);
    public async string transcribe_batch (uint8[] samples_f32, int n_samples,
                                          Cancellable? cancellable = null)
                                          throws GLib.Error;
    public async void stream_begin (Cancellable? cancellable = null);
    public async void stream_feed (uint8[] chunk, Cancellable? cancellable = null);
    public async void stream_finalize (Cancellable? cancellable = null);
}
```

- `load_model` runs `Transcribe.Model.load(path)` in a worker thread
  (`GLib.Task.run`); emits `load_failed` on null return.
- `transcribe_batch` calls `session.run(samples, n)` in a worker; on
  `OK` returns `session.full_text()`. On `ERR_INPUT_TOO_LONG` /
  `ERR_OUTPUT_TRUNCATED` throws a typed error.
- `stream_*` calls wrap `transcribe_stream_begin/feed/finalize`. After
  each `feed`, pull `transcribe_stream_get_text()` → split into
  `committed_text` (last emit) and `tentative_text` (delta) → emit
  `partial_text` with the tentative tail. On `finalize` emit
  `final_text` with the committed text.

### `src/ui/window.vala` + `src/window.ui`

Replace the Phase 0 empty-state content with a `Gtk.Stack`:

```xml
<object class="GtkStack" id="stack">
  <child>
    <object class="GtkStackPage">
      <property name="name">empty</property>
      <property name="child">
        <object class="AdwStatusPage"> ...No Model Loaded... </object>
      </property>
    </object>
  </child>
  <child>
    <object class="GtkStackPage">
      <property name="name">loading</property>
      <property name="child">
        <object class="AdwStatusPage">
          <property name="icon-name">folder-open-symbolic</property>
          <property name="title" translatable="yes">Loading model…</property>
          <child>
            <object class="GtkSpinner"> <property name="spinning">True</property> </object>
          </child>
        </object>
      </property>
    </object>
  </child>
  <child>
    <object class="GtkStackPage">
      <property name="name">active</property>
      <property name="child">
        <object class="AdwToolbarView">
          <child type="bottom">
            <object class="GtkActionBar">
              <child type="start">
                <object class="GtkButton" id="record_btn">
                  <property name="icon-name">audio-input-microphone-symbolic</property>
                  <property name="label" translatable="yes">Record</property>
                  <property name="action-name">win.record</property>
                </object>
              </child>
              <child type="start">
                <object class="GtkButton" id="stop_btn">
                  <property name="icon-name">media-playback-stop-symbolic</property>
                  <property name="action-name">win.stop</property>
                  <property name="sensitive">False</property>
                </object>
              </child>
              <child type="end">
                <object class="GtkButton" id="copy_btn">
                  <property name="icon-name">edit-copy-symbolic</property>
                  <property name="action-name">win.copy</property>
                </object>
              </child>
              <child type="end">
                <object class="GtkButton" id="clear_btn">
                  <property name="icon-name">edit-clear-symbolic</property>
                  <property name="action-name">win.clear</property>
                </object>
              </child>
            </object>
          </child>
          <property name="content">
            <object class="GtkScrolledWindow">
              <property name="child">
                <object class="GtkTextView" id="transcript_view">
                  <property name="editable">True</property>
                  <property name="monospace">True</property>
                  <property name="wrap-mode">word</property>
                </object>
              </property>
            </object>
          </property>
        </object>
      </property>
    </object>
  </child>
</object>
```

`src/window.vala` actions:

```vala
public const GLib.ActionEntry[] WIN_ACTIONS = {
    { "record", on_record },
    { "stop",   on_stop },
    { "clear",  on_clear },
    { "copy",   on_copy },
};

construct {
    add_action_entries (WIN_ACTIONS, this);
    var app = (Kaki.Application) application;
    app.set_accels_for_action ("win.record", {"<Control>R"});
    app.set_accels_for_action ("win.stop",   {"<Control>S"});
    app.set_accels_for_action ("win.copy",   {"<Control>C"});  // clashes; use <Control><Shift>C
    app.set_accels_for_action ("win.clear",  {"<Control>Delete"});
}
```

Flow:

- On `window.realize`, read `model-path` setting. If empty, scan
  `~/.local/share/kaki/models/` for first `*.gguf`. If still empty,
  keep stack on `empty`.
- `win.record`:
  - If model not loaded → load it (stack → `loading`).
  - On load success → `recorder.start()`, swap record/stop button
    sensitivity.
- `recorder.chunk_ready` → if streaming, `transcriber.stream_feed(chunk)`.
- `transcriber.partial_text` → append to `GtkTextBuffer` (replace last
  tentative segment).
- `win.stop` → `recorder.stop()` → `transcriber.stream_finalize()` →
  append final text + newline.
- `win.copy` → `Gdk.Display.get_default().get_clipboard().set_text(buffer.text)`.
- `win.clear` → clear buffer.

## GSchema additions (`data/org.kaki.app.gschema.xml`)

```xml
<key name="model-path" type="s">
  <default>""</default>
  <summary>Path to the GGUF model file used for local transcription</summary>
</key>
<key name="use-streaming" type="b">
  <default>true</default>
  <summary>Use streaming transcription when available</summary>
</key>
<key name="language" type="s">
  <default>"auto"</default>
  <summary>Language code or 'auto' for detection</summary>
</key>
<key name="cpu-threads" type="i">
  <default>4</default>
  <summary>Number of CPU threads for the transcribe.cpp runtime</summary>
</key>
<key name="flash-attention" type="b">
  <default>true</default>
  <summary>Use flash attention when the backend supports it</summary>
</key>
```

## Verification

1. Download a Whisper model manually to `~/.local/share/kaki/models/`:
   ```bash
   mkdir -p ~/.local/share/kaki/models
   cd ~/.local/share/kaki/models
   curl -LO https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf
   ```
2. Launch Kaki → stack should auto-switch to `active` after model
   loads.
3. Click Record, speak, click Stop → transcript appears in the text
   view.
4. Toggle `use-streaming=true` and confirm partial text emits while
   speaking.
5. Copy button copies buffer to clipboard (paste elsewhere to verify).

## Commit

```
Phase 2: GStreamer recorder + transcriber + main window

- src/services/recorder.vala: pulsesrc → appsink pipeline, 100 ms F32 chunks
- src/services/transcriber.vala: async wrapper over transcribe.vapi
  (batch + streaming)
- src/window.vala + window.ui: GtkStack empty/loading/active; GtkTextView
  transcript; record/stop/clear/copy actions
- GSchema: model-path, use-streaming, language, cpu-threads, flash-attention
- meson: add gstreamer-1.0/base/app/audio deps
```
