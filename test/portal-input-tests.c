/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's input handoff, native/Core/input.c, with the fake platform.
   Keys are pressed as a user would, and the fake routes them as the macOS
   platform does: it holds what the core says to hold, and replays it when a
   test runs the event loop.  Emacs's side is played by the actions
   portal-input.el takes, in its order: ack, command, then finish.  Records
   are read from a real pipe. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "portal-fake-backend.h"
#include "portal.h"
#include "views.h"

static int failures;
static int records = -1; /* The pipe's read end. */

#define CHECK(condition) check((condition), #condition, __LINE__)

static void check(bool passed, const char *condition, int line)
{
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
}

static portal_string text(const char *literal)
{
    return (portal_string) {literal, strlen(literal)};
}

enum { C = PORTAL_CONTROL, M = PORTAL_META, S = PORTAL_SUPER, SHIFT = PORTAL_SHIFT };

static void press(char character, uint32_t modifiers)
{
    portal_fake_press((portal_chord) {(unsigned char) character, modifiers}, false);
}

static void repeat(char character, uint32_t modifiers)
{
    portal_fake_press((portal_chord) {(unsigned char) character, modifiers}, true);
}

/* Whether the presses since the last call went where EXPECTED says, a
   format for the targets. */
static bool went(const char *expected, ...)
{
    char wanted[1024];
    va_list arguments;
    va_start(arguments, expected);
    vsnprintf(wanted, sizeof wanted, expected, arguments);
    va_end(arguments);
    const char *keys = portal_fake_keys();
    if (strcmp(keys, wanted))
        fprintf(stderr, "Expected keys \"%s\", got \"%s\"\n", wanted, keys);
    return !strcmp(keys, wanted);
}

/* Every record sent since the last call, valid until the next. */
static const char *received_all(void)
{
    static char buffer[4096];
    ssize_t count = read(records, buffer, sizeof buffer - 1);
    buffer[count > 0 ? count : 0] = '\0';
    return buffer;
}

/* The handoff records sent since the last call, valid until the next:
   without the focus records that each change of the keyboard sends, which
   test_focus_changes_reach_emacs checks. */
static const char *received(void)
{
    static char buffer[4096];
    const char *all = received_all();
    size_t length = 0;
    while (*all) {
        const char *end = strchr(all, '\n');
        size_t line = end ? (size_t) (end - all + 1) : strlen(all);
        if (strncmp(all, "focus ", 6)) {
            memcpy(buffer + length, all, line);
            length += line;
        }
        all += line;
    }
    buffer[length] = '\0';
    return buffer;
}

static bool same_records(const char *got, const char *expected, va_list arguments)
{
    char wanted[1024];
    vsnprintf(wanted, sizeof wanted, expected, arguments);
    if (strcmp(got, wanted))
        fprintf(stderr, "Expected records \"%s\", got \"%s\"\n", wanted, got);
    return !strcmp(got, wanted);
}

/* Whether the handoff records since the last call are EXPECTED, a format. */
static bool sent(const char *expected, ...)
{
    va_list arguments;
    va_start(arguments, expected);
    bool same = same_records(received(), expected, arguments);
    va_end(arguments);
    return same;
}

/* Whether every record since the last call is EXPECTED, a format. */
static bool sent_all(const char *expected, ...)
{
    va_list arguments;
    va_start(arguments, expected);
    bool same = same_records(received_all(), expected, arguments);
    va_end(arguments);
    return same;
}

/* The serial of the one handoff record TYPE for TARGET sent since the last
   call, or 0; set *KEY to its key field, unless KEY is NULL. */
static int64_t handoff_key(const char *type, const char *target, int64_t *event)
{
    const char *got = received();
    char format[64];
    int64_t serial = 0, key = 0;
    snprintf(format, sizeof format, "%s %s %%" SCNd64 " %%" SCNd64 "\n", type, target);
    if (sscanf(got, format, &serial, &key) != 2 || !strchr(got, '\n') || strchr(got, '\n')[1]) {
        fprintf(stderr, "Expected one %s record for %s, got \"%s\"\n", type, target, got);
        return 0;
    }
    if (event)
        *event = key;
    return serial;
}

static int64_t handoff(const char *type, const char *target)
{
    return handoff_key(type, target, NULL);
}

/* The event of TARGET's one binding record since the last call, ending that
   handoff. */
static int64_t binding(const char *target);
static bool bindings(const portal_binding *regular, size_t regular_count,
                     const portal_binding *quick, size_t quick_count, const char *failure);

