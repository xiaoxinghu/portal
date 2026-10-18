/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Web views: Portal's rules for what a web view loads, where its page may
   go, and the bridge between a hosted app and its buffer
   (docs/editor-bridge.md).  The platform loads pages and delivers messages,
   and tells the core what pages do through the calls in portal.h.

   Pages.  The core remembers the URL Emacs loaded last, its address, and
   the URL of the page committed last, both as the platform's parser spells
   them (portal_web_parse_url), so it compares URLs byte for byte with those
   the platform reports.  Loading the page on screen again, ignoring
   fragments, reloads it without a new history entry, and a view
   that has shown nothing yet is at about:blank already.  A hosted app's main
   frame stays at its address's origin: other pages open in the default
   browser, and local files, which WebKit would not load there, go to Emacs.

   The bridge.  Messages a hosted app posts wait here, outside the pipe, so
   large payloads such as drawings never cross it.  The first waiting message
   sends one "bridge TARGET" record, and no other goes until Emacs has
   received them all.  A newer "change" replaces one Emacs has not received
   yet; every other message keeps its order.  Only the app's main frame, at
   its address, may post, as the platform observed it.  The core adds its
   own messages, whose types an app cannot post: "page" for each page the
   view commits, and "follow" for each local link handed to Emacs.  It also
   adds "error" for failures the app cannot report, a type apps use too.

   Appearance.  A web view's pages see the system's appearance, following
   its changes, unless Lisp forces light or dark, at open or later for every
   web view at once.  The core checks the name; the platform shows it.

   Generations.  Each commit starts a new generation.  A message the core
   posts to a page carries the generation it went to as its token, so a
   failed delivery that the platform reports after the page has gone is
   ignored.  A call for a closed view finds no target and is ignored too. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "input.h"
#include "views.h"
#include "web.h"

/* A message waiting for Emacs: one JSON object. */
struct message {
    struct message *next;
    bool change; /* Whether its type is "change". */
    size_t length;
    char json[]; /* LENGTH bytes. */
};

struct portal_web_state {
    bool hosted;
    portal_text address;         /* The URL Emacs loaded last, or no data. */
    portal_text page;            /* The URL committed last, or no data. */
    uint64_t generation;         /* 1 + pages committed: the token of posts now. */
    struct message *first, *last; /* Waiting messages, oldest first. */
    bool announced;              /* Whether a bridge record went out for them. */
};

/* The shared scripts, embedded with C23's #embed, which Clang and GCC 15
   also accept in C11. */
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
#endif
static const char links_script[] = {
#embed "scripts/links.js"
    , 0};
#ifdef __clang__
#pragma clang diagnostic pop
#endif

static portal_string literal(const char *text)
{
    return (portal_string) {text, strlen(text)};
}

static portal_string borrow(portal_text text)
{
    return (portal_string) {text.data, text.length};
}

static bool same(portal_string a, portal_string b)
{
    return a.length == b.length && !memcmp(a.data, b.data, a.length);
}

static char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? (char) (c - 'A' + 'a') : c;
}

/* Whether A and B are the same, ignoring ASCII case. */
static bool same_ignoring_case(portal_string a, portal_string b)
{
    if (a.length != b.length)
        return false;
    for (size_t i = 0; i < a.length; i++)
        if (lower(a.data[i]) != lower(b.data[i]))
            return false;
    return true;
}

/* Set *ERROR to BEFORE, DETAIL and AFTER, and return false. */
static bool fail_around(portal_text *error, const char *before, portal_string detail,
                        const char *after)
{
    size_t head = strlen(before), tail = strlen(after), length = head + detail.length + tail;
    char *text = malloc(length + 1);
    if (text) {
        memcpy(text, before, head);
        if (detail.length)
            memcpy(text + head, detail.data, detail.length);
        memcpy(text + head + detail.length, after, tail + 1);
        *error = (portal_text) {text, length};
    }
    return false;
}

static bool out_of_memory(portal_text *error)
{
    return fail_with(error, "Portal is out of memory");
}

/* Copy STRING into *COPY, NUL-terminated. */
static bool copy(portal_string string, portal_text *copy)
{
    char *data = malloc(string.length + 1);
    if (!data)
        return false;
    if (string.length)
        memcpy(data, string.data, string.length);
    data[string.length] = '\0';
    *copy = (portal_text) {data, string.length};
    return true;
}

