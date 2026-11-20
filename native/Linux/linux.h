/* SPDX-License-Identifier: GPL-3.0-or-later */
/* What the files of the Linux backend share.  Only they include this header.

   backend.c  the operations of portal.h that are not views or input, and
              the Wayland globals.
   views.c    a view from create to destroy: the frame it is in, its Wayland
              surface over a pane, and when each change reaches the screen.
   input.c    a view's keyboard and pointer: the invisible widget in the
              frame, who gets each key, the input method.
   terminal.c a terminal: a content that is a Ghostty surface, and Ghostty's
              app, which every terminal shares.
   presenter.c the thread that shows every terminal's frames.
   pattern.c  the other kind of content, a test pattern for the checks.

   A view has two parts in an Emacs frame, as docs/architecture.md says: a
   Wayland subsurface of the frame's window, which shows its pixels, and an
   invisible GTK widget in the frame's GtkFixed, which takes its input.  What
   the pixels are and what the input does is the view's content, below.

   Threads.  Everything here runs on the module thread, Emacs's main thread,
   which is GTK's, except what a content does on threads of its own or
   shares.  Such a thread may call only portal_linux_present and what is
   said to be for any thread. */
#ifndef PORTAL_LINUX_H
#define PORTAL_LINUX_H

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <gtk/gtk.h>
#include <wayland-client.h>

#include "core.h"
#include "portal.h"

/* Fail with the formatted message, for a Lisp `error' signal. */
bool portal_linux_fail(portal_text *error, const char *format, ...) G_GNUC_PRINTF(2, 3);

/* The display Emacs opened and what the backend binds on it.  The proxies
   are on the display's default queue, which GDK dispatches: none of them is
   given a listener, so GDK drops their events. */
struct portal_wayland {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct wp_viewporter *viewporter;
    struct wl_shm *shm;
    bool shm_abgr; /* wl_shm takes ABGR8888, RGBA bytes as they are. */
    /* Version 3, or NULL for a compositor that takes no DMABUFs: a
       terminal's frames then come in memory. */
    struct zwp_linux_dmabuf_v1 *dmabuf;
    /* The compositor crops a surface's buffer with the viewport's source
       rectangle before it applies the buffer's transform, which the
       viewporter protocol has the other way round: Hyprland, as of 0.56.2,
       for a buffer turned over (views.c, clip). */
    bool crops_buffer;
};
/* The display and its globals, bound at the first call.  Fails for an Emacs
   with no display, for a display that is not Wayland, and for a compositor
   that lacks one of them. */
const struct portal_wayland *portal_linux_wayland(portal_text *error);

/* A view's content: what it shows and what its input does.  Two kinds of
   content exist, a terminal (terminal.c) and the test pattern (pattern.c);
   a page is to come.  The view calls these on the module thread, except
   FRAME.

   A content draws on a thread, its own or one it shares with others, into
   wl_buffers it makes, and shows each with portal_linux_present.  Every
   proxy it makes belongs to the view's queue, so that its buffers' releases
   arrive on the thread that dispatches that queue, and nothing of its is
   ever dispatched by GDK.  Only that thread dispatches the queue, from the
   view's create until the content's STOP, or its DESTROY if it has no STOP.

   A view ends in this order (portal_view_destroy): STOP, if the content has
   one; the view's surface destroyed; DESTROY; the view's queue round-tripped,
   which delivers what was still on its way to it, and destroyed. */