/* The serial of TARGET's one key record since the last call, whose chord is
   CHARACTER with MODIFIERS, or 0. */
static int64_t key_record(const char *target, uint32_t character, uint32_t modifiers)
{
    const char *got = received();
    char format[64], wanted[128];
    int64_t serial = 0;
    snprintf(format, sizeof format, "key %s %%" SCNd64, target);
    if (sscanf(got, format, &serial) != 1)
        serial = 0;
    snprintf(wanted, sizeof wanted, "key %s %" PRId64 " %" PRIu32 " %" PRIu32 "\n", target,
             serial, character, modifiers);
    if (!serial || strcmp(got, wanted)) {
        fprintf(stderr, "Expected one key record for %s, got \"%s\"\n", target, got);
        return 0;
    }
    return serial;
}

/* Perform ACTION on TARGET with SERIAL, which must succeed; its result. */
static bool act(const char *target, const char *action, int64_t serial)
{
    bool result = false;
    portal_text error = {0};
    if (!portal_input_perform(text(target), text(action), serial, &result, &error)) {
        fprintf(stderr, "%s on %s failed: %s\n", action, target, error.data);
        free(error.data);
        failures++;
    }
    return result;
}

/* Open a view of KIND, with the flag option :quick if QUICK, attached, and
   with the keyboard. */
static char *open_view(const char *kind, bool quick)
{
    /* Terminals need a directory (terminals.c). */
    portal_option options[] = {{.name = text("directory"), .is_string = true, .string = text("/")},
                               {.name = text("quick"), .flag = true}};
    portal_text target = {0}, error = {0};
    if (!portal_views_open(text(kind), options, quick ? 2 : 1, &target, &error)
        || !portal_views_place(text(target.data), (portal_edges) {0, 0, 100, 100}, text("frame"),
                               &error))
        abort();
    CHECK(act(target.data, "focus", 0));
    CHECK(act(target.data, "focused", 0));
    return target.data;
}

static void close_view(char *target)
{
    portal_text error = {0};
    CHECK(portal_views_close(text(target), &error));
    free(target);
}

static bool same_calls(struct portal_fake_calls a, struct portal_fake_calls b)
{
    return !memcmp(&a, &b, sizeof a);
}

static void test_a_terminal_chord_falls_through(void)
{
    char *terminal = open_view("terminal", false);
    /* The program gets typing, and every chord but Super's: tmux gets C-b.
       A key that types no character, here Tab, is the program's too. */
    press('x', 0);
    press('X', SHIFT);
    press('b', C);
    press('x', M);
    press('\t', S);
    CHECK(went("%s x, %s S-X, %s C-b, %s M-x, %s s-\t", terminal, terminal, terminal, terminal,
               terminal));
    CHECK(sent(""));
    /* A Super chord goes to Emacs, as typed. */
    press('x', S);
    CHECK(went("held s-x"));
    int64_t serial = key_record(terminal, 'x', S);
    CHECK(serial > 0);
    /* Emacs has the keyboard while it handles the handoff. */
    CHECK(!act(terminal, "focused", 0));
    CHECK(act(terminal, "pending", serial));
    CHECK(portal_input_owner(text(terminal)) == PORTAL_OWNER_PENDING);
    /* Emacs is slow to acknowledge: everything typed meanwhile waits. */
    press('x', C);
    press('b', 0);
    CHECK(went("held C-x, held b"));
    portal_fake_run();
    CHECK(went(""));
    CHECK(act(terminal, "ack", serial));
    CHECK(!act(terminal, "ack", serial));
    portal_fake_run();
    CHECK(went("emacs C-x, emacs b"));
    CHECK(act(terminal, "command", serial));
    CHECK(act(terminal, "pending", serial));
    press('y', 0);
    CHECK(went("emacs y"));
    struct portal_fake_calls before = portal_fake_calls();
    CHECK(act(terminal, "finish", serial));
    CHECK(portal_fake_calls().discarded == before.discarded + 1);
    CHECK(!act(terminal, "pending", 0));
    /* Emacs gives the view the keyboard back. */
    CHECK(act(terminal, "focus", 0));
    CHECK(portal_input_owner(text(terminal)) == PORTAL_OWNER_VIEW);
    press('z', 0);
    CHECK(went("%s z", terminal));
    /* Shift made the character, and the record keeps both. */
    press('!', S | SHIFT);
    CHECK(act(terminal, "finish", key_record(terminal, '!', S | SHIFT)));
    CHECK(act(terminal, "focus", 0));
    CHECK(went("held s-S-!"));
    CHECK(sent(""));
    close_view(terminal);
}

