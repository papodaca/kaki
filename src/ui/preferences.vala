/* preferences.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Adw.PreferencesDialog with four pages: General / Models / Shortcuts /
 * API. The .ui file in src/ui/preferences.ui declares the dialog
 * template and most rows; this file populates the dynamic rows
 * (default-model combo, installed-models list, shortcut rows), binds
 * widgets to GSettings, and wires the model downloader + secret store
 * + test-connection POST.
 *
 * The dialog takes a Kaki.Application so it can ask the app to re-apply
 * accelerators live when the user changes a shortcut (per plan §
 * Shortcuts page: "no restart required").
 */

[GtkTemplate (ui = "/org/kaki/app/preferences.ui")]
public class Kaki.PreferencesDialog : Adw.PreferencesDialog {
    public unowned Kaki.Application application { get; construct; }
    // Adw.Dialog doesn't expose its host widget via the Vala binding,
    // so we carry the parent Gtk.Window in here and pass it to async
    // calls that need a transient parent (e.g. Gtk.FileLauncher).
    public unowned Gtk.Window parent_window { get; construct; }

    // ----- General page -----
    [GtkChild] unowned Adw.ComboRow backend_row;
    [GtkChild] unowned Adw.ComboRow default_model_row;
    [GtkChild] unowned Adw.ComboRow language_row;
    [GtkChild] unowned Adw.SpinRow cpu_threads_row;
    [GtkChild] unowned Adw.SwitchRow flash_attention_row;
    [GtkChild] unowned Adw.SwitchRow streaming_row;

    // ----- Models page -----
    [GtkChild] unowned Adw.PreferencesGroup installed_group;
    [GtkChild] unowned Adw.PreferencesGroup download_progress_group;

    // ----- Shortcuts page -----
    [GtkChild] unowned Adw.PreferencesGroup shortcuts_group;

    // ----- API page -----
    [GtkChild] unowned Adw.ComboRow transcription_source_row;
    [GtkChild] unowned Adw.EntryRow api_endpoint_row;
    [GtkChild] unowned Adw.EntryRow api_model_row;
    [GtkChild] unowned Adw.PasswordEntryRow api_key_row;
    [GtkChild] unowned Adw.ComboRow response_format_row;
    [GtkChild] unowned Adw.SpinRow temperature_row;
    [GtkChild] unowned Adw.SwitchRow translate_row;

    private GLib.Settings settings;
    private Kaki.SecretStore secret;

    // Index → code mappings for the static ComboRow StringLists. Keep
    // these in sync with the .ui file's <items> order.
    private static string[] backend_codes    = {"auto", "hip", "vulkan", "cpu"};
    private static string[] language_codes   = {"auto", "en", "es", "fr", "de", "it",
                                                  "pt", "nl", "pl", "ru", "uk", "tr",
                                                  "ar", "hi", "zh", "ja", "ko"};
    private static string[] source_codes     = {"local", "api"};
    private static string[] response_codes   = {"json", "text", "verbose_json"};

    // Initial catalog of downloadable Whisper GGUFs. URLs verified at
    // implementation time — handy-computer/whisper-*.{en,}-gguf repos on HF.
    private const ModelCatalogEntry[] CATALOG = {
        { "Whisper Tiny (English, Q8_0)",
          "https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf",
          "whisper-tiny.en-Q8_0.gguf" },
        { "Whisper Base (English, Q8_0)",
          "https://huggingface.co/handy-computer/whisper-base.en-gguf/resolve/main/whisper-base.en-Q8_0.gguf",
          "whisper-base.en-Q8_0.gguf" },
        { "Whisper Small (English, Q8_0)",
          "https://huggingface.co/handy-computer/whisper-small.en-gguf/resolve/main/whisper-small.en-Q8_0.gguf",
          "whisper-small.en-Q8_0.gguf" },
    };

    // Used by the ButtonRow signal handlers in .ui to know which catalog
    // entry they correspond to. Set during populate_models_page ().
    private Gtk.StringList installed_list;
    private string[] installed_basenames = {};
    private string models_dir;

    // Active download state.
    private Kaki.ModelDownloader downloader;
    private Cancellable? download_cancellable;
    private Adw.ActionRow active_progress_row;

