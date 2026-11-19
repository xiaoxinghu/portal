/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The Linux backend: the platform operations of native/Core/include/portal.h
   for an Emacs built with pgtk, on GTK3 and Wayland.  The top-level
   CMakeLists.txt links it with the C core into portal.so; macOS builds
   native/Backend.swift instead, and never compiles this file.

   So far it is the module's shape and nothing more: an operation fails,
   saying what Portal lacks on Linux, and changes nothing.  The module
   builds, loads, and answers what the core answers by itself, such as
   portal--shortcuts and portal--input-escape-key.  What is real:

   - wayland_display, which finds the display Emacs opened and refuses any
     other kind.  Creating a view asks it first, so that failure already
     tells an Emacs that could never show a view from one that only waits
     for views to be written.
   - ghostty_start, which starts Ghostty's library, linked from Portal's own
     build of it, with the resources installed beside this module; and
     portal_terminal_engine, which describes it.
   - portal_status_hide, which hides a panel that is never shown.

   What is not, and what each operation waits for:

   - Views and input, on a Wayland subsurface and a GTK3 widget in the
     frame.  Timers come with them: portal_timer_start starts none here, so
     nothing the core schedules ever runs.  Nothing can schedule yet, as
     only views and connections do.
   - Terminals, on the Ghostty that ghostty_start starts, and web views,
     on WebKitGTK.
   - Message sockets, which carry Rex connections.
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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <gdk/gdk.h>
#include <gdk/gdkwayland.h>
#include <ghostty.h>
#include <wayland-client.h>

#include "portal.h"

/* Fail with the formatted message, for a Lisp `error' signal.  Without
   memory for it, leave *ERROR unset. */
static bool fail(portal_text *error, const char *format, ...)
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

/* The Wayland display of the Emacs this module is loaded in: the one its
   pgtk frames are on, which GDK opened for Emacs.  Fails for an Emacs with
   no display, such as batch Emacs or one on a text terminal, and for a
   display that is not Wayland, as when GDK runs pgtk on X11. */
