/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal's rules, native/Core/fed.c, with the fake platform: the
   order of output and grids, the geometry of a pane and the grid it
   reports, and the backlog.  The test plays the platform's side, telling
   the core the pane, the cell, the grid taken and the backlog's crossings,
   and compares the fake's log of what the core asked, line by line, with
   what should have happened.  The fed terminals here are never attached,
   so the fake takes no grid of its own accord. */
#include "fed.h"
#include "portal-core-tests.h"

/* Check that the fake's log since the last look is EXPECTED. */
#define HAPPENED(expected) happened((expected), __LINE__)

static void happened(const char *expected, int line)
{
    const char *log = portal_fake_fed_log();
    checks++;
    if (strcmp(log, expected)) {
        fprintf(stderr, "%s:%d: FAIL: what happened was\n%s-- and not --\n%s--\n", __FILE__,
                line, log, expected);
        failures++;
    }
}

/* Whether the grid TARGET's pane holds, as the core keeps it, is EXPECTED,
   such as "49x18 cell 8x16". */
static bool grid_is(const char *target, const char *expected)
{
    uint32_t grid[4] = {0};
    char said[64];
    portal_views_grid(text(target), grid);
    snprintf(said, sizeof said, "%ux%u cell %ux%u", grid[0], grid[1], grid[2], grid[3]);
    if (strcmp(said, expected))
        fprintf(stderr, "Expected the grid %s, got %s\n", expected, said);
    return !strcmp(said, expected);
}

/* A fed terminal, never attached, with nothing logged. */
static char *make(void)
{
    portal_option fed = {.name = text("fed"), .flag = true};
    portal_text target = {0}, error = {0};
    if (!portal_views_open(text("terminal"), &fed, 1, &target, &error)) {
        fprintf(stderr, "Opening a fed terminal failed: %s\n", error.data);
        exit(2);
    }
    portal_fake_fed_log();
    return target.data;
}

static bool fed(const char *target, const char *output)
{
    portal_text error = {0};
    bool done = portal_fed_feed(text(target), output, strlen(output), &error);
    free(error.data);
    return done;
}

static bool hold(const char *target, uint32_t columns, uint32_t rows)
{
    portal_text error = {0};
    bool done = portal_fed_hold_grid(text(target), columns, rows, &error);
    free(error.data);
    return done;
}

static void took(const char *target, uint32_t columns, uint32_t rows)
{
    portal_terminal_took_grid(text(target), columns, rows);
}

/* The pane is WIDTH by HEIGHT at SCALE, with the Mac's padding: 2 pixels at
   scale 1, 4 at scale 2. */
static void pane(const char *target, double width, double height, double scale)
{
    portal_terminal_pane(text(target), width, height, scale, PORTAL_TERMINAL_PADDING * scale);
}

/* TARGET has BYTES waiting to be parsed, and a mark was crossed. */
static void backlog(const char *target, size_t bytes)
{
    portal_fake_pending(target, bytes);
    portal_terminal_backlog(text(target));
}

/* A pane of 400 by 300 at scale 1, with cells of 8 by 16: its grid is 49
   by 18, (400 - 4) / 8 and (300 - 4) / 16. */
static char *make_in_pane(void)
{
    char *target = make();
    pane(target, 400, 300, 1);
    portal_terminal_cell(text(target), 8, 16);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    CHECK(grid_is(target, "49x18 cell 8x16"));
    return target;
}

/* The order. */

static void test_output_alone(void)
{
    char *target = make();
    CHECK(fed(target, "one"));
    CHECK(fed(target, "two"));
    CHECK(fed(target, ""));
    HAPPENED("parse one\nparse two\n");
    close_view(target);
    HAPPENED("");
}

static void test_grid_between_outputs(void)
{
    char *target = make_in_pane();
    CHECK(fed(target, "before"));
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "after"));
    CHECK(fed(target, "later"));
    /* The output before is parsed on the old grid; the grid then holds
       what comes after it. */
    HAPPENED("parse before\n"
             "drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "timer 250 ms\n");
    /* Other sizes first, as a surface reports on its way: still held. */
    took(target, 49, 18);
    took(target, 79, 24);
    took(target, 80, 23);
    took(target, 0, 0);
    HAPPENED("");
    took(target, 80, 24);
    HAPPENED("parse after\nparse later\n");
    CHECK(fed(target, "now"));
    HAPPENED("parse now\n");
    /* The wait, ended, counts for nothing when its timer fires. */
    portal_fake_fire_timers();
    CHECK(fed(target, "then"));
    HAPPENED("parse then\n");
    close_view(target);
    HAPPENED("");
}