/* URLs, as far as Portal's rules read them.  Only the scheme, host and
   port matter, and the fragment; the platform parses URLs to load them. */

/* URL's scheme, without its colon, or an empty string without one. */
static portal_string scheme(portal_string url)
{
    size_t i = 0;
    char first = url.length ? lower(url.data[0]) : '\0';
    if (first >= 'a' && first <= 'z')
        while (++i < url.length) {
            char c = lower(url.data[i]);
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-'
                  || c == '.'))
                break;
        }
    return (portal_string) {url.data, i < url.length && url.data[i] == ':' ? i : 0};
}

static bool has_scheme(portal_string url, const char *name)
{
    return same_ignoring_case(scheme(url), literal(name));
}

/* Where a URL's document comes from.  Two URLs have the same origin when
   their schemes and hosts match, ignoring case, and their ports as written;
   a URL without an authority, such as a data or file URL, has an empty host
   and port. */
struct origin {
    portal_string scheme, host, port;
};

static struct origin origin(portal_string url)
{
    struct origin origin = {scheme(url), {url.data, 0}, {url.data, 0}};
    size_t start = origin.scheme.length ? origin.scheme.length + 1 : 0;
    if (url.length - start < 2 || url.data[start] != '/' || url.data[start + 1] != '/')
        return origin;
    size_t host = start + 2, end = host;
    while (end < url.length && url.data[end] != '/' && url.data[end] != '?'
           && url.data[end] != '#')
        end++;
    for (size_t i = host; i < end; i++)
        if (url.data[i] == '@') /* After any user name and password. */
            host = i + 1;
    size_t colon = host;
    if (colon < end && url.data[colon] == '[') /* An IPv6 address. */
        while (colon < end && url.data[colon] != ']')
            colon++;
    while (colon < end && url.data[colon] != ':')
        colon++;
    origin.host = (portal_string) {url.data + host, colon - host};
    if (colon < end)
        origin.port = (portal_string) {url.data + colon + 1, end - colon - 1};
    return origin;
}

static bool same_origin(portal_string a, portal_string b)
{
    struct origin first = origin(a), second = origin(b);
    return same_ignoring_case(first.scheme, second.scheme)
        && same_ignoring_case(first.host, second.host) && same(first.port, second.port);
}

/* URL without its fragment. */
static portal_string document(portal_string url)
{
    const char *hash = url.length ? memchr(url.data, '#', url.length) : NULL;
    return (portal_string) {url.data, hash ? (size_t) (hash - url.data) : url.length};
}

/* Whether a web view may load URL: an absolute http or https URL with a
   host, or a file, data or about URL. */
static bool loadable(portal_string url)
{
    if (has_scheme(url, "http") || has_scheme(url, "https"))
        return origin(url).host.length > 0;
    return has_scheme(url, "file") || has_scheme(url, "data") || has_scheme(url, "about");
}

/* The bridge. */

/* Types only the core sends. */
static bool reserved(portal_string type)
{
    return is(type, "page") || is(type, "follow");
}

/* Send TARGET's bridge record, unless one went out for messages Emacs has
   not received.  A record the pipe refuses is tried again with the next
   message. */
static void announce(struct portal_web_state *web, portal_string target)
{
    if (!web->announced && web->first)
        web->announced = portal_channel_send(literal("bridge"), target, NULL, 0);
}

/* Queue the LENGTH bytes of JSON, a message of type "change" if CHANGE, for
   Emacs.  Without memory for it, the message is lost. */
static void queue(struct portal_web_state *web, portal_string target, bool change,
                  const char *json, size_t length)
{
    struct message *message = malloc(sizeof *message + length);
    if (!message)
        return;
    *message = (struct message) {.change = change, .length = length};
    memcpy(message->json, json, length);
    if (change) {
        struct message **link = &web->first;
        web->last = NULL;
        while (*link) {
            if ((*link)->change) {
                struct message *replaced = *link;
                *link = replaced->next;
                free(replaced);
            } else {
                web->last = *link;
                link = &(*link)->next;
            }
        }
    }
    if (web->last)
        web->last->next = message;
    else
        web->first = message;
    web->last = message;
    announce(web, target);
}

