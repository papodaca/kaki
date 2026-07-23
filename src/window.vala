/* window.vala
 *
 * Copyright 2026 Ethan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

[GtkTemplate (ui = "/org/kaki/app/window.ui")]
public class Kaki.Window : Adw.ApplicationWindow {
    [GtkChild] private unowned Gtk.Stack stack;
    [GtkChild] private unowned Gtk.TextView transcript_view;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.ToggleButton dictate_btn;

    private GLib.SimpleAction record_action;
    private GLib.SimpleAction stop_action;
    private GLib.SimpleAction dictate_action;

    private Kaki.Recorder recorder;
    private Kaki.TranscriptionSource source;
    private Kaki.Keystroke keystroke;

    // Mark at the start of the current recording's text region.
    // left_gravity=true keeps the mark before text inserted at it,
    // so it stays at the boundary between committed (previous
    // utterances) and the current recording's tentative text.
    private Gtk.TextMark utterance_start;

    // Batch-mode chunk accumulator (used only when streaming is off
    // or the model doesn't support streaming).
    private float[] batch_buf = new float[0];

    // UI-level recording flag: true from recording_started through
    // stream_finalize / batch completion (including the finalize
    // step). Action sensitivity follows this, so the user can't
    // start a new recording while the previous one is finalizing.
    private bool recording = false;

    // Dictation mode: when true, the streamed transcript is also
    // injected (via `keystroke`) into whatever window had focus before
    // Kaki minimized. `last_typed` tracks the cumulative text already
    // sent so only the delta per partial is typed.
    private bool dictating = false;
    private string last_typed = "";

    // Source ID for the 250 ms minimize→record delay. Stored so it can
    // be cancelled if the window is destroyed during the delay (avoids
    // a use-after-free when the timeout fires after `this` is freed).
    private uint start_timeout_id = 0;

    // Cached settings (constructed once; read on every partial/final).
    private GLib.Settings settings;

    public Window (Gtk.Application app) {
        Object (application: app);

        // Customizable accelerators (Record / Stop / Insert / Dictate)
        // are read from GSettings and applied by Kaki.Application at
        // startup and on every shortcut-* change (see
        // application.vala::apply_shortcuts). Only the non-customizable
        // copy / clear / test-keystroke bindings remain hardcoded here.
        var kaki_app = (Kaki.Application) app;
        kaki_app.set_accels_for_action ("win.copy",  {"<Control><Shift>C"});
        kaki_app.set_accels_for_action ("win.clear", {"<Control>Delete"});
    }

    construct {
        recorder = new Kaki.Recorder ();
        keystroke = new Kaki.Keystroke ();
        settings = new GLib.Settings ("org.kaki.app");

        // Pick the keystroke backend from settings. auto|libei|ydotool|
        // xdotool map to the Keystroke.Backend enum; an unknown value
        // falls through to AUTO.
        string backend_name = settings.get_string ("keystroke-backend");
        Kaki.Keystroke.Backend preferred;
        switch (backend_name) {
        case "libei":   preferred = Kaki.Keystroke.Backend.LIBEI;   break;
        case "ydotool": preferred = Kaki.Keystroke.Backend.YDOTOOL; break;
        case "xdotool": preferred = Kaki.Keystroke.Backend.XDOTOOL; break;
        default:        preferred = Kaki.Keystroke.Backend.AUTO;     break;
        }
        keystroke.init (preferred);

        // Actions. Record/stop/dictate are SimpleAction so we can
        // toggle their enabled state; copy/clear/insert are always-on.
        // `dictate` is stateless and toggled in its activate handler:
        // a stateful boolean action can't be cleanly activated by a
        // keyboard accelerator (it needs a "b" parameter that the
        // accel machinery doesn't supply), so we manage the toggle
        // button's active state explicitly.
        record_action = new GLib.SimpleAction ("record", null);
        record_action.activate.connect (on_record);
        add_action (record_action);

        stop_action = new GLib.SimpleAction ("stop", null);
        stop_action.activate.connect (on_stop);
        add_action (stop_action);

        dictate_action = new GLib.SimpleAction ("dictate", null);
        dictate_action.activate.connect (on_dictate_toggle);
        add_action (dictate_action);

        var copy_action = new GLib.SimpleAction ("copy", null);
        copy_action.activate.connect (on_copy);
        add_action (copy_action);

        var clear_action = new GLib.SimpleAction ("clear", null);
        clear_action.activate.connect (on_clear);
        add_action (clear_action);

        // win.insert: copy the transcript to the clipboard AND type it
        // into the previously focused window. Bound to the customizable
        // shortcut-insert GSettings key (default <Control>I) via
        // Kaki.Application.apply_shortcuts ().
        var insert_action = new GLib.SimpleAction ("insert", null);
        insert_action.activate.connect (on_insert);
        add_action (insert_action);

        var test_keystroke_action = new GLib.SimpleAction ("test-keystroke", null);
        test_keystroke_action.activate.connect (on_test_keystroke);
        add_action (test_keystroke_action);

        // Recorder signals.
        recorder.chunk_ready.connect (on_chunk);
        recorder.recording_started.connect (on_recording_started);
        recorder.recording_stopped.connect (on_recording_stopped);
        recorder.error_occurred.connect (on_recorder_error);

        // Source signals (partial_text / final_text / error_occurred)
        // are wired in prepare_source_async () once the source is built.

        // Auto-prepare the source (local model or remote API) when the
        // window is mapped (the `realize` signal is shadowed by
        // Gtk.Native's realize() method in the GTK4 VAPI, so we use
        // `map` which fires right after realize when the window
        // becomes visible).
        this.map.connect (on_realize);

        // Place the utterance-start mark at the buffer origin; it
        // moves to end-of-buffer on each recording_started.
        var buf = transcript_view.buffer;
        utterance_start = new Gtk.TextMark (null, true);
        Gtk.TextIter start_iter;
        buf.get_start_iter (out start_iter);
        buf.add_mark (utterance_start, start_iter);

        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Source dispatch + prepare                                          */
    /* ----------------------------------------------------------------- */

    private void on_realize () {
        prepare_source_async.begin ();
    }

    // Build the configured TranscriptionSource (local or remote per
    // the transcription-source GSettings key), wire its signals, and
    // run prepare() — LocalSource reads the user-configured model-path
    // and loads the model, RemoteOpenAISource validates endpoint +
    // model. Stack pages: "loading" while prepare runs, "active" on
    // success, "empty" on failure (with a toast so a missing key /
    // bad endpoint / no model configured is visible).
    private async void prepare_source_async () {
        string src = settings.get_string ("transcription-source");
        if (src == "api") {
            var remote = new Kaki.RemoteOpenAISource ();
            remote.endpoint         = settings.get_string ("api-endpoint");
            remote.model            = settings.get_string ("api-model");
            remote.response_format  = settings.get_string ("api-response-format");
            remote.temperature      = settings.get_double ("api-temperature");
            remote.translate        = settings.get_boolean ("api-translate");
            try {
                var secret = new Kaki.SecretStore ();
                string? key = yield secret.get_api_key ();
                remote.api_key = key ?? "";
            } catch (GLib.Error e) {
                warning ("Cannot read API key from keyring: %s", e.message);
                remote.api_key = "";
            }
            source = remote;
        } else {
            source = new Kaki.LocalSource ();
        }

        // Source signals fire on the main thread for both backends
        // (LocalSource resumes its worker threads via Idle.add;
        // RemoteOpenAISource runs entirely on the main thread).
        source.partial_text.connect (on_partial_text);
        source.final_text.connect (on_final_text);
        source.error_occurred.connect (on_source_error);

        stack.visible_child_name = "loading";
        try {
            yield source.prepare ();
            stack.visible_child_name = "active";
        } catch (GLib.Error e) {
            warning ("Source prepare failed: %s", e.message);
            stack.visible_child_name = "empty";
            toast_overlay.add_toast (new Adw.Toast (
                _("Prepare failed: %s").printf (e.message)));
        }
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Action state                                                       */
    /* ----------------------------------------------------------------- */

    private void update_action_state () {
        bool on_active = stack.visible_child_name == "active";
        record_action.set_enabled (on_active && !recording);
        stop_action.set_enabled (on_active && recording);
        // Dictate stays clickable whenever a source is prepared and a
        // keystroke backend is available; toggling it off must remain
        // possible mid-dictation, so it isn't gated on `!recording`.
        dictate_action.set_enabled (
            on_active && keystroke.backend != Kaki.Keystroke.Backend.NONE);
    }

    /* ----------------------------------------------------------------- */
    /* Global-shortcut entry points                                       */
    /* ----------------------------------------------------------------- */

    // Public wrappers used by the global-shortcut handlers in
    // Kaki.Application (portal Activated signal + Unix USR1/USR2/RTMIN+1
    // fallback). They delegate to the private activate handlers, which
    // already guard against re-entrant / no-op calls, so the action-
    // enabled gating (which depends on the in-window stack page being
    // "active") is deliberately bypassed — a global toggle must work
    // even when the window is minimized or on a non-"active" page.
    public bool is_recording { get { return recording; } }

    public void record () { on_record (); }
    public void stop ()   { on_stop (); }

    // Global-shortcut entry point: drive the full dictation flow.
    // Toggle on: minimize Kaki, capture the previously focused window,
    // start recording, and stream partial transcripts into that
    // window via the keystroke backend. Toggle off: stop recording,
    // finalize, and type the final text. Reuses on_dictate_toggle
    // verbatim so the in-window Dictate button and the global shortcut
    // stay in sync (dictate_btn.active, dictating, last_typed all flip
    // through the same path).
    public void toggle_dictation () { on_dictate_toggle (); }

    // Refuse the global "insert" shortcut while dictation is streaming
    // typed partials: on_insert() types the buffer via the keystroke
    // backend, which would interleave with the in-flight dictation
    // typing and garble the target window. The in-window win.insert
    // action (which calls on_insert directly) keeps its pre-existing
    // behavior; only the new global-shortcut entry point is guarded.
    public void insert () {
        if (dictating) {
            toast_overlay.add_toast (new Adw.Toast (
                _("Stop dictation before inserting text")));
            return;
        }
        on_insert ();
    }

    /* ----------------------------------------------------------------- */
    /* Record / stop                                                      */
    /* ----------------------------------------------------------------- */

    private void on_record () {
        if (recording)
            return;
        if (source == null) {
            // We only land here if the stack is "active", which
            // implies the source prepared. Defensive guard anyway.
            warning ("Record pressed with no source prepared");
            return;
        }
        try {
            recorder.start ();
        } catch (GLib.Error e) {
            warning ("Recorder start failed: %s", e.message);
        }
        // recording_started signal drives the state transition.
    }

    private void on_recording_started () {
        recording = true;

        // Move the utterance-start mark to the end of the buffer so
        // the new recording's text is appended after any prior
        // transcript (or user edits).
        var buf = transcript_view.buffer;
        Gtk.TextIter end_iter;
        buf.get_end_iter (out end_iter);
        buf.move_mark (utterance_start, end_iter);

        if (use_streaming ()) {
            source.stream_begin.begin ();
        } else {
            batch_buf = new float[0];
        }

        update_action_state ();
    }

    private void on_chunk (float[] samples) {
        if (!recording)
            return;
        if (use_streaming ()) {
            source.stream_feed.begin (samples);
        } else {
            // Append to the batch accumulator.
            int old_len = batch_buf.length;
            batch_buf.resize (old_len + samples.length);
            for (int i = 0; i < samples.length; i++) {
                batch_buf[old_len + i] = samples[i];
            }
        }
    }

    private void on_stop () {
        if (!recording)
            return;
        recorder.stop ();
        // recording_stopped drives the finalize / batch path.
    }

    private void on_recording_stopped () {
        if (use_streaming ()) {
            source.stream_finalize.begin (null, (obj, res) => {
                source.stream_finalize.end (res);
                recording = false;
                if (dictating) {
                    dictating = false;
                    dictate_btn.active = false;
                }
                update_action_state ();
            });
        } else {
            transcribe_batch_async.begin ();
        }
    }

    private async void transcribe_batch_async () {
        try {
            string text = yield source.transcribe_batch (batch_buf);
            var buf = transcript_view.buffer;
            Gtk.TextIter mark_iter;
            buf.get_iter_at_mark (out mark_iter, utterance_start);
            string full = text + "\n";
            buf.insert (ref mark_iter, full, full.length);
            Gtk.TextIter end_iter;
            buf.get_end_iter (out end_iter);
            buf.move_mark (utterance_start, end_iter);

            // In dictation + batch mode there are no partials, so the
            // whole final transcript is typed in one shot (with the
            // optional trailing newline) and last_typed stays "".
            if (dictating && auto_type_enabled ()) {
                type_dictation (text, true);
            }
        } catch (GLib.Error e) {
            warning ("Batch transcribe failed: %s", e.message);
        }
        recording = false;
        if (dictating) {
            dictating = false;
            dictate_btn.active = false;
        }
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Dictation mode                                                   */
    /* ----------------------------------------------------------------- */

    private void on_dictate_toggle () {
        if (dictating) {
            dictate_btn.active = false;
            stop_dictation ();
        } else {
            if (keystroke.backend == Kaki.Keystroke.Backend.NONE) {
                toast_overlay.add_toast (new Adw.Toast (
                    _("No keystroke backend available")));
                return;
            }
            dictate_btn.active = true;
            start_dictation ();
        }
    }

    private void start_dictation () {
        if (recording) {
            // Record was already started via the Record button; just
            // mark dictation so the partials also get typed out.
            dictating = true;
            last_typed = "";
            return;
        }
        if (source == null) {
            warning ("Dictate pressed with no source prepared");
            return;
        }
        dictating = true;
        last_typed = "";

        // Minimize so the previously focused window receives the
        // injected keystrokes. A short delay lets the WM hand focus
        // back before the recorder starts capturing.
        this.minimize ();
        start_timeout_id = GLib.Timeout.add (250, () => {
            start_timeout_id = 0;
            if (!dictating)
                return false;
            try {
                recorder.start ();
            } catch (GLib.Error e) {
                warning ("Recorder start failed: %s", e.message);
                dictating = false;
                dictate_btn.active = false;
                this.present ();
                toast_overlay.add_toast (new Adw.Toast (
                    _("Recorder start failed: %s").printf (e.message)));
                update_action_state ();
            }
            return false;
        });
    }

    private void stop_dictation () {
        if (!dictating)
            return;
        if (recording) {
            recorder.stop ();
            // recording_stopped drives the finalize path; dictating is
            // cleared in on_recording_stopped / transcribe_batch_async
            // once the final transcript has been typed out.
        } else {
            // Recording hasn't started yet (e.g. the user toggled
            // Dictate off during the 250 ms minimize delay). Clear
            // dictation now; the pending Timeout will see !dictating
            // and skip recorder.start().
            dictating = false;
            last_typed = "";
            if (start_timeout_id != 0) {
                GLib.Source.remove (start_timeout_id);
                start_timeout_id = 0;
            }
        }
    }

    // Test button: types the current transcript buffer into whatever
    // window had focus before Kaki minimized. Bypasses the
    // recording/transcription pipeline so the keystroke backend can
    // be exercised in isolation.
    private void on_test_keystroke () {
        if (keystroke.backend == Kaki.Keystroke.Backend.NONE) {
            toast_overlay.add_toast (new Adw.Toast (
                _("No keystroke backend available")));
            return;
        }
        string text = transcript_view.buffer.text;
        if (text.length == 0) {
            toast_overlay.add_toast (new Adw.Toast (
                _("Buffer is empty — type something to test with first")));
            return;
        }
        this.minimize ();
        GLib.Timeout.add (250, () => {
            keystroke.type_text.begin (text);
            return false;
        });
    }

    // win.insert: copy the transcript to the clipboard AND type it
    // into the previously focused window. Bound to the customizable
    // shortcut-insert GSettings key (default <Control>I). Equivalent
    // to on_test_keystroke with the clipboard copy added.
    private void on_insert () {
        if (keystroke.backend == Kaki.Keystroke.Backend.NONE) {
            toast_overlay.add_toast (new Adw.Toast (
                _("No keystroke backend available")));
            return;
        }
        string text = transcript_view.buffer.text;
        if (text.length == 0) {
            toast_overlay.add_toast (new Adw.Toast (
                _("Buffer is empty — type something to insert first")));
            return;
        }
        var clipboard = Gdk.Display.get_default ().get_clipboard ();
        clipboard.set_text (text);
        this.minimize ();
        GLib.Timeout.add (250, () => {
            keystroke.type_text.begin (text);
            return false;
        });
    }

    /* ----------------------------------------------------------------- */
    /* Source text → buffer                                               */
    /* ----------------------------------------------------------------- */

    private void on_partial_text (string text) {
        var buf = transcript_view.buffer;
        Gtk.TextIter start, end;
        buf.get_iter_at_mark (out start, utterance_start);
        buf.get_end_iter (out end);
        buf.@delete (ref start, ref end);
        Gtk.TextIter insert_iter;
        buf.get_iter_at_mark (out insert_iter, utterance_start);
        buf.insert (ref insert_iter, text, text.length);

        if (dictating && auto_type_enabled ())
            type_dictation (text, false);
    }

    private void on_final_text (string text) {
        var buf = transcript_view.buffer;
        Gtk.TextIter start, end;
        buf.get_iter_at_mark (out start, utterance_start);
        buf.get_end_iter (out end);
        buf.@delete (ref start, ref end);
        Gtk.TextIter insert_iter;
        buf.get_iter_at_mark (out insert_iter, utterance_start);
        string full = text + "\n";
        buf.insert (ref insert_iter, full, full.length);
        Gtk.TextIter new_end;
        buf.get_end_iter (out new_end);
        buf.move_mark (utterance_start, new_end);

        if (dictating && auto_type_enabled ())
            type_dictation (text, true);
    }

    /* ----------------------------------------------------------------- */
    /* Copy / clear                                                       */
    /* ----------------------------------------------------------------- */

    private void on_copy () {
        var clipboard = Gdk.Display.get_default ().get_clipboard ();
        clipboard.set_text (transcript_view.buffer.text);
    }

    private void on_clear () {
        var buf = transcript_view.buffer;
        buf.set_text ("", -1);
        Gtk.TextIter start_iter;
        buf.get_start_iter (out start_iter);
        buf.move_mark (utterance_start, start_iter);
    }

    /* ----------------------------------------------------------------- */
    /* Error handling                                                     */
    /* ----------------------------------------------------------------- */

    private void on_recorder_error (string message) {
        warning ("Recorder error: %s", message);
        recording = false;
        if (dictating) {
            dictating = false;
            dictate_btn.active = false;
            this.present ();
            toast_overlay.add_toast (new Adw.Toast (
                _("Recorder error: %s").printf (message)));
        }
        update_action_state ();
    }

    private void on_source_error (string message) {
        warning ("Source error: %s", message);
        toast_overlay.add_toast (new Adw.Toast (
            _("Source error: %s").printf (message)));
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Helpers                                                            */
    /* ----------------------------------------------------------------- */

    private bool use_streaming () {
        return settings.get_boolean ("use-streaming")
               && source.can_stream;
    }

    private bool auto_type_enabled () {
        return settings.get_boolean ("dictation-auto-type");
    }

    // Send the new suffix of `text` (relative to last_typed) through
    // the keystroke backend. For final text, optionally append a
    // trailing newline per the user setting. last_typed is reset to
    // "" after a final so the next utterance's deltas start fresh.
    //
    // The streaming model emits monotonic prefixes (committed grows,
    // tentative extends the tail), so the common path is a clean
    // suffix. When the model revises (prefix mismatch), we skip the
    // injection for that update to avoid corrupting the target
    // window — the buffer still shows the corrected text.
    private void type_dictation (string text, bool is_final) {
        string delta = "";
        if (last_typed.length > 0 && text.has_prefix (last_typed)) {
            delta = text.substring (last_typed.length);
        } else if (last_typed.length == 0) {
            delta = text;
        }
        last_typed = text;

        if (delta.length > 0 && delta.validate ())
            keystroke.type_text.begin (delta);

        if (is_final) {
            if (settings.get_boolean ("dictation-trailing-newline"))
                keystroke.type_text.begin ("\n");
            last_typed = "";
        }
    }

    public override void dispose () {
        if (start_timeout_id != 0) {
            GLib.Source.remove (start_timeout_id);
            start_timeout_id = 0;
        }
        base.dispose ();
    }
}