struct portal_content_class {
    /* Stop drawing, before the view's surface goes: no thread of the
       content's dispatches the view's queue or presents a frame after this
       returns.  NULL for a content whose DESTROY does all of it. */
    void (*stop)(void *content);
    /* End the content: stop and join its threads, if STOP has not, then
       destroy every proxy it made. */
    void (*destroy)(void *content);
    /* The pane is WIDTH by HEIGHT of Emacs's pixels at SCALE device pixels
       each, and SHOWN or not: a view is not shown while it is detached, or
       while something of Emacs's covers its pane.  Called at each change.
       A content that is not shown has nothing to draw: no frame is taken
       from it and no frame callback comes. */
    void (*configure)(void *content, int32_t width, int32_t height, int32_t scale, bool shown);
    /* A frame shown with portal_linux_present has reached the screen, at
       TIME on the compositor's clock: the time to draw the next.  Called on
       the thread that dispatches the view's queue, once for each frame
       callback: at most one is asked for at a time. */
    void (*frame)(void *content, uint32_t time);
    /* The view's widget gained or lost the keyboard. */
    void (*focus)(void *content, bool focused);
    /* A key event for the content, a press, a repeat or a release, which
       the core passed.  TEXT is what the input method committed for it, as
       it does for a key that types, or NULL; COMPOSING, whether the input
       method is composing.  A press the input method took for itself,
       giving no text or composing, does not come here. */
    void (*key)(void *content, const GdkEventKey *event, const char *text, bool composing);
    /* Text the input method committed apart from any key, as when it ends
       composing, and the text it is composing, with the cursor's position
       in it in characters; "" once it is done. */
    void (*text)(void *content, const char *text);
    void (*preedit)(void *content, const char *text, int cursor);
    /* A button, motion, scroll or crossing event over the view, with its
       position in the pane, in Emacs's pixels from the pane's top left. */
    void (*pointer)(void *content, const GdkEvent *event);
    /* The core offers EVENT, a press, to the content's app, which answers
       later with portal_linux_input_settle.  NULL for a content whose app
       is never asked: it gets the press as any other key. */
    void (*offer)(void *content, const GdkEventKey *event);
    /* Add what only the content knows to DESCRIPTION, as members of a JSON
       object, each followed by a comma. */
    void (*describe)(void *content, struct json *description);
    /* The content's own Copy command, and its Paste of TEXT. */
    void (*copy)(void *content);
    void (*paste)(void *content, const char *text);
};

struct portal_frame;

/* A pane's rectangle in its frame, in Emacs's pixels, and whether the view
   is shown there. */
struct portal_geometry {
    int32_t x, y, width, height;
    bool shown;
};

/* Where a content's frames go in its pane, when they are not the pane's
   size: a frame WIDTH by HEIGHT device pixels whose top left is X and Y
   device pixels from the pane's, either of which may be negative, and
   clipped to the pane.  A fed terminal that holds a grid of its own is so
   (terminal.c).  Unplaced, a frame is shown from the pane's top left. */
struct portal_placement {
    bool placed;
    int32_t x, y, width, height;
};

/* A view, as the core holds it from portal_view_create to
   portal_view_destroy. */
struct portal_view {
    struct portal_view *all; /* The next of every view there is (views.c). */
    uint64_t serial;         /* Its own, never another view's: see portal_linux_view_find. */
    portal_kind kind;
    char *target; /* For records, NUL-terminated. */
    size_t target_length;
    const struct portal_content_class *class;
    void *content;
    /* The content's frames are bottom-up, its first row the bottom one:
       set when it is made, for every frame it presents. */
    bool flipped;
    /* The view has a backdrop, a colour over all of its pane under the
       content's frames, for a content whose frames may leave part of the
       pane bare: set when it is made.  Its colour: portal_linux_view_backdrop. */
    bool backdrop;
    const struct portal_wayland *wayland;
    /* The content's threads' queue, the view's from create to destroy. */
    struct wl_event_queue *queue;

