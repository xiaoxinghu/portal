/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's view registry, native/Core/views.c, with the fake platform.
   These check what the core owns: targets, kinds, the placement it keeps,
   and that no platform view is used outside its life.  The fake counts every
   primitive the core calls, and any call naming a destroyed view.  Where a
   view goes when detached is the platform's business, so these only check
   that the core keeps the same platform view throughout. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "portal-core-tests.h"
#include "portal-fake-backend.h"
#include "portal.h"
#include "terminals.h"
#include "views.h"

static bool place(const char *target, portal_edges edges, const char *frame,
                  portal_text *error)
{
    return portal_views_place(text(target), edges, text(frame), error);
}

/* A view's ID, from its target. */
static long id(const char *target)
{
    return strtol(strchr(target, ':') + 1, NULL, 10);
}

static void test_targets_are_never_reused(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char *terminal = open_view("terminal", &error, "directory", "/", NULL);
    CHECK(web && !strncmp(web, "web:", 4));
    CHECK(terminal && !strncmp(terminal, "terminal:", 9));
    /* IDs are global across kinds. */
    CHECK(id(terminal) == id(web) + 1);
    CHECK(shows(web, "{\"id\":", "\"kind\":\"web\",\"visible\":false,\"edges\":[],\"handle\":",
                NULL));
    CHECK(shows(terminal, "\"kind\":\"terminal\"", NULL));
    long last = id(terminal);
    close_view(terminal);

    /* A failed open registers nothing, yet its ID is spent. */
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(!open_view("terminal", &error, "directory", "/", "fail", "No shell", NULL));
    CHECK(says(&error, "No shell"));
    CHECK(!open_view("window", &error, NULL));
    CHECK(says(&error, "Unknown Portal view kind: window"));
    CHECK(same_calls(portal_fake_calls(), before));
    char failed[32];
    snprintf(failed, sizeof failed, "terminal:%ld", last + 1);
    CHECK(shows(failed, "null", NULL));
    CHECK(!portal_notify(text("select"), text(failed), NULL, 0));

    /* Neither a closed nor a failed view's ID comes back. */
    char *next = open_view("terminal", &error, "directory", "/", NULL);
    CHECK(next && id(next) == last + 2);
    close_view(next);
    close_view(web);
    CHECK(!portal_fake_calls().misused);
}

static void test_invalid_targets_reach_no_view(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char absent[32];
    snprintf(absent, sizeof absent, "web:%ld", id(web) + 1000);
    const char *targets[] = {"", "web", "web:", absent, "Web:1", "1", "web:01"};
    struct portal_fake_calls before = portal_fake_calls();
    for (size_t i = 0; i < sizeof targets / sizeof *targets; i++) {
        char message[64];
        snprintf(message, sizeof message, "No Portal view %s", targets[i]);
        CHECK(!place(targets[i], (portal_edges) {0, 0, 10, 10}, "frame", &error));
        CHECK(says(&error, message));
        CHECK(!portal_views_hide(text(targets[i]), &error));
        CHECK(says(&error, message));
        CHECK(!portal_views_close(text(targets[i]), &error));
        CHECK(says(&error, message));
        CHECK(shows(targets[i], "null", NULL));
        CHECK(!portal_views_find(text(targets[i]), PORTAL_ANY_KIND, NULL));
    }
    /* A target matches in full, NUL bytes and all. */
    char nul[40];
    size_t length = strlen(web);
    memcpy(nul, web, length + 1);
    portal_string with_nul = {nul, length + 1};
    CHECK(!portal_views_hide(with_nul, &error));
    char message[64] = "No Portal view ";
    memcpy(message + 15, nul, length + 1);
    CHECK(said(&error, message, 15 + length + 1));
    CHECK(same_calls(portal_fake_calls(), before));
    close_view(web);
}