static void test_a_page_is_offered_chords(void)
{
    char *web = open_view("web", false);
    /* Typing, and keys that type no character, go straight to the page. */
    press('x', 0);
    press('X', SHIFT);
    press('\t', C);
    CHECK(went("%s x, %s S-X, %s C-\t", web, web, web));
    /* A chord is offered, and what follows waits for the page's answer. */
    press('x', C);
    press('b', 0);
    press('s', C);
    CHECK(went("offered C-x, held b, held C-s"));
    CHECK(sent(""));
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_VIEW);
    /* Unused, it goes to Emacs, and so does what followed it. */
    portal_fake_answer(false);
    CHECK(went("unused held C-x"));
    int64_t serial = key_record(web, 'x', C);
    CHECK(portal_input_owner(text(web)) == PORTAL_OWNER_PENDING);
    CHECK(act(web, "ack", serial));
    portal_fake_run();
    CHECK(went("emacs b, emacs C-s"));
    CHECK(act(web, "command", serial));
    CHECK(act(web, "finish", serial));
    CHECK(act(web, "focus", 0));
    /* Used, it stays with the page, and so does what followed it. */
    press('z', S);
    press('a', 0);
    CHECK(went("offered s-z, held a"));
    portal_fake_answer(true);
    portal_fake_run();
    CHECK(went("used s-z, %s a", web));
    /* A chord's repeats are offered too, but never start a handoff. */
    repeat('z', S);
    portal_fake_answer(false);
    CHECK(went("offered s-z repeat, unused taken s-z repeat"));
    CHECK(sent(""));
    close_view(web);
}

static void test_shortcuts_before_emacs(void)
{
    char *terminal = open_view("terminal", false);
    struct portal_fake_calls before = portal_fake_calls();
    press('c', S);
    press('v', S);
    CHECK(went("taken s-c, taken s-v"));
    CHECK(portal_fake_calls().copied == before.copied + 1);
    CHECK(portal_fake_calls().pasted == before.pasted + 1);
    /* Held down, a shortcut repeats. */
    repeat('v', S);
    CHECK(went("taken s-v repeat"));
    CHECK(portal_fake_calls().pasted == before.pasted + 2);
    /* With other modifiers, it is Emacs's. */
    press('C', S | SHIFT);
    CHECK(act(terminal, "finish", key_record(terminal, 'C', S | SHIFT)));
    CHECK(went("held s-S-C"));
    close_view(terminal);

    /* A page may use Super-C itself; only an unused one copies. */
    char *web = open_view("web", false);
    press('c', S);
    portal_fake_answer(true);
    press('c', S);
    press('x', 0);
    portal_fake_answer(false);
    portal_fake_run();
    CHECK(went("offered s-c, used s-c, offered s-c, held x, unused taken s-c, %s x", web));
    CHECK(portal_fake_calls().copied == before.copied + 2);
    CHECK(sent(""));
    close_view(web);
}

static void test_the_keyboard_moving_during_an_offer(void)
{
    char *web = open_view("web", false);
    /* Escape before the page answers: the keys typed after the
       chord follow the keyboard to Emacs, and the chord goes nowhere. */
    press('x', C);
    press('y', 0);
    portal_fake_escape();
    portal_fake_answer(false);
    portal_fake_run();
    CHECK(went("offered C-x, held y, unused taken C-x, emacs y"));
    CHECK(sent(""));
    /* Escape with the page using the chord. */
    CHECK(act(web, "focus", 0));
    press('x', C);
    press('y', 0);
    portal_fake_escape();
    portal_fake_answer(true);
    portal_fake_run();
    CHECK(went("offered C-x, held y, used C-x, emacs y"));
    CHECK(sent(""));
    close_view(web);
}

