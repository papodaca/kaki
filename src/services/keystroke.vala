/* keystroke.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Keystroke injection for dictation mode. The backend is picked once
 * at init() per the Phase 3 fallback chain:
 *
 *   preferred != AUTO → that backend only (NONE if unavailable)
 *   AUTO              → libei (if compiled in) → ydotool → xdotool → NONE
 *
 * For AUTO with libei compiled in, a runtime socket-setup failure falls
 * back to the subprocess backends so a system without an EIS server
 * still gets dictation; an explicit `libei` request that fails setup
 * surfaces as NONE (and the window shows the "no backend" toast).
 *
 * Streaming partials arrive faster than any backend can usefully emit
 * them, so type_text() appends to a coalescing buffer and a ~60 ms
 * Timeout drains it. libei drains inline (one text_utf8 + frame per
 * flush); ydotool/xdotool spawn one subprocess per flush, serialized
 * by a _busy flag so keystrokes never interleave.
 *
 * libei wiring: an IOChannel watch on ei_get_fd() calls ei_dispatch()
 * and drains ei_get_event() on activity. The handshake (CONNECT →
 * SEAT_ADDED → bind KEYBOARD+TEXT → DEVICE_ADDED → ref → DEVICE_RESUMED
 * → start_emulating) is handled in process_event(); text queued while
 * the device is not yet resumed is flushed on DEVICE_RESUMED.
 */

public class Kaki.Keystroke : GLib.Object {
    public enum Backend {
        AUTO,
        LIBEI,
        YDOTOOL,
        XDOTOOL,
        NONE
    }

    public Backend backend { get; private set; default = Backend.NONE; }

    private const uint FLUSH_MS = 60;

    private GLib.Settings _settings;
    private GLib.StringBuilder _pending = new GLib.StringBuilder ();
    private uint _flush_source = 0;
    private bool _busy = false;

#if HAVE_LIBEI
    private Ei.Context? _ei = null;
    private Ei.Seat?    _seat = null;
    private Ei.Device?  _device = null;
    private bool        _ready = false;
    private uint32       _sequence = 0;
    private uint         _io_watch = 0;
#endif

    /* ----------------------------------------------------------------- */
    /* init / backend selection                                          */
    /* ----------------------------------------------------------------- */

    public bool init (Backend preferred) {
        _settings = new GLib.Settings ("org.kaki.app");

        Backend chosen = select_backend (preferred);

        if (chosen == Backend.LIBEI) {
#if HAVE_LIBEI
            if (!setup_libei ()) {
                if (preferred != Backend.AUTO) {
                    backend = Backend.NONE;
                    return false;
                }
                chosen = select_subprocess_fallback ();
                if (chosen == Backend.NONE) {
                    backend = Backend.NONE;
                    return false;
                }
            }
#else
            // libei requested but not compiled in; select_backend would
            // already have returned NONE for AUTO, so this is an explicit
            // libei request against a libei-less build.
            backend = Backend.NONE;
            return false;
#endif
        }

        if (chosen == Backend.NONE) {
            backend = Backend.NONE;
            return false;
        }

        backend = chosen;
        return true;
    }

    private Backend select_backend (Backend preferred) {
        if (preferred == Backend.LIBEI) {
#if HAVE_LIBEI
            return Backend.LIBEI;
#else
            return Backend.NONE;
#endif
        }
        if (preferred == Backend.YDOTOOL) {
            return (GLib.Environment.find_program_in_path ("ydotool") != null)
                ? Backend.YDOTOOL : Backend.NONE;
        }
        if (preferred == Backend.XDOTOOL) {
            return xdotool_available () ? Backend.XDOTOOL : Backend.NONE;
        }
        // AUTO
#if HAVE_LIBEI
        return Backend.LIBEI;
#else
        return select_subprocess_fallback ();
#endif
    }

    private Backend select_subprocess_fallback () {
        if (GLib.Environment.find_program_in_path ("ydotool") != null)
            return Backend.YDOTOOL;
        if (xdotool_available ())
            return Backend.XDOTOOL;
        return Backend.NONE;
    }