static void test_operations_check_the_kind(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    char *terminal = open_view("terminal", &error, "directory", "/", NULL);
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", web);
    CHECK(!portal_views_find(text(web), PORTAL_TERMINAL, &error));
    CHECK(says(&error, message));
    CHECK(!portal_views_find(text(terminal), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(web), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(web), PORTAL_ANY_KIND, NULL)
          == portal_views_find(text(web), PORTAL_WEB, NULL));

    /* Themes reach every terminal, and only terminals. */
    portal_string beta = text("Beta"), gamma = text("Gamma");
    CHECK(portal_terminals_theme(&beta, &error));
    CHECK(shows(terminal, "\"theme\":\"Beta\"", NULL));
    char *state = inspect(web);
    CHECK(state && !strstr(state, "\"theme\":\"Beta\","));
    free(state);
    CHECK(!portal_terminals_theme(&gamma, &error));
    CHECK(says(&error, "Unknown terminal theme: Gamma"));
    CHECK(shows(terminal, "\"theme\":\"Beta\"", NULL));
    close_view(web);
    close_view(terminal);
    CHECK(!portal_fake_calls().misused);
}

static void test_the_registry_survives_closes_in_any_order(void)
{
    portal_text error = {0};
    char *first = open_view("terminal", &error, "directory", "/", NULL);
    char *second = open_view("terminal", &error, "directory", "/", NULL);
    char *third = open_view("terminal", &error, "directory", "/", NULL);
    close_view(second);
    close_view(third);
    char *fourth = open_view("terminal", &error, "directory", "/", NULL);
    portal_string alpha = text("Alpha");
    CHECK(portal_terminals_theme(&alpha, &error));
    CHECK(shows(first, "\"theme\":\"Alpha\"", NULL));
    CHECK(shows(fourth, "\"theme\":\"Alpha\"", NULL));
    close_view(first);
    close_view(fourth);
    char *fifth = open_view("terminal", &error, "directory", "/", NULL);
    CHECK(fifth && portal_views_find(text(fifth), PORTAL_TERMINAL, NULL));
    close_view(fifth);
    CHECK(!portal_fake_calls().misused);
}

static void test_invalid_rectangles_change_nothing(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    CHECK(place(web, (portal_edges) {10, 20, 110, 220}, "one", &error));
    struct portal_fake_calls before = portal_fake_calls();
    const portal_edges empty[] = {{10, 20, 10, 220}, {10, 20, 110, 20}, {10, 20, 5, 220},
                                  {10, 20, 110, -5}, {INT64_MIN, 0, INT64_MAX, 10}};
    for (size_t i = 0; i < sizeof empty / sizeof *empty; i++) {
        CHECK(!place(web, empty[i], "two", &error));
        CHECK(says(&error, i < 4 ? "Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions"
                                 : "Pane edges must fit in 32 bits"));
    }
    CHECK(!place(web, (portal_edges) {0, 0, (int64_t) INT32_MAX + 1, 10}, "two", &error));
    CHECK(says(&error, "Pane edges must fit in 32 bits"));
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(shows(web, "\"visible\":true,\"edges\":[10,20,110,220]", "\"frame\":\"one\"", NULL));
    /* The extremes that fit are fine. */
    CHECK(place(web, (portal_edges) {INT32_MIN, INT32_MIN, INT32_MAX, INT32_MAX}, "two",
                &error));
    close_view(web);
}

static void test_placing_and_hiding_again(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    struct portal_fake_calls before = portal_fake_calls();
    /* Hiding a view that was never placed has nothing to detach. */
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == before.detached);
    portal_view *handle = portal_views_find(text(web), PORTAL_ANY_KIND, NULL);
    /* The same edges in another frame still move the view, so each place
       attaches. */
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "two", &error));
    CHECK(portal_fake_calls().attached == before.attached + 3);
    CHECK(shows(web, "\"visible\":true,\"edges\":[0,0,100,100]", "\"frame\":\"two\"",
                "\"attached\":true", NULL));
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == before.detached + 1);
    CHECK(shows(web, "\"visible\":false,\"edges\":[]", "\"attached\":false", NULL));
    CHECK(portal_views_find(text(web), PORTAL_ANY_KIND, NULL) == handle);
    CHECK(portal_fake_calls().created == before.created);
    close_view(web);
}

