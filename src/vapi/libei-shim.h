/* libei-shim.h
 *
 * Declarations for the C helpers in libei-shim.c that wrap libei's
 * sentinel-terminated variadic ei_seat_bind_capabilities /
 * ei_seat_unbind_capabilities calls so they can be called from Vala.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <libei.h>

void kaki_ei_seat_bind_keyboard_text(struct ei_seat *seat);
void kaki_ei_seat_unbind_keyboard_text(struct ei_seat *seat);
