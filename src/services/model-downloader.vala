/* model-downloader.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * libsoup-3.0 based downloader for HuggingFace GGUF model files. Emits
 * progress / completed / failed signals; the caller (preferences.vala)
 * binds those to a progress row in the Models page.
 *
 * Atomicity: writes to `<dest_path>.part`, renames to `dest_path` only
 * after the whole transfer succeeds, and removes the .part file on
 * failure or cancellation.
 */

public class Kaki.ModelDownloader : GLib.Object {
    public signal void progress (int64 downloaded, int64 total);
    public signal void completed (string local_path);
    public signal void failed (string message);

    private Soup.Session _session;

    construct {
        _session = new Soup.Session ();
        // 60 s connect/read timeout — long downloads still progress
        // because any chunk read resets the timer via Soup's internal
        // read loop. Abort the whole transfer if 60 s pass with no
        // bytes at all.
        _session.set_timeout (60);
    }

    public async void download_async (string url, string dest_path,
                                       Cancellable? cancellable = null) {
        GLib.Uri uri;
        try {
            uri = GLib.Uri.parse (url, GLib.UriFlags.NONE);
        } catch (GLib.UriError e) {
            failed (@"bad URL: $(e.message)");
            return;
        }

        var msg = new Soup.Message.from_uri ("GET", uri);

        string part_path = dest_path + ".part";
        File part_file = File.new_for_path (part_path);
        File dest_file = File.new_for_path (dest_path);

        FileOutputStream? out = null;
        try {
            // Replace any stale .part from a previous interrupted run.
            if (part_file.query_exists ()) {
                part_file.delete ();
            }
            out = part_file.replace (null, false,
                                     FileCreateFlags.REPLACE_DESTINATION);
        } catch (GLib.Error e) {
            failed (@"open dest: $(e.message)");
            return;
        }

        GLib.InputStream input;
        try {
            input = yield _session.send_async (msg, Priority.DEFAULT, cancellable);
        } catch (GLib.Error e) {
            cleanup_part (part_file);
            if (cancellable != null && cancellable.is_cancelled ())
                failed ("cancelled");
            else
                failed (@"send: $(e.message)");
            return;
        }

        // Some HuggingFace redirects land on a CDN that still sets a
        // Content-Length; if absent (chunked / unknown), report 0 and
        // the caller shows just the bytes-downloaded counter.
        int64 total = msg.get_response_headers ().get_content_length ();

        uint8[] buf = new uint8[64 * 1024];
        int64 downloaded = 0;

        try {
            while (true) {
                ssize_t n = yield input.read_async (buf, Priority.DEFAULT,
                                                    cancellable);
                if (n == 0)
                    break;
                if (n < 0) {
                    failed ("read returned negative");
                    cleanup_part (part_file);
                    return;
                }
                uint8[] slice = buf[0:n];
                out.write_all (slice, null);
                downloaded += n;
                progress (downloaded, total);
            }
            out.close ();
            out = null;

            // Atomically promote .part → final name.
            part_file.move (dest_file, FileCopyFlags.OVERWRITE);
            completed (dest_path);
        } catch (GLib.Error e) {
            if (out != null) {
                try { out.close (); } catch (GLib.Error close_e) {}
            }
            cleanup_part (part_file);
            if (cancellable != null && cancellable.is_cancelled ())
                failed ("cancelled");
            else
                failed (e.message);
        }
    }

    private static void cleanup_part (File part_file) {
        try {
            if (part_file.query_exists ())
                part_file.delete ();
        } catch (GLib.Error e) {
            // Best-effort; ignore.
        }
    }
}