static void test_grid_taken_late(void)
{
    char *target = make_in_pane();
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "after"));
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "timer 250 ms\n");
    /* A quarter of a second, and the output goes on without it. */
    portal_fake_fire_timers_of(PORTAL_FED_TAKE_GRID_MS);
    HAPPENED("parse after\n");
    /* The grid it took at last changes nothing. */
    took(target, 80, 24);
    CHECK(fed(target, "then"));
    HAPPENED("parse then\n");
    close_view(target);
    HAPPENED("");
}

static void test_grid_already_taken(void)
{
    char *target = make_in_pane();
    took(target, 80, 24);
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "after"));
    /* The terminal has that grid: nothing waits. */
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "parse after\n");
    /* The same grid again: no new place. */
    CHECK(hold(target, 80, 24));
    HAPPENED("drain\n");
    /* A grid taken in its rows alone, or its columns alone, is not it. */
    took(target, 79, 24);
    CHECK(hold(target, 80, 24));
    HAPPENED("drain\ntimer 250 ms\n");
    took(target, 80, 24);
    CHECK(fed(target, "taken"));
    HAPPENED("parse taken\n");
    took(target, 80, 23);
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "held"));
    HAPPENED("drain\ntimer 250 ms\n");
    /* Closed while it waits: what waits is never parsed, and the wait's
       timer counts for nothing. */
    close_view(target);
    portal_fake_fire_timers();
    HAPPENED("");
}

static void test_grids_in_a_row(void)
{
    char *target = make_in_pane();
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "a"));
    CHECK(hold(target, 100, 30));
    CHECK(fed(target, "b"));
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "timer 250 ms\n");
    took(target, 80, 24);
    /* 100 * 8 + 4 + 4 by 30 * 16 + 4 + 8. */
    HAPPENED("parse a\n"
             "drain\n"
             "place x 0 y -8 width 808 height 492 top -184\n"
             "timer 250 ms\n");
    took(target, 100, 30);
    HAPPENED("parse b\n");
    close_view(target);
}

static void test_grid_refused(void)
{
    char *target = make();
    portal_text error = {0};
    CHECK(!portal_fed_hold_grid(text(target), 0, 24, &error));
    CHECK(says(&error, "A terminal's grid has at least one cell each way"));
    CHECK(!hold(target, 80, 0));
    CHECK(!hold(target, 65536, 24));
    CHECK(!hold(target, 80, 65536));
    CHECK(hold(target, 65535, 65535));
    /* With no pane known, it fills a pane of nothing. */
    HAPPENED("drain\n"
             "place x 0 y 0 width 0 height 0 top 0\n"
             "timer 250 ms\n");
    close_view(target);
    portal_fake_fire_timers();
}

/* What a platform tells while it creates the view counts once the view is
   open. */
static void test_told_while_created(void)
{
    portal_option options[] = {{.name = text("fed"), .flag = true},
                               {.name = text("early"), .flag = true}};
    portal_text target = {0}, error = {0};
    CHECK(portal_views_open(text("terminal"), options, 2, &target, &error));
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    CHECK(grid_is(target.data, "49x18 cell 8x16"));
    close_view(target.data);
}

/* Only an open fed terminal is fed; the platform's calls for anything else
   change nothing, and a primitive's failure is the feed's. */