static void test_the_trigger_again_goes_to_the_app(void)
{
    const portal_binding regular[] = {{{'j', S}, 100}};
    CHECK(bindings(regular, 1, NULL, 0, NULL));
    char *terminal = open_view("terminal", false);
    /* Typed faster than Emacs acknowledges: a native binding's chord,
       repeated, then the key held down. */
    press('j', S);
    press('j', S);
    repeat('j', S);
    press('x', 0);
    CHECK(went("held s-j, held s-j, held s-j repeat, held x"));
    int64_t event = 0, serial = handoff_key("binding", terminal, &event);
    CHECK(event == 100);
    CHECK(act(terminal, "ack", serial));
    portal_fake_run();
    /* Only the first key of the sequence, and only its press, is literal. */
    CHECK(went("taken s-j, taken s-j repeat, emacs x"));
    CHECK(sent("literal %s %" PRId64 " 0\n", terminal, serial));
    CHECK(act(terminal, "command", serial));
    CHECK(act(terminal, "literal", serial));
    CHECK(went("literal s-j"));
    CHECK(act(terminal, "focused", 0));
    CHECK(act(terminal, "pending", serial)); /* Emacs's own focus is no abandonment. */
    CHECK(act(terminal, "finish", serial));
    /* A key of the sequence after the first is Emacs's, even the trigger. */
    press('j', S);
    serial = handoff("binding", terminal);
    CHECK(act(terminal, "ack", serial));
    press('x', C);
    press('j', S);
    CHECK(went("held s-j, emacs C-x, emacs s-j"));
    CHECK(act(terminal, "finish", serial));
    CHECK(act(terminal, "focus", 0));
    /* After a chord that fell through, the trigger again is Emacs's, as in
       C-x C-x; only its repeats are dropped. */
    press('x', S);
    serial = key_record(terminal, 'x', S);
    CHECK(act(terminal, "ack", serial));
    press('x', S);
    repeat('x', S);
    CHECK(went("held s-x, emacs s-x, taken s-x repeat"));
    CHECK(sent(""));
    /* There is no literal to send. */
    portal_text error = {0};
    bool result;
    CHECK(!portal_input_perform(text(terminal), text("literal"), serial, &result, &error));
    CHECK(error.data && !strcmp(error.data, "No captured native binding key to send"));
    free(error.data);
    CHECK(act(terminal, "finish", serial));
    /* Without a trigger, there is nothing to send either. */
    error = (portal_text) {0};
    CHECK(!portal_input_perform(text(terminal), text("literal"), 0, &result, &error));
    CHECK(error.data && !strcmp(error.data, "No captured native binding key to send"));
    free(error.data);
    CHECK(sent(""));
    close_view(terminal);
    CHECK(bindings(NULL, 0, NULL, 0, NULL));
}

static void test_cancelling_a_handoff(void)
{
    char *terminal = open_view("terminal", false);
    /* C-g while Emacs reads. */
    press('x', S);
    int64_t serial = key_record(terminal, 'x', S);
    CHECK(act(terminal, "ack", serial));
    press('g', C);
    repeat('g', C);
    CHECK(went("held s-x, taken C-g, taken C-g repeat"));
    CHECK(sent("cancel %s %" PRId64 " 0\n", terminal, serial));
    CHECK(act(terminal, "finish", serial));

    /* Escape, before Emacs acknowledges: what the view held is
       dropped, and a late acknowledgement does nothing. */
    CHECK(act(terminal, "focus", 0));
    press('x', S);
    press('x', 0);
    serial = key_record(terminal, 'x', S);
    portal_fake_escape();
    CHECK(sent("escape %s %" PRId64 " 0\n", terminal, serial));
    CHECK(!act(terminal, "pending", 0));
    CHECK(!act(terminal, "ack", serial));
    portal_fake_run();
    press('y', 0);
    CHECK(went("held s-x, held x, emacs y"));

    /* Escape while the view has the keyboard only returns it. */
    CHECK(act(terminal, "focus", 0));
    portal_fake_escape();
    CHECK(!act(terminal, "focused", 0));
    CHECK(sent(""));

    /* Emacs's unfocus ends a handoff silently: Emacs asked for it. */
    CHECK(act(terminal, "focus", 0));
    press('x', S);
    serial = key_record(terminal, 'x', S);
    CHECK(act(terminal, "ack", serial));
    CHECK(act(terminal, "unfocus", 0));
    CHECK(!act(terminal, "pending", serial));
    CHECK(!act(terminal, "finish", serial));
    press('x', S);
    CHECK(went("held s-x, emacs s-x"));
    CHECK(sent(""));
    close_view(terminal);
}

static void test_a_click_abandons_a_handoff_first(void)
{
    char *web = open_view("web", false);
    press('x', C);
    portal_fake_answer(false);
    int64_t serial = key_record(web, 'x', C);
    CHECK(act(web, "ack", serial));
    /* Emacs reads the escape before the select, so it does not read the
       select as the next key. */
    CHECK(portal_fake_click(web));
    CHECK(sent("escape %s %" PRId64 " 0\nselect %s\n", web, serial, web));
    CHECK(act(web, "focused", 0));
    CHECK(!act(web, "finish", serial));
    press('x', 0);
    CHECK(went("offered C-x, unused held C-x, %s x", web));
    /* A click in the view that has the keyboard selects nothing. */
    CHECK(portal_fake_click(web));
    CHECK(sent(""));
    close_view(web);
}

