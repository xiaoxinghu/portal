/* SPDX-License-Identifier: GPL-3.0-or-later */
/* What tests can do to test/portal-fake-backend.c beyond portal.h. */
#ifndef PORTAL_FAKE_BACKEND_H
#define PORTAL_FAKE_BACKEND_H

#include <stdbool.h>
#include <stddef.h>

#include "portal.h"

/* How many times the core called each view and web primitive, and some
   terminal primitives, and how many calls named a view after the core
   destroyed it, or a view of the wrong kind, which must never happen. */
struct portal_fake_calls {
    size_t created, destroyed, attached, detached, described, misused;
    size_t loaded, went, posted; /* Web pages loaded, history steps, and messages posted. */
    size_t focused, unfocused, replayed, discarded;
    size_t copied, pasted; /* Copy and Paste commands given to views' apps. */
    size_t listed, themed, entered; /* Theme lists, themes applied, and Enters tried. */
    size_t appeared; /* Web appearances set. */
    size_t found, zoomed; /* Finds started in pages, and web zooms set. */
    size_t printed;       /* Pages printed, to files or in the print panel. */
};
struct portal_fake_calls portal_fake_calls(void);

/* While REFUSE, every view, web, terminal, hot key and key post primitive
   fails without doing anything, as a platform does when called on the wrong
   thread. */
void portal_fake_refuse(bool refuse);

/* End TERMINAL's process, as when its shell exits: it describes itself as
   "exited", stays open, and reports the change with portal_terminal_changed. */
void portal_fake_exit(portal_view *terminal);
/* TERMINAL's program sets its TITLE and reports its DIRECTORY, as a real
   one does with escape sequences, and the fake reports the change. */
void portal_fake_report(portal_view *terminal, const char *title, const char *directory);

/* The registered hot keys, oldest first, such as "3:P+14 5:F12+2":
   each one's hot key, its key and its portal_modifier bits.  Valid until the
   next call. */
const char *portal_fake_hotkeys(void);
/* How many times a hot key was registered again with its own chord. */
size_t portal_fake_hotkey_restarts(void);
/* The chords posted to the frontmost application since the last call,
   oldest first, such as "V+8 F12+3": each one's key and its
   portal_modifier bits.  Valid until the next call. */
const char *portal_fake_posted(void);

/* How many timers portal_timer_start started that have not fired. */
size_t portal_fake_timers(void);
/* Fire those timers, oldest first.  Timers they start wait for the next call. */
void portal_fake_fire_timers(void);

/* A user presses CHORD, or it repeats, in the fake's one window.  It goes to
   the view holding a trigger or offering a press, if any, else the view with
   the keyboard, else Emacs, and the fake logs where it went. */
void portal_fake_press(portal_chord chord, bool repeat);
/* Let MILLISECONDS pass on the fake clock that times presses.  A replayed
   press keeps the time the user pressed it. */
void portal_fake_wait(uint64_t milliseconds);
/* The page of the view offering a press to it has handled the press: it
   USED it, or reports it unused to the core. */
void portal_fake_answer(bool used);
/* Run the event loop: deliver the presses the core replayed, in order. */
void portal_fake_run(void);
/* The user invokes the reserved return-to-Emacs escape. */
void portal_fake_escape(void);
/* The user clicks in TARGET's view, which sends a select record and gives it
   the keyboard.  False if TARGET names no attached view. */
bool portal_fake_click(const char *target);
/* Where each press went since the last call, such as "held s-x, emacs x":
   to Emacs, a view's app, by its target, held, taken, offered to its page,
   or its trigger delivered as a literal; and a page's answer, "used" or
   "unused", and what the core did with an unused press, such as "unused
   held s-x".  Valid until the next call. */
const char *portal_fake_keys(void);

/* Give portal_screens these COUNT screens, at most 4, primary first. */
void portal_fake_screens(const portal_screen *screens, size_t count);

/* The status panel as the platform last showed it, and how many times the
   core measured one. */
struct portal_fake_status {
    bool shown;
    char text[256];
    portal_status_tone tone;
    portal_rect rect;
    int64_t lines;
    size_t measured;
};
struct portal_fake_status portal_fake_status(void);

#endif