    private static bool xdotool_available () {
        if (GLib.Environment.find_program_in_path ("xdotool") == null)
            return false;
        string? session = GLib.Environment.get_variable ("XDG_SESSION_TYPE");
        return session != null && session == "x11";
    }

    /* ----------------------------------------------------------------- */
    /* type_text / type_key                                              */
    /* ----------------------------------------------------------------- */

    public async void type_text (string text, GLib.Cancellable? cancellable = null) {
        if (backend == Backend.NONE)
            return;
        if (text == null || text.length == 0)
            return;
        _pending.append (text);
        schedule_flush ();
    }

    public async void type_key (uint keycode, bool press,
                                 GLib.Cancellable? cancellable = null) {
        if (backend == Backend.NONE)
            return;
#if HAVE_LIBEI
        if (backend == Backend.LIBEI) {
            if (_ready && _device != null && _ei != null) {
                _device.keyboard_key (keycode, press);
                _device.frame (_ei.now ());
            }
            return;
        }
#endif
        if (backend == Backend.YDOTOOL) {
            yield ydotool_key (keycode, press);
        } else if (backend == Backend.XDOTOOL) {
            yield xdotool_key (keycode, press);
        }
    }

    /* ----------------------------------------------------------------- */
    /* coalescing flush                                                  */
    /* ----------------------------------------------------------------- */

    private void schedule_flush () {
        if (_flush_source != 0)
            return;
        _flush_source = GLib.Timeout.add (FLUSH_MS, on_flush_timeout);
    }

    private bool on_flush_timeout () {
        _flush_source = 0;
        do_flush ();
        return GLib.Source.REMOVE;
    }

    private void do_flush () {
        if (_busy)
            return;
        if (_pending.len == 0)
            return;

#if HAVE_LIBEI
        if (backend == Backend.LIBEI) {
            if (!_ready)
                return;  // flushed on DEVICE_RESUMED
            string text = _pending.str.dup ();
            _pending.truncate (0);
            libei_send_text (text);
            return;
        }
#endif

        string text = _pending.str.dup ();
        _pending.truncate (0);
        dispatch_subprocess.begin (text);
    }

    private async void dispatch_subprocess (string text) {
        _busy = true;
        if (backend == Backend.YDOTOOL) {
            yield ydotool_type (text);
        } else if (backend == Backend.XDOTOOL) {
            yield xdotool_type (text);
        }
        _busy = false;

        // Text that arrived while the subprocess was running is flushed
        // immediately so the next burst doesn't wait for a fresh Timeout.
        if (_pending.len > 0) {
            string more = _pending.str.dup ();
            _pending.truncate (0);
            dispatch_subprocess.begin (more);
        }
    }

    /* ----------------------------------------------------------------- */
    /* libei backend                                                    */
    /* ----------------------------------------------------------------- */

#if HAVE_LIBEI
    private bool setup_libei () {
        _ei = new Ei.Context ();
        _ei.configure_name ("kaki");

        int r = _ei.setup_backend_socket (null);
        if (r < 0) {
            warning ("ei_setup_backend_socket failed: %d (set LIBEI_SOCKET?)", r);
            _ei = null;
            return false;
        }

        int fd = _ei.get_fd ();
        var chan = new GLib.IOChannel.unix_new (fd);
        _io_watch = chan.add_watch (
            GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
            on_libei_fd);
        return true;
    }

    private bool on_libei_fd (GLib.IOChannel source, GLib.IOCondition cond) {
        if ((cond & (GLib.IOCondition.HUP | GLib.IOCondition.ERR)) != 0) {
            libei_handle_disconnect ();
            return false;
        }
        if (_ei == null)
            return false;
        _ei.dispatch ();
        drain_events ();
        return true;
    }

    private void drain_events () {
        while (_ei != null) {
            var ev = _ei.get_event ();
            if (ev == null)
                break;
            process_event (ev);
        }
    }

