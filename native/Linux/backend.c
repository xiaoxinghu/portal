/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The Linux backend: the platform operations of native/Core/include/portal.h
   for an Emacs built with pgtk, on GTK3 and Wayland.  The top-level
   CMakeLists.txt links it with the C core into portal.so; macOS builds
   native/Backend.swift instead, and never compiles these files.  linux.h
   says which file has what.

   What is real:

   - Views and input (views.c, input.c): a view is a Wayland subsurface over
     its pane and an invisible GTK3 widget in the frame.
   - Terminals with a local shell (terminal.c, presenter.c): Ghostty's
     library, linked from Portal's own build of it, draws each one, and
     Portal shows its frames.  ghostty_start starts the library with the
     resources installed beside this module, and portal_terminal_engine
     describes it.
   - Fed terminals, which show a Rex block (terminal.c): Ghostty's
     host-managed surface, fed by a thread of Portal's, placed where the
     core's rules for it say (native/Core/fed.h).
   - Pages (web.c), WPE WebKit's, in portal-web.so, which this module opens
     at the first web view and links nothing of: loading a page, going
     through its history, and parsing a URL as WebKit spells it.
   - A test pattern (pattern.c), the content of a view made with the option
     :test-pattern, of either kind, which the checks of the view machinery
     use.
   - Timers, on GLib's main loop, which Emacs runs.
   - Message sockets, which carry Rex connections: the portable ones of
     native/Shared, told of on that loop.
   - portal_status_hide, which hides a panel that is never shown.

   What is not, and what each operation waits for: it fails, saying what
   Portal lacks on Linux, and changes nothing.

   - The other web primitives, which wait for portal.h's web primitives on
     WPE WebKit: the bridge, appearance, opacity, windows, finding, zoom
     and printing.
   - A web view where WPE WebKit is not installed, or the build had no
     web views: creating one fails, saying what to install.
   - System-wide keys, posted keys and the status panel, which Wayland gives
     a client no direct way to do.
   - The launcher, which rests on the NS build of Emacs and has no Linux
     plan.

   GTK3 is not a choice: this code runs inside Emacs's process, whose
   toolkit it is, and uses the GTK that Emacs has loaded and initialized.
   It never calls gtk_init. */
/* dladdr and realpath. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <locale.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <gdk/gdkwayland.h>
#include <ghostty.h>

#include "linux-dmabuf-v1-client-protocol.h"
#include "message-socket.h"
#include "web.h"
#include "viewporter-client-protocol.h"

bool portal_linux_fail(portal_text *error, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    char *data = length < 0 ? NULL : malloc((size_t) length + 1);
    if (data) {
        va_start(arguments, format);
        vsnprintf(data, (size_t) length + 1, format, arguments);
        va_end(arguments);
        *error = (portal_text) {data, (size_t) length};
    }
    return false;
}

/* The compositor's globals, as the registry announces them. */
static void announce(void *data, struct wl_registry *registry, uint32_t name,
                     const char *interface, uint32_t version)
{
    struct portal_wayland *wayland = data;
    /* Version 4 of the compositor has damage in buffer pixels. */
    if (!strcmp(interface, wl_compositor_interface.name) && version >= 4)
        wayland->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, wl_subcompositor_interface.name))
        wayland->subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
    else if (!strcmp(interface, wp_viewporter_interface.name))
        wayland->viewporter = wl_registry_bind(registry, name, &wp_viewporter_interface, 1);
    else if (!strcmp(interface, wl_shm_interface.name))
        wayland->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    /* Version 3 has the modifiers and the import without a round trip. */
    else if (!strcmp(interface, zwp_linux_dmabuf_v1_interface.name) && version >= 3)
        wayland->dmabuf = wl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface, 3);
    /* Hyprland announces protocols of its own; no other compositor names
       one so. */
    else if (!strncmp(interface, "hyprland_", strlen("hyprland_")))
        wayland->crops_buffer = true;
}

/* The formats wl_shm takes, which it announces once it is bound.  DATA is
   static: the proxy outlives the binding, on GDK's queue. */
