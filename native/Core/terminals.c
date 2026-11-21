/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Terminal views: Portal's rules for them, on the platform's terminal
   primitives.  views.c owns their identity and lifecycle, and asks this file
   to check a terminal's options before the platform creates it.  The
   platform owns the terminal engine, its process and its theme catalog, and
   reports changes to what a terminal describes.  The core keeps no theme,
   opacity or text size: Lisp holds the theme and the opacity and works out
   each terminal's size, and passes them to each new terminal. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core.h"
#include "rex.h"
#include "terminals.h"
#include "views.h"

/* The last option NAME in OPTIONS, since a later duplicate wins; or NULL. */
static const portal_option *option(const portal_option *options, size_t count, const char *name)
{
    const portal_option *found = NULL;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, name))
            found = &options[i];
    return found;
}

/* The platform's theme names. */
struct names {
    portal_text *items;
    size_t count;
};

static bool list_names(struct names *names, portal_text *error)
{
    *names = (struct names) {0};
    return portal_terminal_list_themes(&names->items, &names->count, error);
}

static void free_names(struct names *names)
{
    for (size_t i = 0; i < names->count; i++)
        free(names->items[i].data);
    free(names->items);
}

/* Whether the platform lists the theme NAME; if not, set *ERROR. */
static bool known(portal_string name, portal_text *error)
{
    struct names names;
    if (!list_names(&names, error))
        return false;
    bool found = false;
    for (size_t i = 0; !found && i < names.count; i++)
        found = names.items[i].length == name.length
            && !memcmp(names.items[i].data, name.data, name.length);
    free_names(&names);
    return found || fail(error, "Unknown terminal theme: ", name);
}

bool portal_terminals_fed(const portal_option *options, size_t count)
{
    const portal_option *fed = option(options, count, "fed");
    return fed && fed->flag;
}

double portal_terminal_points(double points)
{
    /* NaN fails both comparisons. */
    return points > PORTAL_TERMINAL_MAX_POINTS ? PORTAL_TERMINAL_MAX_POINTS
        : points >= PORTAL_TERMINAL_MIN_POINTS ? points
                                               : PORTAL_TERMINAL_MIN_POINTS;
}

bool portal_terminals_check(const portal_option *options, size_t count, portal_text *error)
{
    const char *const strings[] = {"directory", "command", "argv", "theme", "dark-theme"};
    for (size_t i = 0; i < sizeof strings / sizeof *strings; i++) {
        const portal_option *value = option(options, count, strings[i]);
        if (value && !value->is_string && value->flag) {
            char message[64];
            snprintf(message, sizeof message, "Option :%s must be a string", strings[i]);
            return fail_with(error, message);
        }
    }
    const portal_option *directory = option(options, count, "directory");
    const portal_option *command = option(options, count, "command");
    const portal_option *argv = option(options, count, "argv");
    if (portal_terminals_fed(options, count)) {
        /* Its program runs elsewhere. */
        if ((command && command->is_string) || (argv && argv->is_string))
            return fail_with(error, "A fed terminal runs no :command or :argv");
    } else if (!directory || !directory->is_string) {
        return fail_with(error, "A terminal view needs a :directory");
    }
    if (command && command->is_string && argv && argv->is_string)
        return fail_with(error, "A terminal view accepts either :command or :argv");
    const portal_option *points = option(options, count, "points");
    if (points && !points->is_number && (points->is_string || points->flag))
        return fail_with(error, "Option :points must be a number");
    const portal_option *opacity = option(options, count, "opacity");
    if (opacity && !opacity->is_number && (opacity->is_string || opacity->flag))
        return fail_with(error, "Option :opacity must be a number");
    if (opacity && opacity->is_number && !portal_terminal_opacity_valid(opacity->number, error))
        return false;
    const portal_option *theme = option(options, count, "theme");
    const portal_option *dark = option(options, count, "dark-theme");
    bool named = theme && theme->is_string, paired = dark && dark->is_string;
    if (paired && !named)
        return fail_with(error, "Option :dark-theme needs a :theme");
    return (!named || known(theme->string, error)) && (!paired || known(dark->string, error));
}

bool portal_terminal_opacity_valid(double opacity, portal_text *error)
{
    /* NaN fails both comparisons. */
    return (opacity >= 0 && opacity <= 1)
        || fail_with(error, "A terminal's opacity is a number from 0 to 1");
}

