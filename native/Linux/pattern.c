/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The test pattern: a view's content for the checks of the view machinery,
   made with the option :test-pattern, whatever the view's kind.  It shows
   where a view is to the pixel, draws from a thread as a terminal's
   presenter will, and describes the input it was given.

   What it draws, in device pixels, one buffer pixel each: an edge one pixel
   wide in red, a fill in magenta, and in the middle a square that takes
   the next of 64 blues with each frame.  With :test-pattern "fill" it is a
   single pixel of the magenta instead, whose blue moves a little with each
   frame, presented as a frame that fills the pane.

   Its thread draws a frame when the pane changes and at each frame
   callback, so it draws as fast as the compositor shows, whatever Emacs is
   doing.  It keeps three buffers of the pane's size in shared memory and
   draws into one the compositor has released.

   What it describes, for portal--inspect: "pattern", true; "frames", how
   many of its frames reached the screen; "drawn", the width and height of
   the last frame it drew, in device pixels; "text", what the input method
   committed and what was pasted; "preedit", what it is composing; "keys",
   the key presses its content got, as names with C-, M-, s- and S- for the
   modifiers held, separated by spaces, with "up:" before a release;
   "offered", the presses the core offered its app; "pointer", where the
   pointer last was in the pane; "presses" and "releases" of its buttons;
   "scrolled", the vertical scrolling in hundredths of a step; "motions";
   and "inside", whether the pointer is over it.

   A web view's app is offered each chord.  The pattern's answers later,
   from the main loop: it uses a chord whose character is in the option
   :uses, a string, and no other. */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <unistd.h>

#include "linux.h"

enum { BUFFERS = 3, TICKER = 64, RECORD = 512 };

static const uint32_t edge_color = 0xffff0000, fill_color = 0xffd93399;

/* One buffer in shared memory.  The thread's alone. */
struct canvas {
    struct wl_buffer *buffer; /* NULL: unused. */
    uint32_t *pixels;
    size_t size;
    int32_t width, height;
    bool busy;  /* With the compositor, or held by the view. */
    bool drawn; /* It has the edge and the fill. */
};

struct pattern {
    struct portal_view *view;
    struct wl_shm *shm; /* A wrapper on the view's queue. */
    bool fill;
    char *uses;
    pthread_t thread;
    int wake; /* An eventfd the thread waits on with the display. */

    /* What the main thread tells the thread, under LOCK. */
    pthread_mutex_t lock;
    int32_t width, height, scale;
    bool shown, stop;
    uint64_t changes; /* Counts each change, so the thread sees one. */

    /* The thread's. */
    struct canvas canvases[BUFFERS];
    bool due; /* A frame callback came, or the pane changed. */
    uint32_t tick;
    atomic_ullong frames;
    atomic_int drawn_width, drawn_height;

    /* The main thread's: the input it was given. */
    GString *text, *keys;
    char *composing;
    int offered, presses, releases, scrolled, motions;
    int pointer_x, pointer_y;
    bool inside;
};

/* The thread. */

static void released(void *data, struct wl_buffer *buffer)
{
    struct pattern *pattern = data;
    for (size_t i = 0; i < BUFFERS; i++)
        if (pattern->canvases[i].buffer == buffer)
            pattern->canvases[i].busy = false;
}

static const struct wl_buffer_listener buffer_listener = {released};

static void canvas_free(struct canvas *canvas)
{
    if (!canvas->buffer)
        return;
    wl_buffer_destroy(canvas->buffer);
    munmap(canvas->pixels, canvas->size);
    *canvas = (struct canvas) {0};
}

/* Make CANVAS a buffer WIDTH by HEIGHT, on the view's queue. */
static bool canvas_make(struct pattern *pattern, struct canvas *canvas, int32_t width,
                        int32_t height)
{
    size_t size = (size_t) width * (size_t) height * 4;
    int memory = memfd_create("portal-test-pattern", MFD_CLOEXEC);
    if (memory < 0 || ftruncate(memory, (off_t) size) < 0) {
        if (memory >= 0)
            close(memory);
        return false;
    }
    void *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, memory, 0);
    if (pixels == MAP_FAILED) {
        close(memory);
        return false;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(pattern->shm, memory, (int32_t) size);
    canvas->buffer =
        wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(memory);
    wl_buffer_add_listener(canvas->buffer, &buffer_listener, pattern);
    canvas->pixels = pixels;
    canvas->size = size;
    canvas->width = width;
    canvas->height = height;
    canvas->busy = canvas->drawn = false;
    return true;
}

/* A buffer WIDTH by HEIGHT that the compositor does not have, or NULL while
   it has them all.  Buffers of another size go as they come back. */
