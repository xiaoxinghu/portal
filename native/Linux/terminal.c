/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Terminals on Linux: a view's content that is a Ghostty surface running a
   local shell, or fed a Rex block's output (a fed terminal, below), and
   Ghostty's app, which every terminal shares.

   Ghostty draws: its renderer has a thread of its own for each surface, and
   the presenter (presenter.c) shows the frames it makes.  Portal gives the
   surface its size, its keys, its mouse and its clipboard, and tells the
   core what it describes.

   The app.  Ghostty's library is started once (backend.c), and the app with
   it, the first time a terminal is made.  Ghostty asks for its app to be
   ticked from any thread (wakeup); the tick runs on Emacs's main thread,
   from GLib's main loop, which Emacs runs whenever it waits or polls for
   input, and goes on whether or not any terminal is shown: a full mailbox
   would stop the terminal's IO.  Everything Ghostty calls back with, but
   the wakeup and the frame-ready callback, comes from the tick.

   Configuration.  As on macOS, no file of an installed Ghostty is read.
   Each terminal has a configuration of its own, made from its theme, its
   opacity and its text size (config_text), applied when it is made and
   again at each change.  Without a theme, or with a light and a dark one,
   it follows the desktop's light or dark preference, which the XDG desktop
   portal says (scheme_follow).  Ghostty's own key
   bindings are cleared, but Copy and Paste: on Linux they are Control and
   Alt chords, which would take keys from the shell, and Portal sizes the
   text itself.  Copy and Paste are Control-Shift-C and Control-Shift-V, as
   in other Linux terminals, and Control-Insert and Shift-Insert, Emacs's
   own, so that a desktop can send Emacs one key for each whatever its pane
   shows.  Shift-Insert pastes the clipboard, not the primary selection as
   Ghostty's default would; a middle click still pastes that.

   A terminal ends (views.c) by stopping: its clipboard requests denied,
   the presenter forgetting it, and the surface freed, which ends the
   shell; then, once the view's surface is gone, its buffers go. */
#define _GNU_SOURCE
#include <dirent.h>
#include <limits.h>
#include <math.h>
#include <pwd.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <gdk/gdkwayland.h>
#include <ghostty.h>

#include "json.h"
#include "linux.h"

/* The padding Ghostty leaves inside a terminal on each side, in points, as
   on macOS: the core's geometry of a fed terminal counts on it, and so
   every terminal has portal.h's. */
enum { PADDING = PORTAL_TERMINAL_PADDING };

struct fed;

struct terminal {
    struct terminal *next; /* Every terminal there is. */
    struct portal_view *view;
    struct portal_stage *stage;
    ghostty_surface_t surface; /* NULL once freed. */
    struct fed *fed;           /* A fed terminal's, or NULL. */
    /* Its configuration: a theme Ghostty lists for the light desktop and
       one for the dark, the same for a fixed theme, or both NULL for the
       default; the background's opacity; the text's size. */
    char *theme, *dark_theme;
    double opacity, points;
    /* What it describes. */
    char *title, *pwd, *program, *progress;
    bool exited;
    guint sampler; /* Samples the foreground program each second. */
    /* The pane, as the view last told it. */
    int32_t width, height, scale;
    /* The keys that are down, for telling a repeat from a press. */
    guint16 down[16];
    size_t down_count;
};

static void fed_cell(struct terminal *terminal);

/* A clipboard read Ghostty asked for, which GTK answers later. */
struct request {
    struct request *next;
    uint64_t id;
    struct terminal *terminal;
    void *state; /* Ghostty's, answered exactly once. */
};

static struct {
    ghostty_app_t app;
    const char *resources;
    atomic_bool ticking; /* A tick is due on the main loop. */
    struct terminal *terminals;
    struct request *requests;
    uint64_t requests_made;
    ghostty_color_scheme_e scheme;
    void *egl; /* An EGLDisplay on Emacs's Wayland connection, or NULL. */
} app;

static void changed(struct terminal *terminal)
{
    portal_terminal_changed((portal_string) {terminal->view->target, terminal->view->target_length});
}

/* Configuration. */

/* NUMBER for Ghostty's configuration, which reads no exponent. */
static void format_number(char *text, size_t size, double number)
{
    snprintf(text, size, "%.3f", number);
}

/* The configuration of a terminal with the themes LIGHT and DARK, OPACITY
   and POINTS, as the text of a file, allocated with g_malloc.  LIGHT or
   DARK as the desktop is light or dark, and without them Alabaster or
   Afterglow: Portal chooses, and not Ghostty with a theme of the form
   light:...,dark:..., since Ghostty then reads such a configuration anew
   from its lines for the dark, and the command and directory a surface was
   made with are not among them. */
static char *config_text(const char *light, const char *dark, double opacity, double points)
{
    bool dim = app.scheme == GHOSTTY_COLOR_SCHEME_DARK;
    const char *theme = light ? (dim && dark ? dark : light) : dim ? "Afterglow" : "Alabaster";
    char alpha[32], size[32];
    format_number(alpha, sizeof alpha, opacity);
    format_number(size, sizeof size, points);
    return g_strdup_printf(
        "theme = %s\n"
        "background-opacity = %s\n"
        "font-size = %s\n"
        "window-padding-x = %d\n"
        "window-padding-y = %d\n"
        "window-padding-balance = false\n"
        /* Every exit is reported as one: none counts as a failed launch. */
        "abnormal-command-exit-runtime = 0\n"
        "keybind = clear\n"
        "keybind = ctrl+shift+c=copy_to_clipboard\n"
        "keybind = ctrl+shift+v=paste_from_clipboard\n"
        "keybind = ctrl+insert=copy_to_clipboard\n"
        "keybind = shift+insert=paste_from_clipboard\n",
        theme, alpha, size, PADDING, PADDING);
}

/* Ghostty's configuration for the themes LIGHT and DARK, OPACITY and
   POINTS, or NULL with *ERROR set.  Ghostty reads configuration only from
   files: this one is in memory, read through its descriptor's name. */
static ghostty_config_t config_make(const char *light, const char *dark, double opacity,
                                    double points, portal_text *error)
{
    char *text = config_text(light, dark, opacity, points);
    size_t length = strlen(text);
    int file = memfd_create("portal-terminal-config", MFD_CLOEXEC);
    bool written = file >= 0 && write(file, text, length) == (ssize_t) length;
    g_free(text);
    if (!written) {
        if (file >= 0)
            close(file);
        portal_linux_fail(error, "Portal could not write a terminal's configuration");
        return NULL;
    }
    char path[64];
    snprintf(path, sizeof path, "/proc/self/fd/%d", file);
    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_file(config, path);
    close(file);
    ghostty_config_finalize(config);
    if (ghostty_config_diagnostics_count(config)) {
        ghostty_diagnostic_s diagnostic = ghostty_config_get_diagnostic(config, 0);
        portal_linux_fail(error, "Ghostty refused a terminal's configuration: %s",
                          diagnostic.message ? diagnostic.message : "no reason given");
        ghostty_config_free(config);
        return NULL;
    }
    return config;
}

/* The opacity Ghostty draws TERMINAL's background at.  Below 1, a fed
   terminal's backdrop alone draws it, at the terminal's opacity, over the
   whole pane, and Ghostty's own is clear: drawn by both, the grid would
   show as a darker box, as on macOS. */
static double own_opacity(const struct terminal *terminal)
{
    return terminal->fed && terminal->opacity < 1 ? 0 : terminal->opacity;
}

/* TERMINAL's configuration, for its theme, its opacity and its text size;
   and for a fed terminal, its view's backdrop in the theme's background. */
static ghostty_config_t terminal_config(struct terminal *terminal, portal_text *error)
{
    ghostty_config_t config = config_make(terminal->theme, terminal->dark_theme,
                                          own_opacity(terminal), terminal->points, error);
    if (config && terminal->fed) {
        static const char key[] = "background";
        ghostty_config_color_s background = {0};
        if (!ghostty_config_get(config, &background, key, sizeof key - 1))
            background = (ghostty_config_color_s) {0, 0, 0};
        portal_linux_view_backdrop(terminal->view, background.r, background.g, background.b,
                                   terminal->opacity);
    }
    return config;
}

/* Apply TERMINAL's configuration to its surface. */
static bool reconfigure(struct terminal *terminal, portal_text *error)
{
    ghostty_config_t config = terminal_config(terminal, error);
    if (!config)
        return false;
    if (terminal->surface)
        ghostty_surface_update_config(terminal->surface, config);
    ghostty_config_free(config);
    return true;
}

/* The desktop's light or dark preference. */

static ghostty_color_scheme_e scheme_of(GVariant *value)
{
    /* 1 is dark; 0, no preference, and 2, light, are light. */
    while (value && g_variant_is_of_type(value, G_VARIANT_TYPE_VARIANT)) {
        GVariant *inner = g_variant_get_variant(value);
        g_variant_unref(value);
        value = inner;
    }
    bool dark = value && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)
             && g_variant_get_uint32(value) == 1;
    if (value)
        g_variant_unref(value);
    return dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
}

/* Whether TERMINAL's theme changes with the desktop's preference: the
   default's does, and a pair's. */
