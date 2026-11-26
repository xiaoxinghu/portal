/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A page: a web view's content, WPE WebKit drawing through a platform of
   Portal's own.  Built into portal-web.so, which portal.so opens at the
   first web view (web.h): only this file includes WPE WebKit's headers.

   WPEPlatform asks a host for three classes, subclassed here: a display,
   which names the GPU and makes the rest; a toplevel, which carries the
   size and scale; and a view, which WebKit hands each finished frame, a
   DMABUF, in render_buffer.  The view gives that frame to the presenter's
   stage, as a terminal's renderer does (presenter.c): the presenter
   imports it as a wl_buffer, presents it to the Portal view at a frame
   callback, tells WebKit it was shown at the frame callback after that
   (wpe_view_buffer_rendered, which is when WebKit draws the next), and
   that its buffer is free once the compositor releases it
   (wpe_view_buffer_released).

   Threads.  WebKit runs on a thread of its own, iterating a GLib context
   of its own, so that a page draws, plays and scrolls while Lisp is busy
   or collecting.  Every call into WebKit goes to that thread (on_webkit),
   and what WebKit tells Portal comes back to Emacs's main thread through
   GLib's default context (on_main).  Two calls wait for WebKit's thread:
   making a page and ending one.  WebKit's thread never waits for Emacs's.

   Input.  A key comes from the view's widget (input.c) with the text the
   input method committed for it, which an input method context of the
   page's hands to WebKit as the key's text.  WebKit does not say whether
   a page used a key: WPE's PageClientImpl::doneWithKeyEvent is empty.  The
   key script, in a world of its own in every frame, reports each trusted
   keydown after its dispatch, with its modifiers, its time and whether the
   page prevented its default; the time, which Portal gave the press, says
   which press the report is for (event_time); and an offered chord is
   used when the page prevented it (key_reported). */
#define _GNU_SOURCE
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>

#include "web.h"

#ifndef EGL_DRM_RENDER_NODE_FILE_EXT
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377
#endif

/* What the page calls in portal.so. */
static const struct portal_web_host *host;

static struct {
    GMainContext *context; /* WebKit's thread's. */
    /* WebKit's thread and Emacs's main thread.  A call for one of them runs
       at once only on it: g_main_context_invoke would run it on any thread
       that can acquire the context. */
    GThread *owner, *main;
    WPEDisplay *display;
    const struct portal_wayland *wayland;
    /* Pages draw in memory, as decided at the first (webkit_start). */
    bool memory;
} webkit;

/* Calls between threads. */

/* Run CALL with DATA on OWNER, the thread that iterates CONTEXT: now, if
   this is that thread, or else from CONTEXT, in the order asked. */
static void run_on(GThread *owner, GMainContext *context, GSourceFunc call, gpointer data,
                   GDestroyNotify free_data)
{
    if (owner && g_thread_self() == owner) {
        call(data);
        if (free_data)
            free_data(data);
        return;
    }
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, call, data, free_data);
    g_source_attach(source, context);
    g_source_unref(source);
}

/* Run CALL with DATA on WebKit's thread: now, if this is that thread. */
static void on_webkit(GSourceFunc call, gpointer data, GDestroyNotify free_data)
{
    run_on(webkit.owner, webkit.context, call, data, free_data);
}

struct waited {
    GSourceFunc call;
    gpointer data;
    GMutex lock;
    GCond done_cond;
    bool done;
};

static gboolean waited_run(gpointer data)
{
    struct waited *waited = data;
    waited->call(waited->data);
    g_mutex_lock(&waited->lock);
    waited->done = true;
    g_cond_signal(&waited->done_cond);
    g_mutex_unlock(&waited->lock);
    return G_SOURCE_REMOVE;
}

/* Run CALL with DATA on WebKit's thread and wait for it to return: only
   from Emacs's main thread, which WebKit's never waits for. */
static void on_webkit_wait(GSourceFunc call, gpointer data)
{
    struct waited waited = {.call = call, .data = data};
    g_mutex_init(&waited.lock);
    g_cond_init(&waited.done_cond);
    run_on(NULL, webkit.context, waited_run, &waited, NULL);
    g_mutex_lock(&waited.lock);
    while (!waited.done)
        g_cond_wait(&waited.done_cond, &waited.lock);
    g_mutex_unlock(&waited.lock);
    g_mutex_clear(&waited.lock);
    g_cond_clear(&waited.done_cond);
}

/* Run CALL with DATA on Emacs's main thread, from GLib's default context,
   which Emacs runs whenever it waits for input. */
static void on_main(GSourceFunc call, gpointer data, GDestroyNotify free_data)
{
    run_on(webkit.main, g_main_context_default(), call, data, free_data);
}

/* The page. */

/* The presses given to WebKit that the key script has not reported yet,
   at most this many. */
enum { PRESSES = 64 };

struct press {
    uint64_t number;
    guint32 time; /* The time WebKit was given it at: see event_time. */
    bool control, alt, meta;
    bool modifier; /* A modifier key's own press, whose modifiers WebKit adds. */
};

/* Presses are given to WebKit at least this many milliseconds apart, and a
   report is its press's if its time is within this much of the press's. */
enum { PRESS_SPACING = 5 };
static const double report_tolerance = 2.5;

struct page {
    struct portal_view *view; /* The main thread's. */
    uint64_t serial;
    struct portal_stage *stage;

    /* WebKit's thread's. */
    WebKitWebView *web;
    WPEView *wpe;
    WPEToplevel *toplevel;
    WPEInputMethodContext *method;
    /* The web view's context, for DIRECTORY or none: see context_of. */
    WebKitWebContext *context;
    char *directory;
    const char *typing; /* The text of the key being given to WebKit. */
    char *preedit;
    int preedit_cursor;
    bool mapped;
    /* What the main thread last told WebKit's of the view, for a web view
       made again (load_on_webkit). */
    int32_t width, height, scale;
    bool shown, focused;

    /* The latest frame WebKit rendered and the stage has not taken, and
       the WebKit view that rendered it, under LOCK: the presenter's thread
       takes them, and never reads WPE, which a web view made again
       replaces on WebKit's (page_remake). */
    pthread_mutex_t lock;
    WPEBuffer *latest;
    WPEView *latest_view;

    /* What WebKit said of the page, the main thread's. */
    char *url, *title, *error;
    bool loading;
    const char *cursor;
    bool terminated;