    public PreferencesDialog (Kaki.Application app, Gtk.Window parent) {
        Object (application: app, parent_window: parent);
    }

    construct {
        settings = new GLib.Settings ("org.kaki.app");
        secret = new Kaki.SecretStore ();
        downloader = new Kaki.ModelDownloader ();

        populate_general_page ();
        populate_models_page ();
        populate_shortcuts_page ();
        populate_api_page ();

        // Refresh installed models when the Models page becomes visible.
        visible_page.notify["visible-page-name"].connect (() => {
            if (visible_page_name == "models")
                refresh_installed_models ();
        });
    }

    /* =================================================================== */
    /* General page                                                         */
    /* =================================================================== */

    private void populate_general_page () {
        // Backend: read-only, reflects Config.GPU_BACKEND baked at build time.
        string resolved = Config.GPU_BACKEND;
        int idx = index_of (backend_codes, resolved);
        if (idx >= 0)
            backend_row.set_selected ((uint) idx);
        string subtitle;
        switch (resolved) {
        case "hip":    subtitle = _("HIP (ROCm) backend compiled in"); break;
        case "vulkan": subtitle = _("Vulkan backend compiled in");     break;
        case "cpu":    subtitle = _("CPU backend compiled in");        break;
        default:       subtitle = _("Auto — backend selected at runtime"); break;
        }
        backend_row.set_subtitle (subtitle);
        // No notify handler: read-only row.

        // Default model combo.
        refresh_default_model_row ();
        default_model_row.notify["selected"].connect (() => {
            uint s = default_model_row.get_selected ();
            if (s == 0) {
                settings.set_string ("model-path", "");
            } else if (s - 1 < installed_basenames.length) {
                string basename = installed_basenames[s - 1];
                settings.set_string ("model-path",
                    GLib.Path.build_filename (models_dir, basename));
            }
        });

        // Language combo.
        int lang_idx = index_of (language_codes, settings.get_string ("language"));
        if (lang_idx < 0)
            lang_idx = 0;
        language_row.set_selected ((uint) lang_idx);
        language_row.notify["selected"].connect (() => {
            uint s = language_row.get_selected ();
            settings.set_string ("language", language_codes[s]);
        });

        // CPU threads (GSettings int <-> SpinRow double).
        cpu_threads_row.set_value ((double) settings.get_int ("cpu-threads"));
        cpu_threads_row.notify["value"].connect (() => {
            settings.set_int ("cpu-threads", (int) cpu_threads_row.get_value ());
        });

        // SwitchRows: direct GSettings bind.
        settings.bind ("flash-attention", flash_attention_row, "active",
                       GLib.SettingsBindFlags.DEFAULT);
        settings.bind ("use-streaming",   streaming_row,     "active",
                       GLib.SettingsBindFlags.DEFAULT);
    }

    private void refresh_default_model_row () {
        // (Re)scan the models directory and rebuild the default-model
        // StringList. The ComboRow already has its expression bound to
        // GtkStringObject.string in the .ui file, so swapping models
        // Just Works.
        models_dir = GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (), "kaki", "models");

        installed_list = new Gtk.StringList (null);
        installed_list.append (_("(none)"));
        installed_basenames = {};

        string current = settings.get_string ("model-path");
        uint selected = 0;

