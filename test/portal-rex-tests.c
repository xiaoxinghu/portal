/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's Rex connections, native/Core/rex.c, with the fake platform's
   message sockets and a real pipe standing in for Emacs's.  The test plays
   the server, through the fake: it reads what the core sent, delivers
   messages and ends connections. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <unistd.h>

#include "channel.h"
#include "portal-core-tests.h"
#include "rex.h"

/* The read end of the pipe the core writes records to. */
static int records;

/* Every record the core has sent since the last call, as one string. */
static const char *sent(void)
{
    static char text[4096];
    ssize_t length = read(records, text, sizeof text - 1);
    text[length > 0 ? length : 0] = '\0';
    return text;
}

static bool is_text(const char *actual, const char *expected)
{
    if (strcmp(actual, expected)) {
        fprintf(stderr, "Expected \"%s\", got \"%s\"\n", expected, actual);
        return false;
    }
    return true;
}

#define HELLO(name, version)                                                              \
    "{\"type\":\"hello\",\"api_revision\":12,\"api_min_revision\":12,\"client\":{\"kind\":" \
    "\"other\",\"platform\":\"macos\",\"name\":\"" name "\",\"version\":\"" version "\"}}"

/* Connect to PATH as Portal 0.1.0; return the ID, or 0 with *ERROR set. */
static uint64_t open_connection(const char *path, portal_text *error)
{
    uint64_t id = 0;
    return portal_rex_open(text(path), text("Portal"), text("0.1.0"), &id, error) ? id : 0;
}

/* Request METHOD with PAYLOAD on ID; return its number, or 0 with *ERROR set. */
static uint64_t request(uint64_t id, const char *method, const char *payload, portal_text *error)
{
    uint64_t number = 0;
    return portal_rex_request(id, text(method), text(payload), &number, error) ? number : 0;
}

/* What waits on ID, as "MESSAGE\nMESSAGE..." and, once the connection has
   ended, a last line "ended: REASON"; or "error: MESSAGE".  Valid until the
   next call. */
static const char *received(uint64_t id)
{
    static char line[4096];
    portal_text *messages = NULL, reason = {0}, error = {0};
    size_t count = 0, length = 0;
    bool ended = false;
    line[0] = '\0';
    if (!portal_rex_receive(id, &messages, &count, &ended, &reason, &error)) {
        snprintf(line, sizeof line, "error: %s", error.data);
        free(error.data);
        return line;
    }
    for (size_t i = 0; i < count; i++) {
        length += (size_t) snprintf(line + length, sizeof line - length, "%s%s", i ? "\n" : "",
                                    messages[i].data);
        free(messages[i].data);
    }
    if (ended)
        snprintf(line + length, sizeof line - length, "%sended: %s", count ? "\n" : "",
                 reason.data);
    free(messages);
    free(reason.data);
    return line;
}

static bool ready(uint64_t id)
{
    bool is_ready = false;
    portal_text error = {0};
    CHECK(portal_rex_wait(id, 1000, &is_ready, &error));
    return is_ready;
}

