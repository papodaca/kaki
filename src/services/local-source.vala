/* local-source.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Local TranscriptionSource backed by the Phase 1 transcribe.cpp
 * engine. Refactored in Phase 6 from the Phase 2 `Kaki.Transcriber`
 * class to implement the `Kaki.TranscriptionSource` interface so
 * the window can dispatch between local and remote backends via
 * the `transcription-source` GSettings key.
 *
 * Async wrapper over the Phase 1 VAPI. Two paths:
 *
 *   - Batch:  transcribe_batch (samples) → returns full transcript.
 *   - Stream: stream_begin → stream_feed (chunk) … stream_finalize →
 *             emits partial_text (committed + tentative) while
 *             feeding and final_text (committed) on finalize.
 *
 * prepare ()
 * ---------
 * Reads the user-configured `model-path` GSettings key (set via the
 * Preferences → General → Default model combo, or the "Set as
 * default" button on the Models page). When empty, falls back to the
 * first *.gguf in ~/.local/share/kaki/models/. Loads the model on a
 * worker thread and throws on failure — the caller (window.vala)
 * switches its stack to the "empty" page on error.
 *
 * Threading model
 * ---------------
 * transcribe.cpp enforces one run / active stream per session at a
 * time. We honor that by guarding every session call with a Mutex.
 * Each public async method spawns a worker Thread; concurrent
 * workers block on the mutex and serialize. The chunk array is
 * copied into the worker's closure so the caller's buffer can be
 * freed once we return.
 *
 * Workers resume the async method via `Idle.add ((owned) callback)`
 * — the canonical Vala async pattern. The continuation (post-yield)
 * runs on the GLib main thread, so `partial_text` / `final_text`
 * signals are emitted there and window handlers can touch GTK
 * directly.
 */

public class Kaki.LocalSource : GLib.Object, TranscriptionSource {
    private Transcribe.Model? _model;
    public unowned Transcribe.Model? model {
        get { return _model; }
    }

    // signals partial_text / final_text / error_occurred are inherited
    // from the TranscriptionSource interface and emitted by name below.

    public bool can_stream { get { return _caps.supports_streaming; } }

    private Transcribe.Session?     _session;
    private Transcribe.Capabilities _caps;
    private GLib.Mutex               _session_lock;
    private string                   _last_partial_emit = "";

    private Transcribe.RunParams    _run_params;
    private Transcribe.StreamParams _stream_params;
    private string                  _language_buf = "";

    public LocalSource () {
        var r = Transcribe.init_backends_default ();
        if (r != Transcribe.Status.OK) {
            warning ("transcribe_init_backends_default: %s", r.to_string ());
        }
    }

    /* ----------------------------------------------------------------- */
    /* prepare — model discovery + load                                   */
    /* ----------------------------------------------------------------- */

    private class LoadResult : GLib.Object {
        public Transcribe.Model?       model;
        public Transcribe.Session?     session;
        public Transcribe.Capabilities caps;
        public string?                 error;
    }

    public async void prepare () throws GLib.Error {
        string path = resolve_model_path ();
        if (path == null || path == "") {
            throw new IOError.NOT_FOUND (
                "No model configured. Set a model in Preferences or place a .gguf in ~/.local/share/kaki/models/.");
        }

        SourceFunc callback = prepare.callback;
        string local_path = path;
        LoadResult? result = null;

        new Thread<void> ("kaki-load-model", () => {
            result = load_model_sync (local_path);
            Idle.add ((owned) callback);
        });

        yield;

        if (result == null || result.model == null || result.session == null) {
            throw new IOError.FAILED (
                result != null ? (result.error ?? "unknown error") : "unknown error");
        }
        _model   = (owned) result.model;
        _session = (owned) result.session;
        _caps    = result.caps;
        build_run_params ();
    }

