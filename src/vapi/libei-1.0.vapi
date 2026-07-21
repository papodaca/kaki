/* libei.vapi
 *
 * Minimal Vala binding for the libei-1.0 client (sender) C API.
 *
 * Only the subset Kaki's keystroke injection needs is bound: context
 * setup, the seat/device event loop, keyboard key events, and (since
 * libei 1.6) UTF-8 text events. The receiver API and the
 * pointer/touch/scroll/button emitters are omitted.
 *
 * The libei C API uses opaque, refcounted structs declared as
 * `struct ei` / `struct ei_seat` / `struct ei_device` / `struct ei_event`
 * (no typedefs), so the cname for each Compact class carries the
 * `struct` keyword. Refcounting is wired through ref_function /
 * unref_function so Vala's ownership tracking balances refs on owned
 * assignment and drops unref on scope exit.
 *
 * The sentinel-terminated variadics ei_seat_bind_capabilities /
 * ei_seat_unbind_capabilities are not bindable directly in Vala; they
 * are wrapped by the C helpers in src/vapi/libei-shim.c
 * (kaki_ei_seat_bind_keyboard_text / kaki_ei_seat_unbind_keyboard_text),
 * which are declared here as plain methods on Seat.
 *
 * SPDX-License-Identifier: MIT
 */

[CCode (cprefix = "Ei", lower_case_cprefix = "ei_", cheader_filename = "libei.h,libei-shim.h")]
namespace Ei {

    [CCode (cname = "enum ei_event_type", cprefix = "EI_EVENT_")]
    public enum EventType {
        CONNECT = 1,
        DISCONNECT,
        SEAT_ADDED,
        SEAT_REMOVED,
        DEVICE_ADDED,
        DEVICE_REMOVED,
        DEVICE_PAUSED,
        DEVICE_RESUMED,
        KEYBOARD_MODIFIERS,
        PONG = 90,
        SYNC,
        FRAME = 100,
        DEVICE_START_EMULATING = 200,
        DEVICE_STOP_EMULATING,
        POINTER_MOTION = 300,
        POINTER_MOTION_ABSOLUTE = 400,
        BUTTON_BUTTON = 500,
        SCROLL_DELTA = 600,
        SCROLL_STOP,
        SCROLL_CANCEL,
        SCROLL_DISCRETE,
        KEYBOARD_KEY = 700,
        TOUCH_DOWN = 800,
        TOUCH_UP,
        TOUCH_MOTION,
        TEXT_KEYSYM = 900,
        TEXT_UTF8
    }

    [CCode (cname = "enum ei_device_capability", cprefix = "EI_DEVICE_CAP_")]
    [Flags]
    public enum DeviceCapability {
        POINTER        = 1 << 0,
        POINTER_ABSOLUTE = 1 << 1,
        KEYBOARD       = 1 << 2,
        TOUCH          = 1 << 3,
        SCROLL         = 1 << 4,
        BUTTON         = 1 << 5,
        TEXT           = 1 << 6
    }

    [CCode (cname = "enum ei_device_type", cprefix = "EI_DEVICE_TYPE_")]
    public enum DeviceType {
        VIRTUAL = 1,
        PHYSICAL
    }

    [CCode (cname = "struct ei", ref_function = "ei_ref", unref_function = "ei_unref")]
    [Compact]
    public class Context {
        [CCode (cname = "ei_new_sender")]
        public Context (void* user_data = null);
        [CCode (cname = "ei_configure_name")]
        public void configure_name (string name);
        [CCode (cname = "ei_setup_backend_socket")]
        public int setup_backend_socket (string? socketpath = null);
        [CCode (cname = "ei_get_fd")]
        public int get_fd ();
        [CCode (cname = "ei_dispatch")]
        public void dispatch ();
        [CCode (cname = "ei_get_event")]
        public Event? get_event ();
        [CCode (cname = "ei_now")]
        public uint64 now ();
        [CCode (cname = "ei_disconnect")]
        public void disconnect ();
    }

    [CCode (cname = "struct ei_seat", ref_function = "ei_seat_ref", unref_function = "ei_seat_unref")]
    [Compact]
    public class Seat {
        [CCode (cname = "kaki_ei_seat_bind_keyboard_text")]
        public void bind_keyboard_text ();
        [CCode (cname = "kaki_ei_seat_unbind_keyboard_text")]
        public void unbind_keyboard_text ();
        [CCode (cname = "ei_seat_has_capability")]
        public bool has_capability (DeviceCapability cap);
        [CCode (cname = "ei_seat_get_name")]
        public unowned string? get_name ();
        [CCode (cname = "ei_seat_get_context")]
        public unowned Context get_context ();
    }

    [CCode (cname = "struct ei_device", ref_function = "ei_device_ref", unref_function = "ei_device_unref")]
    [Compact]
    public class Device {
        [CCode (cname = "ei_device_has_capability")]
        public bool has_capability (DeviceCapability cap);
        [CCode (cname = "ei_device_get_name")]
        public unowned string? get_name ();
        [CCode (cname = "ei_device_get_type")]
        public DeviceType get_type ();
        [CCode (cname = "ei_device_get_context")]
        public unowned Context get_context ();
        [CCode (cname = "ei_device_get_seat")]
        public unowned Seat get_seat ();
        [CCode (cname = "ei_device_start_emulating")]
        public void start_emulating (uint32 sequence);
        [CCode (cname = "ei_device_stop_emulating")]
        public void stop_emulating ();
        [CCode (cname = "ei_device_keyboard_key")]
        public void keyboard_key (uint32 keycode, bool is_press);
        [CCode (cname = "ei_device_text_utf8_with_length")]
        public void text_utf8 (string text, size_t length);
        [CCode (cname = "ei_device_frame")]
        public void frame (uint64 time);
        [CCode (cname = "ei_device_close")]
        public void close ();
    }

    [CCode (cname = "struct ei_event", ref_function = "ei_event_ref", unref_function = "ei_event_unref")]
    [Compact]
    public class Event {
        [CCode (cname = "ei_event_get_type")]
        public EventType get_type ();
        [CCode (cname = "ei_event_get_device")]
        public unowned Device? get_device ();
        [CCode (cname = "ei_event_get_seat")]
        public unowned Seat? get_seat ();
        [CCode (cname = "ei_event_emulating_get_sequence")]
        public uint32 emulating_get_sequence ();
    }
}