    /* Keys, the main thread's.  Each press given to WebKit is numbered and
       kept in PRESSES until the key script reports it, with the time it
       was given at, which travels with it: WebKit makes the keydown's
       time from it (event_time), and the report says that time on the
       document's clock.  So within a document a report's time less its
       press's is the same for every press, OFFSET, to the coarseness of
       the document's clock; and a report is the press's whose time it
       fits, which a press that never reports cannot take from another.
       Presses older than the one a report is for are dropped: theirs never
       came.  OFFSET is learned, CALIBRATED, from the first report that
       came with one press waiting, which is that press's, and follows each
       report after, as the document's clock drifts from Emacs's.  A report
       no later than a press dropped from a full queue is that press's.
       Three reports in a row that fit no press, as when the wall clock was
       set, leave the page ADRIFT: no report settles an offer, each giving
       up, until the document or its process goes.  Before calibration, a
       report is the oldest press's whose modifiers are its own, as WebKit
       dispatches presses in order and the script reports them in order.
       A press numbered OFFER_NUMBER is with the page while OFFERING: the
       report for that press, and for no other, settles it. */
    uint64_t pressed;
    GQueue presses;
    bool calibrated;
    double offset;
    unsigned misses;
    /* Calibration was lost: no report settles an offer until the document
       or its process goes (presses_clear), as reports still on their way
       could not be told from a new press's. */
    bool adrift;
    /* The time of the newest press dropped from PRESSES, or 0: a report of
       that time or before is a dropped press's. */
    guint32 dropped_until;
    /* Reports still to come, before calibration, for presses dropped from
       PRESSES, which a busy page let pile up past its length: the next
       this many are theirs.  Should one never come, no report settles an
       offer, which then gives up, until the document or its process goes.
       Calibrated, a dropped press's report fits no press. */
    unsigned dropped;
    bool offering;
    guint offer_timer;
    uint64_t offer_number;

    /* The compositor took no DMABUF of the page's: it shows nothing. */
    atomic_bool unshowable;
    atomic_ullong rendered, memory_frames;
};

/* What a frame taken holds: references to WebKit's buffer and view, given
   back on WebKit's thread. */
struct held {
    struct portal_linux_frame frame;
    WPEView *view;
    WPEBuffer *buffer;
};

static GQuark texture_quark;
static atomic_ullong textures;

/* The platform's classes. */

G_DECLARE_FINAL_TYPE(PortalDisplay, portal_display, PORTAL, DISPLAY, WPEDisplay)
G_DECLARE_FINAL_TYPE(PortalToplevel, portal_toplevel, PORTAL, TOPLEVEL, WPEToplevel)
G_DECLARE_FINAL_TYPE(PortalWPEView, portal_wpe_view, PORTAL, WPE_VIEW, WPEView)
G_DECLARE_FINAL_TYPE(PortalMethod, portal_method, PORTAL, METHOD, WPEInputMethodContext)

struct _PortalDisplay {
    WPEDisplay parent;
    WPEDRMDevice *device;
    EGLDisplay egl;
    bool looked;
};
G_DEFINE_FINAL_TYPE(PortalDisplay, portal_display, WPE_TYPE_DISPLAY)

struct _PortalToplevel {
    WPEToplevel parent;
};
G_DEFINE_FINAL_TYPE(PortalToplevel, portal_toplevel, WPE_TYPE_TOPLEVEL)
static void portal_toplevel_class_init(PortalToplevelClass *class) { (void) class; }
static void portal_toplevel_init(PortalToplevel *self) { (void) self; }

struct _PortalWPEView {
    WPEView parent;
    struct page *page;
};
G_DEFINE_FINAL_TYPE(PortalWPEView, portal_wpe_view, WPE_TYPE_VIEW)

struct _PortalMethod {
    WPEInputMethodContext parent;
    struct page *page;
};
G_DEFINE_FINAL_TYPE(PortalMethod, portal_method, WPE_TYPE_INPUT_METHOD_CONTEXT)

/* The page whose WebKit view is being made: a view and its input method
   are made inside webkit_web_view's construction, which takes no data. */
static struct page *making;

static gboolean display_connect(WPEDisplay *display, GError **error)
{
    (void) display, (void) error;
    return TRUE;
}

static WPEView *display_create_view(WPEDisplay *display)
{
    PortalWPEView *view = g_object_new(portal_wpe_view_get_type(), "display", display, NULL);
    view->page = making;
    return WPE_VIEW(view);
}

static WPEToplevel *display_create_toplevel(WPEDisplay *display, guint max_views)
{
    (void) max_views;
    return WPE_TOPLEVEL(g_object_new(portal_toplevel_get_type(), "display", display, NULL));
}

static WPEInputMethodContext *display_create_method(WPEDisplay *display, WPEView *view)
{
    (void) display;
    PortalMethod *method = g_object_new(portal_method_get_type(), "view", view, NULL);
    method->page = PORTAL_WPE_VIEW(view)->page;
    if (method->page)
        method->page->method = WPE_INPUT_METHOD_CONTEXT(method);
    return WPE_INPUT_METHOD_CONTEXT(method);
}

/* An EGL display on Emacs's Wayland connection, as a terminal's
   (terminal.c), and from it the compositor's GPU, both of whose nodes
   WebKit needs to make its frames DMABUFs. */
static void display_look(PortalDisplay *self)
{
    if (self->looked)
        return;
    self->looked = true;
    PFNEGLGETPLATFORMDISPLAYEXTPROC display_of =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay egl = display_of
                         ? display_of(EGL_PLATFORM_WAYLAND_KHR, webkit.wayland->display, NULL)
                         : EGL_NO_DISPLAY;
    EGLint major, minor;
    if (egl == EGL_NO_DISPLAY || !eglInitialize(egl, &major, &minor))
        return;
    self->egl = egl;
    PFNEGLQUERYDISPLAYATTRIBEXTPROC query_display =
        (PFNEGLQUERYDISPLAYATTRIBEXTPROC) eglGetProcAddress("eglQueryDisplayAttribEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC query_device =
        (PFNEGLQUERYDEVICESTRINGEXTPROC) eglGetProcAddress("eglQueryDeviceStringEXT");
    EGLAttrib device = 0;
    if (!query_display || !query_device || !query_display(egl, EGL_DEVICE_EXT, &device))
        return;
    const char *primary = query_device((EGLDeviceEXT) device, EGL_DRM_DEVICE_FILE_EXT);
    const char *render = query_device((EGLDeviceEXT) device, EGL_DRM_RENDER_NODE_FILE_EXT);
    if (primary)
        self->device = wpe_drm_device_new(primary, render);
}

/* The GPU, for frames WebKit makes DMABUFs; none for frames it draws in
   memory, which the presenter copies into shared memory.  What WebKit is
   told the first time it asks, at the first page's first load, holds for
   every page of the process: so pages draw in memory only as decided then
   (webkit_start), or where EGL names no GPU, as with a software renderer. */
static WPEDRMDevice *display_get_drm_device(WPEDisplay *display)
{
    PortalDisplay *self = PORTAL_DISPLAY(display);
    if (webkit.memory)
        return NULL;
    display_look(self);
    return self->device;
}

static gpointer display_get_egl_display(WPEDisplay *display, GError **error)
{
    PortalDisplay *self = PORTAL_DISPLAY(display);
    display_look(self);
    if (!self->egl)
        g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE,
                            "Portal: no EGL display on Emacs's connection");
    return self->egl;
}

static void portal_display_class_init(PortalDisplayClass *class)
{
    WPEDisplayClass *display = WPE_DISPLAY_CLASS(class);
    display->connect = display_connect;
    display->create_view = display_create_view;
    display->create_toplevel = display_create_toplevel;
    display->get_drm_device = display_get_drm_device;
    display->get_egl_display = display_get_egl_display;
    display->create_input_method_context = display_create_method;
}
static void portal_display_init(PortalDisplay *self) { (void) self; }