static void test_emacs_moving_the_keyboard_keeps_the_handoff(void)
{
    char *terminal = open_view("terminal", false);
    char *other = open_view("terminal", false);
    press('x', S);
    int64_t serial = key_record(other, 'x', S);
    CHECK(act(other, "ack", serial));
    CHECK(act(other, "command", serial));
    /* The command gives views the keyboard, as other-window does. */
    portal_input_request(true);
    CHECK(act(terminal, "focus", 0));
    portal_input_focus(text(other), true);
    portal_input_request(false);
    CHECK(act(other, "pending", serial));
    CHECK(act(other, "finish", serial));
    CHECK(sent(""));
    /* The same report from the user abandons it. */
    CHECK(act(other, "focus", 0));
    press('x', S);
    serial = key_record(other, 'x', S);
    portal_input_focus(text(other), true);
    CHECK(sent("escape %s %" PRId64 " 0\n", other, serial));
    CHECK(went("held s-x, held s-x"));
    close_view(other);
    close_view(terminal);
}

static void test_serials_name_one_handoff(void)
{
    char *terminal = open_view("terminal", false);
    char *other = open_view("terminal", false);
    press('x', S);
    int64_t first = key_record(other, 'x', S);
    CHECK(act(other, "ack", first));
    CHECK(act(other, "finish", first));
    CHECK(act(other, "focus", 0));
    press('x', S);
    int64_t second = key_record(other, 'x', S);
    CHECK(second != first);
    /* A finished handoff's serial, or another view's, does nothing. */
    struct portal_fake_calls before = portal_fake_calls();
    const char *actions[] = {"pending", "ack", "command", "finish", "literal", "focus",
                             "unfocus", "unknown"};
    for (size_t i = 0; i < sizeof actions / sizeof *actions; i++) {
        CHECK(!act(other, actions[i], first));
        CHECK(!act(terminal, actions[i], second));
    }
    CHECK(same_calls(portal_fake_calls(), before));
    CHECK(act(other, "pending", second));
    CHECK(act(other, "finish", second));
    CHECK(!act(other, "finish", second));
    /* A target that names no view does nothing, whatever the action. */
    CHECK(!act("web:0", "unknown", 0));
    bool result = true;
    portal_text error = {0};
    CHECK(!portal_input_perform(text(terminal), text("unknown"), 0, &result, &error));
    CHECK(error.data && !strcmp(error.data, "Unknown Portal input action: unknown"));
    free(error.data);
    /* Passthrough is gone. */
    error = (portal_text) {0};
    CHECK(!portal_input_perform(text(terminal), text("passthrough"), 0, &result, &error));
    free(error.data);
    CHECK(went("held s-x, held s-x"));
    close_view(other);
    close_view(terminal);
}

static void test_hiding_or_closing_ends_a_handoff(void)
{
    char *terminal = open_view("terminal", false);
    press('x', S);
    int64_t serial = key_record(terminal, 'x', S);
    CHECK(act(terminal, "ack", serial));
    press('x', 0);
    struct portal_fake_calls before = portal_fake_calls();
    portal_text error = {0};
    CHECK(portal_views_hide(text(terminal), &error));
    CHECK(portal_fake_calls().discarded == before.discarded + 1);
    CHECK(!act(terminal, "pending", 0));
    CHECK(!act(terminal, "finish", serial));
    /* A hidden view cannot have the keyboard. */
    CHECK(!act(terminal, "focus", 0));
    CHECK(sent(""));
    CHECK(portal_views_place(text(terminal), (portal_edges) {0, 0, 100, 100}, text("frame"),
                             &error));
    CHECK(act(terminal, "focus", 0));

    /* Closing before Emacs acknowledges: the late acknowledgement and
       completion reach no view, and no later view takes the serial. */
    press('x', S);
    press('y', 0);
    serial = key_record(terminal, 'x', S);
    char *closed = strdup(terminal);
    close_view(terminal);
    CHECK(!act(closed, "ack", serial));
    CHECK(!act(closed, "finish", serial));
    char *next = open_view("terminal", false);
    CHECK(!act(next, "ack", serial));
    press('y', 0);
    CHECK(went("held s-x, emacs x, held s-x, held y, %s y", next));
    CHECK(sent(""));
    free(closed);
    close_view(next);
}

