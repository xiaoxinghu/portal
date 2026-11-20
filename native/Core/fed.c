/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules (fed.h): the order of its output and grids, the
   geometry of its pane, and its backlog, over the platform's fed terminal
   primitives (portal.h).  Every number of a fed terminal is here, but
   Ghostty's padding, which portal.h names for both. */
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "fed.h"
#include "rex.h"
#include "views.h"

/* What the core gave the terminal while it took a grid, in order: output,
   or a grid. */
struct waiting {
    struct waiting *next;
    bool is_grid;
    uint32_t columns, rows;
    size_t length;
    char bytes[];
};

struct portal_fed {
    struct portal_fed *next;
    portal_view *terminal; /* Null until opened. */
    struct waiting *waiting, *waiting_last;
    /* The grid the core gave, which the terminal holds whatever its pane's
       size: none until the core gives one, while it fills its pane. */
    bool holds;
    uint32_t held_columns, held_rows;
    /* The grid the platform last said it took, 0 by 0 until it says. */
    uint32_t taken_columns, taken_rows;
    /* The two timers' tokens, 0 while not running: the wait for a grid to
       be taken, and the next look at the backlog. */
    uint64_t take_grid, look;
    /* The pane and the cell, 0 until told, and whether anything was. */
    bool told;
    double pane_width, pane_height, scale, padding, cell_width, cell_height;
    /* Where the terminal was last put, once it has been. */
    bool placed;
    portal_pane_rect rect;
    /* The pane's grid and cell as last reported, once they have been. */
    bool reported;
    uint32_t reported_pane[4];
    /* Whether the program waits for the backlog to go down. */
    bool backlogged;
    size_t length;
    char target[]; /* LENGTH bytes, NUL-terminated. */
};

/* Every fed terminal's rules, newest first. */
static struct portal_fed *all;

static portal_string target_of(const struct portal_fed *fed)
{
    return (portal_string) {fed->target, fed->length};
}

static struct portal_fed *find(portal_string target)
{
    for (struct portal_fed *fed = all; fed; fed = fed->next)
        if (fed->length == target.length && !memcmp(fed->target, target.data, target.length))
            return fed;
    return NULL;
}

struct portal_fed *portal_fed_new(portal_string target)
{
    struct portal_fed *fed = calloc(1, sizeof *fed + target.length + 1);
    if (!fed)
        return NULL;
    if (target.length)
        memcpy(fed->target, target.data, target.length);
    fed->length = target.length;
    fed->next = all;
    all = fed;
    return fed;
}

static void fit(struct portal_fed *fed);

void portal_fed_opened(struct portal_fed *fed, portal_view *terminal)
{
    fed->terminal = terminal;
    /* What the platform told while it made the view. */
    if (fed->told)
        fit(fed);
}

void portal_fed_free(struct portal_fed *fed)
{
    if (!fed)
        return;
    for (struct portal_fed **link = &all; *link; link = &(*link)->next)
        if (*link == fed) {
            *link = fed->next;
            break;
        }
    for (struct waiting *entry = fed->waiting, *next; entry; entry = next) {
        next = entry->next;
        free(entry);
    }
    free(fed);
}

/* The platform's primitives, whose failures, such as on the wrong thread,
   leave the rules as they would be had nothing been asked. */

static bool parse(struct portal_fed *fed, const char *bytes, size_t length, portal_text *error)
{
    return portal_terminal_parse(fed->terminal, bytes, length, error);
}

static void drain(struct portal_fed *fed)
{
    portal_text error = {0};
    if (!portal_terminal_drain(fed->terminal, &error))
        free(error.data);
}

static size_t pending(struct portal_fed *fed)
{
    portal_text error = {0};
    size_t bytes = 0;
    if (!fed->terminal || !portal_terminal_pending(fed->terminal, &bytes, &error)) {
        free(error.data);
        return 0;
    }
    return bytes;
}

static bool place(struct portal_fed *fed, portal_pane_rect rect)
{
    portal_text error = {0};
    if (fed->terminal && portal_terminal_place(fed->terminal, rect, &error))
        return true;
    free(error.data);
    return false;
}

