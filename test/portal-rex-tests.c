/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's Rex connections, native/Core/rex.c, with the fake platform's
   message sockets and a real pipe standing in for Emacs's.  The test plays
   the server, through the fake: it reads what the core sent, delivers
   messages and ends connections. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <unistd.h>

#include "channel.h"
#include "input.h"
#include "json.h"
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

/* The platform a hello reports, as the core names the one it is built for. */
#ifdef __APPLE__
#define PLATFORM "macos"
#else
#define PLATFORM "linux"
#endif

#define HELLO(name, version)                                                              \
    "{\"type\":\"hello\",\"api_revision\":12,\"api_min_revision\":12,\"client\":{\"kind\":" \
    "\"other\",\"platform\":\"" PLATFORM "\",\"name\":\"" name "\",\"version\":\"" version "\"}}"

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
       the core reads the socket at a report, finds nothing, and sends no
       record. */
    portal_socket_ready(first);
    CHECK(is_text(sent(), ""));
    CHECK(is_text(received(first), ""));
    /* What the core read at the report waits in the core, so a platform
       that cannot be read meanwhile loses Emacs nothing. */
    portal_fake_socket_deliver(first, "{\"type\":\"event\",\"seq\":3}");
    CHECK(is_text(sent(), first_record));
    portal_fake_refuse(true);
    CHECK(is_text(received(first), "{\"type\":\"event\",\"seq\":3}"));
    portal_fake_refuse(false);
    portal_socket_ready(first);
    CHECK(is_text(sent(), ""));
    CHECK(is_text(received(first), ""));
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

static void test_json(void)
{
    portal_string value;
    portal_text decoded = {0};
    int64_t number = 0;
    const char *object =
        " { \"skip\" : [1, {\"type\": \"no\"}, \"]}\\\"\"], \"type\":\"response\" ,"
        "\"id\":\"12\",\"n\":-42,\"big\":9223372036854775807,\"s\":\"a\\u001b\\n\\ud83d\\ude00\\udc00x\"}";
    CHECK(portal_json_member(text(object), "type", &value));
    CHECK(portal_json_is(value, "response"));
    CHECK(!portal_json_is(value, "respons"));
    CHECK(portal_json_member(text(object), "n", &value));
    CHECK(portal_json_integer(value, &number) && number == -42);
    CHECK(portal_json_member(text(object), "big", &value));
    CHECK(portal_json_integer(value, &number) && number == INT64_MAX);
    CHECK(portal_json_member(text(object), "s", &value));
    CHECK(portal_json_string(value, &decoded));
    CHECK(decoded.length == 11
          && !memcmp(decoded.data, "a\x1b\n\xf0\x9f\x98\x80\xef\xbf\xbdx", 11));
    free(decoded.data);
    /* Only the object's own members, not those nested in its values. */
    CHECK(!portal_json_member(text("{\"a\":{\"type\":1}}"), "type", &value));
    CHECK(!portal_json_member(text("{\"a\":1,"), "type", &value));
    CHECK(!portal_json_member(text("{\"a\" 1,\"type\":2}"), "type", &value));
    CHECK(!portal_json_member(text("[\"type\"]"), "type", &value));
    CHECK(!portal_json_member(text("{}"), "type", &value));
    CHECK(portal_json_member(text("{\"a\":[[[]]],\"type\":true}"), "type", &value));
    CHECK(value.length == 4 && !memcmp(value.data, "true", 4));
    const char *integers[] = {"1.5", "1e3", "01", "-", "", "9223372036854775808", "\"1\""};
    for (size_t i = 0; i < sizeof integers / sizeof *integers; i++)
        CHECK(!portal_json_integer(text(integers[i]), &number));
    const char *strings[] = {"\"a", "a\"", "\"\\x\"", "\"\\u12\"", "\"a\nb\"", "1"};
    for (size_t i = 0; i < sizeof strings / sizeof *strings; i++)
        CHECK(!portal_json_string(text(strings[i]), &decoded));
}

/* The block shown in the tests below, and the replies its server gives. */
#define SESSION "session:s"
#define BLOCK "block:b"
#define ON_BLOCK "{\"session_id\":\"" SESSION "\",\"block_id\":\"" BLOCK "\""

/* The request numbered NUMBER that the core sent on ID last, which must be
   METHOD with PAYLOAD; and answer it with RESULT, a JSON object, or an
   error with MESSAGE when RESULT is NULL. */