    /* The frame it is in, attached or parked, or NULL; and the next view
       of that frame. */
    struct portal_frame *frame;
    struct portal_view *next;
    bool attached;   /* Emacs has it in a pane, at RECT. */
    bool occluded;   /* A child frame of Emacs's is over the pane. */
    portal_rect rect;
    int32_t scale;   /* As the content was last told. */
    /* Where the subsurface was last put in the window's surface, if
       POSITIONED; and the backdrop's. */
    bool positioned;
    int32_t position_x, position_y;
    bool under_positioned;
    int32_t under_x, under_y;
    /* The backdrop, the main thread's alone: its subsurface, below the
       view's, and the colour it shows, premultiplied ARGB, which is
       COLOUR once applied.  UNDER_SHOWING: it shows UNDER_WIDTH by
       UNDER_HEIGHT of Emacs's pixels of it. */
    struct wl_surface *under;
    struct wl_subsurface *under_subsurface;
    struct wp_viewport *under_viewport;
    struct wl_buffer *under_buffer, *under_spent; /* The colour's; the one before it. */
    uint32_t colour, under_colour;
    bool under_showing;
    int32_t under_width, under_height;

    /* Input (input.c). */
    GtkWidget *widget;   /* The input widget, a reference of the view's. */
    GtkIMContext *method;
    bool reported;       /* Whether the core was last told it has the keyboard. */
    GdkEvent *trigger;   /* The press the core said to hold, or offered. */
    bool trigger_repeat; /* Whether that press was a repeat. */
    bool offering;       /* The trigger is with the content's app. */
    bool holding;        /* Key events go to HELD. */
    GQueue held;         /* GdkEvent copies, oldest first. */
    guint replay;        /* The idle source that delivers HELD, or 0. */
    /* The input method: whether it is composing; and while a key event is
       being filtered, whether it was composing then (KEYING), and what it
       committed for that key (TYPED). */
    const char *cursor; /* The pointer's shape over the view, a CSS name, or NULL. */
    bool composing;
    enum { PORTAL_KEYING_NONE, PORTAL_KEYING_PLAIN, PORTAL_KEYING_COMPOSING } keying;
    GString *typed;

    /* The surface, and what of it the content's threads share: everything
       from here on, under LOCK.  Whoever holds the lock leaves no state
       pending on the surface: every request it makes is committed before
       it lets go. */
    pthread_mutex_t lock;
    struct wl_surface *surface;
    struct wl_surface *framed; /* A wrapper on QUEUE, for frame callbacks. */
    struct wl_subsurface *subsurface;
    struct wp_viewport *viewport;
    struct wl_callback *callback; /* The frame callback asked for, or NULL. */
    int32_t surface_scale;        /* Device pixels to one of Emacs's. */
    /* Where Emacs wants the view, and what the screen has: the main thread
       makes the second the first after GTK paints.  The same for where the
       content's frames go in the pane. */
    struct portal_geometry wanted, applied;
    struct portal_placement wanted_place, applied_place;
    /* The frame attached to the surface, if SHOWING, in device pixels; 0
       by 0 for one that fills the pane. */
    bool showing;
    int32_t shown_width, shown_height;
    /* A frame the content presented for WANTED, kept until it is applied. */
    struct wl_buffer *held_buffer;
    int32_t held_width, held_height;
    bool held_stale; /* It was held before the view was last hidden. */
    /* The frame showing is the one the content presented last, so the
       damage it gives with its next is against what the screen has. */
    bool sequential;
};

/* An Emacs frame that has views: its GtkWindow and the GtkFixed Emacs draws
   in. */
struct portal_frame {
    struct portal_frame *next;
    GtkWindow *window;
    GtkWidget *fixed;
    GdkFrameClock *clock;
    struct wl_surface *parent; /* The window's, GDK's proxy. */
    /* The window's updates are held back, FROZEN being the GdkWindow, until
       Emacs has drawn (SETTLED) and the views have their frames, or until
       the timeout DEADLINE (views.c). */
    GdkWindow *frozen;
    bool settled;
    guint deadline;
    gint64 frozen_at; /* On GLib's monotonic clock, in microseconds. */
    struct portal_view *views; /* Attached or parked here. */
    /* Input (input.c). */
    struct portal_view *keyboard; /* The view the window's keys go to, or NULL. */
    bool moving;                  /* The backend itself is moving GTK's focus. */
    struct {
        guint16 keycode;
        struct portal_view *owner;
    } pressed[16]; /* The keys that are down, and who got each press. */
    size_t pressed_count;
};

