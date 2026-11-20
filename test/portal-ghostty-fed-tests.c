/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A fed terminal on Linux: a surface of Ghostty's library as Portal builds
   it, with the host-managed backend of the first two of
   native/patches/ghostty, made, fed and read back with no window, no
   Wayland and no Emacs.  It is drawn too, on Mesa's surfaceless display,
   which the Linux platform takes when given no EGL display.

   What it checks is what a Rex block's screen rests on: the library has the
   calls; text written in is on the screen; what the terminal would have
   written to a pty reaches the host, and each new grid; a query in output
   written with ghostty_surface_write_buffer is answered, and one written
   with ghostty_surface_write_buffer_replay is not.

   Exits 77, skipped, when the surface cannot be made here: no EGL that
   renders without a display server. */
#define _POSIX_C_SOURCE 200809L

#include <ghostty.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;
/* How many checks ran: the program ends by printing it. */
static int checks;

#define CHECK(condition) check((condition), #condition, __LINE__)

static bool check(bool passed, const char *condition, int line)
{
    checks++;
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
    return passed;
}

static ghostty_app_t app;
/* Set from any thread when Ghostty wants its app ticked. */
static atomic_bool woken;

static void tick(void)
{
    if (atomic_exchange(&woken, false))
        ghostty_app_tick(app);
}

/* Check that CONDITION comes true within five seconds, ticking the app and
   looking again each millisecond. */