/* The view: WebKit's frames, to the stage. */

static gboolean view_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage,
                                   guint damage_count, GError **error)
{
    (void) damage, (void) damage_count, (void) error;
    struct page *page = PORTAL_WPE_VIEW(view)->page;
    if (!page) {
        wpe_view_buffer_rendered(view, buffer);
        wpe_view_buffer_released(view, buffer);
        return TRUE;
    }
    atomic_fetch_add(&page->rendered, 1);
    pthread_mutex_lock(&page->lock);
    WPEBuffer *untaken = page->latest;
    WPEView *untaken_view = page->latest_view;
    page->latest = g_object_ref(buffer);
    page->latest_view = g_object_ref(view);
    pthread_mutex_unlock(&page->lock);
    if (untaken) {
        /* Never taken: WebKit draws one at a time, so this does not come. */
        wpe_view_buffer_rendered(untaken_view, untaken);
        wpe_view_buffer_released(untaken_view, untaken);
        g_object_unref(untaken);
        g_object_unref(untaken_view);
    }
    host->stage_ready(page->stage);
    return TRUE;
}

struct pointer_shape {
    uint64_t serial;
    const char *name;
};

static gboolean cursor_on_main(gpointer data)
{
    struct pointer_shape *shape = data;
    struct portal_view *view = host->view_find(shape->serial);
    if (view) {
        ((struct page *) view->content)->cursor = shape->name;
        host->input_cursor(view, shape->name);
    }
    return G_SOURCE_REMOVE;
}

static void view_set_cursor_from_name(WPEView *view, const char *name)
{
    struct page *page = PORTAL_WPE_VIEW(view)->page;
    if (!page)
        return;
    struct pointer_shape *shape = g_new(struct pointer_shape, 1);
    shape->serial = page->serial;
    shape->name = name && strcmp(name, "default") ? g_intern_string(name) : NULL;
    on_main(cursor_on_main, shape, g_free);
}

static void portal_wpe_view_class_init(PortalWPEViewClass *class)
{
    WPE_VIEW_CLASS(class)->render_buffer = view_render_buffer;
    WPE_VIEW_CLASS(class)->set_cursor_from_name = view_set_cursor_from_name;
}
static void portal_wpe_view_init(PortalWPEView *self) { (void) self; }

/* The input method context: what Portal's own input method committed and
   composed, given to WebKit as an input method's. */

static void method_get_preedit(WPEInputMethodContext *context, gchar **text, GList **underlines,
                               guint *cursor)
{
    struct page *page = PORTAL_METHOD(context)->page;
    if (text)
        *text = g_strdup(page && page->preedit ? page->preedit : "");
    if (underlines)
        *underlines = NULL;
    if (cursor)
        *cursor = page ? (guint) page->preedit_cursor : 0;
}

static gboolean method_filter_key(WPEInputMethodContext *context, WPEEvent *event)
{
    struct page *page = PORTAL_METHOD(context)->page;
    if (!page || !page->typing || wpe_event_get_event_type(event) != WPE_EVENT_KEYBOARD_KEY_DOWN)
        return FALSE;
    /* The key's text, as an input method's commit. */
    g_signal_emit_by_name(context, "committed", page->typing);
    return TRUE;
}

static void portal_method_class_init(PortalMethodClass *class)
{
    WPEInputMethodContextClass *method = WPE_INPUT_METHOD_CONTEXT_CLASS(class);
    method->get_preedit_string = method_get_preedit;
    method->filter_key_event = method_filter_key;
}
static void portal_method_init(PortalMethod *self) { (void) self; }

/* The stage's source. */

static struct portal_linux_frame *page_take(void *data)
{
    struct page *page = data;
    pthread_mutex_lock(&page->lock);
    WPEBuffer *buffer = page->latest;
    WPEView *view = page->latest_view;
    page->latest = NULL;
    page->latest_view = NULL;
    pthread_mutex_unlock(&page->lock);
    if (!buffer)
        return NULL;
    struct held *held = g_new0(struct held, 1);
    held->view = view;
    held->buffer = buffer;
    struct portal_linux_frame *frame = &held->frame;
    frame->own = held;
    frame->width = wpe_buffer_get_width(buffer);
    frame->height = wpe_buffer_get_height(buffer);
    /* A texture of its own for each of WebKit's buffers, for as long as
       it lives. */
    uint64_t texture = GPOINTER_TO_SIZE(g_object_get_qdata(G_OBJECT(buffer), texture_quark));
    if (!texture) {
        texture = atomic_fetch_add(&textures, 1) + 1;
        g_object_set_qdata(G_OBJECT(buffer), texture_quark, GSIZE_TO_POINTER(texture));
    }
    frame->texture = texture;
    if (WPE_IS_BUFFER_DMA_BUF(buffer)) {
        WPEBufferDMABuf *dmabuf = WPE_BUFFER_DMA_BUF(buffer);
        frame->fourcc = wpe_buffer_dma_buf_get_format(dmabuf);
        frame->modifier = wpe_buffer_dma_buf_get_modifier(dmabuf);
        frame->plane_count = MIN(wpe_buffer_dma_buf_get_n_planes(dmabuf), 4);
        for (uint32_t i = 0; i < frame->plane_count; i++) {
            frame->fds[i] = wpe_buffer_dma_buf_get_fd(dmabuf, i);
            frame->offsets[i] = wpe_buffer_dma_buf_get_offset(dmabuf, i);
            frame->strides[i] = wpe_buffer_dma_buf_get_stride(dmabuf, i);
        }
    } else {
        WPEBufferSHM *shm = WPE_BUFFER_SHM(buffer);
        atomic_fetch_add(&page->memory_frames, 1);
        frame->memory = true;
        frame->bgra = true;
        frame->pixels = g_bytes_get_data(wpe_buffer_shm_get_data(shm), NULL);
        frame->strides[0] = wpe_buffer_shm_get_stride(shm);
    }
    return frame;
}

static gboolean released_on_webkit(gpointer data)
{
    struct held *held = data;
    wpe_view_buffer_released(held->view, held->buffer);
    g_object_unref(held->buffer);
    g_object_unref(held->view);
    g_free(held);
    return G_SOURCE_REMOVE;
}

static void page_done(struct portal_linux_frame *frame)
{
    on_webkit(released_on_webkit, frame->own, NULL);
}

struct rendered {
    WPEView *view;
    WPEBuffer *buffer;
};

static gboolean rendered_on_webkit(gpointer data)
{
    struct rendered *rendered = data;
    wpe_view_buffer_rendered(rendered->view, rendered->buffer);
    g_object_unref(rendered->buffer);
    g_object_unref(rendered->view);
    g_free(rendered);
    return G_SOURCE_REMOVE;
}

static void page_shown(void *data, struct portal_linux_frame *frame)
{
    (void) data;
    struct held *held = frame->own;
    struct rendered *rendered = g_new(struct rendered, 1);
    rendered->view = g_object_ref(held->view);
    rendered->buffer = g_object_ref(held->buffer);
    on_webkit(rendered_on_webkit, rendered, NULL);
}