static void shm_format(void *data, struct wl_shm *shm, uint32_t format)
{
    (void) shm;
    if (format == WL_SHM_FORMAT_ABGR8888)
        *(bool *) data = true;
}

static const struct wl_shm_listener shm_listener = {shm_format};

static void withdraw(void *data, struct wl_registry *registry, uint32_t name)
{
    (void) data, (void) registry, (void) name;
}

static const struct wl_registry_listener registry_listener = {announce, withdraw};

const struct portal_wayland *portal_linux_wayland(portal_text *error)
{
    static struct portal_wayland wayland;
    /* The display its pgtk frames are on, which GDK opened for Emacs: none
       in batch Emacs or on a text terminal, and not Wayland when GDK runs
       pgtk on X11. */
    GdkDisplay *display = gdk_display_get_default();
    if (!display) {
        portal_linux_fail(error, "Portal's native views need a graphical Emacs frame; "
                                 "this Emacs has opened no display");
        return NULL;
    }
    if (!GDK_IS_WAYLAND_DISPLAY(display)) {
        portal_linux_fail(error, "Portal's native views need Emacs on Wayland; this display is a %s",
                          G_OBJECT_TYPE_NAME(display));
        return NULL;
    }
    struct wl_display *connection = gdk_wayland_display_get_wl_display(display);
    if (wayland.display == connection)
        return &wayland;
    if (wayland.display) {
        portal_linux_fail(error, "Portal's native views are on another display of this Emacs");
        return NULL;
    }
    /* Ask on a queue of the backend's own, so that nothing of GDK's is
       dispatched here, then hand what was bound to the default queue: GDK
       dispatches that one, and drops the events of proxies with no
       listener, such as a wl_shm's formats.  The second round trip takes
       the events the binds caused off the queue before it goes. */
    struct portal_wayland found = {.display = connection};
    struct wl_event_queue *queue = wl_display_create_queue(connection);
    struct wl_display *wrapped = wl_proxy_create_wrapper(connection);
    wl_proxy_set_queue((struct wl_proxy *) wrapped, queue);
    struct wl_registry *registry = wl_display_get_registry(wrapped);
    wl_proxy_wrapper_destroy(wrapped);
    wl_registry_add_listener(registry, &registry_listener, &found);
    static bool abgr;
    bool answered = wl_display_roundtrip_queue(connection, queue) >= 0;
    if (found.shm)
        wl_shm_add_listener(found.shm, &shm_listener, &abgr);
    answered = answered && wl_display_roundtrip_queue(connection, queue) >= 0;
    found.shm_abgr = abgr;
    struct wl_proxy *bound[] = {(struct wl_proxy *) found.compositor,
                                (struct wl_proxy *) found.subcompositor,
                                (struct wl_proxy *) found.viewporter,
                                (struct wl_proxy *) found.shm};
    bool complete = answered;
    for (size_t i = 0; i < sizeof bound / sizeof *bound; i++) {
        if (bound[i])
            wl_proxy_set_queue(bound[i], NULL);
        else
            complete = false;
    }
    /* Not needed: without it, terminals show their frames from memory. */
    if (found.dmabuf)
        wl_proxy_set_queue((struct wl_proxy *) found.dmabuf, NULL);
    wl_registry_destroy(registry);
    wl_event_queue_destroy(queue);
    if (!complete) {
        if (found.dmabuf)
            zwp_linux_dmabuf_v1_destroy(found.dmabuf);
        for (size_t i = 0; i < sizeof bound / sizeof *bound; i++)
            if (bound[i])
                wl_proxy_destroy(bound[i]);
        portal_linux_fail(error, "Portal's native views need a Wayland compositor with "
                                 "wl_compositor 4, wl_subcompositor, wp_viewporter and wl_shm");
        return NULL;
    }
    wayland = found;
    return &wayland;
}

/* A copy of the text FORMAT makes, allocated with malloc, or NULL. */
static char *text_of(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    char *text = length < 0 ? NULL : malloc((size_t) length + 1);
    if (text) {
        va_start(arguments, format);
        vsnprintf(text, (size_t) length + 1, format, arguments);
        va_end(arguments);
    }
    return text;
}

