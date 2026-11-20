/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules, native/Shared/fed-terminal.c, with no Emacs, no
   window and no surface: a backend that writes each call down, in order,
   with the core's two reports among them, and timers that run out when a
   test says so.  Each test then compares what happened with what should
   have, line by line.  It links the file and reaches it only through
   fed-terminal.h, defining the two calls into the core itself. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fed-terminal.h"

static int failures;
/* How many checks ran: the program ends by printing it. */
static int checks;

#define CHECK(condition) check((condition), #condition, __LINE__)

static bool check(bool passed, const char *condition, int line)
{
    checks++;
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
    return passed;
}

/* What happened since the last look: one line for each call. */
static char happened[4096];
static size_t happened_length;

static void note(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(happened + happened_length, sizeof happened - happened_length,
                           format, arguments);
    va_end(arguments);
    if (length < 0 || (size_t) length >= sizeof happened - happened_length) {
        fprintf(stderr, "the log is full\n");
        exit(2);
    }
    happened_length += (size_t) length;
}

/* Check that what happened since the last look is EXPECTED, and forget it. */
#define HAPPENED(expected) happened_was((expected), __LINE__)

static void happened_was(const char *expected, int line)
{
    checks++;
    if (strcmp(happened, expected)) {
        fprintf(stderr, "%s:%d: FAIL: what happened was\n%s-- and not --\n%s--\n", __FILE__,
                line, happened, expected);
        failures++;
    }
    happened[0] = 0;
    happened_length = 0;
}

/* The core's side. */

void portal_terminal_grid(portal_string target, uint32_t columns, uint32_t rows,
                          uint32_t cell_width, uint32_t cell_height)
{
    note("core %.*s grid %ux%u cell %ux%u\n", (int) target.length, target.data, columns, rows,
         cell_width, cell_height);
}

void portal_terminal_backlog(portal_string target, bool backlogged)
{
    note("core %.*s backlog %s\n", (int) target.length, target.data,
         backlogged ? "on" : "off");
}

/* The backend's side.  Its context is the bytes waiting to be parsed. */

static void feed(void *context, const char *bytes, size_t length)
{
    (void) context;
    note("feed %.*s\n", (int) length, bytes);
}

static void drain(void *context)
{
    (void) context;
    note("drain\n");
}

static size_t pending(void *context)
{
    return *(size_t *) context;
}

static const char *timer_name(portal_fed_timer timer)
{
    return timer == PORTAL_FED_TAKE_GRID ? "take-grid" : "backlog-look";
}

/* The timers that run, by bit, as the backend sees them. */
static unsigned timers;

static void start_timer(void *context, portal_fed_timer timer, uint32_t milliseconds)
{
    (void) context;
    CHECK(!(timers & (1u << timer)));
    timers |= 1u << timer;
    note("start %s %u ms\n", timer_name(timer), milliseconds);
}

static void stop_timer(void *context, portal_fed_timer timer)
{
    (void) context;
    CHECK(timers & (1u << timer));
    timers &= ~(1u << timer);
    note("stop %s\n", timer_name(timer));
}

/* TIMER, which runs, runs out. */
static void run_out(portal_fed_terminal *terminal, portal_fed_timer timer)
{
    CHECK(timers & (1u << timer));
    timers &= ~(1u << timer);
    portal_fed_terminal_timer(terminal, timer);
}

static void place(void *context, portal_fed_rect rect)
{
    (void) context;
    note("place x %g y %g width %g height %g top %g\n", rect.x, rect.y, rect.width,
         rect.height, rect.top);
}

static const portal_fed_backend backend = {
    .feed = feed,
    .drain = drain,
    .pending = pending,
    .start_timer = start_timer,
    .stop_timer = stop_timer,
    .place = place,
};

static size_t waiting_bytes;

