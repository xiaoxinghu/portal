/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules, for any backend: what portal.h asks of a fed
   terminal beside drawing it, written once over plain values, with no
   view, no surface and no toolkit.  Three things:

   - The order of output and grids.  portal_terminal_feed and
     portal_terminal_hold_grid arrive in an order, and keep it: a grid waits
     for the output before it to be parsed, and holds the output after it
     until the terminal has taken the grid, for a quarter of a second at
     most.
   - The geometry of a pane.  A terminal that holds a grid is sized to it,
     with Ghostty's padding and half a cell to spare, and hangs from its
     pane's bottom-left corner; until it holds one, it fills its pane.  The
     grid the pane would hold goes to the core with portal_terminal_grid,
     at each change.
   - The backlog.  Output fed and not yet parsed past
     PORTAL_TERMINAL_BACKLOG bytes goes to the core with
     portal_terminal_backlog, and again once it is down to a quarter of
     that, looked at again every 10 ms while it waits.

   A backend keeps one of these for each fed terminal, tells it what it
   hears, and gives it the few things only a backend can do as the table
   below: parse bytes, say how many wait, keep two timers and put the
   terminal at a rectangle in its pane.  Everything here runs on the module
   thread, but portal_fed_backlog_crossed, which is pure.

   Units: a pane's size and the rectangle are in the pane's own units,
   AppKit's points or GTK's logical pixels; a cell's size is in pixels of
   the screen; the scale is pixels for each of the pane's units.

   On macOS these are still Swift, native/Terminal.swift, until a Mac can
   run the change to this file. */
#ifndef PORTAL_FED_TERMINAL_H
#define PORTAL_FED_TERMINAL_H

#include "portal.h"

enum {
    /* The padding the backend gives Ghostty inside a fed terminal, on each
       side, in points, with window-padding-x and -y, and
       window-padding-balance off: the geometry counts on it.  In pixels
       it is what portal_fed_terminal_padding says, by default this many
       of the pane's units, as on macOS. */
    PORTAL_FED_PADDING = 2,
    /* How long a grid holds the output after it while the terminal takes
       it, at most, in milliseconds. */
    PORTAL_FED_TAKE_GRID_MS = 250,
    /* How often the backlog is looked at while the core is told to wait,
       in milliseconds. */
    PORTAL_FED_BACKLOG_LOOK_MS = 10,
    /* The backlog's marks, in bytes of output fed and not yet parsed:
       rising past the high one, the core is told to wait; down to the low
       one, that it need not. */
    PORTAL_FED_HIGH_MARK = PORTAL_TERMINAL_BACKLOG,
    PORTAL_FED_LOW_MARK = PORTAL_TERMINAL_BACKLOG / 4,
};

/* The two timers a fed terminal keeps. */
typedef enum portal_fed_timer {
    /* Ends the wait for a grid to be taken. */
    PORTAL_FED_TAKE_GRID,
    /* Looks at the backlog again. */
    PORTAL_FED_BACKLOG_LOOK,
} portal_fed_timer;

/* Where a fed terminal goes in its pane, in the pane's units.  X and Y are
   the rectangle's bottom-left corner from the pane's, with y growing
   upward, as AppKit has it; TOP is the same rectangle's top edge from the
   pane's top, with y growing downward, as GTK and Wayland have it.  Y is
   negative when the rectangle hangs below the pane, TOP when it rises
   above it. */
typedef struct portal_fed_rect {
    double x, y, width, height, top;
} portal_fed_rect;

/* What the rules ask of a backend.  Each is called on the module thread
   with the CONTEXT given to portal_fed_terminal_new, and none may call back
   into this file. */