/* Byte order, which for UTF-8 is code point order. */
static int compare(const void *a, const void *b)
{
    const portal_text *x = a, *y = b;
    int order = memcmp(x->data, y->data, x->length < y->length ? x->length : y->length);
    return order ? order : (x->length > y->length) - (x->length < y->length);
}

bool portal_terminals_themes(portal_text *json, portal_text *error)
{
    struct names names;
    if (!list_names(&names, error))
        return false;
    if (names.count)
        qsort(names.items, names.count, sizeof *names.items, compare);
    /* Brackets and a NUL, and for each name its quotes, a comma, and each
       byte escaped at most as \u00XX. */
    size_t size = 3;
    for (size_t i = 0; i < names.count; i++)
        size += 3 + 6 * names.items[i].length;
    char *text = malloc(size);
    if (!text) {
        free_names(&names);
        return fail_with(error, "Portal is out of memory");
    }
    size_t length = 0;
    text[length++] = '[';
    for (size_t i = 0; i < names.count; i++) {
        if (i)
            text[length++] = ',';
        text[length++] = '"';
        for (size_t k = 0; k < names.items[i].length; k++) {
            unsigned char c = (unsigned char) names.items[i].data[k];
            if (c == '"' || c == '\\') {
                text[length++] = '\\';
                text[length++] = (char) c;
            } else if (c < 0x20) {
                length += (size_t) snprintf(text + length, 7, "\\u%04x", c);
            } else {
                text[length++] = (char) c;
            }
        }
        text[length++] = '"';
    }
    text[length++] = ']';
    text[length] = '\0';
    free_names(&names);
    *json = (portal_text) {text, length};
    return true;
}

struct theme {
    const portal_string *light, *dark;
    portal_text *error;
};

static bool apply(portal_view *terminal, void *context)
{
    struct theme *theme = context;
    return portal_terminal_apply_theme(terminal, theme->light, theme->dark, theme->error);
}

bool portal_terminals_theme(const portal_string *light, const portal_string *dark,
                            portal_text *error)
{
    if (dark && !light)
        return fail_with(error, "A dark terminal theme needs a light one");
    /* Check the names before touching any terminal, even with none open. */
    if ((light && !known(*light, error)) || (dark && !known(*dark, error)))
        return false;
    /* A single name is the pair of itself. */
    struct theme theme = {light, dark ? dark : light, error};
    return portal_views_each(PORTAL_TERMINAL, apply, &theme);
}

struct opacity {
    double opacity;
    portal_text *error;
};

static bool set_opacity(portal_view *terminal, void *context)
{
    struct opacity *opacity = context;
    return portal_terminal_set_opacity(terminal, opacity->opacity, opacity->error);
}

bool portal_terminals_opacity(double opacity, portal_text *error)
{
    /* Check it before touching any terminal, even with none open. */
    if (!portal_terminal_opacity_valid(opacity, error))
        return false;
    struct opacity context = {opacity, error};
    return portal_views_each(PORTAL_TERMINAL, set_opacity, &context);
}

bool portal_terminals_text_size(portal_string target, double points, portal_text *error)
{
    portal_view *terminal = portal_views_find(target, PORTAL_TERMINAL, error);
    return terminal
        && portal_terminal_set_text_size(terminal, portal_terminal_points(points), error);
}

bool portal_terminals_paste(portal_string target, portal_string text, bool enter,
                            portal_text *error)
{
    portal_view *terminal = portal_views_find(target, PORTAL_TERMINAL, error);
    return terminal && portal_terminal_paste_text(terminal, text, error)
        && (!enter || portal_terminal_press_enter(terminal, error));
}

bool portal_terminals_text(portal_string target, portal_text *text, portal_text *error)
{
    portal_view *terminal = portal_views_find(target, PORTAL_TERMINAL, error);
    return terminal && portal_terminal_read_text(terminal, text, error);
}

void portal_terminal_changed(portal_string target)
{
    portal_views_announce(target, PORTAL_TERMINAL, "terminal");
}

void portal_terminal_input(portal_string target, const char *bytes, size_t length)
{
    if (portal_views_fed(target))
        portal_rex_input(target, bytes, length);
}
