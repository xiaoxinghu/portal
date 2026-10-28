/* SPDX-License-Identifier: GPL-3.0-or-later */
/* System-wide shortcuts, as the Emacs bindings use them, and chords posted
   to the frontmost application.  shortcuts.c implements these with the hot
   key and key post primitives of portal.h.  Only the core,
   tests and the standalone checks include this header.

   A chord is written as hyphen-separated modifiers, Control, Option, Command
   and Shift, each at most once, then a key: A to Z, 0 to 9, Space, Escape or
   F1 to F20, such as Control-Option-Command-P.  The modifiers include one of
   the first three, except that a chord posted to an application may be
   Escape alone.  Case does not matter.  Letters and digits are positions on
   a US keyboard.

   Each registration has an ID that no other registration, earlier or later,
   ever has, and every successful set gives it a new one.  A press of its
   chord sends Emacs the record "shortcut ID"; holding the chord sends one. */
#ifndef PORTAL_SHORTCUTS_H
#define PORTAL_SHORTCUTS_H

#include "portal.h"

/* CHORD as the core writes it: Control, Option, Shift and Command in that
   order, then the key, as in Control-Option-Shift-Command-P or Control-F12
   or Command-Space.  Fails for a chord that is not written as above. */
bool portal_shortcuts_chord(portal_string chord, portal_text *normalized, portal_text *error);

/* Register CHORD and set *ID to the registration's new ID.  REPLACING is
   the ID of the registration this replaces, or 0 for none; once this
   succeeds, its old chord is released, or for the same chord, restarted.
   On failure nothing changes: CHORD is invalid or another registration's,
   REPLACING names no registration, or the platform refuses the chord. */
bool portal_shortcuts_set(uint64_t replacing, portal_string chord, uint64_t *id,
                          portal_text *error);

/* Release the registration ID.  An unknown ID is already released.  If the
   platform cannot release its chord, the registration stays. */
bool portal_shortcuts_remove(uint64_t id, portal_text *error);

/* The registrations, oldest first, as a JSON array of objects with the
   members "id", "chord", as portal_shortcuts_chord writes it, "hotkey", the
   platform's name for it, and "held". */
bool portal_shortcuts_describe(portal_text *json, portal_text *error);

/* Press and release CHORD, written as above, in the frontmost application,
   with portal_key_post: its letters and digits name the characters the
   current keyboard layout types, not US key positions.  Fails, posting
   nothing, for a chord that is not written as above, or when the platform
   cannot post it. */
bool portal_shortcuts_post(portal_string chord, portal_text *error);

#endif
