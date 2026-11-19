/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Views on Linux: where a view is, and when each change of it reaches the
   screen.

   A view's pixels are a Wayland subsurface of its frame's window, over the
   pane.  The subsurface takes no input: its input region is empty, so the
   pointer goes through it to the widget of input.c, which sits in the same
   place.

   When changes are made.  Emacs asks for a view's place from a hook that
   runs before it has drawn its own new layout, and the view's content
   draws for the new size on a thread of its own.  Each alone would reach
   the screen when it happened to be ready: the view a frame ahead of the
   panes around it, or a frame behind, or its old frame in the new place.
   So a change is a transaction on the frame's window.  An attach or a
   detach only notes what Emacs wants (`wanted') and freezes the window's
   updates: GTK may run meanwhile, as it does whenever Emacs looks for
   input, in the middle of a redisplay too, but it paints nothing of the
   window.  Emacs says when it has drawn (portal_frames_drawn), and the
   window thaws once each view of it that needs a new frame has been
   presented one, or UNDRAWN milliseconds later.  GTK then paints Emacs's
   new layout, and in that paint the views are made so (`applied'): the
   subsurface's position is sent before GTK commits the window's surface,
   which is when the protocol applies it, and the surface's own state, its
   frame, its size and whether it shows anything, is committed just after,
   from the frame clock's `after-paint': all of it in the same write to the
   compositor as Emacs's frame.  A window is never frozen for longer than
   UNSETTLED milliseconds, whatever Emacs says or does not.

   Who makes which request.  A view's content may draw on a thread of its
   own, and the frames it draws must go on showing while Lisp is busy, so
   that thread attaches buffers and commits them itself.  The requests are
   divided so:

   - The subsurface (its position, its mode, its end) is the main thread's
     alone, and so are making and destroying the surface and the viewport.
   - The surface's state, which a commit applies (its buffer, its damage,
     the viewport's source and destination, a frame callback) is made only
     under the view's lock, by portal_linux_present for the content, from
     any thread, and by the main thread after GTK paints.  Whoever holds the
     lock commits what it has set before letting go, so no commit ever
     carries half of another's change.
   - Under the lock, the content's thread only shows frames: it attaches a
     buffer for the size the pane has on the screen, and the viewport cuts
     it to that size.  The main thread does the rest, and only after GTK
     paints: it attaches nothing to hide the view, cuts the frame showing
     to a pane that shrank, and attaches the frame the content presented
     for a pane's new size or for a view about to be shown, which
     portal_linux_present holds until then.
   - A frame callback is asked for on a wrapper of the surface that belongs
     to the view's queue, and the content's buffers belong to that queue
     too: both are heard on the content's thread.

   A subsurface cannot change its parent, so a view that moves to another
   frame gets a new surface there.  The content never sees a surface: it
   presents buffers, which any surface takes.

   Ending a view, in the order that keeps a queue from outliving what was
   made on it (portal_view_destroy): the content stops its threads and
   destroys its buffers; the surface goes, with the frame callback and the
   wrapper; the queue is round-tripped, which delivers what was still on its
   way, and destroyed; then the input method and the widget. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gdk/gdkwayland.h>

#include "linux.h"
#include "viewporter-client-protocol.h"

static struct portal_view *views;    /* Every view there is. */
static struct portal_frame *frames;  /* Every frame that has views. */

struct portal_view *portal_linux_view_find(uint64_t serial)
{
    for (struct portal_view *view = views; view; view = view->all)
        if (view->serial == serial)
            return view;
    return NULL;
}

uint64_t *portal_linux_serial(uint64_t serial)
{
    uint64_t *copy = g_new(uint64_t, 1);
    *copy = serial;
    return copy;
}

/* How long a window stays frozen at most, in milliseconds: for Emacs to say
   it has drawn, which it does at the end of the redisplay or the command
   that asked; and after that for the views' frames, which a content draws
   in a few milliseconds.  Emacs's own drawing waits as long, so neither is
   more than a hitch. */
enum { UNSETTLED = 150, UNDRAWN = 50 };

/* One pixel, enough for GTK to paint and commit the window's surface. */
void portal_linux_view_repaint(struct portal_view *view)
{
    if (view->frame)
        gtk_widget_queue_draw_area(view->frame->fixed, 0, 0, 1, 1);
}

/* Let FRAME's window paint again, which applies what its views wait for. */
static void thaw(struct portal_frame *frame)
{
    if (!frame->frozen)
        return;
    if (frame->deadline)
        g_source_remove(frame->deadline);
    frame->deadline = 0;
    if (!gdk_window_is_destroyed(frame->frozen))
        gdk_window_thaw_updates(frame->frozen);
    g_object_unref(frame->frozen);
    frame->frozen = NULL;
    gtk_widget_queue_draw_area(frame->fixed, 0, 0, 1, 1);
}

static gboolean overdue(gpointer data)
{
    struct portal_frame *frame = data;
    frame->deadline = 0;
    thaw(frame);
    return G_SOURCE_REMOVE;
}

/* Thaw FRAME's window after at most WAIT more milliseconds, and never
   later than UNSETTLED after it froze. */
static void thaw_within(struct portal_frame *frame, gint64 wait)
{
    gint64 left = UNSETTLED - (g_get_monotonic_time() - frame->frozen_at) / 1000;
    if (frame->deadline)
        g_source_remove(frame->deadline);
    frame->deadline = g_timeout_add((guint) CLAMP(MIN(wait, left), 0, UNSETTLED), overdue, frame);
}

/* Hold back the updates of FRAME's window for a change of its views:
   until Emacs says it has drawn, or, when Emacs has nothing to draw for
   it (SETTLED), only until the views have their frames. */
static void freeze(struct portal_frame *frame, bool settled)
{
    GdkWindow *window = gtk_widget_get_window(GTK_WIDGET(frame->window));
    if (!window || !gtk_widget_get_mapped(GTK_WIDGET(frame->window)))
        return;
    if (frame->frozen) {
        /* One more change of the same transaction. */
        frame->settled = frame->settled && settled;
        return;
    }
    gdk_window_freeze_updates(window);
    frame->frozen = g_object_ref(window);
    frame->frozen_at = g_get_monotonic_time();
    frame->settled = settled;
    thaw_within(frame, settled ? UNDRAWN : UNSETTLED);
}

/* Whether VIEW has what its change needs: a frame to show, if it is to be
   shown or has a new size.  A frame that fills needs another for a new
   size too: Hyprland applies a surface's new size only with a buffer. */
static bool ready(struct portal_view *view)
{
    pthread_mutex_lock(&view->lock);
    bool resized = view->wanted.width != view->applied.width
                || view->wanted.height != view->applied.height;
    int32_t scale = view->surface_scale > 0 ? view->surface_scale : 1;
    /* A frame held since before the view was last hidden is not one the
       content drew for this change. */
    bool has = view->held_buffer && !view->held_stale
            && ((!view->held_width && !view->held_height)
                || (view->held_width == view->wanted.width * scale
                    && view->held_height == view->wanted.height * scale));
    bool needs = view->surface && view->wanted.shown && !has
              && (!view->applied.shown || resized);
    pthread_mutex_unlock(&view->lock);
    return !needs;
}

/* Thaw FRAME's window if Emacs has drawn and its views are ready. */
static void consider(struct portal_frame *frame)
{
    if (!frame->frozen || !frame->settled)
        return;
    for (struct portal_view *view = frame->views; view; view = view->next)
        if (!ready(view))
            return;
    thaw(frame);
}

/* The surface. */

/* The frame callback of a frame the content presented.  It runs on the
   thread that dispatches the view's queue.  The main thread may have
   destroyed the callback meanwhile, as when it hid the view: then it is no
   longer the view's, and nobody is told. */
static void frame_done(void *data, struct wl_callback *callback, uint32_t time)
{
    struct portal_view *view = data;
    pthread_mutex_lock(&view->lock);
    bool current = view->callback == callback;
    if (current) {
        view->callback = NULL;
        wl_callback_destroy(callback);
    }
    pthread_mutex_unlock(&view->lock);
    if (current)
        view->class->frame(view->content, time);
}

static const struct wl_callback_listener frame_listener = {frame_done};

/* Cut the frame attached to VIEW's surface to the pane the screen has: all
   of a frame that fills, and otherwise its top left, one buffer pixel to a
   device pixel.  The caller holds the lock, and commits. */
static void clip(struct portal_view *view)
{
    int32_t scale = view->surface_scale > 0 ? view->surface_scale : 1;
    int32_t width = view->applied.width, height = view->applied.height;
    if (!view->shown_width || !view->shown_height) {
        wl_fixed_t unset = wl_fixed_from_int(-1);
        wp_viewport_set_source(view->viewport, unset, unset, unset, unset);
        wp_viewport_set_destination(view->viewport, width, height);
        return;
    }
    /* Never past the buffer's edge, which is a protocol error. */
    int32_t columns = MIN(view->shown_width, width * scale);
    int32_t rows = MIN(view->shown_height, height * scale);
    wp_viewport_set_source(view->viewport, 0, 0, wl_fixed_from_int(columns),
                           wl_fixed_from_int(rows));
    wp_viewport_set_destination(view->viewport, (columns + scale - 1) / scale,
                                (rows + scale - 1) / scale);
}

/* Attach BUFFER, a frame WIDTH by HEIGHT, to VIEW's surface and commit it,
   asking for a frame callback unless one is still to come.  The caller
   holds the lock. */
static void show(struct portal_view *view, struct wl_buffer *buffer, int32_t width,
                 int32_t height, const int32_t *damage)
{
    view->showing = true;
    view->shown_width = width;
    view->shown_height = height;
    clip(view);
    wl_surface_attach(view->surface, buffer, 0, 0);
    if (damage)
        wl_surface_damage_buffer(view->surface, damage[0], damage[1], damage[2], damage[3]);
    else
        wl_surface_damage_buffer(view->surface, 0, 0, INT32_MAX, INT32_MAX);
    if (!view->callback) {
        view->callback = wl_surface_frame(view->framed);
        wl_callback_add_listener(view->callback, &frame_listener, view);
    }
    wl_surface_commit(view->surface);
}

/* Take what VIEW's surface shows off the screen.  The frame callback asked
   for will not come for a surface that shows nothing, and the next frame
   asks again.  The caller holds the lock. */
static void conceal(struct portal_view *view)
{
    if (view->callback) {
        wl_callback_destroy(view->callback);
        view->callback = NULL;
    }
    if (view->showing) {
        wl_surface_attach(view->surface, NULL, 0, 0);
        wl_surface_commit(view->surface);
        view->showing = false;
    }
}

/* A frame is held for VIEW: its window may be waiting for it, and if not,
   only a paint shows it. */
static gboolean kick(gpointer data)
{
    /* The view may have ended since its thread asked. */
    struct portal_view *view = portal_linux_view_find(*(uint64_t *) data);
    if (!view || !view->frame)
        return G_SOURCE_REMOVE;
    if (view->frame->frozen)
        consider(view->frame);
    else
        portal_linux_view_repaint(view);
    return G_SOURCE_REMOVE;
}

enum portal_presented portal_linux_present(struct portal_view *view, struct wl_buffer *buffer,
                                           int32_t width, int32_t height,
                                           const int32_t *damage, struct wl_buffer **unused)
{
    enum portal_presented result;
    *unused = NULL;
    pthread_mutex_lock(&view->lock);
    int32_t scale = view->surface_scale > 0 ? view->surface_scale : 1;
    bool resizing = view->wanted.width != view->applied.width
                 || view->wanted.height != view->applied.height;
    /* A frame that fills is for any size. */
    bool for_wanted = (!width && !height)
                   || (width == view->wanted.width * scale && height == view->wanted.height * scale);
    if (!view->surface || !view->wanted.shown) {
        result = PORTAL_REFUSED;
    } else if (!view->applied.shown || (resizing && for_wanted)) {
        if (view->held_buffer && view->held_buffer != buffer)
            *unused = view->held_buffer;
        view->held_buffer = buffer;
        view->held_width = width;
        view->held_height = height;
        view->held_stale = false;
        view->sequential = false;
        result = PORTAL_HELD;
    } else {
        /* A frame held is older than this one, and will never show. */
        if (view->held_buffer && view->held_buffer != buffer)
            *unused = view->held_buffer;
        view->held_buffer = NULL;
        /* DAMAGE is against the frame presented before this one, which is
           not what the screen has if that one was held. */
        show(view, buffer, width, height, view->sequential ? damage : NULL);
        view->sequential = true;
        wl_display_flush(wl_proxy_get_display((struct wl_proxy *) view->surface));
        result = PORTAL_PRESENTED;
    }
    pthread_mutex_unlock(&view->lock);
    /* A held frame waits for GTK to paint, which nothing else may ask for,
       and GTK may wait for it. */
    if (result == PORTAL_HELD)
        g_idle_add_full(G_PRIORITY_DEFAULT, kick, portal_linux_serial(view->serial), g_free);
    return result;
}

/* Make VIEW's surface, a subsurface of its frame's window that shows
   nothing yet.  Does nothing while the window has no surface, as while its
   frame is invisible. */
static void surface_make(struct portal_view *view)
{
    const struct portal_wayland *wayland = view->wayland;
    if (view->surface || !view->frame || !view->frame->parent)
        return;
    pthread_mutex_lock(&view->lock);
    view->surface = wl_compositor_create_surface(wayland->compositor);
    /* No input: the pointer goes through to the widget in the frame.  With
       an input region, the surface would take the pointer and GDK, which
       does not know the surface, would drop it. */
    struct wl_region *nowhere = wl_compositor_create_region(wayland->compositor);
    wl_surface_set_input_region(view->surface, nowhere);
    wl_region_destroy(nowhere);
    view->subsurface = wl_subcompositor_get_subsurface(wayland->subcompositor, view->surface,
                                                       view->frame->parent);
    /* The content's commits show at once, whatever Emacs is doing. */
    wl_subsurface_set_desync(view->subsurface);
    view->viewport = wp_viewporter_get_viewport(wayland->viewporter, view->surface);
    view->framed = wl_proxy_create_wrapper(view->surface);
    wl_proxy_set_queue((struct wl_proxy *) view->framed, view->queue);
    wl_surface_commit(view->surface);
    view->applied = (struct portal_geometry) {0};
    view->showing = false;
    view->sequential = false;
    view->positioned = false;
    pthread_mutex_unlock(&view->lock);
}

/* Destroy VIEW's surface, if it has one.  A frame held for it stays held:
   it is the content's latest, and the next surface takes it. */
static void surface_destroy(struct portal_view *view)
{
    pthread_mutex_lock(&view->lock);
    if (view->surface) {
        if (view->callback)
            wl_callback_destroy(view->callback);
        wl_proxy_wrapper_destroy(view->framed);
        wp_viewport_destroy(view->viewport);
        wl_subsurface_destroy(view->subsurface);
        wl_surface_destroy(view->surface);
        view->callback = NULL;
        view->framed = NULL;
        view->viewport = NULL;
        view->subsurface = NULL;
        view->surface = NULL;
        view->applied = (struct portal_geometry) {0};
        view->showing = false;
    }
    pthread_mutex_unlock(&view->lock);
}

/* Note where Emacs wants VIEW and whether it is to show, tell its content
   what changed, and have GTK paint.  With AGAIN, tell the content even if
   nothing did, as when its frames must go to a new surface. */
static void want(struct portal_view *view, bool again)
{
    struct portal_frame *frame = view->frame;
    bool shown = frame && view->attached && !view->occluded;
    int32_t scale = frame ? gtk_widget_get_scale_factor(GTK_WIDGET(frame->window)) : view->scale;
    int32_t width = (int32_t) view->rect.width, height = (int32_t) view->rect.height;
    pthread_mutex_lock(&view->lock);
    bool changed = again || shown != view->wanted.shown || scale != view->surface_scale
                || width != view->wanted.width || height != view->wanted.height;
    view->wanted = (struct portal_geometry) {(int32_t) view->rect.x, (int32_t) view->rect.y,
                                             width, height, shown};
    view->surface_scale = scale;
    pthread_mutex_unlock(&view->lock);
    view->scale = scale;
    if (changed)
        view->class->configure(view->content, width, height, scale, shown);
    portal_linux_view_repaint(view);
}

/* Frames. */

/* Whether CHILD, a child of FRAME's GtkFixed, is a child frame of Emacs's:
   pgtk puts a child frame's own GtkFixed into its parent's. */
static bool child_frame(const struct portal_frame *frame, GtkWidget *child)
{
    return G_OBJECT_TYPE(child) == G_OBJECT_TYPE(frame->fixed);
}

/* Whether a child frame that shows is over RECT in FRAME.  A child frame is
   drawn in its parent's surface, so a view's subsurface would cover it. */
static bool covered(const struct portal_frame *frame, const portal_rect *rect)
{
    GList *children = gtk_container_get_children(GTK_CONTAINER(frame->fixed));
    bool found = false;
    for (GList *item = children; item && !found; item = item->next) {
        GtkWidget *child = item->data;
        GtkAllocation area;
        if (!child_frame(frame, child) || !gtk_widget_get_mapped(child))
            continue;
        gtk_widget_get_allocation(child, &area);
        found = area.x < rect->x + rect->width && rect->x < area.x + area.width
             && area.y < rect->y + rect->height && rect->y < area.y + area.height;
    }
    g_list_free(children);
    return found;
}

/* Hide each view of FRAME that a child frame is over, and show it again
   once none is. */
static void cover(struct portal_frame *frame)
{
    for (struct portal_view *view = frame->views; view; view = view->next) {
        bool occluded = view->attached && covered(frame, &view->rect);
        if (occluded != view->occluded) {
            view->occluded = occluded;
            /* The child frame goes from the screen when GTK next paints:
               so does the view come back, if its frame is there by then. */
            if (!occluded)
                freeze(frame, true);
            want(view, false);
        }
    }
}

static void child_changed(GtkWidget *child, gpointer data)
{
    (void) child;
    cover(data);
}

static void child_allocated(GtkWidget *child, GdkRectangle *area, gpointer data)
{
    (void) child, (void) area;
    cover(data);
}

/* Hear of each child frame of FRAME that comes, goes or moves.  GtkFixed
   announces no new child, so this looks each time GTK has painted: a child
   frame is first seen with its first frame.  One that goes is heard of at
   once, in time for the view's content to draw before GTK paints. */
static void watch_children(struct portal_frame *frame)
{
    static GQuark watched;
    if (!watched)
        watched = g_quark_from_static_string("portal-watched");
    GList *children = gtk_container_get_children(GTK_CONTAINER(frame->fixed));
    for (GList *item = children; item; item = item->next) {
        GtkWidget *child = item->data;
        if (!child_frame(frame, child) || g_object_get_qdata(G_OBJECT(child), watched) == frame)
            continue;
        g_object_set_qdata(G_OBJECT(child), watched, frame);
        g_signal_connect(child, "map", G_CALLBACK(child_changed), frame);
        g_signal_connect(child, "unmap", G_CALLBACK(child_changed), frame);
        g_signal_connect(child, "size-allocate", G_CALLBACK(child_allocated), frame);
    }
    g_list_free(children);
}

static void unwatch_children(struct portal_frame *frame)
{
    GQuark watched = g_quark_from_static_string("portal-watched");
    GList *children = gtk_container_get_children(GTK_CONTAINER(frame->fixed));
    for (GList *item = children; item; item = item->next) {
        if (g_object_get_qdata(G_OBJECT(item->data), watched) != frame)
            continue;
        g_object_set_qdata(G_OBJECT(item->data), watched, NULL);
        g_signal_handlers_disconnect_by_data(item->data, frame);
    }
    g_list_free(children);
}

/* The surface of FRAME's window, which is the parent of its views'
   surfaces.  GTK destroys it when it hides the window and makes another
   when it shows it again: the views' surfaces go and come with it. */
static void follow_parent(struct portal_frame *frame, bool mapped)
{
    GdkWindow *window = gtk_widget_get_window(GTK_WIDGET(frame->window));
    struct wl_surface *parent =
        mapped && window ? gdk_wayland_window_get_wl_surface(window) : NULL;
    if (parent == frame->parent)
        return;
    for (struct portal_view *view = frame->views; view; view = view->next)
        surface_destroy(view);
    frame->parent = parent;
    for (struct portal_view *view = frame->views; view; view = view->next) {
        surface_make(view);
        want(view, true);
    }
}

static void window_unmapped(GtkWidget *window, gpointer data)
{
    (void) window;
    thaw(data);
    follow_parent(data, false);
}

/* Send each view of FRAME its new position in the window's surface, where
   the compositor applies it with the commit of that surface that follows.
   Emacs's menu bar and tool bar are GTK's, beside the GtkFixed, which they
   move in the window; a tab bar is Emacs's own, inside it. */
static void position(struct portal_frame *frame)
{
    int left = 0, top = 0;
    gtk_widget_translate_coordinates(frame->fixed, GTK_WIDGET(frame->window), 0, 0, &left, &top);
    for (struct portal_view *view = frame->views; view; view = view->next) {
        int32_t x = (int32_t) view->rect.x + left, y = (int32_t) view->rect.y + top;
        if (!view->surface || !view->attached || view->occluded
            || (view->positioned && x == view->position_x && y == view->position_y))
            continue;
        wl_subsurface_set_position(view->subsurface, x, y);
        view->positioned = true;
        view->position_x = x;
        view->position_y = y;
    }
}

/* GTK draws Emacs's widget, in a paint of a window that is not frozen:
   before it commits the window's surface. */
static gboolean emacs_drawn(GtkWidget *fixed, cairo_t *cairo, gpointer data)
{
    (void) fixed, (void) cairo;
    position(data);
    return FALSE;
}

static void before_paint(GdkFrameClock *clock, gpointer data)
{
    (void) clock;
    struct portal_frame *frame = data;
    follow_parent(frame, gtk_widget_get_mapped(GTK_WIDGET(frame->window)));
}

/* GTK has painted FRAME's window and committed its surface: make each
   view's surface what Emacs wants, in the same write to the compositor.
   The clock runs for a frozen window too, which paints and commits
   nothing: its views wait with it. */
static void after_paint(GdkFrameClock *clock, gpointer data)
{
    (void) clock;
    struct portal_frame *frame = data;
    /* A child frame's first frame is in this paint.  One that went may
       freeze the window here, for the view it was over. */
    watch_children(frame);
    cover(frame);
    if (frame->frozen)
        return;
    /* A paint that drew nothing of Emacs's widget sent no position: late,
       then, for this commit of the window's surface. */
    position(frame);
    int scale = gtk_widget_get_scale_factor(GTK_WIDGET(frame->window));
    for (struct portal_view *view = frame->views; view; view = view->next) {
        if (scale != view->scale)
            want(view, false);
        pthread_mutex_lock(&view->lock);
        if (view->surface) {
            bool resized = view->wanted.width != view->applied.width
                        || view->wanted.height != view->applied.height;
            view->applied = view->wanted;
            if (!view->wanted.shown) {
                conceal(view);
                view->held_stale = true;
            } else if (view->held_buffer) {
                show(view, view->held_buffer, view->held_width, view->held_height, NULL);
                view->held_buffer = NULL;
                view->sequential = true;
            } else if (view->showing && resized) {
                clip(view);
                wl_surface_commit(view->surface);
            }
        }
        pthread_mutex_unlock(&view->lock);
    }
    if (frame->parent)
        wl_display_flush(wl_proxy_get_display((struct wl_proxy *) frame->parent));
}

static void frame_free(struct portal_frame *frame)
{
    struct portal_frame **link = &frames;
    while (*link != frame)
        link = &(*link)->next;
    *link = frame->next;
    thaw(frame);
    portal_linux_input_unwatch(frame);
    unwatch_children(frame);
    g_signal_handlers_disconnect_by_data(frame->clock, frame);
    g_signal_handlers_disconnect_by_data(frame->window, frame);
    g_object_unref(frame->clock);
    g_object_unref(frame->fixed);
    free(frame);
}

/* Take VIEW out of its frame, which no longer holds it; a frame left with
   no view is forgotten. */
static void leave(struct portal_view *view)
{
    struct portal_frame *frame = view->frame;
    if (!frame)
        return;
    portal_linux_input_park(view);
    surface_destroy(view);
    struct portal_view **link = &frame->views;
    while (*link != view)
        link = &(*link)->next;
    *link = view->next;
    view->next = NULL;
    view->frame = NULL;
    view->occluded = false;
    if (!frame->views)
        frame_free(frame);
}

/* Emacs deleted FRAME, or made it a child frame, with views in it: forget
   them.  Each stays open, in no frame, until Emacs places it again.  GTK
   emits this before it destroys the window's children, so the views'
   widgets are taken out of the frame, not destroyed with it. */
static void window_destroyed(GtkWidget *window, gpointer data)
{
    (void) window;
    struct portal_frame *frame = data;
    /* The last view to leave frees FRAME, which is not looked at again. */
    for (struct portal_view *view = frame->views, *next; view; view = next) {
        next = view->next;
        leave(view);
        want(view, false);
    }
}

static void find_fixed(GtkWidget *widget, gpointer found)
{
    GtkWidget **fixed = found;
    if (*fixed)
        return;
    if (GTK_IS_FIXED(widget))
        *fixed = widget;
    else if (GTK_IS_CONTAINER(widget))
        gtk_container_forall(GTK_CONTAINER(widget), find_fixed, found);
}

/* The frame whose window is titled TITLE now.  Emacs gives the frame that
   title for the length of the call (docs/adr/0002), and pgtk sets a
   window's title at once, so the window is found afresh each time. */
static struct portal_frame *frame_titled(portal_string title, portal_text *error)
{
    GList *windows = gtk_window_list_toplevels();
    GtkWindow *window = NULL;
    for (GList *item = windows; item && !window; item = item->next) {
        const char *name = gtk_window_get_title(item->data);
        if (name && strlen(name) == title.length && !memcmp(name, title.data, title.length))
            window = item->data;
    }
    g_list_free(windows);
    /* A child frame has no window of its own: pgtk draws it in its
       parent's. */
    if (!window) {
        portal_linux_fail(error, "The view's frame was deleted, or is a child frame");
        return NULL;
    }
    for (struct portal_frame *frame = frames; frame; frame = frame->next)
        if (frame->window == window)
            return frame;
    GtkWidget *fixed = NULL;
    find_fixed(GTK_WIDGET(window), &fixed);
    GdkWindow *native = gtk_widget_get_window(GTK_WIDGET(window));
    GdkFrameClock *clock = gtk_widget_get_frame_clock(GTK_WIDGET(window));
    if (!fixed || !native || !clock || !GDK_IS_WAYLAND_WINDOW(native)) {
        portal_linux_fail(error, "The view's frame has no window on Wayland");
        return NULL;
    }
    struct portal_frame *frame = calloc(1, sizeof *frame);
    if (!frame) {
        portal_linux_fail(error, "Portal is out of memory");
        return NULL;
    }
    frame->window = window;
    frame->fixed = g_object_ref(fixed);
    frame->clock = g_object_ref(clock);
    frame->parent = gtk_widget_get_mapped(GTK_WIDGET(window))
                        ? gdk_wayland_window_get_wl_surface(native)
                        : NULL;
    g_signal_connect(fixed, "draw", G_CALLBACK(emacs_drawn), frame);
    g_signal_connect(clock, "before-paint", G_CALLBACK(before_paint), frame);
    g_signal_connect(clock, "after-paint", G_CALLBACK(after_paint), frame);
    g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed), frame);
    g_signal_connect(window, "unmap", G_CALLBACK(window_unmapped), frame);
    watch_children(frame);
    portal_linux_input_watch(frame);
    frame->next = frames;
    frames = frame;
    return frame;
}