/* Whether PATH, in DIRECTORY, is a directory. */
static bool has_directory(const char *directory, const char *path)
{
    char *name = text_of("%s/%s", directory, path);
    struct stat status;
    bool found = name && !stat(name, &status) && S_ISDIR(status.st_mode);
    free(name);
    return found;
}

/* Ghostty's resources, as the build installs them beside this module: the
   shell integration and themes in ghostty-linux/share/ghostty, which
   GHOSTTY_RESOURCES_DIR names, and the terminfo database in share/terminfo
   beside it, where Ghostty looks for it.  An installed Portal keeps that
   directory with the module, as the macOS bundle keeps them inside itself.
   Return the directory, allocated with malloc, or NULL with *ERROR set. */
static char *ghostty_resources(portal_text *error)
{
    Dl_info info;
    char *module = NULL;
    if (!dladdr((void *) ghostty_resources, &info) || !info.dli_fname ||
        !(module = realpath(info.dli_fname, NULL))) {
        portal_linux_fail(error, "Portal cannot find where its module is installed");
        return NULL;
    }
    *strrchr(module, '/') = '\0';
    char *directory = text_of("%s/ghostty-linux/share/ghostty", module);
    free(module);
    if (!directory)
        portal_linux_fail(error, "Portal is out of memory");
    else if (!has_directory(directory, "shell-integration") ||
             !has_directory(directory, "../terminfo")) {
        portal_linux_fail(error, "Portal's build lacks Ghostty's resources in %s: build Portal again",
             directory);
        free(directory);
        directory = NULL;
    }
    return directory;
}

/* Start Ghostty's library with Portal's own resources; set *RESOURCES to
   their directory, which GHOSTTY_RESOURCES_DIR now names.

   Ghostty's start changes the whole process, which is Emacs's: it ignores
   SIGPIPE, raises the limit of open files and sets the locale from the
   environment.  The locale is put back, since Emacs keeps LC_NUMERIC at
   "C" for its printing of numbers; the rest stays.  So batch Emacs, which
   does not ignore SIGPIPE itself, does from then on. */
static bool ghostty_open(char **resources, portal_text *error)
{
    char *directory = ghostty_resources(error);
    if (!directory)
        return false;
    /* Ghostty reads it as it starts, and then looks nowhere else: nothing of
       an installed Ghostty is used.  Emacs's process-environment, which its
       own subprocesses get, is not changed. */
    if (setenv("GHOSTTY_RESOURCES_DIR", directory, 1)) {
        free(directory);
        return portal_linux_fail(error, "Portal cannot set GHOSTTY_RESOURCES_DIR");
    }
    /* Emacs's arguments are not Ghostty's: one such as +10, a line number to
       Emacs, would read as an action, and fail the start. */
    char *locale = text_of("%s", setlocale(LC_ALL, NULL));
    char program[] = "portal", *arguments[] = {program, NULL};
    int status = ghostty_init(1, arguments);
    if (locale)
        setlocale(LC_ALL, locale);
    free(locale);
    if (status) {
        free(directory);
        return portal_linux_fail(error, "Ghostty's library failed to start");
    }
    *resources = directory;
    return true;
}

/* Ghostty's library once started, or why it could not start.  Only Emacs's
   main thread starts it, from a module function, so it needs no lock. */
static struct {
    bool tried;
    char *resources; /* GHOSTTY_RESOURCES_DIR, once started. */
    portal_text failure; /* Why it did not start. */
} ghostty;

/* Start Ghostty's library, once.  After a failed start, fail each time with
   the same message: Ghostty's global state is never started twice. */
static bool ghostty_start(portal_text *error)
{
    if (!ghostty.tried) {
        ghostty.tried = true;
        ghostty_open(&ghostty.resources, &ghostty.failure);
    }
    return ghostty.resources ||
           portal_linux_fail(error, "%s", ghostty.failure.data ? ghostty.failure.data : "Portal is out of memory");
}

bool portal_linux_ghostty_start(const char **resources, portal_text *error)
{
    if (!ghostty_start(error))
        return false;
    *resources = ghostty.resources;
    return true;
}

