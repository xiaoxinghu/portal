/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Web views, as the Emacs bindings and the view registry use them.  web.c
   implements these and, for the platform, the web calls into the core in
   portal.h.  Only the core, tests and the standalone checks include this
   header.

   A TARGET that names no open web view fails with "No Portal view TARGET",
   as in views.h, and reaches no platform view. */
#ifndef PORTAL_WEB_H
#define PORTAL_WEB_H

#include "portal.h"

/* Load URL in web view TARGET: reload its page if URL names the document on
   screen, ignoring fragments, and otherwise load a new document, except
   about:blank in a view that has shown nothing yet.  URL must be an absolute
   http, https, file, data or about URL.  On failure the view keeps the
   address it had. */
bool portal_web_views_load(portal_string target, portal_string url, portal_text *error);
/* Move web view TARGET through its history by STEP, "back" or "forward",
   as portal--web-go does; with no page to go to, nothing changes. */
bool portal_web_views_go(portal_string target, portal_string step, portal_text *error);
/* Check a web view's OPTIONS before the platform creates it: :appearance
   must be "light", "dark" or nil.  A later duplicate option wins, and other
   options pass. */
bool portal_web_views_check(const portal_option *options, size_t count, portal_text *error);
/* Show every open web view's pages in APPEARANCE, "light" or "dark", or the
   system's for a null APPEARANCE, oldest first.  Any other APPEARANCE
   changes none.  If a view fails, the error is its own, the views before it
   keep the new appearance, and it and those after it keep their old one. */
bool portal_web_views_appearance(const portal_string *appearance, portal_text *error);
/* Save web views' downloads in DIRECTORY, an absolute path, from now on. */
bool portal_web_views_download_directory(portal_string directory, portal_text *error);
/* Find TEXT, which must not be empty, in web view TARGET's page: the next
   match, or the previous one if BACKWARD, wrapping around, and ignoring
   case unless CASE_SENSITIVE.  The page highlights it.  When finding ends,
   Emacs gets the record "found TARGET 1", or "found TARGET 0" for no match,
   unless TARGET has started another find since: only the latest one
   reports. */
bool portal_web_views_find(portal_string target, portal_string text, bool backward,
                           bool case_sensitive, portal_text *error);
/* Show the pages from HOST at PERCENT of their size, from 25 to 500, in
   every web view from now on, oldest first: the pages on screen now and
   each page a view commits later.  HOST is spelled as the platform spells a
   page's URL, compared ignoring ASCII case; "" stands for every page without
   a host, such as a file.  A page whose host has no level shows at 100,
   and setting 100 forgets HOST's level.  If a view fails, the error is its
   own, and it and the views after it keep their size until their next
   page; the level stays set either way. */
bool portal_web_views_zoom(portal_string host, int64_t percent, portal_text *error);
/* Print web view TARGET's page, as a browser does: with a null FILE, in
   the system's print panel on the frame the view is attached to, which it
   must be; the user chooses a printer and settings, and prints or cancels.
   Otherwise print it to FILE, an absolute path, as a PDF, with no panel.
   When printing to a file ends, Emacs gets a "print" message on TARGET's
   bridge, as for downloads: its "state", "finished" or "failed", its
   "file", and for a failure the "message" saying why. */
bool portal_web_views_print(portal_string target, const portal_string *file, portal_text *error);
/* Pass the JSON object JSON to hosted web view TARGET's app over its bridge. */
bool portal_web_views_send(portal_string target, portal_string json, portal_text *error);
/* Return, as a JSON array, the messages waiting for Emacs on web view
   TARGET, oldest first; the next message sends a new bridge record.  Only a
   hosted app's page posts messages; every web view gets the core's own. */
bool portal_web_views_receive(portal_string target, portal_text *json, portal_text *error);

/* For the view registry, views.c: what the core keeps for one web view, its
   bridge and its pages. */
struct portal_web_state;

/* The state of a new web view opened with OPTIONS, which is hosted when its
   :hosted option is a string or t; NULL when out of memory. */
struct portal_web_state *portal_web_state_new(const portal_option *options, size_t count);
/* Whether STATE is a hosted app's. */
bool portal_web_state_hosted(const struct portal_web_state *state);
/* Free STATE and any messages still waiting in it. */
void portal_web_state_free(struct portal_web_state *state);

/* For web.c, from views.c: call VISIT with each open web view and its
   state, oldest first, until it returns false; return whether every call
   returned true.  VISIT may call platform primitives but must not open or
   close views. */
bool portal_views_each_web(bool (*visit)(portal_view *native, struct portal_web_state *state,
                                         void *context),
                           void *context);
/* For web.c, from views.c: TARGET's platform view, and its state in *STATE,
   if TARGET names an open web view.  Otherwise return NULL and, unless ERROR
   is NULL, set it to "No Portal view TARGET".  Both are valid until the next
   lifecycle call. */
portal_view *portal_views_find_web(portal_string target, struct portal_web_state **state,
                                   portal_text *error);
/* For web.c, from views.c: whether TARGET names an open view attached to a
   frame. */
bool portal_views_attached(portal_string target);
/* For web.c, from views.c: open a web view for the window the page in
   OPENER asked for with REQUEST, created with portal_web_create_window.
   Set *TARGET to its target, valid while it is open, and *STATE to its
   state.  False when the platform or memory fails, having opened nothing. */
bool portal_views_open_window(portal_view *opener, void *request, portal_string *target,
                              struct portal_web_state **state);

#endif
