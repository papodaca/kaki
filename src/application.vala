/* application.vala
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

public class Kaki.Application : Adw.Application {
    private GLib.Settings? _settings = null;
    private Kaki.GlobalShortcuts? _shortcuts = null;
    // Path to the pidfile written for the kaki-signal fallback helper.
    // Null when no pidfile was written (XDG_RUNTIME_DIR unwritable, or
    // the process is a transient forwarding instance). Cleared in
    // shutdown.
    private string? _pidfile = null;

    public Application () {
        Object (
            application_id: "org.kaki.app",
            flags: ApplicationFlags.DEFAULT_FLAGS,
            resource_base_path: "/org/kaki/app"
        );
    }

    construct {
        ActionEntry[] action_entries = {
            { "about", this.on_about_action },
            { "preferences", this.on_preferences_action },
            { "shortcuts", this.on_shortcuts_action },
            { "quit", this.quit }
        };
        this.add_action_entries (action_entries, this);

        // Apply all customizable shortcuts from GSettings on startup
        // and re-apply live whenever a shortcut-* key changes. The
        // PreferencesDialog.ShortcutRow fires the write to GSettings;
        // the changed:: signal here propagates the change to the
        // application immediately (per plan § Shortcuts page: "no
        // restart required").
        apply_shortcuts ();
        var s = settings;
        foreach (string key in new string[] {
            "shortcut-record", "shortcut-stop", "shortcut-insert",
            "shortcut-dictate", "shortcut-prefs",
            "shortcut-shortcuts", "shortcut-quit"
        }) {
            s.changed.connect ((changed_key) => {
                if (changed_key.has_prefix ("shortcut-"))
                    apply_shortcuts ();
            });
        }
    }

    public unowned GLib.Settings settings {
        get {
            if (_settings == null)
                _settings = new GLib.Settings ("org.kaki.app");
            return _settings;
        }
    }

    /**
     * Re-apply all customizable accelerators from GSettings. Called at
     * startup and whenever a shortcut-* key changes. win.* actions
     * (record/stop/insert/dictate) are routed to the application; the
     * currently-focused window picks them up automatically.
     */
    public void apply_shortcuts () {
        var s = settings;
        // Each action takes a 1-element array of the GSettings value,
        // or an empty array (which removes any existing binding) when
        // the user has cleared the shortcut. The accel_array helper
        // handles the empty-string case.
        set_accels_for_action ("app.quit",
            accel_array (s.get_string ("shortcut-quit")));
        set_accels_for_action ("app.preferences",
            accel_array (s.get_string ("shortcut-prefs")));
        set_accels_for_action ("app.shortcuts",
            accel_array (s.get_string ("shortcut-shortcuts")));
        set_accels_for_action ("win.record",
            accel_array (s.get_string ("shortcut-record")));
        set_accels_for_action ("win.stop",
            accel_array (s.get_string ("shortcut-stop")));
        set_accels_for_action ("win.insert",
            accel_array (s.get_string ("shortcut-insert")));
        set_accels_for_action ("win.dictate",
            accel_array (s.get_string ("shortcut-dictate")));
    }

    // Wrap a single GSettings accel string into the array shape that
    // set_accels_for_action expects. Empty string → empty array (which
    // removes any existing binding for the action).
    private static string[] accel_array (string accel) {
        if (accel == null || accel == "")
            return new string[0];
        return new string[] { accel };
    }

    /* ----------------------------------------------------------------- */
    /* Global shortcuts: portal (preferred) + Unix-signal fallback       */
    /* ----------------------------------------------------------------- */

    // SIGRTMIN is a function-based macro on glibc and a constant on
    // musl; posix.vapi has no binding. The shim in src/vapi/signal-shim.c
    // exposes it; the +1 offset is the first user-usable realtime
    // signal (glibc reserves SIGRTMIN itself).
    [CCode (cname = "kaki_sigrtmin", cheader_filename = "signal-shim.h")]
    private static extern int kaki_sigrtmin ();

    public override void startup () {
        base.startup ();

        // Preferred: xdg-desktop-portal GlobalShortcuts. init is async
        // and best-effort — available flips to false on any failure,
        // leaving the Unix-signal fallback as the active path.
        _shortcuts = new Kaki.GlobalShortcuts ();
        _shortcuts.shortcut_activated.connect (on_global_shortcut_activated);
        _shortcuts.init.begin ();

        // Fallback: the kaki-signal helper sends these. Registered in
        // startup so they're live before the first window appears.
        // Source.CONTINUE keeps the source installed for the process
        // lifetime (a one-shot would miss later signals).
        GLib.Unix.signal_add (Posix.Signal.USR1, () => {
            on_global_toggle ();
            return GLib.Source.CONTINUE;
        });
        GLib.Unix.signal_add (Posix.Signal.USR2, () => {
            on_global_stop ();
            return GLib.Source.CONTINUE;
        });
        GLib.Unix.signal_add (kaki_sigrtmin () + 1, () => {
            on_global_insert ();
            return GLib.Source.CONTINUE;
        });

        write_pidfile ();
    }

    public override void shutdown () {
        remove_pidfile ();
        base.shutdown ();
    }

    // True once the portal interface is confirmed and bound. Read by
    // the Preferences Shortcuts page to pick between "Bind via portal"
    // and "Install helper script" UI.
    public bool global_shortcuts_available {
        get { return _shortcuts != null && _shortcuts.available; }
    }

    // Driven from the Preferences "Bind via portal" button: create the
    // portal session and ask the user to assign a trigger combo. The
    // shortcut drives the full dictation flow (toggle on = record +
    // stream into the focused window, toggle off = stop + type the
    // final text), so the user-facing description says "dictation".
    public async void bind_global_shortcut () {
        if (_shortcuts == null)
            return;
        yield _shortcuts.bind ("toggle-recording", _("Toggle voice dictation"));
    }

    private void on_global_shortcut_activated (string id) {
        if (id == "toggle-recording")
            on_global_toggle ();
    }

    // Drive the full dictation flow: toggle on minimizes Kaki and
    // streams partial transcripts into the previously focused window;
    // toggle off stops recording, finalizes, and types the final
    // text. Reuses Kaki.Window.toggle_dictation (the same path as
    // the in-window Dictate button) so the two stay in sync.
    private void on_global_toggle () {
        (this.active_window as Kaki.Window)?.toggle_dictation ();
    }

    private void on_global_stop () {
        (this.active_window as Kaki.Window)?.stop ();
    }

    private void on_global_insert () {
        (this.active_window as Kaki.Window)?.insert ();
    }

    // Write $XDG_RUNTIME_DIR/kaki.pid (or /tmp/kaki.pid) so the
    // kaki-signal fallback helper can find this process. XDG_RUNTIME_DIR
    // is 0700 user-owned, so the pidfile isn't world-readable.
    private void write_pidfile () {
        string runtime = GLib.Environment.get_variable ("XDG_RUNTIME_DIR");
        if (runtime == null || runtime == "")
            runtime = "/tmp";
        _pidfile = runtime + "/kaki.pid";
        try {
            GLib.FileUtils.set_contents (_pidfile,
                "%d".printf ((int) Posix.getpid ()));
        } catch (GLib.Error e) {
            warning ("cannot write pidfile %s: %s", _pidfile, e.message);
            _pidfile = null;
        }
    }

    private void remove_pidfile () {
        if (_pidfile == null)
            return;
        try {
            GLib.FileUtils.unlink (_pidfile);
        } catch (GLib.Error e) {
            // Already gone (e.g. a second instance overwrote then
            // cleared it) — nothing to do.
        }
        _pidfile = null;
    }

    public override void activate () {
        base.activate ();
        var win = this.active_window ?? new Kaki.Window (this);
        win.present ();
    }

    private void on_about_action () {
        string[] developers = { "Ethan" };
        var about = new Adw.AboutDialog () {
            application_name = "Kaki",
            application_icon = "org.kaki.app",
            developer_name = "Ethan",
            translator_credits = _("translator-credits"),
            version = "0.1.0",
            developers = developers,
            copyright = "© 2026 Ethan",
        };

        about.present (this.active_window);
    }

    private void on_preferences_action () {
        var prefs = new Kaki.PreferencesDialog (this, this.active_window);
        prefs.present (this.active_window);
    }

    private void on_shortcuts_action () {
        var builder = new Gtk.Builder.from_resource ("/org/kaki/app/shortcuts-dialog.ui");
        var dialog = (Adw.ShortcutsDialog) builder.get_object ("shortcuts_dialog");
        dialog.present (this.active_window);
    }
}