static bool asked(uint64_t id, int number, const char *method, const char *payload)
{
    char expected[2048];
    snprintf(expected, sizeof expected,
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":\"%s\",\"payload\":%s}", number,
             method, payload);
    return is_text(portal_fake_socket_sent(id), expected);
}

static void answer_with(uint64_t id, int number, const char *result, const char *message)
{
    char response[4096];
    if (result)
        snprintf(response, sizeof response,
                 "{\"type\":\"response\",\"id\":\"%d\",\"seq\":0,\"payload\":%s}", number, result);
    else
        snprintf(response, sizeof response,
                 "{\"type\":\"response\",\"id\":\"%d\",\"seq\":0,\"error\":{\"code\":\"conflict\","
                 "\"message\":\"%s\",\"status\":409}}",
                 number, message);
    portal_fake_socket_deliver(id, response);
}

/* A fed terminal, placed at 800 by 480: 100 by 30 cells of 8 by 16. */
static char *fed_terminal(portal_text *error)
{
    portal_option fed = {.name = text("fed"), .flag = true};
    portal_text target = {0};
    if (!portal_views_open(text("terminal"), &fed, 1, &target, error))
        return NULL;
    CHECK(portal_views_place(text(target.data), (portal_edges) {0, 0, 800, 480}, text("frame"),
                             error));
    return target.data;
}

/* What TARGET's description says of its block, from its "rex" member on. */
static const char *rex_state(const char *target)
{
    static char state[512];
    char *json = inspect(target);
    const char *found = json ? strstr(json, "\"rex\":") : NULL;
    snprintf(state, sizeof state, "%s", found ? found : "");
    char *end = strchr(state, '}');
    if (end)
        end[1] = '\0';
    free(json);
    return state;
}

static const unsigned char welcome[32] = {0x81, [20] = 0x10, 0x27, [24] = 42};

