/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's notification pipe, native/Core/channel.c, with real POSIX pipes
   and the fake platform's timers, which fire only when a test fires them.
   The write seam stands in for write(2) only to interrupt or shorten writes. */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "portal-fake-backend.h"
#include "portal.h"

static int failures;
/* How many checks ran: the program ends by printing it. */
static int checks;

#define CHECK(condition) check((condition), #condition, __LINE__)

static void check(bool passed, const char *condition, int line)
{
    checks++;
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
}

/* Send the record TYPE TARGET, followed by the NULL-terminated fields. */
static bool notify(const char *type, const char *target, ...)
{
    portal_string fields[8];
    size_t count = 0;
    va_list arguments;
    va_start(arguments, target);
    for (const char *field; (field = va_arg(arguments, const char *));)
        fields[count++] = (portal_string) {field, strlen(field)};
    va_end(arguments);
    return portal_channel_send((portal_string) {type, strlen(type)},
                         (portal_string) {target, strlen(target)}, fields, count);
}

/* A pipe standing in for Emacs's: the test reads, and the core owns the write
   end once connected. */
struct pipe {
    int read, write;
};

static struct pipe open_pipe(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    return (struct pipe) {fds[0], fds[1]};
}

/* Fill the pipe, as an Emacs busy with a long command leaves it; return how
   many bytes that took. */
static size_t fill(struct pipe pipe)
{
    char filler[512];
    memset(filler, '.', sizeof filler);
    size_t filled = 0;
    int status = fcntl(pipe.write, F_GETFL);
    fcntl(pipe.write, F_SETFL, status | O_NONBLOCK);
    for (size_t size = sizeof filler; size; size /= 2)
        for (ssize_t count; (count = write(pipe.write, filler, size)) > 0;)
            filled += (size_t) count;
    return filled;
}

/* Everything the pipe holds now, after SKIP bytes, as a string to free. */
static char *take(struct pipe pipe, size_t skip)
{
    size_t length = 0, capacity = 1024;
    char *text = malloc(capacity);
    for (ssize_t count; (count = read(pipe.read, text + length, capacity - length - 1)) > 0;) {
        length += (size_t) count;
        if (capacity - length < 512)
            text = realloc(text, capacity *= 2);
    }
    text[length] = '\0';
    skip = skip < length ? skip : length;
    memmove(text, text + skip, length - skip + 1);
    return text;
}

static bool took(struct pipe pipe, size_t skip, const char *expected)
{
    char *text = take(pipe, skip);
    bool same = !strcmp(text, expected);
    if (!same)
        fprintf(stderr, "Expected \"%s\", got \"%s\"\n", expected, text);
    free(text);
    return same;
}

static bool closed(int fd)
{
    return fcntl(fd, F_GETFD) == -1 && errno == EBADF;
}

/* Disconnect and let stale timers fire, so each test starts clean. */
static void settle(void)
{
    portal_channel_connect(-1);
    while (portal_fake_timers())
        portal_fake_fire_timers();
}

/* The write seam: interrupt the next INTERRUPTIONS writes, then write at most
   LIMIT bytes once, then fail with EAGAIN once if BLOCK. */
static struct seam {
    int calls, interruptions;
    size_t limit;
    bool block;
} seam;

static ssize_t seam_write(int fd, const void *bytes, size_t length)
{
    seam.calls++;
    if (seam.interruptions) {
        seam.interruptions--;
        errno = EINTR;
        return -1;
    }
    if (seam.limit && length > seam.limit) {
        length = seam.limit;
        seam.limit = 0;
    } else if (seam.block) {
        seam.block = false;
        errno = EAGAIN;
        return -1;
    }
    return write(fd, bytes, length);
}

static void use_seam(void)
{
    seam = (struct seam) {0};
    portal_channel_write = seam_write;
}