/* views.c, for input.c and pattern.c. */

/* The view whose serial is SERIAL, or NULL once it has ended: for work that
   finishes after a call returns, which a view may not outlive.  Such work
   keeps the serial and never the view, whose address a later view may
   have. */
struct portal_view *portal_linux_view_find(uint64_t serial);
/* SERIAL in memory of its own, for a callback's data, which g_free frees. */
uint64_t *portal_linux_serial(uint64_t serial);
/* Have GTK paint in VIEW's frame soon, which applies what waits. */
void portal_linux_view_repaint(struct portal_view *view);
/* VIEW's content puts its frames at PLACEMENT in the pane from now on: a
   change of the view as a change of its pane is, which the screen takes
   with the first frame presented for it, the content's frames being of
   PLACEMENT's size; unplaced, of the pane's.  On the module thread. */
void portal_linux_view_place(struct portal_view *view, struct portal_placement placement);
/* VIEW, which has a backdrop, shows it in RED, GREEN and BLUE, from 0 to
   255, at ALPHA from 0 to 1, from the next paint on.  On the module
   thread. */
void portal_linux_view_backdrop(struct portal_view *view, uint8_t red, uint8_t green,
                                uint8_t blue, double alpha);

/* What became of a frame given to portal_linux_present. */
enum portal_presented {
    PORTAL_PRESENTED, /* Attached and committed: the compositor will release it. */
    PORTAL_HELD,      /* Kept for the main thread to commit after GTK paints. */
    PORTAL_REFUSED,   /* The view is not shown: the buffer is the caller's still. */
};
/* Show BUFFER on VIEW's surface, a frame WIDTH by HEIGHT device pixels, or
   0 by 0 for a frame that fills the pane whatever its size, as a single
   pixel does.  From any thread.  A sized frame is shown from the pane's top
   left, one buffer pixel to a device pixel, and clipped to the pane.

   DAMAGE, if not NULL, is the x, y, width and height of what changed in
   the buffer since the frame before it; otherwise all of it did.

   A frame for the size Emacs wants the pane to have, which the screen does
   not have yet, is held: the main thread commits it with the pane's new
   place, after GTK paints.  So is a frame for a view about to be shown.
   A frame held is given up for the next one presented, held or shown:
   *UNUSED is then its buffer, which was never attached and is the caller's
   again; otherwise NULL.  A frame held when the view is hidden stays held,
   and shows when the view does unless another was presented.  A frame
   callback follows each frame that is committed. */
enum portal_presented portal_linux_present(struct portal_view *view, struct wl_buffer *buffer,
                                           int32_t width, int32_t height,
                                           const int32_t *damage, struct wl_buffer **unused);

/* input.c, for views.c and pattern.c. */

/* Make VIEW's widget and input method; and end them, with what it holds. */
void portal_linux_input_open(struct portal_view *view);
void portal_linux_input_close(struct portal_view *view);
/* Start and stop watching FRAME's window for keys and focus. */
void portal_linux_input_watch(struct portal_frame *frame);
void portal_linux_input_unwatch(struct portal_frame *frame);
/* Put VIEW's widget over its pane in its frame; and take it out of the
   frame, giving Emacs the keyboard if the view has it. */
void portal_linux_input_place(struct portal_view *view);
void portal_linux_input_park(struct portal_view *view);
/* Whether VIEW has its window's keyboard. */
bool portal_linux_input_focused(const struct portal_view *view);
/* The content's app has handled the press offered to it: it USED it, or
   the core decides what happens to it. */
