/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The notification pipe, as the rest of the core uses it.  channel.c
   implements these and, for the platform, portal_timer_fired from portal.h.
   Only the core and tests include this header: the platform sends records
   through portal_notify or the launcher's and hot keys' events, and never
   connects the pipe. */
#ifndef PORTAL_CHANNEL_H
#define PORTAL_CHANNEL_H

#include <stdbool.h>
#include <sys/types.h>

#include "portal.h"

/* Send records to FD, the write end of Emacs's record pipe, or keep them
   waiting while FD is -1.  Records already waiting go to FD first, in order.
   On success the core owns FD, closes the descriptor it had unless that is
   FD, and cancels any pending retry.  On failure errno says why and nothing
   changes: FD stays the caller's and the old pipe stays connected. */
bool portal_channel_connect(int fd);

/* Send the record "TYPE TARGET FIELD...", as portal_notify does, whatever
   TARGET names; views.c checks it first for the platform. */
bool portal_channel_send(portal_string type, portal_string target, const portal_string *fields,
                         size_t count);

/* Start a timer for another part of the core, and return its token, which
   no other timer has: portal_timer_fired passes a token that is not the
   channel's own to that part (rex.c). */
uint64_t portal_channel_timer(uint64_t milliseconds);

/* How the channel writes: write(2), unless a test replaces it to produce what
   a real pipe cannot on demand, such as EINTR or a short write. */
extern ssize_t (*portal_channel_write)(int fd, const void *bytes, size_t length);

#endif