    // Read the user-configured model-path (Preferences → General →
    // Default model combo, or the "Set as default" button on the
    // Models page). When empty, fall back to the first *.gguf in
    // ~/.local/share/kaki/models/ — the same scan the Phase 2
    // window.vala performed, moved here so prepare() is self-contained.
    private string resolve_model_path () {
        var settings = new GLib.Settings ("org.kaki.app");
        string path = settings.get_string ("model-path");
        if (path != null && path != "") {
            return path;
        }
        string models_dir = GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (), "kaki", "models");
        try {
            var dir = GLib.Dir.open (models_dir, 0);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_suffix (".gguf")) {
                    return GLib.Path.build_filename (models_dir, name);
                }
            }
        } catch (GLib.FileError e) {
            // Directory missing or unreadable: treat as no model.
        }
        return "";
    }

    private static LoadResult load_model_sync (string path) {
        var result = new LoadResult ();

        Transcribe.Capabilities caps = Transcribe.Capabilities ();
        var p = Transcribe.ModelLoadParams ();
        Transcribe.Model? m = null;
        var st = Transcribe.Model.load_file (path, p, out m);
        if (st != Transcribe.Status.OK || m == null) {
            result.error = @"transcribe_model_load_file failed: $st";
            return result;
        }

        // Per-model capabilities (fall back to library defaults if
        // the query fails). Both structs are init'd via their Vala
        // constructors (sets struct_size); ref-not-out is required so
        // the C side sees a valid struct_size.
        Transcribe.Capabilities model_caps = Transcribe.Capabilities ();
        var mcstat = m.get_capabilities (ref model_caps);
        if (mcstat == Transcribe.Status.OK) {
            caps = model_caps;
        }

        var sp = Transcribe.SessionParams ();
        var settings = new GLib.Settings ("org.kaki.app");
        sp.n_threads = settings.get_int ("cpu-threads");
        Transcribe.Session? s = null;
        var sst = Transcribe.Session.init (m, sp, out s);
        if (sst != Transcribe.Status.OK || s == null) {
            result.error = @"transcribe_session_init failed: $sst";
            return result;
        }

        result.model   = (owned) m;
        result.session = (owned) s;
        result.caps    = caps;
        return result;
    }

    private void build_run_params () {
        _run_params = Transcribe.RunParams ();
        var settings = new GLib.Settings ("org.kaki.app");
        var lang = settings.get_string ("language");
        // Hold the string in _language_buf so the unowned pointer in
        // _run_params.language stays valid for every subsequent
        // session.run / stream_begin call. The C library copies the
        // string during those calls, so the buffer only needs to
        // outlive the call, not the session.
        if (lang == "auto" || lang == null || lang == "") {
            _language_buf = "";
            _run_params.language = null;
        } else {
            _language_buf = lang;
            _run_params.language = _language_buf;
        }
        _stream_params = Transcribe.StreamParams ();
    }

    /* ----------------------------------------------------------------- */
    /* transcribe_batch                                                   */
    /* ----------------------------------------------------------------- */

    private class BatchResult : GLib.Object {
        public string? text;
        public string? error;
        public int     code;
    }

    public async string transcribe_batch (float[] samples,
                                           Cancellable? cancellable = null)
                                           throws GLib.Error {
        SourceFunc callback = transcribe_batch.callback;
        // Copy the array into a closure-captured buffer the worker
        // owns. The caller's `samples` may be freed once we return.
        var copy = new float[samples.length];
        GLib.Memory.copy (copy, samples, samples.length * sizeof (float));
        BatchResult? result = null;

        new Thread<void> ("kaki-batch", () => {
            result = batch_sync (copy);
            Idle.add ((owned) callback);
        });

        yield;

        if (result == null) {
            throw new IOError.FAILED ("transcribe_batch: no result");
        }
        if (result.error != null && result.text == null) {
            throw new IOError.FAILED (result.error);
        }
        if (result.error != null) {
            warning ("batch: %s", result.error);
        }
        return result.text ?? "";
    }

    private BatchResult batch_sync (float[] samples) {
        if (_session == null) {
            return new BatchResult () { error = "no model loaded", code = -1 };
        }
        _session_lock.lock ();
        Transcribe.Status st;
        try {
            st = _session.run (samples, _run_params);
        } finally {
            _session_lock.unlock ();
        }
        if (st == Transcribe.Status.OK || st == Transcribe.Status.ERR_OUTPUT_TRUNCATED) {
            var text = _session.full_text ();
            var r = new BatchResult () { text = text.dup (), code = (int) st };
            if (st == Transcribe.Status.ERR_OUTPUT_TRUNCATED) {
                r.error = "Output truncated at the model's generation cap";
            }
            return r;
        } else if (st == Transcribe.Status.ERR_INPUT_TOO_LONG) {
            return new BatchResult () {
                error = "Input too long for the model's context window",
                code  = (int) st,
            };
        }
        return new BatchResult () {
            error = @"transcribe_run failed: $st",
            code  = (int) st,
        };
    }

    /* ----------------------------------------------------------------- */
    /* stream_begin / feed / finalize                                     */
    /* ----------------------------------------------------------------- */

    public async void stream_begin (Cancellable? cancellable = null) {
        _last_partial_emit = "";
        SourceFunc callback = stream_begin.callback;
        bool ok = false;

        new Thread<void> ("kaki-stream-begin", () => {
            ok = stream_begin_sync ();
            Idle.add ((owned) callback);
        });

        yield;
        if (!ok) {
            warning ("stream_begin failed");
        }
    }

    private bool stream_begin_sync () {
        if (_session == null)
            return false;
        _session_lock.lock ();
        Transcribe.Status st;
        try {
            st = _session.stream_begin (_run_params, _stream_params);
        } finally {
            _session_lock.unlock ();
        }
        if (st != Transcribe.Status.OK) {
            warning ("stream_begin: %s", st.to_string ());
            return false;
        }
        return true;
    }

    public async void stream_feed (float[] chunk, Cancellable? cancellable = null) {
        SourceFunc callback = stream_feed.callback;
        var copy = new float[chunk.length];
        GLib.Memory.copy (copy, chunk, chunk.length * sizeof (float));

        new Thread<void> ("kaki-stream-feed", () => {
            stream_feed_sync (copy);
            Idle.add ((owned) callback);
        });

        yield;
        emit_partial ();
    }

    private void stream_feed_sync (float[] samples) {
        if (_session == null)
            return;
        _session_lock.lock ();
        Transcribe.Status st;
        try {
            st = _session.stream_feed (samples);
        } finally {
            _session_lock.unlock ();
        }
        if (st != Transcribe.Status.OK) {
            warning ("stream_feed: %s", st.to_string ());
        }
    }

    public async void stream_finalize (Cancellable? cancellable = null) {
        SourceFunc callback = stream_finalize.callback;
        new Thread<void> ("kaki-stream-finalize", () => {
            stream_finalize_sync ();
            Idle.add ((owned) callback);
        });

        yield;
        emit_final ();
    }

    private void stream_finalize_sync () {
        if (_session == null)
            return;
        _session_lock.lock ();
        Transcribe.Status st;
        try {
            st = _session.stream_finalize ();
        } finally {
            _session_lock.unlock ();
        }
        if (st != Transcribe.Status.OK) {
            warning ("stream_finalize: %s", st.to_string ());
        }
    }

    /* ----------------------------------------------------------------- */
    /* text snapshot → signal                                             */
    /* ----------------------------------------------------------------- */

    private void emit_partial () {
        if (_session == null)
            return;
        _session_lock.lock ();
        Transcribe.StreamText st = Transcribe.StreamText ();
        var r = _session.stream_get_text (ref st);
        _session_lock.unlock ();
        if (r != Transcribe.Status.OK)
            return;
        // Concatenation allocates a new owned string; safe to emit
        // even after the next feed rewrites the session buffers.
        string combined = st.committed_text + st.tentative_text;
        if (combined == _last_partial_emit)
            return;
        _last_partial_emit = combined;
        partial_text (combined);
    }

    private void emit_final () {
        if (_session == null)
            return;
        _session_lock.lock ();
        Transcribe.StreamText st = Transcribe.StreamText ();
        var r = _session.stream_get_text (ref st);
        _session_lock.unlock ();
        if (r != Transcribe.Status.OK)
            return;
        // Per the C docs: on successful finalize, committed_text
        // becomes the final transcript; for ON_FINALIZE committed is
        // empty so we fall back to full_text.
        string text = st.committed_text;
        if (text == "")
            text = st.full_text;
        string final_text_copy = text.dup ();
        _last_partial_emit = "";
        final_text (final_text_copy);
    }
}
