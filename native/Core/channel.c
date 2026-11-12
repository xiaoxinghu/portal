/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The notification pipe: every record native code sends Emacs, as one ASCII
   line "TYPE TARGET FIELD...".  Records wait here, oldest first, while the
   pipe is full or disconnected, so a busy or reconnecting Emacs delays them
   but never loses or reorders them; input handoff and bridge announcements
   rely on that.  This file never sees emacs-module.h: records reach Emacs
   only through the pipe, whose reader runs them from Emacs's command loop. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE /* For F_SETNOSIGPIPE. */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "channel.h"
#include "rex.h"
#include "portal.h"

/* How long a full pipe waits before the next write. */
enum { RETRY_MILLISECONDS = 20 };

/* A record waiting for the pipe.  Waiting records form a list, so sending
   one never moves the rest. */
struct record {
    struct record *next;
    size_t length;
    char line[]; /* LENGTH bytes, ending in a newline. */
};

static struct {
    int fd;                      /* Owned, or -1 while disconnected. */
    struct record *first, *last; /* Waiting records, oldest first. */
    size_t sent;                 /* Bytes of FIRST already in the pipe. */
    uint64_t timer;              /* The pending retry's token, or 0. */
    uint64_t tokens;             /* The last timer token used. */
} channel = {.fd = -1};

ssize_t (*portal_channel_write)(int, const void *, size_t) = write;

/* POSIX descriptor handling.  File status flags such as O_NONBLOCK belong to
   the open pipe, which Emacs's own descriptor for its write end shares;
   Emacs only reads the other end.  Nothing here changes how the process
   handles signals. */

#ifdef F_SETNOSIGPIPE
static bool ignore_sigpipe(int fd)
{
    return fcntl(fd, F_SETNOSIGPIPE, 1) != -1;
}
#else
/* A future concern: without a per-descriptor setting, as on Linux, writes
   must block SIGPIPE in the writing thread and consume the one a closed
   reader raises there (pthread_sigmask, sigpending, sigtimedwait). */
#error "Portal needs F_SETNOSIGPIPE to write to Emacs's pipe without SIGPIPE"
#endif

/* Make FD safe to own: writes never block, child processes do not inherit
   it, and a write after Emacs closes its end fails with EPIPE instead of
   raising SIGPIPE, whose default action would kill Emacs. */
static bool prepare(int fd)
{
    int status = fcntl(fd, F_GETFL), flags = fcntl(fd, F_GETFD);
    return status != -1 && flags != -1 && fcntl(fd, F_SETFL, status | O_NONBLOCK) != -1
        && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != -1 && ignore_sigpipe(fd);
}

/* Write what is left of the first waiting record.  Returns 0 once all of it
   is in the pipe, EAGAIN while the pipe is full, or another errno, such as
   EPIPE, when nothing is reading.  A record fits in PIPE_BUF, so POSIX makes
   each write all or nothing; a short write would still resume where it
   stopped, never resending a byte. */
static int write_first(void)
{
    const struct record *record = channel.first;
    while (channel.sent < record->length) {
        ssize_t written = portal_channel_write(channel.fd, record->line + channel.sent,
                                               record->length - channel.sent);
        if (written > 0)
            channel.sent += (size_t) written;
        else if (written == 0 || errno == EAGAIN || errno == EWOULDBLOCK)
            return EAGAIN;
        else if (errno != EINTR)
            return errno;
    }
    return 0;
}

/* Write waiting records in order until the pipe is full, then retry soon.
   Without a reader, records wait for Emacs to connect a pipe. */
static void flush(void)
{
    while (channel.first && channel.fd >= 0) {
        int error = write_first();
        if (error == EAGAIN && !channel.timer) {
            channel.timer = ++channel.tokens;
            portal_timer_start(channel.timer, RETRY_MILLISECONDS);
        }
        if (error)
            return;
        struct record *sent = channel.first;
        channel.first = sent->next;
        if (!channel.first)
            channel.last = NULL;
        channel.sent = 0;
        free(sent);
    }
}

bool portal_channel_connect(int fd)
{
    if (fd >= 0 && !prepare(fd))
        return false;
    if (fd != channel.fd) {
        /* Closed once and never retried: after EINTR the number may already
           name a descriptor that Emacs opened since. */
        if (channel.fd >= 0)
            close(channel.fd);
        channel.fd = fd;
        channel.sent = 0; /* A new reader needs whole records. */
    }
    channel.timer = 0;
    flush();
    return true;
}

uint64_t portal_channel_timer(uint64_t milliseconds)
{
    uint64_t token = ++channel.tokens;
    portal_timer_start(token, milliseconds);
    return token;
}

void portal_timer_fired(uint64_t token)
{
    if (token && token != channel.timer)
        return portal_rex_timer(token);
    if (!token)
        return; /* Cancelled by a connection since. */
    channel.timer = 0;
    flush();
}

/* Whether WORD can be part of a record: nonempty printable ASCII, no spaces. */
static bool valid_word(portal_string word)
{
    if (!word.length)
        return false;
    for (size_t i = 0; i < word.length; i++)
        if ((unsigned char) word.data[i] <= ' ' || (unsigned char) word.data[i] > '~')
            return false;
    return true;
}

bool portal_channel_send(portal_string type, portal_string target, const portal_string *fields,
                         size_t count)
{
    /* Each word takes at least two bytes: itself and a space or the newline. */
    if (count > PIPE_BUF / 2)
        return false;
    size_t words = count + 2, length = 0;
    for (size_t i = 0; i < words; i++) {
        portal_string word = i == 0 ? type : i == 1 ? target : fields[i - 2];
        if (word.length >= PIPE_BUF - length || !valid_word(word))
            return false;
        length += word.length + 1;
    }
    struct record *record = malloc(sizeof *record + length);
    if (!record)
        return false;
    *record = (struct record) {.length = length};
    char *end = record->line;
    for (size_t i = 0; i < words; i++) {
        portal_string word = i == 0 ? type : i == 1 ? target : fields[i - 2];
        memcpy(end, word.data, word.length);
        end += word.length;
        *end++ = i + 1 < words ? ' ' : '\n';
    }
    if (channel.last)
        channel.last->next = record;
    else
        channel.first = record;
    channel.last = record;
    flush();
    return true;
}

/* A feature event has no view target; keep portal_notify's view validation. */
bool portal_launcher_blurred(uint64_t session)
{
    char word[32];
    int length = snprintf(word, sizeof word, "%" PRIu64, session);
    return portal_channel_send((portal_string) {"launcher-blur", 13},
                               (portal_string) {word, (size_t) length}, NULL, 0);
}
