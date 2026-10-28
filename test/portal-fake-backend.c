/* SPDX-License-Identifier: GPL-3.0-or-later */
/* An in-memory backend for the module and core tests.  It implements the
   operations of native/Core/include/portal.h, so the real C core runs without
   AppKit, WebKit or Ghostty.  A view describes what its operations received:
   its options, the "handle" that tells views apart, the "frame" title,
   and "size" it was last attached with, and whether it is "attached".  Views never move:
   attaching records where.

   A view created with the option :description describes itself with exactly
   that text instead, for tests of how the core reads descriptions.

   A terminal describes the facts every platform's terminal reports, "ready",
   "title", "pwd", "program", "columns", "rows" and "exited", which is true
   once a test ends its process.  Its "text" is everything pasted into it, with a newline for
   each Enter, and its "theme" the last one applied, false for the default.
   The engine's themes are those in `themes' below, listed out of order.

   A web view's primitives are described below, at portal_web_load.

   Failures on demand: creating a view with the option :fail fails, with that
   option's string as the message; attaching to a frame whose title starts
   with "deleted" fails, as the frame is gone; every terminal primitive on a
   terminal created with the option :broken fails, with that option's string
   as the message, as does setting the appearance of such a web view; and while a test says so, every view and terminal
   primitive refuses to run, as on the wrong thread.  Timers fire only when a
   test fires them.  A destroyed view's memory is kept, marked destroyed, so a
   later call that names it is counted instead of reading freed memory
   (portal-fake-backend.h).

   Keys: all views share one window, where one attached view at a time can
   have the keyboard, and Emacs has it otherwise.  Tests press keys, click
   and press the configured escape as a user would, and the fake routes each press
   as the macOS platform does: holding what the core says to hold, and
   replaying it when a test runs the event loop.  It logs where each press
   went. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "portal-fake-backend.h"
#include "portal.h"

enum { MAX_PROPERTIES = 32, MAX_TIMERS = 64, MAX_VIEWS = 4096, MAX_KEYS = 64 };

/* A key press, as the platform keeps it. */
struct press {
    portal_chord chord;
    bool repeat;
    uint64_t time; /* On the fake clock, when the user pressed it. */
};

/* One property that portal--inspect reports. */
struct property {
    portal_text name;
    enum { FLAG, INTEGER, INTEGERS, REAL, STRING } kind;
    bool flag;
    int64_t integer;
    double real;
    int64_t *integers; /* COUNT of them. */
    size_t count;
    portal_text string;
};

struct portal_view {
    portal_kind kind;
    char *target; /* For records. */
    bool destroyed;
    struct property properties[MAX_PROPERTIES];
    size_t count;
    bool focused;          /* It has the keyboard. */
    bool triggered;        /* It holds TRIGGER. */
    struct press trigger;
    bool offering;         /* Its page has OFFERED, and has not answered. */
    struct press offered;
    bool holding;          /* It holds the presses in HELD, after TRIGGER or OFFERED. */
    struct press held[MAX_KEYS];
    size_t held_count;
};

static struct portal_fake_calls calls;
static bool refusing; /* See portal_fake_refuse. */
static uint64_t timers[MAX_TIMERS]; /* Tokens of the timers not yet fired, oldest first. */
static size_t timer_count;
static struct portal_view *all[MAX_VIEWS]; /* Every view created, destroyed or not. */
static size_t view_count;
static struct press posted[MAX_KEYS]; /* Replayed presses the event loop has not run. */
static size_t posted_count;
static uint64_t now; /* The fake clock, in milliseconds; see portal_fake_wait. */
static char key_log[4096];            /* Where presses went, since the last portal_fake_keys. */

static portal_text copy(const char *data, size_t length)
{
    char *bytes = malloc(length + 1);
    if (length)
        memcpy(bytes, data, length);
    bytes[length] = '\0';
    return (portal_text) {bytes, length};
}

static bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

static bool fail(portal_text *error, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    char message[256];
    int length = vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    *error = copy(message, length < (int) sizeof message ? (size_t) length : sizeof message - 1);
    return false;
}

static void clear(struct property *property)
{
    free(property->integers);
    free(property->string.data);
    property->integers = NULL;
    property->string = (portal_text) {0};
}

/* VIEW's property NAME, cleared for a new value. */
static struct property *property(struct portal_view *view, const char *name, size_t length)
{
    for (size_t i = 0; i < view->count; i++) {
        struct property *property = &view->properties[i];
        if (property->name.length == length && !memcmp(property->name.data, name, length)) {
            clear(property);
            return property;
        }
    }
    if (view->count == MAX_PROPERTIES)
        abort();
    struct property *property = &view->properties[view->count++];
    property->name = copy(name, length);
    return property;
}

