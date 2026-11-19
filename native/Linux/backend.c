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
   - portal_status_hide, which hides a panel that is never shown.

   What is not, and what each operation waits for:

   - Views and input, on a Wayland subsurface and a GTK3 widget in the
     frame.  Timers come with them: portal_timer_start starts none here, so
     nothing the core schedules ever runs.  Nothing can schedule yet, as
     only views and connections do.
   - Terminals, on Ghostty's library, and web views, on WebKitGTK.
   - Message sockets, which carry Rex connections.
   - System-wide keys, posted keys and the status panel, which Wayland gives
     a client no direct way to do.
   - The launcher, which rests on the NS build of Emacs and has no Linux
     plan.

   GTK3 is not a choice: this code runs inside Emacs's process, whose
   toolkit it is, and uses the GTK that Emacs has loaded and initialized.
   It never calls gtk_init. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gdk/gdk.h>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>

#include "portal.h"

/* Fail with the formatted message, for a Lisp `error' signal. */
static bool fail(portal_text *error, const char *format, ...)
{
    char message[256];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    size_t size = length < (int) sizeof message ? (size_t) length : sizeof message - 1;
    char *data = malloc(size + 1);
    if (data) {
        memcpy(data, message, size);
        data[size] = '\0';
        *error = (portal_text) {data, size};
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
