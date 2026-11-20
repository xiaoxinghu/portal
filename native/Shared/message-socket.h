/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Message sockets for any backend on a POSIX system: the message socket
   primitives of native/Core/include/portal.h, written once on POSIX sockets
   and threads.  It uses no toolkit and no event loop, and so cannot do the
   one thing those primitives ask that is a platform's own: reach the module
   thread.  A backend gives that as a function, below, and its
   portal_socket_* are then these calls, one each.

   The five operations do what portal.h says of portal_socket_open, _send,
   _read, _wait and _close, with the same arguments, results, errors and
   bound, PORTAL_SOCKET_UNREAD; read portal.h for them.  Like those, they
   run on the module thread and nowhere else.  Each socket dials, upgrades,
   reads and writes on one thread of its own.

   Nothing here knows what a message means, or of Rex. */
#ifndef PORTAL_MESSAGE_SOCKET_H
#define PORTAL_MESSAGE_SOCKET_H

#include "portal.h"

/* SOCKET, which had nothing to read, has a message or its end to read.
   Called on the socket's own thread, with nothing locked, at most once
   until the next read; CONTEXT is what open was given.  It must not call
   back into this file.  The backend gets to the module thread, from its
   event loop, and calls portal_socket_ready (SOCKET) there.  A call may
   reach the module thread after the socket was closed: the core ignores a
   socket it has closed, and SOCKET is never another socket's name. */
typedef void (*portal_message_socket_wake)(uint64_t socket, void *context);

/* portal_socket_open, with the function that tells of what arrives, which
   must outlive the socket's thread: a function of the program's, and a
   CONTEXT never freed, or NULL. */
bool portal_message_socket_open(uint64_t socket, portal_string path, portal_string resource,
                                portal_string protocol, bool binary,
                                portal_message_socket_wake wake, void *context,
                                portal_text *error);
bool portal_message_socket_send(uint64_t socket, portal_string text, portal_text *error);
bool portal_message_socket_read(uint64_t socket, portal_text **messages, size_t *count,
                                bool *ended, int *code, portal_text *reason,
                                portal_text *error);
bool portal_message_socket_wait(uint64_t socket, uint64_t milliseconds, bool *ready,
                                portal_text *error);
bool portal_message_socket_close(uint64_t socket, portal_text *error);

#endif