/* TEXT, LENGTH bytes, as a JSON string allocated with malloc, or NULL. */
static char *json_string(const char *text, size_t length)
{
    /* Each byte escaped at most as \u00XX, two quotes and a NUL. */
    char *json = malloc(6 * length + 3), *end = json;
    if (!json)
        return NULL;
    *end++ = '"';
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char) text[i];
        if (c == '"' || c == '\\') {
            *end++ = '\\';
            *end++ = (char) c;
        } else if (c < 0x20) {
            end += snprintf(end, 7, "\\u%04x", c);
        } else {
            *end++ = (char) c;
        }
    }
    *end++ = '"';
    *end = '\0';
    return json;
}

bool portal_terminal_engine(portal_text *json, portal_text *error)
{
    if (!ghostty_start(error))
        return false;
    ghostty_info_s info = ghostty_info();
    const char *mode = info.build_mode == GHOSTTY_BUILD_MODE_DEBUG          ? "Debug"
                       : info.build_mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE ? "ReleaseSafe"
                       : info.build_mode == GHOSTTY_BUILD_MODE_RELEASE_FAST ? "ReleaseFast"
                                                                            : "ReleaseSmall";
    char *version = json_string(info.version, info.version_len);
    char *resources = json_string(ghostty.resources, strlen(ghostty.resources));
    char *text = version && resources
                     ? text_of("{\"engine\":\"ghostty\",\"version\":%s,\"mode\":\"%s\","
                               "\"resources\":%s}",
                               version, mode, resources)
                     : NULL;
    free(version);
    free(resources);
    if (!text)
        return portal_linux_fail(error, "Portal is out of memory");
    *json = (portal_text) {text, strlen(text)};
    return true;
}

/* What each group of operations says until it is written. */
static bool no_launcher(portal_text *error)
{
    return portal_linux_fail(error, "Portal's launcher needs the macOS build of Emacs");
}

static bool no_system_keys(portal_text *error)
{
    return portal_linux_fail(error, "Portal has no system-wide keys on Linux yet");
}

static bool no_status(portal_text *error)
{
    return portal_linux_fail(error, "Portal has no status panel on Linux yet");
}

static const struct portal_web_object *web_open(portal_text *error);

/* The content of a new view: a terminal, a page, or a test pattern of
   either kind, where the kind still decides what the core does with the
   view's keys. */
bool portal_linux_content_create(struct portal_view *view, const portal_option *options,
                                 size_t count, portal_text *error)
{
    bool pattern = false;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "test-pattern"))
            pattern = options[i].is_string || options[i].flag;
    if (pattern)
        return portal_linux_pattern_create(view, options, count, error);
    if (view->kind == PORTAL_TERMINAL)
        return portal_linux_terminal_create(view, options, count, error);
    const struct portal_web_object *object = web_open(error);
    return object && object->create(view, options, count, error);
}

/* The launcher. */

bool portal_launcher_attach(portal_string title, portal_text *error)
{
    (void) title;
    return no_launcher(error);
}

bool portal_launcher_prepare(portal_text *error)
{
    return no_launcher(error);
}

bool portal_launcher_show(int64_t width, int64_t height, int64_t dx, int64_t dy, int64_t screen,
                          bool shadow, int64_t radius, portal_text *error)
{
    (void) width, (void) height, (void) dx, (void) dy, (void) screen, (void) shadow,
        (void) radius;
    return no_launcher(error);
}

bool portal_launcher_fit(uint64_t session, int64_t height, portal_text *error)
{
    (void) session, (void) height;
    return no_launcher(error);
}

bool portal_launcher_hide(bool restore_focus, portal_text *error)
{
    (void) restore_focus;
    return no_launcher(error);
}

bool portal_launcher_detach(portal_text *error)
{
    return no_launcher(error);
}

bool portal_launcher_describe(portal_text *state, portal_text *error)
{
    (void) state;
    return no_launcher(error);
}

/* Web views.  A page is WPE WebKit's, in portal-web.so (web.h, web.c),
   opened at the first web view: this module links nothing of WPE WebKit,
   so that it loads and runs terminals where WPE WebKit is not installed.
   The object is found beside this module, as Ghostty's resources are; the
   build makes it where WPE WebKit's development files are, and an install
   without it has no web views.  What the object needs of this module it is
   given (web_host): it links nothing of it either, which keeps every
   symbol but Emacs's entry points inside each. */