        try {
            var dir = GLib.Dir.open (models_dir, 0);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (name.has_suffix (".gguf")) {
                    installed_list.append (name);
                    installed_basenames += name;
                    if (current.has_suffix (name))
                        selected = (uint) installed_basenames.length;
                }
            }
        } catch (GLib.FileError e) {
            // No models dir yet — leave just the "(none)" entry.
        }

        default_model_row.set_model (installed_list);
        default_model_row.set_selected (selected);
    }

    /* =================================================================== */
    /* Models page                                                          */
    /* =================================================================== */

    private void populate_models_page () {
        refresh_installed_models ();
    }

    private void refresh_installed_models () {
        // Clear existing rows and re-scan.
        // AdwPreferencesGroup's API doesn't expose a "remove all" in the
        // vapi binding, so we remove children one at a time via get_row().
        // For our purposes (a handful of rows at most) it's fine; the
        // alternative — replacing the group wholesale — isn't worth the
        // indirection.
        var models_dir_path = GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (), "kaki", "models");
        models_dir = models_dir_path;

        // Drop existing rows (keep going until get_row(0) returns null).
        for (uint i = 0;; i++) {
            unowned Gtk.Widget? row = installed_group.get_row (0);
            if (row == null)
                break;
            installed_group.remove (row);
        }

        bool any = false;
        try {
            var dir = GLib.Dir.open (models_dir_path, 0);
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (!name.has_suffix (".gguf"))
                    continue;
                any = true;
                var row = new Adw.ActionRow ();
                row.title = name;
                // File size as subtitle.
                var path = GLib.Path.build_filename (models_dir_path, name);
                try {
                    var info = GLib.File.new_for_path (path).query_info (
                        FileAttribute.STANDARD_SIZE,
                        FileQueryInfoFlags.NONE, null);
                    int64 size = info.get_size ();
                    row.subtitle = format_size (size);
                } catch (GLib.Error e) {
                    // Size unavailable — leave subtitle empty.
                }
                // Select button on the right to set as default.
                var select_btn = new Gtk.Button.with_label (_("Set as default"));
                select_btn.clicked.connect (() => {
                    settings.set_string ("model-path", path);
                    refresh_default_model_row ();
                    add_toast (new Adw.Toast (
                        _(@"Set default model to $name")));
                });
                row.add_suffix (select_btn);

                installed_group.add (row);
            }
        } catch (GLib.FileError e) {
            // First run: directory doesn't exist yet. Show a placeholder.
        }

        if (!any) {
            var placeholder = new Adw.ActionRow ();
            placeholder.title = _("No models installed");
            placeholder.subtitle = _("Use Download below to fetch one");
            installed_group.add (placeholder);
        }

        // Refresh the General page's Default model combo too — a model
        // downloaded externally should appear there without re-opening.
        refresh_default_model_row ();
    }

    [GtkCallback]
    private void on_download_tiny () { start_download (0); }
    [GtkCallback]
    private void on_download_base () { start_download (1); }
    [GtkCallback]
    private void on_download_small () { start_download (2); }

    private void start_download (int catalog_index) {
        if (download_cancellable != null) {
            add_toast (new Adw.Toast (_("A download is already running")));
            return;
        }
        var entry = CATALOG[catalog_index];

        // Ensure models dir exists. DirUtils.create_with_parents
        // returns the errno code (0 = success); it does not throw.
        models_dir = GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (), "kaki", "models");
        int rc = GLib.DirUtils.create_with_parents (models_dir, 0700);
        if (rc != 0) {
            add_toast (new Adw.Toast (
                _(@"Failed to create models dir: errno %d").printf (rc)));
            return;
        }

        string dest_path = GLib.Path.build_filename (models_dir, entry.filename);

        // Build a progress row showing spinner + label.
        active_progress_row = new Adw.ActionRow ();
        active_progress_row.title = entry.label;
        active_progress_row.subtitle = _("Starting download…");
        var spinner = new Adw.Spinner ();
        active_progress_row.add_suffix (spinner);

        download_progress_group.add (active_progress_row);
        download_progress_group.set_visible (true);

        download_cancellable = new Cancellable ();

        downloader.progress.connect (on_download_progress);
        downloader.completed.connect (on_download_completed);
        downloader.failed.connect (on_download_failed);

        downloader.download_async.begin (entry.url, dest_path, download_cancellable);
    }

    private void on_download_progress (int64 downloaded, int64 total) {
        if (active_progress_row == null)
            return;
        string dl = format_size (downloaded);
        if (total > 0)
            active_progress_row.subtitle = _(@"$dl / $(format_size (total))");
        else
            active_progress_row.subtitle = _(@"$dl downloaded");
    }

    private void on_download_completed (string local_path) {
        cleanup_download_ui ();
        add_toast (new Adw.Toast (_(@"Downloaded $(GLib.Path.get_basename (local_path))")));
        refresh_installed_models ();
    }

    private void on_download_failed (string message) {
        cleanup_download_ui ();
        add_toast (new Adw.Toast (_(@"Download failed: $message")));
        refresh_installed_models ();
    }

    private void cleanup_download_ui () {
        downloader.progress.disconnect (on_download_progress);
        downloader.completed.disconnect (on_download_completed);
        downloader.failed.disconnect (on_download_failed);

        if (active_progress_row != null) {
            download_progress_group.remove (active_progress_row);
            active_progress_row = null;
        }
        download_progress_group.set_visible (false);
        download_cancellable = null;
    }

    [GtkCallback]
    private async void on_open_models_dir () {
        var dir_path = GLib.Path.build_filename (
            GLib.Environment.get_user_data_dir (), "kaki", "models");
        // Create the dir if missing so the file manager opens a real
        // path instead of erroring out. DirUtils.create_with_parents
        // returns the errno code (0 = success); it does not throw.
        int rc = GLib.DirUtils.create_with_parents (dir_path, 0700);
        if (rc != 0) {
            add_toast (new Adw.Toast (
                _(@"Cannot create models directory: errno %d").printf (rc)));
            return;
        }

        var file = GLib.File.new_for_path (dir_path);
        var launcher = new Gtk.FileLauncher (file);
        try {
            // For a directory path, open_containing_folder opens the
            // directory itself in the default file manager (GTK 4.14+).
            // Pass our parent window so the file manager is transient
            // to the right toplevel.
            yield launcher.open_containing_folder (parent_window, null);
        } catch (GLib.Error e) {
            add_toast (new Adw.Toast (
                _(@"Cannot open models directory: $(e.message)")));
        }
    }

    /* =================================================================== */
    /* Shortcuts page                                                       */
    /* =================================================================== */

    private void populate_shortcuts_page () {
        // (label, action, setting key, default) — order matches the plan.
        var entries = new ShortcutEntry[] {
            { _("Record / Pause"),    "win.record",       "shortcut-record"    },
            { _("Stop"),              "win.stop",          "shortcut-stop"     },
            { _("Insert text"),       "win.insert",        "shortcut-insert"   },
            { _("Toggle dictation"),  "win.dictate",       "shortcut-dictate"  },
            { _("Show preferences"),  "app.preferences",   "shortcut-prefs"    },
            { _("Show shortcuts"),    "app.shortcuts",     "shortcut-shortcuts"},
            { _("Quit"),              "app.quit",          "shortcut-quit"     },
        };

        foreach (var e in entries) {
            var row = new Kaki.ShortcutRow (e.label, e.action, e.key, settings);
            row.shortcut_changed.connect (() => application.apply_shortcuts ());
            shortcuts_group.add (row);
        }
    }

    /* =================================================================== */
    /* API page                                                             */
    /* =================================================================== */

    private void populate_api_page () {
        // Transcription source.
        int src_idx = index_of (source_codes, settings.get_string ("transcription-source"));
        if (src_idx < 0)
            src_idx = 0;
        transcription_source_row.set_selected ((uint) src_idx);
        transcription_source_row.notify["selected"].connect (() => {
            uint s = transcription_source_row.get_selected ();
            settings.set_string ("transcription-source", source_codes[s]);
        });

        // EntryRows — direct GSettings bind.
        settings.bind ("api-endpoint", api_endpoint_row, "text",
                       GLib.SettingsBindFlags.DEFAULT);
        settings.bind ("api-model",     api_model_row,    "text",
                       GLib.SettingsBindFlags.DEFAULT);

        // PasswordEntryRow for the API key — backed by libsecret, not
        // GSettings. Load asynchronously; save on the apply signal.
        load_api_key_async.begin ();

        // Response format.
        int fmt_idx = index_of (response_codes, settings.get_string ("api-response-format"));
        if (fmt_idx < 0)
            fmt_idx = 0;
        response_format_row.set_selected ((uint) fmt_idx);
        response_format_row.notify["selected"].connect (() => {
            uint s = response_format_row.get_selected ();
            settings.set_string ("api-response-format", response_codes[s]);
        });

        // Temperature (double <-> double — direct bind).
        settings.bind ("api-temperature", temperature_row, "value",
                       GLib.SettingsBindFlags.DEFAULT);

        // Translate to English (bool <-> bool).
        settings.bind ("api-translate", translate_row, "active",
                       GLib.SettingsBindFlags.DEFAULT);
    }

    private async void load_api_key_async () {
        try {
            string? key = yield secret.get_api_key ();
            if (key != null)
                api_key_row.set_text (key);
        } catch (GLib.Error e) {
            warning ("loading API key: %s", e.message);
        }
    }

    [GtkCallback]
    private async void on_api_key_apply () {
        string key = api_key_row.get_text ();
        try {
            yield secret.set_api_key (key);
            add_toast (new Adw.Toast (key.length > 0
                ? _("API key saved")
                : _("API key cleared")));
        } catch (GLib.Error e) {
            add_toast (new Adw.Toast (
                _(@"Cannot save API key: $(e.message)")));
        }
    }

    [GtkCallback]
    private async void on_test_connection () {
        add_toast (new Adw.Toast (_("Testing connection…")));

        var session = new Soup.Session ();
        session.set_timeout (30);

        // Load the silent 100 ms WAV from the gresource bundle.
        GLib.Bytes sample;
        try {
            sample = GLib.resources_lookup_data (
                "/org/kaki/app/test-sample.wav", 0);
        } catch (GLib.Error e) {
            add_toast (new Adw.Toast (
                _(@"Missing test-sample.wav resource: $(e.message)")));
            return;
        }

        // Build multipart/form-data: file + scalar fields.
        var multipart = new Soup.Multipart ("multipart/form-data");
        multipart.append_form_file ("file", "sample.wav", "audio/wav", sample);
        multipart.append_form_string ("model",
            settings.get_string ("api-model"));
        multipart.append_form_string ("response_format",
            settings.get_string ("api-response-format"));
        multipart.append_form_string ("temperature",
            settings.get_double ("api-temperature").to_string ());
        if (settings.get_boolean ("api-translate"))
            multipart.append_form_string ("translate", "true");

        var msg = new Soup.Message.from_multipart (
            settings.get_string ("api-endpoint"), multipart);

        // Attach the API key from libsecret (not GSettings).
        string? key = null;
        try {
            key = yield secret.get_api_key ();
        } catch (GLib.Error e) {
            add_toast (new Adw.Toast (
                _(@"Cannot read API key from keyring: $(e.message)")));
            return;
        }
        if (key != null && key.length > 0)
            msg.request_headers.append ("Authorization", @"Bearer $key");

        try {
            GLib.Bytes body = yield session.send_and_read_async (
                msg, Priority.DEFAULT, null);
            uint status = (uint) msg.get_status ();
            string reason = msg.get_reason_phrase () ?? "";
            if (status >= 200 && status < 300) {
                add_toast (new Adw.Toast (
                    _(@"$status OK — %lld bytes").printf (body.get_size ())));
            } else {
                string body_text = (string) body.get_data ();
                string preview = body_text.length > 200
                    ? body_text.substring (0, 200) : body_text;
                add_toast (new Adw.Toast (
                    _(@"$status $reason: $preview")));
            }
        } catch (GLib.Error e) {
            add_toast (new Adw.Toast (
                _(@"Test connection failed: $(e.message)")));
        }
    }

    /* =================================================================== */
    /* Helpers                                                              */
    /* =================================================================== */

    private static int index_of (string[] arr, string value) {
        for (int i = 0; i < arr.length; i++)
            if (arr[i] == value)
                return i;
        return -1;
    }

    private static string format_size (int64 bytes) {
        if (bytes < 1024)
            return _(@"$bytes B");
        if (bytes < 1024 * 1024)
            return _(@"%.1f KB").printf ((double) bytes / 1024);
        if (bytes < 1024L * 1024 * 1024)
            return _(@"%.1f MB").printf ((double) bytes / (1024 * 1024));
        return _(@"%.2f GB").printf ((double) bytes / (1024L * 1024 * 1024));
    }
}

