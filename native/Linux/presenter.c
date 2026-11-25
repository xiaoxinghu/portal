/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The presenter: the thread that shows every terminal's and page's frames.

   A source, Ghostty's renderer for a terminal or WebKit for a page, draws
   on a thread of its own and announces each finished frame there
   (portal_linux_stage_ready).  The presenter is one thread for every
   stage, so that frames reach the screen while Emacs's main thread is busy
   in Lisp.  When a stage's view has shown its last frame, at that frame's
   callback, the presenter takes the latest frame the source has, imports
   it as a wl_buffer and presents it to the view (portal_linux_present): it
   commits no faster than the compositor shows, whatever the source makes.
   A frame is a DMABUF, a texture of the source's, which the source does
   not draw into again until the stage is done with the frame: so a frame
   is kept until the compositor releases the buffer it was shown with, or
   the view gives it back unshown.  A buffer is kept for each texture,
   keyed by the frame's `texture', and used again for the later frames of
   that texture.  A source that asks is told when each frame reaches the
   screen (`shown'), as WebKit is before it draws the next.

   A compositor that refuses the first DMABUF, or has no way to take one,
   makes every source hear that its DMABUFs cannot be shown (`memory'):
   Ghostty's frames then come as pixels in memory, which the presenter
   copies into wl_shm buffers.  A page cannot change how it draws once
   made, so it is shown only when WebKit drew in memory from the start
   (web.c).

   Wayland.  The presenter reads the display on a queue of its own, as GDK
   reads it on Emacs's main thread: whoever reads queues the other's
   events.  Every proxy it makes for a stage is on that stage's
   view's queue, and the presenter dispatches every such queue, so the
   views' frame callbacks and the buffers' releases are heard here.  Once
   it has said it will read, nobody reads without it, so it dispatches
   each view's queue after that and before it waits: nothing can arrive
   unseen.  Work done for a stage, which may make requests and even a
   round trip, is done before that, never between saying it will read and
   reading.

   A stage is a content as the presenter has it: its source, the buffers
   made for its frames, and what the presenter knows of it.  linux.h has
   the source's contract.

   Locks.  The presenter's lock guards the list of stages and everything
   the presenter does for one: it is let go of only while the thread waits.
   The main thread takes it to add a stage and to remove one, after which
   the stage and its view's queue are the main thread's alone.  A stage's
   own lock keeps its source's data from being freed while a thread calls
   into it: the presenter, which takes frames, and the thread that shows
   and hides it, read it; the main thread writes it NULL before it frees
   the data.  The view's lock comes after both. */
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

#include "linux-dmabuf-v1-client-protocol.h"
#include "linux.h"

/* Buffers kept for one stage's textures: the renderer keeps at most six
   at one size, and those of the size before a resize go as they are
   released.  Canvases: wl_shm buffers for frames in memory. */
enum { CACHED = 12, CANVASES = 4 };

/* A buffer imported for one of the renderer's textures, and the frame of
   it that is shown or held, if any. */
struct cached {
    struct portal_stage *stage;
    struct wl_buffer *buffer; /* NULL: unused. */
    uint64_t texture;
    int32_t width, height;
    struct portal_linux_frame *frame; /* Kept until the compositor releases the buffer. */
    uint64_t used;          /* When it was last presented, for evicting. */
};

/* A buffer in shared memory, for frames in memory. */
struct canvas {
    struct portal_stage *stage;
    struct wl_buffer *buffer; /* NULL: unused. */
    void *pixels;
    size_t size;
    int32_t width, height;
    bool busy; /* With the view or the compositor. */
};

struct portal_stage {
    struct portal_stage *next; /* In the presenter's list, under its lock. */
    struct portal_view *view;
    atomic_int references; /* The main thread's, and each task of the shower's. */

    const struct portal_stage_source *source;
    /* The source's data, which the main thread frees: see the top. */
    pthread_rwlock_t lock;
    void *data;
    /* The frame presented last, whose source is still to hear that it
       reached the screen, and whether the stage is done with it already. */
    struct portal_linux_frame *unseen;
    bool unseen_done;

    /* What other threads tell the presenter. */
    atomic_bool announced; /* The renderer has a new frame. */
    atomic_bool called;    /* The last frame presented has reached the screen. */
    atomic_bool changed;   /* The view changed. */
    atomic_bool shown;

    /* Showing and hiding the source, off the main thread (show). */
    atomic_bool visible;  /* What the view wants. */
    atomic_bool queued;   /* A task of the shower's will look at VISIBLE. */
    bool applied_visible; /* What the source was last told, under LOCK. */

    /* The presenter's, while the stage is in its list; then the main
       thread's. */
    struct zwp_linux_dmabuf_v1 *dmabuf; /* Wrappers on the view's queue. */
    struct wl_shm *shm;
    struct cached cached[CACHED];
    struct canvas canvases[CANVASES];
    bool pending;   /* A frame was announced and not taken. */
    bool waiting;   /* A frame presented has not reached the screen. */
    bool memory;      /* DMABUFs cannot be shown. */
    atomic_bool told; /* The source was told so. */
    bool starved;   /* A frame in memory was dropped for want of a canvas. */
    int32_t width, height; /* The size of the frames now. */
    uint64_t clock;

    /* Counted, for the checks. */
    atomic_ullong ready, taken, committed, framed, refused;
};

static struct {
    pthread_mutex_t lock;
    bool started, broken;
    const struct portal_wayland *wayland;
    struct wl_event_queue *home;
    int wake; /* An eventfd. */
    struct portal_stage *stages;
    /* Whether the compositor took the first DMABUF: 0 not tried yet, 1 it
       did, -1 it did not, or none can be offered. */
    int dmabufs;
} presenter = {.lock = PTHREAD_MUTEX_INITIALIZER, .wake = -1};

static void wake(void)
{
    uint64_t one = 1;
    if (presenter.wake >= 0 && write(presenter.wake, &one, sizeof one) < 0)
        return; /* Already woken past what an eventfd counts. */
}

static void stage_unref(struct portal_stage *stage)
{
    if (atomic_fetch_sub(&stage->references, 1) != 1)
        return;
    pthread_rwlock_destroy(&stage->lock);
    free(stage);
}

/* The stage is done with FRAME: the source hears so, after it hears that
   the frame reached the screen, if it is to. */
static void frame_done(struct portal_stage *stage, struct portal_linux_frame *frame)
{
    if (frame == stage->unseen) {
        stage->unseen_done = true;
        return;
    }
    stage->source->done(frame);
}

/* The frame presented last reached the screen, or never will. */
static void frame_seen(struct portal_stage *stage)
{
    struct portal_linux_frame *frame = stage->unseen;
    if (!frame)
        return;
    stage->unseen = NULL;
    pthread_rwlock_rdlock(&stage->lock);
    if (stage->data)
        stage->source->shown(stage->data, frame);
    pthread_rwlock_unlock(&stage->lock);
    if (stage->unseen_done) {
        stage->unseen_done = false;
        stage->source->done(frame);
    }
}

/* Buffers. */

static void cached_drop(struct cached *cached)
{
    wl_buffer_destroy(cached->buffer);
    if (cached->frame)
        frame_done(cached->stage, cached->frame);
    *cached = (struct cached) {0};
}

/* The compositor no longer reads BUFFER: the renderer may draw into its
   texture again.  A buffer of a size the frames no longer have will not be
   used again. */
static void cached_released(void *data, struct wl_buffer *buffer)
{
    (void) buffer;
    struct cached *cached = data;
    struct portal_stage *stage = cached->stage;
    if (cached->frame) {
        frame_done(stage, cached->frame);
        cached->frame = NULL;
    }
    if (cached->width != stage->width || cached->height != stage->height)
        cached_drop(cached);
}

static const struct wl_buffer_listener cached_listener = {cached_released};

static void canvas_drop(struct canvas *canvas)
{
    wl_buffer_destroy(canvas->buffer);
    munmap(canvas->pixels, canvas->size);
    *canvas = (struct canvas) {0};
}

static void canvas_released(void *data, struct wl_buffer *buffer)
{
    (void) buffer;
    struct canvas *canvas = data;
    canvas->busy = false;
    /* A frame dropped for want of this one: the screen has an older one. */
    if (canvas->stage->starved) {
        canvas->stage->starved = false;
        canvas->stage->pending = true;
    }
}

static const struct wl_buffer_listener canvas_listener = {canvas_released};

/* Buffers that show nothing and are of no more use: those of another size
   than WIDTH by HEIGHT, or with ALL, every one, as when the surface was
   hidden and its textures are made anew when it shows. */
static void drop_unused(struct portal_stage *stage, bool all)
{
    for (size_t i = 0; i < CACHED; i++) {
        struct cached *cached = &stage->cached[i];
        if (cached->buffer && !cached->frame
            && (all || cached->width != stage->width || cached->height != stage->height))
            cached_drop(cached);
    }
}

/* SCREEN's view gave BUFFER back, never shown, or refused it: its frame
   is let go of. */
static void give_back(struct portal_stage *stage, struct wl_buffer *buffer)
{
    for (size_t i = 0; i < CACHED; i++) {
        struct cached *cached = &stage->cached[i];
        if (cached->buffer == buffer && cached->frame) {
            frame_done(stage, cached->frame);
            cached->frame = NULL;
        }
    }
    for (size_t i = 0; i < CANVASES; i++)
        if (stage->canvases[i].buffer == buffer)
            stage->canvases[i].busy = false;
}

/* What the compositor answered to the first DMABUF. */
struct asked {
    int answer; /* 0 waiting, 1 made, -1 refused. */
    struct wl_buffer *buffer;
};

static void params_created(void *data, struct zwp_linux_buffer_params_v1 *params,
                           struct wl_buffer *buffer)
{
    (void) params;
    struct asked *asked = data;
    asked->answer = 1;
    asked->buffer = buffer;
}

static void params_failed(void *data, struct zwp_linux_buffer_params_v1 *params)
{
    (void) params;
    ((struct asked *) data)->answer = -1;
}

static const struct zwp_linux_buffer_params_v1_listener params_listener = {params_created,
                                                                           params_failed};

static void add_planes(struct zwp_linux_buffer_params_v1 *params,
                       const struct portal_linux_frame *frame)
{
    for (uint32_t i = 0; i < frame->plane_count && i < 4; i++)
        zwp_linux_buffer_params_v1_add(params, frame->fds[i], i, frame->offsets[i],
                                       frame->strides[i], (uint32_t) (frame->modifier >> 32),
                                       (uint32_t) (frame->modifier & 0xffffffff));
}

/* FRAME as a wl_buffer on SCREEN's view's queue, or NULL if the compositor
   does not take it.  The first one is asked for and waited for, so that a
   refusal is an answer and not a protocol error, which would end Emacs's
   connection; once one is taken, the rest are made without waiting. */
static struct wl_buffer *import(struct portal_stage *stage, const struct portal_linux_frame *frame)
{
    if (presenter.dmabufs < 0 || !stage->dmabuf)
        return NULL;
    int32_t width = (int32_t) frame->width, height = (int32_t) frame->height;
    if (presenter.dmabufs > 0) {
        struct zwp_linux_buffer_params_v1 *params =
            zwp_linux_dmabuf_v1_create_params(stage->dmabuf);
        add_planes(params, frame);
        struct wl_buffer *buffer =
            zwp_linux_buffer_params_v1_create_immed(params, width, height, frame->fourcc, 0);
        zwp_linux_buffer_params_v1_destroy(params);
        return buffer;
    }
    struct wl_display *display = presenter.wayland->display;
    struct wl_event_queue *queue = wl_display_create_queue(display);
    struct zwp_linux_dmabuf_v1 *asking = wl_proxy_create_wrapper(presenter.wayland->dmabuf);
    wl_proxy_set_queue((struct wl_proxy *) asking, queue);
    struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(asking);
    wl_proxy_wrapper_destroy(asking);
    struct asked asked = {0};
    zwp_linux_buffer_params_v1_add_listener(params, &params_listener, &asked);
    add_planes(params, frame);
    zwp_linux_buffer_params_v1_create(params, width, height, frame->fourcc, 0);
    while (!asked.answer && wl_display_roundtrip_queue(display, queue) >= 0)
        continue;
    zwp_linux_buffer_params_v1_destroy(params);
    if (asked.buffer)
        wl_proxy_set_queue((struct wl_proxy *) asked.buffer, stage->view->queue);
    wl_event_queue_destroy(queue);
    presenter.dmabufs = asked.answer > 0 ? 1 : -1;
    if (asked.answer <= 0)
        fprintf(stderr, "Portal: the compositor took no DMABUF of a view's (%.4s, modifier "
                        "0x%llx): views draw into memory from now on\n",
                (const char *) &frame->fourcc, (unsigned long long) frame->modifier);
    return asked.buffer;
}

/* Presenting. */

/* Offer BUFFER, a frame WIDTH by HEIGHT, to SCREEN's view. */
static void offer(struct portal_stage *stage, struct wl_buffer *buffer, int32_t width,
                  int32_t height)
{
    struct wl_buffer *unused = NULL;
    enum portal_presented result =
        portal_linux_present(stage->view, buffer, width, height, NULL, &unused);
    if (unused)
        give_back(stage, unused);
    switch (result) {
    case PORTAL_PRESENTED:
        atomic_fetch_add(&stage->committed, 1);
        stage->waiting = true;
        break;
    case PORTAL_HELD:
        /* Shown after GTK paints, whose frame callback comes then. */
        stage->waiting = true;
        break;
    case PORTAL_REFUSED:
        atomic_fetch_add(&stage->refused, 1);
        give_back(stage, buffer);
        /* It never reaches the screen. */
        frame_seen(stage);
        break;
    }
}

/* A buffer for FRAME's texture: the one kept for it, or one imported now in
   a slot that holds no frame, the least recently used.  NULL with *REFUSED
   when the compositor does not take DMABUFs. */
static struct cached *cached_for(struct portal_stage *stage,
                                 const struct portal_linux_frame *frame, bool *refused)
{
    struct cached *empty = NULL, *oldest = NULL;
    for (size_t i = 0; i < CACHED; i++) {
        struct cached *cached = &stage->cached[i];
        if (cached->buffer && cached->texture == frame->texture)
            return cached;
        if (!cached->buffer) {
            if (!empty)
                empty = cached;
        } else if (!cached->frame && (!oldest || cached->used < oldest->used)) {
            oldest = cached;
        }
    }
    struct cached *slot = empty ? empty : oldest;
    if (!slot)
        return NULL;
    struct wl_buffer *buffer = import(stage, frame);
    if (!buffer) {
        *refused = true;
        return NULL;
    }
    if (slot->buffer)
        cached_drop(slot);
    *slot = (struct cached) {.stage = stage,
                             .buffer = buffer,
                             .texture = frame->texture,
                             .width = (int32_t) frame->width,
                             .height = (int32_t) frame->height};
    wl_buffer_add_listener(buffer, &cached_listener, slot);
    return slot;
}

/* FRAME, taken, is to be shown: its source hears when it was. */
static void showing(struct portal_stage *stage, struct portal_linux_frame *frame)
{
    if (!stage->source->shown)
        return;
    frame_seen(stage);
    stage->unseen = frame;
}

static void present_dmabuf(struct portal_stage *stage, struct portal_linux_frame *frame)
{
    bool refused = false;
    struct cached *cached = cached_for(stage, frame, &refused);
    showing(stage, frame);
    if (!cached) {
        /* Never shown, so let go of at once. */
        frame_seen(stage);
        frame_done(stage, frame);
        if (refused)
            stage->memory = true;
        return;
    }
    /* The renderer never draws into a texture whose frame is kept. */
    if (cached->frame)
        frame_done(stage, cached->frame);
    cached->frame = frame;
    cached->used = ++stage->clock;
    offer(stage, cached->buffer, cached->width, cached->height);
}

/* A canvas WIDTH by HEIGHT that nobody reads, made if need be; or NULL while
   every one is busy. */
static struct canvas *canvas_for(struct portal_stage *stage, int32_t width, int32_t height)
{
    struct canvas *unused = NULL;
    for (size_t i = 0; i < CANVASES; i++) {
        struct canvas *canvas = &stage->canvases[i];
        if (canvas->busy)
            continue;
        if (canvas->buffer && (canvas->width != width || canvas->height != height))
            canvas_drop(canvas);
        if (canvas->buffer)
            return canvas;
        unused = canvas;
    }
    if (!unused)
        return NULL;
    size_t size = (size_t) width * (size_t) height * 4;
    int memory = memfd_create("portal-view", MFD_CLOEXEC);
    if (memory < 0 || ftruncate(memory, (off_t) size) < 0) {
        if (memory >= 0)
            close(memory);
        return NULL;
    }
    void *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, memory, 0);
    if (pixels == MAP_FAILED) {
        close(memory);
        return NULL;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(stage->shm, memory, (int32_t) size);
    unused->buffer = wl_shm_pool_create_buffer(
        pool, 0, width, height, width * 4,
        presenter.wayland->shm_abgr ? WL_SHM_FORMAT_ABGR8888 : WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(memory);
    wl_buffer_add_listener(unused->buffer, &canvas_listener, unused);
    unused->stage = stage;
    unused->pixels = pixels;
    unused->size = size;
    unused->width = width;
    unused->height = height;
    unused->busy = false;
    return unused;
}

/* A frame in memory: RGBA bytes, which are ABGR8888 to wl_shm, or BGRA,
   ARGB8888, copied into a canvas, and let go of. */
static void present_memory(struct portal_stage *stage, struct portal_linux_frame *frame)
{
    int32_t width = (int32_t) frame->width, height = (int32_t) frame->height;
    struct canvas *canvas = canvas_for(stage, width, height);
    showing(stage, frame);
    if (!canvas) {
        frame_seen(stage);
        frame_done(stage, frame);
        stage->starved = true;
        return;
    }
    size_t row = (size_t) width * 4;
    size_t stride = frame->strides[0] ? frame->strides[0] : row;
    for (int32_t y = 0; y < height; y++) {
        uint8_t *to = (uint8_t *) canvas->pixels + (size_t) y * row;
        const uint8_t *from = frame->pixels + (size_t) y * stride;
        if (frame->bgra != presenter.wayland->shm_abgr) {
            memcpy(to, from, row);
            continue;
        }
        for (size_t i = 0; i < row; i += 4) {
            to[i] = from[i + 2];
            to[i + 1] = from[i + 1];
            to[i + 2] = from[i];
            to[i + 3] = from[i + 3];
        }
    }
    frame_done(stage, frame);
    canvas->busy = true;
    offer(stage, canvas->buffer, width, height);
}

/* Take the latest frame, if there is one, and present it. */
static void present_latest(struct portal_stage *stage)
{
    pthread_rwlock_rdlock(&stage->lock);
    struct portal_linux_frame *frame = stage->data ? stage->source->take(stage->data) : NULL;
    pthread_rwlock_unlock(&stage->lock);
    if (!frame)
        return;
    atomic_fetch_add(&stage->taken, 1);
    if ((int32_t) frame->width != stage->width || (int32_t) frame->height != stage->height) {
        stage->width = (int32_t) frame->width;
        stage->height = (int32_t) frame->height;
        drop_unused(stage, false);
    }
    if (frame->memory)
        present_memory(stage, frame);
    else
        present_dmabuf(stage, frame);
}

/* What SCREEN needs done, after what other threads told it. */
static void work(struct portal_stage *stage)
{
    if (atomic_exchange(&stage->changed, false)) {
        /* A frame presented may never reach the screen now, as when the
           view was hidden; and a frame for the change is wanted. */
        stage->waiting = false;
        stage->pending = true;
        frame_seen(stage);
        /* A hidden surface's textures are made anew when it shows. */
        if (!atomic_load(&stage->shown))
            drop_unused(stage, true);
    }
    if (atomic_exchange(&stage->called, false)) {
        stage->waiting = false;
        frame_seen(stage);
    }
    if (atomic_exchange(&stage->announced, false))
        stage->pending = true;
    if (stage->memory && !atomic_load(&stage->told)) {
        atomic_store(&stage->told, true);
        pthread_rwlock_rdlock(&stage->lock);
        if (stage->data && stage->source->memory)
            stage->source->memory(stage->data);
        pthread_rwlock_unlock(&stage->lock);
    }
    if (stage->pending && !stage->waiting) {
        stage->pending = false;
        present_latest(stage);
    }
}

/* Dispatch what waits on each stage's view's queue: frame callbacks and
   releases.  The number dispatched, or -1 once the display is gone. */
static int dispatch(void)
{
    int count = 0;
    for (struct portal_stage *stage = presenter.stages; stage; stage = stage->next) {
        int dispatched =
            wl_display_dispatch_queue_pending(presenter.wayland->display, stage->view->queue);
        if (dispatched < 0)
            return -1;
        count += dispatched;
    }
    return count;
}

static void *run(void *data)
{
    (void) data;
    struct wl_display *display = presenter.wayland->display;
    pthread_mutex_lock(&presenter.lock);
    for (;;) {
        for (struct portal_stage *stage = presenter.stages; stage; stage = stage->next)
            work(stage);
        int dispatched = dispatch();
        if (dispatched < 0)
            break;
        if (dispatched)
            continue;
        if (wl_display_prepare_read_queue(display, presenter.home) != 0) {
            if (wl_display_dispatch_queue_pending(display, presenter.home) < 0)
                break;
            continue;
        }
        /* Nobody reads without this thread now: what waits on a view's
           queue was read before, and is dispatched before the wait. */
        dispatched = dispatch();
        if (dispatched) {
            wl_display_cancel_read(display);
            if (dispatched < 0)
                break;
            continue;
        }
        pthread_mutex_unlock(&presenter.lock);
        wl_display_flush(display);
        struct pollfd waits[] = {{wl_display_get_fd(display), POLLIN, 0},
                                 {presenter.wake, POLLIN, 0}};
        int ready;
        do
            ready = poll(waits, 2, -1);
        while (ready < 0 && errno == EINTR);
        int got = 0;
        if (ready > 0 && (waits[0].revents & POLLIN))
            got = wl_display_read_events(display);
        else
            wl_display_cancel_read(display);
        if (ready > 0 && (waits[1].revents & POLLIN)) {
            uint64_t count;
            if (read(presenter.wake, &count, sizeof count) < 0)
                count = 0;
        }
        pthread_mutex_lock(&presenter.lock);
        if (got < 0 || (ready > 0 && (waits[0].revents & (POLLERR | POLLHUP))))
            break;
    }
    /* The display is gone, and Emacs with it. */
    presenter.broken = true;
    pthread_mutex_unlock(&presenter.lock);
    return NULL;
}

/* Showing and hiding a source, for one that asks.  Ghostty's
   ghostty_surface_set_occlusion takes the terminal's lock on the calling
   thread, which Ghostty's IO thread holds most of the time under a flood
   of output: showing a surface then took up to 164 ms.  So it runs on a
   thread of GLib's pool, never Emacs's main thread, under the stage's lock
   as a reader, which keeps the source's data from being freed meanwhile. */
static void show(gpointer data, gpointer unused)
{
    (void) unused;
    struct portal_stage *stage = data;
    atomic_store(&stage->queued, false);
    pthread_rwlock_rdlock(&stage->lock);
    bool visible = atomic_load(&stage->visible);
    if (stage->data && visible != stage->applied_visible) {
        stage->source->visible(stage->data, visible);
        stage->applied_visible = visible;
    }
    pthread_rwlock_unlock(&stage->lock);
    stage_unref(stage);
}

static GThreadPool *shower;

/* The stage's source is to be VISIBLE or not. */
static void want_visible(struct portal_stage *stage, bool visible)
{
    if (!stage->source->visible)
        return;
    atomic_store(&stage->visible, visible);
    if (atomic_exchange(&stage->queued, true))
        return;
    if (!shower)
        shower = g_thread_pool_new(show, NULL, 1, FALSE, NULL);
    atomic_fetch_add(&stage->references, 1);
    /* Without a thread, on this one: the task's reference goes either way. */
    if (!shower || !g_thread_pool_push(shower, stage, NULL))
        show(stage, NULL);
}

/* The interface of linux.h. */

struct portal_stage *portal_linux_stage_new(struct portal_view *view,
                                            const struct portal_stage_source *source)
{
    struct portal_stage *stage = calloc(1, sizeof *stage);
    if (!stage)
        return NULL;
    stage->view = view;
    stage->source = source;
    atomic_init(&stage->references, 1);
    pthread_rwlockattr_t attributes;
    pthread_rwlockattr_init(&attributes);
    /* The main thread, which frees the data, is not kept waiting behind
       a stream of readers. */
    pthread_rwlockattr_setkind_np(&attributes, PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
    pthread_rwlock_init(&stage->lock, &attributes);
    pthread_rwlockattr_destroy(&attributes);
    /* A source starts shown: Ghostty makes a surface so. */
    stage->applied_visible = true;
    atomic_init(&stage->visible, true);
    const struct portal_wayland *wayland = view->wayland;
    if (wayland->dmabuf) {
        stage->dmabuf = wl_proxy_create_wrapper(wayland->dmabuf);
        wl_proxy_set_queue((struct wl_proxy *) stage->dmabuf, view->queue);
    }
    stage->shm = wl_proxy_create_wrapper(wayland->shm);
    wl_proxy_set_queue((struct wl_proxy *) stage->shm, view->queue);
    return stage;
}

bool portal_linux_dmabufs_refused(void)
{
    pthread_mutex_lock(&presenter.lock);
    bool refused = presenter.dmabufs < 0 && presenter.wayland && presenter.wayland->dmabuf;
    pthread_mutex_unlock(&presenter.lock);
    return refused;
}

void portal_linux_stage_ready(void *data)
{
    struct portal_stage *stage = data;
    atomic_fetch_add(&stage->ready, 1);
    atomic_store(&stage->announced, true);
    wake();
}

bool portal_linux_stage_start(struct portal_stage *stage, void *data, portal_text *error)
{
    pthread_mutex_lock(&presenter.lock);
    bool started = presenter.started;
    if (!started && !presenter.broken) {
        presenter.wayland = stage->view->wayland;
        presenter.wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        presenter.home = wl_display_create_queue(presenter.wayland->display);
        if (!presenter.wayland->dmabuf)
            presenter.dmabufs = -1;
        pthread_t thread;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        started = presenter.wake >= 0 && !pthread_create(&thread, &attributes, run, NULL);
        pthread_attr_destroy(&attributes);
        if (!started) {
            if (presenter.wake >= 0)
                close(presenter.wake);
            presenter.wake = -1;
            wl_event_queue_destroy(presenter.home);
            presenter.home = NULL;
        }
        presenter.started = started;
    }
    if (started && !presenter.broken) {
        pthread_rwlock_wrlock(&stage->lock);
        stage->data = data;
        pthread_rwlock_unlock(&stage->lock);
        /* Once a compositor has refused one, no DMABUF is offered. */
        stage->memory = presenter.dmabufs < 0;
        stage->next = presenter.stages;
        presenter.stages = stage;
    }
    bool broken = presenter.broken;
    pthread_mutex_unlock(&presenter.lock);
    if (!started || broken)
        return portal_linux_fail(error, "Portal could not start the thread that shows views");
    wake();
    return true;
}

void portal_linux_stage_configure(struct portal_stage *stage, bool shown)
{
    atomic_store(&stage->shown, shown);
    atomic_store(&stage->changed, true);
    want_visible(stage, shown);
    wake();
}

void portal_linux_stage_frame(struct portal_stage *stage)
{
    atomic_fetch_add(&stage->framed, 1);
    atomic_store(&stage->called, true);
}

void portal_linux_stage_stop(struct portal_stage *stage)
{
    /* Out of the presenter's list: it no longer dispatches the view's
       queue, takes frames or makes requests for this stage. */
    pthread_mutex_lock(&presenter.lock);
    struct portal_stage **link = &presenter.stages;
    while (*link && *link != stage)
        link = &(*link)->next;
    if (*link)
        *link = stage->next;
    stage->next = NULL;
    pthread_mutex_unlock(&presenter.lock);
    /* And nothing else calls into the data: a show or hide under way
       finishes first. */
    pthread_rwlock_wrlock(&stage->lock);
    stage->data = NULL;
    pthread_rwlock_unlock(&stage->lock);
}

void portal_linux_stage_free(struct portal_stage *stage)
{
    /* The frames shown go with their buffers: a source allows that after
       its data is freed, as Ghostty does after its surface is, and the
       view's surface, which showed them, is gone. */
    for (size_t i = 0; i < CACHED; i++)
        if (stage->cached[i].buffer)
            cached_drop(&stage->cached[i]);
    for (size_t i = 0; i < CANVASES; i++)
        if (stage->canvases[i].buffer)
            canvas_drop(&stage->canvases[i]);
    if (stage->unseen && stage->unseen_done)
        stage->source->done(stage->unseen);
    stage->unseen = NULL;
    if (stage->dmabuf)
        wl_proxy_wrapper_destroy(stage->dmabuf);
    wl_proxy_wrapper_destroy(stage->shm);
    stage->dmabuf = NULL;
    stage->shm = NULL;
    stage_unref(stage);
}

void portal_linux_stage_describe(struct portal_stage *stage, struct json *description)
{
    char facts[256];
    /* "announced", frames the renderer made; "taken" by the presenter;
       "committed" to the view's surface by the presenter, not counting
       those the main thread committed after holding them; "framed", frame
       callbacks; "refused", frames the view did not take, being hidden;
       "memory", frames come in memory. */
    int length = snprintf(facts, sizeof facts,
                          "\"announced\":%llu,\"taken\":%llu,\"committed\":%llu,\"framed\":%llu,"
                          "\"refused\":%llu,\"memory\":%s,",
                          atomic_load(&stage->ready), atomic_load(&stage->taken),
                          atomic_load(&stage->committed), atomic_load(&stage->framed),
                          atomic_load(&stage->refused), atomic_load(&stage->told) ? "true" : "false");
    put(description, facts, (size_t) length);
}