static gboolean unmap_on_webkit(gpointer data)
{
    struct page *page = data;
    if (page->wpe && page->mapped)
        wpe_view_unmap(page->wpe);
    page->mapped = false;
    return G_SOURCE_REMOVE;
}

/* The compositor refused a DMABUF of the page's, or a terminal's, after
   WebKit was told of the GPU: no page of this process can draw in memory
   (display_get_drm_device).  The page says it cannot be shown and stops
   drawing, rather than drawing frames that are each dropped; pages show
   again in the next Emacs, which knows from its first terminal. */
static void page_memory(void *data)
{
    struct page *page = data;
    if (webkit.memory || atomic_exchange(&page->unshowable, true))
        return;
    fprintf(stderr, "Portal: the compositor took no DMABUF of a page's: it cannot be shown "
                    "until Emacs starts again\n");
    on_webkit(unmap_on_webkit, page, NULL);
}

static const struct portal_stage_source page_source = {
    .take = page_take,
    .done = page_done,
    .shown = page_shown,
    .visible = NULL,
    .memory = page_memory,
};

/* WebKit's thread. */

static gpointer webkit_run(gpointer data)
{
    GMainLoop *loop = data;
    g_main_context_push_thread_default(g_main_loop_get_context(loop));
    g_main_loop_run(loop);
    return NULL;
}

static gboolean webkit_make(gpointer data)
{
    (void) data;
    texture_quark = g_quark_from_static_string("portal-web-texture");
    WPEDisplay *display = g_object_new(portal_display_get_type(), NULL);
    GError *error = NULL;
    if (!wpe_display_connect(display, &error)) {
        fprintf(stderr, "Portal: WebKit's display: %s\n", error->message);
        g_error_free(error);
        g_object_unref(display);
        return G_SOURCE_REMOVE;
    }
    wpe_display_set_primary(display);
    webkit.display = display;
    return G_SOURCE_REMOVE;
}

/* Start WebKit's thread and make the display there, once. */
static bool webkit_start(const struct portal_wayland *wayland, portal_text *error)
{
    static bool started;
    if (!started) {
        started = true;
        webkit.wayland = wayland;
        /* Pages draw in memory where the compositor takes no DMABUF: it
           has no way to, or it refused a terminal's already.
           PORTAL_TEST_WEB_MEMORY, for the checks, has them draw so as
           well, which only the process's first page can decide. */
        const char *test = getenv("PORTAL_TEST_WEB_MEMORY");
        webkit.memory = !wayland->dmabuf || host->dmabufs_refused() || (test && *test);
        webkit.main = g_thread_self();
        webkit.context = g_main_context_new();
        GMainLoop *loop = g_main_loop_new(webkit.context, FALSE);
        webkit.owner = g_thread_new("portal-webkit", webkit_run, loop);
        on_webkit_wait(webkit_make, NULL);
    }
    return webkit.display != NULL || host->fail(error, "WebKit could not make a display for Portal");
}

/* What WebKit said, for the main thread. */

/* The key script, in a world of its own in every frame: each trusted
   keydown, once its dispatch is over, with its modifiers, whether the page
   prevented its default, and its time on the document's clock, in
   milliseconds. */
static const char key_script[] =
    "addEventListener('keydown', (event) => {"
    "  if (!event.isTrusted) return;"
    "  setTimeout(() => window.webkit.messageHandlers.portalKey.postMessage("
    "    [event.ctrlKey, event.altKey, event.metaKey, event.defaultPrevented,"
    "     performance.timeOrigin + event.timeStamp]), 0);"
    "}, true);";

static void offer_settle(struct page *page, bool used)
{
    if (!page->offering)
        return;
    page->offering = false;
    if (page->offer_timer)
        g_source_remove(page->offer_timer);
    page->offer_timer = 0;
    host->input_settle(page->view, used);
}

static void presses_clear(struct page *page)
{
    g_queue_clear_full(&page->presses, g_free);
    page->dropped = 0;
    page->dropped_until = 0;
    /* A new document's clock has an origin of its own. */
    page->calibrated = false;
    page->adrift = false;
    page->misses = 0;
}

struct key_report {
    uint64_t serial;
    bool control, alt, meta, prevented;
    double time;
};

/* The press REPORT is for, by order, before calibration: the oldest whose
   modifiers are the report's, those before it dropped. */
static struct press *press_by_order(struct page *page, const struct key_report *report)
{
    struct press *press;
    while ((press = g_queue_pop_head(&page->presses))) {
        if (press->modifier || (press->control == report->control &&
                                press->alt == report->alt && press->meta == report->meta))
            return press;
        g_free(press); /* It never reached a document: this report is a later one's. */
    }
    return NULL;
}

/* The press REPORT is for, by its time, those before it dropped; or NULL
   for a report of a press no longer kept. */
static struct press *press_by_time(struct page *page, const struct key_report *report)
{
    for (GList *link = page->presses.head; link; link = link->next) {
        struct press *press = link->data;
        double off = report->time - press->time - page->offset;
        if (off < -report_tolerance || off > report_tolerance)
            continue;
        while (g_queue_peek_head(&page->presses) != press)
            g_free(g_queue_pop_head(&page->presses));
        g_queue_pop_head(&page->presses);
        page->offset += off;
        page->misses = 0;
        return press;
    }
    /* A press dropped from a full queue, whose report came late: never
       another's. */
    if (page->dropped_until && report->time - page->offset <= page->dropped_until + report_tolerance)
        return NULL;
    /* Three in a row that fit no press, as when the wall clock was set: no
       report can be told to be a press's any more, so the presses go, an
       offer waiting gives up, and none is settled by a report until the
       document or its process goes. */
    if (!g_queue_is_empty(&page->presses) && ++page->misses >= 3) {
        g_queue_clear_full(&page->presses, g_free);
        page->calibrated = false;
        page->adrift = true;
    }
    return NULL;
}

static gboolean key_report_on_main(gpointer data)
{
    struct key_report *report = data;
    struct portal_view *view = host->view_find(report->serial);
    if (!view)
        return G_SOURCE_REMOVE;
    struct page *page = view->content;
    struct press *press;
    if (page->adrift) {
        return G_SOURCE_REMOVE;
    } else if (page->calibrated) {
        press = press_by_time(page, report);
    } else if (page->dropped) {
        page->dropped--;
        return G_SOURCE_REMOVE;
    } else {
        bool alone = g_queue_get_length(&page->presses) == 1;
        press = press_by_order(page, report);
        if (press && alone) {
            page->offset = report->time - press->time;
            page->calibrated = true;
            page->misses = 0;
            page->dropped = 0;
        }
    }
    if (press && page->offering && press->number == page->offer_number)
        offer_settle(page, report->prevented);
    g_free(press);
    return G_SOURCE_REMOVE;
}