static bool follows(const struct terminal *terminal)
{
    return !terminal->theme || g_strcmp0(terminal->theme, terminal->dark_theme);
}

/* The desktop is light or dark now: each terminal of the default theme or
   of a pair takes the one for it. */
static void scheme_apply(ghostty_color_scheme_e scheme)
{
    if (scheme == app.scheme)
        return;
    app.scheme = scheme;
    for (struct terminal *terminal = app.terminals; terminal; terminal = terminal->next) {
        portal_text error = {0};
        if (follows(terminal) && !reconfigure(terminal, &error))
            free(error.data);
    }
}

static void setting_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
                            const gchar *interface, const gchar *signal, GVariant *parameters,
                            gpointer data)
{
    (void) bus, (void) sender, (void) path, (void) interface, (void) signal, (void) data;
    const gchar *space = NULL, *key = NULL;
    GVariant *value = NULL;
    g_variant_get(parameters, "(&s&sv)", &space, &key, &value);
    if (!g_strcmp0(space, "org.freedesktop.appearance") && !g_strcmp0(key, "color-scheme"))
        scheme_apply(scheme_of(value));
    else if (value)
        g_variant_unref(value);
}

/* Ask the desktop portal for the preference, briefly, and follow it. */
static void scheme_follow(void)
{
    app.scheme = GHOSTTY_COLOR_SCHEME_LIGHT;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus)
        return;
    g_dbus_connection_signal_subscribe(bus, "org.freedesktop.portal.Desktop",
                                       "org.freedesktop.portal.Settings", "SettingChanged",
                                       "/org/freedesktop/portal/desktop",
                                       "org.freedesktop.appearance", G_DBUS_SIGNAL_FLAGS_NONE,
                                       setting_changed, NULL, NULL);
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings", "Read",
        g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 250, NULL, NULL);
    if (reply) {
        GVariant *value = NULL;
        g_variant_get(reply, "(v)", &value);
        g_variant_unref(reply);
        scheme_apply(scheme_of(value));
    }
}

/* Ghostty's callbacks. */

static gboolean tick(gpointer data)
{
    (void) data;
    atomic_store(&app.ticking, false);
    ghostty_app_tick(app.app);
    return G_SOURCE_REMOVE;
}

/* From any thread. */
static void wakeup(void *data)
{
    (void) data;
    if (!atomic_exchange(&app.ticking, true))
        g_idle_add_full(G_PRIORITY_DEFAULT, tick, NULL, NULL);
}

static struct terminal *terminal_of_target(ghostty_target_s target)
{
    if (target.tag != GHOSTTY_TARGET_SURFACE || !target.target.surface)
        return NULL;
    return ghostty_surface_userdata(target.target.surface);
}

/* Replace *TEXT with VALUE, LENGTH bytes; whether it changed. */
static bool set_text(char **text, const char *value, size_t length)
{
    if (*text && strlen(*text) == length && !memcmp(*text, value, length))
        return false;
    g_free(*text);
    *text = g_strndup(value, length);
    return true;
}

/* The executable of the process group in the foreground of TERMINAL's
   pty, or "". */
static char *foreground_program(const struct terminal *terminal)
{
    uint64_t pid = terminal->surface && !terminal->exited
                       ? ghostty_surface_foreground_pid(terminal->surface)
                       : 0;
    if (!pid)
        return g_strdup("");
    char link[64], path[PATH_MAX];
    snprintf(link, sizeof link, "/proc/%llu/exe", (unsigned long long) pid);
    ssize_t length = readlink(link, path, sizeof path - 1);
    return g_strndup(length > 0 ? path : "", length > 0 ? (size_t) length : 0);
}

/* Note the foreground program now; whether it changed. */
static bool sample_program(struct terminal *terminal)
{
    char *program = foreground_program(terminal);
    bool different = set_text(&terminal->program, program, strlen(program));
    g_free(program);
    return different;
}

static gboolean sampled(gpointer data)
{
    struct terminal *terminal = data;
    if (sample_program(terminal))
        changed(terminal);
    return G_SOURCE_CONTINUE;
}

/* TERMINAL's process ended: the view stays, showing its last output. */
static void ended(struct terminal *terminal)
{
    if (terminal->exited)
        return;
    terminal->exited = true;
    if (terminal->sampler)
        g_source_remove(terminal->sampler);
    terminal->sampler = 0;
    set_text(&terminal->program, "", 0);
    changed(terminal);
}

/* The CSS name of Ghostty's pointer SHAPE. */
static const char *shape_name(ghostty_action_mouse_shape_e shape)
{
    switch (shape) {
    case GHOSTTY_MOUSE_SHAPE_TEXT:
        return "text";
    case GHOSTTY_MOUSE_SHAPE_POINTER:
        return "pointer";
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
        return "crosshair";
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
        return "not-allowed";
    case GHOSTTY_MOUSE_SHAPE_WAIT:
        return "wait";
    case GHOSTTY_MOUSE_SHAPE_PROGRESS:
        return "progress";
    case GHOSTTY_MOUSE_SHAPE_GRAB:
        return "grab";
    case GHOSTTY_MOUSE_SHAPE_GRABBING:
        return "grabbing";
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
        return "col-resize";
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
        return "row-resize";
    default:
        return "default";
    }
}

static void open_url(const char *url, size_t length)
{
    char *text = g_strndup(url, length);
    char *scheme = g_uri_parse_scheme(text);
    /* What a click on a link may open, as on macOS. */
    if (scheme && (!g_ascii_strcasecmp(scheme, "http") || !g_ascii_strcasecmp(scheme, "https")
                   || !g_ascii_strcasecmp(scheme, "mailto")))
        g_app_info_launch_default_for_uri(text, NULL, NULL);
    g_free(scheme);
    g_free(text);
}

static bool act(ghostty_app_t ghostty, ghostty_target_s target, ghostty_action_s action)
{
    (void) ghostty;
    struct terminal *terminal = terminal_of_target(target);
    switch (action.tag) {
    case GHOSTTY_ACTION_SET_TITLE: {
        const char *title = action.action.set_title.title;
        if (terminal && !terminal->fed && title
            && set_text(&terminal->title, title, strlen(title))) {
            sample_program(terminal);
            changed(terminal);
        }
        return true;
    }
    case GHOSTTY_ACTION_PWD: {
        const char *pwd = action.action.pwd.pwd;
        if (terminal && !terminal->fed && pwd && set_text(&terminal->pwd, pwd, strlen(pwd))) {
            sample_program(terminal);
            changed(terminal);
        }
        return true;
    }
    case GHOSTTY_ACTION_PROGRESS_REPORT: {
        static const char *const states[] = {"remove", "set", "error", "indeterminate", "pause"};
        unsigned state = action.action.progress_report.state;
        const char *name = state < G_N_ELEMENTS(states) ? states[state] : "";
        if (terminal && set_text(&terminal->progress, name, strlen(name)))
            changed(terminal);
        return true;
    }
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        /* A fed terminal never exits by itself. */
        if (terminal && !terminal->fed)
            ended(terminal);
        return true;
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        if (terminal)
            portal_linux_input_cursor(terminal->view, shape_name(action.action.mouse_shape));
        return true;
    case GHOSTTY_ACTION_OPEN_URL:
        open_url(action.action.open_url.url, action.action.open_url.len);
        return true;
    case GHOSTTY_ACTION_RELOAD_CONFIG:
        /* The configuration again, which is all of it. */
        if (terminal) {
            portal_text error = {0};
            if (!reconfigure(terminal, &error))
                free(error.data);
        }
        return true;
    case GHOSTTY_ACTION_CELL_SIZE:
        /* A new text size or scale: a held grid's place changes, and the
           grid the pane would hold. */
        if (terminal)
            fed_cell(terminal);
        return true;
    case GHOSTTY_ACTION_RENDERER_HEALTH:
    case GHOSTTY_ACTION_COLOR_CHANGE:
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
    case GHOSTTY_ACTION_CONFIG_CHANGE:
        return true;
    default:
        return false;
    }
}

/* Ghostty asks to close the surface when its process ends, and at each key
   pressed after that.  Portal keeps the view: the end is reported, and a key
   after it gives the keyboard back to Emacs. */
static void close_surface(void *data, bool alive)
{
    struct terminal *terminal = data;
    if (!terminal)
        return;
    if (!alive && !terminal->exited) {
        ended(terminal);
    } else {
        portal_text error = {0};
        if (!portal_view_unfocus(terminal->view, &error))
            free(error.data);
    }
}

/* The clipboard.  Ghostty asks to read it for a paste, and for a program
   that asks (OSC 52); GTK answers later, and each request is answered
   exactly once: with the text, or denied, as at the terminal's end. */

static GtkClipboard *clipboard_of(ghostty_clipboard_e which)
{
    return gtk_clipboard_get(which == GHOSTTY_CLIPBOARD_STANDARD ? GDK_SELECTION_CLIPBOARD
                                                                 : GDK_SELECTION_PRIMARY);
}