typedef struct portal_fed_backend {
    /* Parse LENGTH bytes of output after the bytes before them, off the
       module thread, answering no query in them.  The bytes are the
       caller's only for the call. */
    void (*feed)(void *context, const char *bytes, size_t length);
    /* Return once every byte fed so far has been parsed. */
    void (*drain)(void *context);
    /* How many bytes fed have not been parsed yet. */
    size_t (*pending)(void *context);
    /* Call portal_fed_terminal_timer with TIMER, once, on the module thread,
       MILLISECONDS from now, and not before this returns.  A timer already
       running is never started again; one is stopped only while it runs. */
    void (*start_timer)(void *context, portal_fed_timer timer, uint32_t milliseconds);
    void (*stop_timer)(void *context, portal_fed_timer timer);
    /* Put the terminal at RECT in its pane, clipped by the pane.  Called at
       each change of RECT, the first time included. */
    void (*place)(void *context, portal_fed_rect rect);
} portal_fed_backend;

typedef struct portal_fed_terminal portal_fed_terminal;

/* A fed terminal's rules for the terminal TARGET, the target its reports
   to the core name, with BACKEND and CONTEXT, both of which must outlive
   it.  Null when out of memory. */
portal_fed_terminal *portal_fed_terminal_new(portal_string target,
                                             const portal_fed_backend *backend, void *context);
/* Forget TERMINAL, stopping its running timers: nothing waiting is fed. */
void portal_fed_terminal_free(portal_fed_terminal *terminal);

/* portal_terminal_feed and portal_terminal_hold_grid, as portal.h says,
   for a terminal the backend knows to be fed.  The grid has between 1 and
   65535 cells each way. */
bool portal_fed_terminal_feed(portal_fed_terminal *terminal, const char *bytes, size_t length,
                              portal_text *error);
bool portal_fed_terminal_hold_grid(portal_fed_terminal *terminal, uint32_t columns,
                                   uint32_t rows, portal_text *error);

/* The terminal has a grid of COLUMNS by ROWS cells now, as its surface
   says.  A surface may say so on a thread of its own: the backend brings
   it to the module thread. */
void portal_fed_terminal_took_grid(portal_fed_terminal *terminal, uint32_t columns, uint32_t rows);
/* The pane is WIDTH by HEIGHT now, at SCALE pixels to each of its units. */
void portal_fed_terminal_pane(portal_fed_terminal *terminal, double width, double height,
                              double scale);
/* The terminal's cell is WIDTH by HEIGHT pixels now, or 0 by 0 until it
   knows. */
void portal_fed_terminal_cell(portal_fed_terminal *terminal, double width, double height);
/* Ghostty pads the terminal with PIXELS on each side now, its
   PORTAL_FED_PADDING points as its fonts count them: on macOS a point is a
   pixel at scale 1, which is the default, PORTAL_FED_PADDING times the
   scale; on Linux Ghostty counts 96 pixels to the inch at scale 1 and
   keeps whole ones, 5 for 2 points at scale 2.  0 goes back to the
   default. */
void portal_fed_terminal_padding(portal_fed_terminal *terminal, double pixels);

/* Whether the bytes waiting to be parsed, going from BEFORE to AFTER, rose
   past the high mark or fell to the low one: a feeder that sees this calls
   portal_fed_terminal_backlog on the module thread.  On any thread. */
bool portal_fed_backlog_crossed(size_t before, size_t after);
/* Look at how much waits to be parsed, after a crossing: tell the core if
   it has changed, and while it is backlogged look again soon. */
void portal_fed_terminal_backlog(portal_fed_terminal *terminal);

/* TIMER, started by the rules, has run out. */
void portal_fed_terminal_timer(portal_fed_terminal *terminal, portal_fed_timer timer);

/* The geometry alone.  Where a terminal that holds a grid of COLUMNS by
   ROWS goes in a pane of PANE_HEIGHT, with cells of CELL_WIDTH by
   CELL_HEIGHT pixels and PADDING pixels of Ghostty's on each side, at
   SCALE. */
portal_fed_rect portal_fed_grid_rect(uint32_t columns, uint32_t rows, double pane_height,
                                     double cell_width, double cell_height, double padding,
                                     double scale);
/* The grid a pane of WIDTH by HEIGHT would hold, with those cells and that
   padding, in *COLUMNS and *ROWS: whole cells inside Ghostty's padding, at
   least 0. */
void portal_fed_pane_grid(double width, double height, double cell_width, double cell_height,
                          double padding, double scale, uint32_t *columns, uint32_t *rows);

#endif