static void test_only_fed_terminals(void)
{
    portal_text error = {0};
    CHECK(!portal_fed_feed(text("terminal:none"), "x", 1, &error));
    CHECK(says(&error, "No fed terminal terminal:none"));
    CHECK(!portal_fed_hold_grid(text("terminal:none"), 80, 24, &error));
    CHECK(says(&error, "No fed terminal terminal:none"));
    char *own = open_view("terminal", &error, "directory", "/tmp", NULL);
    char message[64];
    snprintf(message, sizeof message, "No fed terminal %s", own);
    CHECK(!portal_fed_feed(text(own), "x", 1, &error));
    CHECK(says(&error, message));
    portal_terminal_pane(text(own), 400, 300, 1, 2);
    portal_terminal_cell(text(own), 8, 16);
    took(own, 80, 24);
    portal_terminal_backlog(text(own));
    portal_terminal_backlog(text("terminal:none"));
    HAPPENED("");
    CHECK(grid_is(own, "0x0 cell 0x0"));
    CHECK(!portal_fed_backlogged(text(own)));
    close_view(own);
    portal_option options[] = {{.name = text("fed"), .flag = true},
                               {.name = text("broken"), .is_string = true,
                                .string = text("The terminal broke")}};
    portal_text target = {0};
    CHECK(portal_views_open(text("terminal"), options, 2, &target, &error));
    CHECK(!portal_fed_feed(text(target.data), "x", 1, &error));
    CHECK(says(&error, "The terminal broke"));
    close_view(target.data);
}

/* The geometry. */

