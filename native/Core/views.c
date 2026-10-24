/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Portal views: every view's identity and the lifecycle bookkeeping that
   every kind shares.  A view is registered here from a successful create
   until close, and the platform view it holds is never used outside that
   span.  The platform renders views; Lisp chooses where (portal-view.el).
   Each view keeps its input here too, which input.c manages, and what
   web.c keeps for it.

   The registry is a list in creation order.  Emacs has few views at once,
   so finding a target walks the list. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "terminals.h"
#include "views.h"
#include "web.h"

struct view {
    struct view *next;
    portal_view *native;
    portal_kind kind;
    struct portal_web_state *web; /* A web view's pages and bridge (web.c). */
    uint64_t id;
    bool attached;
    bool announced; /* Its portal_views_announce record waits for an inspection. */
    portal_edges edges; /* Where it is attached, while ATTACHED. */
    struct portal_input input;
    size_t length;
    char target[]; /* LENGTH bytes, NUL-terminated, such as "web:3". */
};

static struct {
    struct view *first, *last; /* Open views, oldest first. */
    uint64_t ids;              /* The last ID given out. */
} views;

static const char *const kinds[] = {[PORTAL_WEB] = "web", [PORTAL_TERMINAL] = "terminal"};

static struct view *find(portal_string target, int kind, portal_text *error)
{
    for (struct view *view = views.first; view; view = view->next)
        if (view->length == target.length && !memcmp(view->target, target.data, target.length)
            && (kind == PORTAL_ANY_KIND || (int) view->kind == kind))
            return view;
    if (error)
        fail(error, "No Portal view ", target);
    return NULL;
}

portal_view *portal_views_find(portal_string target, int kind, portal_text *error)
{
    struct view *view = find(target, kind, error);
    return view ? view->native : NULL;
}

struct portal_input *portal_views_input(portal_string target)
{
    struct view *view = find(target, PORTAL_ANY_KIND, NULL);
    return view ? &view->input : NULL;
}

portal_view *portal_views_find_web(portal_string target, struct portal_web_state **web,
                                   portal_text *error)
{
    struct view *view = find(target, PORTAL_WEB, error);
    if (!view)
        return NULL;
    *web = view->web;
    return view->native;
}

/* Register a new view of KIND, which the platform creates from OPTIONS, or,
   when OPENER is not NULL, as the window OPENER's page asked for with
   REQUEST.  Return it, with a copy of its target in *COPY unless COPY is
   NULL; on failure return NULL with *ERROR set, having registered nothing. */
static struct view *add(portal_kind kind, const portal_option *options, size_t count,
                        portal_view *opener, void *request, char **copy, portal_text *error)
{
    /* An open that gets this far spends its ID even if it fails, so no two
       opens share one. */
    uint64_t id = ++views.ids;
    char name[32];
    size_t length = (size_t) snprintf(name, sizeof name, "%s:%" PRIu64, kinds[kind], id);
    /* Allocate all the core needs first: once the platform has a view,
       nothing but the platform can fail. */
    struct view *view = malloc(sizeof *view + length + 1);
    char *target = copy ? malloc(length + 1) : NULL;
    struct portal_web_state *web = kind == PORTAL_WEB ? portal_web_state_new(options, count) : NULL;
    if (!view || (copy && !target) || (kind == PORTAL_WEB && !web)) {
        free(view);
        free(target);
        portal_web_state_free(web);
        fail_with(error, "Portal is out of memory");
        return NULL;
    }
    *view = (struct view) {.kind = kind, .web = web, .id = id, .length = length};
    memcpy(view->target, name, length + 1);
    portal_string own = {view->target, length};
    if (!(opener ? portal_web_create_window(opener, own, request, &view->native, error)
                 : portal_view_create(kind, own, options, count, &view->native, error))) {
        free(view);
        free(target);
        portal_web_state_free(web);
        return NULL;
    }
    portal_input_open(&view->input, view->native, own, kind, options, count);
    if (views.last)
        views.last->next = view;
    else
        views.first = view;
    views.last = view;
    if (copy) {
        memcpy(target, name, length + 1);
        *copy = target;
    }
    return view;
}

bool portal_views_open(portal_string kind_name, const portal_option *options, size_t count,
                       portal_text *target, portal_text *error)
{
    portal_kind kind;
    if (is(kind_name, "web"))
        kind = PORTAL_WEB;
    else if (is(kind_name, "terminal"))
        kind = PORTAL_TERMINAL;
    else
        return fail(error, "Unknown Portal view kind: ", kind_name);
    if (kind == PORTAL_TERMINAL && !portal_terminals_check(options, count, error))
        return false;
    if (kind == PORTAL_WEB && !portal_web_views_check(options, count, error))
        return false;
    char *copy;
    struct view *view = add(kind, options, count, NULL, NULL, &copy, error);
    if (!view)
        return false;
    *target = (portal_text) {copy, view->length};
    return true;
}

bool portal_views_open_window(portal_view *opener, void *request, portal_string *target,
                              struct portal_web_state **web)
{
    portal_text error = {0};
    struct view *view = add(PORTAL_WEB, NULL, 0, opener, request, NULL, &error);
    free(error.data); /* No one asked, so no one hears why. */
    if (!view)
        return false;
    *target = (portal_string) {view->target, view->length};
    *web = view->web;
    return true;
}