static void test_opening(void)
{
    portal_text error = {0};
    uint64_t unset = 99;
    /* A connection asks its socket for the control protocol and says hello
       before anything else. */
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    CHECK(id == 1);
    CHECK(is_text(portal_fake_socket_address(id), "/tmp/rex/server.sock /api/control rex.control.v1"));
    CHECK(is_text(portal_fake_socket_sent(id), HELLO("Portal", "0.1.0")));
    CHECK(is_text(sent(), ""));
    /* The client's name and version are written as JSON strings. */
    uint64_t quoted = 0;
    CHECK(portal_rex_open(text("/tmp/a b.sock"), text("Port\"al\n"), text("1\\2"), &quoted, &error));
    CHECK(quoted == 2);
    CHECK(is_text(portal_fake_socket_sent(quoted), HELLO("Port\\\"al\\u000a", "1\\\\2")));
    CHECK(portal_rex_close(quoted, &error));
    /* A socket is an absolute file name, and a client has a name. */
    CHECK(!portal_rex_open(text("server.sock"), text("Portal"), text("1"), &unset, &error));
    CHECK(says(&error, "A Rex server's socket is an absolute file name, not server.sock"));
    CHECK(!portal_rex_open(text(""), text("Portal"), text("1"), &unset, &error));
    CHECK(says(&error, "A Rex server's socket is an absolute file name, not "));
    CHECK(!portal_rex_open((portal_string) {"/a\0b", 4}, text("Portal"), text("1"), &unset, &error));
    CHECK(said(&error, "A Rex server's socket is an absolute file name, not /a\0b", 56));
    CHECK(!portal_rex_open(text("/s"), text(""), text("1"), &unset, &error));
    CHECK(says(&error, "A Rex client needs a name and a version"));
    CHECK(!portal_rex_open(text("/s"), text("Portal"), text(""), &unset, &error));
    CHECK(says(&error, "A Rex client needs a name and a version"));
    /* The platform's refusal is the error, and opens nothing. */
    char path[160];
    memset(path, 'a', sizeof path);
    path[0] = '/';
    path[sizeof path - 1] = '\0';
    CHECK(!open_connection(path, &error));
    CHECK(says(&error, "The fake's socket path is too long: 159 bytes"));
    portal_fake_refuse(true);
    CHECK(!open_connection("/tmp/rex/server.sock", &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(unset == 99);
    CHECK(portal_fake_sockets() == 1);
    /* An ID is never reused, even one a failed open took. */
    uint64_t next = open_connection("/tmp/rex/other.sock", &error);
    CHECK(next == 5);
    CHECK(portal_rex_close(next, &error));
    CHECK(portal_rex_close(id, &error));
    CHECK(portal_fake_sockets() == 0);
}

static void test_requests(void)
{
    portal_text error = {0};
    uint64_t first = open_connection("/tmp/rex/server.sock", &error);
    uint64_t second = open_connection("/tmp/rex/other.sock", &error);
    portal_fake_socket_sent(first);
    portal_fake_socket_sent(second);
    /* Each connection numbers its own requests, from 1. */
    CHECK(request(first, "session.list", "{}", &error) == 1);
    CHECK(request(first, "session.attach_all", "{\"event_scope\":\"session\"}", &error) == 2);
    CHECK(request(second, "server.version", "{}", &error) == 1);
    CHECK(is_text(portal_fake_socket_sent(first),
                  "{\"type\":\"request\",\"id\":\"1\",\"method\":\"session.list\",\"payload\":{}}\n"
                  "{\"type\":\"request\",\"id\":\"2\",\"method\":\"session.attach_all\","
                  "\"payload\":{\"event_scope\":\"session\"}}"));
    CHECK(is_text(portal_fake_socket_sent(second),
                  "{\"type\":\"request\",\"id\":\"1\",\"method\":\"server.version\",\"payload\":{}}"));
    /* A method is written as a JSON string, whatever it holds. */
    CHECK(request(first, "a\"b\\c", "{}", &error) == 3);
    CHECK(is_text(portal_fake_socket_sent(first),
                  "{\"type\":\"request\",\"id\":\"3\",\"method\":\"a\\\"b\\\\c\",\"payload\":{}}"));
    /* A request that is not sent takes no number. */
    CHECK(!request(first, "", "{}", &error));
    CHECK(says(&error, "A Rex request needs a method"));
    const char *payloads[] = {"", "{", "[]", "null", "\"{}\"", "{} ", " {}"};
    for (size_t i = 0; i < sizeof payloads / sizeof *payloads; i++) {
        char message[96];
        snprintf(message, sizeof message, "A Rex request's payload must be a JSON object, not %s",
                 payloads[i]);
        CHECK(!request(first, "session.list", payloads[i], &error));
        CHECK(says(&error, message));
    }
    portal_fake_refuse(true);
    CHECK(!request(first, "session.list", "{}", &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(is_text(portal_fake_socket_sent(first), ""));
    CHECK(request(first, "session.list", "{}", &error) == 4);
    /* A connection that is not open takes no request. */
    CHECK(!request(0, "session.list", "{}", &error));
    CHECK(says(&error, "No Rex connection 0"));
    CHECK(!request(second + 1, "session.list", "{}", &error));
    CHECK(says(&error, "No Rex connection 8"));
    CHECK(portal_rex_close(first, &error));
    CHECK(portal_rex_close(second, &error));
}

static void test_messages(void)
{
    portal_text error = {0};
    uint64_t first = open_connection("/tmp/rex/server.sock", &error);
    uint64_t second = open_connection("/tmp/rex/other.sock", &error);
    char first_record[32], second_record[32];
    snprintf(first_record, sizeof first_record, "rex %llu\n", (unsigned long long) first);
    snprintf(second_record, sizeof second_record, "rex %llu\n", (unsigned long long) second);
    CHECK(!ready(first));
    CHECK(is_text(received(first), ""));
    /* The first message waiting sends one record; those after it send none
       until Emacs has received them all, in the order they arrived. */
    portal_fake_socket_deliver(first, "{\"type\":\"welcome\"}");
    CHECK(is_text(sent(), first_record));
    CHECK(ready(first));
    portal_fake_socket_deliver(first, "{\"type\":\"event\",\"seq\":1}");
    portal_fake_socket_deliver(first, "not JSON at all");
    CHECK(is_text(sent(), ""));
    /* Each connection has its own record. */
    portal_fake_socket_deliver(second, "{\"type\":\"welcome\",\"second\":true}");
    CHECK(is_text(sent(), second_record));
    CHECK(is_text(received(first),
                  "{\"type\":\"welcome\"}\n{\"type\":\"event\",\"seq\":1}\nnot JSON at all"));
    CHECK(!ready(first));
    CHECK(is_text(received(first), ""));
    CHECK(is_text(received(second), "{\"type\":\"welcome\",\"second\":true}"));
    portal_fake_socket_deliver(first, "{\"type\":\"event\",\"seq\":2}");
    CHECK(is_text(sent(), first_record));
    /* A report for a socket that already has its record sends no other. */
    portal_socket_ready(first);
    CHECK(is_text(sent(), ""));
    CHECK(is_text(received(first), "{\"type\":\"event\",\"seq\":2}"));
    /* The platform may report late, after Emacs received what it reports:
       the record costs one empty receive. */
    portal_socket_ready(first);
    CHECK(is_text(sent(), first_record));
    CHECK(is_text(received(first), ""));
    /* A failed receive leaves the record standing. */
    portal_fake_socket_deliver(first, "{\"type\":\"event\",\"seq\":3}");
    CHECK(is_text(sent(), first_record));
    portal_fake_refuse(true);
    CHECK(is_text(received(first), "error: The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    portal_socket_ready(first);
    CHECK(is_text(sent(), ""));
    CHECK(is_text(received(first), "{\"type\":\"event\",\"seq\":3}"));
    CHECK(portal_rex_close(first, &error));
    CHECK(portal_rex_close(second, &error));
}

static void test_ending(void)
{
    portal_text error = {0};
    bool unset = true;
    char record[32], gone[64];
    /* A connection the server ends hands over its last messages with the
       reason, and is gone: its socket is closed and its ID names nothing. */
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    snprintf(record, sizeof record, "rex %llu\n", (unsigned long long) id);
    snprintf(gone, sizeof gone, "No Rex connection %llu", (unsigned long long) id);
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\"}");
    portal_fake_socket_end(id, "The server closed the connection");
    CHECK(is_text(sent(), record));
    CHECK(portal_fake_sockets() == 1);
    CHECK(is_text(received(id), "{\"type\":\"welcome\"}\nended: The server closed the connection"));
    CHECK(portal_fake_sockets() == 0);
    char expected[80];
    snprintf(expected, sizeof expected, "error: %s", gone);
    CHECK(is_text(received(id), expected));
    CHECK(!request(id, "session.list", "{}", &error));
    CHECK(says(&error, gone));
    CHECK(!portal_rex_wait(id, 0, &unset, &error));
    CHECK(says(&error, gone));
    CHECK(!portal_rex_close(id, &error));
    CHECK(says(&error, gone));
    CHECK(unset);
    /* The end alone sends the record too, as for a server that is not there. */
    id = open_connection("/tmp/rex/server.sock", &error);
    snprintf(record, sizeof record, "rex %llu\n", (unsigned long long) id);
    portal_fake_socket_end(id, "Connection refused");
    CHECK(is_text(sent(), record));
    CHECK(ready(id));
    CHECK(is_text(received(id), "ended: Connection refused"));
    CHECK(portal_fake_sockets() == 0);
    /* Closing drops what waits; a late report for it reaches nothing, and
       nothing more names it. */
    id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\"}");
    sent();
    portal_fake_refuse(true);
    CHECK(!portal_rex_close(id, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(portal_fake_sockets() == 1);
    CHECK(portal_rex_close(id, &error));
    CHECK(portal_fake_sockets() == 0);
    portal_socket_ready(id);
    portal_socket_ready(0);
    portal_socket_ready(12345);
    CHECK(is_text(sent(), ""));
    CHECK(!portal_rex_close(id, &error));
    snprintf(gone, sizeof gone, "No Rex connection %llu", (unsigned long long) id);
    CHECK(says(&error, gone));
}

int main(void)
{
    int ends[2];
    if (pipe(ends) || fcntl(ends[0], F_SETFL, O_NONBLOCK) == -1
        || !portal_channel_connect(ends[1])) {
        perror("pipe");
        return 1;
    }
    records = ends[0];
    test_opening();
    test_requests();
    test_messages();
    test_ending();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Rex connections passed");
    return 0;
}
