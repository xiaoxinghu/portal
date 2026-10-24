/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Portal's Emacs module: registers the Lisp interface of docs/adr/0002,
   converts arguments and results, and signals errors.  Each Lisp function
   copies its arguments, calls the core, and converts and frees what it
   returns.  The lifecycle functions call views.h, portal--channel
   channel.h, the input functions input.h, the terminal functions
   terminals.h, the web functions web.h, the shortcut functions shortcuts.h, and the status panel's status.h.  No Emacs environment or value
   outlives the module call that received it. */
#include <emacs-module.h>
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "portal.h"
#include "shortcuts.h"
#include "status.h"
#include "terminals.h"
#include "views.h"
#include "web.h"

int plugin_is_GPL_compatible;

/* A Lisp function.  Emacs checks the arity. */
#define UNUSED __attribute__((unused))
#define LISP_FUNCTION(name)                                                               \
    static emacs_value name(emacs_env *env, UNUSED ptrdiff_t nargs, UNUSED emacs_value *args, \
                            UNUSED void *data)

static bool returning(emacs_env *env)
{
    return env->non_local_exit_check(env) == emacs_funcall_exit_return;
}

static emacs_value symbol(emacs_env *env, const char *name)
{
    return env->intern(env, name);
}

static emacs_value list(emacs_env *env, emacs_value *items, size_t count)
{
    return env->funcall(env, symbol(env, "list"), (ptrdiff_t) count, items);
}

/* Signal `error' with (format FORMAT ARGUMENT), or FORMAT if ARGUMENT is null.
   An earlier pending signal or throw is kept. */
static void signal_error(emacs_env *env, const char *format, emacs_value argument)
{
    emacs_value arguments[] = {env->make_string(env, format, (ptrdiff_t) strlen(format)),
                               argument};
    if (returning(env))
        env->funcall(env, symbol(env, "error"), argument ? 2 : 1, arguments);
}

static void out_of_memory(emacs_env *env)
{
    signal_error(env, "Portal is out of memory", NULL);
}

static portal_string borrow(portal_text text)
{
    return (portal_string) {text.data, text.length};
}

/* Whether BYTES is well-formed UTF-8.  Emacs copies a unibyte string's raw
   bytes, and a surrogate character's bytes, without checking them. */
static bool valid_utf8(const unsigned char *bytes, size_t length)
{
    for (size_t i = 0; i < length;) {
        size_t extra;
        uint32_t code, minimum;
        if (bytes[i] < 0x80) {
            i++;
            continue;
        } else if ((bytes[i] & 0xe0) == 0xc0) {
            extra = 1, code = bytes[i] & 0x1f, minimum = 0x80;
        } else if ((bytes[i] & 0xf0) == 0xe0) {
            extra = 2, code = bytes[i] & 0x0f, minimum = 0x800;
        } else if ((bytes[i] & 0xf8) == 0xf0) {
            extra = 3, code = bytes[i] & 0x07, minimum = 0x10000;
        } else {
            return false;
        }
        if (length - i <= extra)
            return false;
        for (size_t k = 1; k <= extra; k++) {
            if ((bytes[i + k] & 0xc0) != 0x80)
                return false;
            code = code << 6 | (bytes[i + k] & 0x3f);
        }
        if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))
            return false;
        i += extra + 1;
    }
    return true;
}

/* Copy the Lisp string VALUE into *TEXT, which the caller frees. */
static bool read_text(emacs_env *env, emacs_value value, portal_text *text)
{
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, value, NULL, &size))
        return false;
    char *bytes = malloc((size_t) size);
    if (!bytes) {
        out_of_memory(env);
        return false;
    }
    if (!env->copy_string_contents(env, value, bytes, &size)) {
        free(bytes);
        return false;
    }
    if (!valid_utf8((const unsigned char *) bytes, (size_t) size - 1)) {
        free(bytes);
        emacs_value data[] = {symbol(env, "unicode-string-p"), value};
        env->non_local_exit_signal(env, symbol(env, "wrong-type-argument"), list(env, data, 2));
        return false;
    }
    *text = (portal_text) {bytes, (size_t) size - 1};
    return true;
}