static void test_showing(void)
{
    portal_text error = {0};
    char record[64];
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    char *target = fed_terminal(&error);
    snprintf(record, sizeof record, "rex-block %s\n", target);
    /* Attach, claim, then wait for the grid to settle before sizing. */
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    CHECK(asked(id, 1, "session.attach", "{\"session_id\":\"" SESSION "\"}"));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"starting\",\"columns\":0,\"rows\":0}"));
    /* Emacs's own requests are numbered among the core's, and only their
       answers reach it. */
    CHECK(request(id, "session.list", "{}", &error) == 2);
    portal_fake_socket_sent(id);
    answer_with(id, 1, "{\"client_id\":\"client:1\",\"view\":{}}", NULL);
    CHECK(is_text(sent(), ""));
    CHECK(asked(id, 3, "session.own_block",
                "{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],\"mode\":\"take\"}"));
    answer_with(id, 2, "{\"sessions\":[]}", NULL);
    char lisp_record[32];
    snprintf(lisp_record, sizeof lisp_record, "rex %llu\n", (unsigned long long) id);
    CHECK(is_text(sent(), lisp_record));
    CHECK(is_text(received(id),
                  "{\"type\":\"response\",\"id\":\"2\",\"seq\":0,\"payload\":{\"sessions\":[]}}"));
    answer_with(id, 3, "{\"blocks\":[]}", NULL);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    CHECK(portal_fake_timers() == 1);
    /* A new grid meanwhile settles again: the first timer counts for
       nothing, and the block takes the new grid. */
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 640, 320}, text("frame"), &error));
    CHECK(portal_fake_timers() == 2);
    portal_fake_fire_timers();
    CHECK(asked(id, 4, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":80,\"rows\":20,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 4, "{}", NULL);
    CHECK(asked(id, 5, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    /* The ticket, base64url, opens the stream with a HELLO of its bytes. */
    answer_with(id, 5, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\",\"expires_in_ms\":30000}", NULL);
    uint64_t data = portal_fake_socket_last();
    CHECK(data > id);
    CHECK(is_text(portal_fake_socket_address(data),
                  "/tmp/rex/server.sock /api/data rex.data.terminal.v1 binary"));
    CHECK(is_text(portal_fake_socket_sent(data), "01000102030405060708090a0b0c0d0e0f"));
    /* WELCOME, nonce 42; then the snapshot, skipped whole, split anywhere,
       with the program's output and Rex's messages after it, split too. */
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, "GHOSTSNP\x01\x00\x01\x00\x03\x00", 14);
    portal_fake_socket_deliver_bytes(data, "\x00\x00\x00\x00\x00\x00", 6);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    static const char rest[] = "abc\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00hello \x1b_rex1;4";
    portal_fake_socket_deliver_bytes(data, rest, sizeof rest - 1);
    CHECK(asked(id, 6, "com.superlogical.terminal.format",
                ON_BLOCK ",\"args\":{\"format\":\"vt\",\"extra_charsets\":true,"
                         "\"extra_cursor\":true,\"extra_hyperlink\":true,\"extra_keyboard\":true,"
                         "\"extra_kitty_keyboard\":true,\"extra_modes\":true,"
                         "\"extra_palette\":true,\"extra_protection\":true,\"extra_pwd\":true,"
                         "\"extra_scrolling_region\":true,\"extra_style\":true,"
                         "\"extra_tabstops\":true,\"max_bytes\":983040}}"));
    portal_fake_socket_deliver(data, "2;{\"type\":\"resize\",\"cols\":80,\"rows\":20,\"owner\":null}"
                                     "\x1b\\world \x1b_rex1;7;{}\x1b\\\x1b");
    /* Held until the paint has gone. */
    CHECK(is_text(portal_fake_fed(target), ""));
    /* The paint, in two parts. */
    answer_with(id, 6, "{\"content\":\"\\u001b[HPAINT\",\"id\":9,\"total\":11,\"eof\":false}",
                NULL);
    CHECK(asked(id, 7, "com.superlogical.terminal.blob_read",
                ON_BLOCK ",\"args\":{\"id\":9,\"offset\":8,\"max_bytes\":983040}}"));
    CHECK(is_text(sent(), ""));
    answer_with(id, 7, "{\"id\":9,\"data\":\"-MORE\",\"total\":11,\"eof\":true}", NULL);
    CHECK(is_text(portal_fake_fed(target), "\x1b[HPAINT-MORE" "hello world \x1b_rex1;7;{}\x1b\\"));
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"live\",\"columns\":80,\"rows\":20}"));
    /* Live: the ESC held back starts no message after all. */
    portal_fake_socket_deliver(data, "[c\x1b_rex1;42;{\"type\":\"resize\",\"cols\":81,\"rows\":21}\x1b\\!");
    CHECK(is_text(portal_fake_fed(target),
                  "\x1b[HPAINT-MORE" "hello world \x1b_rex1;7;{}\x1b\\\x1b[c!"));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"live\",\"columns\":81,\"rows\":21}"));
    /* The server ends the stream: the block has closed. */
    portal_fake_socket_end(data, "The server closed the connection (4000: block closed)");
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target),
                  "\"rex\":{\"state\":\"ended\",\"columns\":81,\"rows\":21,\"reason\":\"The block's "
                  "stream ended: The server closed the connection (4000: block closed)\"}"));
    CHECK(!*portal_fake_socket_address(data));
    /* Its last screen stays, and takes no typing. */
    portal_terminal_input(text(target), "rm -rf x\r", 9);
    portal_input_focus(text(target), true);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    sent(); /* The focus record. */
    CHECK(portal_views_close(text(target), &error));
    free(target);

    /* A second terminal in the same session: the connection is attached. */
    target = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    CHECK(asked(id, 8, "session.own_block",
                "{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],\"mode\":\"take\"}"));
    /* One terminal per block and block per terminal. */
    char *other = fed_terminal(&error);
    CHECK(!portal_rex_show(id, text(other), text(SESSION), text(BLOCK), &error));
    CHECK(says(&error, "The block is shown already: " BLOCK));
    CHECK(!portal_rex_show(id, text(target), text(SESSION), text("block:c"), &error));
    char message[96];
    snprintf(message, sizeof message, "A block is shown already in %s", target);
    CHECK(says(&error, message));
    /* A refusal fails the show, which Emacs hears of. */
    snprintf(record, sizeof record, "rex-block %s\n", target);
    answer_with(id, 8, NULL, "not yours");
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,"
                                     "\"reason\":\"session.own_block: not yours\"}"));
    CHECK(portal_views_close(text(target), &error));
    free(target);
    /* Only a fed terminal shows a block. */
    char *plain = open_view("terminal", &error, "directory", "/tmp", NULL);
    CHECK(!portal_rex_show(id, text(plain), text(SESSION), text(BLOCK), &error));
    snprintf(message, sizeof message, "No fed terminal %s", plain);
    CHECK(says(&error, message));
    CHECK(portal_views_close(text(plain), &error));
    free(plain);
    /* A REJECT fails it. */
    CHECK(portal_rex_show(id, text(other), text(SESSION), text(BLOCK), &error));
    answer_with(id, 9, "{}", NULL);
    portal_fake_fire_timers();
    answer_with(id, 10, "{}", NULL);
    answer_with(id, 11, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    portal_fake_socket_sent(id);
    data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, "\x82\x01", 2);
    CHECK(is_text(rex_state(other), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,"
                                    "\"reason\":\"The server refused the block's stream: reason 0x01\"}"));
    CHECK(!*portal_fake_socket_address(data));
    CHECK(portal_views_close(text(other), &error));
    free(other);
    /* The connection's end ends what it shows. */
    other = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(other), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_end(id, "The connection to the server was lost");
    CHECK(is_text(rex_state(other), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,"
                                    "\"reason\":\"The connection to the server ended\"}"));
    CHECK(is_text(received(id), "ended: The connection to the server was lost"));
    CHECK(!portal_rex_show(id, text(other), text(SESSION), text("block:c"), &error));
    CHECK(error.data != NULL);
    free(error.data);
    CHECK(portal_views_close(text(other), &error));
    free(other);
    sent();
}