/* The geometry. */

portal_pane_rect portal_fed_grid_rect(uint32_t columns, uint32_t rows, double pane_height,
                                      double cell_width, double cell_height, double padding,
                                      double scale)
{
    /* The grid, Ghostty's padding, and half a cell to spare, so that
       rounding never loses a row or a column.  Ghostty leaves the spare
       below the grid and to its right, so the terminal hangs that much
       below the pane: the grid's last row sits at the pane's bottom, and a
       grid that fits the pane is never clipped. */
    portal_pane_rect rect = {
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

static bool knows_cell(const struct portal_fed *fed)
{
    return fed->cell_width > 0 && fed->cell_height > 0 && fed->scale > 0;
}

/* Hold the grid the pane would hold, whatever grid the terminal holds, and
   tell rex.c of each change: the size Emacs gives the block when it owns
   it. */
static void report_pane(struct portal_fed *fed)
{
    if (!knows_cell(fed))
        return;
    uint32_t values[4];
    portal_fed_pane_grid(fed->pane_width, fed->pane_height, fed->cell_width, fed->cell_height,
                         fed->padding, fed->scale, &values[0], &values[1]);
    values[2] = cells(fed->cell_width);
    values[3] = cells(fed->cell_height);
    if (!values[0] || !values[1]
        || (fed->reported && !memcmp(values, fed->reported_pane, sizeof values)))
        return;
    fed->reported = true;
    memcpy(fed->reported_pane, values, sizeof values);
    portal_views_set_grid(target_of(fed), values);
    portal_rex_grid(target_of(fed));
}

static bool same_rect(portal_pane_rect a, portal_pane_rect b)
{
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
        && a.top == b.top;
}

/* Size the terminal to the grid it holds, at its pane's bottom-left, or to
   its pane until it holds one; then report the pane's grid. */
static void fit(struct portal_fed *fed)
{
    portal_pane_rect rect = {0, 0, fed->pane_width, fed->pane_height, 0};
    if (fed->holds && knows_cell(fed))
        rect = portal_fed_grid_rect(fed->held_columns, fed->held_rows, fed->pane_height,
                                    fed->cell_width, fed->cell_height, fed->padding, fed->scale);
    if ((!fed->placed || !same_rect(rect, fed->rect)) && place(fed, rect)) {
        fed->placed = true;
        fed->rect = rect;
    }
    report_pane(fed);
}

void portal_terminal_pane(portal_string target, double width, double height, double scale,
                          double padding)
{
    struct portal_fed *fed = find(target);
    if (!fed)
        return;
    fed->told = true;
    fed->pane_width = width;
    fed->pane_height = height;
    fed->scale = scale;
    fed->padding = padding > 0 ? padding : 0;
    if (fed->terminal)
        fit(fed);
}

void portal_terminal_cell(portal_string target, double width, double height)
{
    struct portal_fed *fed = find(target);
    if (!fed)
        return;
    fed->told = true;
    fed->cell_width = width;
    fed->cell_height = height;
    if (fed->terminal)
        fit(fed);
}

/* The order. */

static bool taking(const struct portal_fed *fed)
{
    return fed->take_grid != 0;
}

/* The core's output and grids, in order: a grid waits for the output
   before it to be parsed, and holds the output after it until the
   terminal has taken it, for at most a quarter of a second. */
static void flush(struct portal_fed *fed)
{
    while (!taking(fed) && fed->waiting) {
        struct waiting *entry = fed->waiting;
        fed->waiting = entry->next;
        if (!fed->waiting)
            fed->waiting_last = NULL;
        if (!entry->is_grid) {
            portal_text error = {0};
            if (!parse(fed, entry->bytes, entry->length, &error))
                free(error.data);
        } else {
            drain(fed);
            fed->holds = true;
            fed->held_columns = entry->columns;
            fed->held_rows = entry->rows;
            fit(fed);
            if (fed->taken_columns != entry->columns || fed->taken_rows != entry->rows)
                fed->take_grid = portal_channel_timer(PORTAL_FED_TAKE_GRID_MS);
        }
        free(entry);
    }
}

static bool wait_with(struct portal_fed *fed, struct waiting *entry, portal_text *error)
{
    if (!entry)
        return fail_with(error, "Portal is out of memory");
    entry->next = NULL;
    if (fed->waiting_last)
        fed->waiting_last->next = entry;
    else
        fed->waiting = entry;
    fed->waiting_last = entry;
    flush(fed);
    return true;
}

/* TARGET's rules, once its view is open; or NULL, with *ERROR set. */
static struct portal_fed *open_fed(portal_string target, portal_text *error)
{
    struct portal_fed *fed = find(target);
    if (fed && fed->terminal)
        return fed;
    fail(error, "No fed terminal ", target);
    return NULL;
}

bool portal_fed_feed(portal_string target, const char *bytes, size_t length, portal_text *error)
{
    struct portal_fed *fed = open_fed(target, error);
    if (!fed)
        return false;
    if (!length)
        return true;
    /* Nothing waits: parse it now, without a copy. */
    if (!taking(fed) && !fed->waiting)
        return parse(fed, bytes, length, error);
    if (length > SIZE_MAX - sizeof(struct waiting))
        return fail_with(error, "Portal is out of memory");
    struct waiting *entry = malloc(sizeof *entry + length);
    if (entry) {
        entry->is_grid = false;
        entry->length = length;
        memcpy(entry->bytes, bytes, length);
    }
    return wait_with(fed, entry, error);
}

bool portal_fed_hold_grid(portal_string target, uint32_t columns, uint32_t rows,
                          portal_text *error)
{
    struct portal_fed *fed = open_fed(target, error);
    if (!fed)
        return false;
    if (!columns || !rows || columns > UINT16_MAX || rows > UINT16_MAX)
        return fail_with(error, "A terminal's grid has at least one cell each way");
    struct waiting *entry = malloc(sizeof *entry);
    if (entry) {
        entry->is_grid = true;
        entry->columns = columns;
        entry->rows = rows;
        entry->length = 0;
    }
    return wait_with(fed, entry, error);
}

void portal_terminal_took_grid(portal_string target, uint32_t columns, uint32_t rows)
{
    struct portal_fed *fed = find(target);
    if (!fed)
        return;
    fed->taken_columns = columns;
    fed->taken_rows = rows;
    if (taking(fed) && fed->held_columns == columns && fed->held_rows == rows) {
        fed->take_grid = 0;
        flush(fed);
    }
}

/* The backlog. */

bool portal_terminal_backlog_crossed(size_t before, size_t after)
{
    return (before <= PORTAL_TERMINAL_BACKLOG && after > PORTAL_TERMINAL_BACKLOG)
        || (before > PORTAL_TERMINAL_BACKLOG_LOW && after <= PORTAL_TERMINAL_BACKLOG_LOW);
}

/* A crossing only says when to look, and two can reach the module thread in
   the other order than they happened, so the count is read here, and while
   the program waits it is read again until it is down to the low mark: a
   crossing whose call came first can leave nothing waiting. */
static void look(struct portal_fed *fed)
{
    bool backlogged = pending(fed) > PORTAL_TERMINAL_BACKLOG_LOW;
    if (backlogged != fed->backlogged) {
        fed->backlogged = backlogged;
        portal_rex_backlog(target_of(fed), backlogged);
    }
    fed->look = backlogged ? portal_channel_timer(PORTAL_FED_BACKLOG_LOOK_MS) : 0;
}

void portal_terminal_backlog(portal_string target)
{
    struct portal_fed *fed = find(target);
    if (fed)
        look(fed);
}

bool portal_fed_backlogged(portal_string target)
{
    struct portal_fed *fed = find(target);
    return fed && fed->backlogged;
}

bool portal_fed_timer(uint64_t token)
{
    for (struct portal_fed *fed = all; fed; fed = fed->next) {
        if (fed->take_grid == token) {
            fed->take_grid = 0;
            flush(fed);
            return true;
        }
        if (fed->look == token) {
            look(fed);
            return true;
        }
    }
    return false;
}