/* Take the request ID off the list: NULL if it was answered. */
static struct request *request_take(uint64_t id)
{
    for (struct request **link = &app.requests; *link; link = &(*link)->next)
        if ((*link)->id == id) {
            struct request *request = *link;
            *link = request->next;
            return request;
        }
    return NULL;
}

static void clipboard_read(GtkClipboard *clipboard, const gchar *text, gpointer data)
{
    (void) clipboard;
    struct request *request = request_take(*(uint64_t *) data);
    g_free(data);
    if (!request)
        return;
    ghostty_surface_t surface = request->terminal->surface;
    if (text && surface) {
        ghostty_clipboard_content_s content = {"text/plain", text, strlen(text)};
        ghostty_clipboard_complete_s complete = {.contents = &content, .contents_len = 1};
        ghostty_surface_complete_clipboard_request(surface, &complete, request->state);
    } else if (surface) {
        ghostty_surface_deny_clipboard_request(surface, request->state);
    }
    free(request);
}

static ghostty_clipboard_read_result_e read_clipboard(void *data, ghostty_clipboard_e which,
                                                      void *state, const char *const *types,
                                                      size_t count, bool list)
{
    (void) list;
    struct terminal *terminal = data;
    bool text = false;
    for (size_t i = 0; i < count; i++)
        text = text || !strcmp(types[i], "text/plain");
    if (!terminal || !text)
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
    struct request *request = calloc(1, sizeof *request);
    if (!request)
        return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
    request->id = ++app.requests_made;
    request->terminal = terminal;
    request->state = state;
    request->next = app.requests;
    app.requests = request;
    gtk_clipboard_request_text(clipboard_of(which), clipboard_read,
                               portal_linux_serial(request->id));
    return GHOSTTY_CLIPBOARD_READ_STARTED;
}

/* A request Ghostty wants confirmed, with the contents it would complete
   with, which are borrowed: a paste with text that runs commands, or a
   program reading the clipboard.  Portal has nobody to ask.  The user asked
   for a paste, which goes ahead; a program's read is denied. */
static void confirm_read_clipboard(void *data, const ghostty_clipboard_confirm_s *confirm,
                                   void *state, ghostty_clipboard_request_e kind)
{
    struct terminal *terminal = data;
    if (!terminal || !terminal->surface)
        return;
    if (kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE) {
        ghostty_clipboard_complete_s complete = {.contents = confirm->contents,
                                                 .contents_len = confirm->contents_len,
                                                 .available = confirm->available,
                                                 .available_len = confirm->available_len,
                                                 .confirmed = true};
        ghostty_surface_complete_clipboard_request(terminal->surface, &complete, state);
    } else {
        ghostty_surface_deny_clipboard_request(terminal->surface, state);
    }
}

static void write_clipboard(void *data, ghostty_clipboard_e which,
                            const ghostty_clipboard_content_s *contents, size_t count,
                            bool confirm)
{
    (void) data;
    /* A write that wants confirming is one nobody is asked about. */
    if (confirm)
        return;
    for (size_t i = 0; i < count; i++)
        if (contents[i].mime && !strcmp(contents[i].mime, "text/plain")) {
            gtk_clipboard_set_text(clipboard_of(which), contents[i].data,
                                   (gint) contents[i].len);
            return;
        }
}

/* Deny TERMINAL's requests still under way, before its surface goes. */
static void requests_deny(struct terminal *terminal)
{
    for (struct request **link = &app.requests; *link;) {
        struct request *request = *link;
        if (request->terminal != terminal) {
            link = &request->next;
            continue;
        }
        *link = request->next;
        if (terminal->surface)
            ghostty_surface_deny_clipboard_request(terminal->surface, request->state);
        free(request);
    }
}

/* The app. */

/* An EGL display on Emacs's own Wayland connection, so that Ghostty draws
   with the compositor's GPU; or NULL, for Mesa's surfaceless one. */
static void *egl_display(const struct portal_wayland *wayland)
{
    PFNEGLGETPLATFORMDISPLAYEXTPROC display_of =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!display_of)
        return NULL;
    EGLDisplay display = display_of(EGL_PLATFORM_WAYLAND_KHR, wayland->display, NULL);
    EGLint major, minor;
    return display != EGL_NO_DISPLAY && eglInitialize(display, &major, &minor) ? display : NULL;
}

static bool app_start(const struct portal_wayland *wayland, portal_text *error)
{
    if (app.app)
        return true;
    if (!portal_linux_ghostty_start(&app.resources, error))
        return false;
    scheme_follow();
    ghostty_config_t config = config_make(NULL, NULL, 1, PORTAL_TERMINAL_POINTS, error);
    if (!config)
        return false;
    ghostty_runtime_config_s runtime = {
        .userdata = NULL,
        .supports_selection_clipboard = true,
        .wakeup_cb = wakeup,
        .action_cb = act,
        .read_clipboard_cb = read_clipboard,
        .confirm_read_clipboard_cb = confirm_read_clipboard,
        .write_clipboard_cb = write_clipboard,
        .close_surface_cb = close_surface,
    };
    app.app = ghostty_app_new(&runtime, config);
    ghostty_config_free(config);
    if (!app.app)
        return portal_linux_fail(error, "Ghostty could not start its app");
    app.egl = egl_display(wayland);
    return true;
}

/* Commands. */

/* VALUE as a single-quoted word for POSIX shells and fish, as macOS quotes
   it: backslashes outside the quotes, which fish reads inside them. */
static void quote(GString *line, const char *value)
{
    g_string_append_c(line, '\'');
    for (const char *c = value; *c; c++) {
        if (*c == '\'')
            g_string_append(line, "'\\''");
        else if (*c == '\\')
            g_string_append(line, "'\\\\'");
        else
            g_string_append_c(line, *c);
    }
    g_string_append_c(line, '\'');
}

/* The command line that runs ARGV, a JSON array of a program and literal
   arguments, through the user's interactive login shell in DIRECTORY, as
   on macOS: the shell loads its startup files and finds the program.  NULL
   with *ERROR set. */
static char *argv_command(portal_string json, const char *directory, portal_text *error)
{
    GPtrArray *argv = g_ptr_array_new_with_free_func(free);
    portal_string element;
    bool valid = true;
    for (size_t i = 0; valid && portal_json_element(json, i, &element); i++) {
        portal_text word;
        valid = portal_json_string(element, &word);
        if (valid) {
            g_ptr_array_add(argv, word.data);
            valid = !memchr(word.data, '\0', word.length);
        }
    }
    if (!valid || !argv->len || !((char *) argv->pdata[0])[0]) {
        g_ptr_array_free(argv, TRUE);
        portal_linux_fail(error, "Terminal :argv must contain a program and literal arguments, "
                                 "without :command");
        return NULL;
    }
    const char *shell = getenv("SHELL");
    struct passwd *user = (!shell || !*shell) ? getpwuid(getuid()) : NULL;
    if (user && user->pw_shell && *user->pw_shell)
        shell = user->pw_shell;
    if (!shell || !*shell)
        shell = "/bin/sh";
    const char *name = strrchr(shell, '/') ? strrchr(shell, '/') + 1 : shell;
    static const char *const shells[] = {"sh", "bash", "zsh", "dash", "ksh", "fish"};
    bool known = false;
    for (size_t i = 0; i < G_N_ELEMENTS(shells); i++)
        known = known || !strcmp(name, shells[i]);
    if (!known) {
        g_ptr_array_free(argv, TRUE);
        portal_linux_fail(error, "Program launches need a POSIX-compatible shell or fish; found %s",
                          shell);
        return NULL;
    }
    /* Startup files may change directory; the program still starts here. */
    GString *script = g_string_new("cd ");
    quote(script, directory);
    g_string_append(script, " && exec");
    for (size_t i = 0; i < argv->len; i++) {
        g_string_append_c(script, ' ');
        quote(script, argv->pdata[i]);
    }
    GString *line = g_string_new(NULL);
    const char *words[] = {shell, "-l", "-i", "-c", script->str};
    for (size_t i = 0; i < G_N_ELEMENTS(words); i++) {
        if (i)
            g_string_append_c(line, ' ');
        quote(line, words[i]);
    }
    g_string_free(script, TRUE);
    g_ptr_array_free(argv, TRUE);
    char *command = strdup(line->str);
    g_string_free(line, TRUE);
    return command;
}

/* A fed terminal.  Its surface runs no program: Ghostty's host-managed
   backend (native/patches/ghostty, 0001) hands what the terminal would
   write to a pty to fed_written, and each grid it takes to fed_resized,
   both on Ghostty's IO thread, and they reach the core on the main thread,
   in order.  Its output is parsed by a thread of the terminal's own, the
   feeder, with ghostty_surface_write_buffer_replay (0002), which answers
   no query in it: on macOS the package's in-memory session does this, here
   Portal does.  The order of output and grids, where the terminal goes in
   its pane, and when its program waits for a backlog are the core's rules
   (native/Core/fed.h), which this gives the feeder, its count of bytes
   waiting, the view's placement (views.c), which shows a grid that is not
   the pane's from the corner of the pane the core hangs it from, over the
   view's backdrop, the theme's background at the terminal's opacity, and
   the view's hold of the frame it shows across a change of grid; and tells
   them the pane, the cell, each grid the surface takes and each crossing
   of the backlog's marks.

   A fed terminal's title, directory and program are the core's to
   describe, from what its program reports (rex.h): none is sampled here. */