static void test_rect_at_both_scales(void)
{
    /* Cells of 8 by 16 pixels at scale 1, and the same cells at scale 2,
       16 by 32 pixels: the rectangle is the same in the pane's units. */
    portal_pane_rect one = portal_fed_grid_rect(80, 24, 300, 8, 16, 2, 1);
    portal_pane_rect two = portal_fed_grid_rect(80, 24, 300, 16, 32, 4, 2);
    CHECK(one.x == 0 && one.y == -8 && one.width == 648 && one.height == 396);
    CHECK(one.top == -88);
    CHECK(two.x == 0 && two.y == -8 && two.width == 648 && two.height == 396);
    CHECK(two.top == -88);
    /* A grid smaller than the pane: its last row at the pane's bottom, the
       rest of the pane above it.  10 * 9 + 4 + 4.5 by 5 * 18 + 4 + 9. */
    portal_pane_rect small = portal_fed_grid_rect(10, 5, 300, 9, 18, 2, 1);
    CHECK(small.y == -9 && small.width == 98.5 && small.height == 103);
    CHECK(small.top == 206);
    /* At scale 2 with odd pixels: (10 * 9 + 8 + 4.5) / 2 by
       (5 * 19 + 8 + 9.5) / 2, hanging 4.75 below. */
    portal_pane_rect odd = portal_fed_grid_rect(10, 5, 100, 9, 19, 4, 2);
    CHECK(odd.y == -4.75 && odd.width == 51.25 && odd.height == 56.25);
    CHECK(odd.top == 48.5);
    /* Ghostty's padding on Linux, 5 pixels at scale 2:
       (80 * 16 + 10 + 8) / 2 by (24 * 32 + 10 + 16) / 2. */
    portal_pane_rect linux = portal_fed_grid_rect(80, 24, 300, 16, 32, 5, 2);
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

/* Ghostty's padding as the platform says it, as Linux's Ghostty has it:
   whole pixels at 96 to the inch, 5 for 2 points at scale 2. */
static void test_padding_told(void)
{
    char *target = make();
    pane(target, 404, 300, 2);
    portal_terminal_cell(text(target), 16, 32);
    /* At the Mac's 4: (808 - 8) / 16 and (600 - 8) / 32. */
    HAPPENED("place x 0 y 0 width 404 height 300 top 0\n");
    CHECK(grid_is(target, "50x18 cell 16x32"));
    /* At 5, a column fewer: (808 - 10) / 16. */
    portal_terminal_pane(text(target), 404, 300, 2, 5);
    HAPPENED("");
    CHECK(grid_is(target, "49x18 cell 16x32"));
    /* A held grid is that much larger: (80 * 16 + 10 + 8) / 2 by
       (24 * 32 + 10 + 16) / 2, hanging 8 below. */
    CHECK(hold(target, 80, 24));
    HAPPENED("drain\n"
             "place x 0 y -8 width 649 height 397 top -89\n"
             "timer 250 ms\n");
    /* Back to 4. */
    pane(target, 404, 300, 2);
    HAPPENED("place x 0 y -8 width 648 height 396 top -88\n");
    CHECK(grid_is(target, "50x18 cell 16x32"));
    close_view(target);
    portal_fake_fire_timers();
}

static void test_pane_reports(void)
{
    char *target = make();
    /* Before the cell is known, the terminal fills its pane and no grid is
       known. */
    pane(target, 400, 300, 2);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    CHECK(grid_is(target, "0x0 cell 0x0"));
    portal_terminal_cell(text(target), 16, 32);
    CHECK(grid_is(target, "49x18 cell 16x32"));
    /* The same again: nothing. */
    portal_terminal_cell(text(target), 16, 32);
    pane(target, 400, 300, 2);
    HAPPENED("");
    /* A pane a little larger that holds the same grid: placed. */
    pane(target, 401, 301, 2);
    HAPPENED("place x 0 y 0 width 401 height 301 top 0\n");
    CHECK(grid_is(target, "49x18 cell 16x32"));
    /* A change of cell size alone counts: the text grew at scale 2,
       (802 - 8) / 18 and (602 - 8) / 36. */
    portal_terminal_cell(text(target), 18, 36);
    CHECK(grid_is(target, "44x16 cell 18x36"));
    /* The same pane at scale 1, the cell not yet changed with it: (401 -
       4) / 18 and (301 - 4) / 36. */
    pane(target, 401, 301, 1);
    CHECK(grid_is(target, "22x8 cell 18x36"));
    portal_terminal_cell(text(target), 9, 18);
    CHECK(grid_is(target, "44x16 cell 9x18"));
    /* A pane too small for a cell is placed, and keeps the grid it had. */
    pane(target, 6, 300, 1);
    HAPPENED("place x 0 y 0 width 6 height 300 top 0\n");
    CHECK(grid_is(target, "44x16 cell 9x18"));
    /* The cell unknown again: the grid stays. */
    portal_terminal_cell(text(target), 0, 0);
    pane(target, 500, 300, 1);
    HAPPENED("place x 0 y 0 width 500 height 300 top 0\n");
    CHECK(grid_is(target, "44x16 cell 9x18"));
    close_view(target);
}

static void test_held_grid_follows_the_pane(void)
{
    char *target = make();
    /* A grid held before the cell is known fills the pane until it is. */
    took(target, 80, 24);
    CHECK(hold(target, 80, 24));
    HAPPENED("drain\nplace x 0 y 0 width 0 height 0 top 0\n");
    pane(target, 400, 300, 2);
    HAPPENED("place x 0 y 0 width 400 height 300 top 0\n");
    portal_terminal_cell(text(target), 16, 32);
    HAPPENED("place x 0 y -8 width 648 height 396 top -88\n");
    CHECK(grid_is(target, "49x18 cell 16x32"));
    /* A taller pane: the same rectangle, from a lower top. */
    pane(target, 400, 500, 2);
    HAPPENED("place x 0 y -8 width 648 height 396 top 112\n");
    CHECK(grid_is(target, "49x31 cell 16x32"));
    /* The same pane at scale 1, its cells 16 by 32 still: twice as large
       in the pane's units, hanging 16 below. */
    pane(target, 400, 500, 1);
    HAPPENED("place x 0 y -16 width 1292 height 788 top -272\n");
    CHECK(grid_is(target, "24x15 cell 16x32"));
    close_view(target);
}

/* The backlog. */

static void test_backlog_crossings(void)
{
    const size_t high = PORTAL_TERMINAL_BACKLOG, low = PORTAL_TERMINAL_BACKLOG_LOW;
    CHECK(high == 524288 && low == 131072);
    /* Rising past the high mark, and only past it. */
    CHECK(portal_terminal_backlog_crossed(0, high + 1));
    CHECK(portal_terminal_backlog_crossed(high, high + 1));
    CHECK(!portal_terminal_backlog_crossed(0, high));
    CHECK(!portal_terminal_backlog_crossed(high + 1, high + 2));
    CHECK(!portal_terminal_backlog_crossed(low, low + 1));
    /* Falling to the low mark, and only to it. */
    CHECK(portal_terminal_backlog_crossed(low + 1, low));
    CHECK(portal_terminal_backlog_crossed(high + 1, 0));
    CHECK(!portal_terminal_backlog_crossed(low, 0));
    CHECK(!portal_terminal_backlog_crossed(high + 1, high));
    CHECK(!portal_terminal_backlog_crossed(high + 1, low + 1));
    CHECK(!portal_terminal_backlog_crossed(0, 0));
}

static void test_backlog_across_both_marks(void)
{
    char *target = make();
    /* Past the high mark: the program waits, and the count is looked at
       again every 10 ms. */
    backlog(target, PORTAL_TERMINAL_BACKLOG + 1);
    CHECK(portal_fed_backlogged(text(target)));
    HAPPENED("timer 10 ms\n");
    /* Below the high mark but above the low one: still waiting. */
    portal_fake_pending(target, PORTAL_TERMINAL_BACKLOG - 1);
    portal_fake_fire_timers_of(PORTAL_FED_BACKLOG_LOOK_MS);
    HAPPENED("timer 10 ms\n");
    portal_fake_pending(target, PORTAL_TERMINAL_BACKLOG_LOW + 1);
    portal_fake_fire_timers_of(PORTAL_FED_BACKLOG_LOOK_MS);
    HAPPENED("timer 10 ms\n");
    CHECK(portal_fed_backlogged(text(target)));
    /* A crossing heard meanwhile looks at once, and starts the look
       again: the one before counts for nothing. */
    portal_terminal_backlog(text(target));
    HAPPENED("timer 10 ms\n");
    CHECK(portal_fake_timers() == 2);
    /* Down to the low mark: the program goes on, and nothing looks
       again. */
    portal_fake_pending(target, PORTAL_TERMINAL_BACKLOG_LOW);
    portal_fake_fire_timers_of(PORTAL_FED_BACKLOG_LOOK_MS);
    CHECK(!portal_fed_backlogged(text(target)));
    HAPPENED("");
    CHECK(!portal_fake_timers());
    /* A crossing heard late, with nothing waiting by then: nothing
       changes. */
    backlog(target, 0);
    CHECK(!portal_fed_backlogged(text(target)));
    HAPPENED("");
    close_view(target);
}

static void test_backlog_crossings_out_of_order(void)
{
    char *target = make();
    /* The fall was heard before the rise, and the count is high: the last
       look says how it is. */
    backlog(target, PORTAL_TERMINAL_BACKLOG + 1);
    portal_terminal_backlog(text(target));
    CHECK(portal_fed_backlogged(text(target)));
    HAPPENED("timer 10 ms\ntimer 10 ms\n");
    /* The rise came after its fall, with nothing left: the look the rise
       started finds that. */
    portal_fake_pending(target, 0);
    portal_fake_fire_timers();
    CHECK(!portal_fed_backlogged(text(target)));
    HAPPENED("");
    /* Closed while waiting: the look counts for nothing. */
    backlog(target, PORTAL_TERMINAL_BACKLOG + 1);
    CHECK(portal_fed_backlogged(text(target)));
    HAPPENED("timer 10 ms\n");
    close_view(target);
    portal_fake_fire_timers();
    HAPPENED("");
    CHECK(!portal_fake_timers());
}

static void test_timers_apart(void)
{
    char *target = make_in_pane();
    CHECK(hold(target, 80, 24));
    CHECK(fed(target, "held"));
    backlog(target, PORTAL_TERMINAL_BACKLOG + 1);
    HAPPENED("drain\n"
             "place x 0 y -8 width 648 height 396 top -88\n"
             "timer 250 ms\n"
             "timer 10 ms\n");
    /* The backlog's look leaves the grid's wait alone, and the other way. */
    portal_fake_fire_timers_of(PORTAL_FED_BACKLOG_LOOK_MS);
    HAPPENED("timer 10 ms\n");
    portal_fake_fire_timers_of(PORTAL_FED_TAKE_GRID_MS);
    HAPPENED("parse held\n");
    CHECK(portal_fed_backlogged(text(target)));
    close_view(target);
    portal_fake_fire_timers();
    HAPPENED("");
}

int main(void)
{
    test_output_alone();
    test_grid_between_outputs();
    test_grid_taken_late();
    test_grid_already_taken();
    test_grids_in_a_row();
    test_grid_refused();
    test_told_while_created();
    test_only_fed_terminals();
    test_rect_at_both_scales();
    test_pane_grid_at_both_scales();
    test_padding_told();
    test_pane_reports();
    test_held_grid_follows_the_pane();
    test_backlog_crossings();
    test_backlog_across_both_marks();
    test_backlog_crossings_out_of_order();
    test_timers_apart();
    CHECK(!portal_fake_calls().misused);
    if (failures) {
        fprintf(stderr, "%d of %d checks failed\n", failures, checks);
        return 1;
    }
    puts("A fed terminal's rules passed");
    printf("%d checks passed\n", checks);
    return 0;
}