/* The primitives of portal.h. */

bool portal_view_create(portal_kind kind, portal_string target, const portal_option *options,
                        size_t count, portal_view **created, portal_text *error)
{
    const struct portal_wayland *wayland = portal_linux_wayland(error);
    if (!wayland)
        return false;
    struct portal_view *view = calloc(1, sizeof *view);
    char *name = malloc(target.length + 1);
    if (!view || !name) {
        free(view);
        free(name);
        return portal_linux_fail(error, "Portal is out of memory");
    }
    memcpy(name, target.data, target.length);
    name[target.length] = '\0';
    static uint64_t serials;
    view->serial = ++serials;
    view->kind = kind;
    view->target = name;
    view->target_length = target.length;
    view->wayland = wayland;
    view->scale = 1;
    pthread_mutex_init(&view->lock, NULL);
    view->queue = wl_display_create_queue(wayland->display);
    portal_linux_input_open(view);
    if (!portal_linux_content_create(view, options, count, error)) {
        portal_linux_input_close(view);
        wl_event_queue_destroy(view->queue);
        pthread_mutex_destroy(&view->lock);
        free(name);
        free(view);
        return false;
    }
    view->all = views;
    views = view;
    *created = view;
    return true;
}

bool portal_view_destroy(portal_view *view, portal_text *error)
{
    (void) error;
    if (view->frame)
        portal_linux_input_park(view);
    /* In this order.  The content's threads stop, and its buffers go; then
       the surface, with what the view made on the content's queue; then the
       queue, once a round trip has delivered what was on its way to it.  A
       queue destroyed with a proxy still on it, or events still to come for
       one, brings Emacs down. */
    view->class->destroy(view->content);
    surface_destroy(view);
    wl_display_roundtrip_queue(view->wayland->display, view->queue);
    wl_event_queue_destroy(view->queue);
    portal_linux_input_close(view);
    leave(view);
    struct portal_view **link = &views;
    while (*link != view)
        link = &(*link)->all;
    *link = view->all;
    pthread_mutex_destroy(&view->lock);
    free(view->target);
    free(view);
    return true;
}