/* Output waiting for the feeder, oldest first. */
struct chunk {
    struct chunk *next;
    size_t length, done;
    char bytes[];
};

/* The most the feeder parses at once: a call holds the terminal's lock,
   which the renderer takes to draw. */
enum { SLICE = 1 << 16 };

struct fed {
    uint64_t serial; /* The view's, for work on the main loop. */
    struct terminal *terminal;
    /* The feeder's surface: set before it starts, which is joined before
       the surface is freed. */
    ghostty_surface_t surface;
    pthread_t feeder;
    bool feeding; /* The feeder runs. */

    /* Under LOCK: the output waiting and how many of its bytes are not
       parsed yet; whether the feeder is to end; and what the surface
       wrote, which the core has not been given yet. */
    pthread_mutex_t lock;
    pthread_cond_t work, drained;
    struct chunk *first, *last;
    size_t pending;
    bool ending;
    GByteArray *written;
    bool writing; /* An idle source will give the core WRITTEN. */

    atomic_bool looking;          /* An idle source will tell the core of a crossing. */
    atomic_uint_fast32_t taken;   /* The grid the surface took last, packed. */
    atomic_bool telling;          /* An idle source will tell the core of it. */

    /* The pane as the core was last told, in Emacs's pixels; and where it
       put the terminal in it, and the surface's size for that, in device
       pixels. */
    double width, height, scale;
    portal_pane_rect rect;
    bool placed;
    uint32_t surface_width, surface_height;
};

/* The fed terminal of the view SERIAL, on the main thread, or NULL once it
   has ended. */
static struct fed *fed_find(uint64_t serial)
{
    struct portal_view *view = portal_linux_view_find(serial);
    struct terminal *terminal = view ? view->content : NULL;
    return terminal ? terminal->fed : NULL;
}

/* FED's view's target. */
static portal_string fed_target(const struct fed *fed)
{
    return (portal_string) {fed->terminal->view->target, fed->terminal->view->target_length};
}

static gboolean fed_look(gpointer data)
{
    struct fed *fed = fed_find(*(uint64_t *) data);
    if (fed) {
        atomic_store(&fed->looking, false);
        portal_terminal_backlog(fed_target(fed));
    }
    return G_SOURCE_REMOVE;
}

/* The backlog crossed a mark: the core looks at it, on the main thread.
   From any thread. */
static void fed_crossed(struct fed *fed)
{
    if (!atomic_exchange(&fed->looking, true))
        g_idle_add_full(G_PRIORITY_DEFAULT, fed_look, portal_linux_serial(fed->serial), g_free);
}

static void *feeder(void *data)
{
    struct fed *fed = data;
    pthread_mutex_lock(&fed->lock);
    for (;;) {
        while (!fed->first && !fed->ending)
            pthread_cond_wait(&fed->work, &fed->lock);
        if (fed->ending)
            break;
        /* Only this thread takes a chunk off the list, and the main thread
           frees what is left once it has joined it. */
        struct chunk *chunk = fed->first;
        size_t length = MIN(chunk->length - chunk->done, (size_t) SLICE);
        const char *bytes = chunk->bytes + chunk->done;
        pthread_mutex_unlock(&fed->lock);
        ghostty_surface_write_buffer_replay(fed->surface, (const uint8_t *) bytes, length);
        pthread_mutex_lock(&fed->lock);
        chunk->done += length;
        if (chunk->done == chunk->length) {
            fed->first = chunk->next;
            if (!fed->first)
                fed->last = NULL;
            free(chunk);
        }
        size_t before = fed->pending;
        fed->pending -= length;
        if (!fed->pending)
            pthread_cond_broadcast(&fed->drained);
        if (portal_terminal_backlog_crossed(before, fed->pending))
            fed_crossed(fed);
    }
    pthread_mutex_unlock(&fed->lock);
    return NULL;
}

/* What the core's rules ask of a fed terminal (portal.h), on the main
   thread. */

/* Give the feeder LENGTH BYTES to parse. */
static bool fed_parse(struct fed *fed, const char *bytes, size_t length, portal_text *error)
{
    struct chunk *chunk = malloc(sizeof *chunk + length);
    if (!chunk)
        return portal_linux_fail(error, "Portal is out of memory");
    chunk->next = NULL;
    chunk->length = length;
    chunk->done = 0;
    memcpy(chunk->bytes, bytes, length);
    pthread_mutex_lock(&fed->lock);
    if (fed->last)
        fed->last->next = chunk;
    else
        fed->first = chunk;
    fed->last = chunk;
    size_t before = fed->pending;
    fed->pending += length;
    pthread_cond_signal(&fed->work);
    pthread_mutex_unlock(&fed->lock);
    /* Not now: the core is calling. */
    if (portal_terminal_backlog_crossed(before, before + length))
        fed_crossed(fed);
    return true;
}

static void fed_drain(struct fed *fed)
{
    pthread_mutex_lock(&fed->lock);
    while (fed->pending && fed->feeding)
        pthread_cond_wait(&fed->drained, &fed->lock);
    pthread_mutex_unlock(&fed->lock);
}

static size_t fed_pending(struct fed *fed)
{
    pthread_mutex_lock(&fed->lock);
    size_t pending = fed->pending;
    pthread_mutex_unlock(&fed->lock);
    return pending;
}

/* Put the terminal at RECT in its pane: its surface sized to it, in device
   pixels, and its frames shown there.  A terminal that fills its pane is
   shown as any other is. */
static void fed_place(struct fed *fed, portal_pane_rect rect)
{
    struct terminal *terminal = fed->terminal;
    double scale = fed->scale > 0 ? fed->scale : 1;
    uint32_t width = (uint32_t) ceil(rect.width * scale - 1e-6);
    uint32_t height = (uint32_t) ceil(rect.height * scale - 1e-6);
    fed->rect = rect;
    fed->placed = true;
    if (!width || !height)
        return;
    if (terminal->surface && (width != fed->surface_width || height != fed->surface_height))
        ghostty_surface_set_size(terminal->surface, width, height);
    fed->surface_width = width;
    fed->surface_height = height;
    bool fills = rect.x == 0 && rect.top == 0 && rect.width == fed->width
              && rect.height == fed->height;
    portal_linux_view_place(terminal->view,
                            (struct portal_placement) {.placed = !fills,
                                                       .x = (int32_t) lround(rect.x * scale),
                                                       .y = (int32_t) lround(rect.top * scale),
                                                       .width = (int32_t) width,
                                                       .height = (int32_t) height,
                                                       .from_bottom = rect.from_bottom});
}

/* What the surface tells, on Ghostty's IO thread. */

static gboolean fed_hand_over(gpointer data)
{
    struct fed *fed = fed_find(*(uint64_t *) data);
    if (!fed)
        return G_SOURCE_REMOVE;
    pthread_mutex_lock(&fed->lock);
    GByteArray *written = fed->written;
    fed->written = g_byte_array_new();
    fed->writing = false;
    pthread_mutex_unlock(&fed->lock);
    struct portal_view *view = fed->terminal->view;
    if (written->len)
        portal_terminal_input((portal_string) {view->target, view->target_length},
                              (const char *) written->data, written->len);
    g_byte_array_unref(written);
    return G_SOURCE_REMOVE;
}

/* The terminal wrote BYTES, keys it encoded, a paste or a report, for its
   program: they go to the core, in order. */
static void fed_written(void *data, const uint8_t *bytes, size_t length)
{
    struct fed *fed = data;
    pthread_mutex_lock(&fed->lock);
    g_byte_array_append(fed->written, bytes, (guint) length);
    bool idle = !fed->writing;
    fed->writing = true;
    pthread_mutex_unlock(&fed->lock);
    if (idle)
        g_idle_add_full(G_PRIORITY_DEFAULT, fed_hand_over, portal_linux_serial(fed->serial),
                        g_free);
}

static gboolean fed_tell(gpointer data)
{
    struct fed *fed = fed_find(*(uint64_t *) data);
    if (!fed)
        return G_SOURCE_REMOVE;
    atomic_store(&fed->telling, false);
    uint32_t taken = (uint32_t) atomic_load(&fed->taken);
    portal_terminal_took_grid(fed_target(fed), taken >> 16, taken & 0xffff);
    return G_SOURCE_REMOVE;
}

/* The terminal has a grid of COLUMNS by ROWS now. */
static void fed_resized(void *data, uint16_t columns, uint16_t rows, uint32_t width,
                        uint32_t height)
{
    (void) width, (void) height;
    struct fed *fed = data;
    atomic_store(&fed->taken, (uint_fast32_t) columns << 16 | rows);
    if (!atomic_exchange(&fed->telling, true))
        g_idle_add_full(G_PRIORITY_DEFAULT, fed_tell, portal_linux_serial(fed->serial), g_free);
}

/* The core hears of the terminal's cell, in device pixels. */
static void fed_cell(struct terminal *terminal)
{
    if (!terminal->fed || !terminal->surface)
        return;
    ghostty_surface_size_s size = ghostty_surface_size(terminal->surface);
    portal_terminal_cell(fed_target(terminal->fed), size.cell_width_px, size.cell_height_px);
}