static bool bindings(const portal_binding *regular, size_t regular_count,
                     const portal_binding *quick, size_t quick_count, const char *failure)
{
    portal_text error = {0};
    bool done = portal_input_bindings(regular, regular_count, quick, quick_count, &error);
    bool expected = failure ? !done && error.data && !strcmp(error.data, failure) : done;
    if (!expected)
        fprintf(stderr, "Expected %s, got %s\n", failure ? failure : "success",
                error.data ? error.data : "success");
    free(error.data);
    return expected;
}

static int64_t binding(const char *target)
{
    int64_t event = 0, serial = handoff_key("binding", target, &event);
    CHECK(act(target, "finish", serial));
    CHECK(act(target, "focus", 0));
    return event;
}

static void test_native_bindings_by_profile(void)
{
    const portal_binding regular[] = {{{'j', C}, 100}, {{'!', S}, 101}, {{'J', S | SHIFT}, 102}};
    const portal_binding quick[] = {{{'`', S}, 200}, {{'j', C}, 100}};
    CHECK(bindings(regular, 3, quick, 2, NULL));
    char *terminal = open_view("terminal", false);
    /* A binding claims a chord the program would get. */
    press('j', C);
    CHECK(binding(terminal) == 100);
    /* Shift that made the punctuation is no modifier; on a letter it is. */
    press('!', S | SHIFT);
    CHECK(went("held C-j, held s-S-!"));
    int64_t event, serial = handoff_key("binding", terminal, &event);
    CHECK(event == 101);
    CHECK(act(terminal, "ack", serial));
    press('!', S | SHIFT);
    CHECK(went("taken s-S-!"));
    CHECK(sent("literal %s %" PRId64 " 0\n", terminal, serial));
    CHECK(act(terminal, "finish", serial));
    CHECK(act(terminal, "focus", 0));
    press('J', S | SHIFT);
    CHECK(binding(terminal) == 102);
    press('J', C);
    CHECK(binding(terminal) == 100);
    CHECK(went("held s-S-J, held C-J"));
    /* Not the quick profile's: it falls through. */
    press('`', S);
    CHECK(act(terminal, "finish", key_record(terminal, '`', S)));
    close_view(terminal);

    char *quick_terminal = open_view("terminal", true);
    press('`', S);
    CHECK(binding(quick_terminal) == 200);
    press('j', C);
    CHECK(binding(quick_terminal) == 100);
    close_view(quick_terminal);
    /* Web views have none. */
    char *web = open_view("web", false);
    press('j', C);
    portal_fake_answer(true);
    CHECK(went("held s-`, held s-`, held C-j, offered C-j, used C-j"));
    close_view(web);
    CHECK(bindings(NULL, 0, NULL, 0, NULL));
}

static void test_configuration_changes_atomically(void)
{
    const portal_binding working[] = {{{'j', S}, 100}};
    CHECK(bindings(working, 1, working, 1, NULL));
    /* Invalid or conflicting bindings, in either profile, change nothing. */
    const portal_binding invalid[][1] = {
        {{{'a', 0}, 1}},          {{{'!', SHIFT}, 1}},  {{{0x7f, C}, 1}}, {{{0xe9, C}, 1}},
        {{{'a', C | 16}, 1}},     {{{'a', C}, 0}},      {{{'a', C}, -1}}, {{{0, C}, 1}},
    };
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        CHECK(bindings(invalid[i], 1, NULL, 0, "Invalid native terminal binding"));
        CHECK(bindings(working, 1, invalid[i], 1, "Invalid native terminal binding"));
    }
    const portal_binding duplicate[] = {{{'k', S}, 1}, {{'K', S}, 2}};
    CHECK(bindings(working, 1, duplicate, 2, "Conflicting native terminal binding"));
    char *terminal = open_view("terminal", false);
    press('j', S);
    CHECK(act(terminal, "finish", handoff("binding", terminal)));
    CHECK(act(terminal, "focus", 0));
    CHECK(went("held s-j"));
    CHECK(bindings(NULL, 0, NULL, 0, NULL));
    /* Without the binding, the chord falls through. */
    press('j', S);
    CHECK(act(terminal, "finish", key_record(terminal, 'j', S)));
    CHECK(went("held s-j"));
    close_view(terminal);
}

static void test_a_held_chord_takes_one_handoff(void)
{
    char *terminal = open_view("terminal", false);
    /* A chord's own repeats, before and after it starts a handoff. */
    repeat('x', S);
    CHECK(went("taken s-x repeat"));
    CHECK(sent(""));
    press('x', S);
    repeat('x', S);
    int64_t serial = key_record(terminal, 'x', S);
    CHECK(act(terminal, "ack", serial));
    portal_fake_run();
    CHECK(went("held s-x, held s-x repeat, taken s-x repeat"));
    CHECK(sent(""));
    CHECK(act(terminal, "finish", serial));
    close_view(terminal);
}