/* Copy the vector [LEFT TOP RIGHT BOTTOM] of integers into *EDGES. */
static bool read_edges(emacs_env *env, emacs_value vector, portal_edges *edges)
{
    ptrdiff_t size = env->vec_size(env, vector);
    if (!returning(env))
        return false;
    if (size != 4) {
        signal_error(env, "Expected [LEFT TOP RIGHT BOTTOM]", NULL);
        return false;
    }
    int64_t values[4];
    for (ptrdiff_t i = 0; i < 4; i++) {
        values[i] = env->extract_integer(env, env->vec_get(env, vector, i));
        if (!returning(env))
            return false;
    }
    *edges = (portal_edges) {values[0], values[1], values[2], values[3]};
    return true;
}

/* Copies of portal--open's options: a name and a string value for each. */
struct options {
    portal_option *items;
    portal_text *texts;
    size_t count;
};

static void free_options(struct options *options)
{
    for (size_t i = 0; options->texts && i < 2 * options->count; i++)
        free(options->texts[i].data);
    free(options->texts);
    free(options->items);
}

/* Read a plist of keywords to strings, t or nil, such as (:directory "~/" :quick t). */
static bool read_options(emacs_env *env, emacs_value plist, struct options *options)
{
    emacs_value length = env->funcall(env, symbol(env, "proper-list-p"), 1, &plist);
    if (!returning(env))
        return false;
    intmax_t size = env->is_not_nil(env, length) ? env->extract_integer(env, length) : -1;
    if (size < 0 || size % 2 != 0) {
        signal_error(env, "Options must be a plist", NULL);
        return false;
    }
    emacs_value vector = env->funcall(env, symbol(env, "vconcat"), 1, &plist);
    if (!returning(env))
        return false;
    options->count = (size_t) size / 2;
    options->items = calloc(options->count + 1, sizeof *options->items);
    options->texts = calloc(2 * options->count + 1, sizeof *options->texts);
    if (!options->items || !options->texts) {
        out_of_memory(env);
        return false;
    }
    for (size_t i = 0; i < options->count; i++) {
        emacs_value key = env->vec_get(env, vector, (ptrdiff_t) (2 * i));
        emacs_value value = env->vec_get(env, vector, (ptrdiff_t) (2 * i + 1));
        emacs_value keyword = env->funcall(env, symbol(env, "keywordp"), 1, &key);
        if (!returning(env))
            return false;
        if (!env->is_not_nil(env, keyword)) {
            signal_error(env, "Option names must be keywords", NULL);
            return false;
        }
        portal_option *option = &options->items[i];
        portal_text *name = &options->texts[2 * i], *string = name + 1;
        if (!read_text(env, env->funcall(env, symbol(env, "symbol-name"), 1, &key), name))
            return false;
        option->name = (portal_string) {name->data + 1, name->length - 1};
        if (!env->is_not_nil(env, value)) {
            option->flag = false;
        } else if (env->eq(env, value, symbol(env, "t"))) {
            option->flag = true;
        } else if (env->eq(env, env->type_of(env, value), symbol(env, "string"))) {
            if (!read_text(env, value, string))
                return false;
            option->is_string = true;
            option->string = borrow(*string);
        } else {
            signal_error(env, "Option %s must be a string, t or nil", key);
            return false;
        }
    }
    return true;
}

static emacs_value boolean(emacs_env *env, bool value)
{
    return symbol(env, value ? "t" : "nil");
}

/* Convert TEXT to a Lisp string and free it. */
static emacs_value take_string(emacs_env *env, portal_text *text)
{
    emacs_value value =
        env->make_string(env, text->data ? text->data : "", (ptrdiff_t) text->length);
    free(text->data);
    *text = (portal_text) {0};
    return value;
}

/* Parse the JSON TEXT, with objects as plists, arrays as lists, and null and
   false as nil; free it. */