/* The padding Ghostty leaves on each side at SCALE, in device pixels: its
   PADDING points as it counts them on Linux, 96 pixels to the inch at
   scale 1, in whole pixels
   (github.com/ghostty-org/ghostty:src/Surface.zig#scaledPadding and
   src/font/face.zig#default_dpi), 5 at scale 2 where macOS has 4. */
static double ghostty_padding(double scale)
{
    return floor(PADDING * 96.0 * scale / 72.0);
}

/* The pane is WIDTH by HEIGHT of Emacs's pixels, at SCALE. */
static void fed_pane(struct terminal *terminal, double width, double height, double scale)
{
    struct fed *fed = terminal->fed;
    fed->width = width;
    fed->height = height;
    fed->scale = scale;
    portal_terminal_pane(fed_target(fed), width, height, scale, ghostty_padding(scale));
}

/* The scale of Emacs's frames, as far as can be told before a terminal is
   in one: so that a grid held before it is shown is held at its size. */
static int32_t scale_guess(void)
{
    int32_t scale = 1;
    GList *windows = gtk_window_list_toplevels();
    for (GList *item = windows; item; item = item->next)
        if (gtk_widget_get_mapped(item->data)) {
            scale = gtk_widget_get_scale_factor(item->data);
            break;
        }
    g_list_free(windows);
    return scale > 0 ? scale : 1;
}

static struct fed *fed_new(struct terminal *terminal)
{
    struct fed *fed = calloc(1, sizeof *fed);
    if (!fed)
        return NULL;
    fed->terminal = terminal;
    fed->serial = terminal->view->serial;
    pthread_mutex_init(&fed->lock, NULL);
    pthread_cond_init(&fed->work, NULL);
    pthread_cond_init(&fed->drained, NULL);
    fed->written = g_byte_array_new();
    return fed;
}

/* Start the feeder on SURFACE, with none of Emacs's signals. */
static bool fed_start(struct fed *fed, ghostty_surface_t surface)
{
    fed->surface = surface;
    sigset_t all, before;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &before);
    fed->feeding = !pthread_create(&fed->feeder, NULL, feeder, fed);
    pthread_sigmask(SIG_SETMASK, &before, NULL);
    return fed->feeding;
}

/* Before the surface is freed: the feeder ends, leaving what waits
   unparsed. */
static void fed_stop(struct fed *fed)
{
    if (!fed->feeding)
        return;
    pthread_mutex_lock(&fed->lock);
    fed->ending = true;
    pthread_cond_signal(&fed->work);
    pthread_mutex_unlock(&fed->lock);
    pthread_join(fed->feeder, NULL);
    fed->feeding = false;
}

/* Once the surface is freed, and Ghostty's threads with it. */
static void fed_free(struct fed *fed)
{
    if (!fed)
        return;
    for (struct chunk *chunk = fed->first, *next; chunk; chunk = next) {
        next = chunk->next;
        free(chunk);
    }
    g_byte_array_unref(fed->written);
    pthread_cond_destroy(&fed->drained);
    pthread_cond_destroy(&fed->work);
    pthread_mutex_destroy(&fed->lock);
    free(fed);
}

/* The content's class. */

static struct terminal *terminal_of(portal_view *view, portal_text *error);

/* The stage's source: Ghostty's surface and its frames. */

static struct portal_linux_frame *ghostty_take(void *surface)
{
    ghostty_frame_s *taken = ghostty_surface_take_frame(surface);
    if (!taken)
        return NULL;
    struct portal_linux_frame *frame = calloc(1, sizeof *frame);
    if (!frame) {
        ghostty_frame_free(taken);
        return NULL;
    }
    *frame = (struct portal_linux_frame) {.memory = taken->kind == GHOSTTY_FRAME_MEMORY,
                                          .width = (int32_t) taken->width,
                                          .height = (int32_t) taken->height,
                                          .texture = taken->texture,
                                          .fourcc = taken->fourcc,
                                          .modifier = taken->modifier,
                                          .plane_count = taken->plane_count,
                                          .pixels = taken->pixels,
                                          .own = taken};
    for (uint32_t i = 0; i < 4; i++) {
        frame->fds[i] = taken->fds[i];
        frame->offsets[i] = taken->offsets[i];
        frame->strides[i] = taken->strides[i];
    }
    if (frame->memory)
        frame->strides[0] = 0;
    return frame;
}

static void ghostty_done(struct portal_linux_frame *frame)
{
    ghostty_frame_free(frame->own);
    free(frame);
}

static void ghostty_visible(void *surface, bool visible)
{
    ghostty_surface_set_occlusion(surface, visible);
}

static void ghostty_memory(void *surface)
{
    ghostty_surface_set_presentation_health(surface, false);
    ghostty_surface_draw(surface);
}

static const struct portal_stage_source ghostty_source = {
    .take = ghostty_take,
    .done = ghostty_done,
    .shown = NULL,
    .visible = ghostty_visible,
    .memory = ghostty_memory,
};

static void terminal_stop(void *content)
{
    struct terminal *terminal = content;
    if (terminal->sampler)
        g_source_remove(terminal->sampler);
    terminal->sampler = 0;
    requests_deny(terminal);
    /* In this order: a fed terminal's feeder ends; the
       presenter and the shower forget the surface; then it is freed, which
       ends the shell, or a fed terminal's IO thread, and stops its
       renderer, after which Ghostty announces no frame and writes nothing. */
    if (terminal->fed)
        fed_stop(terminal->fed);
    portal_linux_stage_stop(terminal->stage);
    ghostty_surface_t surface = terminal->surface;
    terminal->surface = NULL;
    if (surface)
        ghostty_surface_free(surface);
    for (struct terminal **link = &app.terminals; *link; link = &(*link)->next)
        if (*link == terminal) {
            *link = terminal->next;
            break;
        }
}

static void terminal_destroy(void *content)
{
    struct terminal *terminal = content;
    /* The frames still shown go with their buffers, the view's surface
       being gone. */
    portal_linux_stage_free(terminal->stage);
    fed_free(terminal->fed);
    g_free(terminal->theme);
    g_free(terminal->dark_theme);
    g_free(terminal->title);
    g_free(terminal->pwd);
    g_free(terminal->program);
    g_free(terminal->progress);
    free(terminal);
}

static void terminal_configure(void *content, int32_t width, int32_t height, int32_t scale,
                               bool shown)
{
    struct terminal *terminal = content;
    if (terminal->fed && terminal->surface && width > 0 && height > 0 && scale > 0) {
        /* The core sizes the surface, to the pane or to the grid it holds. */
        if (scale != terminal->scale)
            ghostty_surface_set_content_scale(terminal->surface, scale, scale);
        terminal->width = width;
        terminal->height = height;
        terminal->scale = scale;
        fed_pane(terminal, width, height, scale);
        fed_cell(terminal);
    } else if (terminal->surface && width > 0 && height > 0 && scale > 0) {
        if (scale != terminal->scale)
            ghostty_surface_set_content_scale(terminal->surface, scale, scale);
        if (scale != terminal->scale || width != terminal->width || height != terminal->height)
            ghostty_surface_set_size(terminal->surface, (uint32_t) (width * scale),
                                     (uint32_t) (height * scale));
        terminal->width = width;
        terminal->height = height;
        terminal->scale = scale;
    }
    portal_linux_stage_configure(terminal->stage, shown);
}

static void terminal_frame(void *content, uint32_t time)
{
    (void) time;
    struct terminal *terminal = content;
    portal_linux_stage_frame(terminal->stage);
}

static void terminal_focus(void *content, bool focused)
{
    struct terminal *terminal = content;
    if (!focused)
        terminal->down_count = 0;
    if (terminal->surface)
        ghostty_surface_set_focus(terminal->surface, focused);
}

/* GTK's modifiers STATE as Ghostty's. */
static ghostty_input_mods_e mods_of(guint state)
{
    ghostty_input_mods_e mods = GHOSTTY_MODS_NONE;
    if (state & GDK_SHIFT_MASK)
        mods |= GHOSTTY_MODS_SHIFT;
    if (state & GDK_CONTROL_MASK)
        mods |= GHOSTTY_MODS_CTRL;
    if (state & (GDK_MOD1_MASK | GDK_META_MASK))
        mods |= GHOSTTY_MODS_ALT;
    if (state & (GDK_MOD4_MASK | GDK_SUPER_MASK))
        mods |= GHOSTTY_MODS_SUPER;
    if (state & GDK_LOCK_MASK)
        mods |= GHOSTTY_MODS_CAPS;
    if (state & GDK_MOD2_MASK)
        mods |= GHOSTTY_MODS_NUM;
    return mods;
}

/* The modifier a modifier key KEYVAL is, or none.  GTK gives a key event
   the modifiers from before it: Ghostty wants those after it. */