static void key_reported(WebKitUserContentManager *manager, JSCValue *value, gpointer data)
{
    (void) manager;
    struct page *page = data;
    if (!jsc_value_is_array(value))
        return;
    struct key_report *report = g_new0(struct key_report, 1);
    report->serial = page->serial;
    bool *flags[] = {&report->control, &report->alt, &report->meta, &report->prevented};
    for (guint i = 0; i < G_N_ELEMENTS(flags); i++) {
        JSCValue *item = jsc_value_object_get_property_at_index(value, i);
        *flags[i] = jsc_value_to_boolean(item);
        g_object_unref(item);
    }
    JSCValue *item = jsc_value_object_get_property_at_index(value, G_N_ELEMENTS(flags));
    report->time = jsc_value_to_double(item);
    g_object_unref(item);
    on_main(key_report_on_main, report, g_free);
}

/* News of the page, for the main thread. */
enum news_kind { NEWS_LOADING, NEWS_COMMITTED, NEWS_LOADED, NEWS_TITLE, NEWS_FAILED, NEWS_ENDED };

struct news {
    uint64_t serial;
    enum news_kind kind;
    char *text, *url;
};

static void news_free(gpointer data)
{
    struct news *news = data;
    g_free(news->text);
    g_free(news->url);
    g_free(news);
}

static void replace(char **field, char **with)
{
    g_free(*field);
    *field = g_steal_pointer(with);
}

static gboolean news_on_main(gpointer data)
{
    struct news *news = data;
    struct portal_view *view = host->view_find(news->serial);
    if (!view)
        return G_SOURCE_REMOVE;
    struct page *page = view->content;
    portal_string target = {view->target, view->target_length};
    switch (news->kind) {
    case NEWS_LOADING:
        page->loading = true;
        g_clear_pointer(&page->error, g_free);
        page->terminated = false;
        break;
    case NEWS_COMMITTED:
        /* The document before has gone, and with it the reports of the
           presses it had not reported: WebKit's thread passes its reports
           on before it says the next one committed. */
        presses_clear(page);
        replace(&page->url, &news->url);
        if (page->url)
            host->committed(target, (portal_string) {page->url, strlen(page->url)});
        break;
    case NEWS_LOADED:
        page->loading = false;
        break;
    case NEWS_TITLE:
        replace(&page->title, &news->text);
        break;
    case NEWS_FAILED:
        page->loading = false;
        replace(&page->error, &news->text);
        host->failed(target, 0, (portal_string) {page->error, strlen(page->error)});
        break;
    case NEWS_ENDED:
        /* No report comes for a press its process had. */
        page->loading = false;
        page->terminated = true;
        presses_clear(page);
        offer_settle(page, false);
        replace(&page->error, &news->text);
        host->failed(target, 0, (portal_string) {page->error, strlen(page->error)});
        break;
    }
    if (news->url && news->kind != NEWS_COMMITTED)
        replace(&page->url, &news->url);
    return G_SOURCE_REMOVE;
}

static void tell(struct page *page, enum news_kind kind, const char *text, const char *url)
{
    struct news *news = g_new0(struct news, 1);
    news->serial = page->serial;
    news->kind = kind;
    news->text = g_strdup(text);
    news->url = g_strdup(url);
    on_main(news_on_main, news, news_free);
}

static void web_terminated(WebKitWebView *web, WebKitWebProcessTerminationReason reason,
                           gpointer data)
{
    (void) web;
    tell(data, NEWS_ENDED,
         reason == WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT
             ? "The page's web process stopped: it used too much memory."
             : "The page's web process stopped.",
         NULL);
}

static void web_load_changed(WebKitWebView *web, WebKitLoadEvent event, gpointer data)
{
    const char *url = webkit_web_view_get_uri(web);
    if (event == WEBKIT_LOAD_STARTED)
        tell(data, NEWS_LOADING, NULL, url);
    else if (event == WEBKIT_LOAD_COMMITTED)
        tell(data, NEWS_COMMITTED, NULL, url);
    else if (event == WEBKIT_LOAD_FINISHED)
        tell(data, NEWS_LOADED, NULL, url);
}

static gboolean web_load_failed(WebKitWebView *web, WebKitLoadEvent event, char *url,
                                GError *error, gpointer data)
{
    (void) web, (void) event, (void) url;
    /* A load cancelled, as by another, or turned into a download. */
    if (!g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED) &&
        !g_error_matches(error, WEBKIT_POLICY_ERROR,
                         WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE))
        tell(data, NEWS_FAILED, error->message, NULL);
    return FALSE;
}

static void web_title(GObject *web, GParamSpec *property, gpointer data)
{
    (void) property;
    tell(data, NEWS_TITLE, webkit_web_view_get_title(WEBKIT_WEB_VIEW(web)), NULL);
}

/* The context for a page of DIRECTORY, or of none, made the first time and
   never freed: WebKit keeps its default one in a function's static, which
   exit() frees on the thread that exits, Emacs's main thread, aborting
   Emacs when WebKit is on another.

   WebKit's sandbox shows a web process only the paths its context was
   given, and takes none once the context has started a process; a page's
   media, which the web process reads itself, would not play from a file of
   the page's directory.  So a file's page goes in a context of its own
   directory's, which may read that directory, as a file's page may on
   macOS. */
static WebKitWebContext *context_of(const char *directory)
{
    static GHashTable *contexts;
    if (!contexts)
        contexts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    const char *key = directory ? directory : "";
    WebKitWebContext *context = g_hash_table_lookup(contexts, key);
    if (!context) {
        context = webkit_web_context_new();
        if (directory)
            webkit_web_context_add_path_to_sandbox(context, directory, TRUE);
        g_hash_table_insert(contexts, g_strdup(key), context);
    }
    return context;
}

/* Tell the web view the size, scale and showing the main thread last
   gave: on WebKit's thread. */
static void view_apply(struct page *page)
{
    if (!page->wpe)
        return;
    if (page->width > 0 && page->height > 0) {
        wpe_toplevel_scale_changed(page->toplevel, page->scale);
        wpe_toplevel_resized(page->toplevel, page->width, page->height);
        wpe_view_resized(page->wpe, page->width, page->height);
    }
    if (page->shown && !page->mapped)
        wpe_view_map(page->wpe);
    else if (!page->shown && page->mapped)
        wpe_view_unmap(page->wpe);
    page->mapped = page->shown;
    if (page->focused)
        wpe_view_focus_in(page->wpe);
}

/* Make the page's web view, in its context. */
static gboolean page_make(gpointer data)
{
    struct page *page = data;
    WebKitUserContentManager *content = webkit_user_content_manager_new();
    webkit_user_content_manager_register_script_message_handler(content, "portalKey",
                                                                "portal-keys");
    g_signal_connect(content, "script-message-received::portalKey", G_CALLBACK(key_reported),
                     page);
    WebKitUserScript *script = webkit_user_script_new_for_world(
        key_script, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, "portal-keys", NULL, NULL);
    webkit_user_content_manager_add_script(content, script);
    webkit_user_script_unref(script);
    WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
    page->context = context_of(page->directory);
    making = page;
    page->web = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", webkit.display, "web-context",
                             page->context, "network-session", session,
                             "user-content-manager", content, NULL);
    making = NULL;
    g_object_unref(session);
    g_object_unref(content);
    page->wpe = webkit_web_view_get_wpe_view(page->web);
    if (!PORTAL_IS_WPE_VIEW(page->wpe)) {
        /* Not this display's: it would show nothing of Portal's. */
        g_clear_object(&page->web);
        page->wpe = NULL;
        return G_SOURCE_REMOVE;
    }
    page->toplevel = wpe_view_get_toplevel(page->wpe);
    g_signal_connect(page->web, "web-process-terminated", G_CALLBACK(web_terminated), page);
    g_signal_connect(page->web, "load-changed", G_CALLBACK(web_load_changed), page);
    g_signal_connect(page->web, "load-failed", G_CALLBACK(web_load_failed), page);
    g_signal_connect(page->web, "notify::title", G_CALLBACK(web_title), page);
    page->mapped = false;
    view_apply(page);
    return G_SOURCE_REMOVE;
}