static emacs_value take_json(emacs_env *env, portal_text *text)
{
    emacs_value nil = symbol(env, "nil");
    emacs_value arguments[] = {take_string(env, text),
                               symbol(env, ":object-type"), symbol(env, "plist"),
                               symbol(env, ":array-type"), symbol(env, "list"),
                               symbol(env, ":null-object"), nil,
                               symbol(env, ":false-object"), nil};
    return env->funcall(env, symbol(env, "json-parse-string"),
                        sizeof arguments / sizeof *arguments, arguments);
}

/* Signal a backend's ERROR and free it. */
static void fail(emacs_env *env, portal_text *error)
{
    if (error->data)
        signal_error(env, "%s", take_string(env, error));
    else
        signal_error(env, "Portal native call failed", NULL);
}

/* Return t if the operation SUCCEEDED; otherwise signal ERROR. */
static emacs_value done(emacs_env *env, bool succeeded, portal_text *error)
{
    if (succeeded)
        return symbol(env, "t");
    fail(env, error);
    return NULL;
}

/* A Lisp function whose arguments, at most two, are all strings.  OPERATION
   receives their copies, and RESULT says what reaches Lisp. */
struct strings_function {
    bool (*operation)(const portal_string *arguments, portal_text *result, portal_text *error);
    enum { RESULT_T, RESULT_STRING, RESULT_JSON } result;
};

LISP_FUNCTION(Fstrings)
{
    const struct strings_function *function = data;
    portal_text copies[2] = {{0}}, result = {0}, error = {0};
    portal_string arguments[2];
    emacs_value value = NULL;
    ptrdiff_t count = 0;
    while (count < nargs && read_text(env, args[count], &copies[count])) {
        arguments[count] = borrow(copies[count]);
        count++;
    }
    if (count == nargs) {
        if (!function->operation(arguments, &result, &error))
            fail(env, &error);
        else if (function->result == RESULT_T)
            value = symbol(env, "t");
        else if (function->result == RESULT_STRING)
            value = take_string(env, &result);
        else
            value = take_json(env, &result);
    }
    while (count > 0)
        free(copies[--count].data);
    return value;
}

/* How each strings function calls the core, with arguments A. */
#define STRINGS(name, call)                                                        \
    static bool name(UNUSED const portal_string *a, UNUSED portal_text *result, \
                     portal_text *error)                                          \
    {                                                                             \
        return call;                                                              \
    }
STRINGS(hide, portal_views_hide(a[0], error))
STRINGS(close_view, portal_views_close(a[0], error))
STRINGS(inspect, portal_views_inspect(a[0], result, error))
STRINGS(web_load, portal_web_views_load(a[0], a[1], error))
STRINGS(web_send, portal_web_views_send(a[0], a[1], error))
STRINGS(web_receive, portal_web_views_receive(a[0], result, error))
STRINGS(web_go, portal_web_views_go(a[0], a[1], error))
STRINGS(web_download_directory, portal_web_views_download_directory(a[0], error))
STRINGS(terminal_themes, portal_terminals_themes(result, error))
STRINGS(terminal_text, portal_terminals_text(a[0], result, error))
STRINGS(launcher_detach, portal_launcher_detach(error))
STRINGS(launcher_prepare, portal_launcher_prepare(error))
STRINGS(launcher_describe, portal_launcher_describe(result, error))
STRINGS(shortcut_chord, portal_shortcuts_chord(a[0], result, error))
STRINGS(shortcuts_describe, portal_shortcuts_describe(result, error))
STRINGS(key_post, portal_shortcuts_post(a[0], error))
STRINGS(status_hide, portal_status_dismiss(error))

LISP_FUNCTION(Flauncher_hide)
{
    portal_text error = {0};
    return done(env, portal_launcher_hide(nargs > 0 && env->is_not_nil(env, args[0]), &error), &error);
}

/* Gate attachment even when the private binding is called directly. The
   platform additionally checks the NS window/view classes before moving them. */
