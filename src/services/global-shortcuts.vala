/* global-shortcuts.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * org.freedesktop.portal.GlobalShortcuts binding for a single
 * "toggle-recording" shortcut. Preferred path for toggling recording
 * from anywhere on the desktop (Wayland-friendly, no extra daemon).
 *
 * Flow:
 *   1. init()        — open a DBus proxy to org.freedesktop.portal.Desktop
 *                      and confirm the GlobalShortcuts interface is
 *                      implemented (some portal backends don't). Sets
 *                      `available` accordingly.
 *   2. bind()        — CreateSession + BindShortcuts for the single
 *                      shortcut id. The portal presents a dialog so the
 *                      user assigns a trigger combo.
 *   3. Activated sig — portal fires Activated(session, id, ...) when the
 *                      user presses the combo anywhere; we re-emit
 *                      `shortcut_activated(id)`. Kaki.Application wires
 *                      that to the record/stop toggle.
 *
 * The async portal pattern (method returns a request handle, result
 * arrives later via the org.freedesktop.portal.Request::Response signal
 * on that handle) is handled with a subscribe-before-call helper so the
 * Response signal can't be lost between the method reply and the
 * subscription. A 30 s timeout keeps bind() from hanging forever if the
 * portal never responds.
 *
 * On any failure `available` flips to false and the fallback path
 * (kaki-signal + Unix signals, see application.vala) takes over.
 */

[DBus (name = "org.freedesktop.portal.GlobalShortcuts")]
private interface Kaki.PortalGlobalShortcuts : GLib.Object {
    public abstract async GLib.ObjectPath create_session (
        GLib.HashTable<string, GLib.Variant> options) throws GLib.Error;
    public abstract async GLib.ObjectPath bind_shortcuts (
        GLib.ObjectPath session_handle,
        GLib.Variant shortcuts,
        string parent_window,
        GLib.HashTable<string, GLib.Variant> options) throws GLib.Error;
    public abstract async GLib.ObjectPath list_shortcuts (
        GLib.ObjectPath session_handle) throws GLib.Error;

    public signal void activated (GLib.ObjectPath session_handle,
                                   string shortcut_id,
                                   uint64 timestamp,
                                   GLib.HashTable<string, GLib.Variant> options);
    public signal void deactivated (GLib.ObjectPath session_handle,
                                     string shortcut_id,
                                     uint64 timestamp,
                                     GLib.HashTable<string, GLib.Variant> options);

    public abstract uint version { owned get; }
}

public class Kaki.GlobalShortcuts : GLib.Object {
    public bool available { get; private set; default = false; }

    public signal void shortcut_activated (string id);

    private const string _BUS_NAME    = "org.freedesktop.portal.Desktop";
    private const string _OBJECT_PATH = "/org/freedesktop/portal/desktop";

    // Since xdg-desktop-portal 0.9 the request handle is
    // /org/freedesktop/portal/desktop/request/SENDER/TOKEN, where SENDER
    // is the caller's unique bus name with the leading ':' stripped and
    // every '.' replaced by '_'. This form exists specifically so callers
    // can subscribe to the Response signal BEFORE invoking the method
    // (avoiding a lost-signal race), so we predict the handle from our own
    // unique name instead of subscribing to the wrong path and relying on
    // a post-reply resubscribe.
    private string _sender_segment () {
        string sender = _conn.get_unique_name ();
        // ":1.42" -> "1_42"
        string s = sender.substring (1);
        return s.replace (".", "_");
    }

    private PortalGlobalShortcuts? _portal = null;
    private GLib.DBusConnection?   _conn   = null;
    private GLib.ObjectPath?       _session_handle = null;
    private string                 _bound_id = "";
    private uint                   _counter  = 0;

    public async bool init () {
        try {
            _conn  = yield GLib.Bus.get (GLib.BusType.SESSION);
            _portal = yield GLib.Bus.get_proxy<PortalGlobalShortcuts> (
                GLib.BusType.SESSION, _BUS_NAME, _OBJECT_PATH);
            // Reading `version` confirms the interface is implemented by
            // the active portal backend. get_proxy itself succeeds even
            // when the backend doesn't expose GlobalShortcuts; the
            // property read is what fails.
            available = (_portal.version > 0);
            if (available)
                _portal.activated.connect (_on_activated);
        } catch (GLib.Error e) {
            available = false;
            warning ("GlobalShortcuts portal unavailable: %s", e.message);
        }
        return available;
    }

