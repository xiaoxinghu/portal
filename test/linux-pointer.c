/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A pointer for the Linux graphical checks: moves, clicks and scrolls
   through the compositor's virtual pointer (wlr-virtual-pointer-unstable-v1,
   test/fixtures), so that what a test does reaches the window under the
   pointer as a mouse's would, through the compositor and GDK.  It acts on
   the compositor WAYLAND_DISPLAY names, which test/linux-desktop.sh makes
   one of the test's own.  test/gui-ert.sh builds it.

     linux-pointer WIDTH HEIGHT ACTION...

   WIDTH and HEIGHT are the size of the desktop, in its own pixels, which a
   position is given in.  The actions, in order:

     move X Y       put the pointer at X, Y
     press [B]      press button B, by its Linux code: 272, the left, if left out
     release [B]    release it
     click [B]      press, wait 30 ms, release
     scroll STEPS   turn the wheel STEPS notches, down if positive
     wait MS        do nothing for MS milliseconds */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;

static void announce(void *data, struct wl_registry *registry, uint32_t name,
                     const char *interface, uint32_t version)
{
    (void) data, (void) version;
    if (!strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name))
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void withdraw(void *data, struct wl_registry *registry, uint32_t name)
{
    (void) data, (void) registry, (void) name;
}

static const struct wl_registry_listener listener = {announce, withdraw};

static uint32_t now(void)
{
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint32_t) (time.tv_sec * 1000 + time.tv_nsec / 1000000);
}

static void pause_for(long milliseconds)
{
    struct timespec time = {milliseconds / 1000, milliseconds % 1000 * 1000000};
    nanosleep(&time, NULL);
}

/* Whether the argument after ARGV[*INDEX] is a number, which is then *VALUE
   and consumed. */
static int number(int argc, char **argv, int *index, long *value)
{
    char *end;
    if (*index + 1 >= argc)
        return 0;
    long parsed = strtol(argv[*index + 1], &end, 10);
    if (end == argv[*index + 1] || *end)
        return 0;
    *value = parsed;
    ++*index;
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: linux-pointer WIDTH HEIGHT ACTION...\n");
        return 2;
    }
    uint32_t width = (uint32_t) atoi(argv[1]), height = (uint32_t) atoi(argv[2]);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "linux-pointer: no Wayland display\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!manager) {
        fprintf(stderr, "linux-pointer: the compositor has no virtual pointer\n");
        return 1;
    }
    struct zwlr_virtual_pointer_v1 *pointer =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
    for (int i = 3; i < argc; i++) {
        const char *action = argv[i];
        long first = 0, second = 0;
        if (!strcmp(action, "move") && number(argc, argv, &i, &first)
            && number(argc, argv, &i, &second)) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, now(), (uint32_t) first,
                                                    (uint32_t) second, width, height);
        } else if (!strcmp(action, "press") || !strcmp(action, "release")
                   || !strcmp(action, "click")) {
            uint32_t button = number(argc, argv, &i, &first) ? (uint32_t) first : 272;
            if (strcmp(action, "release")) {
                zwlr_virtual_pointer_v1_button(pointer, now(), button,
                                               WL_POINTER_BUTTON_STATE_PRESSED);
                zwlr_virtual_pointer_v1_frame(pointer);
                wl_display_roundtrip(display);
            }
            if (!strcmp(action, "click"))
                pause_for(30);
            if (strcmp(action, "press"))
                zwlr_virtual_pointer_v1_button(pointer, now(), button,
                                               WL_POINTER_BUTTON_STATE_RELEASED);
        } else if (!strcmp(action, "scroll") && number(argc, argv, &i, &first)) {
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, now(), WL_POINTER_AXIS_VERTICAL_SCROLL,
                                                  wl_fixed_from_int((int) first * 15),
                                                  (int32_t) first);
        } else if (!strcmp(action, "wait") && number(argc, argv, &i, &first)) {
            pause_for(first);
            continue;
        } else {
            fprintf(stderr, "linux-pointer: cannot %s\n", action);
            return 2;
        }
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