static void test_rejects_malformed_and_oversized_records(void)
{
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    CHECK(!notify("two words", "web:1", NULL));
    CHECK(!notify("", "web:1", NULL));
    CHECK(!notify("escape", "", NULL));
    CHECK(!notify("escape", "web:1", "2", "", NULL));
    CHECK(!notify("escape", "web:1", "tab\there", NULL));
    CHECK(!notify("escape", "web:1", "line\n", NULL));
    CHECK(!notify("r\xc3\xa9sum\xc3\xa9", "web:1", NULL));
    CHECK(!notify("delete\x7f", "web:1", NULL));
    portal_string nul = {"a\0b", 3};
    CHECK(!portal_channel_send(nul, nul, NULL, 0));
    CHECK(!portal_channel_send(nul, nul, NULL, (size_t) -1));

    /* A record fills PIPE_BUF exactly, newline included, and no more. */
    char type[PIPE_BUF];
    memset(type, 't', sizeof type);
    portal_string target = {"web:1", 5};
    CHECK(!portal_channel_send((portal_string) {type, PIPE_BUF - 6}, target, NULL, 0));
    CHECK(!portal_channel_send((portal_string) {type, PIPE_BUF}, target, NULL, 0));
    CHECK(portal_channel_send((portal_string) {type, PIPE_BUF - 7}, target, NULL, 0));
    char expected[PIPE_BUF + 1];
    memcpy(expected, type, PIPE_BUF - 7);
    memcpy(expected + PIPE_BUF - 7, " web:1\n", 8);
    CHECK(took(pipe, 0, expected));
    CHECK(!portal_fake_timers());
    settle();
    close(pipe.read);
}

static void test_full_pipe_delivers_in_order(void)
{
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    size_t filled = fill(pipe);
    CHECK(filled > 0);
    char expected[4096] = "";
    for (int i = 0; i < 40; i++) {
        char serial[16], line[64];
        snprintf(serial, sizeof serial, "%d", i);
        static const char *const types[] = {"key", "binding", "literal", "cancel",
                                            "escape", "bridge", "select"};
        const char *type = types[i % 7];
        bool fields = strcmp(type, "bridge") && strcmp(type, "select");
        CHECK(fields ? notify(type, "terminal:2", serial, "0", NULL) : notify(type, "web:3", NULL));
        snprintf(line, sizeof line, fields ? "%s terminal:2 %s 0\n" : "%s web:3\n", type, serial);
        strcat(expected, line);
    }
    /* One retry is pending, however many records wait. */
    CHECK(portal_fake_timers() == 1);

    /* Emacs reads a little at a time; each retry sends what fits. */
    size_t length = 0, retries = 0, capacity = filled + sizeof expected;
    char *received = malloc(capacity);
    while (portal_fake_timers() && retries++ < 1000) {
        ssize_t count = read(pipe.read, received + length, 97);
        length += count > 0 ? (size_t) count : 0;
        portal_fake_fire_timers();
    }
    for (ssize_t count; (count = read(pipe.read, received + length, capacity - length - 1)) > 0;)
        length += (size_t) count;
    received[length] = '\0';
    CHECK(retries > 2);
    CHECK(length > filled && !strcmp(received + filled, expected));
    free(received);
    settle();
    close(pipe.read);
}

static void test_records_wait_while_disconnected(void)
{
    settle();
    CHECK(notify("escape", "web:1", "4", "0", NULL));
    CHECK(notify("bridge", "web:1", NULL));
    CHECK(!portal_fake_timers());
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    CHECK(took(pipe, 0, "escape web:1 4 0\nbridge web:1\n"));
    settle();
    close(pipe.read);
}

