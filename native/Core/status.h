/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The status panel, as the Emacs bindings use it: where it goes and how big
   it is, on the screen and panel primitives of portal.h.  status.c implements
   these.  Only the core, tests and the standalone checks include this
   header. */
#ifndef PORTAL_STATUS_H
#define PORTAL_STATUS_H

#include "portal.h"

/* Where the panel goes and how big it is, in logical points.

   POSITION anchors it to the usable area of a screen: "top-left", "top",
   "top-right", "left", "center", "right", "bottom-left", "bottom" or
   "bottom-right".  DX and DY move it from there: inward from each edge it is
   anchored to, and along an axis it is centered on, right or down.  The panel
   always stays inside the area.

   SCREEN is -1 for the screen under the pointer, which stays the panel's
   screen while it is shown, or an index into portal_screens, 0 for the
   primary screen; a missing screen falls back to the pointer's.

   WIDTH and HEIGHT fix the panel's size; 0 fits it to the text, between
   MIN_WIDTH and MAX_WIDTH when they are not 0.  The text wraps to at most
   LINES lines, at least 1, the last cut short if needed.  The area bounds
   every size. */
typedef struct portal_status_layout {
    portal_string position;
    int64_t screen;
    int64_t dx, dy;
    int64_t width, height, min_width, max_width;
    int64_t lines;
} portal_status_layout;

/* Show TEXT, which is not empty, with TONE, "neutral", "progress",
   "success", "warning" or "error", in the status panel laid out as LAYOUT
   says, replacing what it showed.  Fails, changing nothing, for an invalid
   argument, or when the platform cannot show it. */
bool portal_status_present(portal_string text, portal_string tone,
                           const portal_status_layout *layout, portal_text *error);

/* Hide the status panel; a hidden panel stays hidden. */
bool portal_status_dismiss(portal_text *error);

#endif
