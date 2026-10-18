/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Input handoff, as the rest of the core uses it.  input.c implements these
   and, for the platform, portal_input_key and portal_input_focus from
   portal.h.  Only the core, tests and the standalone checks include this
   header.

   A view's app gets the keys typed in it, except the first chord of a
   terminal's native binding and a chord the app does not use (input.c has
   the order).  Either starts a handoff: Emacs reads the rest of a key
   sequence and runs its command, then usually gives the view the keyboard
   back (portal-input.el).  Each handoff has a serial, never reused, and
   Emacs names it in every action it takes, so a late action for an
   abandoned or finished handoff does nothing. */
#ifndef PORTAL_INPUT_H
#define PORTAL_INPUT_H

#include "portal.h"

/* Where a view's handoff is.  Emacs owns the keyboard in every state but
   IDLE, from the key press that starts the handoff. */
enum portal_handoff {
    PORTAL_IDLE,
    /* The platform holds the trigger and every key event after it, until
       Emacs acknowledges the handoff's record. */
    PORTAL_AWAITING,
    /* Emacs reads the rest of the key sequence.  After a native binding's
       trigger, its first key, if it is the trigger again, sends the trigger
       to the app instead; C-g cancels. */
    PORTAL_READING,
    /* Emacs runs the command. */
    PORTAL_EXECUTING,
};

/* A view's input, which the view registry keeps with the view from open to
   close. */
struct portal_input {
    portal_view *view;
    portal_string target; /* The registry's copy. */
    portal_kind kind;
    /* Web views have no native bindings, and quick terminals the quick ones. */
    enum { PORTAL_NO_BINDINGS, PORTAL_REGULAR_BINDINGS, PORTAL_QUICK_BINDINGS } bindings;
    enum portal_handoff handoff;
    int64_t serial;       /* The latest handoff's. */
    portal_chord trigger; /* The key that started it, normalized. */
    bool binding;         /* It started with a native binding's chord. */
    bool first;           /* Reading: no key of the sequence yet. */
    bool focused;         /* As the platform last reported. */
};

/* Set up the input of a new view of KIND, created with OPTIONS. */
void portal_input_open(struct portal_input *input, portal_view *view, portal_string target,
                       portal_kind kind, const portal_option *options, size_t count);
/* End INPUT's handoff, without a record, before its view is hidden or
   closed.  Any later action for the handoff does nothing. */
bool portal_input_close(struct portal_input *input, portal_text *error);

/* A native terminal binding: a first chord, and the Lisp event its record
   carries. */
typedef struct portal_binding {
    portal_chord chord;
    int64_t event;
} portal_binding;

/* Replace both binding profiles: the regular one for every terminal, and the
   quick one for quick terminals.  Each chord is modified ASCII, other than
   the profile's other chords, and each event positive.  On failure nothing
   changes. */
bool portal_input_bindings(const portal_binding *regular, size_t regular_count,
                           const portal_binding *quick, size_t quick_count,
                           portal_text *error);

/* Set the reserved return-to-Emacs chord, initially Super-period. Accept one
   printable ASCII character or Escape (27), with Control, Meta or Super.
   Invalid chords leave the previous choice intact. */
bool portal_input_set_escape(portal_chord chord, portal_text *error);

/* Perform ACTION on TARGET's input, as portal--input does, and set *RESULT.
   A nonzero SERIAL must name TARGET's handoff, still going, or nothing
   happens.  A TARGET that names no open view does nothing either. */
bool portal_input_perform(portal_string target, portal_string action, int64_t serial,
                          bool *result, portal_text *error);

/* The user handed something in TARGET's view to Emacs, such as a hosted app's
   link to a local file: return the keyboard to Emacs, as the platform's own
   way back does (portal_input_focus).  A handoff ends with its "escape"
   record first, so Emacs stops reading its key sequence before any record
   the caller sends next.  A TARGET that names no open view does nothing. */
void portal_input_escape(portal_string target);

/* Who has a view's keyboard: Emacs, the view, or Emacs handling the view's
   handoff. */
typedef enum portal_owner {
    PORTAL_OWNER_EMACS,
    PORTAL_OWNER_VIEW,
    PORTAL_OWNER_PENDING,
} portal_owner;

/* Who has TARGET's keyboard; Emacs for a TARGET that names no open view. */
portal_owner portal_input_owner(portal_string target);

/* Emacs calls the module, from true until false; calls nest.  A focus change
   the platform reports meanwhile is Emacs's doing, not the user's, so it
   never abandons a handoff. */
void portal_input_request(bool requesting);

#endif