LISP_FUNCTION(Flauncher_attach)
{
    const char *names[] = {"emacs-version", "emacs-repository-version"};
    const char *supported[] = {"31.1", "a360712c9d272d950d8d8255ef74570f7e90b7d9"};
    for (size_t i = 0; i < 2; i++) {
        emacs_value name = symbol(env, names[i]);
        emacs_value actual = env->funcall(env, symbol(env, "symbol-value"), 1, &name);
        emacs_value expected = env->make_string(env, supported[i], (ptrdiff_t) strlen(supported[i]));
        emacs_value pair[] = {actual, expected};
        emacs_value equal = env->funcall(env, symbol(env, "equal"), 2, pair);
        if (!returning(env))
            return NULL;
        if (!env->is_not_nil(env, equal)) {
            signal_error(env, "Portal launcher requires GNU Emacs NS 31.1 revision "
                         "a360712c9d272d950d8d8255ef74570f7e90b7d9", NULL);
            return NULL;
        }
    }
    portal_text title = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &title))
        result = done(env, portal_launcher_attach(borrow(title), &error), &error);
    free(title.data);
    return result;
}

/* Copy the shortcut ID VALUE, a natural number or nil for none, into *ID. */
static bool read_id(emacs_env *env, emacs_value value, uint64_t *id)
{
    intmax_t number = env->is_not_nil(env, value) ? env->extract_integer(env, value) : 0;
    if (!returning(env))
        return false;
    if (number < 0) {
        signal_error(env, "A shortcut ID is a natural number, not %S", value);
        return false;
    }
    *id = (uint64_t) number;
    return true;
}

LISP_FUNCTION(Fshortcut_set)
{
    portal_text chord = {0}, error = {0};
    uint64_t replacing, id;
    emacs_value result = NULL;
    if (read_id(env, args[0], &replacing) && read_text(env, args[1], &chord)) {
        if (portal_shortcuts_set(replacing, borrow(chord), &id, &error))
            result = env->make_integer(env, (intmax_t) id);
        else
            fail(env, &error);
    }
    free(chord.data);
    return result;
}

LISP_FUNCTION(Fshortcut_remove)
{
    uint64_t id;
    portal_text error = {0};
    return read_id(env, args[0], &id) ? done(env, portal_shortcuts_remove(id, &error), &error)
                                      : NULL;
}

LISP_FUNCTION(Flauncher_show)
{
    int64_t values[6];
    for (size_t i = 0; i < 6; i++) {
        values[i] = env->extract_integer(env, args[i == 5 ? 6 : i]);
        if (!returning(env))
            return NULL;
    }
    if (values[0] < 200 || values[1] < 1 || values[4] < -1 || values[5] < 0) {
        signal_error(env, "Launcher needs width >= 200, height >= 1, screen >= -1 and radius >= 0",
                     NULL);
        return NULL;
    }
    portal_text error = {0};
    return done(env, portal_launcher_show(values[0], values[1], values[2], values[3],
                                          values[4], env->is_not_nil(env, args[5]), values[5],
                                          &error), &error);
}

/* TEXT TONE POSITION, strings, then the layout's integers in the order of
   portal_status_layout. */
LISP_FUNCTION(Fstatus_show)
{
    int64_t values[8];
    for (size_t i = 0; i < 8; i++) {
        values[i] = env->extract_integer(env, args[3 + i]);
        if (!returning(env))
            return NULL;
    }
    portal_text text = {0}, tone = {0}, position = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &text) && read_text(env, args[1], &tone)
        && read_text(env, args[2], &position)) {
        portal_status_layout layout = {
            .position = borrow(position),
            .screen = values[0],
            .dx = values[1],
            .dy = values[2],
            .width = values[3],
            .height = values[4],
            .min_width = values[5],
            .max_width = values[6],
            .lines = values[7],
        };
        result = done(env, portal_status_present(borrow(text), borrow(tone), &layout, &error),
                      &error);
    }
    free(text.data);
    free(tone.data);
    free(position.data);
    return result;
}

