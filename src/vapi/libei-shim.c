/* libei-shim.c
 *
 * C helpers wrapping libei's sentinel-terminated variadic functions
 * so they can be called from Vala without binding the varargs. Only
 * the KEYBOARD + TEXT (since libei 1.6) capabilities are bound, which
 * is all Kaki's dictation mode needs.
 *
 * TEXT (EI_DEVICE_CAP_TEXT = 1 << 6) was added in libei 1.6. On older
 * libei the value is unknown to the EIS implementation and
 * ei_seat_bind_capabilities treats unknown caps as a no-op, so this
 * shim is safe to compile against any libei-1.0.
 *
 * SPDX-License-Identifier: MIT
 */

#include "libei-shim.h"

void
kaki_ei_seat_bind_keyboard_text(struct ei_seat *seat)
{
    ei_seat_bind_capabilities(seat,
                              EI_DEVICE_CAP_KEYBOARD,
                              EI_DEVICE_CAP_TEXT,
                              NULL);
}

void
kaki_ei_seat_unbind_keyboard_text(struct ei_seat *seat)
{
    ei_seat_unbind_capabilities(seat,
                                EI_DEVICE_CAP_KEYBOARD,
                                EI_DEVICE_CAP_TEXT,
                                NULL);
}