static const struct property *get(const struct portal_view *view, const char *name)
{
    for (size_t i = 0; i < view->count; i++)
        if (view->properties[i].name.length == strlen(name)
            && !memcmp(view->properties[i].name.data, name, strlen(name)))
            return &view->properties[i];
    return NULL;
}

static void set_flag(struct portal_view *view, const char *name, bool flag)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = FLAG;
    entry->flag = flag;
}

static void set_integer(struct portal_view *view, const char *name, int64_t integer)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = INTEGER;
    entry->integer = integer;
}

static void set_string(struct portal_view *view, const char *name, const char *data, size_t length)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = STRING;
    entry->string = copy(data, length);
}

/* Append DATA to VIEW's string property NAME, after SEPARATOR if it is not empty. */
static void append(struct portal_view *view, const char *name, const char *separator, const char *data,
                   size_t length)
{
    const struct property *old = get(view, name);
    portal_text previous = old ? copy(old->string.data, old->string.length) : copy("", 0);
    size_t gap = previous.length ? strlen(separator) : 0;
    char *bytes = malloc(previous.length + gap + length + 1);
    memcpy(bytes, previous.data, previous.length);
    memcpy(bytes + previous.length, separator, gap);
    if (length)
        memcpy(bytes + previous.length + gap, data, length);
    set_string(view, name, bytes, previous.length + gap + length);
    free(bytes);
    free(previous.data);
}

/* A growing JSON text. */
struct json {
    char *data;
    size_t length;
};

static void put(struct json *json, const char *data, size_t length)
{
    json->data = realloc(json->data, json->length + length + 1);
    memcpy(json->data + json->length, data, length);
    json->length += length;
    json->data[json->length] = '\0';
}

static void put_format(struct json *json, const char *format, long long value)
{
    char number[32];
    put(json, number, (size_t) snprintf(number, sizeof number, format, value));
}

static void put_real(struct json *json, double value)
{
    char number[32];
    put(json, number, (size_t) snprintf(number, sizeof number, "%g", value));
}

static void put_string(struct json *json, portal_text text)
{
    put(json, "\"", 1);
    for (size_t i = 0; i < text.length; i++) {
        unsigned char c = (unsigned char) text.data[i];
        if (c == '"' || c == '\\')
            put(json, "\\", 1), put(json, (char *) &c, 1);
        else if (c < 0x20)
            put_format(json, "\\u%04llx", c);
        else
            put(json, (char *) &c, 1);
    }
    put(json, "\"", 1);
}

/* Whether a view or terminal primitive refuses to run, setting *ERROR. */
static bool refused(portal_text *error)
{
    return refusing && !fail(error, "The fake refuses to run view primitives");
}

void portal_fake_refuse(bool refuse)
{
    refusing = refuse;
}

/* Whether the core may use VIEW, of KIND unless KIND is -1: it must not
   have been destroyed.  Anything else is counted for the tests to find. */
static bool usable(struct portal_view *view, int kind, portal_text *error)
{
    if (view && !view->destroyed && (kind < 0 || (int) view->kind == kind))
        return true;
    calls.misused++;
    return fail(error, "The core passed a view it may not use");
}

static void set_integers(struct portal_view *view, const char *name, const int64_t *integers,
                         size_t count)
{
    struct property *entry = property(view, name, strlen(name));
    entry->kind = INTEGERS;
    entry->count = count;
    entry->integers = malloc((count ? count : 1) * sizeof *entry->integers);
    memcpy(entry->integers, integers, count * sizeof *entry->integers);
}

bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **result, portal_text *error)
{
    if (refused(error))
        return false;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "fail") && (options[i].is_string || options[i].flag))
            return options[i].is_string
                ? fail(error, "%.*s", (int) options[i].string.length, options[i].string.data)
                : fail(error, "The fake could not create the view");
    struct portal_view *view = calloc(1, sizeof *view);
    view->kind = kind;
    view->target = copy(target.data, target.length).data;
    set_integer(view, "handle", (int64_t) ++calls.created);
    if (view_count == MAX_VIEWS)
        abort();
    all[view_count++] = view;
    set_flag(view, "attached", false);
    if (kind == PORTAL_TERMINAL) {
        set_flag(view, "ready", true);
        set_string(view, "title", "Fake terminal", 13);
        set_string(view, "pwd", "", 0);
        set_string(view, "program", "", 0);
        set_integer(view, "columns", 80);
        set_integer(view, "rows", 24);
        set_flag(view, "exited", false);
    }
    for (size_t i = 0; i < count; i++) {
        struct property *entry = property(view, options[i].name.data, options[i].name.length);
        entry->kind = options[i].is_string ? STRING : FLAG;
        if (options[i].is_string)
            entry->string = copy(options[i].string.data, options[i].string.length);
        else
            entry->flag = options[i].flag;
    }
    *result = view;
    return true;
}