bool portal_view_attach(portal_view *view, portal_string title, portal_rect rect,
                        portal_text *error)
{
    /* Checked before anything moves, so a failure leaves the view where it
       was. */
    struct portal_frame *frame = frame_titled(title, error);
    if (!frame)
        return false;
    bool moved = view->frame != frame;
    if (moved) {
        leave(view);
        view->frame = frame;
        view->next = frame->views;
        frame->views = view;
        surface_make(view);
    }
    view->attached = true;
    view->rect = rect;
    view->occluded = covered(frame, &rect);
    portal_linux_input_place(view);
    freeze(frame, false);
    want(view, moved);
    return true;
}

bool portal_view_detach(portal_view *view, portal_text *error)
{
    (void) error;
    /* Parked: its widget out of the frame at once, and its surface showing
       nothing from the next paint on, when Emacs's own pane is there. */
    view->attached = false;
    view->occluded = false;
    portal_linux_input_park(view);
    if (view->frame)
        freeze(view->frame, false);
    want(view, false);
    return true;
}

bool portal_frames_drawn(portal_text *error)
{
    (void) error;
    for (struct portal_frame *frame = frames; frame; frame = frame->next) {
        if (!frame->frozen || frame->settled)
            continue;
        frame->settled = true;
        thaw_within(frame, UNDRAWN);
        consider(frame);
    }
    return true;
}

bool portal_view_describe(portal_view *view, portal_text *state, portal_text *error)
{
    struct json json = {0};
    pthread_mutex_lock(&view->lock);
    bool showing = view->showing;
    pthread_mutex_unlock(&view->lock);
    put(&json, "{", 1);
    view->class->describe(view->content, &json);
    char facts[192];
    /* "focused": its window's keys go to it, whether or not the window has
       the keyboard, which is "active".  "showing": a frame of the content's
       is on the screen.  "occluded": the view is hidden while a child frame
       of Emacs's is over its pane. */
    bool active = view->frame && gtk_window_has_toplevel_focus(view->frame->window);
    int length = snprintf(facts, sizeof facts,
                          "\"focused\":%s,\"active\":%s,\"showing\":%s,\"occluded\":%s,"
                          "\"scale\":%d}",
                          portal_linux_input_focused(view) ? "true" : "false",
                          active ? "true" : "false", showing ? "true" : "false",
                          view->occluded ? "true" : "false", (int) view->scale);
    put(&json, facts, (size_t) length);
    if (json.failed) {
        free(json.data);
        return portal_linux_fail(error, "Portal is out of memory");
    }
    *state = (portal_text) {json.data, json.length};
    return true;
}