    private void _on_activated (GLib.ObjectPath sh, string id, uint64 ts,
                                 GLib.HashTable<string, GLib.Variant> opts) {
        if (_session_handle == null || sh != _session_handle)
            return;
        if (id == _bound_id)
            shortcut_activated (id);
    }

    public async void bind (string id, string description) {
        if (!available || _portal == null || _conn == null)
            return;
        _bound_id = id;

        // ----- CreateSession -----
        var cs_w = new _PortalWait ();
        cs_w.conn = _conn;
        // resume is captured BEFORE subscribing so a fast Response can't
        // arrive with resume still null.
        cs_w.resume = bind.callback;

        var cs_opts = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        cs_opts.insert ("session_handle_token",
                        new Variant.string ("kaki_session"));
        string cs_token = "kaki_create_session_%u".printf (++_counter);
        cs_opts.insert ("handle_token", new Variant.string (cs_token));
        string cs_expected =
            @"$(_OBJECT_PATH)/request/$(_sender_segment ())/$(cs_token)";

        cs_w.sub_id = _conn.signal_subscribe (
            _BUS_NAME, "org.freedesktop.portal.Request", "Response",
            cs_expected, null, GLib.DBusSignalFlags.NONE, cs_w.on_response);
        cs_w.timeout_id = GLib.Timeout.add_seconds (30, cs_w.on_timeout);

        // Fire CreateSession. The completion only resubscribes if the
        // portal ignored handle_token (or marks failure); it does NOT
        // resume bind — only the Response signal does, so the method-
        // reply and the result-signal can't race for the callback.
        _portal.create_session.begin (cs_opts, (obj, res) => {
            try {
                GLib.ObjectPath actual = _portal.create_session.end (res);
                if ((string) actual != cs_expected) {
                    // Pre-0.9 portal or unexpected handle: resubscribe on
                    // the actual path. Guard against a Response/timeout that
                    // already fired — otherwise the new subscription leaks
                    // (cs_w won't run _finish a second time).
                    if (cs_w.done)
                        return;
                    _conn.signal_unsubscribe (cs_w.sub_id);
                    cs_w.sub_id = _conn.signal_subscribe (
                        _BUS_NAME, "org.freedesktop.portal.Request",
                        "Response", (string) actual, null,
                        GLib.DBusSignalFlags.NONE, cs_w.on_response);
                }
            } catch (GLib.Error e) {
                _fail_request (cs_w, e.message);
            }
        });
        yield;

        if (cs_w.error != null || cs_w.raw_params == null) {
            warning ("CreateSession failed: %s", cs_w.error ?? "no response");
            available = false;
            return;
        }
        var cs_result = _unpack_response (cs_w.raw_params);
        if (cs_result == null) {
            warning ("CreateSession rejected by portal");
            available = false;
            return;
        }
        string? sh_str = _result_string (cs_result, "session_handle");
        if (sh_str == null) {
            warning ("CreateSession returned no session_handle");
            available = false;
            return;
        }
        _session_handle = new GLib.ObjectPath (sh_str);

        // ----- BindShortcuts -----
        // shortcuts: a(sa{sv}) — one (id, {description: description}).
        var vd = new GLib.VariantBuilder (new GLib.VariantType ("a{sv}"));
        vd.add ("{sv}", "description", new Variant.string (description));
        var entry = new GLib.VariantBuilder (new GLib.VariantType ("(sa{sv})"));
        entry.add ("s", id);
        entry.add_value (vd.end ());
        var arr = new GLib.VariantBuilder (new GLib.VariantType ("a(sa{sv})"));
        arr.add_value (entry.end ());
        var shortcuts_variant = arr.end ();

        var bs_w = new _PortalWait ();
        bs_w.conn = _conn;
        bs_w.resume = bind.callback;

        var bs_opts = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        string bs_token = "kaki_bind_shortcuts_%u".printf (++_counter);
        bs_opts.insert ("handle_token", new Variant.string (bs_token));
        string bs_expected =
            @"$(_OBJECT_PATH)/request/$(_sender_segment ())/$(bs_token)";

        bs_w.sub_id = _conn.signal_subscribe (
            _BUS_NAME, "org.freedesktop.portal.Request", "Response",
            bs_expected, null, GLib.DBusSignalFlags.NONE, bs_w.on_response);
        bs_w.timeout_id = GLib.Timeout.add_seconds (30, bs_w.on_timeout);

        _portal.bind_shortcuts.begin (
            _session_handle, shortcuts_variant, "", bs_opts, (obj, res) => {
            try {
                GLib.ObjectPath actual = _portal.bind_shortcuts.end (res);
                if ((string) actual != bs_expected) {
                    if (bs_w.done)
                        return;
                    _conn.signal_unsubscribe (bs_w.sub_id);
                    bs_w.sub_id = _conn.signal_subscribe (
                        _BUS_NAME, "org.freedesktop.portal.Request",
                        "Response", (string) actual, null,
                        GLib.DBusSignalFlags.NONE, bs_w.on_response);
                }
            } catch (GLib.Error e) {
                _fail_request (bs_w, e.message);
            }
        });
        yield;

        if (bs_w.error != null || bs_w.raw_params == null) {
            warning ("BindShortcuts failed: %s", bs_w.error ?? "no response");
            available = false;
            _session_handle = null;
            return;
        }
        var bs_result = _unpack_response (bs_w.raw_params);
        if (bs_result == null) {
            warning ("BindShortcuts rejected by portal");
            available = false;
            _session_handle = null;
        }
    }

