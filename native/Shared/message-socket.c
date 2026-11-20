/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Message sockets (message-socket.h): text messages, or binary ones, to and
   from a server on a Unix socket, as a WebSocket (RFC 6455) framed by hand,
   since no system client dials a Unix socket.  POSIX sockets, poll and
   threads only, so that one file serves every backend.

   One thread for each socket dials, upgrades, reads and writes, waiting in
   poll for the server, for something to send, and for the module thread,
   which wakes it through a pipe.  The module thread only queues, takes and
   wakes, except in wait: nothing here makes it wait for a server.

   The thread owns the descriptor from socket to close, so no other thread
   ever writes to a number that names another file by then.  A socket
   outlives its close until its thread is done with it; the two share it by
   count. */
/* For getentropy, and for the socket options glibc keeps from strict C11;
   macOS shows everything once _POSIX_C_SOURCE is not alone. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "message-socket.h"

/* A write to a server that has gone must fail with EPIPE, never raise
   SIGPIPE, which batch Emacs does not ignore: Linux says so at each send,
   macOS once on the socket (SO_NOSIGPIPE, below). */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

enum {
    /* The largest message a server may send, fragments together. */
    LARGEST_MESSAGE = 16 << 20,
    /* The most of a server's answer to the upgrade to read for its end. */
    LARGEST_ANSWER = 16384,
    /* How much to ask the socket for at a time. */
    CHUNK = 65536,
    /* How long a server that accepted may say nothing before it has answered
       the upgrade; once the connection is up, silence is normal. */
    PATIENCE_MILLISECONDS = 10000,
    /* How long a goodbye may take to go out: a server that has stopped
       reading would hold it forever. */
    GOODBYE_MILLISECONDS = 1000,
    /* The longest wait, an hour. */
    LONGEST_WAIT_MILLISECONDS = 3600000,
};

/* Bytes that grow, with a NUL after them that LENGTH does not count. */
struct bytes {
    char *data;
    size_t length, capacity;
    bool failed; /* No memory: what was put since is missing. */
};

static bool reserve(struct bytes *bytes, size_t more)
{
    if (bytes->failed || more > SIZE_MAX - bytes->length - 1) {
        bytes->failed = true;
        return false;
    }
    size_t needed = bytes->length + more + 1;
    if (needed <= bytes->capacity)
        return true;
    size_t capacity = bytes->capacity < 64 ? 64 : bytes->capacity;
    while (capacity < needed)
        capacity = capacity > SIZE_MAX / 2 ? needed : capacity * 2;
    char *grown = realloc(bytes->data, capacity);
    if (!grown) {
        bytes->failed = true;
        return false;
    }
    bytes->data = grown;
    bytes->capacity = capacity;
    return true;
}

static void put(struct bytes *bytes, const void *data, size_t length)
{
    if (!reserve(bytes, length))
        return;
    if (length)
        memcpy(bytes->data + bytes->length, data, length);
    bytes->length += length;
    bytes->data[bytes->length] = '\0';
}

static void put_text(struct bytes *bytes, const char *text)
{
    put(bytes, text, strlen(text));
}

/* The length of the well-formed UTF-8 sequence at BYTES, of LENGTH bytes or
   more; or 0, with *SKIP the length of what is ill-formed there: as much as
   could have started a sequence, at least one byte (Unicode's "maximal
   subpart", which is how Swift's String(decoding:as:) and Python's
   "replace" count too). */
static size_t utf8_sequence(const unsigned char *bytes, size_t length, size_t *skip)
{
    unsigned char lead = bytes[0], low = 0x80, high = 0xbf;
    size_t count;
    if (lead < 0x80)
        return 1;
    if (lead >= 0xc2 && lead <= 0xdf) {
        count = 2;
    } else if (lead >= 0xe0 && lead <= 0xef) {
        count = 3;
        if (lead == 0xe0)
            low = 0xa0; /* No overlong forms. */
        else if (lead == 0xed)
            high = 0x9f; /* No surrogates. */
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        count = 4;
        if (lead == 0xf0)
            low = 0x90;
        else if (lead == 0xf4)
            high = 0x8f; /* Nothing past U+10FFFF. */
    } else {
        *skip = 1;
        return 0;
    }
    for (size_t i = 1; i < count; i++) {
        if (i == length || bytes[i] < low || bytes[i] > high) {
            *skip = i;
            return 0;
        }
        low = 0x80;
        high = 0xbf;
    }
    return count;
}

/* Put the LENGTH BYTES as UTF-8: as they are where they are well-formed,
   and U+FFFD for each stretch that is not. */
static void put_utf8(struct bytes *out, const void *data, size_t length)
{
    const unsigned char *bytes = data;
    size_t start = 0, at = 0, skip = 0;
    while (at < length) {
        size_t count = utf8_sequence(bytes + at, length - at, &skip);
        if (count) {
            at += count;
            continue;
        }
        put(out, bytes + start, at - start);
        put(out, "\xef\xbf\xbd", 3);
        at += skip;
        start = at;
    }
    put(out, bytes + start, at - start);
}