static gboolean page_unmake(gpointer data)
{
    struct page *page = data;
    if (!page->web)
        return G_SOURCE_REMOVE;
    g_signal_handlers_disconnect_by_data(page->web, page);
    PORTAL_WPE_VIEW(page->wpe)->page = NULL;
    if (page->method)
        PORTAL_METHOD(page->method)->page = NULL;
    page->method = NULL;
    pthread_mutex_lock(&page->lock);
    WPEBuffer *latest = page->latest;
    WPEView *latest_view = page->latest_view;
    page->latest = NULL;
    page->latest_view = NULL;
    pthread_mutex_unlock(&page->lock);
    if (latest) {
        wpe_view_buffer_rendered(latest_view, latest);
        wpe_view_buffer_released(latest_view, latest);
        g_object_unref(latest);
        g_object_unref(latest_view);
    }
    WebKitUserContentManager *content = webkit_web_view_get_user_content_manager(page->web);
    g_signal_handlers_disconnect_by_data(content, page);
    /* With a context of Portal's, a page's web process would outlive its
       view, and its network process and D-Bus proxy with it: each page has
       a process of its own, WebKit's process model since 2.40, ended here. */
    webkit_web_view_terminate_web_process(page->web);
    g_clear_object(&page->web);
    page->wpe = NULL;
    return G_SOURCE_REMOVE;
}

/* The class. */

static void page_stop(void *content)
{
    struct page *page = content;
    offer_settle(page, false);
    /* The presenter no longer takes its frames or dispatches its queue. */
    host->stage_stop(page->stage);
}

static void page_free(struct page *page)
{
    pthread_mutex_destroy(&page->lock);
    presses_clear(page);
    g_free(page->preedit);
    g_free(page->directory);
    g_free(page->url);
    g_free(page->title);
    g_free(page->error);
    g_free(page);
}

static void page_destroy(void *content)
{
    struct page *page = content;
    on_webkit_wait(page_unmake, page);
    host->stage_free(page->stage);
    page_free(page);
}

struct configured {
    struct page *page;
    int32_t width, height, scale;
    bool shown;
};

static gboolean configure_on_webkit(gpointer data)
{
    struct configured *configured = data;
    struct page *page = configured->page;
    page->width = configured->width;
    page->height = configured->height;
    page->scale = configured->scale;
    page->shown = configured->shown;
    view_apply(page);
    return G_SOURCE_REMOVE;
}

static void page_configure(void *content, int32_t width, int32_t height, int32_t scale,
                           bool shown)
{
    struct page *page = content;
    struct configured *configured = g_new(struct configured, 1);
    *configured = (struct configured) {page, width, height, scale < 1 ? 1 : scale, shown};
    on_webkit(configure_on_webkit, configured, g_free);
    host->stage_configure(page->stage, shown);
}

static void page_frame(void *content, uint32_t time)
{
    (void) time;
    struct page *page = content;
    host->stage_frame(page->stage);
}

struct focused {
    struct page *page;
    bool focused;
};

static gboolean focus_on_webkit(gpointer data)
{
    struct focused *focused = data;
    struct page *page = focused->page;
    page->focused = focused->focused;
    if (!page->wpe)
        return G_SOURCE_REMOVE;
    if (page->focused)
        wpe_view_focus_in(page->wpe);
    else
        wpe_view_focus_out(page->wpe);
    return G_SOURCE_REMOVE;
}

static void page_focus(void *content, bool focused)
{
    struct focused *focus = g_new(struct focused, 1);
    *focus = (struct focused) {content, focused};
    on_webkit(focus_on_webkit, focus, g_free);
}

static WPEModifiers modifiers_of(GdkModifierType state)
{
    WPEModifiers modifiers = 0;
    if (state & GDK_CONTROL_MASK)
        modifiers |= WPE_MODIFIER_KEYBOARD_CONTROL;
    if (state & GDK_SHIFT_MASK)
        modifiers |= WPE_MODIFIER_KEYBOARD_SHIFT;
    if (state & GDK_MOD1_MASK)
        modifiers |= WPE_MODIFIER_KEYBOARD_ALT;
    if (state & (GDK_SUPER_MASK | GDK_MOD4_MASK | GDK_META_MASK))
        modifiers |= WPE_MODIFIER_KEYBOARD_META;
    if (state & GDK_LOCK_MASK)
        modifiers |= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
    if (state & GDK_BUTTON1_MASK)
        modifiers |= WPE_MODIFIER_POINTER_BUTTON1;
    if (state & GDK_BUTTON2_MASK)
        modifiers |= WPE_MODIFIER_POINTER_BUTTON2;
    if (state & GDK_BUTTON3_MASK)
        modifiers |= WPE_MODIFIER_POINTER_BUTTON3;
    return modifiers;
}

/* An input event, as the main thread copied it, for WebKit's thread. */
struct given {
    struct page *page;
    WPEEventType type;
    guint32 time;
    WPEModifiers modifiers;
    guint keycode, keyval, button;
    double x, y, dx, dy;
    bool precise, stop, touchpad;
    char *text;
};

static void given_free(gpointer data)
{
    struct given *given = data;
    g_free(given->text);
    g_free(given);
}

static gboolean given_on_webkit(gpointer data)
{
    struct given *given = data;
    struct page *page = given->page;
    WPEView *view = page->wpe;
    if (!view)
        return G_SOURCE_REMOVE;
    WPEEvent *event = NULL;
    WPEInputSource source = given->touchpad ? WPE_INPUT_SOURCE_TOUCHPAD : WPE_INPUT_SOURCE_MOUSE;
    switch (given->type) {
    case WPE_EVENT_KEYBOARD_KEY_DOWN:
    case WPE_EVENT_KEYBOARD_KEY_UP:
        event = wpe_event_keyboard_new(given->type, view, WPE_INPUT_SOURCE_KEYBOARD, given->time,
                                       given->modifiers, given->keycode, given->keyval);
        break;
    case WPE_EVENT_POINTER_DOWN:
    case WPE_EVENT_POINTER_UP: {
        guint count = given->type == WPE_EVENT_POINTER_DOWN
                          ? wpe_view_compute_press_count(view, given->x, given->y, given->button,
                                                         given->time)
                          : 0;
        event = wpe_event_pointer_button_new(given->type, view, source, given->time,
                                             given->modifiers, given->button, given->x, given->y,
                                             count);
        break;
    }
    case WPE_EVENT_POINTER_MOVE:
    case WPE_EVENT_POINTER_ENTER:
    case WPE_EVENT_POINTER_LEAVE:
        event = wpe_event_pointer_move_new(given->type, view, source, given->time,
                                           given->modifiers, given->x, given->y, given->dx,
                                           given->dy);
        break;
    case WPE_EVENT_SCROLL:
        event = wpe_event_scroll_new(view, source, given->time, given->modifiers, given->dx,
                                     given->dy, given->precise, given->stop, given->x, given->y);
        break;
    default:
        break;
    }
    if (!event)
        return G_SOURCE_REMOVE;
    page->typing = given->text;
    wpe_view_event(view, event);
    page->typing = NULL;
    wpe_event_unref(event);
    return G_SOURCE_REMOVE;
}

