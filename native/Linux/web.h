/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Between portal.so and portal-web.so, the page.

   A page is WPE WebKit's, which a system may not have: portal.so links
   nothing of it, so that it loads and runs terminals where WPE WebKit is
   not installed.  The page is a second object, portal-web.so, built beside
   portal.so where WPE WebKit's development files are, linked to WPE
   WebKit, and opened by portal.so at the first web view (backend.c).  It
   exports one function, portal_web_object_open, which takes what it calls
   in portal.so and returns what portal.so calls in it.  Both are built
   from one tree, and the interface's number keeps an object of another
   build from being used. */
#ifndef PORTAL_LINUX_WEB_H
#define PORTAL_LINUX_WEB_H

#include "linux.h"

enum { PORTAL_WEB_INTERFACE = 1 };

/* What the page calls in portal.so: linux.h's functions of those names. */
struct portal_web_host {
    int interface;
    bool (*fail)(portal_text *error, const char *message);
    struct portal_view *(*view_find)(uint64_t serial);
    void (*input_settle)(struct portal_view *view, bool used);
    void (*input_cursor)(struct portal_view *view, const char *name);
    struct portal_stage *(*stage_new)(struct portal_view *view,
                                      const struct portal_stage_source *source);
    void (*stage_ready)(void *data);
    bool (*stage_start)(struct portal_stage *stage, void *data, portal_text *error);
    void (*stage_configure)(struct portal_stage *stage, bool shown);
    void (*stage_frame)(struct portal_stage *stage);
    void (*stage_stop)(struct portal_stage *stage);
    void (*stage_free)(struct portal_stage *stage);
    void (*stage_describe)(struct portal_stage *stage, struct json *description);
    /* portal.h's calls into the core of those names, on the module thread. */
    void (*committed)(portal_string target, portal_string url);
    void (*failed)(portal_string target, uint64_t token, portal_string message);
};

/* What portal.so calls in the page, on the module thread. */
struct portal_web_object {
    int interface;
    /* Make a page, the content of VIEW, a new web view, from OPTIONS. */
    bool (*create)(struct portal_view *view, const portal_option *options, size_t count,
                   portal_text *error);
    /* Whether VIEW's content is a page, and not a test pattern. */
    bool (*is_page)(const struct portal_view *view);
    /* portal.h's primitives of those names, for a VIEW that is a page. */
    bool (*load)(struct portal_view *view, portal_string url, portal_text *error);
    bool (*go)(struct portal_view *view, portal_history step, portal_text *error);
};

/* Start the page's side with HOST, which stays as long as the process, and
   return what it offers; or NULL with *ERROR set, a message in memory of
   malloc's.  Called once. */
typedef const struct portal_web_object *portal_web_object_open_function(
    const struct portal_web_host *host, char **error);
portal_web_object_open_function portal_web_object_open;

#endif
