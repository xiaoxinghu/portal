/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Helpers for the C programs that test the core's views with the fake
   platform: checks, and opening, inspecting and closing views as emacs.c
   does.  Each program includes this once. */
#ifndef PORTAL_CORE_TESTS_H
#define PORTAL_CORE_TESTS_H

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "portal-fake-backend.h"
#include "portal.h"
#include "views.h"

static int failures;
/* How many checks ran: each program ends by printing it. */
static int checks;

#define CHECK(condition) check((condition), #condition, __FILE__, __LINE__)

static inline void check(bool passed, const char *condition, const char *file, int line)
{
    checks++;
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", file, line, condition);
        failures++;
    }
}

static inline portal_string text(const char *literal)
{
    return (portal_string) {literal, strlen(literal)};
}

/* Whether ERROR says MESSAGE, which may hold LENGTH bytes including NULs;
   free it. */
static inline bool said(portal_text *error, const char *message, size_t length)
{
    bool same = error->data && error->length == length && !memcmp(error->data, message, length);
    if (!same)
        fprintf(stderr, "Expected error \"%.*s\", got \"%s\"\n", (int) length, message,
                error->data ? error->data : "(none)");
    free(error->data);
    *error = (portal_text) {0};
    return same;
}

static inline bool says(portal_text *error, const char *message)
{
    return said(error, message, strlen(message));
}

/* Open a view of KIND with the string options NAME, VALUE, ...; return its
   target to free, or NULL with *ERROR set. */
static inline char *open_view(const char *kind, portal_text *error, ...)
{
    portal_option options[4];
    size_t count = 0;
    va_list arguments;
    va_start(arguments, error);
    for (const char *name; (name = va_arg(arguments, const char *));) {
        const char *value = va_arg(arguments, const char *);
        options[count++] = (portal_option) {.name = text(name), .is_string = true,
                                            .string = text(value)};
    }
    va_end(arguments);
    portal_text target = {0};
    if (!portal_views_open(text(kind), options, count, &target, error))
        return NULL;
    return target.data;
}

/* TARGET's state as JSON, to free. */
static inline char *inspect(const char *target)
{
    portal_text state = {0}, error = {0};
    if (!portal_views_inspect(text(target), &state, &error)) {
        fprintf(stderr, "Inspecting %s failed: %s\n", target, error.data);
        free(error.data);
        return NULL;
    }
    return state.data;
}

/* Whether TARGET's state contains each of the NULL-terminated fragments. */
static inline bool shows(const char *target, ...)
{
    char *state = inspect(target);
    bool all = state != NULL;
    va_list arguments;
    va_start(arguments, target);
    for (const char *fragment; all && (fragment = va_arg(arguments, const char *));)
        if (!strstr(state, fragment)) {
            fprintf(stderr, "Expected %s in %s\n", fragment, state);
            all = false;
        }
    va_end(arguments);
    free(state);
    return all;
}

static inline bool same_calls(struct portal_fake_calls a, struct portal_fake_calls b)
{
    return !memcmp(&a, &b, sizeof a);
}

static inline void close_view(char *target)
{
    portal_text error = {0};
    CHECK(portal_views_close(text(target), &error));
    free(target);
}

#endif