/* The time an event is given to WebKit at, in milliseconds, never less
   than the last one's, and for a press at least PRESS_SPACING more: the
   identity of a press, which its keydown and the key script's report of it
   carry.  WebKit makes an event's time from the first it was given in the
   process and the time since (monotonicTimeForEventTimeInMilliseconds in
   WebKit's WebEventConversion.cpp), so every event's must be Portal's,
   counted from a start of its own, and none earlier than the first.  A
   press given in a burst, as by a program that types, is that much later
   to the page; a person's are spaced further apart.  From the module
   thread. */
static guint32 event_time(bool press)
{
    static gint64 start;
    static guint32 last;
    gint64 now = g_get_monotonic_time() / 1000;
    if (!start)
        start = now - 1;
    guint32 time = (guint32) (now - start);
    guint32 floor = press && last ? last + PRESS_SPACING : last;
    last = time > floor ? time : floor;
    return last;
}

static void give(struct page *page, struct given *given)
{
    given->page = page;
    on_webkit(given_on_webkit, given, given_free);
}

/* Give WebKit the key EVENT with TEXT, numbering a press; return its
   number, or 0 for a release. */
static uint64_t give_key(struct page *page, const GdkEventKey *event, const char *text)
{
    struct given *given = g_new0(struct given, 1);
    bool press = event->type == GDK_KEY_PRESS;
    given->type = press ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP;
    guint32 time = event_time(press);
    given->time = time;
    given->modifiers = modifiers_of(event->state);
    given->keycode = event->hardware_keycode;
    given->keyval = event->keyval;
    given->text = text && *text ? g_strdup(text) : NULL;
    /* GIVEN is WebKit's thread's from here on. */
    give(page, given);
    if (!press)
        return 0;
    struct press *pressed = g_new(struct press, 1);
    *pressed = (struct press) {
        .number = ++page->pressed,
        .time = time,
        .control = event->state & GDK_CONTROL_MASK,
        .alt = event->state & GDK_MOD1_MASK,
        .meta = event->state & (GDK_SUPER_MASK | GDK_MOD4_MASK | GDK_META_MASK),
        .modifier = event->is_modifier,
    };
    g_queue_push_tail(&page->presses, pressed);
    while (g_queue_get_length(&page->presses) > PRESSES) {
        struct press *dropped = g_queue_pop_head(&page->presses);
        page->dropped_until = dropped->time;
        g_free(dropped);
        if (!page->calibrated && !page->adrift)
            page->dropped++;
    }
    return pressed->number;
}

static void page_key(void *content, const GdkEventKey *event, const char *text, bool composing)
{
    (void) composing;
    give_key(content, event, text);
}

struct typed {
    struct page *page;
    char *text;
    int cursor;
    bool preedit;
};

static void typed_free(gpointer data)
{
    struct typed *typed = data;
    g_free(typed->text);
    g_free(typed);
}

static gboolean typed_on_webkit(gpointer data)
{
    struct typed *typed = data;
    struct page *page = typed->page;
    if (!page->method)
        return G_SOURCE_REMOVE;
    if (!typed->preedit) {
        g_signal_emit_by_name(page->method, "committed", typed->text);
        return G_SOURCE_REMOVE;
    }
    bool was = page->preedit && *page->preedit, is = *typed->text;
    g_free(page->preedit);
    page->preedit = g_strdup(typed->text);
    page->preedit_cursor = typed->cursor;
    if (is && !was)
        g_signal_emit_by_name(page->method, "preedit-started");
    g_signal_emit_by_name(page->method, "preedit-changed");
    if (!is && was)
        g_signal_emit_by_name(page->method, "preedit-finished");
    return G_SOURCE_REMOVE;
}

static void page_text(void *content, const char *text)
{
    struct typed *typed = g_new0(struct typed, 1);
    *typed = (struct typed) {content, g_strdup(text), 0, false};
    on_webkit(typed_on_webkit, typed, typed_free);
}

static void page_preedit(void *content, const char *text, int cursor)
{
    struct typed *typed = g_new0(struct typed, 1);
    *typed = (struct typed) {content, g_strdup(text), cursor, true};
    on_webkit(typed_on_webkit, typed, typed_free);
}

/* A scroll, as WebKit's own Wayland seat gives it: a wheel's steps, or a
   touchpad's or a pointing stick's pixels, precise; up and left positive.
   GDK says which by the event's source device, one for each of the
   compositor's axis sources: a wheel, a finger, continuous. */
static void scroll_of(const GdkEvent *event, GdkDevice *device, struct given *given)
{
    switch (event->scroll.direction) {
    case GDK_SCROLL_UP:
        given->dy = 1;
        return;
    case GDK_SCROLL_DOWN:
        given->dy = -1;
        return;
    case GDK_SCROLL_LEFT:
        given->dx = 1;
        return;
    case GDK_SCROLL_RIGHT:
        given->dx = -1;
        return;
    case GDK_SCROLL_SMOOTH:
        break;
    }
    gdouble dx = 0, dy = 0;
    gdk_event_get_scroll_deltas(event, &dx, &dy);
    GdkInputSource source = device ? gdk_device_get_source(device) : GDK_SOURCE_MOUSE;
    given->stop = gdk_event_is_scroll_stop_event(event);
    if (source == GDK_SOURCE_TOUCHPAD || source == GDK_SOURCE_TRACKPOINT || given->stop) {
        /* GDK gives the compositor's pixels divided by ten. */
        given->precise = true;
        given->touchpad = source == GDK_SOURCE_TOUCHPAD;
        given->dx = -dx * 10;
        given->dy = -dy * 10;
    } else {
        /* A wheel's notch, 15 in the compositor's axis value, is 1.5 to
           GDK: one step to WebKit, as its own seat counts it. */
        given->dx = -dx / 1.5;
        given->dy = -dy / 1.5;
    }
}