static portal_fed_terminal *make(void)
{
    timers = 0;
    waiting_bytes = 0;
    portal_fed_terminal *terminal =
        portal_fed_terminal_new((portal_string) {"t1", 2}, &backend, &waiting_bytes);
    if (!terminal) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    return terminal;
}

static bool fed(portal_fed_terminal *terminal, const char *text)
{
    portal_text error = {0};
    bool done = portal_fed_terminal_feed(terminal, text, strlen(text), &error);
    free(error.data);
    return done;
}

static bool hold(portal_fed_terminal *terminal, uint32_t columns, uint32_t rows)
{
    portal_text error = {0};
    bool done = portal_fed_terminal_hold_grid(terminal, columns, rows, &error);
    free(error.data);
    return done;
}

/* A pane of 400 by 300 at scale 1, with cells of 8 by 16: its grid is 49
   by 18, (400 - 4) / 8 and (300 - 4) / 16. */
static portal_fed_terminal *make_in_pane(void)
{
    portal_fed_terminal *terminal = make();
    portal_fed_terminal_pane(terminal, 400, 300, 1);
    portal_fed_terminal_cell(terminal, 8, 16);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n"
             "core t1 grid 49x18 cell 8x16\n");
    return terminal;
}

/* The order. */

static void test_output_alone(void)
{
    portal_fed_terminal *terminal = make();
    CHECK(fed(terminal, "one"));
    CHECK(fed(terminal, "two"));
    CHECK(fed(terminal, ""));
    HAPPENED("feed one\nfeed two\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("");
}

static void test_grid_between_outputs(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    CHECK(fed(terminal, "before"));
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "after"));
    CHECK(fed(terminal, "later"));
    /* The output before is parsed on the old grid; the grid then holds
       what comes after it. */
    HAPPENED("feed before\n"
             "drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "start take-grid 250 ms\n");
    /* Other sizes first, as a surface reports on its way: still held. */
    portal_fed_terminal_took_grid(terminal, 49, 18);
    portal_fed_terminal_took_grid(terminal, 79, 24);
    portal_fed_terminal_took_grid(terminal, 80, 23);
    portal_fed_terminal_took_grid(terminal, 0, 0);
    HAPPENED("");
    portal_fed_terminal_took_grid(terminal, 80, 24);
    HAPPENED("stop take-grid\nfeed after\nfeed later\n");
    CHECK(fed(terminal, "now"));
    HAPPENED("feed now\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("");
}

static void test_grid_taken_late(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "after"));
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "start take-grid 250 ms\n");
    /* A quarter of a second, and the output goes on without it. */
    run_out(terminal, PORTAL_FED_TAKE_GRID);
    HAPPENED("feed after\n");
    /* The grid it took at last changes nothing. */
    portal_fed_terminal_took_grid(terminal, 80, 24);
    CHECK(fed(terminal, "then"));
    HAPPENED("feed then\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("");
}

static void test_grid_already_taken(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    portal_fed_terminal_took_grid(terminal, 80, 24);
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "after"));
    /* The terminal has that grid: nothing waits. */
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "feed after\n");
    /* The same grid again: no new place. */
    CHECK(hold(terminal, 80, 24));
    HAPPENED("drain\n");
    /* A grid taken in its rows alone, or its columns alone, is not it. */
    portal_fed_terminal_took_grid(terminal, 79, 24);
    CHECK(hold(terminal, 80, 24));
    HAPPENED("drain\nstart take-grid 250 ms\n");
    portal_fed_terminal_took_grid(terminal, 80, 24);
    HAPPENED("stop take-grid\n");
    portal_fed_terminal_took_grid(terminal, 80, 23);
    CHECK(hold(terminal, 80, 24));
    HAPPENED("drain\nstart take-grid 250 ms\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("stop take-grid\n");
}