/* ----------------------------------------------------------------------- */
/* ModelCatalogEntry                                                       */
/* ----------------------------------------------------------------------- */

private struct ModelCatalogEntry {
    public string label;
    public string url;
    public string filename;
}

/* ----------------------------------------------------------------------- */
/* ShortcutEntry                                                           */
/* ----------------------------------------------------------------------- */

private struct ShortcutEntry {
    public string label;
    public string action;
    public string key;
}

/* ----------------------------------------------------------------------- */
/* ShortcutRow — a custom widget per plan § Shortcuts page                */
/* ----------------------------------------------------------------------- */

public class Kaki.ShortcutRow : Adw.ActionRow {
    public string action_name { get; construct set; }
    public string setting_key { get; construct set; }
    // Construct property: must be available when the `construct {}`
    // block runs, which is BEFORE the constructor body. Setting it
    // via Object(...) guarantees the timing.
    public GLib.Settings settings { get; construct; }

    private Gtk.ShortcutLabel shortcut_label;
    private Gtk.Button set_button;
    private Gtk.EventControllerKey key_controller;
    private bool capturing = false;

    // Emitted when the GSettings value for our shortcut changes. The
    // dialog connects to this and asks the application to re-apply
    // accelerators live (no restart required). Renamed from `changed`
    // to avoid shadowing Gtk.ListBoxRow.changed.
    public signal void shortcut_changed ();