static void page_pointer(void *content, const GdkEvent *event)
{
    struct page *page = content;
    struct given *given = g_new0(struct given, 1);
    gdouble x = 0, y = 0;
    gdk_event_get_coords(event, &x, &y);
    given->x = x;
    given->y = y;
    given->time = event_time(false);
    GdkModifierType state = 0;
    gdk_event_get_state(event, &state);
    given->modifiers = modifiers_of(state);
    GdkDevice *device = gdk_event_get_source_device(event);
    given->touchpad = device && gdk_device_get_source(device) == GDK_SOURCE_TOUCHPAD;
    switch (event->type) {
    case GDK_BUTTON_PRESS:
    case GDK_BUTTON_RELEASE:
        given->type =
            event->type == GDK_BUTTON_PRESS ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP;
        given->button = event->button.button;
        break;
    case GDK_MOTION_NOTIFY:
        given->type = WPE_EVENT_POINTER_MOVE;
        break;
    case GDK_ENTER_NOTIFY:
        given->type = WPE_EVENT_POINTER_ENTER;
        break;
    case GDK_LEAVE_NOTIFY:
        given->type = WPE_EVENT_POINTER_LEAVE;
        break;
    case GDK_SCROLL:
        given->type = WPE_EVENT_SCROLL;
        scroll_of(event, device, given);
        break;
    default:
        g_free(given);
        return;
    }
    give(page, given);
}

static gboolean offer_expired(gpointer data)
{
    struct page *page = data;
    page->offer_timer = 0;
    /* No report in time: a page with no document, or one too busy to say. */
    offer_settle(page, false);
    return G_SOURCE_REMOVE;
}

static void page_offer(void *content, const GdkEventKey *event)
{
    struct page *page = content;
    page->offering = true;
    if (page->offer_timer)
        g_source_remove(page->offer_timer);
    page->offer_timer = g_timeout_add(1000, offer_expired, page);
    page->offer_number = give_key(page, event, NULL);
}

static void page_describe(void *content, struct json *description)
{
    struct page *page = content;
    char facts[256];
    int length = snprintf(facts, sizeof facts,
                          "\"loading\":%s,\"rendered\":%llu,\"memory_frames\":%llu,"
                          "\"offering\":%s,\"unshowable\":%s,\"terminated\":%s,"
                          "\"keys_by_time\":%s,",
                          page->loading ? "true" : "false", atomic_load(&page->rendered),
                          atomic_load(&page->memory_frames), page->offering ? "true" : "false",
                          atomic_load(&page->unshowable) ? "true" : "false",
                          page->terminated ? "true" : "false", page->calibrated ? "true" : "false");
    put(description, facts, (size_t) length);
    host->stage_describe(page->stage, description);
    const struct {
        const char *name, *value;
    } strings[] = {{"\"url\":", page->url},
                   {"\"title\":", page->title},
                   {"\"error\":", page->error},
                   {"\"cursor\":", page->cursor}};
    for (size_t i = 0; i < G_N_ELEMENTS(strings); i++) {
        if (!strings[i].value)
            continue;
        put(description, strings[i].name, strlen(strings[i].name));
        put_string(description, (portal_string) {strings[i].value, strlen(strings[i].value)});
        put(description, ",", 1);
    }
}

static gboolean copy_on_webkit(gpointer data)
{
    struct page *page = data;
    if (page->web)
        webkit_web_view_execute_editing_command(page->web, WEBKIT_EDITING_COMMAND_COPY);
    return G_SOURCE_REMOVE;
}

static void page_copy(void *content)
{
    on_webkit(copy_on_webkit, content, NULL);
}

static void page_paste(void *content, const char *text)
{
    page_text(content, text);
}

static const struct portal_content_class page_class = {
    .stop = page_stop,
    .destroy = page_destroy,
    .configure = page_configure,
    .frame = page_frame,
    .focus = page_focus,
    .key = page_key,
    .text = page_text,
    .preedit = page_preedit,
    .pointer = page_pointer,
    .offer = page_offer,
    .describe = page_describe,
    .copy = page_copy,
    .paste = page_paste,
};

static bool web_create(struct portal_view *view, const portal_option *options, size_t count,
                       portal_text *error)
{
    (void) options, (void) count;
    if (!webkit_start(view->wayland, error))
        return false;
    struct page *page = g_new0(struct page, 1);
    page->view = view;
    page->serial = view->serial;
    g_queue_init(&page->presses);
    pthread_mutex_init(&page->lock, NULL);
    page->stage = host->stage_new(view, &page_source);
    if (!page->stage) {
        page_free(page);
        return host->fail(error, "Portal is out of memory");
    }
    on_webkit_wait(page_make, page);
    if (!page->wpe || !host->stage_start(page->stage, page, error)) {
        on_webkit_wait(page_unmake, page);
        host->stage_stop(page->stage);
        host->stage_free(page->stage);
        bool failed = error->data != NULL;
        page_free(page);
        return failed ? false : host->fail(error, "WebKit made no page for Portal's display");
    }
    host->stage_configure(page->stage, false);
    view->class = &page_class;
    view->content = page;
    return true;
}

static bool web_is_page(const struct portal_view *view)
{
    return view->class == &page_class;
}

struct loaded {
    struct page *page;
    char *url;
    portal_history step;
};

static void loaded_free(gpointer data)
{
    struct loaded *loaded = data;
    g_free(loaded->url);
    g_free(loaded);
}

/* Make the page's web view again, in the context of DIRECTORY: a web view
   starts a history of its own. */
static void page_remake(struct page *page, char *directory)
{
    page_unmake(page);
    g_free(page->directory);
    page->directory = directory;
    page_make(page);
}

static gboolean load_on_webkit(gpointer data)
{
    struct loaded *loaded = data;
    struct page *page = loaded->page;
    if (!page->web)
        return G_SOURCE_REMOVE;
    if (loaded->url) {
        char *file = g_str_has_prefix(loaded->url, "file:")
                         ? g_filename_from_uri(loaded->url, NULL, NULL)
                         : NULL;
        char *directory = file ? g_path_get_dirname(file) : NULL;
        g_free(file);
        if (directory && g_strcmp0(directory, page->directory))
            page_remake(page, g_steal_pointer(&directory));
        g_free(directory);
        if (page->web)
            webkit_web_view_load_uri(page->web, loaded->url);
    } else if (loaded->step == PORTAL_BACK) {
        webkit_web_view_go_back(page->web);
    } else if (loaded->step == PORTAL_FORWARD) {
        webkit_web_view_go_forward(page->web);
    } else {
        webkit_web_view_reload(page->web);
    }
    return G_SOURCE_REMOVE;
}


static bool web_load(struct portal_view *view, portal_string url, portal_text *error)
{
    (void) error;
    struct loaded *loaded = g_new0(struct loaded, 1);
    loaded->page = view->content;
    loaded->url = g_strndup(url.data, url.length);
    on_webkit(load_on_webkit, loaded, loaded_free);
    return true;
}

static bool web_go(struct portal_view *view, portal_history step, portal_text *error)
{
    (void) error;
    struct loaded *loaded = g_new0(struct loaded, 1);
    loaded->page = view->content;
    loaded->step = step;
    on_webkit(load_on_webkit, loaded, loaded_free);
    return true;
}

static const struct portal_web_object object = {
    .interface = PORTAL_WEB_INTERFACE,
    .create = web_create,
    .is_page = web_is_page,
    .load = web_load,
    .go = web_go,
};

__attribute__((visibility("default"))) const struct portal_web_object *
portal_web_object_open(const struct portal_web_host *given, char **error)
{
    if (given->interface != PORTAL_WEB_INTERFACE) {
        *error = strdup("portal-web.so is of another build of Portal: build Portal again");
        return NULL;
    }
    host = given;
    return &object;
}