/* Queue the core's message {"type":TYPE}, with "NAME":VALUE unless NAME is
   NULL. */
static void queue_own(struct portal_web_state *web, portal_string target, const char *type,
                      const char *name, portal_string value)
{
    struct json json = {0};
    put(&json, "{\"type\":", 8);
    put_string(&json, literal(type));
    if (name) {
        put(&json, ",", 1);
        put_string(&json, literal(name));
        put(&json, ":", 1);
        put_string(&json, value);
    }
    put(&json, "}", 1);
    if (!json.failed)
        queue(web, target, false, json.data, json.length);
    free(json.data);
}

static void free_messages(struct portal_web_state *web)
{
    while (web->first) {
        struct message *next = web->first->next;
        free(web->first);
        web->first = next;
    }
    web->last = NULL;
}

/* The open web view TARGET, for the platform's calls: NULL when it is gone. */
static portal_view *find(portal_string target, struct portal_web_state **web)
{
    return portal_views_find_web(target, web, NULL);
}

/* Give Emacs the keyboard, ending any handoff it is handling, then queue the
   core's message TYPE, with a "url" unless URL is empty.  The escape record
   goes out first (input.h), so Emacs has stopped reading the handoff's key
   sequence by the time it receives the message. */
static void hand_off(portal_string target, const char *type, portal_string url)
{
    portal_input_escape(target);
    struct portal_web_state *web;
    if (find(target, &web)) /* The platform cannot close it, but check. */
        queue_own(web, target, type, url.length ? "url" : NULL, url);
}

/* Lifetime, for views.c. */

struct portal_web_state *portal_web_state_new(const portal_option *options, size_t count)
{
    struct portal_web_state *web = calloc(1, sizeof *web);
    if (!web)
        return NULL;
    web->generation = 1;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "hosted"))
            web->hosted = options[i].is_string || options[i].flag;
    return web;
}

bool portal_web_state_hosted(const struct portal_web_state *web)
{
    return web->hosted;
}

void portal_web_state_free(struct portal_web_state *web)
{
    if (!web)
        return;
    free_messages(web);
    free(web->address.data);
    free(web->page.data);
    free(web);
}

/* The Lisp functions, for emacs.c. */

/* The appearance NAME means, or the system's for a null NAME; false, with
   *ERROR set, for any other NAME. */
static bool appearance(const portal_string *name, portal_appearance *appearance,
                       portal_text *error)
{
    if (!name)
        *appearance = PORTAL_APPEARANCE_SYSTEM;
    else if (is(*name, "light"))
        *appearance = PORTAL_APPEARANCE_LIGHT;
    else if (is(*name, "dark"))
        *appearance = PORTAL_APPEARANCE_DARK;
    else
        return fail(error, "Unknown web appearance: ", *name);
    return true;
}

bool portal_web_views_check(const portal_option *options, size_t count, portal_text *error)
{
    const portal_option *found = NULL;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "appearance"))
            found = &options[i];
    if (!found || (!found->is_string && !found->flag))
        return true;
    if (!found->is_string)
        return fail_with(error, "Option :appearance must be \"light\", \"dark\" or nil");
    portal_appearance unused;
    return appearance(&found->string, &unused, error);
}

struct appear {
    portal_appearance appearance;
    portal_text *error;
};

static bool appear(portal_view *web, void *context)
{
    struct appear *appear = context;
    return portal_web_set_appearance(web, appear->appearance, appear->error);
}

bool portal_web_views_appearance(const portal_string *name, portal_text *error)
{
    struct appear context = {.error = error};
    return appearance(name, &context.appearance, error)
        && portal_views_each(PORTAL_WEB, appear, &context);
}