static void set_focus(struct portal_view *view);

bool portal_view_destroy(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.destroyed++;
    if (view->focused)
        set_focus(NULL);
    for (size_t i = 0; i < view->count; i++) {
        clear(&view->properties[i]);
        free(view->properties[i].name.data);
    }
    free(view->target);
    *view = (struct portal_view) {.destroyed = true};
    return true;
}

bool portal_view_attach(portal_view *view, portal_string frame, portal_rect rect,
                        portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.attached++;
    if (frame.length >= 7 && !memcmp(frame.data, "deleted", 7))
        return fail(error, "Cannot find the requested native Emacs frame");
    set_string(view, "frame", frame.data, frame.length);
    set_integers(view, "size", (int64_t[]) {rect.width, rect.height}, 2);
    set_flag(view, "attached", true);
    return true;
}

bool portal_view_detach(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.detached++;
    if (view->focused)
        set_focus(NULL);
    set_flag(view, "frame", false);
    set_flag(view, "attached", false);
    return true;
}

static void put_properties(struct json *json, const struct portal_view *view)
{
    for (size_t i = 0; i < view->count; i++) {
        const struct property *property = &view->properties[i];
        if (i)
            put(json, ",", 1);
        put_string(json, property->name);
        put(json, ":", 1);
        if (property->kind == FLAG)
            put(json, property->flag ? "true" : "false", property->flag ? 4 : 5);
        else if (property->kind == INTEGER)
            put_format(json, "%lld", property->integer);
        else if (property->kind == REAL)
            put_real(json, property->real);
        else if (property->kind == STRING)
            put_string(json, property->string);
        else
            for (size_t k = 0; k < property->count; k++)
                put_format(json, k ? ",%lld" : "[%lld", property->integers[k]);
        if (property->kind == INTEGERS)
            put(json, property->count ? "]" : "[]", property->count ? 1 : 2);
    }
}

bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.described++;
    const struct property *description = get(view, "description");
    if (description && description->kind == STRING) {
        *state = copy(description->string.data, description->string.length);
        return true;
    }
    struct json json = {0};
    put(&json, "{", 1);
    put_properties(&json, view);
    put(&json, "}", 1);
    *state = (portal_text) {json.data, json.length};
    return true;
}

struct portal_fake_calls portal_fake_calls(void)
{
    return calls;
}

void portal_timer_start(uint64_t token, uint64_t milliseconds)
{
    (void) milliseconds;
    if (timer_count == MAX_TIMERS)
        abort();
    timers[timer_count++] = token;
}

size_t portal_fake_timers(void)
{
    return timer_count;
}

void portal_fake_fire_timers(void)
{
    uint64_t fired[MAX_TIMERS];
    size_t count = timer_count;
    memcpy(fired, timers, count * sizeof *timers);
    timer_count = 0;
    for (size_t i = 0; i < count; i++)
        portal_timer_fired(fired[i]);
}

/* The fake's URL parser percent-encodes, in uppercase, each byte a URL may
   not hold raw, such as a space or non-ASCII, as a real parser would.  It
   changes nothing else: real parsers also spell hosts in punycode. */
bool portal_web_parse_url(portal_string url, portal_text *parsed, portal_text *error)
{
    if (refused(error))
        return false;
    static const char hex[] = "0123456789ABCDEF";
    char *data = malloc(3 * url.length + 1), *end = data;
    for (size_t i = 0; i < url.length; i++) {
        unsigned char c = (unsigned char) url.data[i];
        if (c > ' ' && c < 0x7f && !strchr("\"<>\\^`{|}", c)) {
            *end++ = (char) c;
        } else {
            *end++ = '%';
            *end++ = hex[c >> 4];
            *end++ = hex[c & 15];
        }
    }
    *end = '\0';
    *parsed = (portal_text) {data, (size_t) (end - data)};
    return true;
}

/* A web view records the "url" it loaded last, and the "history" steps it
   took, such as "reload".  Its page does nothing by itself: tests report
   what pages do by calling the core as the platform does. */
bool portal_web_load(portal_view *web, portal_string url, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    calls.loaded++;
    set_string(web, "url", url.data, url.length);
    return true;
}

bool portal_web_go(portal_view *web, portal_history step, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    calls.went++;
    const char *name = step == PORTAL_BACK ? "back" : step == PORTAL_FORWARD ? "forward" : "reload";
    append(web, "history", " ", name, strlen(name));
    return true;
}