#define EVENTUALLY(condition) \
    do { \
        bool came_ = false; \
        for (int tries_ = 0; tries_ < 5000 && !(came_ = (condition)); tries_++) { \
            tick(); \
            nanosleep(&(struct timespec) {.tv_nsec = 1000000}, NULL); \
        } \
        check(came_, #condition, __LINE__); \
    } while (0)

/* What the surface handed the host, from Ghostty's threads. */
static struct {
    pthread_mutex_t lock;
    char bytes[4096];
    size_t length;
    uint16_t columns, rows;
    int resizes;
} host = {.lock = PTHREAD_MUTEX_INITIALIZER};

static atomic_int frames;

static void received(void *data, const uint8_t *bytes, size_t length)
{
    (void) data;
    pthread_mutex_lock(&host.lock);
    if (length > sizeof host.bytes - host.length)
        length = sizeof host.bytes - host.length;
    memcpy(host.bytes + host.length, bytes, length);
    host.length += length;
    pthread_mutex_unlock(&host.lock);
}

static void resized(void *data, uint16_t columns, uint16_t rows, uint32_t width, uint32_t height)
{
    (void) data, (void) width, (void) height;
    pthread_mutex_lock(&host.lock);
    host.columns = columns;
    host.rows = rows;
    host.resizes++;
    pthread_mutex_unlock(&host.lock);
}

/* What the host has been handed since the last call, as a string. */
static void take(char *into, size_t size)
{
    pthread_mutex_lock(&host.lock);
    size_t length = host.length < size - 1 ? host.length : size - 1;
    memcpy(into, host.bytes, length);
    into[length] = '\0';
    host.length = 0;
    pthread_mutex_unlock(&host.lock);
}

/* Whether the host has been handed TEXT, as the end of what it has. */
static bool handed(const char *text)
{
    size_t length = strlen(text);
    pthread_mutex_lock(&host.lock);
    bool found = host.length >= length &&
                 !memcmp(host.bytes + host.length - length, text, length);
    pthread_mutex_unlock(&host.lock);
    return found;
}

/* Whether the host's last grid is the surface's. */
static bool gridded(ghostty_surface_t surface)
{
    ghostty_surface_size_s size = ghostty_surface_size(surface);
    pthread_mutex_lock(&host.lock);
    bool same = host.resizes && host.columns == size.columns && host.rows == size.rows;
    pthread_mutex_unlock(&host.lock);
    return same;
}

static void frame_ready(void *data)
{
    (void) data;
    atomic_fetch_add(&frames, 1);
}

static void wakeup(void *data)
{
    (void) data;
    atomic_store(&woken, true);
}

static bool act(ghostty_app_t ghostty, ghostty_target_s target, ghostty_action_s action)
{
    (void) ghostty, (void) target, (void) action;
    return false;
}

static ghostty_clipboard_read_result_e read_clipboard(void *data, ghostty_clipboard_e which,
                                                      void *state, const char *const *types,
                                                      size_t count, bool list)
{
    (void) data, (void) which, (void) state, (void) types, (void) count, (void) list;
    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
}

static void confirm_read_clipboard(void *data, const ghostty_clipboard_confirm_s *confirm,
                                   void *state, ghostty_clipboard_request_e kind)
{
    (void) data, (void) confirm, (void) state, (void) kind;
}

static void write_clipboard(void *data, ghostty_clipboard_e which,
                            const ghostty_clipboard_content_s *contents, size_t count,
                            bool confirm)
{
    (void) data, (void) which, (void) contents, (void) count, (void) confirm;
}

static void close_surface(void *data, bool process_alive)
{
    (void) data, (void) process_alive;
}

static void feed(ghostty_surface_t surface, const char *text)
{
    ghostty_surface_write_buffer(surface, (const uint8_t *) text, strlen(text));
}

static void replay(ghostty_surface_t surface, const char *text)
{
    ghostty_surface_write_buffer_replay(surface, (const uint8_t *) text, strlen(text));
}

/* Whether the screen, scrollback and all, shows TEXT. */
static bool shows(ghostty_surface_t surface, const char *text)
{
    ghostty_selection_s all = {
        .top_left = {GHOSTTY_POINT_SCREEN, GHOSTTY_POINT_COORD_TOP_LEFT, 0, 0},
        .bottom_right = {GHOSTTY_POINT_SCREEN, GHOSTTY_POINT_COORD_BOTTOM_RIGHT, 0, 0},
        .rectangle = false,
    };
    ghostty_text_s screen;
    if (!ghostty_surface_read_text(surface, all, &screen))
        return false;
    bool found = screen.text && strstr(screen.text, text);
    ghostty_surface_free_text(surface, &screen);
    return found;
}

int main(int argc, char **argv)
{
    /* The resources the build installed, as the module sets them. */
    if (argc > 1)
        setenv("GHOSTTY_RESOURCES_DIR", argv[1], 1);
    char program[] = "portal-ghostty-fed-tests", *arguments[] = {program, NULL};
    if (ghostty_init(1, arguments)) {
        fprintf(stderr, "Ghostty's library failed to start\n");
        return 1;
    }

    /* Ghostty's defaults: no configuration file of the user's is read. */
    ghostty_config_t config = ghostty_config_new();
    ghostty_config_finalize(config);
    ghostty_runtime_config_s runtime = {
        .wakeup_cb = wakeup,
        .action_cb = act,
        .read_clipboard_cb = read_clipboard,
        .confirm_read_clipboard_cb = confirm_read_clipboard,
        .write_clipboard_cb = write_clipboard,
        .close_surface_cb = close_surface,
    };
    app = ghostty_app_new(&runtime, config);
    ghostty_config_free(config);
    if (!app) {
        fprintf(stderr, "Ghostty could not start its app\n");
        return 1;
    }

    ghostty_surface_config_s settings = ghostty_surface_config_new();
    settings.platform_tag = GHOSTTY_PLATFORM_LINUX;
    settings.platform.linux_.egl_display = NULL;
    settings.platform.linux_.frame_ready_cb = frame_ready;
    settings.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
    settings.receive_buffer = received;
    settings.receive_resize = resized;
    settings.scale_factor = 1;
    ghostty_surface_t surface = ghostty_surface_new(app, &settings);
    if (!surface) {
        fprintf(stderr, "skipped: Ghostty could not make a surface here, "
                        "which needs an EGL that renders with no display server\n");
        ghostty_app_free(app);
        return 77;
    }

    /* A grid for a size, handed to the host as a pty's would be: the last
       the host is handed is the surface's. */
    ghostty_surface_set_size(surface, 800, 480);
    ghostty_surface_size_s size = ghostty_surface_size(surface);
    CHECK(size.width_px == 800 && size.height_px == 480);
    CHECK(size.columns > 10 && size.rows > 5);
    EVENTUALLY(gridded(surface));

    /* Fed text is on the screen, read back as a host reads it. */
    feed(surface, "fed from the host\r\n");
    CHECK(shows(surface, "fed from the host"));
    /* And split anywhere, even within a sequence. */
    feed(surface, "\x1b[1");
    feed(surface, "mbold\x1b[0m and plain\r\n");
    CHECK(shows(surface, "bold and plain"));

    /* A query written with write_buffer is answered, to the host. */
    feed(surface, "\x1b[5n");
    EVENTUALLY(handed("\x1b[0n"));
    char answer[256];
    take(answer, sizeof answer);
    CHECK(!strcmp(answer, "\x1b[0n"));

    /* One replayed is not: the device attributes, the cursor's place, the
       text area's size and the background colour, each followed by a query
       fed as above, whose answer comes after any the replay made.  Each of
       them is answered when fed. */
    const char *queries[] = {"\x1b[c", "\x1b[6n", "\x1b[18t", "\x1b]11;?\x1b\\"};
    for (size_t i = 0; i < sizeof queries / sizeof *queries; i++) {
        replay(surface, queries[i]);
        feed(surface, "\x1b[5n");
        EVENTUALLY(handed("\x1b[0n"));
        take(answer, sizeof answer);
        if (!CHECK(!strcmp(answer, "\x1b[0n")))
            fprintf(stderr, "  replayed query %zu answered: %zu bytes\n", i, strlen(answer));
    }
    /* The same device attributes fed are answered: the replay's silence is
       not the query's. */
    feed(surface, "\x1b[c");
    feed(surface, "\x1b[5n");
    EVENTUALLY(handed("\x1b[0n"));
    take(answer, sizeof answer);
    CHECK(!strncmp(answer, "\x1b[?", 3) && strlen(answer) > strlen("\x1b[0n"));

    /* A replay is parsed as a feed is, screen and all. */
    replay(surface, "\x1b[2Jreplayed history\r\n");
    CHECK(shows(surface, "replayed history"));

    /* And drawn, with no window to draw for. */
    ghostty_surface_draw(surface);
    EVENTUALLY(atomic_load(&frames) > 0);
    ghostty_frame_s *frame = ghostty_surface_take_frame(surface);
    if (CHECK(frame != NULL)) {
        CHECK(frame->width == 800 && frame->height == 480);
        ghostty_frame_free(frame);
    }

    ghostty_surface_free(surface);
    ghostty_app_free(app);
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