static void test_waiting_records_move_to_a_new_pipe(void)
{
    struct pipe old = open_pipe(), new = open_pipe();
    CHECK(portal_channel_connect(old.write));
    size_t filled = fill(old);
    CHECK(notify("escape", "web:1", "3", "0", NULL));
    CHECK(notify("bridge", "web:1", NULL));
    CHECK(portal_fake_timers() == 1);
    CHECK(portal_channel_connect(new.write));
    CHECK(closed(old.write));
    CHECK(took(new, 0, "escape web:1 3 0\nbridge web:1\n"));
    /* The old reader gets its filler, then end of file: nothing else wrote. */
    CHECK(took(old, filled, ""));
    char byte;
    CHECK(read(old.read, &byte, 1) == 0);
    /* The old pipe's retry was cancelled; firing it sends nothing twice. */
    portal_fake_fire_timers();
    CHECK(took(new, 0, ""));
    settle();
    close(old.read);
    close(new.read);
}

static void test_reconnecting_cancels_the_retry(void)
{
    struct pipe first = open_pipe(), second = open_pipe();
    CHECK(portal_channel_connect(first.write));
    fill(first);
    CHECK(notify("key", "web:1", "5", "0", NULL));
    CHECK(portal_fake_timers() == 1);
    /* The second pipe is full too, so it needs a retry of its own. */
    size_t filled = fill(second);
    CHECK(portal_channel_connect(second.write));
    CHECK(portal_fake_timers() == 2);
    /* While the pipe stays full, the cancelled timer starts no retry. */
    portal_fake_fire_timers();
    CHECK(portal_fake_timers() == 1);
    use_seam();
    CHECK(took(second, filled, ""));
    portal_fake_fire_timers();
    CHECK(seam.calls == 1);
    CHECK(took(second, 0, "key web:1 5 0\n"));
    CHECK(!portal_fake_timers());

    /* Disconnecting cancels a retry too: its timer writes nothing. */
    fill(second);
    CHECK(notify("cancel", "web:1", "5", "0", NULL));
    CHECK(portal_fake_timers() == 1);
    CHECK(portal_channel_connect(-1));
    seam.calls = 0;
    portal_fake_fire_timers();
    CHECK(seam.calls == 0 && !portal_fake_timers());
    struct pipe third = open_pipe();
    CHECK(portal_channel_connect(third.write));
    CHECK(took(third, 0, "cancel web:1 5 0\n"));
    portal_channel_write = write;
    settle();
    close(first.read);
    close(second.read);
    close(third.read);
}

static void test_interrupted_and_short_writes(void)
{
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    use_seam();
    seam.interruptions = 2;
    CHECK(notify("select", "web:1", NULL));
    CHECK(seam.calls == 3);
    CHECK(took(pipe, 0, "select web:1\n"));

    /* A short write resumes where it stopped, now or after a retry. */
    seam = (struct seam) {.limit = 3};
    CHECK(notify("bridge", "web:2", NULL));
    CHECK(took(pipe, 0, "bridge web:2\n"));
    seam = (struct seam) {.limit = 3, .block = true};
    CHECK(notify("bridge", "web:3", NULL));
    CHECK(took(pipe, 0, "bri"));
    CHECK(portal_fake_timers() == 1);
    seam.interruptions = 1;
    portal_fake_fire_timers();
    CHECK(took(pipe, 0, "dge web:3\n"));

    /* A new pipe gets the whole record that the old one got part of. */
    seam = (struct seam) {.limit = 3, .block = true};
    CHECK(notify("bridge", "web:4", NULL));
    CHECK(took(pipe, 0, "bri"));
    struct pipe next = open_pipe();
    CHECK(portal_channel_connect(next.write));
    CHECK(took(next, 0, "bridge web:4\n"));
    portal_channel_write = write;
    settle();
    close(pipe.read);
    close(next.read);
}