/* SHA-1 (FIPS 180-4) of the LENGTH BYTES, which the upgrade's answer is
   checked with.  Nothing here is kept secret by it. */
static void sha1(const unsigned char *bytes, size_t length, unsigned char digest[20])
{
    uint32_t state[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
    unsigned char block[64];
    /* The message, then 0x80, zeros, and its length in bits, in whole blocks. */
    size_t padded = (length + 9 + 63) / 64 * 64;
    uint64_t bits = (uint64_t) length * 8;
    for (size_t offset = 0; offset < padded; offset += 64) {
        for (size_t i = 0; i < 64; i++) {
            size_t at = offset + i;
            block[i] = at < length ? bytes[at]
                : at == length     ? 0x80
                : at < padded - 8  ? 0
                                   : (unsigned char) (bits >> (padded - 1 - at) * 8);
        }
        uint32_t words[80];
        for (size_t i = 0; i < 16; i++)
            words[i] = (uint32_t) block[4 * i] << 24 | (uint32_t) block[4 * i + 1] << 16
                | (uint32_t) block[4 * i + 2] << 8 | block[4 * i + 3];
        for (size_t i = 16; i < 80; i++) {
            uint32_t word = words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16];
            words[i] = word << 1 | word >> 31;
        }
        uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
        for (size_t i = 0; i < 80; i++) {
            uint32_t mixed = i < 20 ? ((b & c) | (~b & d)) + 0x5a827999
                : i < 40            ? (b ^ c ^ d) + 0x6ed9eba1
                : i < 60            ? ((b & c) | (b & d) | (c & d)) + 0x8f1bbcdc
                                    : (b ^ c ^ d) + 0xca62c1d6;
            uint32_t next = (a << 5 | a >> 27) + mixed + e + words[i];
            e = d;
            d = c;
            c = b << 30 | b >> 2;
            b = a;
            a = next;
        }
        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
    }
    for (size_t i = 0; i < 20; i++)
        digest[i] = (unsigned char) (state[i / 4] >> (3 - i % 4) * 8);
}

/* The LENGTH BYTES in base64, with padding, as text at OUT, which holds
   4 * ((LENGTH + 2) / 3) + 1 bytes. */
static void base64(const unsigned char *bytes, size_t length, char *out)
{
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < length; i += 3) {
        uint32_t group = (uint32_t) bytes[i] << 16
            | (i + 1 < length ? (uint32_t) bytes[i + 1] << 8 : 0)
            | (i + 2 < length ? bytes[i + 2] : 0);
        *out++ = alphabet[group >> 18];
        *out++ = alphabet[group >> 12 & 63];
        *out++ = i + 1 < length ? alphabet[group >> 6 & 63] : '=';
        *out++ = i + 2 < length ? alphabet[group & 63] : '=';
    }
    *out = '\0';
}

/* What the server's answer to the upgrade must carry for KEY, 24 characters,
   at ACCEPT, which holds 29 bytes (RFC 6455, section 4.2.2). */