static struct canvas *canvas_available(struct pattern *pattern, int32_t width, int32_t height)
{
    struct canvas *unused = NULL;
    for (size_t i = 0; i < BUFFERS; i++) {
        struct canvas *canvas = &pattern->canvases[i];
        if (canvas->busy)
            continue;
        if (canvas->buffer && (canvas->width != width || canvas->height != height))
            canvas_free(canvas);
        if (canvas->buffer)
            return canvas;
        unused = canvas;
    }
    return unused && canvas_make(pattern, unused, width, height) ? unused : NULL;
}

/* Draw the next frame for a pane WIDTH by HEIGHT at SCALE, and present
   it. */
static void draw(struct pattern *pattern, int32_t width, int32_t height, int32_t scale)
{
    int32_t columns = pattern->fill ? 1 : width * scale, rows = pattern->fill ? 1 : height * scale;
    struct canvas *canvas = canvas_available(pattern, columns, rows);
    if (!canvas)
        return; /* The next release or frame callback draws. */
    uint32_t tick = pattern->tick++;
    int32_t damage[4] = {0, 0, columns, rows};
    if (pattern->fill) {
        canvas->pixels[0] = fill_color + (tick & 31);
    } else {
        if (!canvas->drawn) {
            for (int32_t y = 0; y < rows; y++) {
                uint32_t *row = canvas->pixels + (size_t) y * (size_t) columns;
                bool border = y == 0 || y == rows - 1;
                for (int32_t x = 0; x < columns; x++)
                    row[x] = border || x == 0 || x == columns - 1 ? edge_color : fill_color;
            }
            canvas->drawn = true;
        }
        /* The square, inside the edge, in a buffer large enough for one. */
        int32_t side = MIN(TICKER, MIN(columns, rows) - 2);
        if (side > 0) {
            int32_t left = (columns - side) / 2, top = (rows - side) / 2;
            uint32_t blue = 0xff0000ff | ((tick & 63) * 4) << 8;
            for (int32_t y = top; y < top + side; y++)
                for (int32_t x = left; x < left + side; x++)
                    canvas->pixels[(size_t) y * (size_t) columns + (size_t) x] = blue;
            damage[0] = left, damage[1] = top, damage[2] = damage[3] = side;
        }
    }
    atomic_store(&pattern->drawn_width, columns);
    atomic_store(&pattern->drawn_height, rows);
    struct wl_buffer *unused = NULL;
    enum portal_presented presented =
        portal_linux_present(pattern->view, canvas->buffer, pattern->fill ? 0 : columns,
                             pattern->fill ? 0 : rows, damage, &unused);
    canvas->busy = presented != PORTAL_REFUSED;
    if (unused)
        released(pattern, unused);
    /* The frame callback of a frame that is shown asks for the next. */
    pattern->due = false;
}

static void *run(void *data)
{
    struct pattern *pattern = data;
    struct wl_display *display = pattern->view->wayland->display;
    struct wl_event_queue *queue = pattern->view->queue;
    uint64_t seen = 0;
    for (;;) {
        pthread_mutex_lock(&pattern->lock);
        bool stop = pattern->stop, shown = pattern->shown;
        int32_t width = pattern->width, height = pattern->height, scale = pattern->scale;
        if (pattern->changes != seen)
            pattern->due = true;
        seen = pattern->changes;
        pthread_mutex_unlock(&pattern->lock);
        if (stop)
            break;
        if (shown && pattern->due && width > 0 && height > 0)
            draw(pattern, width, height, scale > 0 ? scale : 1);
        /* Read the display with GDK, which reads it on the main thread:
           whoever reads queues the other's events.  Events GDK has read
           for this queue may be a frame callback, which asks for a frame:
           back to the drawing, not on to a wait that nothing would end. */
        if (wl_display_prepare_read_queue(display, queue) != 0) {
            if (wl_display_dispatch_queue_pending(display, queue) < 0)
                break;
            continue;
        }
        wl_display_flush(display);
        struct pollfd waits[] = {{wl_display_get_fd(display), POLLIN, 0},
                                 {pattern->wake, POLLIN, 0}};
        int ready;
        do
            ready = poll(waits, 2, -1);
        while (ready < 0 && errno == EINTR);
        if (ready > 0 && (waits[0].revents & POLLIN))
            wl_display_read_events(display);
        else
            wl_display_cancel_read(display);
        if (ready > 0 && (waits[1].revents & POLLIN)) {
            uint64_t count;
            if (read(pattern->wake, &count, sizeof count) < 0)
                count = 0;
        }
        if (wl_display_dispatch_queue_pending(display, queue) < 0)
            break; /* The display is gone, and Emacs with it. */
    }
    return NULL;
}

static void wake(struct pattern *pattern)
{
    uint64_t one = 1;
    if (write(pattern->wake, &one, sizeof one) < 0)
        return;
}