LISP_FUNCTION(Flauncher_fit)
{
    intmax_t values[2];
    for (size_t i = 0; i < 2; i++) {
        values[i] = env->extract_integer(env, args[i]);
        if (!returning(env))
            return NULL;
    }
    if (values[0] < 0 || values[1] < 1) {
        signal_error(env, "Launcher fit needs a session >= 0 and height >= 1", NULL);
        return NULL;
    }
    portal_text error = {0};
    return done(env, portal_launcher_fit((uint64_t) values[0], (int64_t) values[1], &error),
                &error);
}

LISP_FUNCTION(Fopen)
{
    portal_text kind = {0}, target = {0}, error = {0};
    struct options options = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &kind) && read_options(env, args[1], &options)) {
        if (portal_views_open(borrow(kind), options.items, options.count, &target, &error))
            result = take_string(env, &target);
        else
            fail(env, &error);
    }
    free(kind.data);
    free_options(&options);
    return result;
}

LISP_FUNCTION(Fplace)
{
    portal_text target = {0}, title = {0}, error = {0};
    portal_edges edges;
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_edges(env, args[1], &edges)
        && read_text(env, args[2], &title))
        result = done(env, portal_views_place(borrow(target), edges, borrow(title), &error),
                      &error);
    free(target.data);
    free(title.data);
    return result;
}

/* open_channel returns a new descriptor, which the core owns once connected. */
LISP_FUNCTION(Fchannel)
{
    int fd = env->is_not_nil(env, args[0]) ? env->open_channel(env, args[0]) : -1;
    if (!returning(env))
        return NULL;
    if (portal_channel_connect(fd))
        return symbol(env, "t");
    const char *reason = strerror(errno);
    close(fd);
    signal_error(env, "Portal cannot use the record pipe: %s",
                 env->make_string(env, reason, (ptrdiff_t) strlen(reason)));
    return NULL;
}

LISP_FUNCTION(Fterminal_theme)
{
    portal_text name = {0}, error = {0};
    emacs_value result = NULL;
    bool named = env->is_not_nil(env, args[0]);
    if (!named || read_text(env, args[0], &name)) {
        portal_string borrowed = borrow(name);
        result =
            done(env, portal_terminals_theme(named ? &borrowed : NULL, &error), &error);
    }
    free(name.data);
    return result;
}

LISP_FUNCTION(Fweb_appearance)
{
    portal_text name = {0}, error = {0};
    emacs_value result = NULL;
    bool named = env->is_not_nil(env, args[0]);
    if (!named || read_text(env, args[0], &name)) {
        portal_string borrowed = borrow(name);
        result =
            done(env, portal_web_views_appearance(named ? &borrowed : NULL, &error), &error);
    }
    free(name.data);
    return result;
}

LISP_FUNCTION(Fterminal_paste)
{
    portal_text target = {0}, text = {0}, error = {0};
    emacs_value result = NULL;
    bool enter = nargs > 2 && env->is_not_nil(env, args[2]);
    if (read_text(env, args[0], &target) && read_text(env, args[1], &text))
        result = done(env, portal_terminals_paste(borrow(target), borrow(text), enter, &error),
                      &error);
    free(target.data);
    free(text.data);
    return result;
}

/* The code point of the one-character Lisp string VALUE, or 0 if it has
   another length. */
static bool read_character(emacs_env *env, emacs_value value, uint32_t *character)
{
    portal_text text = {0};
    if (!read_text(env, value, &text))
        return false;
    const unsigned char *bytes = (const unsigned char *) text.data;
    size_t extra = !text.length ? 0 : bytes[0] < 0x80 ? 0 : bytes[0] < 0xe0 ? 1 : bytes[0] < 0xf0 ? 2 : 3;
    *character = 0;
    if (text.length && text.length == extra + 1) {
        *character = extra ? bytes[0] & (0x3f >> extra) : bytes[0];
        for (size_t i = 1; i <= extra; i++)
            *character = *character << 6 | (bytes[i] & 0x3f);
    }
    free(text.data);
    return true;
}

/* Read a chord: CHARACTER, a string, and MODIFIERS, an integer.  The core
   rejects any that is not one character, or has modifiers it does not know. */