static void accept_of(const char *key, char accept[29])
{
    static const char magic[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    unsigned char joined[24 + sizeof magic - 1], digest[20];
    memcpy(joined, key, 24);
    memcpy(joined + 24, magic, sizeof magic - 1);
    sha1(joined, sizeof joined, digest);
    base64(digest, sizeof digest, accept);
}

/* The next of a stream of numbers no server can guess, for a frame's mask
   (xorshift64*).  A mask keeps a proxy from reading a frame as a request of
   its own; a Unix socket has none, and the masks need be no better. */
static uint64_t random_next(uint64_t *state)
{
    *state ^= *state >> 12;
    *state ^= *state << 25;
    *state ^= *state >> 27;
    return *state * UINT64_C(0x2545f4914f6cdd1d);
}

/* A frame on its way out.  Frames form a list, oldest first. */
struct frame {
    struct frame *next;
    size_t length, written;
    unsigned char bytes[];
};

/* A client's frame: final, and masked, as each must be.  NULL without
   memory. */
static struct frame *frame_of(unsigned opcode, const void *payload, size_t length,
                              uint64_t *random)
{
    size_t header = 2 + (length < 126 ? 0 : length < 65536 ? 2 : 8) + 4;
    if (length > SIZE_MAX - header - sizeof(struct frame))
        return NULL;
    struct frame *frame = malloc(sizeof *frame + header + length);
    if (!frame)
        return NULL;
    frame->next = NULL;
    frame->length = header + length;
    frame->written = 0;
    unsigned char *out = frame->bytes;
    *out++ = (unsigned char) (0x80 | opcode);
    if (length < 126) {
        *out++ = (unsigned char) (0x80 | length);
    } else if (length < 65536) {
        *out++ = 0x80 | 126;
        *out++ = (unsigned char) (length >> 8);
        *out++ = (unsigned char) length;
    } else {
        *out++ = 0x80 | 127;
        for (int shift = 56; shift >= 0; shift -= 8)
            *out++ = (unsigned char) ((uint64_t) length >> shift);
    }
    uint64_t drawn = random_next(random);
    unsigned char mask[4] = {(unsigned char) (drawn >> 24), (unsigned char) (drawn >> 32),
                             (unsigned char) (drawn >> 40), (unsigned char) (drawn >> 48)};
    memcpy(out, mask, 4);
    out += 4;
    const unsigned char *bytes = payload;
    for (size_t i = 0; i < length; i++)
        out[i] = bytes[i] ^ mask[i & 3];
    return frame;
}

/* A message that arrived.  Messages form a list, oldest first. */
struct message {
    struct message *next;
    portal_text text; /* NUL-terminated, for the core to free. */
};

enum phase { CONNECTING, OPEN, ENDED };

struct message_socket {
    /* The module thread's: the open sockets, and its masks. */
    struct message_socket *next;
    uint64_t module_random;

    /* Set at open and never changed. */
    uint64_t id;
    char *path, *resource, *protocol;
    bool binary; /* Messages are binary, both ways, not text. */
    portal_message_socket_wake wake;
    void *context;
    /* Where the masks of its thread's own frames start. */
    uint64_t thread_random;
    /* How the module thread wakes the socket's own: a byte written to [1]
       ends the poll on [0]. */
    int pipe[2];

    /* Guards what follows; CHANGED wakes wait. */
    pthread_mutex_t lock;
    pthread_cond_t changed;
    /* The open sockets' hold on it, and its thread's. */
    int holds;
    enum phase phase;
    /* Frames to write, those sent before the connection was up too.  Only
       the socket's thread takes one off. */
    struct frame *out, *out_last;
    /* Messages the core has not read, and their bytes: past
       PORTAL_SOCKET_UNREAD on a binary socket, its thread stops reading
       until the core reads. */
    struct message *arrived, *arrived_last;
    size_t arrived_count, unread;
    /* Why the connection ended, once it has, and the status of the server's
       close frame, or 0 without one. */
    portal_text reason;
    int code;
    /* The core closed the socket: report nothing more. */
    bool closed;
};

/* The open sockets, by the core's name for each.  The module thread's. */
static struct message_socket *sockets;

static bool fail(portal_text *error, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(NULL, 0, format, arguments);
    va_end(arguments);
    char *data = length < 0 ? NULL : malloc((size_t) length + 1);
    if (data) {
        va_start(arguments, format);
        vsnprintf(data, (size_t) length + 1, format, arguments);
        va_end(arguments);
        *error = (portal_text) {data, (size_t) length};
    }
    return false;
}

static struct message_socket *find(uint64_t id, portal_text *error)
{
    for (struct message_socket *socket = sockets; id && socket; socket = socket->next)
        if (socket->id == id)
            return socket;
    if (error)
        fail(error, "No message socket %llu", (unsigned long long) id);
    return NULL;
}

/* End the poll of SOCKET's thread: something changed that it waits for. */
static void poke(struct message_socket *socket)
{
    /* A full pipe has woken it already. */
    ssize_t ignored = write(socket->pipe[1], "", 1);
    (void) ignored;
}

static void drop_frames(struct frame *frames)
{
    while (frames) {
        struct frame *next = frames->next;
        free(frames);
        frames = next;
    }
}

/* Let go of one hold on SOCKET, and of SOCKET with the last. */
static void release(struct message_socket *socket)
{
    pthread_mutex_lock(&socket->lock);
    bool last = --socket->holds == 0;
    pthread_mutex_unlock(&socket->lock);
    if (!last)
        return;
    drop_frames(socket->out);
    while (socket->arrived) {
        struct message *next = socket->arrived->next;
        free(socket->arrived->text.data);
        free(socket->arrived);
        socket->arrived = next;
    }
    close(socket->pipe[0]);
    close(socket->pipe[1]);
    pthread_mutex_destroy(&socket->lock);
    pthread_cond_destroy(&socket->changed);
    free(socket->reason.data);
    free(socket->path);
    free(socket->resource);
    free(socket->protocol);
    free(socket);
}

/* The socket's own thread. */

/* What the thread alone holds. */
struct line {
    struct message_socket *socket;
    int fd; /* -1 before the dial. */
    /* What arrived and is not parsed: BUFFER from CONSUMED on. */
    struct bytes buffer;
    size_t consumed;
    /* The frames so far of a message in fragments. */
    struct bytes message;
    bool fragmented;
    /* The status the connection ends with, or 0. */
    int code;
    /* The server takes no more: nothing is written from then on, and what
       it sent before going is still read. */
    bool mute;
    uint64_t random;
};

/* Why a connection ended, as text for people. */
static portal_text because(const char *why)
{
    struct bytes text = {0};
    put_text(&text, why);
    return (portal_text) {text.data, text.length};
}

static const char gone[] = "The connection to the server was lost";

static int64_t now_milliseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t) now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static bool closed(struct message_socket *socket)
{
    pthread_mutex_lock(&socket->lock);
    bool is = socket->closed;
    pthread_mutex_unlock(&socket->lock);
    return is;
}