/* WPE WebKit's library, by its soname, and what to install for it. */
static const char wpe_library[] = "libWPEWebKit-2.0.so.1";
#define PORTAL_WPE_RUNTIME                                                                   \
    "WPE WebKit 2.0 with its WPEPlatform API, libWPEWebKit-2.0.so.1, such as Arch's "       \
    "wpewebkit"
#define PORTAL_WPE_PACKAGES                                                                  \
    "pkg-config's wpe-webkit-2.0 and wpe-platform-2.0, such as Arch's wpewebkit"

static bool host_fail(portal_text *error, const char *message)
{
    return portal_linux_fail(error, "%s", message);
}

static const struct portal_web_host web_host = {
    .interface = PORTAL_WEB_INTERFACE,
    .fail = host_fail,
    .view_find = portal_linux_view_find,
    .input_settle = portal_linux_input_settle,
    .input_cursor = portal_linux_input_cursor,
    .stage_new = portal_linux_stage_new,
    .stage_ready = portal_linux_stage_ready,
    .stage_start = portal_linux_stage_start,
    .stage_configure = portal_linux_stage_configure,
    .stage_frame = portal_linux_stage_frame,
    .stage_stop = portal_linux_stage_stop,
    .stage_free = portal_linux_stage_free,
    .stage_describe = portal_linux_stage_describe,
    .dmabufs_refused = portal_linux_dmabufs_refused,
    .committed = portal_web_committed,
    .moved = portal_web_moved,
    .failed = portal_web_failed,
};

/* JavaScriptCore stops threads for its collector with a signal, SIGUSR1
   unless told another, and takes the signal's handler over from the
   process.  Emacs binds SIGUSR1 to its sigusr1 event: one sent to Emacs
   with a page open crashed it.  So JavaScriptCore is told one that nothing
   of Emacs's uses, before it starts, unless the environment names one. */
static void jsc_signal(void)
{
    char number[16];
    snprintf(number, sizeof number, "%d", SIGRTMIN + 6);
    setenv("JSC_SIGNAL_FOR_GC", number, 0);
}

/* The page's object, once opened.  Only Emacs's main thread opens it. */
static const struct portal_web_object *web_object;

/* Open portal-web.so, beside this module, the first time; or fail saying
   what to install.  A failure is not kept: WPE WebKit may be installed
   while Emacs runs. */
static const struct portal_web_object *web_open(portal_text *error)
{
    if (web_object)
        return web_object;
    Dl_info info;
    char *module = NULL;
    if (!dladdr((void *) web_open, &info) || !info.dli_fname ||
        !(module = realpath(info.dli_fname, NULL))) {
        portal_linux_fail(error, "Portal cannot find where its module is installed");
        return NULL;
    }
    *strrchr(module, '/') = '\0';
    char *path = text_of("%s/portal-web.so", module);
    free(module);
    if (!path) {
        portal_linux_fail(error, "Portal is out of memory");
        return NULL;
    }
    struct stat status;
    if (stat(path, &status)) {
        portal_linux_fail(error,
                          "This build of Portal has no web views: build it again where WPE "
                          "WebKit's development files are installed (%s)",
                          PORTAL_WPE_PACKAGES);
        free(path);
        return NULL;
    }
    jsc_signal();
    void *wpe = dlopen(wpe_library, RTLD_NOW | RTLD_LOCAL);
    if (!wpe) {
        portal_linux_fail(error, "Web views on Linux need WPE WebKit, which is not installed: "
                                 "install %s",
                          PORTAL_WPE_RUNTIME);
        free(path);
        return NULL;
    }
    void *object = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    free(path);
    portal_web_object_open_function *open =
        object ? (portal_web_object_open_function *) dlsym(object, "portal_web_object_open")
               : NULL;
    if (!open) {
        portal_linux_fail(error, "Portal's web views could not start: %s", dlerror());
        if (object)
            dlclose(object);
        dlclose(wpe);
        return NULL;
    }
    char *failure = NULL;
    web_object = open(&web_host, &failure);
    if (!web_object) {
        portal_linux_fail(error, "%s", failure ? failure : "Portal is out of memory");
        free(failure);
    }
    /* Neither is ever closed: WebKit's threads and types stay. */
    return web_object;
}

