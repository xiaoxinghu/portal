/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Connections to Rex servers, as the Emacs bindings use them.  rex.c
   implements these with the message socket primitives of portal.h and, for
   the platform, portal_socket_ready.  Only the core, tests and the
   standalone checks include this header.

   A connection is Portal's end of one Rex server's control protocol.  Each
   has an ID that no other connection, earlier or later, ever has.  An ID
   that names no open connection fails with "No Rex connection ID".

   The core owns what every connection says first and how a request is
   written; it does not read what the server sends.  Messages wait with the
   platform, outside the pipe, so a long result never crosses it: the first
   one waiting sends Emacs the record "rex ID", and no other goes until
   Emacs has received them all.  Lisp parses them (portal-rex.el). */
#ifndef PORTAL_REX_H
#define PORTAL_REX_H

#include "portal.h"

/* The one revision of Rex's API that Portal speaks.  The server translates
   every message to and from it, so a newer server changes nothing here. */
enum { PORTAL_REX_API_REVISION = 12 };

/* Start connecting to the Rex server listening on the Unix socket at PATH,
   an absolute file name, and set *ID to the connection's new ID.  The
   connection's first message is its hello: PORTAL_REX_API_REVISION as both
   the oldest and the newest revision Portal speaks, and the client's NAME
   and VERSION, which the server shows its other clients.  This returns
   before the server is reached: the server's welcome, or why the connection
   ended, arrives like any other message.  On failure nothing is open. */
bool portal_rex_open(portal_string path, portal_string name, portal_string version, uint64_t *id,
                     portal_text *error);

/* Ask connection ID's server to run METHOD, such as "session.list", with
   PAYLOAD, its arguments as a JSON object, and set *REQUEST to the request's
   number, which the server's response carries as its "id", in decimal.  A
   connection never gives two requests one number.  Requests made before the
   server is reached follow the hello.  Fails, sending nothing, for an empty
   METHOD or a PAYLOAD that is not written as a JSON object. */
bool portal_rex_request(uint64_t id, portal_string method, portal_string payload,
                        uint64_t *request, portal_text *error);

/* Take the messages waiting for Emacs on connection ID, oldest first, each
   as the server sent it: *MESSAGES is an array of *COUNT texts, allocated
   with malloc like each text, for the caller to free.  The next message
   sends a new record.  When the connection has ended, these are its last
   messages: *ENDED is set and *REASON says why, for the caller to free, and
   ID names no connection from then on. */
bool portal_rex_receive(uint64_t id, portal_text **messages, size_t *count, bool *ended,
                        portal_text *reason, portal_text *error);

/* Wait until connection ID has something to receive, a message or its end,
   for at most MILLISECONDS, and set *READY to whether it has.  This blocks
   Emacs, so callers wait in short turns. */
bool portal_rex_wait(uint64_t id, uint64_t milliseconds, bool *ready, portal_text *error);

/* End connection ID, dropping what Emacs has not received.  No record
   names it afterwards. */
bool portal_rex_close(uint64_t id, portal_text *error);

#endif
