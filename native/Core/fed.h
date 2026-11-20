/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules (portal.h), kept by the core over the platform's
   fed terminal primitives.  Three things:

   - The order of output and grids.  portal_fed_feed and
     portal_fed_hold_grid arrive in an order, and keep it: a grid waits for
     the output before it to be parsed, and holds the output after it
     until the terminal has taken the grid, for a quarter of a second at
     most.
   - The geometry of a pane.  A terminal that holds a grid is sized to it,
     with Ghostty's padding and half a cell to spare, and hangs from its
     pane's bottom-left corner; until it holds one, it fills its pane.  The
     grid the pane would hold is views.c's to keep and rex.c's to hear of,
     at each change.
   - The backlog.  Output given and not yet parsed past
     PORTAL_TERMINAL_BACKLOG bytes holds the program back (rex.c), until it
     is down to PORTAL_TERMINAL_BACKLOG_LOW, looked at again every 10 ms
     while it waits.

   views.c makes one of these for each fed terminal it opens and frees it
   when the terminal closes; the platform's calls of portal.h reach it by
   the terminal's target, and its timers are the core's
   (portal_channel_timer).

   Units: a pane's size and the rectangle are in the pane's own units,
   AppKit's points or GTK's logical pixels; a cell's size and the padding
   are in pixels of the screen; the scale is pixels for each of the pane's
   units. */
#ifndef PORTAL_FED_H
#define PORTAL_FED_H

#include "portal.h"

enum {
    /* How long a grid holds the output after it while the terminal takes
       it, at most, in milliseconds. */
    PORTAL_FED_TAKE_GRID_MS = 250,
    /* How often the backlog is looked at while the program waits, in
       milliseconds. */
    PORTAL_FED_BACKLOG_LOOK_MS = 10,
};

struct portal_fed;

/* The rules of the fed terminal TARGET, before the platform creates it:
   they hear what the platform tells them for TARGET from now on, and act
   on its view once views.c gives it with portal_fed_opened.  Null when out
   of memory. */
struct portal_fed *portal_fed_new(portal_string target);
/* TERMINAL, the platform's view of FED, exists now. */
void portal_fed_opened(struct portal_fed *fed, portal_view *terminal);
/* Forget FED, once its view is destroyed: what waits is never parsed, and
   its timers count for nothing. */
void portal_fed_free(struct portal_fed *fed);

/* Give TARGET, a fed terminal, LENGTH bytes of its program's output, after
   those given before: it parses them in order, after any grid given before
   them, and holds them while it takes that grid. */
bool portal_fed_feed(portal_string target, const char *bytes, size_t length, portal_text *error);
/* From the output given after this call on, TARGET has a grid of COLUMNS by
   ROWS cells, between 1 and 65535 each way, whatever the size of its pane;
   the output given before it is parsed on the grid it had. */
bool portal_fed_hold_grid(portal_string target, uint32_t columns, uint32_t rows,
                          portal_text *error);
/* Whether TARGET's program waits for its backlog to go down. */
bool portal_fed_backlogged(portal_string target);

/* For channel.c: whether the timer TOKEN is a fed terminal's, which it then
   runs. */
bool portal_fed_timer(uint64_t token);

/* The geometry alone.  Where a terminal that holds a grid of COLUMNS by
   ROWS goes in a pane of PANE_HEIGHT, with cells of CELL_WIDTH by
   CELL_HEIGHT pixels and PADDING pixels of Ghostty's on each side, at
   SCALE. */
portal_pane_rect portal_fed_grid_rect(uint32_t columns, uint32_t rows, double pane_height,
                                      double cell_width, double cell_height, double padding,
                                      double scale);
/* The grid a pane of WIDTH by HEIGHT would hold, with those cells and that
   padding, in *COLUMNS and *ROWS: whole cells inside Ghostty's padding, at
   least 0. */
void portal_fed_pane_grid(double width, double height, double cell_width, double cell_height,
                          double padding, double scale, uint32_t *columns, uint32_t *rows);

#endif