/* The page receives each message: they collect, in order, in "posts", and
   the last token in "token".  A view created with the option :echo is an app
   that posts each message back at once, from its main frame at the URL it
   loaded last, with no type. */
bool portal_web_post(portal_view *web, portal_string json, uint64_t token, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    if (!json.length || json.data[0] != '{')
        return fail(error, "A bridge message must be a JSON object");
    calls.posted++;
    append(web, "posts", ",", json.data, json.length);
    set_integer(web, "token", (int64_t) token);
    const struct property *echo = get(web, "echo"), *url = get(web, "url");
    if (echo && (echo->kind == STRING || echo->flag)) {
        portal_sender sender = {true, url ? (portal_string) {url->string.data, url->string.length}
                                          : (portal_string) {"", 0}};
        portal_web_posted((portal_string) {web->target, strlen(web->target)}, sender,
                          (portal_string) {"", 0}, json);
    }
    return true;
}

static portal_string target_of(const struct portal_view *view);

/* A window is a web view created as portal_view_create creates one, which
   describes the "opener" whose page asked for it, the "request", a
   NUL-terminated string such as the URL the page asked for, and the
   opener's "appearance".  A request of "fail" fails. */
bool portal_web_create_window(portal_view *opener, portal_string target, void *request,
                              portal_view **view, portal_text *error)
{
    if (!usable(opener, PORTAL_WEB, error) || refused(error))
        return false;
    const char *asked = request;
    if (!strcmp(asked, "fail"))
        return fail(error, "The fake could not open the window");
    portal_option options[3] = {
        {.name = {"opener", 6}, .is_string = true, .string = target_of(opener)},
        {.name = {"request", 7}, .is_string = true, .string = {asked, strlen(asked)}},
    };
    size_t count = 2;
    const struct property *appearance = get(opener, "appearance");
    if (appearance)
        options[count++] = (portal_option) {
            .name = {"appearance", 10},
            .is_string = appearance->kind == STRING,
            .string = {appearance->string.data, appearance->string.length},
            .flag = appearance->kind == FLAG && appearance->flag,
        };
    return portal_view_create(PORTAL_WEB, target, options, count, view, error);
}

void portal_fake_exit(portal_view *terminal)
{
    set_flag(terminal, "exited", true);
    portal_terminal_changed((portal_string) {terminal->target, strlen(terminal->target)});
}

void portal_fake_report(portal_view *terminal, const char *title, const char *directory)
{
    set_string(terminal, "title", title, strlen(title));
    set_string(terminal, "pwd", directory, strlen(directory));
    portal_terminal_changed((portal_string) {terminal->target, strlen(terminal->target)});
}

/* The engine's themes, not in order.  One needs escaping in JSON. */
static const char *const themes[] = {"Ωmega", "Beta", "Back\\slash \"quoted\"", "Alpha"};

bool portal_terminal_list_themes(portal_text **names, size_t *count, portal_text *error)
{
    if (refused(error))
        return false;
    calls.listed++;
    *count = sizeof themes / sizeof *themes;
    *names = malloc(*count * sizeof **names);
    for (size_t i = 0; i < *count; i++)
        (*names)[i] = copy(themes[i], strlen(themes[i]));
    return true;
}

/* Whether a terminal primitive may run on TERMINAL, which must be open and
   not :broken. */
static bool working(struct portal_view *terminal, portal_text *error)
{
    if (!usable(terminal, PORTAL_TERMINAL, error) || refused(error))
        return false;
    const struct property *broken = get(terminal, "broken");
    return !broken || broken->kind != STRING
        || fail(error, "%.*s", (int) broken->string.length, broken->string.data);
}

bool portal_terminal_apply_theme(portal_view *terminal, const portal_string *name,
                                 portal_text *error)
{
    if (!working(terminal, error))
        return false;
    calls.themed++;
    if (name)
        set_string(terminal, "theme", name->data, name->length);
    else
        set_flag(terminal, "theme", false);
    return true;
}

bool portal_terminal_paste_text(portal_view *terminal, portal_string text, portal_text *error)
{
    if (!working(terminal, error))
        return false;
    append(terminal, "text", "", text.data, text.length);
    return true;
}

bool portal_terminal_press_enter(portal_view *terminal, portal_text *error)
{
    calls.entered++; /* Even if it fails. */
    if (!working(terminal, error))
        return false;
    append(terminal, "text", "", "\n", 1);
    return true;
}

bool portal_terminal_read_text(portal_view *terminal, portal_text *text, portal_text *error)
{
    if (!working(terminal, error))
        return false;
    const struct property *scrollback = get(terminal, "text");
    *text = scrollback ? copy(scrollback->string.data, scrollback->string.length) : copy("", 0);
    return true;
}

static bool attached(const struct portal_view *view);