bool portal_web_views_load(portal_string target, portal_string url, portal_text *error)
{
    struct portal_web_state *web;
    portal_view *native = portal_views_find_web(target, &web, error);
    if (!native)
        return false;
    if (!loadable(url))
        return fail_with(error, "Expected an absolute http, https, file, data or about URL");
    /* The platform's spelling, which is also how it reports this page. */
    portal_text address, previous = web->address;
    if (!portal_web_parse_url(url, &address, error))
        return false;
    portal_string parsed = borrow(address);
    /* The address is in place while the platform loads, so the navigation
       this starts is to the view's own origin. */
    web->address = address;
    bool loaded;
    if (!web->page.data && is(parsed, "about:blank"))
        loaded = true; /* Loading it would put a blank page in the history. */
    else if (web->page.data && same(document(parsed), document(borrow(web->page))))
        loaded = portal_web_go(native, PORTAL_RELOAD, error);
    else
        loaded = portal_web_load(native, parsed, error);
    if (!loaded) {
        web->address = previous;
        free(address.data);
        return false;
    }
    free(previous.data);
    return true;
}

/* TARGET's view and state, if it is a hosted web view. */
static portal_view *find_hosted(portal_string target, struct portal_web_state **web,
                                portal_text *error)
{
    portal_view *native = portal_views_find_web(target, web, error);
    if (!native || (*web)->hosted)
        return native;
    fail_around(error, "Web view ", target, " is not a hosted app, so it has no bridge");
    return NULL;
}

bool portal_web_views_send(portal_string target, portal_string json, portal_text *error)
{
    struct portal_web_state *web;
    portal_view *native = find_hosted(target, &web, error);
    return native && portal_web_post(native, json, web->generation, error);
}

bool portal_web_views_receive(portal_string target, portal_text *json, portal_text *error)
{
    struct portal_web_state *web;
    if (!find_hosted(target, &web, error))
        return false;
    size_t length = 2;
    for (struct message *message = web->first; message; message = message->next)
        length += message->length + (message != web->first);
    char *data = malloc(length + 1);
    if (!data)
        return out_of_memory(error);
    char *end = data;
    *end++ = '[';
    for (struct message *message = web->first; message; message = message->next) {
        if (message != web->first)
            *end++ = ',';
        memcpy(end, message->json, message->length);
        end += message->length;
    }
    *end++ = ']';
    *end = '\0';
    free_messages(web);
    web->announced = false;
    *json = (portal_text) {data, length};
    return true;
}

bool portal_web_views_go(portal_string target, portal_string step, portal_text *error)
{
    struct portal_web_state *web;
    portal_view *native = portal_views_find_web(target, &web, error);
    if (!native)
        return false;
    if (is(step, "back"))
        return portal_web_go(native, PORTAL_BACK, error);
    if (is(step, "forward"))
        return portal_web_go(native, PORTAL_FORWARD, error);
    return fail(error, "Web history step must be \"back\" or \"forward\", not ", step);
}

/* The platform's calls, from portal.h. */

void portal_web_posted(portal_string target, portal_sender sender, portal_string type,
                       portal_string json)
{
    struct portal_web_state *web;
    if (find(target, &web) && web->hosted && sender.main_frame && web->address.data
        && same(sender.url, borrow(web->address)) && !reserved(type))
        queue(web, target, is(type, "change"), json.data, json.length);
}

portal_navigation portal_web_navigating(portal_string target, portal_string url,
                                        bool main_frame)
{
    struct portal_web_state *web;
    portal_view *native = find(target, &web);
    if (!native || !web->hosted || !main_frame || has_scheme(url, "about")
        || (web->address.data && same_origin(url, borrow(web->address))))
        return PORTAL_NAVIGATION_ALLOW;
    if (!has_scheme(url, "file"))
        return PORTAL_NAVIGATION_EXTERNAL;
    hand_off(target, "follow", url);
    return PORTAL_NAVIGATION_EMACS;
}

void portal_web_committed(portal_string target, portal_string url)
{
    struct portal_web_state *web;
    if (!find(target, &web))
        return;
    free(web->page.data);
    if (!copy(url, &web->page)) /* Unknown: the next load loads. */
        web->page = (portal_text) {0};
    web->generation++;
    if (web->hosted)
        queue_own(web, target, "page", "url", url);
}

void portal_web_failed(portal_string target, uint64_t token, portal_string message)
{
    struct portal_web_state *web;
    if (find(target, &web) && web->hosted && (!token || token == web->generation))
        queue_own(web, target, "error", "message", message);
}

portal_string portal_web_links_script(void)
{
    return (portal_string) {links_script, sizeof links_script - 1};
}