static ghostty_input_mods_e modifier_of(guint keyval)
{
    switch (keyval) {
    case GDK_KEY_Shift_L:
    case GDK_KEY_Shift_R:
        return GHOSTTY_MODS_SHIFT;
    case GDK_KEY_Control_L:
    case GDK_KEY_Control_R:
        return GHOSTTY_MODS_CTRL;
    case GDK_KEY_Alt_L:
    case GDK_KEY_Alt_R:
    case GDK_KEY_Meta_L:
    case GDK_KEY_Meta_R:
        return GHOSTTY_MODS_ALT;
    case GDK_KEY_Super_L:
    case GDK_KEY_Super_R:
        return GHOSTTY_MODS_SUPER;
    default:
        return GHOSTTY_MODS_NONE;
    }
}

/* Whether KEYCODE went down already, a repeat; noting a press or release. */
static bool key_repeats(struct terminal *terminal, guint16 keycode, bool press)
{
    for (size_t i = 0; i < terminal->down_count; i++)
        if (terminal->down[i] == keycode) {
            if (!press)
                terminal->down[i] = terminal->down[--terminal->down_count];
            return press;
        }
    if (press) {
        if (terminal->down_count == G_N_ELEMENTS(terminal->down))
            terminal->down_count = 0;
        terminal->down[terminal->down_count++] = keycode;
    }
    return false;
}

/* The XKB key code Ghostty is given for EVENT.  Ghostty reads the key from
   the code, by the US layout's positions.  Its own GTK view takes the key
   from the keyval instead for a key that types a letter, a digit or a sign,
   so that a chord such as Control-C is the same on any Latin layout.  Portal
   goes further and does so for every key it knows by its keyval, named keys
   included: a key remapped by the layout, such as Caps Lock made Escape, is
   then the key it was made, and so is a key from a virtual keyboard such as
   wtype's, whose codes are its own.  Any other key is its code. */
static guint16 keycode_of(const GdkEventKey *event)
{
    static const struct {
        guint keyval;
        guint16 code;
    } codes[] = {
        {GDK_KEY_Escape, 9},       {GDK_KEY_1, 10},           {GDK_KEY_2, 11},
        {GDK_KEY_3, 12},           {GDK_KEY_4, 13},           {GDK_KEY_5, 14},
        {GDK_KEY_6, 15},           {GDK_KEY_7, 16},           {GDK_KEY_8, 17},
        {GDK_KEY_9, 18},           {GDK_KEY_0, 19},           {GDK_KEY_minus, 20},
        {GDK_KEY_equal, 21},       {GDK_KEY_BackSpace, 22},   {GDK_KEY_Tab, 23},
        {GDK_KEY_ISO_Left_Tab, 23}, {GDK_KEY_q, 24},          {GDK_KEY_w, 25},
        {GDK_KEY_e, 26},           {GDK_KEY_r, 27},           {GDK_KEY_t, 28},
        {GDK_KEY_y, 29},           {GDK_KEY_u, 30},           {GDK_KEY_i, 31},
        {GDK_KEY_o, 32},           {GDK_KEY_p, 33},           {GDK_KEY_bracketleft, 34},
        {GDK_KEY_bracketright, 35}, {GDK_KEY_Return, 36},     {GDK_KEY_a, 38},
        {GDK_KEY_s, 39},           {GDK_KEY_d, 40},           {GDK_KEY_f, 41},
        {GDK_KEY_g, 42},           {GDK_KEY_h, 43},           {GDK_KEY_j, 44},
        {GDK_KEY_k, 45},           {GDK_KEY_l, 46},           {GDK_KEY_semicolon, 47},
        {GDK_KEY_apostrophe, 48},  {GDK_KEY_grave, 49},       {GDK_KEY_backslash, 51},
        {GDK_KEY_z, 52},           {GDK_KEY_x, 53},           {GDK_KEY_c, 54},
        {GDK_KEY_v, 55},           {GDK_KEY_b, 56},           {GDK_KEY_n, 57},
        {GDK_KEY_m, 58},           {GDK_KEY_comma, 59},       {GDK_KEY_period, 60},
        {GDK_KEY_slash, 61},       {GDK_KEY_space, 65},       {GDK_KEY_F1, 67},
        {GDK_KEY_F2, 68},          {GDK_KEY_F3, 69},          {GDK_KEY_F4, 70},
        {GDK_KEY_F5, 71},          {GDK_KEY_F6, 72},          {GDK_KEY_F7, 73},
        {GDK_KEY_F8, 74},          {GDK_KEY_F9, 75},          {GDK_KEY_F10, 76},
        {GDK_KEY_F11, 95},         {GDK_KEY_F12, 96},         {GDK_KEY_KP_Enter, 104},
        {GDK_KEY_Home, 110},       {GDK_KEY_Up, 111},         {GDK_KEY_Prior, 112},
        {GDK_KEY_Left, 113},       {GDK_KEY_Right, 114},      {GDK_KEY_End, 115},
        {GDK_KEY_Down, 116},       {GDK_KEY_Next, 117},       {GDK_KEY_Insert, 118},
        {GDK_KEY_Delete, 119},
        /* The signs a US layout types with Shift, at their keys. */
        {GDK_KEY_exclam, 10},      {GDK_KEY_at, 11},          {GDK_KEY_numbersign, 12},
        {GDK_KEY_dollar, 13},      {GDK_KEY_percent, 14},     {GDK_KEY_asciicircum, 15},
        {GDK_KEY_ampersand, 16},   {GDK_KEY_asterisk, 17},    {GDK_KEY_parenleft, 18},
        {GDK_KEY_parenright, 19},  {GDK_KEY_underscore, 20},  {GDK_KEY_plus, 21},
        {GDK_KEY_braceleft, 34},   {GDK_KEY_braceright, 35},  {GDK_KEY_colon, 47},
        {GDK_KEY_quotedbl, 48},    {GDK_KEY_asciitilde, 49},  {GDK_KEY_bar, 51},
        {GDK_KEY_less, 59},        {GDK_KEY_greater, 60},     {GDK_KEY_question, 61},
    };
    guint keyval = gdk_keyval_to_lower(event->keyval);
    for (size_t i = 0; i < G_N_ELEMENTS(codes); i++)
        if (codes[i].keyval == keyval)
            return codes[i].code;
    return event->hardware_keycode;
}

/* EVENT as Ghostty takes a key, as its own GTK view and the probe of the
   frames spike translate one: the XKB key code (keycode_of); the text the
   key types, which the input method committed or its keyval has, never a
   control character, which Ghostty encodes from the key; the character the
   key has with no modifier; the modifiers after it, and those its
   translation used. */
static void terminal_key(void *content, const GdkEventKey *event, const char *text,
                         bool composing)
{
    struct terminal *terminal = content;
    if (!terminal->surface)
        return;
    bool press = event->type == GDK_KEY_PRESS;
    bool repeat = key_repeats(terminal, event->hardware_keycode, press);
    GdkModifierType consumed = 0;
    guint unshifted = 0;
    if (!portal_linux_input_translate(event, 0, &unshifted, &consumed)) {
        consumed = 0;
        unshifted = gdk_keyval_to_lower(event->keyval);
    }
    ghostty_input_mods_e mods = mods_of(event->state), modifier = modifier_of(event->keyval);
    mods = press ? mods | modifier : mods & ~modifier;
    char typed[8] = {0};
    if (press && !text) {
        gunichar character = gdk_keyval_to_unicode(event->keyval);
        if (character >= 0x20 && character != 0x7f)
            g_unichar_to_utf8(character, typed);
        text = typed[0] ? typed : NULL;
    }
    ghostty_input_key_s key = {
        .action = !press ? GHOSTTY_ACTION_RELEASE : repeat ? GHOSTTY_ACTION_REPEAT
                                                           : GHOSTTY_ACTION_PRESS,
        .mods = mods,
        .consumed_mods = mods_of(consumed & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_MOD1_MASK
                                             | GDK_MOD4_MASK | GDK_LOCK_MASK)),
        .keycode = keycode_of(event),
        .text = press ? text : NULL,
        .unshifted_codepoint = gdk_keyval_to_unicode(unshifted),
        .composing = composing,
    };
    ghostty_surface_key(terminal->surface, key);
}

/* Text the input method committed apart from a key: a key Ghostty knows
   not, with that text, as Ghostty's GTK view sends it. */
static void terminal_text(void *content, const char *text)
{
    struct terminal *terminal = content;
    if (!terminal->surface)
        return;
    ghostty_surface_preedit(terminal->surface, "", 0);
    ghostty_input_key_s key = {.action = GHOSTTY_ACTION_PRESS, .text = text};
    ghostty_surface_key(terminal->surface, key);
}

static void terminal_preedit(void *content, const char *text, int cursor)
{
    (void) cursor;
    struct terminal *terminal = content;
    if (terminal->surface)
        ghostty_surface_preedit(terminal->surface, text, strlen(text));
}

/* GDK's button BUTTON as Ghostty's: by name, since the two number the
   middle and the right ones the other way round. */