/* Take what woke the thread out of its pipe. */
static void drain(struct message_socket *socket)
{
    char woken[64];
    while (read(socket->pipe[0], woken, sizeof woken) > 0)
        continue;
}

/* Wait until LINE's descriptor has EVENTS, the module thread wakes the
   socket, or MILLISECONDS pass, -1 for no limit; with no EVENTS, for the
   other two alone.  Return what the descriptor has, 0 for none. */
static short await(struct line *line, short events, int milliseconds)
{
    struct pollfd waits[2] = {{.fd = events ? line->fd : -1, .events = events},
                              {.fd = line->socket->pipe[0], .events = POLLIN}};
    if (poll(waits, 2, milliseconds) <= 0)
        return 0;
    if (waits[1].revents)
        drain(line->socket);
    return waits[0].revents;
}

/* Read what has arrived into LINE's buffer: 1 for some, 0 for none yet, -1
   once the server has hung up or the line broke. */
static int take_in(struct line *line)
{
    struct bytes *buffer = &line->buffer;
    if (line->consumed > CHUNK && line->consumed > buffer->length / 2) {
        memmove(buffer->data, buffer->data + line->consumed, buffer->length - line->consumed);
        buffer->length -= line->consumed;
        line->consumed = 0;
    }
    if (!reserve(buffer, CHUNK))
        return -1;
    for (;;) {
        ssize_t count = read(line->fd, buffer->data + buffer->length, CHUNK);
        if (count > 0) {
            buffer->length += (size_t) count;
            return 1;
        }
        if (count < 0 && errno == EINTR)
            continue;
        return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
    }
}

/* Write what waits to go out, as much as the server takes now: 1 once
   nothing waits, 0 while some does, -1 once the line broke. */
static int write_out(struct line *line)
{
    struct message_socket *socket = line->socket;
    for (;;) {
        pthread_mutex_lock(&socket->lock);
        struct frame *frame = socket->out;
        pthread_mutex_unlock(&socket->lock);
        if (!frame)
            return 1;
        ssize_t count = send(line->fd, frame->bytes + frame->written,
                             frame->length - frame->written, MSG_NOSIGNAL);
        if (count > 0) {
            frame->written += (size_t) count;
            if (frame->written < frame->length)
                continue;
            pthread_mutex_lock(&socket->lock);
            socket->out = frame->next;
            if (!socket->out)
                socket->out_last = NULL;
            pthread_mutex_unlock(&socket->lock);
            free(frame);
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
        }
    }
}

/* Queue FRAME, which may be NULL for want of memory, behind what waits. */
static void queue(struct message_socket *socket, struct frame *frame)
{
    if (!frame)
        return;
    pthread_mutex_lock(&socket->lock);
    if (socket->phase == ENDED || socket->closed) {
        pthread_mutex_unlock(&socket->lock);
        free(frame);
        return;
    }
    if (socket->out_last)
        socket->out_last->next = frame;
    else
        socket->out = frame;
    socket->out_last = frame;
    pthread_mutex_unlock(&socket->lock);
}

/* Forget what waits to go out. */
static void drop_out(struct message_socket *socket)
{
    pthread_mutex_lock(&socket->lock);
    struct frame *frames = socket->out;
    socket->out = socket->out_last = NULL;
    pthread_mutex_unlock(&socket->lock);
    drop_frames(frames);
}

/* Say goodbye with PAYLOAD, a close frame's, behind what waits to go out,
   and give it all GOODBYE_MILLISECONDS to leave. */
static void goodbye(struct line *line, const unsigned char *payload, size_t length)
{
    struct message_socket *socket = line->socket;
    if (line->mute)
        return;
    struct frame *frame = frame_of(0x8, payload, length, &line->random);
    if (frame) {
        /* Past queue's refusal of a closed socket: this is its last frame. */
        pthread_mutex_lock(&socket->lock);
        if (socket->out_last)
            socket->out_last->next = frame;
        else
            socket->out = frame;
        socket->out_last = frame;
        pthread_mutex_unlock(&socket->lock);
    }
    int64_t deadline = now_milliseconds() + GOODBYE_MILLISECONDS;
    while (write_out(line) == 0) {
        int64_t left = deadline - now_milliseconds();
        if (left <= 0)
            break;
        /* Woken or not, only the server taking more gets the goodbye out. */
        struct pollfd wait = {.fd = line->fd, .events = POLLOUT};
        poll(&wait, 1, (int) left);
    }
}

/* Dial the socket's path and upgrade the connection: NULL once it is up,
   or why it is not, as because gives it. */
