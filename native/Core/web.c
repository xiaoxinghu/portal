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
   Every web view, hosted or not, has the core's "download" messages.

   Downloads.  A page asks to download a link, or gets a response the
   platform cannot show or that the server marks as an attachment, and the
   platform downloads it.  Each download goes to a new file in the directory
   Lisp chose: the name the server or page suggests, made safe, with " (1)",
   " (2)" and so on before its extension while a file or another download
   has it.  A "download" message tells Emacs when it starts, and when it
   finishes or fails.  Closing a view cancels its downloads; each keeps its
   name taken until the platform reports its end.

   Windows.  A page that is not a hosted app's may open windows, as
   window.open and links to target=_blank do: each is a new web view, which
   Emacs hears of with an "opened NEW OPENER" record and gives a buffer.  A
   window may close itself, as window.close does, which Emacs hears of with
   a "closed TARGET" record; no other view can.  Each page a window commits
   sends a "web TARGET" record, and no other until Emacs has inspected the
   view, so Emacs can name the window's buffer after the page it shows.

   Appearance.  A web view's pages see the system's appearance, following
   its changes, unless Lisp forces light or dark, at open or later for every
   web view at once.  The core checks the name; the platform shows it.

   Zoom.  Lisp gives hosts a level, and every page from a host shows at its
   level, in every view, as a browser remembers zoom per site: the pages on
   screen when Lisp sets it, and each page a view commits, whatever loaded
   it.  Pages without a host, such as files, share the host "".

   Camera and microphone.  A page asks to use them, and the core decides:
   a hosted app never may, and a page may use what the user has let its
   origin, and the origin of the frame that asks, use together since Emacs
   started, in any view.  The platform asks the user about anything else and
   reports each grant, which the core keeps until Emacs quits.  Refusals are
   not kept: the page may ask again.

   Finding.  The platform finds text its own way and reports when it is
   done.  Only the latest find in a view reports to Emacs, so a result that
   arrives after the user has typed on never answers the newer find.

   Generations.  Each commit starts a new generation.  A message the core
   posts to a page carries the generation it went to as its token, so a
   failed delivery that the platform reports after the page has gone is
   ignored.  A call for a closed view finds no target and is ignored too. */
#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

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
    uint64_t finds;              /* The token of the latest find, or 0. */
    int64_t zoom;                /* The level its pages show at now, in percent. */
    struct message *first, *last; /* Waiting messages, oldest first. */
    bool announced;              /* Whether a bridge record went out for them. */
    bool window;                 /* Whether a page opened it, as a new window. */
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
    return is(type, "page") || is(type, "follow") || is(type, "download");
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

/* Zoom. */

/* A host's level, in percent: any other than 100. */
struct zoom {
    struct zoom *next;
    int64_t percent;
    size_t length;
    char host[]; /* LENGTH bytes. */
};

static struct zoom *zooms; /* Newest first. */

/* The host of the page WEB committed last, or "" without one. */
static portal_string page_host(const struct portal_web_state *web)
{
    return web->page.data ? origin(borrow(web->page)).host : literal("");
}

static struct zoom **zoom_link(portal_string host)
{
    struct zoom **link = &zooms;
    while (*link && !same_ignoring_case((portal_string) {(*link)->host, (*link)->length}, host))
        link = &(*link)->next;
    return link;
}

/* HOST's level, in percent. */
static int64_t level(portal_string host)
{
    struct zoom *zoom = *zoom_link(host);
    return zoom ? zoom->percent : 100;
}

/* Show WEB's pages at PERCENT, unless they do already. */
static bool zoom_to(portal_view *native, struct portal_web_state *web, int64_t percent,
                    portal_text *error)
{
    if (web->zoom == percent)
        return true;
    if (!portal_web_set_zoom(native, (double) percent / 100, error))
        return false;
    web->zoom = percent;
    return true;
}

/* Give HOST the level PERCENT; 100 forgets it. */
static bool remember(portal_string host, int64_t percent, portal_text *error)
{
    struct zoom **link = zoom_link(host);
    if (*link && percent != 100) {
        (*link)->percent = percent;
    } else if (*link) {
        struct zoom *forgotten = *link;
        *link = forgotten->next;
        free(forgotten);
    } else if (percent != 100) {
        struct zoom *zoom = malloc(sizeof *zoom + host.length);
        if (!zoom)
            return out_of_memory(error);
        *zoom = (struct zoom) {.next = zooms, .percent = percent, .length = host.length};
        if (host.length)
            memcpy(zoom->host, host.data, host.length);
        zooms = zoom;
    }
    return true;
}