/* The class. */

static void pattern_destroy(void *content)
{
    struct pattern *pattern = content;
    pthread_mutex_lock(&pattern->lock);
    pattern->stop = true;
    pthread_mutex_unlock(&pattern->lock);
    wake(pattern);
    pthread_join(pattern->thread, NULL);
    /* Every proxy on the view's queue, before the view destroys the queue. */
    for (size_t i = 0; i < BUFFERS; i++)
        canvas_free(&pattern->canvases[i]);
    wl_proxy_wrapper_destroy(pattern->shm);
    close(pattern->wake);
    pthread_mutex_destroy(&pattern->lock);
    g_string_free(pattern->text, TRUE);
    g_string_free(pattern->keys, TRUE);
    g_free(pattern->composing);
    g_free(pattern->uses);
    free(pattern);
}

static void pattern_configure(void *content, int32_t width, int32_t height, int32_t scale,
                              bool shown)
{
    struct pattern *pattern = content;
    pthread_mutex_lock(&pattern->lock);
    pattern->width = width;
    pattern->height = height;
    pattern->scale = scale;
    pattern->shown = shown;
    pattern->changes++;
    pthread_mutex_unlock(&pattern->lock);
    wake(pattern);
}

static void pattern_frame(void *content, uint32_t time)
{
    (void) time;
    struct pattern *pattern = content;
    atomic_fetch_add(&pattern->frames, 1);
    pattern->due = true;
}

static void pattern_focus(void *content, bool focused)
{
    (void) content, (void) focused;
}

/* Add WORD to RECORD, which keeps the latest of what it is given. */
static void note(GString *record, const char *word, bool spaced)
{
    if (spaced && record->len)
        g_string_append_c(record, ' ');
    g_string_append(record, word);
    if (record->len > RECORD) {
        /* Whole characters: what it describes is UTF-8. */
        gsize cut = record->len - RECORD;
        while (cut < record->len && ((guchar) record->str[cut] & 0xc0) == 0x80)
            cut++;
        g_string_erase(record, 0, (gssize) cut);
    }
}

/* EVENT's key as "C-M-s-S-name". */
static void name_key(const GdkEventKey *event, char *name, size_t size)
{
    const char *symbol = gdk_keyval_name(event->keyval);
    snprintf(name, size, "%s%s%s%s%s%s", event->type == GDK_KEY_RELEASE ? "up:" : "",
             event->state & GDK_CONTROL_MASK ? "C-" : "",
             event->state & (GDK_MOD1_MASK | GDK_META_MASK) ? "M-" : "",
             event->state & (GDK_MOD4_MASK | GDK_SUPER_MASK) ? "s-" : "",
             event->state & GDK_SHIFT_MASK ? "S-" : "", symbol ? symbol : "?");
}

static void pattern_key(void *content, const GdkEventKey *event, const char *text,
                        bool composing)
{
    (void) composing;
    struct pattern *pattern = content;
    char name[96];
    /* A key that types is its text, as the input method committed it. */
    if (text) {
        note(pattern->text, text, false);
        return;
    }
    if (event->is_modifier)
        return;
    name_key(event, name, sizeof name);
    note(pattern->keys, name, true);
}

static void pattern_text(void *content, const char *text)
{
    struct pattern *pattern = content;
    note(pattern->text, text, false);
}

static void pattern_preedit(void *content, const char *text, int cursor)
{
    (void) cursor;
    struct pattern *pattern = content;
    g_free(pattern->composing);
    pattern->composing = g_strdup(text);
}

static void pattern_pointer(void *content, const GdkEvent *event)
{
    struct pattern *pattern = content;
    gdouble x, y;
    if (gdk_event_get_coords(event, &x, &y)) {
        pattern->pointer_x = (int) x;
        pattern->pointer_y = (int) y;
    }
    switch (event->type) {
    case GDK_BUTTON_PRESS:
        pattern->presses++;
        break;
    case GDK_BUTTON_RELEASE:
        pattern->releases++;
        break;
    case GDK_MOTION_NOTIFY:
        pattern->motions++;
        break;
    case GDK_SCROLL: {
        gdouble dx = 0, dy = 0;
        if (event->scroll.direction == GDK_SCROLL_UP)
            dy = -1;
        else if (event->scroll.direction == GDK_SCROLL_DOWN)
            dy = 1;
        else
            gdk_event_get_scroll_deltas(event, &dx, &dy);
        pattern->scrolled += (int) (dy * 100);
        break;
    }
    case GDK_ENTER_NOTIFY:
        pattern->inside = true;
        break;
    case GDK_LEAVE_NOTIFY:
        pattern->inside = false;
        break;
    default:
        break;
    }
}

struct answer {
    uint64_t view; /* Its serial. */
    bool used;
};

