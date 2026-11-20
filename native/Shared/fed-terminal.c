/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules (fed-terminal.h): the order of its output and
   grids, the geometry of its pane, and its backlog.  Plain C11 with no
   platform in it, and the numbers of a fed terminal on both systems. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fed-terminal.h"

/* What the core gave the terminal while it took a grid, in order: output,
   or a grid. */
struct waiting {
    struct waiting *next;
    bool is_grid;
    uint32_t columns, rows;
    size_t length;
    char bytes[];
};

struct portal_fed_terminal {
    const portal_fed_backend *backend;
    void *context;
    portal_text target;
    struct waiting *waiting, *waiting_last;
    /* The grid the core gave, which the terminal holds whatever its pane's
       size: none until the core gives one, while it fills its pane. */
    bool holds;
    uint32_t held_columns, held_rows;
    /* The grid the surface last said it has, 0 by 0 until it says. */
    uint32_t taken_columns, taken_rows;
    /* The timers that run, by bit. */
    unsigned timers;
    /* The pane and the cell, 0 until known; Ghostty's padding in pixels,
       0 for the default. */
    double pane_width, pane_height, scale, cell_width, cell_height, padding;
    /* Where the terminal was last put, once it has been. */
    bool placed;
    portal_fed_rect rect;
    /* The pane's grid and cell as last reported to the core, once they
       have been. */
    bool reported;
    uint32_t reported_pane[4];
    /* What the core was last told of the backlog. */
    bool backlogged;
};

static bool fail(portal_text *error, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    char *data = length < 0 ? NULL : malloc((size_t) length + 1);
    if (data) {
        va_start(arguments, format);
        vsnprintf(data, (size_t) length + 1, format, arguments);
        va_end(arguments);
        *error = (portal_text) {data, (size_t) length};
    }
    return false;
}

static bool running(const portal_fed_terminal *terminal, portal_fed_timer timer)
{
    return terminal->timers & (1u << timer);
}

static void start(portal_fed_terminal *terminal, portal_fed_timer timer, uint32_t milliseconds)
{
    terminal->timers |= 1u << timer;
    terminal->backend->start_timer(terminal->context, timer, milliseconds);
}

static void stop(portal_fed_terminal *terminal, portal_fed_timer timer)
{
    if (!running(terminal, timer))
        return;
    terminal->timers &= ~(1u << timer);
    terminal->backend->stop_timer(terminal->context, timer);
}

portal_fed_terminal *portal_fed_terminal_new(portal_string target,
                                             const portal_fed_backend *backend, void *context)
{
    portal_fed_terminal *terminal = calloc(1, sizeof *terminal);
    char *name = malloc(target.length + 1);
    if (!terminal || !name) {
        free(terminal);
        free(name);
        return NULL;
    }
    if (target.length)
        memcpy(name, target.data, target.length);
    name[target.length] = 0;
    terminal->backend = backend;
    terminal->context = context;
    terminal->target = (portal_text) {name, target.length};
    return terminal;
}

void portal_fed_terminal_free(portal_fed_terminal *terminal)
{
    if (!terminal)
        return;
    stop(terminal, PORTAL_FED_TAKE_GRID);
    stop(terminal, PORTAL_FED_BACKLOG_LOOK);
    for (struct waiting *entry = terminal->waiting, *next; entry; entry = next) {
        next = entry->next;
        free(entry);
    }
    free(terminal->target.data);
    free(terminal);
}

/* The geometry. */

/* Ghostty's padding on each side, in pixels, as TERMINAL knows it. */
static double padding_of(const portal_fed_terminal *terminal)
{
    return terminal->padding > 0 ? terminal->padding : PORTAL_FED_PADDING * terminal->scale;
}

portal_fed_rect portal_fed_grid_rect(uint32_t columns, uint32_t rows, double pane_height,
                                     double cell_width, double cell_height, double padding,
                                     double scale)
{
    /* The grid, Ghostty's padding, and half a cell to spare, so that
       rounding never loses a row or a column.  Ghostty leaves the spare
       below the grid and to its right, so the terminal hangs that much
       below the pane: the grid's last row sits at the pane's bottom, and a
       grid that fits the pane is never clipped. */
    portal_fed_rect rect = {
        .x = 0,
        .y = -cell_height / 2 / scale,
        .width = ((double) columns * cell_width + 2 * padding + cell_width / 2) / scale,
        .height = ((double) rows * cell_height + 2 * padding + cell_height / 2) / scale,
    };
    rect.top = pane_height - (rect.y + rect.height);
    return rect;
}