/* EDGES as a rectangle, if it has positive dimensions and fits in 32 bits. */
static bool rectangle(portal_edges edges, portal_rect *rect, portal_text *error)
{
    int64_t values[] = {edges.left, edges.top, edges.right, edges.bottom};
    for (size_t i = 0; i < 4; i++)
        if (values[i] < INT32_MIN || values[i] > INT32_MAX)
            return fail_with(error, "Pane edges must fit in 32 bits");
    if (edges.right <= edges.left || edges.bottom <= edges.top)
        return fail_with(error, "Expected [LEFT TOP RIGHT BOTTOM] with positive dimensions");
    *rect = (portal_rect) {edges.left, edges.top, edges.right - edges.left,
                           edges.bottom - edges.top};
    return true;
}

bool portal_views_place(portal_string target, portal_edges edges, portal_string title,
                        portal_text *error)
{
    portal_rect rect;
    struct view *view = find(target, PORTAL_ANY_KIND, error);
    if (!view || !rectangle(edges, &rect, error))
        return false;
    /* The frame may differ even when EDGES do not, so every place attaches. */
    if (!portal_view_attach(view->native, title, rect, error))
        return false;
    view->attached = true;
    view->edges = edges;
    return true;
}

bool portal_views_hide(portal_string target, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, error);
    if (!view || !portal_input_close(&view->input, error))
        return false;
    if (view->attached && !portal_view_detach(view->native, error))
        return false;
    view->attached = false;
    return true;
}

bool portal_views_close(portal_string target, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, error), *previous = NULL;
    if (!view || !portal_input_close(&view->input, error))
        return false;
    for (struct view *other = views.first; other != view; other = other->next)
        previous = other;
    struct view **link = previous ? &previous->next : &views.first;
    *link = view->next;
    if (views.last == view)
        views.last = previous;
    if (!portal_view_destroy(view->native, error)) {
        /* Nothing changed, so the view is open where it was. */
        *link = view;
        if (!view->next)
            views.last = view;
        return false;
    }
    portal_web_state_free(view->web);
    free(view);
    return true;
}

/* Whether C is JSON whitespace. */
static bool blank(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

bool portal_views_inspect(portal_string target, portal_text *state, portal_text *error)
{
    struct view *view = find(target, PORTAL_ANY_KIND, NULL);
    if (!view) {
        char *null = malloc(5);
        if (!null)
            return fail_with(error, "Portal is out of memory");
        memcpy(null, "null", 5);
        *state = (portal_text) {null, 4};
        return true;
    }
    /* This description shows every change so far; the next one announces. */
    view->announced = false;
    portal_text described = {0};
    if (!portal_view_describe(view->native, &described, error))
        return false;
    /* Splice the core's properties into the platform's object: {"id":...,REST}.
       Any JSON whitespace may surround the object or fill an empty one. */
    const char *data = described.data;
    size_t start = 0, end = described.length;
    while (start < end && blank(data[start]))
        start++;
    while (end > start && blank(data[end - 1]))
        end--;
    if (end - start < 2 || data[start] != '{' || data[end - 1] != '}') {
        free(described.data);
        return fail_with(error, "The platform described a view with no JSON object");
    }
    size_t rest = start + 1; /* The object's first member, or its '}'. */
    while (blank(data[rest]))
        rest++;
    char prefix[256];
    if (view->attached)
        snprintf(prefix, sizeof prefix,
                 "{\"id\":%" PRIu64 ",\"kind\":\"%s\",\"visible\":true,"
                 "\"edges\":[%" PRId64 ",%" PRId64 ",%" PRId64 ",%" PRId64 "]",
                 view->id, kinds[view->kind], view->edges.left, view->edges.top,
                 view->edges.right, view->edges.bottom);
    else
        snprintf(prefix, sizeof prefix,
                 "{\"id\":%" PRIu64 ",\"kind\":\"%s\",\"visible\":false,\"edges\":[]", view->id,
                 kinds[view->kind]);
    bool empty = rest == end - 1;
    size_t head = strlen(prefix), total = head + (empty ? 1 : 1 + end - rest);
    char *json = malloc(total + 1);
    if (!json) {
        free(described.data);
        return fail_with(error, "Portal is out of memory");
    }
    memcpy(json, prefix, head);
    if (empty) {
        json[head] = '}';
    } else {
        json[head] = ',';
        memcpy(json + head + 1, data + rest, end - rest);
    }
    json[total] = '\0';
    free(described.data);
    *state = (portal_text) {json, total};
    return true;
}

bool portal_views_each(portal_kind kind, bool (*visit)(portal_view *view, void *context),
                       void *context)
{
    for (struct view *view = views.first; view; view = view->next)
        if (view->kind == kind && !visit(view->native, context))
            return false;
    return true;
}

bool portal_views_each_web(bool (*visit)(portal_view *native, struct portal_web_state *state,
                                         void *context),
                           void *context)
{
    for (struct view *view = views.first; view; view = view->next)
        if (view->kind == PORTAL_WEB && !visit(view->native, view->web, context))
            return false;
    return true;
}

void portal_views_announce(portal_string target, portal_kind kind, const char *type)
{
    struct view *view = find(target, (int) kind, NULL);
    if (view && !view->announced)
        view->announced = portal_channel_send((portal_string) {type, strlen(type)}, target,
                                              NULL, 0);
}

/* A platform's late record, for a view that is gone or not yet open, would
   reach Emacs with a target no buffer has.  It never leaves the core. */
bool portal_notify(portal_string type, portal_string target, const portal_string *fields,
                   size_t count)
{
    return find(target, PORTAL_ANY_KIND, NULL)
        && portal_channel_send(type, target, fields, count);
}
