/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Portal views, as the Emacs bindings use them.  views.c implements these
   and, for the platform, portal_notify from portal.h.  Only emacs.c, tests
   and the standalone checks include this header.

   A view's target, such as "web:3", is its kind and an ID.  IDs are global
   across kinds and never reused, even after a failed open, so a stale target
   can never reach a newer view.  An operation on a target that names no open
   view fails with "No Portal view TARGET" and reaches no platform view. */
#ifndef PORTAL_VIEWS_H
#define PORTAL_VIEWS_H

#include "input.h"
#include "portal.h"

/* A pane's pixel edges in its frame, as `window-inside-pixel-edges'. */
typedef struct portal_edges {
    int64_t left, top, right, bottom;
} portal_edges;

/* Open a view of KIND, "web" or "terminal", and return its new target.  On
   failure nothing is registered, and the platform has released what it made. */
bool portal_views_open(portal_string kind, const portal_option *options, size_t count,
                       portal_text *target, portal_text *error);
/* Attach TARGET's view at EDGES in the frame titled TITLE.  Placing an
   attached view again moves the same platform view.  On failure the view
   stays where it was, attached or not, and still open. */
bool portal_views_place(portal_string target, portal_edges edges, portal_string title,
                        portal_text *error);
/* Detach TARGET's view if it is attached, keeping its page or session, and
   end its handoff.  If the platform refuses, the view stays
   attached. */
bool portal_views_hide(portal_string target, portal_text *error);
/* Close TARGET, ending its handoff and destroying its platform view once.
   The target is gone before the platform hears of it, so nothing the
   platform does meanwhile can reach it.  If the platform refuses, the view
   stays open. */
bool portal_views_close(portal_string target, portal_text *error);
/* TARGET's state as a JSON object, or null for a target that names no open
   view: the platform's description, with "id", "kind", "visible" and
   "edges" ([] while hidden) from the core. */
bool portal_views_inspect(portal_string target, portal_text *state, portal_text *error);

/* Any kind, for portal_views_find. */
enum { PORTAL_ANY_KIND = -1 };

/* TARGET's platform view, if TARGET names an open view of KIND, a
   portal_kind or PORTAL_ANY_KIND.  Otherwise return NULL and, unless ERROR
   is NULL, set it to "No Portal view TARGET".  The view is valid until the
   next lifecycle call. */
portal_view *portal_views_find(portal_string target, int kind, portal_text *error);

/* Send the record "TYPE TARGET" if TARGET names an open view of KIND, unless
   the last one this sent for the view is still waiting for Emacs to inspect
   it: inspecting the view lets the next go. */
void portal_views_announce(portal_string target, portal_kind kind, const char *type);

/* TARGET's input, if TARGET names an open view; valid until it closes. */
struct portal_input *portal_views_input(portal_string target);

/* Call VISIT with each open view of KIND, oldest first, until it returns
   false; return whether every call returned true.  VISIT may call platform
   primitives but must not open or close views. */
bool portal_views_each(portal_kind kind, bool (*visit)(portal_view *view, void *context),
                       void *context);

#endif
