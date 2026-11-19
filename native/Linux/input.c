/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Input on Linux: a view's keyboard and pointer.

   The widget.  Each view has a GtkEventBox with an input-only window, which
   draws nothing, in Emacs's GtkFixed over the view's pane.  The pointer
   over the pane is the widget's, at the pane's coordinates, and the widget
   takes GTK's keyboard focus when the view has the keyboard, so that
   Emacs's own widget loses it and the input method has a client.

   Keys.  A handler on the frame's window is the first to see every key
   event, before GtkWindow's own keys, such as F10 for the menu bar, and
   before the focused widget.  There the core decides (native/Core/input.c):
   the handler asks it about each press in a view that has the keyboard or
   holds a trigger, and does what it answers.  A key for the view goes to
   its input method, then to its content, and never on to GTK; a key for
   Emacs is left to GTK, which gives it to Emacs's widget.  Held events are
   copies, delivered again through gtk_main_do_event, so each passes this
   handler again as a new event would.

   The keyboard.  `keyboard' is the view its window's keys go to, as the
   core is told (portal_input_focus).  The view's widget is the window's
   focus widget only while the window itself has the keyboard: when the
   window loses it, the backend gives GTK's focus back to Emacs's widget
   first, and takes it again when the window has the keyboard back.  Emacs
   hears of its frame's focus from that widget alone, so this is what lets
   it hear the window lose and gain the keyboard while a view has it
   (portal-view.el says what Lisp makes of the rest). */
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>

#include "linux.h"

static portal_string target(const struct portal_view *view)
{
    return (portal_string) {view->target, view->target_length};
}

bool portal_linux_input_focused(const struct portal_view *view)
{
    return view->frame && view->frame->keyboard == view;
}

/* Tell the core whether VIEW has the keyboard, when that changed. */
static void report(struct portal_view *view, bool focused)
{
    if (view->reported == focused)
        return;
    view->reported = focused;
    portal_input_focus(target(view), focused);
}

/* Give GTK's focus in FRAME's window to WIDGET.  The handlers below know
   that this is the backend's own doing. */
static void move_focus(struct portal_frame *frame, GtkWidget *widget)
{
    if (gtk_widget_in_destruction(GTK_WIDGET(frame->window))
        || gtk_window_get_focus(frame->window) == widget)
        return;
    frame->moving = true;
    gtk_widget_grab_focus(widget);
    frame->moving = false;
}

/* Give VIEW the keyboard of its window. */
static void give(struct portal_view *view)
{
    struct portal_frame *frame = view->frame;
    struct portal_view *other = frame->keyboard;
    frame->keyboard = view;
    if (other && other != view)
        report(other, false);
    /* A window without the keyboard takes it for the view when it gets it
       back (window_focused). */
    if (gtk_window_has_toplevel_focus(frame->window))
        move_focus(frame, view->widget);
    report(view, true);
}

/* Return the keyboard to Emacs, if VIEW has it. */
static void take(struct portal_view *view)
{
    struct portal_frame *frame = view->frame;
    if (frame && frame->keyboard == view) {
        frame->keyboard = NULL;
        GtkWidget *focus = gtk_window_get_focus(frame->window);
        if (!focus || focus == view->widget)
            move_focus(frame, frame->fixed);
    }
    report(view, false);
}

/* The way back to Emacs that needs neither Lisp nor the app: report it
   even if the view does not have the keyboard, which ends a handoff Emacs
   is handling. */
static void escape(struct portal_view *view)
{
    take(view);
    view->reported = false;
    portal_input_focus(target(view), false);
}

/* The widget. */

static gboolean widget_focused(GtkWidget *widget, GdkEventFocus *event, gpointer data)
{
    (void) widget;
    struct portal_view *view = data;
    struct portal_frame *frame = view->frame;
    if (event->in) {
        gtk_im_context_focus_in(view->method);
        /* GTK gave it the keyboard by a way of its own. */
        if (frame && frame->keyboard != view && !frame->moving) {
            struct portal_view *other = frame->keyboard;
            frame->keyboard = view;
            if (other)
                report(other, false);
            report(view, true);
        }
    } else {
        gtk_im_context_focus_out(view->method);
        /* Something else in the window took the keyboard, as a child frame
           of Emacs's does when it is clicked. */
        if (frame && frame->keyboard == view && !frame->moving) {
            frame->keyboard = NULL;
            report(view, false);
        }
    }
    view->class->focus(view->content, event->in);
    return FALSE;
}

/* Whether the pointer over VIEW's widget is the view's now.  While a child
   frame hides the view, the pane under the widget is Emacs's. */
static bool pointed(const struct portal_view *view)
{
    return view->frame && view->attached && !view->occluded;
}

static gboolean widget_pressed(GtkWidget *widget, GdkEventButton *event, gpointer data)
{
    (void) widget;
    struct portal_view *view = data;
    if (!pointed(view))
        return FALSE;
    /* A click that gives the view the keyboard asks Emacs to select the
       view's pane, so the two agree.  The report comes first, as it
       abandons a handoff whose keys Emacs may be reading. */
    if (event->type == GDK_BUTTON_PRESS && view->frame->keyboard != view) {
        view->reported = true;
        portal_input_focus(target(view), true);
        portal_notify((portal_string) {"select", 6}, target(view), NULL, 0);
        give(view);
    }
    view->class->pointer(view->content, (const GdkEvent *) event);
    return TRUE;
}

static gboolean widget_pointed(GtkWidget *widget, GdkEvent *event, gpointer data)
{
    (void) widget;
    struct portal_view *view = data;
    if (!pointed(view))
        return FALSE;
    view->class->pointer(view->content, event);
    return TRUE;
}

/* The widget's own window, which takes its events: GTK makes it with the
   widget, above every window in Emacs's GtkFixed then.  A child frame of
   Emacs's is such a window too, and the pointer over one must be its own
   wherever a view's pane is, so the widget's goes to the bottom. */
/* The widget's own window, an input-only child of its parent's, or NULL
   while it has none. */
static GdkWindow *widget_window(GtkWidget *widget)
{
    GdkWindow *parent = gtk_widget_get_window(widget);
    for (GList *item = parent ? gdk_window_peek_children(parent) : NULL; item; item = item->next) {
        gpointer owner = NULL;
        gdk_window_get_user_data(item->data, &owner);
        if (owner == widget)
            return item->data;
    }
    return NULL;
}

/* Show the pointer over VIEW's widget as its content last asked. */
static void point(struct portal_view *view)
{
    GdkWindow *window = view->widget ? widget_window(view->widget) : NULL;
    if (!window)
        return;
    GdkCursor *cursor =
        view->cursor ? gdk_cursor_new_from_name(gdk_window_get_display(window), view->cursor) : NULL;
    gdk_window_set_cursor(window, cursor);
    if (cursor)
        g_object_unref(cursor);
}

void portal_linux_input_cursor(struct portal_view *view, const char *name)
{
    if (view->cursor == name)
        return;
    view->cursor = name;
    point(view);
}

static void widget_mapped(GtkWidget *widget, gpointer data)
{
    struct portal_view *view = data;
    gtk_im_context_set_client_window(view->method, gtk_widget_get_window(widget));
    GdkWindow *window = widget_window(widget);
    if (window)
        gdk_window_lower(window);
    point(view);
}

static void widget_unrealized(GtkWidget *widget, gpointer data)
{
    (void) widget;
    struct portal_view *view = data;
    gtk_im_context_set_client_window(view->method, NULL);
}

/* The input method.  As in Ghostty's own GTK view: text committed while a
   key is filtered, and nothing was being composed, is what that key types,
   and goes to the content with the key (deliver); text committed apart
   from a key, or that ends composing, goes as text. */
static void committed(GtkIMContext *method, gchar *text, gpointer data)
{
    (void) method;
    struct portal_view *view = data;
    if (view->keying == PORTAL_KEYING_PLAIN) {
        g_string_append(view->typed, text);
        return;
    }
    view->composing = false;
    view->class->text(view->content, text);
}

static void composing(GtkIMContext *method, gpointer data)
{
    struct portal_view *view = data;
    gchar *text = NULL;
    gint cursor = 0;
    /* Some input methods change the preedit after a commit, with no new
       start. */
    view->composing = true;
    gtk_im_context_get_preedit_string(method, &text, NULL, &cursor);
    view->class->preedit(view->content, text ? text : "", cursor);
    g_free(text);
}

static void composing_started(GtkIMContext *method, gpointer data)
{
    (void) method;
    struct portal_view *view = data;
    view->composing = true;
}

static void composing_ended(GtkIMContext *method, gpointer data)
{
    (void) method;
    struct portal_view *view = data;
    view->composing = false;
    view->class->preedit(view->content, "", 0);
}

void portal_linux_input_open(struct portal_view *view)
{
    GtkWidget *widget = gtk_event_box_new();
    /* An input-only window: the widget draws nothing over Emacs's text. */
    gtk_event_box_set_visible_window(GTK_EVENT_BOX(widget), FALSE);
    gtk_widget_set_can_focus(widget, TRUE);
    gtk_widget_add_events(widget, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK
                                      | GDK_POINTER_MOTION_MASK | GDK_SCROLL_MASK
                                      | GDK_SMOOTH_SCROLL_MASK | GDK_ENTER_NOTIFY_MASK
                                      | GDK_LEAVE_NOTIFY_MASK | GDK_FOCUS_CHANGE_MASK);
    g_signal_connect(widget, "focus-in-event", G_CALLBACK(widget_focused), view);
    g_signal_connect(widget, "focus-out-event", G_CALLBACK(widget_focused), view);
    g_signal_connect(widget, "button-press-event", G_CALLBACK(widget_pressed), view);
    g_signal_connect(widget, "button-release-event", G_CALLBACK(widget_pressed), view);
    g_signal_connect(widget, "motion-notify-event", G_CALLBACK(widget_pointed), view);
    g_signal_connect(widget, "scroll-event", G_CALLBACK(widget_pointed), view);
    g_signal_connect(widget, "enter-notify-event", G_CALLBACK(widget_pointed), view);
    g_signal_connect(widget, "leave-notify-event", G_CALLBACK(widget_pointed), view);
    g_signal_connect(widget, "map", G_CALLBACK(widget_mapped), view);
    g_signal_connect(widget, "unrealize", G_CALLBACK(widget_unrealized), view);
    view->widget = g_object_ref_sink(widget);
    view->method = gtk_im_multicontext_new();
    g_signal_connect(view->method, "commit", G_CALLBACK(committed), view);
    g_signal_connect(view->method, "preedit-changed", G_CALLBACK(composing), view);
    g_signal_connect(view->method, "preedit-start", G_CALLBACK(composing_started), view);
    g_signal_connect(view->method, "preedit-end", G_CALLBACK(composing_ended), view);
    view->typed = g_string_new(NULL);
    g_queue_init(&view->held);
}

/* Drop the key events VIEW holds, its trigger included. */
static void discard(struct portal_view *view)
{
    if (view->replay) {
        g_source_remove(view->replay);
        view->replay = 0;
    }
    if (view->trigger)
        gdk_event_free(view->trigger);
    view->trigger = NULL;
    view->offering = false;
    view->holding = false;
    for (GdkEvent *event; (event = g_queue_pop_head(&view->held));)
        gdk_event_free(event);
}

void portal_linux_input_close(struct portal_view *view)
{
    discard(view);
    /* The input method first, as it is the widget's window's client. */
    gtk_im_context_set_client_window(view->method, NULL);
    g_signal_handlers_disconnect_by_data(view->method, view);
    g_object_unref(view->method);
    view->method = NULL;
    g_string_free(view->typed, TRUE);
    view->typed = NULL;
    g_signal_handlers_disconnect_by_data(view->widget, view);
    gtk_widget_destroy(view->widget);
    g_object_unref(view->widget);
    view->widget = NULL;
}

void portal_linux_input_place(struct portal_view *view)
{
    GtkWidget *fixed = view->frame->fixed, *widget = view->widget;
    gtk_widget_set_size_request(widget, (gint) view->rect.width, (gint) view->rect.height);
    if (gtk_widget_get_parent(widget) == fixed) {
        gtk_fixed_move(GTK_FIXED(fixed), widget, (gint) view->rect.x, (gint) view->rect.y);
    } else {
        gtk_fixed_put(GTK_FIXED(fixed), widget, (gint) view->rect.x, (gint) view->rect.y);
        gtk_widget_show(widget);
    }
}

/* Forget VIEW in FRAME's record of the keys that are down. */
static void forget(struct portal_frame *frame, const struct portal_view *view)
{
    for (size_t i = 0; i < frame->pressed_count; i++)
        if (frame->pressed[i].owner == view)
            frame->pressed[i].owner = NULL;
}

void portal_linux_input_park(struct portal_view *view)
{
    if (!view->widget)
        return;
    take(view);
    if (view->frame)
        forget(view->frame, view);
    GtkWidget *parent = gtk_widget_get_parent(view->widget);
    if (parent)
        gtk_container_remove(GTK_CONTAINER(parent), view->widget);
}

/* Keys. */

/* EVENT's key as the core sees it: the character it types with Shift but
   no other modifier, and Portal's modifiers.  Alt is Meta.  The keys that
   type a control character have it, as on macOS; a key that types no
   character, such as an arrow, is 0. */
bool portal_linux_input_translate(const GdkEventKey *event, GdkModifierType state, guint *keyval,
                                  GdkModifierType *consumed)
{
    GdkKeymap *keymap = gdk_keymap_get_for_display(gdk_window_get_display(event->window));
    guint again;
    return gdk_keymap_translate_keyboard_state(keymap, event->hardware_keycode, event->state,
                                               event->group, &again, NULL, NULL, consumed)
        && again == event->keyval
        && gdk_keymap_translate_keyboard_state(keymap, event->hardware_keycode, state,
                                               event->group, keyval, NULL, NULL, NULL);
}

static portal_chord chord_of(const GdkEventKey *event)
{
    guint symbol = event->keyval, plain;
    /* Its keyval with Shift alone; or, where the key's code no longer
       translates as it did, the keyval it came with, Control and all. */
    if (portal_linux_input_translate(event, event->state & GDK_SHIFT_MASK, &plain, NULL))
        symbol = plain;
    uint32_t character;
    switch (symbol) {
    case GDK_KEY_Escape:
        character = 27;
        break;
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter:
    case GDK_KEY_ISO_Enter:
        character = '\r';
        break;
    case GDK_KEY_Tab:
    case GDK_KEY_KP_Tab:
    case GDK_KEY_ISO_Left_Tab:
        character = '\t';
        break;
    case GDK_KEY_BackSpace:
        character = 0x7f;
        break;
    default:
        character = gdk_keyval_to_unicode(symbol);
        if (character < ' ' || character == 0x7f)
            character = 0;
    }
    uint32_t modifiers = 0;
    if (event->state & GDK_SHIFT_MASK)
        modifiers |= PORTAL_SHIFT;
    if (event->state & GDK_CONTROL_MASK)
        modifiers |= PORTAL_CONTROL;
    if (event->state & (GDK_MOD1_MASK | GDK_META_MASK))
        modifiers |= PORTAL_META;
    if (event->state & (GDK_MOD4_MASK | GDK_SUPER_MASK))
        modifiers |= PORTAL_SUPER;
    return (portal_chord) {character, modifiers};
}

/* Give EVENT to VIEW's app: its input method first, then its content with
   the text the input method committed for it.  A press the input method
   took for itself goes no further: one it is composing with, one that
   ends composing, which commits text of its own, and one that typed
   nothing, as when it opens a picker of its own. */
static void deliver(struct portal_view *view, GdkEventKey *event)
{
    bool before = view->composing;
    view->keying = before ? PORTAL_KEYING_COMPOSING : PORTAL_KEYING_PLAIN;
    g_string_truncate(view->typed, 0);
    bool taken = gtk_im_context_filter_keypress(view->method, event);
    view->keying = PORTAL_KEYING_NONE;
    if (taken && (view->composing || before || !view->typed->len))
        return;
    view->class->key(view->content, event, view->typed->len ? view->typed->str : NULL,
                     view->composing);
}

/* The view whose handoff Emacs is handling in FRAME's window, or whose app
   has not answered a press offered to it: key events there are its own. */
static struct portal_view *capture(const struct portal_frame *frame)
{
    for (struct portal_view *view = frame->views; view; view = view->next)
        if (view->trigger)
            return view;
    return NULL;
}

/* Note that KEYCODE went down in FRAME's window, for OWNER or for Emacs,
   and return whether it was down already: a repeat. */
static bool pressed(struct portal_frame *frame, guint16 keycode, struct portal_view *owner)
{
    for (size_t i = 0; i < frame->pressed_count; i++)
        if (frame->pressed[i].keycode == keycode) {
            frame->pressed[i].owner = owner;
            return true;
        }
    if (frame->pressed_count == G_N_ELEMENTS(frame->pressed))
        frame->pressed_count = 0; /* More keys than hands: start again. */
    frame->pressed[frame->pressed_count].keycode = keycode;
    frame->pressed[frame->pressed_count++].owner = owner;
    return false;
}

/* Note that KEYCODE went up, and return whether its press went to OWNER,
   or was never seen. */
static bool released(struct portal_frame *frame, guint16 keycode, const struct portal_view *owner)
{
    for (size_t i = 0; i < frame->pressed_count; i++)
        if (frame->pressed[i].keycode == keycode) {
            bool same = frame->pressed[i].owner == owner;
            frame->pressed[i] = frame->pressed[--frame->pressed_count];
            return same;
        }
    return true;
}

/* A key event in FRAME's window, before GTK has done anything with it:
   true if it is not Emacs's. */
static gboolean window_keyed(GtkWidget *window, GdkEventKey *event, gpointer data)
{
    (void) window;
    struct portal_frame *frame = data;
    struct portal_view *view = capture(frame);
    if (!view)
        view = frame->keyboard;
    bool press = event->type == GDK_KEY_PRESS;
    bool asked = press && !event->is_modifier;
    if (!view) {
        if (press)
            pressed(frame, event->hardware_keycode, NULL);
        /* A release whose press a view got is not for Emacs. */
        return !press && !released(frame, event->hardware_keycode, NULL);
    }
    portal_chord chord = chord_of(event);
    /* Before anything is held, and without a round trip to Lisp or the
       app, so that the way back always works. */
    if (asked && portal_input_is_escape(chord)) {
        pressed(frame, event->hardware_keycode, view);
        escape(view);
        return TRUE;
    }
    if (view->holding) {
        g_queue_push_tail(&view->held, gdk_event_copy((GdkEvent *) event));
        return TRUE;
    }
    /* A command can move the keyboard before a key's release: that
       release reaches neither the view nor Emacs, which never saw its
       press. */
    if (!press && !released(frame, event->hardware_keycode, view))
        return TRUE;
    portal_key answer = PORTAL_KEY_PASS;
    if (asked) {
        bool repeat = pressed(frame, event->hardware_keycode, view);
        answer = portal_input_key(target(view), chord, repeat, event->time);
        if (answer == PORTAL_KEY_OFFER && !view->class->offer)
            answer = PORTAL_KEY_PASS;
        if (answer == PORTAL_KEY_TAKE)
            return TRUE;
        if (answer == PORTAL_KEY_HOLD || answer == PORTAL_KEY_OFFER) {
            /* A view that keeps a trigger and holds nothing, once its
               events were replayed, drops a press the core says to hold. */
            if (!view->trigger) {
                view->trigger = gdk_event_copy((GdkEvent *) event);
                view->trigger_repeat = repeat;
                view->holding = true;
                view->offering = answer == PORTAL_KEY_OFFER;
                if (view->offering)
                    view->class->offer(view->content, event);
            }
            return TRUE;
        }
    }
    /* As it would go without Portal: to the view, if it has the keyboard
       still, which the core may have just returned to Emacs. */
    if (frame->keyboard != view)
        return FALSE;
    deliver(view, event);
    return TRUE;
}

/* Deliver the events VIEW held, in order, as if they had just happened:
   each goes through window_keyed again.  If one of them starts a new hold,
   those after it join that. */
static gboolean replay(gpointer data)
{
    struct portal_view *view = data;
    GQueue events = view->held;
    g_queue_init(&view->held);
    view->replay = 0;
    view->holding = false;
    for (GdkEvent *event; (event = g_queue_pop_head(&events));) {
        gtk_main_do_event(event);
        gdk_event_free(event);
    }
    return G_SOURCE_REMOVE;
}

/* Stop holding VIEW's events and deliver them, ahead of any new one: from
   the main loop, before GDK's own source, which has the new ones, and
   holding meanwhile. */
static void release(struct portal_view *view)
{
    if (view->holding && !view->replay)
        view->replay = g_idle_add_full(G_PRIORITY_HIGH, replay, view, NULL);
}

void portal_linux_input_settle(struct portal_view *view, bool used)
{
    if (!view->offering)
        return;
    view->offering = false;
    /* The press is the view's trigger now, and what follows stays held. */
    if (!used
        && portal_input_unused(target(view), chord_of(&view->trigger->key), view->trigger_repeat)
               == PORTAL_KEY_HOLD)
        return;
    gdk_event_free(view->trigger);
    view->trigger = NULL;
    release(view);
}

/* The window. */

/* FRAME's window is about to lose the keyboard: GTK's own handler runs
   after this one.  Emacs's widget takes GTK's focus first, so that it is
   the one to lose it, and Emacs hears. */
static gboolean window_unfocused(GtkWidget *window, GdkEventFocus *event, gpointer data)
{
    (void) window, (void) event;
    struct portal_frame *frame = data;
    if (frame->keyboard)
        move_focus(frame, frame->fixed);
    return FALSE;
}

/* FRAME's window has the keyboard again, and GTK has given it to Emacs's
   widget: the view that had it takes it back. */
static gboolean window_focused(GtkWidget *window, GdkEventFocus *event, gpointer data)
{
    (void) window, (void) event;
    struct portal_frame *frame = data;
    if (frame->keyboard)
        move_focus(frame, frame->keyboard->widget);
    return FALSE;
}

/* An event Emacs's own widget got.  A click there, outside every view,
   gives Emacs the keyboard, which GTK leaves where it is. */
static void emacs_event(GtkWidget *fixed, GdkEvent *event, gpointer data)
{
    (void) fixed;
    struct portal_frame *frame = data;
    if (event->type == GDK_BUTTON_PRESS && frame->keyboard)
        take(frame->keyboard);
}

void portal_linux_input_watch(struct portal_frame *frame)
{
    g_signal_connect(frame->window, "key-press-event", G_CALLBACK(window_keyed), frame);
    g_signal_connect(frame->window, "key-release-event", G_CALLBACK(window_keyed), frame);
    g_signal_connect(frame->window, "focus-out-event", G_CALLBACK(window_unfocused), frame);
    g_signal_connect_after(frame->window, "focus-in-event", G_CALLBACK(window_focused), frame);
    g_signal_connect(frame->fixed, "event-after", G_CALLBACK(emacs_event), frame);
}

void portal_linux_input_unwatch(struct portal_frame *frame)
{
    g_signal_handlers_disconnect_by_data(frame->fixed, frame);
}

/* The primitives of portal.h. */

bool portal_view_focus(portal_view *view, portal_text *error)
{
    (void) error;
    if (view->frame && view->attached)
        give(view);
    return true;
}

bool portal_view_unfocus(portal_view *view, portal_text *error)
{
    (void) error;
    take(view);
    return true;
}

bool portal_view_replay(portal_view *view, bool again, portal_text *error)
{
    (void) error;
    if (again)
        release(view);
    else
        discard(view);
    return true;
}

bool portal_view_literal(portal_view *view, portal_text *error)
{
    if (!view->trigger)
        return portal_linux_fail(error, "No captured prefix key to send");
    /* A press and its release, to where the view's keys go. */
    GdkEvent *up = gdk_event_copy(view->trigger);
    up->type = GDK_KEY_RELEASE;
    deliver(view, &view->trigger->key);
    deliver(view, &up->key);
    gdk_event_free(up);
    return true;
}

bool portal_view_copy(portal_view *view, portal_text *error)
{
    (void) error;
    view->class->copy(view->content);
    return true;
}

static void pasted(GtkClipboard *clipboard, const gchar *text, gpointer data)
{
    (void) clipboard;
    /* The clipboard's owner answers later, and the view may have ended. */
    struct portal_view *view = portal_linux_view_find(*(uint64_t *) data);
    g_free(data);
    if (text && view)
        view->class->paste(view->content, text);
}

bool portal_view_paste(portal_view *view, portal_text *error)
{
    (void) error;
    gtk_clipboard_request_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), pasted,
                               portal_linux_serial(view->serial));
    return true;
}