static void test_a_closed_reader_raises_no_sigpipe(void)
{
    /* SIGPIPE's default action ends the process, as it would end Emacs. */
    signal(SIGPIPE, SIG_DFL);
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    close(pipe.read);
    CHECK(notify("escape", "web:1", "6", "0", NULL));
    CHECK(notify("bridge", "web:1", NULL));
    /* Retrying cannot help; the records wait for Emacs to connect a pipe. */
    CHECK(!portal_fake_timers());
    struct pipe next = open_pipe();
    CHECK(portal_channel_connect(next.write));
    CHECK(closed(pipe.write));
    CHECK(took(next, 0, "escape web:1 6 0\nbridge web:1\n"));
    /* The writes left the thread's signal mask as it was. */
    sigset_t mask;
    CHECK(!pthread_sigmask(SIG_SETMASK, NULL, &mask) && !sigismember(&mask, SIGPIPE));
    settle();
    close(next.read);
}

/* A SIGPIPE pending before a write was not the pipe's: a platform that takes
   the pipe's own, for lack of a descriptor that raises none, leaves it. */
static void test_a_pending_sigpipe_stays(void)
{
    sigset_t sigpipe, mask, pending;
    sigemptyset(&sigpipe);
    sigaddset(&sigpipe, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &sigpipe, &mask);
    raise(SIGPIPE);
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    close(pipe.read);
    CHECK(notify("select", "web:1", NULL));
    CHECK(!sigpending(&pending) && sigismember(&pending, SIGPIPE));
    /* Ignoring a pending signal discards it, so unblocking delivers none. */
    signal(SIGPIPE, SIG_IGN);
    pthread_sigmask(SIG_SETMASK, &mask, NULL);
    signal(SIGPIPE, SIG_DFL);
    struct pipe next = open_pipe();
    CHECK(portal_channel_connect(next.write));
    CHECK(took(next, 0, "select web:1\n"));
    settle();
    close(next.read);
}

static void test_descriptor_ownership(void)
{
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    CHECK(fcntl(pipe.write, F_GETFL) & O_NONBLOCK);
    CHECK(fcntl(pipe.write, F_GETFD) & FD_CLOEXEC);
    /* Connecting the same descriptor again keeps it. */
    CHECK(portal_channel_connect(pipe.write));
    CHECK(!closed(pipe.write));
    /* A descriptor that cannot be prepared stays the caller's, and the pipe
       already connected stays connected. */
    int spare = dup(pipe.read);
    close(spare);
    errno = 0;
    CHECK(!portal_channel_connect(spare));
    CHECK(errno == EBADF);
    CHECK(notify("select", "web:1", NULL));
    CHECK(took(pipe, 0, "select web:1\n"));
    /* Disconnecting closes it, once. */
    CHECK(portal_channel_connect(-1));
    CHECK(closed(pipe.write));
    CHECK(portal_channel_connect(-1));
    settle();
    close(pipe.read);
}

static void test_launcher_without_views(void)
{
    CHECK(portal_channel_connect(-1));
    CHECK(portal_launcher_blurred(7));
    struct pipe pipe = open_pipe();
    CHECK(portal_channel_connect(pipe.write));
    CHECK(took(pipe, 0, "launcher-blur 7\n"));
    size_t filled = fill(pipe);
    CHECK(portal_launcher_blurred(UINT64_MAX));
    CHECK(notify("select", "web:1", NULL));
    CHECK(took(pipe, filled, ""));
    portal_fake_fire_timers();
    CHECK(took(pipe, 0, "launcher-blur 18446744073709551615\nselect web:1\n"));
    CHECK(portal_channel_connect(-1));
    close(pipe.read);
}

int main(void)
{
    test_rejects_malformed_and_oversized_records();
    test_full_pipe_delivers_in_order();
    test_records_wait_while_disconnected();
    test_waiting_records_move_to_a_new_pipe();
    test_reconnecting_cancels_the_retry();
    test_interrupted_and_short_writes();
    test_a_closed_reader_raises_no_sigpipe();
    test_a_pending_sigpipe_stays();
    test_descriptor_ownership();
    test_launcher_without_views();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("The notification pipe passed");
    printf("%d checks passed\n", checks);
    return 0;
}