/* A web view describes the "appearance" it was last set to, "light" or
   "dark", or false for the system's; before any, its :appearance option.  A
   web view created with :broken refuses one, with that option's string as
   the message. */
bool portal_web_set_appearance(portal_view *web, portal_appearance appearance,
                               portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    const struct property *broken = get(web, "broken");
    if (broken && broken->kind == STRING)
        return fail(error, "%.*s", (int) broken->string.length, broken->string.data);
    calls.appeared++;
    if (appearance == PORTAL_APPEARANCE_SYSTEM)
        set_flag(web, "appearance", false);
    else if (appearance == PORTAL_APPEARANCE_LIGHT)
        set_string(web, "appearance", "light", 5);
    else
        set_string(web, "appearance", "dark", 4);
    return true;
}

/* A page records each find in "finds", such as "apple forward case",
   and its token in "find"; tests report the result as a platform does. */
bool portal_web_find(portal_view *web, portal_string text, bool backward, bool case_sensitive,
                     uint64_t token, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    calls.found++;
    char find[256];
    snprintf(find, sizeof find, "%.*s %s %s", (int) text.length, text.data,
             backward ? "backward" : "forward", case_sensitive ? "case" : "nocase");
    append(web, "finds", ",", find, strlen(find)); /* Tests find short texts. */
    set_integer(web, "find", (int64_t) token);
    return true;
}

/* A web view describes its "zoom" in percent once the core has set one.  A
   web view created with :broken refuses, as for appearances. */
bool portal_web_set_zoom(portal_view *web, double factor, portal_text *error)
{
    if (!usable(web, PORTAL_WEB, error) || refused(error))
        return false;
    const struct property *broken = get(web, "broken");
    if (broken && broken->kind == STRING)
        return fail(error, "%.*s", (int) broken->string.length, broken->string.data);
    calls.zoomed++;
    set_integer(web, "zoom", (int64_t) (factor * 100 + 0.5));
    return true;
}

/* Input.  Reports of the focus changes the fake makes reach the core at
   once, as the contract in portal.h asks. */

static portal_string target_of(const struct portal_view *view)
{
    return (portal_string) {view->target, strlen(view->target)};
}

/* Give VIEW the keyboard, or Emacs for NULL, reporting each change. */
static void set_focus(struct portal_view *view)
{
    for (size_t i = 0; i < view_count; i++) {
        struct portal_view *other = all[i];
        if (other->destroyed || other->focused == (other == view))
            continue;
        other->focused = other == view;
        portal_input_focus(target_of(other), other->focused);
    }
}

static bool attached(const struct portal_view *view)
{
    const struct property *flag = get(view, "attached");
    return flag && flag->flag;
}

bool portal_view_focus(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.focused++;
    if (attached(view))
        set_focus(view);
    return true;
}

bool portal_view_unfocus(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.unfocused++;
    if (view->focused)
        set_focus(NULL);
    return true;
}

static void log_key(const char *where, struct press press)
{
    char name[32];
    size_t length = 0;
    const char *prefixes[] = {"C-", "M-", "s-", "S-"};
    const uint32_t bits[] = {PORTAL_CONTROL, PORTAL_META, PORTAL_SUPER, PORTAL_SHIFT};
    for (size_t i = 0; i < 4; i++)
        if (press.chord.modifiers & bits[i])
            length += (size_t) snprintf(name + length, sizeof name - length, "%s", prefixes[i]);
    if (press.chord.character == 27)
        snprintf(name + length, sizeof name - length, "ESC%s", press.repeat ? " repeat" : "");
    else
        snprintf(name + length, sizeof name - length, "%c%s", (char) press.chord.character,
                 press.repeat ? " repeat" : "");
    size_t used = strlen(key_log);
    snprintf(key_log + used, sizeof key_log - used, "%s%s %s", used ? ", " : "", where, name);
}

static void release(struct portal_view *view);

bool portal_view_replay(portal_view *view, bool replay, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    if (replay) {
        calls.replayed++;
        /* Ahead of presses posted before, as NSApp.postEvent(atStart:). */
        release(view);
    } else {
        calls.discarded++;
        view->triggered = false;
    }
    view->holding = false;
    view->held_count = 0;
    return true;
}

bool portal_view_copy(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.copied++;
    return true;
}

bool portal_view_paste(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    calls.pasted++;
    return true;
}

bool portal_view_literal(portal_view *view, portal_text *error)
{
    if (!usable(view, -1, error) || refused(error))
        return false;
    if (!view->triggered)
        return fail(error, "The fake holds no trigger to deliver");
    if (!view->focused)
        return fail(error, "The fake cannot deliver to a view without the keyboard");
    log_key("literal", view->trigger);
    return true;
}