static ghostty_input_mouse_button_e button_of(guint button)
{
    static const ghostty_input_mouse_button_e buttons[] = {
        GHOSTTY_MOUSE_UNKNOWN, GHOSTTY_MOUSE_LEFT,  GHOSTTY_MOUSE_MIDDLE, GHOSTTY_MOUSE_RIGHT,
        GHOSTTY_MOUSE_FOUR,    GHOSTTY_MOUSE_FIVE,  GHOSTTY_MOUSE_SIX,    GHOSTTY_MOUSE_SEVEN,
        GHOSTTY_MOUSE_EIGHT,   GHOSTTY_MOUSE_NINE,  GHOSTTY_MOUSE_TEN,    GHOSTTY_MOUSE_ELEVEN,
    };
    return button < G_N_ELEMENTS(buttons) ? buttons[button] : GHOSTTY_MOUSE_UNKNOWN;
}

static void terminal_pointer(void *content, const GdkEvent *event)
{
    struct terminal *terminal = content;
    ghostty_surface_t surface = terminal->surface;
    gdouble x = 0, y = 0;
    GdkModifierType state = 0;
    if (!surface)
        return;
    gdk_event_get_state(event, &state);
    bool placed = gdk_event_get_coords(event, &x, &y);
    /* A fed terminal's surface is where the core puts it in the pane. */
    if (terminal->fed && terminal->fed->placed) {
        x -= terminal->fed->rect.x;
        y -= terminal->fed->rect.top;
    }
    ghostty_input_mods_e mods = mods_of(state);
    switch (event->type) {
    case GDK_BUTTON_PRESS:
    case GDK_BUTTON_RELEASE:
        if (placed)
            ghostty_surface_mouse_pos(surface, x, y, mods);
        ghostty_surface_mouse_button(surface,
                                     event->type == GDK_BUTTON_PRESS ? GHOSTTY_MOUSE_PRESS
                                                                     : GHOSTTY_MOUSE_RELEASE,
                                     button_of(event->button.button), mods);
        break;
    case GDK_MOTION_NOTIFY:
    case GDK_ENTER_NOTIFY:
        if (placed)
            ghostty_surface_mouse_pos(surface, x, y, mods);
        break;
    case GDK_LEAVE_NOTIFY:
        /* Off the terminal: no cell is under the pointer. */
        ghostty_surface_mouse_pos(surface, -1, -1, mods);
        break;
    case GDK_SCROLL: {
        /* Ghostty's offsets are the other way from GTK's deltas, as its own
           GTK view sends them; a touchpad's are precise, and ten times. */
        gdouble dx = 0, dy = 0;
        bool precise = false;
        switch (event->scroll.direction) {
        case GDK_SCROLL_UP:
            dy = -1;
            break;
        case GDK_SCROLL_DOWN:
            dy = 1;
            break;
        case GDK_SCROLL_LEFT:
            dx = -1;
            break;
        case GDK_SCROLL_RIGHT:
            dx = 1;
            break;
        default: {
            gdk_event_get_scroll_deltas(event, &dx, &dy);
            GdkDevice *device = gdk_event_get_source_device(event);
            precise = device && gdk_device_get_source(device) == GDK_SOURCE_TOUCHPAD;
        }
        }
        double factor = precise ? -10 : -1;
        ghostty_surface_mouse_scroll(surface, dx * factor, dy * factor, precise ? 1 : 0);
        break;
    }
    default:
        break;
    }
}

/* JSON-escaped TEXT as a member NAME of DESCRIPTION. */
static void describe_text(struct json *description, const char *name, const char *text)
{
    char key[32];
    int length = snprintf(key, sizeof key, "\"%s\":", name);
    put(description, key, (size_t) length);
    put_string(description, (portal_string) {text ? text : "", text ? strlen(text) : 0});
    put(description, ",", 1);
}

static void terminal_describe(void *content, struct json *description)
{
    struct terminal *terminal = content;
    ghostty_surface_size_s size = {0};
    if (terminal->surface)
        size = ghostty_surface_size(terminal->surface);
    char facts[256];
    int length = snprintf(facts, sizeof facts,
                          "\"ready\":%s,%s\"columns\":%u,\"rows\":%u,"
                          "\"points\":%.2f,\"cell\":[%u,%u],",
                          terminal->surface ? "true" : "false",
                          terminal->fed ? ""
                          : terminal->exited ? "\"exited\":true," : "\"exited\":false,",
                          size.columns, size.rows, terminal->points, size.cell_width_px,
                          size.cell_height_px);
    put(description, facts, (size_t) length);
    /* A fed terminal's program runs elsewhere: the core describes it. */
    if (!terminal->fed) {
        describe_text(description, "title", terminal->title);
        describe_text(description, "pwd", terminal->pwd);
        describe_text(description, "program", terminal->program);
    }
    describe_text(description, "progress", terminal->progress);
    describe_text(description, "theme", terminal->theme);
    describe_text(description, "dark-theme", terminal->dark_theme);
    /* The opacities the background is drawn at: Ghostty's, and a fed
       terminal's backdrop's. */
    length = snprintf(facts, sizeof facts, "\"ghostty-opacity\":%.3f,", own_opacity(terminal));
    put(description, facts, (size_t) length);
    if (terminal->fed) {
        portal_pane_rect rect = terminal->fed->rect;
        length = snprintf(facts, sizeof facts,
                          "\"pane-opacity\":%.3f,\"placed\":[%.2f,%.2f,%.2f,%.2f],",
                          terminal->opacity, rect.x, rect.top, rect.width, rect.height);
        put(description, facts, (size_t) length);
    }
    portal_linux_stage_describe(terminal->stage, description);
}

static void terminal_copy(void *content)
{
    struct terminal *terminal = content;
    static const char action[] = "copy_to_clipboard";
    if (terminal->surface)
        ghostty_surface_binding_action(terminal->surface, action, sizeof action - 1);
}

static void terminal_paste(void *content, const char *text)
{
    struct terminal *terminal = content;
    if (terminal->surface)
        ghostty_surface_paste_text(terminal->surface, text, strlen(text));
}

static const struct portal_content_class terminal_class = {
    .stop = terminal_stop,
    .destroy = terminal_destroy,
    .configure = terminal_configure,
    .frame = terminal_frame,
    .focus = terminal_focus,
    .key = terminal_key,
    .text = terminal_text,
    .preedit = terminal_preedit,
    .pointer = terminal_pointer,
    .offer = NULL,
    .describe = terminal_describe,
    .copy = terminal_copy,
    .paste = terminal_paste,
};

/* Making one. */

/* The option NAME of OPTIONS, the last if repeated, or NULL. */
static const portal_option *option(const portal_option *options, size_t count, const char *name)
{
    const portal_option *found = NULL;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, name))
            found = &options[i];
    return found;
}

static char *string_option(const portal_option *options, size_t count, const char *name)
{
    const portal_option *found = option(options, count, name);
    return found && found->is_string ? g_strndup(found->string.data, found->string.length) : NULL;
}