static void test_grids_in_a_row(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "a"));
    CHECK(hold(terminal, 100, 30));
    CHECK(fed(terminal, "b"));
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "start take-grid 250 ms\n");
    portal_fed_terminal_took_grid(terminal, 80, 24);
    /* 100 * 8 + 4 + 4 by 30 * 16 + 4 + 8. */
    HAPPENED("stop take-grid\n"
             "feed a\n"
             "drain\n"
             "place x 0 y -8 width 808 height 492 top -184\n"
             "start take-grid 250 ms\n");
    portal_fed_terminal_took_grid(terminal, 100, 30);
    HAPPENED("stop take-grid\nfeed b\n");
    portal_fed_terminal_free(terminal);
}

static void test_freed_while_taking(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "never"));
    CHECK(hold(terminal, 90, 24));
    CHECK(fed(terminal, "parsed"));
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "start take-grid 250 ms\n");
    /* What waits is dropped, unparsed, and the timer stopped. */
    portal_fed_terminal_free(terminal);
    HAPPENED("stop take-grid\n");
    CHECK(!timers);
}

static void test_grid_refused(void)
{
    portal_fed_terminal *terminal = make();
    portal_text error = {0};
    CHECK(!portal_fed_terminal_hold_grid(terminal, 0, 24, &error));
    CHECK(error.data && !strcmp(error.data, "A terminal's grid has at least one cell each way"));
    free(error.data);
    CHECK(!hold(terminal, 80, 0));
    CHECK(!hold(terminal, 65536, 24));
    CHECK(!hold(terminal, 80, 65536));
    CHECK(hold(terminal, 65535, 65535));
    /* With no pane known, it fills a pane of nothing. */
    HAPPENED("drain\n"
             "place x 0 y 0 width 0 height 0 top 0\n"
             "start take-grid 250 ms\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("stop take-grid\n");
}

/* The geometry. */

static void test_rect_at_both_scales(void)
{
    /* Cells of 8 by 16 pixels at scale 1, and the same cells at scale 2,
       16 by 32 pixels: the rectangle is the same in the pane's units. */
    portal_fed_rect one = portal_fed_grid_rect(80, 24, 300, 8, 16, 2, 1);
    portal_fed_rect two = portal_fed_grid_rect(80, 24, 300, 16, 32, 4, 2);
    CHECK(one.x == 0 && one.y == -8 && one.width == 648 && one.height == 396);
    CHECK(one.top == -88);
    CHECK(two.x == 0 && two.y == -8 && two.width == 648 && two.height == 396);
    CHECK(two.top == -88);
    /* A grid smaller than the pane: its last row at the pane's bottom, the
       rest of the pane above it.  10 * 9 + 4 + 4.5 by 5 * 18 + 4 + 9. */
    portal_fed_rect small = portal_fed_grid_rect(10, 5, 300, 9, 18, 2, 1);
    CHECK(small.y == -9 && small.width == 98.5 && small.height == 103);
    CHECK(small.top == 206);
    /* At scale 2 with odd pixels: (10 * 9 + 8 + 4.5) / 2 by
       (5 * 19 + 8 + 9.5) / 2, hanging 4.75 below. */
    portal_fed_rect odd = portal_fed_grid_rect(10, 5, 100, 9, 19, 4, 2);
    CHECK(odd.y == -4.75 && odd.width == 51.25 && odd.height == 56.25);
    CHECK(odd.top == 48.5);
    /* Ghostty's padding on Linux, 5 pixels at scale 2:
       (80 * 16 + 10 + 8) / 2 by (24 * 32 + 10 + 16) / 2. */
    portal_fed_rect linux = portal_fed_grid_rect(80, 24, 300, 16, 32, 5, 2);
    CHECK(linux.y == -8 && linux.width == 649 && linux.height == 397);
    CHECK(linux.top == -89);
}

static void test_pane_grid_at_both_scales(void)
{
    uint32_t columns, rows;
    portal_fed_pane_grid(400, 300, 8, 16, 2, 1, &columns, &rows);
    CHECK(columns == 49 && rows == 18);
    portal_fed_pane_grid(400, 300, 16, 32, 4, 2, &columns, &rows);
    CHECK(columns == 49 && rows == 18);
    /* Exactly whole: (804 - 4) / 8 and (324 - 4) / 16. */
    portal_fed_pane_grid(804, 324, 8, 16, 2, 1, &columns, &rows);
    CHECK(columns == 100 && rows == 20);
    /* At scale 2 the padding is 8 pixels: (402 * 2 - 8) / 16. */
    portal_fed_pane_grid(402, 162, 16, 32, 4, 2, &columns, &rows);
    CHECK(columns == 49 && rows == 9);
    /* With Linux's 5 pixels, a pane that holds a column more at 4 does not:
       (402 * 2 - 10) / 16 is 49.6, and (404 * 2 - 8) / 16 is 50. */
    portal_fed_pane_grid(404, 162, 16, 32, 4, 2, &columns, &rows);
    CHECK(columns == 50);
    portal_fed_pane_grid(404, 162, 16, 32, 5, 2, &columns, &rows);
    CHECK(columns == 49);
    /* Smaller than the padding, or nothing. */
    portal_fed_pane_grid(3, 3, 8, 16, 2, 1, &columns, &rows);
    CHECK(columns == 0 && rows == 0);
    portal_fed_pane_grid(0, 0, 8, 16, 4, 2, &columns, &rows);
    CHECK(columns == 0 && rows == 0);
}

/* Ghostty's padding as the backend says it, as Linux's Ghostty has it:
   whole pixels at 96 to the inch, 5 for 2 points at scale 2. */
static void test_padding_told(void)
{
    portal_fed_terminal *terminal = make();
    portal_fed_terminal_pane(terminal, 404, 300, 2);
    portal_fed_terminal_cell(terminal, 16, 32);
    /* At the default 4: (808 - 8) / 16 and (600 - 8) / 32. */
    HAPPENED("place x 0 y 0 width 404 height 300 top 0\n"
             "core t1 grid 50x18 cell 16x32\n");
    /* At 5, a column fewer: (808 - 10) / 16. */
    portal_fed_terminal_padding(terminal, 5);
    HAPPENED("core t1 grid 49x18 cell 16x32\n");
    /* A held grid is that much larger: (80 * 16 + 10 + 8) / 2 by
       (24 * 32 + 10 + 16) / 2, hanging 8 below. */
    CHECK(hold(terminal, 80, 24));
    HAPPENED("drain\n"
             "place x 0 y -8 width 649 height 397 top -89\n"
             "start take-grid 250 ms\n");
    /* Back to the default. */
    portal_fed_terminal_padding(terminal, 0);
    HAPPENED("place x 0 y -8 width 648 height 396 top -88\n"
             "core t1 grid 50x18 cell 16x32\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("stop take-grid\n");
}

static void test_pane_reports(void)
{
    portal_fed_terminal *terminal = make();
    /* Before the cell is known, the terminal fills its pane and nothing is
       reported. */
    portal_fed_terminal_pane(terminal, 400, 300, 2);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    portal_fed_terminal_cell(terminal, 16, 32);
    HAPPENED("core t1 grid 49x18 cell 16x32\n");
    /* The same again: nothing. */
    portal_fed_terminal_cell(terminal, 16, 32);
    portal_fed_terminal_pane(terminal, 400, 300, 2);
    HAPPENED("");
    /* A pane a little larger that holds the same grid: placed, not
       reported. */
    portal_fed_terminal_pane(terminal, 401, 301, 2);
    HAPPENED("place x 0 y 0 width 401 height 301 top 0\n");
    /* A change of cell size alone is reported: the text grew at scale 2,
       (802 - 8) / 18 and (602 - 8) / 36. */
    portal_fed_terminal_cell(terminal, 18, 36);
    HAPPENED("core t1 grid 44x16 cell 18x36\n");
    /* The same pane at scale 1, the cell not yet changed with it: (401 -
       4) / 18 and (301 - 4) / 36. */
    portal_fed_terminal_pane(terminal, 401, 301, 1);
    HAPPENED("core t1 grid 22x8 cell 18x36\n");
    portal_fed_terminal_cell(terminal, 9, 18);
    HAPPENED("core t1 grid 44x16 cell 9x18\n");
    /* A pane too small for a cell is placed and not reported. */
    portal_fed_terminal_pane(terminal, 6, 300, 1);
    HAPPENED("place x 0 y 0 width 6 height 300 top 0\n");
    /* The cell unknown again: nothing reported. */
    portal_fed_terminal_cell(terminal, 0, 0);
    portal_fed_terminal_pane(terminal, 500, 300, 1);
    HAPPENED("place x 0 y 0 width 500 height 300 top 0\n");
    portal_fed_terminal_free(terminal);
}

static void test_held_grid_follows_the_pane(void)
{
    portal_fed_terminal *terminal = make();
    /* A grid held before the cell is known fills the pane until it is. */
    portal_fed_terminal_took_grid(terminal, 80, 24);
    CHECK(hold(terminal, 80, 24));
    HAPPENED("drain\nplace x 0 y 0 width 0 height 0 top 0\n");
    portal_fed_terminal_pane(terminal, 400, 300, 2);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    portal_fed_terminal_cell(terminal, 16, 32);
    HAPPENED("place x 0 y -8 width 648 height 396 top -88\n"
             "core t1 grid 49x18 cell 16x32\n");
    /* A taller pane: the same rectangle, from a lower top. */
    portal_fed_terminal_pane(terminal, 400, 500, 2);
    HAPPENED("place x 0 y -8 width 648 height 396 top 112\n"
             "core t1 grid 49x31 cell 16x32\n");
    /* The same pane at scale 1, its cells 16 by 32 still: twice as large
       in the pane's units, hanging 16 below. */
    portal_fed_terminal_pane(terminal, 400, 500, 1);
    HAPPENED("place x 0 y -16 width 1292 height 788 top -272\n"
             "core t1 grid 24x15 cell 16x32\n");
    portal_fed_terminal_free(terminal);
}

/* The backlog. */

static void test_backlog_crossings(void)
{
    const size_t high = PORTAL_FED_HIGH_MARK, low = PORTAL_FED_LOW_MARK;
    CHECK(high == 524288 && low == 131072);
    /* Rising past the high mark, and only past it. */
    CHECK(portal_fed_backlog_crossed(0, high + 1));
    CHECK(portal_fed_backlog_crossed(high, high + 1));
    CHECK(!portal_fed_backlog_crossed(0, high));
    CHECK(!portal_fed_backlog_crossed(high + 1, high + 2));
    CHECK(!portal_fed_backlog_crossed(low, low + 1));
    /* Falling to the low mark, and only to it. */
    CHECK(portal_fed_backlog_crossed(low + 1, low));
    CHECK(portal_fed_backlog_crossed(high + 1, 0));
    CHECK(!portal_fed_backlog_crossed(low, 0));
    CHECK(!portal_fed_backlog_crossed(high + 1, high));
    CHECK(!portal_fed_backlog_crossed(high + 1, low + 1));
    CHECK(!portal_fed_backlog_crossed(0, 0));
}

static void test_backlog_across_both_marks(void)
{
    portal_fed_terminal *terminal = make();
    /* Past the high mark: the core waits, and the count is looked at again
       every 10 ms. */
    waiting_bytes = PORTAL_FED_HIGH_MARK + 1;
    portal_fed_terminal_backlog(terminal);
    HAPPENED("core t1 backlog on\nstart backlog-look 10 ms\n");
    /* Below the high mark but above the low one: still waiting. */
    waiting_bytes = PORTAL_FED_HIGH_MARK - 1;
    run_out(terminal, PORTAL_FED_BACKLOG_LOOK);
    HAPPENED("start backlog-look 10 ms\n");
    waiting_bytes = PORTAL_FED_LOW_MARK + 1;
    run_out(terminal, PORTAL_FED_BACKLOG_LOOK);
    HAPPENED("start backlog-look 10 ms\n");
    /* A crossing heard meanwhile looks at once, and starts the look
       again. */
    portal_fed_terminal_backlog(terminal);
    HAPPENED("stop backlog-look\nstart backlog-look 10 ms\n");
    /* Down to the low mark: the core goes on, and nothing looks again. */
    waiting_bytes = PORTAL_FED_LOW_MARK;
    run_out(terminal, PORTAL_FED_BACKLOG_LOOK);
    HAPPENED("core t1 backlog off\n");
    CHECK(!timers);
    /* A crossing heard late, with nothing waiting by then: nothing said. */
    waiting_bytes = 0;
    portal_fed_terminal_backlog(terminal);
    HAPPENED("");
    portal_fed_terminal_free(terminal);
    HAPPENED("");
}

static void test_backlog_crossings_out_of_order(void)
{
    portal_fed_terminal *terminal = make();
    /* The fall was heard before the rise, and the count is high: the last
       look says how it is. */
    waiting_bytes = PORTAL_FED_HIGH_MARK + 1;
    portal_fed_terminal_backlog(terminal);
    portal_fed_terminal_backlog(terminal);
    HAPPENED("core t1 backlog on\n"
             "start backlog-look 10 ms\n"
             "stop backlog-look\n"
             "start backlog-look 10 ms\n");
    /* The rise came after its fall, with nothing left: the look the rise
       started finds that. */
    waiting_bytes = 0;
    run_out(terminal, PORTAL_FED_BACKLOG_LOOK);
    HAPPENED("core t1 backlog off\n");
    /* Freed while waiting: the look is stopped. */
    waiting_bytes = PORTAL_FED_HIGH_MARK + 1;
    portal_fed_terminal_backlog(terminal);
    HAPPENED("core t1 backlog on\nstart backlog-look 10 ms\n");
    portal_fed_terminal_free(terminal);
    HAPPENED("stop backlog-look\n");
    CHECK(!timers);
}

static void test_timers_apart(void)
{
    portal_fed_terminal *terminal = make_in_pane();
    CHECK(hold(terminal, 80, 24));
    CHECK(fed(terminal, "held"));
    waiting_bytes = PORTAL_FED_HIGH_MARK + 1;
    portal_fed_terminal_backlog(terminal);
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "start take-grid 250 ms\n"
             "core t1 backlog on\n"
             "start backlog-look 10 ms\n");
    /* The backlog's look leaves the grid's wait alone, and the other way. */
    run_out(terminal, PORTAL_FED_BACKLOG_LOOK);
    HAPPENED("start backlog-look 10 ms\n");
    run_out(terminal, PORTAL_FED_TAKE_GRID);
    HAPPENED("feed held\n");
    /* A call for a timer that does not run does nothing. */
    portal_fed_terminal_timer(terminal, PORTAL_FED_TAKE_GRID);
    HAPPENED("");
    portal_fed_terminal_free(terminal);
    HAPPENED("stop backlog-look\n");
}

int main(void)
{
    test_output_alone();
    test_grid_between_outputs();
    test_grid_taken_late();
    test_grid_already_taken();
    test_grids_in_a_row();
    test_freed_while_taking();
    test_grid_refused();
    test_rect_at_both_scales();
    test_pane_grid_at_both_scales();
    test_pane_reports();
    test_padding_told();
    test_held_grid_follows_the_pane();
    test_backlog_crossings();
    test_backlog_across_both_marks();
    test_backlog_crossings_out_of_order();
    test_timers_apart();
    if (failures) {
        fprintf(stderr, "%d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("%d checks passed\n", checks);
    return 0;
}