    public async void unbind (string id) {
        // The portal Session interface has a Close method, but partial
        // unbind isn't supported. Dropping our handle and clearing the
        // bound id is enough: the portal tears the session down when the
        // connection closes, and we ignore any further Activated signals.
        _session_handle = null;
        _bound_id = "";
    }

    /* ----------------------------------------------------------------- */
    /* Portal request/response helper                                     */
    /* ----------------------------------------------------------------- */

    // Per-request state shared between the async caller and its DBus
    // signal / timeout callbacks. Held alive by the signal subscription
    // and the timeout source until one of them fires and resumes the
    // caller. `resume` is captured BEFORE subscribing (in bind()) so a
    // fast Response can't find it null.
    private class _PortalWait : GLib.Object {
        public uint sub_id = 0;
        public uint timeout_id = 0;
        public bool done = false;
        public GLib.Variant? raw_params = null;
        public string? error = null;
        // Strong: the wait outlives the async caller's stack frame while a
        // subscription / timeout is pending; a weak ref could dangle if a
        // future refactor changes that lifetime invariant.
        public GLib.DBusConnection conn;
        public SourceFunc resume;

        // public so the enclosing class's _fail_request helper can call it;
        // _PortalWait itself is private so this isn't part of the API.
        public void _finish (GLib.Variant? params, string? err) {
            if (done)
                return;
            done = true;
            raw_params = params;
            error = err;
            if (sub_id != 0) {
                conn.signal_unsubscribe (sub_id);
                sub_id = 0;
            }
            if (timeout_id != 0) {
                GLib.Source.remove (timeout_id);
                timeout_id = 0;
            }
            if (resume != null) {
                var r = (owned) resume;
                Idle.add ((owned) r);
            }
        }

        public void on_response (GLib.DBusConnection c, string? sender,
                                 string object_path, string interface_name,
                                 string signal_name, GLib.Variant parameters) {
            _finish (parameters, null);
        }

        public bool on_timeout () {
            _finish (null, "timed out");
            return GLib.Source.REMOVE;
        }
    }

    // Called from a portal method's AsyncReadyCallback when the call
    // itself (not the Response) fails. Marks the wait done and resumes
    // bind(); the Response subscription is torn down so a late signal
    // can't double-resume.
    private static void _fail_request (_PortalWait w, string message) {
        w._finish (null, message);
    }

    // Response signal payload is (u response, a{sv} results). Pull the
    // results vardict out as a HashTable<string, Variant> so callers can
    // look up keys directly. Returns null when the portal rejected the
    // request (non-zero response code).
    private static GLib.HashTable<string, GLib.Variant>? _unpack_response (
        GLib.Variant params) {
        uint code;
        GLib.Variant dict_v;
        params.get ("(u@a{sv})", out code, out dict_v);
        if (code != 0)
            return null;
        var ht = new GLib.HashTable<string, GLib.Variant> (str_hash, str_equal);
        var iter = new GLib.VariantIter (dict_v);
        GLib.Variant entry;
        while ((entry = iter.next_value ()) != null) {
            string k = entry.get_child_value (0).get_string ();
            GLib.Variant v = entry.get_child_value (1).get_variant ();
            ht.insert (k, v);
        }
        return ht;
    }

    private static string? _result_string (
        GLib.HashTable<string, GLib.Variant> results, string key) {
        GLib.Variant? v = results.lookup (key);
        if (v == null)
            return null;
        return v.get_string ();
    }
}