/* COUNT whole cells, at least 0 and at most what 32 bits hold. */
static uint32_t cells(double count)
{
    if (!(count > 0))
        return 0;
    return count >= (double) UINT32_MAX ? UINT32_MAX : (uint32_t) count;
}

void portal_fed_pane_grid(double width, double height, double cell_width, double cell_height,
                          double padding, double scale, uint32_t *columns, uint32_t *rows)
{
    *columns = cells((width * scale - 2 * padding) / cell_width);
    *rows = cells((height * scale - 2 * padding) / cell_height);
}

static bool knows_cell(const portal_fed_terminal *terminal)
{
    return terminal->cell_width > 0 && terminal->cell_height > 0 && terminal->scale > 0;
}

/* Tell the core the grid the pane would hold, whatever grid the terminal
   holds: the size Emacs gives the block when it owns it. */
static void report_pane(portal_fed_terminal *terminal)
{
    if (!knows_cell(terminal))
        return;
    uint32_t values[4];
    portal_fed_pane_grid(terminal->pane_width, terminal->pane_height, terminal->cell_width,
                         terminal->cell_height, padding_of(terminal), terminal->scale, &values[0],
                         &values[1]);
    values[2] = cells(terminal->cell_width);
    values[3] = cells(terminal->cell_height);
    if (!values[0] || !values[1]
        || (terminal->reported && !memcmp(values, terminal->reported_pane, sizeof values)))
        return;
    terminal->reported = true;
    memcpy(terminal->reported_pane, values, sizeof values);
    portal_terminal_grid((portal_string) {terminal->target.data, terminal->target.length},
                         values[0], values[1], values[2], values[3]);
}

static bool same_rect(portal_fed_rect a, portal_fed_rect b)
{
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
        && a.top == b.top;
}

/* Size the terminal to the grid it holds, at its pane's bottom-left, or to
   its pane until it holds one; then report the pane's grid. */
static void fit(portal_fed_terminal *terminal)
{
    portal_fed_rect rect = {0, 0, terminal->pane_width, terminal->pane_height, 0};
    if (terminal->holds && knows_cell(terminal))
        rect = portal_fed_grid_rect(terminal->held_columns, terminal->held_rows,
                                    terminal->pane_height, terminal->cell_width,
                                    terminal->cell_height, padding_of(terminal), terminal->scale);
    if (!terminal->placed || !same_rect(rect, terminal->rect)) {
        terminal->placed = true;
        terminal->rect = rect;
        terminal->backend->place(terminal->context, rect);
    }
    report_pane(terminal);
}

void portal_fed_terminal_pane(portal_fed_terminal *terminal, double width, double height,
                              double scale)
{
    terminal->pane_width = width;
    terminal->pane_height = height;
    terminal->scale = scale;
    fit(terminal);
}

void portal_fed_terminal_cell(portal_fed_terminal *terminal, double width, double height)
{
    terminal->cell_width = width;
    terminal->cell_height = height;
    fit(terminal);
}

void portal_fed_terminal_padding(portal_fed_terminal *terminal, double pixels)
{
    terminal->padding = pixels > 0 ? pixels : 0;
    fit(terminal);
}

/* The order. */

static bool taking(const portal_fed_terminal *terminal)
{
    return running(terminal, PORTAL_FED_TAKE_GRID);
}

/* The core's output and grids, in order: a grid waits for the output
   before it to be parsed, and holds the output after it until the
   terminal has taken it, for at most a quarter of a second. */