    public ShortcutRow (string title, string action, string key,
                         GLib.Settings settings) {
        Object (title: title, action_name: action, setting_key: key,
                settings: settings);
    }

    construct {
        // settings is set by the time construct runs (it's a construct
        // property), so the initial label can be read from it.
        shortcut_label = new Gtk.ShortcutLabel (settings.get_string (setting_key));
        shortcut_label.valign = Gtk.Align.CENTER;
        add_suffix (shortcut_label);

        set_button = new Gtk.Button.with_label (_("Set…"));
        set_button.valign = Gtk.Align.CENTER;
        set_button.clicked.connect (on_set_clicked);
        add_suffix (set_button);

        // Listen for external changes to our setting (e.g. reset-to-default)
        // and refresh the label.
        settings.changed.connect (on_settings_changed);

        // ESC key on the row itself cancels capture mode.
        key_controller = new Gtk.EventControllerKey ();
        key_controller.key_pressed.connect (on_key_pressed);
        key_controller.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        ((Gtk.Widget) this).add_controller (key_controller);
    }

    private void on_settings_changed (string key) {
        if (key != setting_key)
            return;
        string accel = settings.get_string (setting_key);
        shortcut_label.set_accelerator (accel);
        // Tell the dialog so it can re-apply accels live.
        shortcut_changed ();
    }