static void test_a_failed_placement_changes_nothing(void)
{
    portal_text error = {0};
    char *web = open_view("web", &error, NULL);
    /* Detached, it stays detached. */
    CHECK(!place(web, (portal_edges) {0, 0, 100, 100}, "deleted frame", &error));
    CHECK(says(&error, "Cannot find the requested native Emacs frame"));
    CHECK(shows(web, "\"visible\":false,\"edges\":[]", "\"attached\":false", NULL));
    /* Attached, it stays where it was, and hiding still detaches it. */
    CHECK(place(web, (portal_edges) {10, 10, 50, 50}, "one", &error));
    CHECK(!place(web, (portal_edges) {0, 0, 100, 100}, "deleted frame", &error));
    CHECK(says(&error, "Cannot find the requested native Emacs frame"));
    CHECK(shows(web, "\"visible\":true,\"edges\":[10,10,50,50]", "\"frame\":\"one\"", NULL));
    size_t detached = portal_fake_calls().detached;
    CHECK(portal_views_hide(text(web), &error));
    CHECK(portal_fake_calls().detached == detached + 1);
    /* The core still owns it, and closing destroys it once. */
    size_t destroyed = portal_fake_calls().destroyed;
    close_view(web);
    CHECK(portal_fake_calls().destroyed == destroyed + 1);
}

static void test_hiding_keeps_the_session_and_its_size(void)
{
    portal_text error = {0};
    char *terminal = open_view("terminal", &error, "directory", "/", NULL);
    portal_view *handle = portal_views_find(text(terminal), PORTAL_TERMINAL, NULL);
    size_t created = portal_fake_calls().created;
    CHECK(portal_terminals_paste(text(terminal), text("echo kept"), true, &error));
    CHECK(place(terminal, (portal_edges) {0, 0, 800, 600}, "one", &error));
    CHECK(portal_views_hide(text(terminal), &error));
    CHECK(shows(terminal, "\"visible\":false", "\"size\":[800,600]", "\"text\":\"echo kept\\u000a\"",
                NULL));
    /* Placing it elsewhere moves the same platform view. */
    CHECK(place(terminal, (portal_edges) {10, 10, 410, 310}, "two", &error));
    CHECK(portal_views_find(text(terminal), PORTAL_TERMINAL, NULL) == handle);
    CHECK(portal_fake_calls().created == created);
    CHECK(shows(terminal, "\"size\":[400,300]", "\"text\":\"echo kept\\u000a\"", NULL));
    close_view(terminal);
}