static gboolean answer(gpointer data)
{
    struct answer *answer = data;
    /* The view may have ended before its app answered. */
    struct portal_view *view = portal_linux_view_find(answer->view);
    if (view)
        portal_linux_input_settle(view, answer->used);
    return G_SOURCE_REMOVE;
}

static void pattern_offer(void *content, const GdkEventKey *event)
{
    struct pattern *pattern = content;
    char name[96];
    gunichar character = gdk_keyval_to_unicode(gdk_keyval_to_lower(event->keyval));
    struct answer *later = g_new(struct answer, 1);
    later->view = pattern->view->serial;
    later->used = character && pattern->uses && g_utf8_strchr(pattern->uses, -1, character);
    pattern->offered++;
    if (later->used) {
        name_key(event, name, sizeof name);
        note(pattern->keys, name, true);
    }
    g_idle_add_full(G_PRIORITY_DEFAULT, answer, later, g_free);
}

static void pattern_describe(void *content, struct json *json)
{
    struct pattern *pattern = content;
    char facts[320];
    int length = snprintf(facts, sizeof facts,
                          "\"pattern\":true,\"frames\":%llu,\"drawn\":[%d,%d],\"offered\":%d,"
                          "\"pointer\":[%d,%d],\"presses\":%d,\"releases\":%d,\"scrolled\":%d,"
                          "\"motions\":%d,\"inside\":%s,",
                          atomic_load(&pattern->frames), atomic_load(&pattern->drawn_width),
                          atomic_load(&pattern->drawn_height), pattern->offered,
                          pattern->pointer_x, pattern->pointer_y, pattern->presses,
                          pattern->releases, pattern->scrolled, pattern->motions,
                          pattern->inside ? "true" : "false");
    put(json, facts, (size_t) length);
    const struct {
        const char *name, *value;
    } strings[] = {{"\"text\":", pattern->text->str},
                   {"\"keys\":", pattern->keys->str},
                   {"\"preedit\":", pattern->composing ? pattern->composing : ""}};
    for (size_t i = 0; i < G_N_ELEMENTS(strings); i++) {
        put(json, strings[i].name, strlen(strings[i].name));
        put_string(json, (portal_string) {strings[i].value, strlen(strings[i].value)});
        put(json, ",", 1);
    }
}

static void pattern_copy(void *content)
{
    struct pattern *pattern = content;
    gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), pattern->text->str, -1);
}

static void pattern_paste(void *content, const char *text)
{
    struct pattern *pattern = content;
    note(pattern->text, text, false);
}

static const struct portal_content_class pattern_class = {
    .stop = NULL,
    .destroy = pattern_destroy,
    .configure = pattern_configure,
    .frame = pattern_frame,
    .focus = pattern_focus,
    .key = pattern_key,
    .text = pattern_text,
    .preedit = pattern_preedit,
    .pointer = pattern_pointer,
    .offer = pattern_offer,
    .describe = pattern_describe,
    .copy = pattern_copy,
    .paste = pattern_paste,
};

bool portal_linux_pattern_create(struct portal_view *view, const portal_option *options,
                                 size_t count, portal_text *error)
{
    struct pattern *pattern = calloc(1, sizeof *pattern);
    if (!pattern)
        return portal_linux_fail(error, "Portal is out of memory");
    for (size_t i = 0; i < count; i++) {
        if (is(options[i].name, "test-pattern"))
            pattern->fill = options[i].is_string && is(options[i].string, "fill");
        if (is(options[i].name, "uses")) {
            g_free(pattern->uses);
            pattern->uses = options[i].is_string
                                ? g_strndup(options[i].string.data, options[i].string.length)
                                : NULL;
        }
    }
    pattern->view = view;
    pattern->wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (pattern->wake < 0) {
        g_free(pattern->uses);
        free(pattern);
        return portal_linux_fail(error, "Portal's test pattern could not make an eventfd");
    }
    pattern->shm = wl_proxy_create_wrapper(view->wayland->shm);
    wl_proxy_set_queue((struct wl_proxy *) pattern->shm, view->queue);
    pattern->text = g_string_new(NULL);
    pattern->keys = g_string_new(NULL);
    pthread_mutex_init(&pattern->lock, NULL);
    view->class = &pattern_class;
    view->content = pattern;
    if (pthread_create(&pattern->thread, NULL, run, pattern)) {
        wl_proxy_wrapper_destroy(pattern->shm);
        close(pattern->wake);
        pthread_mutex_destroy(&pattern->lock);
        g_string_free(pattern->text, TRUE);
        g_string_free(pattern->keys, TRUE);
        g_free(pattern->uses);
        free(pattern);
        return portal_linux_fail(error, "Portal's test pattern could not start its thread");
    }
    return true;
}