static const char *dial(struct line *line, struct bytes *why)
{
    struct message_socket *socket_ = line->socket;
#ifdef SOCK_CLOEXEC
    line->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
    line->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (line->fd >= 0)
        fcntl(line->fd, F_SETFD, FD_CLOEXEC);
#endif
    if (line->fd < 0) {
        put_text(why, "Cannot make a socket: ");
        put_text(why, strerror(errno));
        return why->data;
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(line->fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    if (closed(socket_))
        return "Closed";

    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, socket_->path, strlen(socket_->path) + 1);
    int dialed = connect(line->fd, (struct sockaddr *) &address, sizeof address);
    if (dialed != 0 && errno == EINTR) {
        /* The dial goes on by itself: wait for how it ends. */
        struct pollfd wait = {.fd = line->fd, .events = POLLOUT};
        socklen_t size = sizeof dialed;
        while (poll(&wait, 1, -1) < 0 && errno == EINTR)
            continue;
        if (getsockopt(line->fd, SOL_SOCKET, SO_ERROR, &dialed, &size) == 0 && dialed)
            errno = dialed;
    }
    if (dialed != 0) {
        if (errno == ENOENT || errno == ECONNREFUSED)
            return "Nothing is listening on that socket";
        put_text(why, "Cannot connect: ");
        put_text(why, strerror(errno));
        return why->data;
    }
    fcntl(line->fd, F_SETFL, fcntl(line->fd, F_GETFL) | O_NONBLOCK);

    unsigned char drawn[16];
    for (size_t i = 0; i < sizeof drawn; i += 8) {
        uint64_t number = random_next(&line->random);
        memcpy(drawn + i, &number, 8);
    }
    char key[25], accept[29];
    base64(drawn, sizeof drawn, key);
    accept_of(key, accept);
    struct bytes request = {0};
    put_text(&request, "GET ");
    put_text(&request, socket_->resource);
    put_text(&request, " HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                       "Connection: Upgrade\r\nSec-WebSocket-Key: ");
    put_text(&request, key);
    put_text(&request, "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: ");
    put_text(&request, socket_->protocol);
    put_text(&request, "\r\n\r\n");
    if (request.failed) {
        free(request.data);
        return gone;
    }
    for (size_t written = 0; written < request.length;) {
        ssize_t count = send(line->fd, request.data + written, request.length - written,
                             MSG_NOSIGNAL);
        if (count > 0) {
            written += (size_t) count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            await(line, POLLOUT, -1);
            if (closed(socket_)) {
                free(request.data);
                return "Closed";
            }
        } else {
            free(request.data);
            return gone;
        }
    }
    free(request.data);

    /* The answer: a status line and headers, up to an empty line. */
    const char *end = NULL;
    while (!end) {
        struct bytes *buffer = &line->buffer;
        for (size_t i = 0; !end && i + 4 <= buffer->length; i++)
            if (!memcmp(buffer->data + i, "\r\n\r\n", 4))
                end = buffer->data + i;
        if (end)
            break;
        if (buffer->length >= LARGEST_ANSWER)
            return "The server's answer is not a WebSocket's";
        /* The server has until then to say something, each time. */
        int64_t deadline = now_milliseconds() + PATIENCE_MILLISECONDS;
        for (;;) {
            int took = take_in(line);
            if (took > 0)
                break;
            if (took < 0)
                return gone;
            int64_t left = deadline - now_milliseconds();
            if (left <= 0)
                return "The server did not answer";
            await(line, POLLIN, (int) left);
            if (closed(socket_))
                return "Closed";
        }
    }
    const char *head = line->buffer.data;
    line->consumed = (size_t) (end - head) + 4;
    const char *status_end = head;
    while (status_end < end && memcmp(status_end, "\r\n", 2))
        status_end++;
    static const char switching[] = "HTTP/1.1 101";
    if ((size_t) (status_end - head) < sizeof switching - 1
        || memcmp(head, switching, sizeof switching - 1)) {
        put_text(why, "The server refused the connection: ");
        put_utf8(why, head, (size_t) (status_end - head));
        return why->data;
    }
    /* The headers the answer must carry, the last of each name: what the
       key hashes to, and the subprotocol asked for. */
    bool accepted = false, spoken = false;
    for (const char *at = status_end; at < end;) {
        at += 2;
        const char *stop = at;
        while (stop < end && memcmp(stop, "\r\n", 2))
            stop++;
        const char *colon = memchr(at, ':', (size_t) (stop - at));
        if (colon) {
            const char *value = colon + 1, *value_end = stop;
            while (value < value_end && (*value == ' ' || *value == '\t'))
                value++;
            while (value_end > value && (value_end[-1] == ' ' || value_end[-1] == '\t'))
                value_end--;
            size_t length = (size_t) (value_end - value);
            static const char accept_name[] = "sec-websocket-accept";
            static const char protocol_name[] = "sec-websocket-protocol";
            if ((size_t) (colon - at) == sizeof accept_name - 1
                && !strncasecmp(at, accept_name, sizeof accept_name - 1))
                accepted = length == strlen(accept) && !memcmp(value, accept, length);
            else if ((size_t) (colon - at) == sizeof protocol_name - 1
                     && !strncasecmp(at, protocol_name, sizeof protocol_name - 1))
                spoken = length == strlen(socket_->protocol)
                    && !memcmp(value, socket_->protocol, length);
        }
        at = stop;
    }
    if (!accepted)
        return "The server's answer is not a WebSocket's";
    if (!spoken) {
        put_text(why, "The server does not speak ");
        put_text(why, socket_->protocol);
        return why->data;
    }

    /* What was sent meanwhile waits in order, ahead of any send that finds
       the connection open.  A close that found it still connecting told
       only this thread: it must not be left open. */
    pthread_mutex_lock(&socket_->lock);
    bool closed_meanwhile = socket_->closed;
    if (!closed_meanwhile)
        socket_->phase = OPEN;
    pthread_mutex_unlock(&socket_->lock);
    return closed_meanwhile ? "Closed" : NULL;
}

/* Hand TEXT, a whole message, to the core, and tell of it if nothing was
   waiting to be read. */
static void deliver(struct message_socket *socket, portal_text text)
{
    struct message *message = malloc(sizeof *message);
    if (!message) {
        free(text.data);
        return;
    }
    *message = (struct message) {.text = text};
    pthread_mutex_lock(&socket->lock);
    bool report = !socket->arrived && !socket->closed;
    if (socket->arrived_last)
        socket->arrived_last->next = message;
    else
        socket->arrived = message;
    socket->arrived_last = message;
    socket->arrived_count++;
    socket->unread += text.length;
    pthread_cond_broadcast(&socket->changed);
    pthread_mutex_unlock(&socket->lock);
    if (report)
        socket->wake(socket->id, socket->context);
}

enum parsed { MORE, FRAME, END };

/* The connection ends because the server broke the protocol: WHY, with
   STATUS as its code, what a close of the client's would say. */
static enum parsed refuse(struct line *line, portal_text *reason, const char *why, int status)
{
    line->code = status;
    *reason = because(why);
    return END;
}

static enum parsed broken(struct line *line, portal_text *reason)
{
    return refuse(line, reason, "The server broke the WebSocket protocol", 1002);
}

/* Take one frame out of LINE's buffer, if a whole one is there: MORE when
   none is, FRAME when one was, END with *REASON when it ends the
   connection. */
static enum parsed parse(struct line *line, portal_text *reason)
{
    struct message_socket *socket = line->socket;
    static const char large[] = "The server sent a message that is too large";
    const unsigned char *bytes = (const unsigned char *) line->buffer.data + line->consumed;
    size_t have = line->buffer.length - line->consumed, header = 2;
    if (have < header)
        return MORE;
    bool last = bytes[0] & 0x80;
    unsigned opcode = bytes[0] & 0x0f;
    /* No extension was asked for, and a server never masks. */
    if ((bytes[0] & 0x70) || (bytes[1] & 0x80))
        return broken(line, reason);
    uint64_t length = bytes[1] & 0x7f;
    if (length >= 126) {
        size_t wide = length == 126 ? 2 : 8;
        if (have < header + wide)
            return MORE;
        length = 0;
        for (size_t i = 0; i < wide; i++)
            length = length << 8 | bytes[header + i];
        header += wide;
    }
    bool control = opcode >= 0x8;
    if (control && !(last && length < 126))
        return broken(line, reason);
    if (length > LARGEST_MESSAGE)
        return refuse(line, reason, large, 1009);
    if (have - header < length)
        return MORE;
    const unsigned char *payload = bytes + header;
    line->consumed += header + (size_t) length;

    switch (opcode) {
    case 0x9: /* A ping: answer with what it carried. */
        if (!line->mute)
            queue(socket, frame_of(0xa, payload, (size_t) length, &line->random));
        return FRAME;
    case 0xa:
        return FRAME;
    case 0x8: {
        /* The server is closing the connection: answer with its status,
           and say why. */
        struct bytes why = {0};
        put_text(&why, "The server closed the connection");
        if (length >= 2) {
            line->code = payload[0] << 8 | payload[1];
            char number[16];
            snprintf(number, sizeof number, " (%d", line->code);
            put_text(&why, number);
            if (length > 2) {
                put_text(&why, ": ");
                put_utf8(&why, payload + 2, (size_t) length - 2);
            }
            put_text(&why, ")");
        }
        goodbye(line, payload, length < 2 ? (size_t) length : 2);
        *reason = (portal_text) {why.data, why.length};
        return END;
    }
    case 0x0:
    case 0x1:
    case 0x2: {
        /* A message starts with a text frame, or a binary one on a binary
           socket, and goes on with continuation frames, never the other
           way around. */
        if (opcode == (socket->binary ? 0x1u : 0x2u))
            return refuse(line, reason,
                          socket->binary ? "The server sent a message that is not binary"
                                         : "The server sent a message that is not text",
                          1002);
        if ((opcode != 0x0) == line->fragmented)
            return broken(line, reason);
        if (line->message.length + length > LARGEST_MESSAGE)
            return refuse(line, reason, large, 1009);
        put(&line->message, payload, (size_t) length);
        line->fragmented = true;
        if (!last)
            return FRAME;
        struct bytes whole = line->message, text = {0};
        line->message = (struct bytes) {0};
        line->fragmented = false;
        if (whole.failed) {
            /* Without memory for it, the message is lost and the next one
               is not. */
            free(whole.data);
            return FRAME;
        }
        if (socket->binary) {
            text = whole;
        } else {
            put_utf8(&text, whole.data, whole.length);
            free(whole.data);
        }
        if (!text.failed && reserve(&text, 0)) {
            text.data[text.length] = '\0';
            deliver(socket, (portal_text) {text.data, text.length});
        } else {
            free(text.data);
        }
        return FRAME;
    }
    default:
        return broken(line, reason);
    }
}

/* Read messages and write what is sent until the connection ends; return
   why it did. */
static portal_text receive(struct line *line)
{
    struct message_socket *socket = line->socket;
    for (;;) {
        pthread_mutex_lock(&socket->lock);
        bool closing = socket->closed;
        /* On a binary socket, the core's unread bytes hold the reading
           back, and so the server: what is not read from the socket stays
           with it. */
        bool held = socket->binary && socket->unread >= PORTAL_SOCKET_UNREAD;
        bool sending = socket->out != NULL;
        pthread_mutex_unlock(&socket->lock);
        if (closing) {
            /* Normal closure, 1000. */
            goodbye(line, (const unsigned char *) "\x03\xe8", 2);
            return because("Closed");
        }
        if (!held) {
            portal_text reason = {0};
            enum parsed parsed = parse(line, &reason);
            if (parsed == FRAME)
                continue;
            if (parsed == END)
                return reason;
        }
        if (line->mute && sending) {
            drop_out(socket);
            sending = false;
        }
        short events = (short) ((held ? 0 : POLLIN) | (sending ? POLLOUT : 0));
        short ready = await(line, events, -1);
        if ((ready & (POLLOUT | POLLERR | POLLHUP)) && sending && write_out(line) < 0) {
            /* What the server sent before it went is still to be read: a
               close frame among it says why. */
            line->mute = true;
            drop_out(socket);
        }
        if ((ready & (POLLIN | POLLERR | POLLHUP)) && !held && take_in(line) < 0)
            return because(gone);
    }
}

static void *run(void *argument)
{
    struct line line = {.socket = argument, .fd = -1};
    struct message_socket *socket = line.socket;
    line.random = socket->thread_random;
    struct bytes said = {0};
    const char *refused = dial(&line, &said);
    /* A reason there was no memory for is an empty one. */
    portal_text reason = !refused       ? receive(&line)
        : refused == said.data          ? (portal_text) {said.data, said.length}
                                        : because(refused);
    if (refused != said.data)
        free(said.data);
    if (line.fd >= 0)
        close(line.fd);
    free(line.buffer.data);
    free(line.message.data);

    /* The end and its reason come together: a read sees both or neither. */
    pthread_mutex_lock(&socket->lock);
    socket->phase = ENDED;
    struct frame *unsent = socket->out;
    socket->out = socket->out_last = NULL;
    socket->reason = reason;
    socket->code = line.code;
    bool report = !socket->arrived && !socket->closed;
    pthread_cond_broadcast(&socket->changed);
    pthread_mutex_unlock(&socket->lock);
    drop_frames(unsent);
    if (report)
        socket->wake(socket->id, socket->context);
    release(socket);
    return NULL;
}

/* The module thread. */

static char *copy_string(portal_string string)
{
    char *copy = malloc(string.length + 1);
    if (copy) {
        if (string.length)
            memcpy(copy, string.data, string.length);
        copy[string.length] = '\0';
    }
    return copy;
}

/* Make DESCRIPTOR one that no program Emacs starts inherits, and that
   never makes its caller wait. */
static bool private_nonblocking(int descriptor)
{
    return fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1
        && fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1;
}

bool portal_message_socket_open(uint64_t id, portal_string path, portal_string resource,
                                portal_string protocol, bool binary,
                                portal_message_socket_wake wake, void *context,
                                portal_text *error)
{
    if (!id || find(id, NULL))
        return fail(error, "Message socket %llu is already open", (unsigned long long) id);
    size_t capacity = sizeof ((struct sockaddr_un *) 0)->sun_path;
    if (path.length >= capacity)
        return fail(error, "A socket's path is at most %zu bytes, and this one is %zu: %.*s",
                    capacity - 1, path.length, (int) (path.length > 4096 ? 4096 : path.length),
                    path.data);
    struct message_socket *socket = calloc(1, sizeof *socket);
    if (!socket)
        return fail(error, "Portal is out of memory");
    *socket = (struct message_socket) {
        .id = id,
        .path = copy_string(path),
        .resource = copy_string(resource),
        .protocol = copy_string(protocol),
        .binary = binary,
        .wake = wake,
        .context = context,
        .pipe = {-1, -1},
        .holds = 2,
        .phase = CONNECTING,
    };
    errno = 0;
    bool piped = socket->path && socket->resource && socket->protocol && pipe(socket->pipe) == 0
        && private_nonblocking(socket->pipe[0]) && private_nonblocking(socket->pipe[1]);
    int failed = piped ? 0 : errno ? errno : ENOMEM;
    pthread_attr_t detached;
    if (!failed && !(failed = pthread_attr_init(&detached))) {
        pthread_mutex_init(&socket->lock, NULL);
        pthread_cond_init(&socket->changed, NULL);
        /* What no server can guess; without it, what few can. */
        if (getentropy(&socket->module_random, sizeof socket->module_random) != 0)
            socket->module_random = (uint64_t) now_milliseconds() ^ (uintptr_t) socket;
        /* Odd, so never the zero such numbers would stay at. */
        socket->module_random |= 1;
        socket->thread_random = (socket->module_random ^ UINT64_C(0x9e3779b97f4a7c14)) | 1;
        /* Emacs's signals are for Emacs's threads: this one takes none. */
        sigset_t every, before;
        sigfillset(&every);
        pthread_sigmask(SIG_BLOCK, &every, &before);
        pthread_t thread;
        pthread_attr_setdetachstate(&detached, PTHREAD_CREATE_DETACHED);
        failed = pthread_create(&thread, &detached, run, socket);
        pthread_sigmask(SIG_SETMASK, &before, NULL);
        pthread_attr_destroy(&detached);
        if (failed) {
            pthread_mutex_destroy(&socket->lock);
            pthread_cond_destroy(&socket->changed);
        }
    }
    if (failed) {
        if (socket->pipe[0] >= 0)
            close(socket->pipe[0]);
        if (socket->pipe[1] >= 0)
            close(socket->pipe[1]);
        free(socket->path);
        free(socket->resource);
        free(socket->protocol);
        free(socket);
        return fail(error, "Cannot start a message socket: %s", strerror(failed));
    }
    socket->next = sockets;
    sockets = socket;
    return true;
}

bool portal_message_socket_send(uint64_t id, portal_string text, portal_text *error)
{
    struct message_socket *socket = find(id, error);
    if (!socket)
        return false;
    struct frame *frame =
        frame_of(socket->binary ? 0x2 : 0x1, text.data, text.length, &socket->module_random);
    if (!frame)
        return fail(error, "Portal is out of memory");
    queue(socket, frame);
    poke(socket);
    return true;
}

bool portal_message_socket_read(uint64_t id, portal_text **messages, size_t *count, bool *ended,
                                int *code, portal_text *reason, portal_text *error)
{
    struct message_socket *socket = find(id, error);
    if (!socket)
        return false;
    pthread_mutex_lock(&socket->lock);
    bool over = socket->phase == ENDED;
    size_t room = socket->arrived_count ? socket->arrived_count : 1;
    portal_text *taken = malloc(room * sizeof *taken);
    char *why = over ? malloc(socket->reason.length + 1) : NULL;
    if (!taken || (over && !why)) {
        pthread_mutex_unlock(&socket->lock);
        free(taken);
        free(why);
        return fail(error, "Portal is out of memory");
    }
    size_t held = 0;
    while (socket->arrived) {
        struct message *message = socket->arrived;
        socket->arrived = message->next;
        taken[held++] = message->text;
        free(message);
    }
    socket->arrived_last = NULL;
    socket->arrived_count = 0;
    socket->unread = 0;
    if (over) {
        if (socket->reason.length)
            memcpy(why, socket->reason.data, socket->reason.length);
        why[socket->reason.length] = '\0';
        *reason = (portal_text) {why, socket->reason.length};
    }
    *code = over ? socket->code : 0;
    pthread_mutex_unlock(&socket->lock);
    *messages = taken;
    *count = held;
    *ended = over;
    /* A thread holding back for the core has room again. */
    poke(socket);
    return true;
}

bool portal_message_socket_wait(uint64_t id, uint64_t milliseconds, bool *ready,
                                portal_text *error)
{
    struct message_socket *socket = find(id, error);
    if (!socket)
        return false;
    if (milliseconds > LONGEST_WAIT_MILLISECONDS)
        milliseconds = LONGEST_WAIT_MILLISECONDS;
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t) (milliseconds / 1000);
    deadline.tv_nsec += (long) (milliseconds % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }
    pthread_mutex_lock(&socket->lock);
    while (!socket->arrived && socket->phase != ENDED)
        if (pthread_cond_timedwait(&socket->changed, &socket->lock, &deadline) == ETIMEDOUT)
            break;
    *ready = socket->arrived || socket->phase == ENDED;
    pthread_mutex_unlock(&socket->lock);
    return true;
}

bool portal_message_socket_close(uint64_t id, portal_text *error)
{
    struct message_socket *socket = find(id, error);
    if (!socket)
        return false;
    for (struct message_socket **link = &sockets; *link; link = &(*link)->next)
        if (*link == socket) {
            *link = socket->next;
            break;
        }
    /* Its thread says goodbye if the connection is up, and hangs up. */
    pthread_mutex_lock(&socket->lock);
    socket->closed = true;
    pthread_mutex_unlock(&socket->lock);
    poke(socket);
    release(socket);
    return true;
}