/* The view whose window's keys are its own: the one holding a trigger, or
   offering a press to its page. */
static struct portal_view *capturing(void)
{
    for (size_t i = 0; i < view_count; i++)
        if (!all[i]->destroyed && (all[i]->triggered || all[i]->offering))
            return all[i];
    return NULL;
}

/* Deliver VIEW's held presses again, ahead of those posted before. */
static void release(struct portal_view *view)
{
    if (posted_count + view->held_count > MAX_KEYS)
        abort();
    memmove(posted + view->held_count, posted, posted_count * sizeof *posted);
    memcpy(posted, view->held, view->held_count * sizeof *posted);
    posted_count += view->held_count;
    view->holding = false;
    view->held_count = 0;
}

static struct portal_view *focused(void)
{
    for (size_t i = 0; i < view_count; i++)
        if (!all[i]->destroyed && all[i]->focused)
            return all[i];
    return NULL;
}

/* Route PRESS as the platform routes a key event, now or replayed. */
static void route(struct press press)
{
    portal_chord chord = press.chord;
    bool repeat = press.repeat;
    struct portal_view *view = capturing();
    if ((view || focused()) && portal_input_is_escape(chord)) {
        portal_fake_escape();
        return;
    }
    if (view && view->holding) {
        if (view->held_count == MAX_KEYS)
            abort();
        view->held[view->held_count++] = press;
        log_key("held", press);
        return;
    }
    if (!view)
        view = focused();
    if (!view) {
        log_key("emacs", press);
        return;
    }
    switch (portal_input_key(target_of(view), chord, repeat, press.time)) {
    case PORTAL_KEY_PASS:
        /* Where it would go without Portal: the keyboard may have moved. */
        view = focused();
        log_key(view ? view->target : "emacs", press);
        break;
    case PORTAL_KEY_TAKE:
        log_key("taken", press);
        break;
    case PORTAL_KEY_HOLD:
        if (view->triggered) {
            view->held[view->held_count++] = press;
        } else {
            view->triggered = view->holding = true;
            view->trigger = press;
        }
        log_key("held", press);
        break;
    case PORTAL_KEY_OFFER:
        view->offering = view->holding = true;
        view->offered = press;
        log_key("offered", press);
        break;
    }
}

void portal_fake_press(portal_chord chord, bool repeat)
{
    route((struct press) {chord, repeat, now});
}

void portal_fake_wait(uint64_t milliseconds)
{
    now += milliseconds;
}

void portal_fake_answer(bool used)
{
    struct portal_view *view = NULL;
    for (size_t i = 0; i < view_count && !view; i++)
        if (!all[i]->destroyed && all[i]->offering)
            view = all[i];
    if (!view)
        abort();
    view->offering = false;
    if (used) {
        log_key("used", view->offered);
        release(view);
        return;
    }
    switch (portal_input_unused(target_of(view), view->offered.chord, view->offered.repeat)) {
    case PORTAL_KEY_HOLD:
        log_key("unused held", view->offered);
        view->triggered = true;
        view->trigger = view->offered;
        break;
    case PORTAL_KEY_TAKE:
        log_key("unused taken", view->offered);
        release(view);
        break;
    default:
        abort(); /* The core answers an unused press TAKE or HOLD only. */
    }
}

void portal_fake_run(void)
{
    while (posted_count) {
        struct press press = posted[0];
        memmove(posted, posted + 1, --posted_count * sizeof *posted);
        route(press);
    }
}

void portal_fake_escape(void)
{
    struct portal_view *view = capturing();
    if (!view)
        view = focused();
    if (!view)
        return;
    if (view->focused)
        set_focus(NULL);
    portal_input_focus(target_of(view), false);
}

bool portal_fake_click(const char *target)
{
    for (size_t i = 0; i < view_count; i++) {
        struct portal_view *view = all[i];
        if (view->destroyed || strcmp(view->target, target) || !attached(view))
            continue;
        if (!view->focused) {
            portal_input_focus(target_of(view), true);
            portal_notify((portal_string) {"select", 6}, target_of(view), NULL, 0);
        }
        set_focus(view);
        return true;
    }
    return false;
}

const char *portal_fake_keys(void)
{
    static char keys[sizeof key_log];
    memcpy(keys, key_log, sizeof keys);
    key_log[0] = '\0';
    return keys;
}

/* Launcher bindings are tested independently of the view registry. This fake
   records what crossed the C boundary; real NS ownership is checked in GUI. */
static portal_text launcher_title;
static int64_t launcher_values[6];
static bool launcher_visible, launcher_shadow;
static unsigned launcher_calls;
static uint64_t launcher_session;

