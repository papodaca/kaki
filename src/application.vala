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