static void test_keys_after_a_whole_command_stay_with_emacs(void)
{
    char *terminal = open_view("terminal", false);
    /* Typed at once after a chord that is a whole command. */
    press('n', S);
    press('x', 0);
    CHECK(went("held s-n, held x"));
    int64_t serial = key_record(terminal, 'n', S);
    /* Emacs needs no key after the trigger: it runs the command without
       reading x, and takes it in before deciding to resume the view. */
    CHECK(act(terminal, "ack", serial));
    CHECK(act(terminal, "command", serial));
    CHECK(act(terminal, "finish", serial));
    portal_fake_run();
    CHECK(went("emacs x"));
    CHECK(!act(terminal, "focused", 0));
    CHECK(sent(""));
    close_view(terminal);
}

static void test_configurable_escape(void)
{
    portal_text error = {0};
    CHECK(portal_input_is_escape((portal_chord) {'.', S}));
    CHECK(!portal_input_is_escape((portal_chord) {27, S}));
    char *terminal = open_view("terminal", false);
    press('.', S);
    CHECK(!act(terminal, "focused", 0));
    CHECK(sent(""));
    CHECK(went(""));

    CHECK(portal_input_set_escape((portal_chord) {'G', C | S}, &error));
    CHECK(!portal_input_is_escape((portal_chord) {'.', S}));
    CHECK(portal_input_is_escape((portal_chord) {'g', C | S}));
    CHECK(!portal_input_is_escape((portal_chord) {'g', C | S | SHIFT}));
    const portal_chord bad[] = {{'g', 0}, {'g', SHIFT}, {0, S}, {'g', 128}, {27, 0}};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        CHECK(!portal_input_set_escape(bad[i], &error));
        free(error.data);
        error = (portal_text) {0};
        CHECK(portal_input_is_escape((portal_chord) {'g', C | S}));
    }
    CHECK(act(terminal, "focus", 0));
    press('.', S); /* The old escape is now an ordinary Emacs chord. */
    int64_t serial = key_record(terminal, '.', S);
    press('x', 0);
    press('g', C | S); /* Escape before Lisp acknowledges: drop held keys. */
    CHECK(sent("escape %s %" PRId64 " 0\n", terminal, serial));
    CHECK(!act(terminal, "pending", 0));
    CHECK(!act(terminal, "focused", 0));
    CHECK(went("held s-., held x"));
    close_view(terminal);

    CHECK(portal_input_set_escape((portal_chord) {27, C}, &error));
    CHECK(portal_input_is_escape((portal_chord) {27, C}));
    CHECK(portal_input_set_escape((portal_chord) {'!', S}, &error));
    CHECK(portal_input_is_escape((portal_chord) {'!', S | SHIFT}));
    CHECK(portal_input_set_escape((portal_chord) {'.', S}, &error));
    char *web = open_view("web", false);
    press('k', C); /* Escape must not wait for the app's answer either. */
    press('.', S);
    CHECK(!act(web, "focused", 0));
    CHECK(went("offered C-k"));
    CHECK(sent(""));
    close_view(web);
}

/* With double escape on, a plain Escape soon after another that the app got,
   with no press between, returns to Emacs; the app still gets the first. */
static void test_double_escape(void)
{
    portal_text error = {0};
    char *terminal = open_view("terminal", false);
    /* Off at first: every Escape is the program's, as vim needs. */
    press(27, 0);
    press(27, 0);
    CHECK(went("%s ESC, %s ESC", terminal, terminal));
    CHECK(!portal_input_set_double_escape(-1, &error));
    free(error.data);
    error = (portal_text) {0};
    CHECK(portal_input_set_double_escape(300, &error));
    portal_fake_wait(1000);

    press(27, 0);
    portal_fake_wait(300);
    press(27, 0);
    CHECK(went("%s ESC, taken ESC", terminal));
    CHECK(!act(terminal, "focused", 0));
    CHECK(sent("")); /* No handoff to end. */
    press(27, 0);
    CHECK(went("emacs ESC"));

    /* Too slow, another key between, or the keyboard moving between: the
       second is a first again. */
    CHECK(act(terminal, "focus", 0));
    press(27, 0);
    portal_fake_wait(301);
    press(27, 0);
    press('x', 0);
    press(27, 0);
    CHECK(act(terminal, "unfocus", 0));
    CHECK(act(terminal, "focus", 0));
    press(27, 0);
    CHECK(went("%s ESC, %s ESC, %s x, %s ESC, %s ESC", terminal, terminal, terminal, terminal,
               terminal));
    CHECK(act(terminal, "focused", 0));
    /* A held Escape's repeats are the program's, and no second tap. */
    repeat(27, 0);
    press(27, M);
    CHECK(went("%s ESC repeat, %s M-ESC", terminal, terminal));
    CHECK(act(terminal, "focused", 0));
    close_view(terminal);

    /* A page gets the first Escape too.  Presses held while the page
       answers keep the time they were typed. */
    char *web = open_view("web", false);
    press('k', C);
    press(27, 0);
    press(27, 0);
    portal_fake_wait(1000);
    portal_fake_answer(true);
    portal_fake_run();
    CHECK(went("offered C-k, held ESC, held ESC, used C-k, %s ESC, taken ESC", web));
    CHECK(!act(web, "focused", 0));
    CHECK(sent(""));
    close_view(web);
    CHECK(portal_input_set_double_escape(0, &error));
}

