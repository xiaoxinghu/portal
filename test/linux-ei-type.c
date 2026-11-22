/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only: type TEXT, lowercase letters, then Return into the window
   with the keyboard on KDE Plasma, through KWin's EIS, for
   test/render-smoke.sh.  Usage: linux-ei-type TEXT

   KWin hands out an EIS socket to whoever asks on the session bus
   (org.kde.KWin.EIS.RemoteDesktop.connectToEIS), and a libei sender on
   it gets a keyboard that types as a person's does.  The keys are evdev
   codes, which KWin reads with its own keymap: a layout that does not put
   the letters where US English does types other letters.  Exits 0 once
   every key is sent, 1 when KWin refuses or offers no keyboard. */
#define _POSIX_C_SOURCE 200809L
#include <dbus/dbus.h>
#include <libei.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

enum { KEYBOARD = 1 };

static const int letters[26] = {
    KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M,
    KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T, KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z};

static void pause_ms(long ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000};
    nanosleep(&t, NULL);
}

/* KWin's EIS socket and the cookie that ends it, or false. */
static bool connect_eis(DBusConnection *bus, int *fd, dbus_int32_t *cookie)
{
    DBusError error;
    dbus_error_init(&error);
    DBusMessage *call = dbus_message_new_method_call("org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop",
                                                     "org.kde.KWin.EIS.RemoteDesktop", "connectToEIS");
    dbus_int32_t capabilities = KEYBOARD;
    dbus_message_append_args(call, DBUS_TYPE_INT32, &capabilities, DBUS_TYPE_INVALID);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(bus, call, 5000, &error);
    dbus_message_unref(call);
    bool ok = reply && dbus_message_get_args(reply, &error, DBUS_TYPE_UNIX_FD, fd, DBUS_TYPE_INT32,
                                             cookie, DBUS_TYPE_INVALID);
    if (!ok) fprintf(stderr, "linux-ei-type: KWin's connectToEIS: %s\n", error.message);
    if (reply) dbus_message_unref(reply);
    dbus_error_free(&error);
    return ok;
}

static void disconnect_eis(DBusConnection *bus, dbus_int32_t cookie)
{
    DBusMessage *call = dbus_message_new_method_call("org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop",
                                                     "org.kde.KWin.EIS.RemoteDesktop", "disconnect");
    dbus_message_append_args(call, DBUS_TYPE_INT32, &cookie, DBUS_TYPE_INVALID);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(bus, call, 2000, NULL);
    if (reply) dbus_message_unref(reply);
    dbus_message_unref(call);
}

/* The keyboard KWin offers on the socket, resumed, or NULL within 5 s. */
static struct ei_device *keyboard(struct ei *ei)
{
    struct ei_device *found = NULL;
    time_t deadline = time(NULL) + 5;
    while (!found && time(NULL) < deadline) {
        struct pollfd ready = {.fd = ei_get_fd(ei), .events = POLLIN};
        poll(&ready, 1, 100);
        ei_dispatch(ei);
        struct ei_event *event;
        while ((event = ei_get_event(ei))) {
            switch (ei_event_get_type(event)) {
            case EI_EVENT_SEAT_ADDED:
                ei_seat_bind_capabilities(ei_event_get_seat(event), EI_DEVICE_CAP_KEYBOARD, NULL);
                break;
            case EI_EVENT_DEVICE_RESUMED:
                if (!found && ei_device_has_capability(ei_event_get_device(event), EI_DEVICE_CAP_KEYBOARD))
                    found = ei_device_ref(ei_event_get_device(event));
                break;
            case EI_EVENT_DISCONNECT:
                fprintf(stderr, "linux-ei-type: KWin closed the EIS connection\n");
                ei_event_unref(event);
                return NULL;
            default:
                break;
            }
            ei_event_unref(event);
        }
    }
    if (!found) fprintf(stderr, "linux-ei-type: KWin offered no keyboard in 5 s\n");
    return found;
}

static void key(struct ei *ei, struct ei_device *device, int code)
{
    ei_device_keyboard_key(device, code, true);
    ei_device_frame(device, ei_now(ei));
    ei_device_keyboard_key(device, code, false);
    ei_device_frame(device, ei_now(ei));
    ei_dispatch(ei);
    pause_ms(10);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: linux-ei-type TEXT\n");
        return 2;
    }
    for (const char *c = argv[1]; *c; c++)
        if (*c < 'a' || *c > 'z') {
            fprintf(stderr, "linux-ei-type: types lowercase letters only\n");
            return 2;
        }
    DBusError error;
    dbus_error_init(&error);
    DBusConnection *bus = dbus_bus_get(DBUS_BUS_SESSION, &error);
    if (!bus) {
        fprintf(stderr, "linux-ei-type: no session bus: %s\n", error.message);
        return 1;
    }
    int fd;
    dbus_int32_t cookie;
    if (!connect_eis(bus, &fd, &cookie)) return 1;
    int status = 1;
    struct ei *ei = ei_new_sender(NULL);
    ei_configure_name(ei, "portal-render-smoke");
    if (ei_setup_backend_fd(ei, fd) < 0) {
        fprintf(stderr, "linux-ei-type: libei refused KWin's socket\n");
    } else {
        struct ei_device *device = keyboard(ei);
        if (device) {
            ei_device_start_emulating(device, 1);
            for (const char *c = argv[1]; *c; c++) key(ei, device, letters[*c - 'a']);
            key(ei, device, KEY_ENTER);
            ei_device_stop_emulating(device);
            ei_dispatch(ei);
            /* Let KWin read the last keys before the socket closes. */
            pause_ms(100);
            ei_device_unref(device);
            status = 0;
        }
    }
    ei_unref(ei);
    disconnect_eis(bus, cookie);
    dbus_connection_unref(bus);
    return status;
}
