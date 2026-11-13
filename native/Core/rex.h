/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Connections to Rex servers, as the Emacs bindings use them.  rex.c
   implements these with the message socket primitives of portal.h and, for
   the platform, portal_socket_ready.  Only the core, tests and the
   standalone checks include this header.

   A connection is Portal's end of one Rex server's control protocol.  Each
   has an ID that no other connection, earlier or later, ever has.  An ID
   that names no open connection fails with "No Rex connection ID".

   The core owns what every connection says first and how a request is
   written; of what the server sends, it reads only the answers to its own
   requests and the events of the blocks it shows.  Messages wait with the
   platform, outside the pipe, so a long result never crosses it: the first
   one waiting sends Emacs the record "rex ID", and no other goes until
   Emacs has received them all.  Lisp parses them (portal-rex.el). */
#ifndef PORTAL_REX_H
#define PORTAL_REX_H

#include "portal.h"

struct json; /* core.h */

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
   names it afterwards, and the blocks it showed end, as below. */
bool portal_rex_close(uint64_t id, portal_text *error);

/* Blocks shown in terminals.  The core also makes requests of its own on
   a connection, numbered among Emacs's, and takes their responses out of
   what the server sends before Emacs receives it: Emacs never sees them.

   Show the block BLOCK, of the session SESSION on connection ID's server,
   in TARGET, an open fed terminal (portal.h), from now until TARGET
   closes.  This returns at once; the core then, in turn, attaches the
   connection to SESSION unless it has, claims the block with "request",
   which makes Emacs its owner only if no other client is, waits for the
   grid of TARGET's pane to settle and sends it as Emacs's size for the
   block, opens the block's data stream, skips its snapshot, paints TARGET
   from the server's "format" of the screen in VT form, unwrapped, and then
   feeds it the stream's bytes from the snapshot on, without Rex's own
   messages.  From then on what TARGET writes is typed into the block, one
   request at a time so that it arrives in order, except the terminal's own
   reports of focus, size and colour scheme, which the server makes for
   itself; a change of who has the keyboard is sent as a "focus" block
   event, and a change of the grid of TARGET's pane is sent as Emacs's size
   for the block, whoever owns it.  The paint leaves the server's palette
   out, so TARGET keeps its own theme's colours.

   A block has the size its owner gives it.  The server keeps the size
   every other client sends and applies a client's the moment it becomes
   the owner, so claiming the block with "take" (portal_rex_take) is all
   it takes to size it to Emacs's pane.  TARGET always holds the block's
   grid, from the paint on and from each "resize" message at its place in
   the stream (portal_terminal_hold_grid), as the stream's bytes are laid
   out for it, whoever sized it.  A resize to another grid while the paint
   is on its way asks for the paint again, for that grid, and drops the
   output held until then, as the new paint has it.  A paint that comes
   before the stream has given the grid waits for it.  A key typed into a block that another
   client owns, or whose owner is not known yet, takes it first.

   As it claims the block, the core also asks for the terminal's title,
   reported directory and processes, once, and from then on follows the
   block's events of each: title_changed, pwd_changed, process_changed and
   child_exited, and of its owner, block_owner_changed, which the claims'
   answers say too.  An event that overtakes an answer wins, by its seq.
   A change tells Emacs with a "terminal TARGET" record, as a terminal's
   platform does (portal.h).

   Fails, starting nothing, for a closed connection, a TARGET that names no
   open fed terminal or shows a block already, or a block that another
   terminal shows on this connection, as a server allows one stream of a
   block per client. */
bool portal_rex_show(uint64_t id, portal_string target, portal_string session,
                     portal_string block, portal_text *error);

/* Claim TARGET's block with "take", once the claim the show makes has been
   answered: Emacs owns it from then on, and it takes Emacs's size, until
   another client takes it.  A take already waiting stands for this one.
   Fails, sending nothing, for a TARGET that shows no block. */
bool portal_rex_take(portal_string target, portal_text *error);

/* For views.c: what TARGET shows, if it shows a block, as the members
   ,"title":T,"pwd":P,"program":G,"exited":E,
   "rex":{"state":STATE,"columns":C,"rows":R,"owner":O,"owner_name":N,
   "directory":P} appended to
   JSON, with "reason" after them once it has failed or ended.

   T, P, G and E are what a terminal's platform describes of a terminal
   with its own pty (portal.h), for the block's program: T its title, ""
   until one is set; P the block's directory, the last its program
   reported (OSC 7) from this Mac, percent-decoded, and until one does,
   the working directory of its foreground process, "" until known; G its
   foreground process, by Rex's label (its script, else its argv0 without
   a login shell's "-", else its name), "" until known and once the
   program has exited; and E whether the program has exited and the block
   stayed.  A block whose program exits usually closes at once, so E waits
   a quarter of a second for that, and never becomes true for a block that
   closes.  The block's directory is also the terminal's, as every server
   Portal reaches is on this Mac.

   STATE is "starting" until the first paint, then "live", or "failed" or
   "ended" once the stream will bring nothing more; C and R are the
   block's grid as the stream last said, 0 until it has; O is who owns the
   block, as the server last said: "self" for Emacs, "other" for another
   client, "none" for no client, "unknown" until the server has said; and
   N what the other client calls itself, its label or else its program's
   name, "" until the server says, which it does only while that client
   is connected.  The core sends
   Emacs the record "rex-block TARGET" when the state becomes live, failed
   or ended, and no other until TARGET is described; a stream that ends as
   its program exits or its block closes says so only once the quarter of
   a second has passed.  Appends nothing for a TARGET that shows no
   block. */
void portal_rex_describe(portal_string target, struct json *json);

/* For views.c: TARGET has closed.  Its block's stream ends, and the block
   carries on. */
void portal_rex_closed(portal_string target);

/* For terminals.c and input.c: what a fed terminal TARGET wrote, its new
   grid, which views.c holds, and whether it has the keyboard. */
void portal_rex_input(portal_string target, const char *bytes, size_t length);
void portal_rex_grid(portal_string target);
void portal_rex_focus(portal_string target, bool focused);

/* For channel.c: the timer TOKEN, which is not the channel's, fired. */
void portal_rex_timer(uint64_t token);

#endif