/* WEB's page, or NULL with *ERROR set for a web view that shows none, a
   test pattern. */
static const struct portal_web_object *page_of(portal_view *web, portal_text *error)
{
    if (web_object && web_object->is_page(web))
        return web_object;
    portal_linux_fail(error, "This web view shows a test pattern, not a page");
    return NULL;
}

bool portal_web_load(portal_view *web, portal_string url, portal_text *error)
{
    const struct portal_web_object *object = page_of(web, error);
    return object && object->load(web, url, error);
}

/* URL as WebKit spells it, with GLib's parser: the scheme and an ASCII host
   in lower case, a Unicode host in punycode, a scheme's default port left
   out, dot segments removed, and spaces and other bytes no URL holds
   percent-encoded. */
bool portal_web_parse_url(portal_string url, portal_text *parsed, portal_text *error)
{
    char *text = g_strndup(url.data, url.length);
    GError *failure = NULL;
    GUri *uri = memchr(url.data, 0, url.length)
                    ? NULL
                    : g_uri_parse(text, G_URI_FLAGS_ENCODED | G_URI_FLAGS_SCHEME_NORMALIZE |
                                            G_URI_FLAGS_PARSE_RELAXED,
                                  &failure);
    g_free(text);
    if (!uri) {
        bool failed = portal_linux_fail(error, "Not a URL: %s",
                                        failure ? failure->message : "it holds a NUL");
        if (failure)
            g_error_free(failure);
        return failed;
    }
    const char *host = g_uri_get_host(uri);
    char *lower = host ? g_ascii_strdown(host, -1) : NULL;
    GUri *spelled = lower ? g_uri_build(g_uri_get_flags(uri), g_uri_get_scheme(uri),
                                        g_uri_get_userinfo(uri), lower, g_uri_get_port(uri),
                                        g_uri_get_path(uri), g_uri_get_query(uri),
                                        g_uri_get_fragment(uri))
                          : g_uri_ref(uri);
    char *string = g_uri_to_string(spelled);
    g_free(lower);
    g_uri_unref(spelled);
    g_uri_unref(uri);
    char *copy = string ? strdup(string) : NULL;
    g_free(string);
    if (!copy)
        return portal_linux_fail(error, "Portal is out of memory");
    *parsed = (portal_text) {copy, strlen(copy)};
    return true;
}

bool portal_web_go(portal_view *web, portal_history step, portal_text *error)
{
    const struct portal_web_object *object = page_of(web, error);
    return object && object->go(web, step, error);
}

/* The rest wait for portal.h's web primitives on WPE WebKit. */

static bool no_web(portal_text *error)
{
    return portal_linux_fail(error, "Portal's web views on Linux cannot do this yet");
}

bool portal_web_post(portal_view *web, portal_string json, uint64_t token, portal_text *error)
{
    (void) web, (void) json, (void) token;
    return no_web(error);
}

bool portal_web_set_appearance(portal_view *web, portal_appearance appearance,
                               portal_text *error)
{
    (void) web, (void) appearance;
    return no_web(error);
}

bool portal_web_set_opacity(portal_view *web, double opacity, portal_text *error)
{
    (void) web, (void) opacity;
    return no_web(error);
}

bool portal_web_create_window(portal_view *opener, portal_string target, void *request,
                              portal_view **view, portal_text *error)
{
    (void) opener, (void) target, (void) request, (void) view;
    return no_web(error);
}

bool portal_web_find(portal_view *web, portal_string text, bool backward, bool case_sensitive,
                     uint64_t token, portal_text *error)
{
    (void) web, (void) text, (void) backward, (void) case_sensitive, (void) token;
    return no_web(error);
}

bool portal_web_find_done(portal_view *web, portal_text *error)
{
    (void) web;
    return no_web(error);
}

bool portal_web_set_zoom(portal_view *web, double factor, portal_text *error)
{
    (void) web, (void) factor;
    return no_web(error);
}