static void test_a_refusing_platform_changes_nothing(void)
{
    portal_text error = {0};
    char *first = open_view("web", &error, NULL);
    char *web = open_view("web", &error, NULL);
    char *last = open_view("web", &error, NULL);
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    portal_fake_refuse(true);
    CHECK(!open_view("web", &error, NULL));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_views_hide(text(web), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_views_close(text(web), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    /* A refused close keeps the view open, in its place in the registry. */
    CHECK(!portal_views_close(text(last), &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(shows(web, "\"visible\":true", "\"attached\":true", NULL));
    CHECK(portal_views_find(text(first), PORTAL_WEB, NULL));
    CHECK(portal_views_find(text(last), PORTAL_WEB, NULL));
    size_t destroyed = portal_fake_calls().destroyed;
    close_view(web);
    close_view(last);
    char *next = open_view("web", &error, NULL);
    CHECK(next && portal_views_find(text(next), PORTAL_WEB, NULL));
    CHECK(portal_fake_calls().destroyed == destroyed + 2);
    close_view(next);
    close_view(first);
    CHECK(!portal_fake_calls().misused);
}

/* TARGET's state, exactly as the core makes it: a string to free. */
static char *described(const char *description)
{
    portal_text error = {0};
    char *target = open_view("web", &error, "description", description, NULL);
    char *state = inspect(target);
    close_view(target);
    return state;
}

static void test_descriptions_may_hold_json_whitespace(void)
{
    const char *cases[][2] = {
        {"{}", ""},
        {"{ }", ""},
        {" \t\r\n{\n}\n", ""},
        {"{\"a\":1}", ",\"a\":1}"},
        {"\n{\n  \"a\": 1,\n  \"b\": [ 2 ]\n}\n", ",\"a\": 1,\n  \"b\": [ 2 ]\n}"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        char *state = described(cases[i][0]);
        const char *end = strstr(state, "\"edges\":[]");
        CHECK(end != NULL);
        if (!end)
            continue;
        end += strlen("\"edges\":[]");
        bool same = *cases[i][1] ? !strcmp(end, cases[i][1]) : !strcmp(end, "}");
        if (!same)
            fprintf(stderr, "Description \"%s\" became \"%s\"\n", cases[i][0], state);
        CHECK(same);
        free(state);
    }
    const char *invalid[] = {"", "  ", "{", "}", "[]", "x{}", "{}x"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        portal_text error = {0}, state = {0};
        char *target = open_view("web", &error, "description", invalid[i], NULL);
        CHECK(!portal_views_inspect(text(target), &state, &error));
        CHECK(says(&error, "The platform described a view with no JSON object"));
        close_view(target);
    }
}

/* Everything the pipe holds now, valid until the next call. */
static char *drain(int fd)
{
    static char buffer[4096];
    ssize_t count = read(fd, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

static void test_closing_ends_the_view_once(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    CHECK(portal_channel_connect(fds[1]));
    portal_text error = {0}, state = {0};
    char *web = open_view("web", &error, "hosted", "yes", NULL);
    CHECK(place(web, (portal_edges) {0, 0, 100, 100}, "one", &error));
    /* The platform's records reach Emacs while the view is open. */
    CHECK(portal_notify(text("select"), text(web), NULL, 0));
    char record[64];
    snprintf(record, sizeof record, "select %s\n", web);
    CHECK(!strcmp(drain(fds[0]), record));

    struct portal_fake_calls before = portal_fake_calls();
    char *target = strdup(web);
    close_view(web);
    CHECK(portal_fake_calls().destroyed == before.destroyed + 1);
    /* Closed views are not detached first: destroying ends them wherever
       they are. */
    CHECK(portal_fake_calls().detached == before.detached);
    before = portal_fake_calls();
    char message[64];
    snprintf(message, sizeof message, "No Portal view %s", target);
    CHECK(!portal_views_close(text(target), &error));
    CHECK(says(&error, message));
    CHECK(!place(target, (portal_edges) {0, 0, 100, 100}, "one", &error));
    CHECK(says(&error, message));
    CHECK(!portal_views_hide(text(target), &error));
    CHECK(says(&error, message));
    CHECK(portal_views_inspect(text(target), &state, &error));
    CHECK(!strcmp(state.data, "null"));
    free(state.data);
    CHECK(!portal_views_find(text(target), PORTAL_WEB, NULL));
    CHECK(same_calls(portal_fake_calls(), before));
    /* A late record from the platform, for the closed view, never reaches
       Emacs; it could not reach another view either, since no target is
       reused. */
    CHECK(!portal_notify(text("select"), text(target), NULL, 0));
    CHECK(!strcmp(drain(fds[0]), ""));
    CHECK(!portal_fake_calls().misused);
    free(target);
    portal_channel_connect(-1);
    close(fds[0]);
}

int main(void)
{
    test_targets_are_never_reused();
    test_invalid_targets_reach_no_view();
    test_operations_check_the_kind();
    test_the_registry_survives_closes_in_any_order();
    test_invalid_rectangles_change_nothing();
    test_placing_and_hiding_again();
    test_a_failed_placement_changes_nothing();
    test_hiding_keeps_the_session_and_its_size();
    test_a_refusing_platform_changes_nothing();
    test_descriptions_may_hold_json_whitespace();
    test_closing_ends_the_view_once();
    CHECK(!portal_fake_calls().misused);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("The view registry passed");
    return 0;
}