static void flush(portal_fed_terminal *terminal)
{
    while (!taking(terminal) && terminal->waiting) {
        struct waiting *entry = terminal->waiting;
        terminal->waiting = entry->next;
        if (!terminal->waiting)
            terminal->waiting_last = NULL;
        if (!entry->is_grid) {
            terminal->backend->feed(terminal->context, entry->bytes, entry->length);
        } else {
            terminal->backend->drain(terminal->context);
            terminal->holds = true;
            terminal->held_columns = entry->columns;
            terminal->held_rows = entry->rows;
            fit(terminal);
            if (terminal->taken_columns != entry->columns || terminal->taken_rows != entry->rows)
                start(terminal, PORTAL_FED_TAKE_GRID, PORTAL_FED_TAKE_GRID_MS);
        }
        free(entry);
    }
}

static bool wait_with(portal_fed_terminal *terminal, struct waiting *entry, portal_text *error)
{
    if (!entry)
        return fail(error, "Portal is out of memory");
    entry->next = NULL;
    if (terminal->waiting_last)
        terminal->waiting_last->next = entry;
    else
        terminal->waiting = entry;
    terminal->waiting_last = entry;
    flush(terminal);
    return true;
}

bool portal_fed_terminal_feed(portal_fed_terminal *terminal, const char *bytes, size_t length,
                              portal_text *error)
{
    if (!length)
        return true;
    /* Nothing waits: parse it now, without a copy. */
    if (!taking(terminal) && !terminal->waiting) {
        terminal->backend->feed(terminal->context, bytes, length);
        return true;
    }
    if (length > SIZE_MAX - sizeof(struct waiting))
        return fail(error, "Portal is out of memory");
    struct waiting *entry = malloc(sizeof *entry + length);
    if (entry) {
        entry->is_grid = false;
        entry->length = length;
        memcpy(entry->bytes, bytes, length);
    }
    return wait_with(terminal, entry, error);
}

bool portal_fed_terminal_hold_grid(portal_fed_terminal *terminal, uint32_t columns,
                                   uint32_t rows, portal_text *error)
{
    if (!columns || !rows || columns > UINT16_MAX || rows > UINT16_MAX)
        return fail(error, "A terminal's grid has at least one cell each way");
    struct waiting *entry = malloc(sizeof *entry);
    if (entry) {
        entry->is_grid = true;
        entry->columns = columns;
        entry->rows = rows;
        entry->length = 0;
    }
    return wait_with(terminal, entry, error);
}

void portal_fed_terminal_took_grid(portal_fed_terminal *terminal, uint32_t columns, uint32_t rows)
{
    terminal->taken_columns = columns;
    terminal->taken_rows = rows;
    if (taking(terminal) && terminal->held_columns == columns && terminal->held_rows == rows) {
        stop(terminal, PORTAL_FED_TAKE_GRID);
        flush(terminal);
    }
}

/* The backlog. */

bool portal_fed_backlog_crossed(size_t before, size_t after)
{
    return (before <= PORTAL_FED_HIGH_MARK && after > PORTAL_FED_HIGH_MARK)
        || (before > PORTAL_FED_LOW_MARK && after <= PORTAL_FED_LOW_MARK);
}

/* A crossing only says when to look, and two can reach the module thread in
   the other order than they happened, so the count is read here, and while
   the core is told to wait it is read again until it is down to the low
   mark: a crossing whose call came first can leave nothing waiting. */
void portal_fed_terminal_backlog(portal_fed_terminal *terminal)
{
    bool backlogged = terminal->backend->pending(terminal->context) > PORTAL_FED_LOW_MARK;
    if (backlogged != terminal->backlogged) {
        terminal->backlogged = backlogged;
        portal_terminal_backlog((portal_string) {terminal->target.data, terminal->target.length},
                                backlogged);
    }
    stop(terminal, PORTAL_FED_BACKLOG_LOOK);
    if (backlogged)
        start(terminal, PORTAL_FED_BACKLOG_LOOK, PORTAL_FED_BACKLOG_LOOK_MS);
}

void portal_fed_terminal_timer(portal_fed_terminal *terminal, portal_fed_timer timer)
{
    /* A call for a timer stopped meanwhile does nothing. */
    if (!running(terminal, timer))
        return;
    terminal->timers &= ~(1u << timer);
    if (timer == PORTAL_FED_TAKE_GRID)
        flush(terminal);
    else
        portal_fed_terminal_backlog(terminal);
}
