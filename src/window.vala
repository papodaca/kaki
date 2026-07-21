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

    private GLib.SimpleAction record_action;
    private GLib.SimpleAction stop_action;

    private Kaki.Recorder recorder;
    private Kaki.Transcriber transcriber;

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

    public Window (Gtk.Application app) {
        Object (application: app);

        // Accelerator registration must happen after the application
        // property is fully set; in the construct block `application`
        // is not yet a valid Gtk.Application (GObject construction
        // order: construct properties are set, then construct runs,
        // but Gtk.Window.application needs the app to be wired up
        // at the GTK level, which happens after construct).
        var kaki_app = (Kaki.Application) app;
        kaki_app.set_accels_for_action ("win.record", {"<Control>R"});
        kaki_app.set_accels_for_action ("win.stop",   {"<Control>S"});
        kaki_app.set_accels_for_action ("win.copy",   {"<Control><Shift>C"});
        kaki_app.set_accels_for_action ("win.clear",  {"<Control>Delete"});
    }

    construct {
        recorder = new Kaki.Recorder ();
        transcriber = new Kaki.Transcriber ();

        // Actions. Record/stop are SimpleAction so we can toggle
        // their enabled state; copy/clear are always-on.
        record_action = new GLib.SimpleAction ("record", null);
        record_action.activate.connect (on_record);
        add_action (record_action);

        stop_action = new GLib.SimpleAction ("stop", null);
        stop_action.activate.connect (on_stop);
        add_action (stop_action);

        var copy_action = new GLib.SimpleAction ("copy", null);
        copy_action.activate.connect (on_copy);
        add_action (copy_action);

        var clear_action = new GLib.SimpleAction ("clear", null);
        clear_action.activate.connect (on_clear);
        add_action (clear_action);

        // Recorder signals.
        recorder.chunk_ready.connect (on_chunk);
        recorder.recording_started.connect (on_recording_started);
        recorder.recording_stopped.connect (on_recording_stopped);
        recorder.error_occurred.connect (on_recorder_error);

        // Transcriber signals.
        transcriber.partial_text.connect (on_partial_text);
        transcriber.final_text.connect (on_final_text);
        transcriber.load_failed.connect (on_load_failed);

        // Auto-load model when the window is mapped (the `realize`
        // signal is shadowed by Gtk.Native's realize() method in the
        // GTK4 VAPI, so we use `map` which fires right after realize
        // when the window becomes visible).
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
    /* Model discovery + auto-load                                        */
    /* ----------------------------------------------------------------- */

    private void on_realize () {
        string path = resolve_model_path ();
        if (path == null || path == "") {
            stack.visible_child_name = "empty";
            update_action_state ();
            return;
        }
        stack.visible_child_name = "loading";
        load_model_async.begin (path);
    }

    private async void load_model_async (string path) {
        bool ok = yield transcriber.load_model (path);
        if (ok) {
            stack.visible_child_name = "active";
        } else {
            // load_failed signal already fired from the transcriber.
            stack.visible_child_name = "empty";
        }
        update_action_state ();
    }

    private string resolve_model_path () {
        var settings = new GLib.Settings ("org.kaki.app");
        string path = settings.get_string ("model-path");
        if (path != null && path != "") {
            return path;
        }
        // Fall back to the first *.gguf in ~/.local/share/kaki/models/.
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

    /* ----------------------------------------------------------------- */
    /* Action state                                                       */
    /* ----------------------------------------------------------------- */

    private void update_action_state () {
        bool on_active = stack.visible_child_name == "active";
        record_action.set_enabled (on_active && !recording);
        stop_action.set_enabled (on_active && recording);
    }

    /* ----------------------------------------------------------------- */
    /* Record / stop                                                      */
    /* ----------------------------------------------------------------- */

    private void on_record () {
        if (recording)
            return;
        if (transcriber.model == null) {
            // We only land here if the stack is "active", which
            // implies the model loaded. Defensive guard anyway.
            warning ("Record pressed with no model loaded");
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
            transcriber.stream_begin.begin ();
        } else {
            batch_buf = new float[0];
        }

        update_action_state ();
    }

    private void on_chunk (float[] samples) {
        if (!recording)
            return;
        if (use_streaming ()) {
            transcriber.stream_feed.begin (samples);
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
            transcriber.stream_finalize.begin (null, (obj, res) => {
                transcriber.stream_finalize.end (res);
                recording = false;
                update_action_state ();
            });
        } else {
            transcribe_batch_async.begin ();
        }
    }

    private async void transcribe_batch_async () {
        try {
            string text = yield transcriber.transcribe_batch (batch_buf);
            var buf = transcript_view.buffer;
            Gtk.TextIter mark_iter;
            buf.get_iter_at_mark (out mark_iter, utterance_start);
            string full = text + "\n";
            buf.insert (ref mark_iter, full, full.length);
            Gtk.TextIter end_iter;
            buf.get_end_iter (out end_iter);
            buf.move_mark (utterance_start, end_iter);
        } catch (GLib.Error e) {
            warning ("Batch transcribe failed: %s", e.message);
        }
        recording = false;
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Transcriber text → buffer                                          */
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
        update_action_state ();
    }

    private void on_load_failed (string message) {
        warning ("Model load failed: %s", message);
        stack.visible_child_name = "empty";
        update_action_state ();
    }

    /* ----------------------------------------------------------------- */
    /* Helpers                                                            */
    /* ----------------------------------------------------------------- */

    private bool use_streaming () {
        var settings = new GLib.Settings ("org.kaki.app");
        return settings.get_boolean ("use-streaming")
               && transcriber.supports_streaming ();
    }
}