void portal_linux_input_settle(struct portal_view *view, bool used);
/* Translate EVENT's key code with the modifiers STATE, setting *KEYVAL,
   and set *CONSUMED, if not NULL, to the modifiers the event's own
   translation used.  False when the keymap GDK has now does not translate
   the code to the event's keyval: it changed since the event was made, as
   a virtual keyboard's does each time it starts, and the event's keyval is
   all there is to go by. */
bool portal_linux_input_translate(const GdkEventKey *event, GdkModifierType state, guint *keyval,
                                  GdkModifierType *consumed);
/* Show the pointer over VIEW as NAME, a cursor's CSS name in static memory,
   or as its parent's for NULL. */
void portal_linux_input_cursor(struct portal_view *view, const char *name);

/* backend.c, terminal.c and pattern.c. */

/* Give VIEW, a new view, the content its kind and OPTIONS ask for, setting
   its class and content; or fail, as for a kind that has none yet. */
bool portal_linux_content_create(struct portal_view *view, const portal_option *options,
                                 size_t count, portal_text *error);
/* Make a test pattern for VIEW from OPTIONS. */
bool portal_linux_pattern_create(struct portal_view *view, const portal_option *options,
                                 size_t count, portal_text *error);
/* Make a terminal for VIEW from OPTIONS, whose :directory the core has
   checked. */
bool portal_linux_terminal_create(struct portal_view *view, const portal_option *options,
                                  size_t count, portal_text *error);
/* Start Ghostty's library, once, and set *RESOURCES to the directory of
   its resources, which stays as long as the process; or fail, the same way
   each time after a first failure. */
bool portal_linux_ghostty_start(const char **resources, portal_text *error);

/* presenter.c, for terminal.c: what shows a terminal's frames.

   A stage is a terminal as the presenter has it: its Ghostty surface and
   the buffers made for its frames.  The presenter is one thread for every
   terminal, with a Wayland queue of its own, which it reads the display
   with, and it dispatches each stage's view's queue.  Ghostty's renderer
   announces each frame on its own thread; the presenter takes the latest
   when the view's last frame has reached the screen, at its frame
   callback, and shows it, so it commits no faster than the compositor
   shows.  A frame is kept until the compositor releases the buffer it was
   shown with.

   A stage is made, with portal_linux_stage_new, before its Ghostty
   surface, whose frame-ready callback is portal_linux_stage_ready with the
   stage; started with that surface; stopped before the surface is freed,
   which Portal's main thread does; and freed after the view's surface is
   gone.  Between the stop and the free, Ghostty may still announce frames,
   until ghostty_surface_free returns. */
struct portal_stage;
struct portal_stage *portal_linux_stage_new(struct portal_view *view);
/* Ghostty's frame-ready callback for the stage DATA: on the render thread. */
void portal_linux_stage_ready(void *data);
/* Start showing SURFACE, a ghostty_surface_t, on STAGE's view. */
bool portal_linux_stage_start(struct portal_stage *stage, void *surface, portal_text *error);
/* The view changed: its size, its scale or whether it is SHOWN.  The stage
   asks Ghostty to show or hide the surface to match, off the main thread:
   Ghostty takes the terminal's lock for that, which its IO thread holds
   most of the time under a flood of output. */
void portal_linux_stage_configure(struct portal_stage *stage, bool shown);
/* A frame shown on STAGE's view has reached the screen: its frame
   callback, on the presenter's thread. */
void portal_linux_stage_frame(struct portal_stage *stage);
/* Forget STAGE's surface: nothing of the presenter's calls into it after
   this returns, and it may be freed. */
void portal_linux_stage_stop(struct portal_stage *stage);
/* Destroy STAGE's buffers, freeing the frames they showed, and STAGE. */
void portal_linux_stage_free(struct portal_stage *stage);
/* Add what the presenter counted for STAGE to DESCRIPTION, as members of a
   JSON object, each followed by a comma. */
void portal_linux_stage_describe(struct portal_stage *stage, struct json *description);

#endif