static bool read_chord(emacs_env *env, emacs_value character, emacs_value modifiers,
                       portal_chord *chord)
{
    if (!read_character(env, character, &chord->character))
        return false;
    intmax_t bits = env->extract_integer(env, modifiers);
    chord->modifiers = bits < 0 || bits > UINT32_MAX ? UINT32_MAX : (uint32_t) bits;
    return returning(env);
}

/* Whether VALUE's `type-of' is TYPE. */
static bool of_type(emacs_env *env, emacs_value value, const char *type)
{
    return env->eq(env, env->type_of(env, value), symbol(env, type));
}

/* (alist-get KEY ALIST), for a symbol KEY. */
static emacs_value get(emacs_env *env, emacs_value alist, const char *key)
{
    emacs_value arguments[] = {symbol(env, key), alist};
    return env->funcall(env, symbol(env, "alist-get"), 2, arguments);
}

/* Read ENTRY, an alist of a "character", "modifiers" and "event", into
   *BINDING.  An entry of another shape stays an invalid binding, for the core
   to reject. */
static bool read_binding(emacs_env *env, emacs_value entry, portal_binding *binding)
{
    *binding = (portal_binding) {{0, 0}, 0};
    if (!of_type(env, entry, "cons"))
        return true;
    emacs_value character = get(env, entry, "character"),
                modifiers = get(env, entry, "modifiers"), event = get(env, entry, "event");
    if (!returning(env))
        return false;
    if (!of_type(env, character, "string") || !of_type(env, modifiers, "integer")
        || !of_type(env, event, "integer"))
        return true;
    if (!read_chord(env, character, modifiers, &binding->chord))
        return false;
    binding->event = env->extract_integer(env, event);
    return returning(env);
}

/* JSON is {"regular": BINDINGS, "quick": BINDINGS}, each an array of
   bindings. */
LISP_FUNCTION(Fterminal_bindings)
{
    emacs_value arguments[] = {args[0], symbol(env, ":object-type"), symbol(env, "alist"),
                               symbol(env, ":array-type"), symbol(env, "array")};
    emacs_value json = env->funcall(env, symbol(env, "json-parse-string"), 5, arguments);
    if (!returning(env))
        return NULL;
    portal_binding *profiles[2] = {NULL, NULL};
    size_t counts[2] = {0, 0};
    const char *names[] = {"regular", "quick"};
    bool read = true;
    for (size_t p = 0; read && p < 2; p++) {
        emacs_value vector = of_type(env, json, "cons") ? get(env, json, names[p]) : NULL;
        if (!returning(env) || !vector || !of_type(env, vector, "vector")) {
            signal_error(env, "Invalid native terminal binding", NULL);
            read = false;
            break;
        }
        counts[p] = (size_t) env->vec_size(env, vector);
        profiles[p] = calloc(counts[p] + 1, sizeof *profiles[p]);
        if (!profiles[p]) {
            out_of_memory(env);
            read = false;
        }
        for (size_t i = 0; read && i < counts[p]; i++)
            read = read_binding(env, env->vec_get(env, vector, (ptrdiff_t) i), &profiles[p][i]);
    }
    emacs_value result = NULL;
    if (read) {
        portal_text error = {0};
        result = done(env,
                      portal_input_bindings(profiles[0], counts[0], profiles[1], counts[1],
                                            &error),
                      &error);
    }
    free(profiles[0]);
    free(profiles[1]);
    return result;
}

LISP_FUNCTION(Finput_escape_key)
{
    portal_chord chord = {0};
    portal_text error = {0};
    if (!read_chord(env, args[0], args[1], &chord))
        return NULL;
    return done(env, portal_input_set_escape(chord, &error), &error);
}

LISP_FUNCTION(Finput_double_escape)
{
    int64_t milliseconds = env->extract_integer(env, args[0]);
    portal_text error = {0};
    if (!returning(env))
        return NULL;
    return done(env, portal_input_set_double_escape(milliseconds, &error), &error);
}