    private void process_event (Ei.Event ev) {
        switch (ev.get_type ()) {
        case Ei.EventType.CONNECT:
            break;

        case Ei.EventType.SEAT_ADDED:
            var seat = ev.get_seat ();
            if (seat != null) {
                seat.bind_keyboard_text ();
                _seat = seat;
            }
            break;

        case Ei.EventType.DEVICE_ADDED:
            var dev = ev.get_device ();
            // text_utf8 requires EI_DEVICE_CAP_TEXT; prefer a device
            // that also has KEYBOARD (for type_key), but TEXT is the
            // hard requirement for the dictation text path.
            if (dev != null && dev.has_capability (Ei.DeviceCapability.TEXT)) {
                _device = dev;
            }
            break;

        case Ei.EventType.DEVICE_RESUMED:
            if (_device != null && ev.get_device () == _device) {
                _ready = true;
                _device.start_emulating (++_sequence);
                do_flush ();
            }
            break;

        case Ei.EventType.DEVICE_PAUSED:
            _ready = false;
            break;

        case Ei.EventType.DEVICE_REMOVED:
            if (ev.get_device () == _device) {
                _ready = false;
                _device = null;
            }
            break;

        case Ei.EventType.SEAT_REMOVED:
            _seat = null;
            break;

        case Ei.EventType.DISCONNECT:
            libei_handle_disconnect ();
            break;

        default:
            break;
        }
    }

    private void libei_send_text (string text) {
        if (!_ready || _device == null || _ei == null)
            return;
        _device.text_utf8 (text, text.length);
        _device.frame (_ei.now ());
    }

    private void libei_handle_disconnect () {
        _ready = false;
        _device = null;
        _seat = null;
        if (_io_watch != 0) {
            GLib.Source.remove (_io_watch);
            _io_watch = 0;
        }
        _ei = null;
    }
#endif

    /* ----------------------------------------------------------------- */
    /* ydotool backend                                                  */
    /* ----------------------------------------------------------------- */

    private async void ydotool_type (string text) {
        int delay = _settings.get_int ("dictation-key-delay-ms");
        try {
            var launcher = new GLib.SubprocessLauncher (GLib.SubprocessFlags.NONE);
            launcher.setenv ("YDOTOOL_SLEEP_POST_TYPE", "n", true);
            var sub = launcher.spawnv ({
                "ydotool", "type",
                "--key-delay", delay.to_string (),
                "--", text
            });
            yield sub.wait_async ();
        } catch (GLib.Error e) {
            warning ("ydotool type failed: %s", e.message);
        }
    }

    private async void ydotool_key (uint keycode, bool press) {
        try {
            var sub = new GLib.Subprocess (GLib.SubprocessFlags.NONE,
                "ydotool", "key", "%u:%d".printf (keycode, press ? 1 : 0));
            yield sub.wait_async ();
        } catch (GLib.Error e) {
            warning ("ydotool key failed: %s", e.message);
        }
    }

    /* ----------------------------------------------------------------- */
    /* xdotool backend                                                  */
    /* ----------------------------------------------------------------- */

    private async void xdotool_type (string text) {
        int delay = _settings.get_int ("dictation-key-delay-ms");
        try {
            var sub = new GLib.Subprocess (GLib.SubprocessFlags.NONE,
                "xdotool", "type",
                "--clearmodifiers",
                "--delay", delay.to_string (),
                "--", text);
            yield sub.wait_async ();
        } catch (GLib.Error e) {
            warning ("xdotool type failed: %s", e.message);
        }
    }

    private async void xdotool_key (uint keycode, bool press) {
        // xdotool key takes XKB keysym names, not evdev scancodes; the
        // libei/ydotool keycode path is not directly applicable. type_key
        // is not used by Phase 3 dictation, so we log and no-op here
        // rather than ship a fragile scancode→keysym table.
        warning ("xdotool type_key not implemented (keycode %u, press %s)",
                 keycode, press.to_string ());
    }

    /* ----------------------------------------------------------------- */
    /* cleanup                                                          */
    /* ----------------------------------------------------------------- */

    public override void dispose () {
        if (_flush_source != 0) {
            GLib.Source.remove (_flush_source);
            _flush_source = 0;
        }
#if HAVE_LIBEI
        if (_io_watch != 0) {
            GLib.Source.remove (_io_watch);
            _io_watch = 0;
        }
        _ready = false;
        _device = null;
        _seat = null;
        _ei = null;
#endif
        base.dispose ();
    }
}