bool portal_launcher_attach(portal_string title, portal_text *error)
{
    launcher_calls++;
    if (launcher_title.data)
        return fail(error, "Portal launcher is already attached");
    if (is(title, "missing"))
        return fail(error, "Cannot find launcher frame");
    launcher_title = copy(title.data, title.length);
    return true;
}

bool portal_launcher_show(int64_t width, int64_t height, int64_t dx, int64_t dy,
                          int64_t screen, bool shadow, int64_t radius, portal_text *error)
{
    launcher_calls++;
    if (!launcher_title.data)
        return fail(error, "Portal launcher is not attached");
    int64_t values[] = {width, height, dx, dy, screen, radius};
    memcpy(launcher_values, values, sizeof values);
    launcher_shadow = shadow;
    launcher_visible = true;
    launcher_session++;
    return true;
}

/* As on the platform, only the visible panel's current session changes. */
bool portal_launcher_fit(uint64_t session, int64_t height, portal_text *error)
{
    (void) error;
    launcher_calls++;
    if (launcher_visible && session == launcher_session)
        launcher_values[1] = height;
    return true;
}

bool portal_launcher_hide(bool restore_focus, portal_text *error)
{
    (void) restore_focus;
    (void) error;
    launcher_calls++;
    launcher_visible = false;
    launcher_session++;
    return true;
}

bool portal_launcher_prepare(portal_text *error)
{
    (void) error;
    return true;
}

bool portal_launcher_detach(portal_text *error)
{
    (void) error;
    launcher_calls++;
    free(launcher_title.data);
    launcher_title = (portal_text) {0};
    launcher_visible = false;
    launcher_session++;
    return true;
}

bool portal_launcher_describe(portal_text *state, portal_text *error)
{
    (void) error;
    struct json json = {0};
    const char *prefix = "{\"title\":";
    put(&json, prefix, strlen(prefix));
    put_string(&json, launcher_title);
    put_format(&json, ",\"calls\":%lld", launcher_calls);
    put_format(&json, ",\"session\":%lld", launcher_session);
    put_format(&json, ",\"attached\":%lld", launcher_title.data != NULL);
    put_format(&json, ",\"visible\":%lld", launcher_visible);
    put_format(&json, ",\"shadow\":%lld", launcher_shadow);
    const char *keys[] = {"width", "height", "dx", "dy", "screen", "radius"};
    for (size_t i = 0; i < 6; i++) {
        put(&json, ",", 1);
        put_string(&json, (portal_text) {(char *) keys[i], strlen(keys[i])});
        put_format(&json, ":%lld", launcher_values[i]);
    }
    put(&json, "}", 1);
    *state = (portal_text) {json.data, json.length};
    return true;
}

/* System-wide hot keys.  The fake registers any chord but F19, which it
   says another application has, and, like macOS, refuses a chord it already
   has under another hot key; the core must never ask for that.  Registering
   a hot key again with its own chord restarts it, which it counts.  It
   cannot release F18, to test what the core does when a release fails.  Real
   registration uses Carbon in the standalone checks. */
enum { MAX_HOTKEYS = 64 };
static struct hotkey {
    uint64_t hotkey;
    uint32_t key, modifiers;
} hotkeys[MAX_HOTKEYS];
static size_t hotkey_count, hotkey_restarts;

bool portal_hotkey_register(uint64_t hotkey, uint32_t key, uint32_t modifiers,
                            portal_text *error)
{
    if (refused(error))
        return false;
    if (key == PORTAL_FUNCTION_KEY + 19)
        return fail(error, "Another application has this chord");
    for (size_t i = 0; i < hotkey_count; i++) {
        bool chord = hotkeys[i].key == key && hotkeys[i].modifiers == modifiers;
        if (hotkeys[i].hotkey == hotkey && chord) {
            hotkey_restarts++;
            return true;
        }
        if (hotkeys[i].hotkey == hotkey || chord)
            return fail(error, "The fake already has this hot key or chord");
    }
    if (!hotkey || hotkey_count == MAX_HOTKEYS)
        return fail(error, "The fake cannot register hot key %llu", (unsigned long long) hotkey);
    hotkeys[hotkey_count++] = (struct hotkey) {hotkey, key, modifiers};
    return true;
}

bool portal_hotkey_unregister(uint64_t hotkey, portal_text *error)
{
    if (refused(error))
        return false;
    for (size_t i = 0; i < hotkey_count; i++) {
        if (hotkeys[i].hotkey == hotkey) {
            if (hotkeys[i].key == PORTAL_FUNCTION_KEY + 18)
                return fail(error, "The fake cannot release F18");
            memmove(&hotkeys[i], &hotkeys[i + 1], (--hotkey_count - i) * sizeof *hotkeys);
            return true;
        }
    }
    return true;
}