/* Each change of whether a view has the keyboard reaches Emacs as a focus
   record, whatever made it, for the view's mode line; nothing else does. */
static void test_focus_changes_reach_emacs(void)
{
    portal_option options[] = {{.name = text("directory"), .is_string = true, .string = text("/")}};
    portal_text target = {0}, error = {0};
    CHECK(portal_views_open(text("terminal"), options, 1, &target, &error));
    char *terminal = target.data;
    CHECK(portal_views_place(text(terminal), (portal_edges) {0, 0, 100, 100}, text("frame"),
                             &error));
    CHECK(sent_all(""));
    /* Emacs gives the view the keyboard, and takes it back; a report of no
       change sends nothing. */
    CHECK(act(terminal, "focus", 0));
    CHECK(act(terminal, "focus", 0));
    portal_input_focus(text(terminal), true);
    CHECK(sent_all("focus %s 1\n", terminal));
    CHECK(act(terminal, "unfocus", 0));
    CHECK(sent_all("focus %s 0\n", terminal));
    /* A handoff takes it from the view, after the handoff's own record,
       and Emacs gives it back once the command is done. */
    CHECK(act(terminal, "focus", 0));
    press('x', S);
    const char *got = received_all();
    char prefix[64], tail[64];
    snprintf(prefix, sizeof prefix, "focus %s 1\nkey %s ", terminal, terminal);
    snprintf(tail, sizeof tail, " 120 8\nfocus %s 0\n", terminal);
    int64_t serial = 0;
    CHECK(!strncmp(got, prefix, strlen(prefix)));
    CHECK(sscanf(got + strlen(prefix), "%" SCNd64, &serial) == 1 && serial > 0);
    CHECK(strlen(got) > strlen(tail) && !strcmp(got + strlen(got) - strlen(tail), tail));
    CHECK(act(terminal, "ack", serial));
    CHECK(act(terminal, "finish", serial));
    CHECK(sent_all(""));
    CHECK(act(terminal, "focus", 0));
    CHECK(sent_all("focus %s 1\n", terminal));
    /* The user's escape and click move it, before the click's own record. */
    portal_fake_escape();
    CHECK(sent_all("focus %s 0\n", terminal));
    CHECK(portal_fake_click(terminal));
    CHECK(sent_all("focus %s 1\nselect %s\n", terminal, terminal));
    /* Hiding the view returns the keyboard to Emacs. */
    CHECK(portal_views_hide(text(terminal), &error));
    CHECK(sent_all("focus %s 0\n", terminal));
    close_view(terminal);
    CHECK(went("held s-x"));
}

int main(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1 || !portal_channel_connect(fds[1]))
        abort();
    records = fds[0];
    test_a_terminal_chord_falls_through();
    test_a_page_is_offered_chords();
    test_shortcuts_before_emacs();
    test_the_keyboard_moving_during_an_offer();
    test_the_trigger_again_goes_to_the_app();
    test_cancelling_a_handoff();
    test_a_click_abandons_a_handoff_first();
    test_emacs_moving_the_keyboard_keeps_the_handoff();
    test_serials_name_one_handoff();
    test_hiding_or_closing_ends_a_handoff();
    test_native_bindings_by_profile();
    test_configuration_changes_atomically();
    test_a_held_chord_takes_one_handoff();
    test_keys_after_a_whole_command_stay_with_emacs();
    test_configurable_escape();
    test_double_escape();
    test_focus_changes_reach_emacs();
    CHECK(!portal_fake_calls().misused);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Input handoff passed");
    return 0;
}
