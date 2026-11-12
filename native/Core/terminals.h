/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Terminal views, as the Emacs bindings use them.  terminals.c implements
   these with the terminal primitives of portal.h.  Only the core, tests and
   the standalone checks include this header.

   A TARGET that names no open terminal fails with "No Portal view TARGET",
   as in views.h, and reaches no platform view. */
#ifndef PORTAL_TERMINALS_H
#define PORTAL_TERMINALS_H

#include "portal.h"

/* Check a terminal's OPTIONS before the platform creates it: :directory must
   be a string, unless :fed is non-nil; :command, :argv and :theme a string
   or nil; :command and :argv mutually exclusive, and neither with :fed;
   :theme a name the platform lists; and :points nil or a number, which may
   be out of range: the platform clamps it with portal_terminal_points.  A
   later duplicate option wins, and other options pass. */
bool portal_terminals_check(const portal_option *options, size_t count, portal_text *error);

/* Whether OPTIONS make a fed terminal (portal.h): :fed, non-nil.  Rex
   shows its blocks in fed terminals (rex.h). */
bool portal_terminals_fed(const portal_option *options, size_t count);

/* The platform's theme names as a sorted JSON array of strings. */
bool portal_terminals_themes(portal_text *json, portal_text *error);

/* Apply the theme NAME, or the default for a null NAME, to every open
   terminal, oldest first.  An unknown NAME changes none.  If a terminal
   rejects the theme, the error is its own, the terminals before it keep the
   new theme, and it and those after it keep their old one. */
bool portal_terminals_theme(const portal_string *name, portal_text *error);

/* Show TARGET's text at POINTS, clamped with portal_terminal_points.  Other
   terminals keep their size. */
bool portal_terminals_text_size(portal_string target, double points, portal_text *error);

/* Paste TEXT into TARGET, then press Enter as a separate key if ENTER.  If
   the paste fails, Enter is not pressed. */
bool portal_terminals_paste(portal_string target, portal_string text, bool enter,
                            portal_text *error);

/* All of TARGET's text: scrollback and screen. */
bool portal_terminals_text(portal_string target, portal_text *text, portal_text *error);

#endif