static struct wl_display *wayland_display(portal_text *error)
{
    GdkDisplay *display = gdk_display_get_default();
    if (!display) {
        fail(error, "Portal's native views need a graphical Emacs frame; "
                    "this Emacs has opened no display");
        return NULL;
    }
    if (!GDK_IS_WAYLAND_DISPLAY(display)) {
        fail(error, "Portal's native views need Emacs on Wayland; this display is a %s",
             G_OBJECT_TYPE_NAME(display));
        return NULL;
    }
    return gdk_wayland_display_get_wl_display(display);
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
        fail(error, "Portal cannot find where its module is installed");
        return NULL;
    }
    *strrchr(module, '/') = '\0';
    char *directory = text_of("%s/ghostty-linux/share/ghostty", module);
    free(module);
    if (!directory)
        fail(error, "Portal is out of memory");
    else if (!has_directory(directory, "shell-integration") ||
             !has_directory(directory, "../terminfo")) {
        fail(error, "Portal's build lacks Ghostty's resources in %s: build Portal again",
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
        return fail(error, "Portal cannot set GHOSTTY_RESOURCES_DIR");
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
        return fail(error, "Ghostty's library failed to start");
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
           fail(error, "%s", ghostty.failure.data ? ghostty.failure.data : "Portal is out of memory");
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
        return fail(error, "Portal is out of memory");
    *json = (portal_text) {text, strlen(text)};
    return true;
}

/* What each group of operations says until it is written. */
static bool no_views(portal_text *error)
{
    return fail(error, "Portal has no native views on Linux yet");
}

static bool no_launcher(portal_text *error)
{
    return fail(error, "Portal's launcher needs the macOS build of Emacs");
}

static bool no_sockets(portal_text *error)
{
    return fail(error, "Portal has no Rex connections on Linux yet");
}

static bool no_system_keys(portal_text *error)
{
    return fail(error, "Portal has no system-wide keys on Linux yet");
}

static bool no_status(portal_text *error)
{
    return fail(error, "Portal has no status panel on Linux yet");
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

/* Views.  No view is ever created, so the core never has one to pass to the
   operations that take a view: they fail all the same, should one arrive. */

bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **view, portal_text *error)
{
    (void) kind, (void) target, (void) options, (void) count, (void) view;
    return wayland_display(error) && no_views(error);
}

bool portal_view_destroy(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_attach(portal_view *view, portal_string frame, portal_rect rect,
                        portal_text *error)
{
    (void) view, (void) frame, (void) rect;
    return no_views(error);
}

bool portal_view_detach(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error)
{
    (void) view, (void) state;
    return no_views(error);
}

/* Web views. */

bool portal_web_load(portal_view *web, portal_string url, portal_text *error)
{
    (void) web, (void) url;
    return no_views(error);
}

bool portal_web_parse_url(portal_string url, portal_text *parsed, portal_text *error)
{
    (void) url, (void) parsed;
    return no_views(error);
}

bool portal_web_go(portal_view *web, portal_history step, portal_text *error)
{
    (void) web, (void) step;
    return no_views(error);
}

bool portal_web_post(portal_view *web, portal_string json, uint64_t token, portal_text *error)
{
    (void) web, (void) json, (void) token;
    return no_views(error);
}

bool portal_web_set_appearance(portal_view *web, portal_appearance appearance,
                               portal_text *error)
{
    (void) web, (void) appearance;
    return no_views(error);
}

bool portal_web_set_opacity(portal_view *web, double opacity, portal_text *error)
{
    (void) web, (void) opacity;
    return no_views(error);
}

bool portal_web_create_window(portal_view *opener, portal_string target, void *request,
                              portal_view **view, portal_text *error)
{
    (void) opener, (void) target, (void) request, (void) view;
    return no_views(error);
}

bool portal_web_find(portal_view *web, portal_string text, bool backward, bool case_sensitive,
                     uint64_t token, portal_text *error)
{
    (void) web, (void) text, (void) backward, (void) case_sensitive, (void) token;
    return no_views(error);
}

bool portal_web_find_done(portal_view *web, portal_text *error)
{
    (void) web;
    return no_views(error);
}

bool portal_web_set_zoom(portal_view *web, double factor, portal_text *error)
{
    (void) web, (void) factor;
    return no_views(error);
}

bool portal_web_print(portal_view *web, const portal_string *file, portal_text *error)
{
    (void) web, (void) file;
    return no_views(error);
}

/* Terminal views. */

bool portal_terminal_list_themes(portal_text **names, size_t *count, portal_text *error)
{
    (void) names, (void) count;
    return no_views(error);
}

bool portal_terminal_apply_theme(portal_view *terminal, const portal_string *name,
                                 portal_text *error)
{
    (void) terminal, (void) name;
    return no_views(error);
}

bool portal_terminal_set_opacity(portal_view *terminal, double opacity, portal_text *error)
{
    (void) terminal, (void) opacity;
    return no_views(error);
}

bool portal_terminal_set_text_size(portal_view *terminal, double points, portal_text *error)
{
    (void) terminal, (void) points;
    return no_views(error);
}

bool portal_terminal_paste_text(portal_view *terminal, portal_string text, portal_text *error)
{
    (void) terminal, (void) text;
    return no_views(error);
}

bool portal_terminal_press_enter(portal_view *terminal, portal_text *error)
{
    (void) terminal;
    return no_views(error);
}

bool portal_terminal_read_text(portal_view *terminal, portal_text *text, portal_text *error)
{
    (void) terminal, (void) text;
    return no_views(error);
}

bool portal_terminal_feed(portal_view *terminal, const char *bytes, size_t length,
                          portal_text *error)
{
    (void) terminal, (void) bytes, (void) length;
    return no_views(error);
}

bool portal_terminal_hold_grid(portal_view *terminal, uint32_t columns, uint32_t rows,
                               portal_text *error)
{
    (void) terminal, (void) columns, (void) rows;
    return no_views(error);
}

/* Input. */

bool portal_view_focus(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_unfocus(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_replay(portal_view *view, bool replay, portal_text *error)
{
    (void) view, (void) replay;
    return no_views(error);
}

bool portal_view_literal(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_copy(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

bool portal_view_paste(portal_view *view, portal_text *error)
{
    (void) view;
    return no_views(error);
}

/* Message sockets.  Open fails, so the core has no socket to send on, read,
   wait for or close. */

bool portal_socket_open(uint64_t socket, portal_string path, portal_string resource,
                        portal_string protocol, bool binary, portal_text *error)
{
    (void) socket, (void) path, (void) resource, (void) protocol, (void) binary;
    return no_sockets(error);
}

bool portal_socket_send(uint64_t socket, portal_string text, portal_text *error)
{
    (void) socket, (void) text;
    return no_sockets(error);
}

bool portal_socket_read(uint64_t socket, portal_text **messages, size_t *count, bool *ended,
                        int *code, portal_text *reason, portal_text *error)
{
    (void) socket, (void) messages, (void) count, (void) ended, (void) code, (void) reason;
    return no_sockets(error);
}

bool portal_socket_wait(uint64_t socket, uint64_t milliseconds, bool *ready, portal_text *error)
{
    (void) socket, (void) milliseconds, (void) ready;
    return no_sockets(error);
}

bool portal_socket_close(uint64_t socket, portal_text *error)
{
    (void) socket;
    return no_sockets(error);
}

/* Timers.  None starts: a timer cannot fail, and the views that bring an
   event loop to fire one from are not written.  Until then nothing the core
   does can need one: only a view's records, a handoff and a connection
   schedule anything. */
void portal_timer_start(uint64_t token, uint64_t milliseconds)
{
    (void) token, (void) milliseconds;
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