static void test_typing(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    char *target = fed_terminal(&error);
    /* Typing goes from the start, before the paint. */
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_sent(id);
    portal_terminal_input(text(target), "a", 1);
    CHECK(asked(id, 2, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"a\"}}"));
    /* One write at a time, the next joining what came meanwhile, and the
       terminal's own reports dropped. */
    portal_terminal_input(text(target), "b", 1);
    portal_terminal_input(text(target), "\x1b[I", 3);
    portal_terminal_input(text(target), "\x1b[48;20;80;320;640t", 19);
    portal_terminal_input(text(target), "\x1b[?997;2n", 9);
    portal_terminal_input(text(target), "c\x85\xe2\x82\xac", 5);
    portal_input_focus(text(target), true);
    portal_terminal_input(text(target), "\x1b[48;20t", 8);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    answer_with(id, 2, "{\"bytes_written\":1}", NULL);
    CHECK(asked(id, 3, "com.superlogical.terminal.write",
                ON_BLOCK ",\"args\":{\"data\":\"bc\xef\xbf\xbd\xe2\x82\xac\"}}"));
    answer_with(id, 3, NULL, "refused");
    /* Focus as a block event, in its place among the writes. */
    CHECK(asked(id, 4, "block.event",
                ON_BLOCK ",\"event\":{\"type\":\"focus\",\"payload\":{\"action\":\"in\"}}}"));
    answer_with(id, 4, "{}", NULL);
    CHECK(asked(id, 5, "com.superlogical.terminal.write",
                ON_BLOCK ",\"args\":{\"data\":\"\\u001b[48;20t\"}}"));
    /* The attach comes back meanwhile; the show goes on. */
    answer_with(id, 1, "{}", NULL);
    CHECK(asked(id, 6, "session.own_block",
                "{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],\"mode\":\"take\"}"));
    answer_with(id, 5, "{}", NULL);
    answer_with(id, 6, "{}", NULL);
    portal_fake_fire_timers();
    CHECK(asked(id, 7, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":100,\"rows\":30,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 7, "{}", NULL);
    portal_fake_socket_sent(id);
    answer_with(id, 8, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    uint64_t data = portal_fake_socket_last();
    CHECK(data > id);
    /* Once sized, a new grid resizes the block, the latest of several. */
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 400, 160}, text("frame"), &error));
    CHECK(asked(id, 9, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":50,\"rows\":10,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 480, 160}, text("frame"), &error));
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 560, 160}, text("frame"), &error));
    portal_terminal_input(text(target), "d", 1);
    answer_with(id, 9, "{}", NULL);
    CHECK(asked(id, 10, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":70,\"rows\":10,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 10, "{}", NULL);
    CHECK(asked(id, 11, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"d\"}}"));
    /* The stream ends while a write is out: what was typed after it is
       dropped, not sent once the write is answered. */
    portal_terminal_input(text(target), "e", 1);
    answer_with(id, 11, "{}", NULL);
    CHECK(asked(id, 12, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"e\"}}"));
    portal_terminal_input(text(target), "f", 1);
    portal_fake_socket_end(data, "The server closed the connection (1001: keepalive timeout)");
    answer_with(id, 12, "{}", NULL);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    /* Closing the terminal stops its typing. */
    CHECK(portal_views_close(text(target), &error));
    portal_terminal_input(text(target), "g", 1);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    CHECK(is_text(received(id), ""));
    free(target);
    CHECK(portal_rex_close(id, &error));
    sent();
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
    test_json();
    test_showing();
    test_typing();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Rex connections passed");
    return 0;
}