LISP_FUNCTION(Finput)
{
    portal_text target = {0}, action = {0}, error = {0};
    emacs_value result = NULL;
    if (read_text(env, args[0], &target) && read_text(env, args[1], &action)) {
        int64_t serial =
            nargs > 2 && env->is_not_nil(env, args[2]) ? env->extract_integer(env, args[2]) : 0;
        bool performed = false;
        if (returning(env)) {
            if (portal_input_perform(borrow(target), borrow(action), serial, &performed, &error))
                result = boolean(env, performed);
            else
                fail(env, &error);
        }
    }
    free(target.data);
    free(action.data);
    return result;
}

#define STRINGS_FUNCTION(name, result) \
    Fstrings, &(const struct strings_function) {name, result}

static const struct export {
    const char *name;
    ptrdiff_t minimum, maximum;
    emacs_function function;
    const void *data;
    const char *documentation;
} exports[] = {
    {"portal--open", 2, 2, Fopen, NULL,
     "Open a view of KIND (\"terminal\" or \"web\") with an OPTIONS plist; return its target, "
     "such as \"web:1\"."},
    {"portal--place", 3, 3, Fplace, NULL,
     "Show TARGET at EDGES [LEFT TOP RIGHT BOTTOM] in the frame titled TITLE."},
    {"portal--hide", 1, 1, STRINGS_FUNCTION(hide, RESULT_T),
     "Hide TARGET, keeping its session alive."},
    {"portal--close", 1, 1, STRINGS_FUNCTION(close_view, RESULT_T),
     "End TARGET and release its view."},
    {"portal--inspect", 1, 1, STRINGS_FUNCTION(inspect, RESULT_JSON),
     "Return TARGET's native state as a plist, or nil for an unknown target."},
    {"portal--channel", 1, 1, Fchannel, NULL,
     "Send every view's records, lines of \"TYPE TARGET FIELD...\", to pipe PROCESS; nil "
     "disconnects."},
    {"portal--web-load", 2, 2, STRINGS_FUNCTION(web_load, RESULT_T),
     "Load URL, an absolute http, https, file, data or about URL, in web view TARGET."},
    {"portal--web-send", 2, 2, STRINGS_FUNCTION(web_send, RESULT_T),
     "Send the JSON object JSON to hosted web view TARGET's app over its bridge."},
    {"portal--web-receive", 1, 1, STRINGS_FUNCTION(web_receive, RESULT_STRING),
     "Return the messages waiting for Emacs on web view TARGET, as a JSON array."},
    {"portal--web-go", 2, 2, STRINGS_FUNCTION(web_go, RESULT_T),
     "Move web view TARGET through its history by STEP, \"back\" or \"forward\"."},
    {"portal--web-download-directory", 1, 1,
     STRINGS_FUNCTION(web_download_directory, RESULT_T),
     "Save web views' downloads in DIRECTORY, an absolute path, from now on."},
    {"portal--web-appearance", 1, 1, Fweb_appearance, NULL,
     "Show every web view in APPEARANCE, \"light\" or \"dark\"; nil follows the system's."},
    {"portal--terminal-theme", 1, 1, Fterminal_theme, NULL,
     "Apply named THEME to all terminals; nil restores system appearance defaults."},
    {"portal--terminal-themes", 0, 0, STRINGS_FUNCTION(terminal_themes, RESULT_JSON),
     "Return the available terminal theme names."},
    {"portal--terminal-paste", 2, 3, Fterminal_paste, NULL,
     "Paste TEXT into terminal TARGET; press Enter if ENTER is non-nil."},
    {"portal--terminal-text", 1, 1, STRINGS_FUNCTION(terminal_text, RESULT_STRING),
     "Select all of TARGET's scrollback and return its text. Leaves the native selection "
     "active."},
    {"portal--terminal-bindings", 1, 1, Fterminal_bindings, NULL,
     "Atomically replace runtime binding profiles from JSON."},
    {"portal--input-escape-key", 2, 2, Finput_escape_key, NULL,
     "Reserve CHARACTER with MODIFIERS for returning to Emacs in every view."},
    {"portal--input-double-escape", 1, 1, Finput_double_escape, NULL,
     "Return to Emacs on a second Escape within MILLISECONDS of the first; 0 never does."},
    {"portal--input", 2, 3, Finput, NULL,
     "Perform ACTION on native TARGET, optionally validating its handoff SERIAL."},
    {"portal--launcher-attach", 1, 1, Flauncher_attach, NULL,
     "Attach new hidden launcher frame TITLE on the validated GNU Emacs NS build."},
    {"portal--launcher-show", 7, 7, Flauncher_show, NULL,
     "Present the launcher at WIDTH HEIGHT DX DY SCREEN SHADOW RADIUS, in logical points."},
    {"portal--launcher-fit", 2, 2, Flauncher_fit, NULL,
     "Resize presentation SESSION's panel to HEIGHT points, keeping its top edge; no focus change."},
    {"portal--launcher-prepare", 0, 0, STRINGS_FUNCTION(launcher_prepare, RESULT_T),
     "Capture cancellation focus before creating or selecting a launcher frame."},
    {"portal--launcher-hide", 0, 1, Flauncher_hide, NULL,
     "Hide the launcher. Optional RESTORE-FOCUS restores cancellation focus if still owned."},
    {"portal--launcher-detach", 0, 0, STRINGS_FUNCTION(launcher_detach, RESULT_T),
     "Restore the launcher frame's original window BEFORE deleting the Emacs frame."},
    {"portal--launcher-inspect", 0, 0, STRINGS_FUNCTION(launcher_describe, RESULT_JSON),
     "Return launcher attachment, visibility and native geometry as a plist."},
    {"portal--shortcut-chord", 1, 1, STRINGS_FUNCTION(shortcut_chord, RESULT_STRING),
     "Return shortcut CHORD, such as \"command-control-option-p\", as the module writes it."},
    {"portal--shortcut-set", 2, 2, Fshortcut_set, NULL,
     "Register system-wide CHORD in place of shortcut REPLACING, or nil; return its new ID."},
    {"portal--shortcut-remove", 1, 1, Fshortcut_remove, NULL,
     "Release the system-wide shortcut ID; an unknown ID is already released."},
    {"portal--shortcuts", 0, 0, STRINGS_FUNCTION(shortcuts_describe, RESULT_JSON),
     "Return the system-wide shortcuts as plists of :id, :chord, :hotkey and :held."},
    {"portal--key-post", 1, 1, STRINGS_FUNCTION(key_post, RESULT_T),
     "Press and release CHORD, such as \"Command-V\", in the frontmost application."},
    {"portal--status-show", 11, 11, Fstatus_show, NULL,
     "Show TEXT with TONE in the status panel at POSITION on SCREEN, moved by DX DY, WIDTH "
     "HEIGHT MIN-WIDTH MAX-WIDTH LINES."},
    {"portal--status-hide", 0, 0, STRINGS_FUNCTION(status_hide, RESULT_T),
     "Hide the status panel; do nothing when it is hidden."},
};

/* Run the Lisp function DATA, an export, at Emacs's request (input.h). */
static emacs_value Frequest(emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
    const struct export *export = data;
    portal_input_request(true);
    emacs_value result = export->function(env, nargs, args, (void *) export->data);
    portal_input_request(false);
    return result;
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    if (runtime->size < (ptrdiff_t) sizeof *runtime)
        return 1;
    emacs_env *env = runtime->get_environment(runtime);
    if (env->size < (ptrdiff_t) sizeof *env)
        return 2;
    for (size_t i = 0; i < sizeof exports / sizeof *exports; i++) {
        emacs_value arguments[] = {
            symbol(env, exports[i].name),
            env->make_function(env, exports[i].minimum, exports[i].maximum, Frequest,
                               exports[i].documentation, (void *) &exports[i])};
        env->funcall(env, symbol(env, "fset"), 2, arguments);
        if (!returning(env))
            return 1;
    }
    emacs_value feature = symbol(env, "portal-native-module");
    env->funcall(env, symbol(env, "provide"), 1, &feature);
    return returning(env) ? 0 : 1;
}