/* Camera and microphone. */

/* Devices the user let FRAME, in a page from ORIGIN, use. */
struct grant {
    struct grant *next;
    unsigned devices;
    portal_text origin, frame;
};

static struct grant *grants;

static struct grant *granted(portal_string origin, portal_string frame)
{
    struct grant *grant = grants;
    while (grant && !(same_origin(borrow(grant->origin), origin)
                      && same_origin(borrow(grant->frame), frame)))
        grant = grant->next;
    return grant;
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

/* Downloads. */

/* A download the platform runs, from its start until it reports the end,
   with its file's path from when the core chose it. */
struct download {
    struct download *next;
    uint64_t id;
    portal_text target, url, path;
};

static struct {
    portal_text directory; /* Where downloads go, or no data until Lisp says. */
    struct download *first; /* Running downloads. */
    uint64_t ids;           /* The last number given out. */
} downloads;

/* The longest name, in bytes, given to a download's file: below the 255 of
   common file systems, with room for a number. */
enum { NAME_LIMIT = 200, EXTENSION_LIMIT = 32 };

/* Tell Emacs, over TARGET's messages, that the download of URL to FILE is
   in STATE now, because of PROBLEM unless it is NULL. */
static void report(portal_string target, const char *state, portal_string url, portal_string file,
                   const portal_string *problem)
{
    struct portal_web_state *web;
    if (!find(target, &web))
        return;
    static const char head[] = "{\"type\":\"download\",\"state\":";
    struct json json = {0};
    put(&json, head, sizeof head - 1);
    put_string(&json, literal(state));
    put(&json, ",\"url\":", 7);
    put_string(&json, url);
    put(&json, ",\"file\":", 8);
    put_string(&json, file);
    if (problem) {
        put(&json, ",\"message\":", 11);
        put_string(&json, *problem);
    }
    put(&json, "}", 1);
    if (!json.failed)
        queue(web, target, false, json.data, json.length);
    free(json.data);
}

/* NAME as a file's name: without leading dots or spaces, which would hide
   it, with "_" in place of slashes and control characters, and "download"
   when nothing is left.  It is split into its STEM and its EXTENSION, from
   its last dot, and the stem is cut to fit NAME_LIMIT. */
static bool file_name(portal_string name, portal_text *stem, portal_string *extension)
{
    size_t start = 0;
    while (start < name.length && (name.data[start] == '.' || name.data[start] == ' '))
        start++;
    if (start == name.length) {
        name = literal("download");
        start = 0;
    }
    if (!copy((portal_string) {name.data + start, name.length - start}, stem))
        return false;
    for (size_t i = 0; i < stem->length; i++) {
        unsigned char c = (unsigned char) stem->data[i];
        if (c == '/' || c < 0x20 || c == 0x7f)
            stem->data[i] = '_';
    }
    const char *dot = NULL;
    for (size_t i = 1; i < stem->length; i++)
        if (stem->data[i] == '.')
            dot = stem->data + i;
    size_t length = dot ? (size_t) (stem->data + stem->length - dot) : 0;
    if (length > EXTENSION_LIMIT) {
        dot = NULL;
        length = 0;
    }
    *extension = (portal_string) {dot ? dot : "", length};
    size_t limit = NAME_LIMIT - length, end = stem->length - length;
    if (end > limit) /* Cut whole UTF-8 characters, before any continuation byte. */
        for (end = limit; end && ((unsigned char) stem->data[end] & 0xc0) == 0x80;)
            end--;
    stem->length = end;
    return true;
}

/* Whether a file or a running download has PATH.  A running download's
   file may not exist yet, so its name is compared ignoring case, as the
   default file systems of macOS and Windows do. */
static bool taken(const char *path)
{
    for (struct download *download = downloads.first; download; download = download->next)
        if (download->path.data && same_ignoring_case(borrow(download->path), literal(path)))
            return true;
    struct stat status;
    return !lstat(path, &status);
}

/* A new file's path, to free, for a download suggested to be called NAME:
   NULL with *PROBLEM set when there is none. */
static char *destination(portal_string name, portal_text *problem)
{
    portal_string directory = borrow(downloads.directory);
    struct stat status;
    if (!directory.data) {
        fail_with(problem, "Portal has no download directory");
        return NULL;
    }
    if (stat(directory.data, &status) || !S_ISDIR(status.st_mode)) {
        fail(problem, "No download directory ", directory);
        return NULL;
    }
    portal_text stem;
    portal_string extension;
    if (!file_name(name, &stem, &extension)) {
        out_of_memory(problem);
        return NULL;
    }
    bool slash = directory.data[directory.length - 1] == '/';
    size_t size = directory.length + 1 + stem.length + sizeof " (999)" + extension.length;
    char *path = malloc(size);
    if (path)
        fail(problem, "No free name for the file in ", directory);
    else
        out_of_memory(problem);
    for (unsigned number = 0; path && number < 1000; number++) {
        char suffix[sizeof " (999)"] = "";
        if (number)
            snprintf(suffix, sizeof suffix, " (%u)", number);
        snprintf(path, size, "%.*s%s%.*s%s%.*s", (int) directory.length, directory.data,
                 slash ? "" : "/", (int) stem.length, stem.data, suffix,
                 (int) extension.length, extension.data);
        if (!taken(path)) {
            free(stem.data);
            free(problem->data);
            *problem = (portal_text) {0};
            return path;
        }
    }
    free(stem.data);
    free(path);
    return NULL;
}

static void free_download(struct download *download)
{
    free(download->target.data);
    free(download->url.data);
    free(download->path.data);
    free(download);
}

bool portal_web_views_download_directory(portal_string directory, portal_text *error)
{
    if (!directory.length || directory.data[0] != '/'
        || memchr(directory.data, 0, directory.length))
        return fail(error, "The download directory must be an absolute path, not ", directory);
    portal_text copied;
    if (!copy(directory, &copied))
        return out_of_memory(error);
    free(downloads.directory.data);
    downloads.directory = copied;
    return true;
}

uint64_t portal_web_download_started(portal_string target, portal_string url)
{
    struct portal_web_state *web;
    struct download *started = find(target, &web) ? calloc(1, sizeof *started) : NULL;
    if (!started)
        return 0;
    if (!copy(target, &started->target) || !copy(url, &started->url)) {
        free_download(started);
        return 0;
    }
    started->id = ++downloads.ids;
    started->next = downloads.first;
    downloads.first = started;
    return started->id;
}

/* DOWNLOAD's entry, and the link to it in the list; NULL when there is none. */
static struct download **running(uint64_t download)
{
    struct download **link = &downloads.first;
    while (*link && (*link)->id != download)
        link = &(*link)->next;
    return *link ? link : NULL;
}

/* Remove DOWNLOAD from the running downloads, telling Emacs it is now in
   STATE, because of PROBLEM unless it is NULL. */
static void end(struct download **link, const char *state, const portal_string *problem)
{
    struct download *ended = *link;
    *link = ended->next;
    report(borrow(ended->target), state, borrow(ended->url),
           ended->path.data ? borrow(ended->path) : literal(""), problem);
    free_download(ended);
}

portal_string portal_web_download_destination(uint64_t download, portal_string name)
{
    struct download **link = running(download), *named = link ? *link : NULL;
    if (!named || named->path.data)
        return literal("");
    portal_text problem = {0};
    char *path = destination(name, &problem);
    if (!path) {
        portal_string why = problem.data ? borrow(problem) : literal("Portal is out of memory");
        end(link, "failed", &why);
        free(problem.data);
        return literal("");
    }
    named->path = (portal_text) {path, strlen(path)};
    report(borrow(named->target), "started", borrow(named->url), borrow(named->path), NULL);
    return borrow(named->path);
}

void portal_web_download_finished(uint64_t download, const portal_string *error)
{
    struct download **link = running(download);
    if (link)
        end(link, error ? "failed" : "finished", error);
}

/* Lifetime, for views.c. */

struct portal_web_state *portal_web_state_new(const portal_option *options, size_t count)
{
    struct portal_web_state *web = calloc(1, sizeof *web);
    if (!web)
        return NULL;
    web->generation = 1;
    web->zoom = 100;
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

struct rezoom {
    portal_string host;
    int64_t percent;
    portal_text *error;
};

static bool rezoom(portal_view *native, struct portal_web_state *web, void *context)
{
    struct rezoom *rezoom = context;
    return !same_ignoring_case(page_host(web), rezoom->host)
        || zoom_to(native, web, rezoom->percent, rezoom->error);
}

bool portal_web_views_zoom(portal_string host, int64_t percent, portal_text *error)
{
    if (percent < 25 || percent > 500)
        return fail_with(error, "Web zoom must be from 25 to 500 percent");
    struct rezoom context = {host, percent, error};
    return remember(host, percent, error) && portal_views_each_web(rezoom, &context);
}

bool portal_web_views_find(portal_string target, portal_string text, bool backward,
                           bool case_sensitive, portal_text *error)
{
    struct portal_web_state *web;
    portal_view *native = portal_views_find_web(target, &web, error);
    if (!native)
        return false;
    if (!text.length)
        return fail_with(error, "Nothing to find");
    /* The latest find from now, so that its result counts even if the
       platform reports it at once. */
    uint64_t token = ++web->finds;
    if (!portal_web_find(native, text, backward, case_sensitive, token, error)) {
        web->finds--;
        return false;
    }
    return true;
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
    if (!portal_views_find_web(target, &web, error))
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
                                        bool main_frame, bool download)
{
    if (download) /* Downloading leaves the page where it is. */
        return PORTAL_NAVIGATION_DOWNLOAD;
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

bool portal_web_window(portal_string target, void *request)
{
    struct portal_web_state *web, *window;
    portal_string opened;
    portal_view *native = find(target, &web);
    if (!native || web->hosted || !portal_views_open_window(native, request, &opened, &window))
        return false;
    window->window = true;
    if (portal_channel_send(literal("opened"), opened, &target, 1))
        return true;
    /* Emacs would never hear of it, so it never gets a buffer. */
    portal_text error = {0};
    portal_views_close(opened, &error);
    free(error.data);
    return false;
}

void portal_web_closed(portal_string target)
{
    struct portal_web_state *web;
    if (find(target, &web) && web->window)
        portal_channel_send(literal("closed"), target, NULL, 0);
}

portal_navigation portal_web_responding(portal_string target, bool showable, bool attachment)
{
    struct portal_web_state *web;
    return find(target, &web) && (!showable || attachment) ? PORTAL_NAVIGATION_DOWNLOAD
                                                           : PORTAL_NAVIGATION_ALLOW;
}

void portal_web_committed(portal_string target, portal_string url)
{
    struct portal_web_state *web;
    portal_view *native = find(target, &web);
    if (!native)
        return;
    free(web->page.data);
    if (!copy(url, &web->page)) /* Unknown: the next load loads. */
        web->page = (portal_text) {0};
    web->generation++;
    if (web->window)
        portal_views_announce(target, PORTAL_WEB, "web");
    /* No one to report a failure to: the page keeps its size. */
    portal_text error = {0};
    if (!zoom_to(native, web, level(page_host(web)), &error))
        free(error.data);
    if (web->hosted)
        queue_own(web, target, "page", "url", url);
}

void portal_web_failed(portal_string target, uint64_t token, portal_string message)
{
    struct portal_web_state *web;
    if (find(target, &web) && web->hosted && (!token || token == web->generation))
        queue_own(web, target, "error", "message", message);
}

void portal_web_found(portal_string target, uint64_t token, bool found)
{
    struct portal_web_state *web;
    if (find(target, &web) && token == web->finds) {
        portal_string matched = literal(found ? "1" : "0");
        portal_channel_send(literal("found"), target, &matched, 1);
    }
}

portal_permission portal_web_media(portal_string target, portal_string origin,
                                   portal_string frame, unsigned devices)
{
    struct portal_web_state *web;
    if (!find(target, &web) || web->hosted)
        return PORTAL_PERMISSION_DENY;
    struct grant *grant = granted(origin, frame);
    return grant && (grant->devices & devices) == devices ? PORTAL_PERMISSION_GRANT
                                                          : PORTAL_PERMISSION_ASK;
}

void portal_web_media_granted(portal_string target, portal_string origin, portal_string frame,
                              unsigned devices)
{
    struct portal_web_state *web;
    if (!find(target, &web) || web->hosted)
        return;
    struct grant *grant = granted(origin, frame);
    if (grant) {
        grant->devices |= devices;
        return;
    }
    /* Out of memory, the user is asked again. */
    if (!(grant = calloc(1, sizeof *grant)) || !copy(origin, &grant->origin)
        || !copy(frame, &grant->frame)) {
        if (grant)
            free(grant->origin.data);
        free(grant);
        return;
    }
    grant->devices = devices;
    grant->next = grants;
    grants = grant;
}

portal_string portal_web_links_script(void)
{
    return (portal_string) {links_script, sizeof links_script - 1};
}