    private void on_set_clicked () {
        if (capturing) {
            cancel_capture ();
            return;
        }
        capturing = true;
        set_button.label = _("Press keys…");
        set_button.add_css_class ("suggested-action");
        // Grab focus so the EventControllerKey (on the row) sees the
        // next keypress.
        set_button.grab_focus ();
    }

    private void cancel_capture () {
        capturing = false;
        set_button.label = _("Set…");
        set_button.remove_css_class ("suggested-action");
    }

    private bool on_key_pressed (uint keyval, uint keycode,
                                  Gdk.ModifierType state) {
        if (!capturing)
            return false;

        // ESC cancels.
        if (keyval == Gdk.Key.Escape) {
            cancel_capture ();
            return true;
        }
        // Backspace clears the shortcut (GTK / GNOME convention).
        if (keyval == Gdk.Key.BackSpace) {
            settings.set_string (setting_key, "");
            cancel_capture ();
            return true;
        }
        // Accept the first non-modifier key combo.
        if (Gtk.accelerator_valid (keyval, state)) {
            // Strip Lock and Super (caps-lock / num-lock) — they aren't
            // part of a meaningful accelerator and would only pollute
            // storage. SUPER_MASK corresponds to the old GTK3 MOD4_MASK.
            Gdk.ModifierType clean = state & ~(
                Gdk.ModifierType.LOCK_MASK |
                Gdk.ModifierType.SUPER_MASK);
            string accel = Gtk.accelerator_name (keyval, clean);
            settings.set_string (setting_key, accel);
            cancel_capture ();
            return true;
        }
        // Modifier-only press: keep waiting.
        return true;
    }
}