bool portal_web_print(portal_view *web, const portal_string *file, portal_text *error)
{
    (void) web, (void) file;
    return no_web(error);
}

/* Message sockets, which carry the core's Rex connections: the portable
   ones of native/Shared/message-socket.c.  What is this backend's own is
   the way from a socket's thread to the module thread: GLib's default main
   context, which Emacs dispatches whenever it waits for or polls input in a
   graphical session.  Batch Emacs runs no such loop, so there the core is
   never told that a socket has something to read, and its caller waits for
   each message with portal_socket_wait. */
static gboolean socket_ready(gpointer data)
{
    portal_socket_ready(*(uint64_t *) data);
    return G_SOURCE_REMOVE;
}

/* On the socket's thread: g_idle_add_full may be called from any. */
static void socket_wake(uint64_t socket, void *context)
{
    (void) context;
    uint64_t *copy = g_new(uint64_t, 1);
    *copy = socket;
    g_idle_add_full(G_PRIORITY_DEFAULT, socket_ready, copy, g_free);
}

bool portal_socket_open(uint64_t socket, portal_string path, portal_string resource,
                        portal_string protocol, bool binary, portal_text *error)
{
    return portal_message_socket_open(socket, path, resource, protocol, binary, socket_wake, NULL,
                                      error);
}

bool portal_socket_send(uint64_t socket, portal_string text, portal_text *error)
{
    return portal_message_socket_send(socket, text, error);
}

bool portal_socket_read(uint64_t socket, portal_text **messages, size_t *count, bool *ended,
                        int *code, portal_text *reason, portal_text *error)
{
    return portal_message_socket_read(socket, messages, count, ended, code, reason, error);
}

bool portal_socket_wait(uint64_t socket, uint64_t milliseconds, bool *ready, portal_text *error)
{
    return portal_message_socket_wait(socket, milliseconds, ready, error);
}

bool portal_socket_close(uint64_t socket, portal_text *error)
{
    return portal_message_socket_close(socket, error);
}

/* Timers, on GLib's default main context, which Emacs dispatches whenever
   it waits for or polls input in a graphical session.  Batch Emacs runs no
   such loop, so a timer started there never fires. */
static gboolean timer_fired(gpointer data)
{
    portal_timer_fired(*(uint64_t *) data);
    return G_SOURCE_REMOVE;
}

void portal_timer_start(uint64_t token, uint64_t milliseconds)
{
    uint64_t *copy = g_new(uint64_t, 1);
    *copy = token;
    g_timeout_add_full(G_PRIORITY_DEFAULT,
                       milliseconds > G_MAXUINT ? G_MAXUINT : (guint) milliseconds,
                       timer_fired, copy, g_free);
}

/* System-wide keys. */

bool portal_hotkey_register(uint64_t hotkey, uint32_t key, uint32_t modifiers,
                            portal_text *error)
{
    (void) hotkey, (void) key, (void) modifiers;
    return no_system_keys(error);
}

bool portal_hotkey_unregister(uint64_t hotkey, portal_text *error)
{
    (void) hotkey;
    return no_system_keys(error);
}

bool portal_key_post(uint32_t key, uint32_t modifiers, portal_text *error)
{
    (void) key, (void) modifiers;
    return no_system_keys(error);
}

/* Screens and the status panel. */

bool portal_screens(portal_screen **screens, size_t *count, portal_text *error)
{
    (void) screens, (void) count;
    return no_status(error);
}

bool portal_status_measure(portal_string text, portal_status_tone tone, int64_t width,
                           int64_t lines, int64_t *fitted_width, int64_t *height,
                           portal_text *error)
{
    (void) text, (void) tone, (void) width, (void) lines, (void) fitted_width, (void) height;
    return no_status(error);
}

bool portal_status_show(portal_string text, portal_status_tone tone, portal_rect rect,
                        int64_t lines, portal_text *error)
{
    (void) text, (void) tone, (void) rect, (void) lines;
    return no_status(error);
}

bool portal_status_hide(portal_text *error)
{
    (void) error;
    /* Hiding a panel that is hidden does nothing, and none is ever shown. */
    return true;
}