size_t portal_fake_hotkey_restarts(void)
{
    return hotkey_restarts;
}

/* KEY, as the hot key and key post primitives take it, in NAME. */
static void key_name(uint32_t key, char name[8])
{
    if (key > PORTAL_FUNCTION_KEY)
        snprintf(name, 8, "F%u", (unsigned) (key - PORTAL_FUNCTION_KEY));
    else
        snprintf(name, 8, "%s",
                 key == ' '                 ? "Space"
                 : key == PORTAL_ESCAPE_KEY ? "Escape"
                                            : (char[]) {(char) key, 0});
}

const char *portal_fake_hotkeys(void)
{
    static char text[MAX_HOTKEYS * 24];
    size_t length = 0;
    text[0] = '\0';
    for (size_t i = 0; i < hotkey_count; i++) {
        char name[8];
        key_name(hotkeys[i].key, name);
        length += (size_t) snprintf(text + length, sizeof text - length, "%s%llu:%s+%u",
                                    i ? " " : "", (unsigned long long) hotkeys[i].hotkey, name,
                                    (unsigned) hotkeys[i].modifiers);
    }
    return text;
}

/* Posted keys.  The fake posts any chord but one with F19, which it says
   it has no permission to post, naming the key and modifiers it was asked
   for, and logs the rest for portal_fake_posted.  Real posting is manual
   (docs/testing.md). */
static char chords[1024];
static size_t chords_length;

bool portal_key_post(uint32_t key, uint32_t modifiers, portal_text *error)
{
    if (refused(error))
        return false;
    char name[8];
    key_name(key, name);
    if (key == PORTAL_FUNCTION_KEY + 19)
        return fail(error, "The fake may not post %s+%u", name, (unsigned) modifiers);
    chords_length += (size_t) snprintf(chords + chords_length, sizeof chords - chords_length,
                                       "%s%s+%u", chords_length ? " " : "", name,
                                       (unsigned) modifiers);
    return true;
}

const char *portal_fake_posted(void)
{
    static char text[sizeof chords];
    memcpy(text, chords, sizeof text);
    chords[0] = '\0';
    chords_length = 0;
    return text;
}

/* Screens and the status panel.  The fake has the screens a test gives it,
   by default one usable area of 1440 by 875 points under a menu bar, with
   the pointer.  Its panel is 16 points of padding on each side of 8-point
   characters on 16-point lines, with 14 points between the lines and the
   top and bottom, and a 20-point mark for every tone but neutral.  It shows
   any text but one starting with "Refuse", which it says it may not show,
   quoting the text it was given.  Real panels are checked by
   test/native-status.swift. */
static portal_screen screens[4] = {{{0, 25, 1440, 875}, true}};
static size_t screen_count = 1;
static struct portal_fake_status status;

void portal_fake_screens(const portal_screen *given, size_t count)
{
    screen_count = count < 4 ? count : 4;
    memcpy(screens, given, screen_count * sizeof *screens);
}

bool portal_screens(portal_screen **result, size_t *count, portal_text *error)
{
    if (refused(error))
        return false;
    *result = malloc((screen_count ? screen_count : 1) * sizeof **result);
    if (!*result)
        return fail(error, "The fake is out of memory");
    memcpy(*result, screens, screen_count * sizeof **result);
    *count = screen_count;
    return true;
}

bool portal_status_measure(portal_string text, portal_status_tone tone, int64_t width,
                           int64_t lines, int64_t *fitted_width, int64_t *height,
                           portal_text *error)
{
    if (refused(error))
        return false;
    int64_t chrome = 32 + (tone == PORTAL_STATUS_NEUTRAL ? 0 : 20);
    int64_t per_line = (width - chrome) / 8 > 0 ? (width - chrome) / 8 : 1;
    int64_t length = (int64_t) text.length, needed = (length + per_line - 1) / per_line;
    *fitted_width = needed > 1 ? width : length * 8 + chrome;
    *height = (needed < lines ? needed : lines) * 16 + 14;
    status.measured++;
    return true;
}

bool portal_status_show(portal_string text, portal_status_tone tone, portal_rect rect,
                        int64_t lines, portal_text *error)
{
    if (refused(error))
        return false;
    if (strncmp(text.data, "Refuse", 6) == 0)
        return fail(error, "The fake may not show \"%s\"", text.data);
    status.shown = true;
    snprintf(status.text, sizeof status.text, "%s", text.data);
    status.tone = tone;
    status.rect = rect;
    status.lines = lines;
    return true;
}

bool portal_status_hide(portal_text *error)
{
    if (refused(error))
        return false;
    status.shown = false;
    return true;
}

struct portal_fake_status portal_fake_status(void)
{
    return status;
}