bool portal_linux_terminal_create(struct portal_view *view, const portal_option *options,
                                  size_t count, portal_text *error)
{
    const portal_option *fed = option(options, count, "fed");
    bool feeding = fed && fed->flag;
    if (!app_start(view->wayland, error))
        return false;
    /* A fed terminal runs nothing here: the core has checked that it is
       given no command. */
    char *directory = feeding ? NULL : string_option(options, count, "directory");
    char *command = feeding ? NULL : string_option(options, count, "command");
    const portal_option *argv = feeding ? NULL : option(options, count, "argv");
    if (argv && argv->is_string) {
        g_free(command);
        command = argv_command(argv->string, directory ? directory : "/", error);
        if (!command) {
            g_free(directory);
            return false;
        }
    }
    const portal_option *points = option(options, count, "points");
    const portal_option *opacity = option(options, count, "opacity");
    struct terminal *terminal = calloc(1, sizeof *terminal);
    struct portal_stage *stage = terminal ? portal_linux_stage_new(view, &ghostty_source) : NULL;
    if (terminal) {
        terminal->view = view;
        terminal->fed = stage && feeding ? fed_new(terminal) : NULL;
    }
    if (!stage || (feeding && !terminal->fed)) {
        if (stage) {
            portal_linux_stage_stop(stage);
            portal_linux_stage_free(stage);
        }
        free(terminal);
        g_free(directory);
        free(command);
        return portal_linux_fail(error, "Portal is out of memory");
    }
    terminal->stage = stage;
    /* A fed terminal may leave part of its pane bare: the theme's
       background shows there, under it. */
    view->backdrop = feeding;
    /* A dark theme comes only with a light one (portal.h). */
    terminal->theme = string_option(options, count, "theme");
    terminal->dark_theme = string_option(options, count, "dark-theme");
    if (terminal->theme && !terminal->dark_theme)
        terminal->dark_theme = g_strdup(terminal->theme);
    terminal->points = portal_terminal_points(points && points->is_number ? points->number
                                                                          : PORTAL_TERMINAL_POINTS);
    terminal->opacity = opacity && opacity->is_number ? opacity->number : 1;
    ghostty_config_t config = terminal_config(terminal, error);
    if (config) {
        ghostty_env_var_s environment[] = {{"INSIDE_EMACS", "portal-ghostty"}};
        ghostty_surface_config_s surface = ghostty_surface_config_new();
        surface.platform_tag = GHOSTTY_PLATFORM_LINUX;
        surface.platform.linux_.egl_display = app.egl;
        surface.platform.linux_.frame_ready_cb = portal_linux_stage_ready;
        surface.platform.linux_.frame_ready_userdata = stage;
        surface.userdata = terminal;
        surface.scale_factor = 1;
        surface.font_size = (float) terminal->points;
        if (feeding) {
            /* What it would write to a pty, and each grid it takes, come
               to the fed terminal; and it starts at the scale it will
               likely have, so that a grid held before it is shown is held
               at its size. */
            surface.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
            surface.receive_userdata = terminal->fed;
            surface.receive_buffer = fed_written;
            surface.receive_resize = fed_resized;
            terminal->scale = scale_guess();
            surface.scale_factor = terminal->scale;
        } else {
            surface.working_directory = directory;
            surface.command = command;
            surface.env_vars = environment;
            surface.env_var_count = G_N_ELEMENTS(environment);
            /* Ghostty then reports the exit at once, as a close request,
               which leaves the view and its last output. */
            surface.wait_after_command = false;
        }
        terminal->surface = ghostty_surface_new(app.app, &surface);
        if (terminal->surface) {
            ghostty_surface_update_config(terminal->surface, config);
        } else {
            portal_linux_fail(error, "Ghostty could not make a terminal");
        }
        ghostty_config_free(config);
    }
    g_free(directory);
    free(command);
    if (terminal->surface && feeding && !fed_start(terminal->fed, terminal->surface)) {
        portal_linux_fail(error, "Portal could not start the thread that feeds a terminal");
        ghostty_surface_free(terminal->surface);
        terminal->surface = NULL;
    }
    if (terminal->surface && !portal_linux_stage_start(stage, terminal->surface, error)) {
        if (terminal->fed)
            fed_stop(terminal->fed);
        ghostty_surface_free(terminal->surface);
        terminal->surface = NULL;
    }
    if (!terminal->surface) {
        portal_linux_stage_stop(stage);
        portal_linux_stage_free(stage);
        fed_free(terminal->fed);
        /* The backdrop's colour, made for a view that is not to be. */
        if (view->under_buffer)
            wl_buffer_destroy(view->under_buffer);
        if (view->under_spent)
            wl_buffer_destroy(view->under_spent);
        view->under_buffer = view->under_spent = NULL;
        g_free(terminal->theme);
        g_free(terminal->dark_theme);
        free(terminal);
        return false;
    }
    /* Hidden until its view is shown: it draws nothing for nobody. */
    portal_linux_stage_configure(stage, false);
    view->flipped = true;
    view->class = &terminal_class;
    view->content = terminal;
    if (terminal->fed) {
        /* No pane yet, but its scale, and its cell. */
        fed_pane(terminal, 0, 0, terminal->scale);
        fed_cell(terminal);
    } else {
        terminal->sampler = g_timeout_add_seconds(1, sampled, terminal);
    }
    terminal->next = app.terminals;
    app.terminals = terminal;
    return true;
}

/* The terminal primitives of portal.h. */

static struct terminal *terminal_of(portal_view *view, portal_text *error)
{
    if (view->class == &terminal_class && ((struct terminal *) view->content)->surface)
        return view->content;
    portal_linux_fail(error, "This view shows Portal's test pattern, not a terminal");
    return NULL;
}

bool portal_terminal_list_themes(portal_text **names, size_t *count, portal_text *error)
{
    const char *resources;
    if (!portal_linux_ghostty_start(&resources, error))
        return false;
    char *path = g_build_filename(resources, "themes", NULL);
    DIR *directory = opendir(path);
    g_free(path);
    if (!directory)
        return portal_linux_fail(error, "Portal's build lacks Ghostty's themes: build Portal again");
    size_t size = 0, used = 0;
    portal_text *list = NULL;
    for (struct dirent *entry; (entry = readdir(directory));) {
        if (entry->d_name[0] == '.')
            continue;
        if (used == size) {
            size = size ? 2 * size : 1024;
            portal_text *larger = realloc(list, size * sizeof *list);
            if (!larger)
                break;
            list = larger;
        }
        char *name = strdup(entry->d_name);
        if (!name)
            break;
        list[used++] = (portal_text) {name, strlen(name)};
    }
    closedir(directory);
    *names = list;
    *count = used;
    return true;
}

/* Change TERMINAL's configuration with CHANGE, putting it back if Ghostty
   refuses the result. */
#define RECONFIGURE(terminal, change, error)                                                     \
    do {                                                                                         \
        char *was_theme = g_strdup((terminal)->theme);                                           \
        char *was_dark_theme = g_strdup((terminal)->dark_theme);                                 \
        double was_opacity = (terminal)->opacity, was_points = (terminal)->points;               \
        change;                                                                                  \
        if (!reconfigure((terminal), (error))) {                                                 \
            g_free((terminal)->theme);                                                           \
            g_free((terminal)->dark_theme);                                                      \
            (terminal)->theme = was_theme;                                                       \
            (terminal)->dark_theme = was_dark_theme;                                             \
            (terminal)->opacity = was_opacity;                                                   \
            (terminal)->points = was_points;                                                     \
            return false;                                                                        \
        }                                                                                        \
        g_free(was_theme);                                                                       \
        g_free(was_dark_theme);                                                                  \
    } while (0)

bool portal_terminal_apply_theme(portal_view *view, const portal_string *light,
                                 const portal_string *dark, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    RECONFIGURE(terminal,
                {
                    g_free(terminal->theme);
                    g_free(terminal->dark_theme);
                    terminal->theme = light ? g_strndup(light->data, light->length) : NULL;
                    terminal->dark_theme = dark ? g_strndup(dark->data, dark->length) : NULL;
                },
                error);
    return true;
}

bool portal_terminal_set_opacity(portal_view *view, double opacity, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    RECONFIGURE(terminal, terminal->opacity = opacity, error);
    return true;
}

bool portal_terminal_set_text_size(portal_view *view, double points, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    RECONFIGURE(terminal, terminal->points = points, error);
    return true;
}

bool portal_terminal_paste_text(portal_view *view, portal_string text, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    /* A portal_string is NUL-terminated, as Ghostty wants it. */
    ghostty_surface_paste_text(terminal->surface, text.data, text.length);
    return true;
}

bool portal_terminal_press_enter(portal_view *view, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    /* Return's XKB key code, on any layout. */
    ghostty_input_key_s key = {.action = GHOSTTY_ACTION_PRESS, .keycode = 36};
    ghostty_surface_key(terminal->surface, key);
    key.action = GHOSTTY_ACTION_RELEASE;
    ghostty_surface_key(terminal->surface, key);
    return true;
}

bool portal_terminal_read_text(portal_view *view, portal_text *text, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return false;
    static const char all[] = "select_all";
    if (!ghostty_surface_binding_action(terminal->surface, all, sizeof all - 1))
        return portal_linux_fail(error, "Ghostty could not select terminal text");
    ghostty_text_s selection = {0};
    char *copy;
    if (ghostty_surface_read_selection(terminal->surface, &selection)) {
        copy = g_utf8_make_valid(selection.text ? selection.text : "",
                                 (gssize) selection.text_len);
        ghostty_surface_free_text(terminal->surface, &selection);
    } else {
        copy = g_strdup("");
    }
    *text = (portal_text) {strdup(copy), strlen(copy)};
    g_free(copy);
    if (!text->data)
        return portal_linux_fail(error, "Portal is out of memory");
    return true;
}

/* A fed terminal's primitives, for the core's rules (portal.h). */

/* VIEW's fed terminal, or NULL with *ERROR set. */
static struct fed *fed_of(portal_view *view, portal_text *error)
{
    struct terminal *terminal = terminal_of(view, error);
    if (!terminal)
        return NULL;
    if (!terminal->fed)
        portal_linux_fail(error, "Only a fed terminal is fed its output");
    return terminal->fed;
}

bool portal_terminal_parse(portal_view *view, const char *bytes, size_t length,
                           portal_text *error)
{
    struct fed *fed = fed_of(view, error);
    return fed && fed_parse(fed, bytes, length, error);
}

bool portal_terminal_drain(portal_view *view, portal_text *error)
{
    struct fed *fed = fed_of(view, error);
    if (fed)
        fed_drain(fed);
    return fed;
}

bool portal_terminal_pending(portal_view *view, size_t *bytes, portal_text *error)
{
    struct fed *fed = fed_of(view, error);
    if (fed)
        *bytes = fed_pending(fed);
    return fed;
}

bool portal_terminal_place(portal_view *view, portal_pane_rect rect, portal_text *error)
{
    struct fed *fed = fed_of(view, error);
    if (fed)
        fed_place(fed, rect);
    return fed;
}

/* Held, the view keeps the frame it shows; let go, Ghostty draws again, so
   that its latest frame, passed over meanwhile, shows. */
bool portal_terminal_hold_frame(portal_view *view, bool hold, portal_text *error)
{
    struct fed *fed = fed_of(view, error);
    if (!fed)
        return false;
    portal_linux_view_hold(fed->terminal->view, hold);
    if (!hold && fed->terminal->surface)
        ghostty_surface_refresh(fed->terminal->surface);
    return true;
}
