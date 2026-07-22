/*
 * signal-shim.c
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * SIGRTMIN is a compile-time constant on musl but a function-based macro
 * on glibc (it may reserve the lowest realtime signal for the libc).
 * Vala's posix.vapi has no binding for it, so expose the macro through a
 * tiny C function that both libcs resolve at link time. The +1 offset
 * (the first user-usable realtime signal) is applied at the call site.
 */
#include <signal.h>

int kaki_sigrtmin (void) {
    return SIGRTMIN;
}
