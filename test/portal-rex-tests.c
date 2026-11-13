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
    /* A connection the server ends for good hands over its last messages
       with the reason, and is gone: its socket is closed and its ID names
       nothing. */
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    snprintf(record, sizeof record, "rex %llu\n", (unsigned long long) id);
    snprintf(gone, sizeof gone, "No Rex connection %llu", (unsigned long long) id);
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\"}");
    portal_fake_socket_closed(id, 1008, "The server closed the connection (1008: no common API revision)");
    CHECK(is_text(sent(), record));
    CHECK(portal_fake_sockets() == 1);
    CHECK(is_text(received(id), "{\"type\":\"welcome\"}\nended: The server closed the connection "
                                "(1008: no common API revision)"));
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
    /* An array's elements, by index. */
    CHECK(portal_json_element(text(" [ 1 , {\"a\":[2]} ,\"]\" ] "), 1, &value));
    CHECK(value.length == 9 && !memcmp(value.data, "{\"a\":[2]}", 9));
    CHECK(portal_json_element(text("[1,{\"a\":[2]},\"]\"]"), 2, &value));
    CHECK(portal_json_is(value, "]"));
    CHECK(!portal_json_element(text("[1,2]"), 2, &value));
    CHECK(!portal_json_element(text("[]"), 0, &value));
    CHECK(!portal_json_element(text("[1,"), 1, &value));
    CHECK(!portal_json_element(text("{\"a\":1}"), 0, &value));
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

/* The claim of the block numbered NUMBER, a request, and the three
   questions about its terminal that follow it, the last thing the core
   sent on ID. */
static bool claimed(uint64_t id, int number)
{
    char expected[2048];
    snprintf(expected, sizeof expected,
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":\"session.own_block\","
             "\"payload\":{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],"
             "\"mode\":\"request\"}}\n"
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":"
             "\"com.superlogical.terminal.title\",\"payload\":" ON_BLOCK ",\"args\":{}}}\n"
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":"
             "\"com.superlogical.terminal.pwd\",\"payload\":" ON_BLOCK ",\"args\":{}}}\n"
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":"
             "\"com.superlogical.terminal.process\",\"payload\":" ON_BLOCK ",\"args\":{}}}",
             number, number + 1, number + 2, number + 3);
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
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"starting\",\"columns\":0,\"rows\":0,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\"}"));
    /* Emacs's own requests are numbered among the core's, and only their
       answers reach it. */
    CHECK(request(id, "session.list", "{}", &error) == 2);
    portal_fake_socket_sent(id);
    answer_with(id, 1, "{\"client_id\":\"client:1\",\"view\":{}}", NULL);
    CHECK(is_text(sent(), ""));
    CHECK(claimed(id, 3));
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
    CHECK(asked(id, 7, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":80,\"rows\":20,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 7, "{}", NULL);
    CHECK(asked(id, 8, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    /* The ticket, base64url, opens the stream with a HELLO of its bytes. */
    answer_with(id, 8, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\",\"expires_in_ms\":30000}", NULL);
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
    /* Without the server's palette: the terminal keeps its theme's.  Lines
       the terminal wrapped come unwrapped, so that the terminal wraps them
       again as the server does at the next resize. */
    CHECK(asked(id, 9, "com.superlogical.terminal.format",
                ON_BLOCK ",\"args\":{\"format\":\"vt\",\"extra_charsets\":true,"
                         "\"extra_cursor\":true,\"extra_hyperlink\":true,\"extra_keyboard\":true,"
                         "\"extra_kitty_keyboard\":true,\"extra_modes\":true,"
                         "\"extra_protection\":true,\"extra_pwd\":true,"
                         "\"extra_scrolling_region\":true,\"extra_style\":true,"
                         "\"extra_tabstops\":true,\"unwrap\":true,\"max_bytes\":983040}}"));
    portal_fake_socket_deliver(data, "2;{\"type\":\"resize\",\"cols\":80,\"rows\":20,\"owner\":null}"
                                     "\x1b\\world \x1b_rex1;7;{}\x1b\\\x1b");
    /* Held until the paint has gone. */
    CHECK(is_text(portal_fake_fed(target), ""));
    /* The paint, in two parts. */
    answer_with(id, 9, "{\"content\":\"\\u001b[HPAINT\",\"id\":9,\"total\":11,\"eof\":false}",
                NULL);
    CHECK(asked(id, 10, "com.superlogical.terminal.blob_read",
                ON_BLOCK ",\"args\":{\"id\":9,\"offset\":8,\"max_bytes\":983040}}"));
    CHECK(is_text(sent(), ""));
    answer_with(id, 10, "{\"id\":9,\"data\":\"-MORE\",\"total\":11,\"eof\":true}", NULL);
    /* The paint takes the block's grid, the last the stream gave. */
    CHECK(is_text(portal_fake_fed(target),
                  "<grid 80x20>\x1b[HPAINT-MORE" "hello world \x1b_rex1;7;{}\x1b\\"));
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"live\",\"columns\":80,\"rows\":20,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\"}"));
    /* Live: the ESC held back starts no message after all. */
    portal_fake_socket_deliver(data, "[c\x1b_rex1;42;{\"type\":\"resize\",\"cols\":81,\"rows\":21}\x1b\\!");
    /* A new grid takes its place in the stream; the same grid again is no
       change. */
    portal_fake_socket_deliver(data, "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":81,\"rows\":21}\x1b\\?");
    CHECK(is_text(portal_fake_fed(target), "<grid 80x20>\x1b[HPAINT-MORE"
                                           "hello world \x1b_rex1;7;{}\x1b\\\x1b[c<grid 81x21>!?"));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"live\",\"columns\":81,\"rows\":21,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\"}"));
    /* The server ends the stream: the block has closed. */
    portal_fake_socket_closed(data, 4000, "The server closed the connection (4000: block closed)");
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target),
                  "\"rex\":{\"state\":\"ended\",\"columns\":81,\"rows\":21,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\",\"reason\":\"The block's "
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
    CHECK(claimed(id, 11));
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
    answer_with(id, 11, NULL, "not yours");
    CHECK(is_text(sent(), record));
    CHECK(is_text(rex_state(target), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\","
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
    answer_with(id, 15, "{}", NULL);
    portal_fake_fire_timers();
    answer_with(id, 19, "{}", NULL);
    answer_with(id, 20, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    portal_fake_socket_sent(id);
    data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, "\x82\x01", 2);
    CHECK(is_text(rex_state(other), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\","
                                    "\"reason\":\"The server refused the block's stream: reason 0x01\"}"));
    CHECK(!*portal_fake_socket_address(data));
    CHECK(portal_views_close(text(other), &error));
    free(other);
    /* The connection's end ends what it shows. */
    other = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(other), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_end(id, "The connection to the server was lost");
    CHECK(is_text(rex_state(other), "\"rex\":{\"state\":\"failed\",\"columns\":0,\"rows\":0,\"owner\":\"unknown\",\"owner_name\":\"\",\"directory\":\"\","
                                    "\"reason\":\"The connection to the server ended\"}"));
    CHECK(is_text(received(id), "ended: The connection to the server was lost"));
    CHECK(!portal_rex_show(id, text(other), text(SESSION), text("block:c"), &error));
    CHECK(error.data != NULL);
    free(error.data);
    CHECK(portal_views_close(text(other), &error));
    free(other);
    sent();
}

/* The server's welcome to ID's client, client:me. */
static void welcome_me(uint64_t id)
{
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\",\"protocol\":\"rex.control.v1\","
                                   "\"client\":{\"id\":\"client:me\",\"reconnect_token\":\"t\"},"
                                   "\"api_revision\":12}");
    received(id);
    sent();
}

/* A take of the block, the last thing the core sent on ID, numbered NUMBER. */
static bool took(uint64_t id, int number)
{
    return asked(id, number, "session.own_block",
                 "{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],\"mode\":\"take\"}");
}

#define OWNED_BY(client) "{\"blocks\":[{\"block_id\":\"" BLOCK "\",\"owner\":\"" client "\"}]}"

static void test_typing(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    welcome_me(id);
    char *target = fed_terminal(&error);
    /* Typing waits for the claim, as nothing reaches a block before the
       session is attached. */
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_sent(id);
    portal_terminal_input(text(target), "a", 1);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    /* What is typed meanwhile joins it, and the terminal's own reports are
       dropped. */
    portal_terminal_input(text(target), "b", 1);
    portal_terminal_input(text(target), "\x1b[I", 3);
    portal_terminal_input(text(target), "\x1b[48;20;80;320;640t", 19);
    portal_terminal_input(text(target), "\x1b[?997;2n", 9);
    portal_terminal_input(text(target), "c\x85\xe2\x82\xac", 5);
    portal_input_focus(text(target), true);
    portal_terminal_input(text(target), "\x1b[48;20t", 8);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    answer_with(id, 1, "{}", NULL);
    CHECK(claimed(id, 2));
    /* Another client owns the block: Emacs asks what it is called, and
       typing takes the block first, once. */
    answer_with(id, 2, OWNED_BY("client:app"), NULL);
    CHECK(is_text(portal_fake_socket_sent(id),
                  "{\"type\":\"request\",\"id\":\"6\",\"method\":\"client.inspect\","
                  "\"payload\":{\"client_id\":\"client:app\"}}\n"
                  "{\"type\":\"request\",\"id\":\"7\",\"method\":\"session.own_block\","
                  "\"payload\":{\"session_id\":\"" SESSION "\",\"block_ids\":[\"" BLOCK "\"],"
                  "\"mode\":\"take\"}}"));
    answer_with(id, 7, OWNED_BY("client:me"), NULL);
    CHECK(asked(id, 8, "com.superlogical.terminal.write",
                ON_BLOCK ",\"args\":{\"data\":\"abc\xef\xbf\xbd\xe2\x82\xac\"}}"));
    answer_with(id, 8, NULL, "refused");
    /* Focus as a block event, in its place among the writes. */
    CHECK(asked(id, 9, "block.event",
                ON_BLOCK ",\"event\":{\"type\":\"focus\",\"payload\":{\"action\":\"in\"}}}"));
    answer_with(id, 9, "{}", NULL);
    CHECK(asked(id, 10, "com.superlogical.terminal.write",
                ON_BLOCK ",\"args\":{\"data\":\"\\u001b[48;20t\"}}"));
    answer_with(id, 10, "{}", NULL);
    /* The pane's grid settles and goes to the server. */
    portal_fake_fire_timers();
    CHECK(asked(id, 11, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":100,\"rows\":30,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 11, "{}", NULL);
    portal_fake_socket_sent(id);
    answer_with(id, 12, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    uint64_t data = portal_fake_socket_last();
    CHECK(data > id);
    /* Once sized, a new grid resizes the block, the latest of several. */
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 400, 160}, text("frame"), &error));
    CHECK(asked(id, 13, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":50,\"rows\":10,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 480, 160}, text("frame"), &error));
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 560, 160}, text("frame"), &error));
    portal_terminal_input(text(target), "d", 1);
    answer_with(id, 13, "{}", NULL);
    CHECK(asked(id, 14, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":70,\"rows\":10,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    answer_with(id, 14, "{}", NULL);
    CHECK(asked(id, 15, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"d\"}}"));
    /* The stream ends while a write is out: what was typed after it is
       dropped, not sent once the write is answered. */
    portal_terminal_input(text(target), "e", 1);
    answer_with(id, 15, "{}", NULL);
    CHECK(asked(id, 16, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"e\"}}"));
    portal_terminal_input(text(target), "f", 1);
    portal_fake_socket_closed(data, 1000, "The server closed the connection (1000)");
    answer_with(id, 16, "{}", NULL);
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

/* An event of BLOCK at SEQ: the block event NAME of a terminal, with
   FIELDS, a JSON object. */
static void block_event(uint64_t id, int seq, const char *block, const char *name,
                        const char *fields)
{
    char event[2048];
    snprintf(event, sizeof event,
             "{\"type\":\"event\",\"seq\":%d,\"payload\":{\"type\":\"session_event\",\"payload\":"
             "{\"session_id\":\"" SESSION "\",\"event\":{\"type\":\"block_event\",\"payload\":"
             "{\"block_id\":\"%s\",\"creator_name\":\"com.superlogical.terminal\",\"name\":\"%s\","
             "\"payload\":%s}}}}}",
             seq, block, name, fields);
    portal_fake_socket_deliver(id, event);
}

/* Answer request NUMBER on ID with RESULT, written at SEQ. */
static void answer_at(uint64_t id, int number, int seq, const char *result)
{
    char response[2048];
    snprintf(response, sizeof response,
             "{\"type\":\"response\",\"id\":\"%d\",\"seq\":%d,\"payload\":%s}", number, seq, result);
    portal_fake_socket_deliver(id, response);
}

/* What TARGET describes of its block's program: from its "title" to its
   "rex" member. */
static const char *details(const char *target)
{
    static char found[1024];
    char *json = inspect(target);
    const char *start = json ? strstr(json, "\"title\":") : NULL;
    const char *end = start ? strstr(start, ",\"rex\":") : NULL;
    snprintf(found, sizeof found, "%.*s", end ? (int) (end - start) : 0, start ? start : "");
    free(json);
    return found;
}

static void test_details(void)
{
    portal_text error = {0};
    char terminal[64], lisp[32], both[96], url[512], expected[512], host[256] = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    snprintf(lisp, sizeof lisp, "rex %llu\n", (unsigned long long) id);
    char *target = fed_terminal(&error);
    snprintf(terminal, sizeof terminal, "terminal %s\n", target);
    snprintf(both, sizeof both, "%s%s", terminal, lisp);
    /* A fed terminal describes nothing of a program until it shows a block. */
    char *json = inspect(target);
    CHECK(json && !strstr(json, "\"title\"") && !strstr(json, "\"exited\""));
    free(json);
    /* Claiming the block asks what its terminal reports. */
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_sent(id);
    answer_with(id, 1, "{}", NULL);
    CHECK(claimed(id, 2));
    CHECK(is_text(details(target), "\"title\":\"\",\"pwd\":\"\",\"program\":\"\",\"exited\":false"));
    /* An event that overtakes an answer wins; Emacs gets the event too. */
    block_event(id, 5, BLOCK, "title_changed", "{\"title\":\"vim: notes\",\"owner\":{}}");
    CHECK(is_text(sent(), both));
    CHECK(strstr(received(id), "\"name\":\"title_changed\"") != NULL);
    /* One record waits until the terminal is described. */
    block_event(id, 6, "block:c", "title_changed", "{\"title\":\"x\"}");
    CHECK(is_text(sent(), lisp));
    received(id);
    CHECK(strstr(details(target), "\"title\":\"vim: notes\"") != NULL);
    answer_at(id, 3, 4, "{\"title\":\"older\"}");
    CHECK(is_text(sent(), ""));
    /* The reported directory, percent-decoded, wins over the process's. */
    answer_at(id, 4, 4, "{\"pwd\":\"file://localhost/tmp/a%20b\"}");
    answer_at(id, 5, 4, "{\"foreground\":{\"pid\":7,\"name\":\"zsh\",\"argv0\":\"-zsh\","
                        "\"cwd\":\"/private/tmp/a b\"},\"last_exit\":null}");
    CHECK(is_text(sent(), terminal));
    CHECK(is_text(details(target), "\"title\":\"vim: notes\",\"pwd\":\"/tmp/a b\","
                                   "\"program\":\"zsh\",\"exited\":false"));
    CHECK(strstr(rex_state(target), "\"directory\":\"/tmp/a b\"") != NULL);
    /* A program is labelled as Rex does: script, argv0, name. */
    block_event(id, 7, BLOCK, "process_changed",
                "{\"generation\":3,\"foreground\":{\"name\":\"node\",\"argv0\":\"node\","
                "\"script\":\"/opt/tool.js\",\"cwd\":\"/opt\"}}");
    CHECK(is_text(sent(), both));
    received(id);
    CHECK(is_text(details(target), "\"title\":\"vim: notes\",\"pwd\":\"/tmp/a b\","
                                   "\"program\":\"/opt/tool.js\",\"exited\":false"));
    /* A directory from another host, as from ssh, is not this Mac's; one
       named for this Mac is. */
    block_event(id, 8, BLOCK, "pwd_changed", "{\"pwd\":\"file://elsewhere.example/srv\"}");
    CHECK(is_text(sent(), lisp));
    received(id);
    CHECK(gethostname(host, sizeof host - 1) == 0);
    snprintf(url, sizeof url, "{\"pwd\":\"file://%s/Users/me%%2Fx\"}", host);
    block_event(id, 9, BLOCK, "pwd_changed", url);
    CHECK(is_text(sent(), both));
    received(id);
    CHECK(strstr(details(target), "\"pwd\":\"/Users/me/x\"") != NULL);
    /* Another block's events, or another kind of block's, change nothing. */
    block_event(id, 10, "block:c", "title_changed", "{\"title\":\"other\"}");
    CHECK(is_text(sent(), lisp));
    received(id);
    portal_fake_socket_deliver(id, "{\"type\":\"event\",\"seq\":11,\"payload\":{\"type\":"
                                   "\"session_event\",\"payload\":{\"session_id\":\"" SESSION
                                   "\",\"event\":{\"type\":\"block_event\",\"payload\":{\"block_id\":"
                                   "\"" BLOCK "\",\"creator_name\":\"com.example.other\",\"name\":"
                                   "\"title_changed\",\"payload\":{\"title\":\"other\"}}}}}}");
    CHECK(is_text(sent(), lisp));
    received(id);
    CHECK(strstr(details(target), "\"title\":\"vim: notes\"") != NULL);
    /* A program that exits, in a block that stays: said once the block
       has had its moment to close, with no program. */
    block_event(id, 12, BLOCK, "child_exited", "{\"exit_code\":0}");
    CHECK(is_text(sent(), lisp));
    received(id);
    CHECK(strstr(details(target), "\"exited\":false") != NULL);
    CHECK(portal_fake_timers() == 1);
    portal_fake_fire_timers();
    CHECK(is_text(sent(), terminal));
    snprintf(expected, sizeof expected,
             "\"title\":\"vim: notes\",\"pwd\":\"/Users/me/x\",\"program\":\"\",\"exited\":true");
    CHECK(is_text(details(target), expected));
    /* No later process brings a program back. */
    block_event(id, 13, BLOCK, "process_changed", "{\"foreground\":null}");
    CHECK(is_text(details(target), expected));
    received(id);
    sent();
    CHECK(portal_views_close(text(target), &error));
    free(target);

    /* A block whose program exits and which closes never says it exited,
       nor that its stream ended, before it has had its moment. */
    target = fed_terminal(&error);
    snprintf(terminal, sizeof terminal, "terminal %s\n", target);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    CHECK(claimed(id, 6));
    answer_at(id, 9, 13, "{\"foreground\":{\"name\":\"sh\",\"cwd\":\"/\"},\"last_exit\":null}");
    CHECK(is_text(sent(), terminal));
    CHECK(is_text(details(target), "\"title\":\"\",\"pwd\":\"/\",\"program\":\"sh\",\"exited\":false"));
    block_event(id, 14, BLOCK, "child_exited", "{\"exit_code\":3,\"error\":\"exit status 3\"}");
    portal_fake_socket_deliver(id, "{\"type\":\"event\",\"seq\":15,\"payload\":{\"type\":"
                                   "\"session_event\",\"payload\":{\"session_id\":\"" SESSION
                                   "\",\"event\":{\"type\":\"block_closed\",\"payload\":"
                                   "{\"block_id\":\"" BLOCK "\"}}}}}");
    portal_fake_socket_end(id, "The connection to the server was lost");
    CHECK(is_text(sent(), lisp));
    snprintf(expected, sizeof expected, "rex-block %s\n", target);
    portal_fake_fire_timers();
    CHECK(is_text(sent(), expected));
    CHECK(is_text(details(target), "\"title\":\"\",\"pwd\":\"/\",\"program\":\"sh\",\"exited\":false"));
    CHECK(portal_views_close(text(target), &error));
    free(target);
    received(id);
}

/* An event at SEQ on ID: BLOCK's owner is now OWNER, or no client for NULL. */
static void owner_changed(uint64_t id, int seq, const char *owner)
{
    char event[1024], field[128] = "";
    if (owner)
        snprintf(field, sizeof field, "\"owner\":\"%s\",", owner);
    snprintf(event, sizeof event,
             "{\"type\":\"event\",\"seq\":%d,\"payload\":{\"type\":\"session_event\",\"payload\":"
             "{\"session_id\":\"" SESSION "\",\"event\":{\"type\":\"block_owner_changed\","
             "\"payload\":{\"block_id\":\"" BLOCK "\",%s\"previous\":\"client:x\","
             "\"reason\":\"take\"}}}}}",
             seq, field);
    portal_fake_socket_deliver(id, event);
}

/* What TARGET's description says of its block's owner. */
static const char *owner_of(const char *target)
{
    static char found[256];
    const char *state = rex_state(target), *start = strstr(state, "\"owner\":");
    const char *end = start ? strstr(start, ",\"directory\"") : NULL;
    snprintf(found, sizeof found, "%.*s", end ? (int) (end - start) : 0, start ? start : "");
    return found;
}

static void test_owning(void)
{
    portal_text error = {0};
    char terminal[64], lisp[32], both[96];
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    welcome_me(id);
    snprintf(lisp, sizeof lisp, "rex %llu\n", (unsigned long long) id);
    char *target = fed_terminal(&error);
    snprintf(terminal, sizeof terminal, "terminal %s\n", target);
    snprintf(both, sizeof both, "%s%s", terminal, lisp);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    portal_fake_socket_sent(id);
    CHECK(is_text(owner_of(target), "\"owner\":\"unknown\",\"owner_name\":\"\""));
    /* A take waits for the show's own claim, and one waiting stands for
       the next. */
    CHECK(portal_rex_take(text(target), &error));
    CHECK(portal_rex_take(text(target), &error));
    answer_with(id, 1, "{}", NULL);
    CHECK(claimed(id, 2));
    answer_with(id, 2, "{\"blocks\":[{\"block_id\":\"block:c\",\"owner\":\"client:x\"},"
                       "{\"block_id\":\"" BLOCK "\"}]}",
                NULL);
    CHECK(is_text(sent(), terminal));
    CHECK(is_text(owner_of(target), "\"owner\":\"none\",\"owner_name\":\"\""));
    CHECK(took(id, 6));
    /* A take unanswered stands for another. */
    CHECK(portal_rex_take(text(target), &error));
    answer_with(id, 6, OWNED_BY("client:me"), NULL);
    CHECK(is_text(sent(), terminal));
    CHECK(is_text(owner_of(target), "\"owner\":\"self\",\"owner_name\":\"\""));
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    /* Typing into a block Emacs owns takes nothing. */
    portal_terminal_input(text(target), "x", 1);
    CHECK(asked(id, 7, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"x\"}}"));
    /* Another client takes it: Emacs hears, and asks what it is called. */
    owner_changed(id, 5, "client:app");
    CHECK(is_text(sent(), both));
    received(id);
    CHECK(is_text(owner_of(target), "\"owner\":\"other\",\"owner_name\":\"\""));
    CHECK(asked(id, 8, "client.inspect", "{\"client_id\":\"client:app\"}"));
    answer_with(id, 8, "{\"client\":{\"client_id\":\"client:app\",\"info\":{\"kind\":\"app\","
                       "\"name\":\"Rex.app\"}}}",
                NULL);
    CHECK(is_text(sent(), terminal));
    CHECK(is_text(owner_of(target), "\"owner\":\"other\",\"owner_name\":\"Rex.app\""));
    /* An older word changes nothing. */
    owner_changed(id, 4, "client:me");
    CHECK(is_text(sent(), lisp));
    received(id);
    CHECK(is_text(owner_of(target), "\"owner\":\"other\",\"owner_name\":\"Rex.app\""));
    /* The pane's grid still goes to the server, as Emacs's size for when
       it owns the block again. */
    portal_fake_fire_timers();
    CHECK(asked(id, 9, "com.superlogical.terminal.resize",
                ON_BLOCK ",\"args\":{\"columns\":100,\"rows\":30,\"cell_width_px\":8,"
                         "\"cell_height_px\":16}}"));
    /* A key typed now takes the block back first, after the write out. */
    portal_terminal_input(text(target), "y", 1);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    answer_with(id, 7, "{}", NULL);
    CHECK(took(id, 10));
    owner_changed(id, 6, "client:me");
    CHECK(is_text(sent(), both));
    received(id);
    CHECK(is_text(owner_of(target), "\"owner\":\"self\",\"owner_name\":\"\""));
    answer_at(id, 10, 6, OWNED_BY("client:me"));
    CHECK(asked(id, 11, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"y\"}}"));
    answer_with(id, 11, "{}", NULL);
    /* A client named by its label; one that has left is not named. */
    owner_changed(id, 7, "client:phone");
    CHECK(asked(id, 12, "client.inspect", "{\"client_id\":\"client:phone\"}"));
    answer_with(id, 12, "{\"client\":{\"client_id\":\"client:phone\",\"info\":{\"label\":\"iPhone\","
                        "\"name\":\"Rex\"}}}",
                NULL);
    CHECK(is_text(owner_of(target), "\"owner\":\"other\",\"owner_name\":\"iPhone\""));
    owner_changed(id, 8, "client:gone");
    CHECK(asked(id, 13, "client.inspect", "{\"client_id\":\"client:gone\"}"));
    answer_with(id, 13, NULL, "client not found");
    CHECK(is_text(owner_of(target), "\"owner\":\"other\",\"owner_name\":\"\""));
    CHECK(strstr(rex_state(target), "\"state\":\"starting\"") != NULL);
    /* A name that comes after its client lost the block names nothing. */
    owner_changed(id, 9, "client:app");
    owner_changed(id, 10, NULL);
    answer_with(id, 14, "{\"client\":{\"client_id\":\"client:app\",\"info\":{\"name\":\"Rex.app\"}}}",
                NULL);
    CHECK(is_text(owner_of(target), "\"owner\":\"none\",\"owner_name\":\"\""));
    received(id);
    sent();
    /* Only a terminal that shows a block takes one. */
    CHECK(!portal_rex_take(text("terminal:none"), &error));
    CHECK(says(&error, "No block is shown in terminal:none"));
    CHECK(portal_views_close(text(target), &error));
    CHECK(!portal_rex_take(text(target), &error));
    free(error.data);
    free(target);
    CHECK(portal_rex_close(id, &error));
    sent();
}

/* Whether the last thing the core sent on ID is the first paint's request,
   numbered NUMBER. */
static bool paint_asked(uint64_t id, int number)
{
    char expected[96];
    snprintf(expected, sizeof expected,
             "{\"type\":\"request\",\"id\":\"%d\",\"method\":\"com.superlogical.terminal.format\"",
             number);
    const char *got = portal_fake_socket_sent(id);
    if (strncmp(got, expected, strlen(expected)) || strchr(got, '\n')) {
        fprintf(stderr, "Expected a paint request %d, got \"%s\"\n", number, got);
        return false;
    }
    return true;
}

static void test_resizing_while_painting(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    welcome_me(id);
    char *target = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    answer_with(id, 1, "{}", NULL);
    answer_with(id, 2, OWNED_BY("client:app"), NULL);
    portal_fake_fire_timers();
    answer_with(id, 7, "{}", NULL);
    answer_with(id, 8, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    portal_fake_socket_sent(id);
    uint64_t data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    /* The snapshot, then the stream's first resize, which says the grid
       the paint is for, and output. */
    static const char snapshot[] = "GHOSTSNP\x01\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    CHECK(paint_asked(id, 9));
    portal_fake_socket_deliver(data, "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":60,\"rows\":15}\x1b\\early ");
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    /* The same grid again changes nothing. */
    portal_fake_socket_deliver(data, "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":60,\"rows\":15}\x1b\\still ");
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    /* Another client resizes the block before the paint comes: output on
       either side of it is laid out for a different grid, so the paint is
       asked for again, and only output after the resize waits for it. */
    portal_fake_socket_deliver(data, "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":90,\"rows\":25}\x1b\\late");
    CHECK(paint_asked(id, 10));
    /* The first paint, answered late, is not drawn; nor are its parts. */
    answer_with(id, 9, "{\"content\":\"OLD\",\"id\":1,\"total\":9,\"eof\":false}", NULL);
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    CHECK(is_text(portal_fake_fed(target), ""));
    answer_with(id, 10, "{\"content\":\"NEW \"}", NULL);
    CHECK(is_text(portal_fake_fed(target), "<grid 90x25>NEW late"));
    CHECK(strstr(rex_state(target), "\"state\":\"live\",\"columns\":90,\"rows\":25") != NULL);
    sent();
    received(id);
    CHECK(portal_views_close(text(target), &error));
    free(target);

    /* A paint that comes before the stream's grid waits for it: the paint
       arrives on the control connection, the grid on the stream. */
    target = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    answer_with(id, 11, OWNED_BY("client:app"), NULL);
    portal_fake_fire_timers();
    answer_with(id, 16, "{}", NULL);
    answer_with(id, 17, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    portal_fake_socket_sent(id);
    data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    CHECK(paint_asked(id, 18));
    answer_with(id, 18, "{\"content\":\"PAINT \"}", NULL);
    CHECK(is_text(portal_fake_fed(target), ""));
    CHECK(strstr(rex_state(target), "\"state\":\"starting\"") != NULL);
    portal_fake_socket_deliver(data, "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":60,\"rows\":15}\x1b\\after");
    CHECK(is_text(portal_fake_fed(target), "<grid 60x15>PAINT after"));
    CHECK(strstr(rex_state(target), "\"state\":\"live\",\"columns\":60,\"rows\":15") != NULL);
    sent();
    received(id);
    CHECK(portal_views_close(text(target), &error));
    free(target);
    CHECK(portal_rex_close(id, &error));
    sent();
}

/* What was fed to TARGET since the last call for it. */
static const char *fresh(const char *target)
{
    static char last[64];
    static size_t seen;
    const char *all = portal_fake_fed(target);
    size_t length = strlen(all);
    if (strcmp(last, target) || seen > length) {
        snprintf(last, sizeof last, "%s", target);
        seen = 0;
    }
    const char *rest = all + seen;
    seen = length;
    return rest;
}

/* A WELCOME whose token is TOKEN in every byte, with the nonce 42. */
static void welcome_with(unsigned char bytes[static 32], unsigned char token)
{
    memcpy(bytes, welcome, 32);
    memset(bytes + 1, token, 16);
}

/* The snapshot a stream starts with: no records but the last; and the
   grid message that follows it, which the first paint waits for. */
static const char snapshot[] = "GHOSTSNP\x01\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00";
static const char grid_message[] = "\x1b_rex1;42;{\"type\":\"resize\",\"cols\":80,\"rows\":24}\x1b\\";

/* How many bytes a stream has taken once it is live, and COUNT more. */
#define TAKEN(count) (sizeof snapshot - 1 + sizeof grid_message - 1 + (count))

/* What show_on's claim is answered with: who owns the block; and what
   its terminal was fed. */
static const char *claim_answer = "{}";
static char show_fed[256];

/* Show the block in TARGET on connection ID, whose socket is now CONTROL
   and whose next request is numbered NUMBER, unless the show has STARTED
   already, and which attaches to its session if ATTACH; until it is live,
   painted with PAINT; return its stream's socket.  *NUMBER is the next
   request's number after it. */
static uint64_t show_on(uint64_t id, uint64_t control, const char *target, int *number,
                        bool started, bool attach, const char *paint)
{
    portal_text error = {0};
    char content[256];
    if (!started) {
        portal_fake_socket_sent(control);
        CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    }
    if (attach) {
        if (!started)
            CHECK(asked(control, *number, "session.attach", "{\"session_id\":\"" SESSION "\"}"));
        answer_with(control, (*number)++, "{}", NULL);
    }
    CHECK(claimed(control, *number));
    answer_with(control, *number, claim_answer, NULL);
    *number += 4;
    portal_fake_fire_timers();
    answer_with(control, (*number)++, "{}", NULL);
    answer_with(control, (*number)++, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    uint64_t data = portal_fake_socket_last();
    portal_fake_socket_sent(data);
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    portal_fake_socket_deliver(data, grid_message);
    snprintf(content, sizeof content, "{\"content\":\"%s\"}", paint);
    answer_with(control, (*number)++, content, NULL);
    portal_fake_socket_sent(control);
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    /* What the terminal was fed, its grid first unless it has it. */
    const char *fed = fresh(target);
    snprintf(show_fed, sizeof show_fed, "%s", fed);
    CHECK(strlen(fed) >= strlen(paint) && !strcmp(fed + strlen(fed) - strlen(paint), paint));
    sent();
    return data;
}

/* show_on, for a connection whose socket is its first. */
static uint64_t show_live(uint64_t id, const char *target, int *number, bool started,
                          bool attach, const char *paint)
{
    return show_on(id, id, target, number, started, attach, paint);
}

/* The RESUME a stream sends with the token TOKEN in every byte, having
   taken COUNT bytes, in hex. */
static const char *resume_hex(unsigned char token, uint64_t count)
{
    static char hex[64];
    size_t length = (size_t) snprintf(hex, sizeof hex, "02");
    for (int i = 0; i < 16; i++)
        length += (size_t) snprintf(hex + length, sizeof hex - length, "%02x", token);
    for (int i = 0; i < 8; i++)
        length += (size_t) snprintf(hex + length, sizeof hex - length, "%02x",
                                    (unsigned) (count >> (8 * i)) & 0xff);
    return hex;
}

static void test_backlog(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    int number = 1;
    char *target = fed_terminal(&error);
    uint64_t data = show_live(id, target, &number, false, true, "P");
    /* While the terminal has too much to parse, the stream waits unread. */
    portal_terminal_backlog(text(target), true);
    portal_fake_socket_deliver(data, "one ");
    portal_fake_socket_deliver(data, "two ");
    CHECK(is_text(fresh(target), ""));
    bool readable = false;
    CHECK(portal_socket_wait(data, 0, &readable, &error) && readable);
    /* Worked down, it is read where it stopped, in order. */
    portal_terminal_backlog(text(target), false);
    CHECK(is_text(fresh(target), "one two "));
    CHECK(portal_socket_wait(data, 0, &readable, &error) && !readable);
    portal_fake_socket_deliver(data, "three");
    CHECK(is_text(fresh(target), "three"));
    /* Its end waits too, and comes in its place, after the output. */
    portal_terminal_backlog(text(target), true);
    portal_fake_socket_deliver(data, "last");
    portal_fake_socket_closed(data, 1000, "The server closed the connection (1000)");
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    portal_terminal_backlog(text(target), false);
    CHECK(is_text(fresh(target), "last"));
    CHECK(strstr(rex_state(target), "\"state\":\"ended\"") != NULL);
    /* Another terminal's backlog, or none, changes nothing. */
    portal_terminal_backlog(text("terminal:none"), true);
    CHECK(portal_views_close(text(target), &error));
    free(target);
    CHECK(portal_rex_close(id, &error));
    sent();
}

static void test_resuming(void)
{
    portal_text error = {0};
    char record[64];
    unsigned char renewed[32];
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    int number = 1;
    char *target = fed_terminal(&error);
    snprintf(record, sizeof record, "rex-block %s\n", target);
    uint64_t data = show_live(id, target, &number, false, true, "P");
    portal_fake_socket_deliver(data, "abc");
    fresh(target);
    /* A stream that drops resumes on a new data connection with the
       WELCOME's token and the bytes taken: the snapshot and "abc". */
    portal_fake_socket_end(data, "The connection to the server was lost");
    CHECK(!*portal_fake_socket_address(data));
    uint64_t resumed = portal_fake_socket_last();
    CHECK(resumed > data);
    CHECK(is_text(portal_fake_socket_address(resumed),
                  "/tmp/rex/server.sock /api/data rex.data.terminal.v1 binary"));
    CHECK(is_text(portal_fake_socket_sent(resumed), resume_hex(0, TAKEN(3))));
    CHECK(is_text(portal_fake_socket_sent(id), ""));
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    /* Its WELCOME brings a new token, and the stream goes on where it was,
       a Rex message split across the drop included. */
    welcome_with(renewed, 7);
    portal_fake_socket_deliver_bytes(resumed, renewed, sizeof renewed);
    portal_fake_socket_deliver(resumed, "def\x1b_rex1;42;{\"type\":\"resize\",\"cols\":90,\"rows\":9}\x1b\\g");
    CHECK(is_text(fresh(target), "def<grid 90x9>g"));
    CHECK(strstr(rex_state(target), "\"columns\":90,\"rows\":9") != NULL);
    CHECK(is_text(sent(), ""));
    /* The server asks for a new stream (1013), as when it could hold no
       more: a new ticket, a HELLO, and a new paint, the terminal reset
       first, with no record meanwhile. */
    portal_fake_socket_closed(resumed, 1013, "The server closed the connection (1013: data reconnect required)");
    CHECK(asked(id, number, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    answer_with(id, number++, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    data = portal_fake_socket_last();
    CHECK(is_text(portal_fake_socket_sent(data), "01000102030405060708090a0b0c0d0e0f"));
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    portal_fake_socket_deliver(data, grid_message);
    portal_fake_socket_deliver(data, "h");
    portal_fake_socket_sent(id);
    answer_with(id, number++, "{\"content\":\"AGAIN\"}", NULL);
    CHECK(is_text(fresh(target), "\x1b" "c\x1b[3J<grid 80x24>AGAINh"));
    CHECK(is_text(sent(), record));
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    /* A resume the server refuses starts over. */
    portal_fake_socket_end(data, "The connection to the server was lost");
    resumed = portal_fake_socket_last();
    CHECK(is_text(portal_fake_socket_sent(resumed), resume_hex(0, TAKEN(1))));
    portal_fake_socket_deliver_bytes(resumed, "\x82\x03", 2);
    CHECK(!*portal_fake_socket_address(resumed));
    CHECK(asked(id, number, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    /* A stream that keeps ending before it shows anything gives up. */
    for (int i = 0; i < 2; i++) {
        answer_with(id, number++, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
        portal_fake_socket_end(portal_fake_socket_last(), "Nothing is listening on that socket");
    }
    CHECK(strstr(rex_state(target), "\"state\":\"failed\"") != NULL);
    CHECK(strstr(rex_state(target), "keeps ending") != NULL);
    sent();
    CHECK(portal_views_close(text(target), &error));
    free(target);

    /* The block's end, and a failure, end the show; neither resumes. */
    target = fed_terminal(&error);
    data = show_live(id, target, &number, false, false, "P");
    portal_fake_socket_closed(data, 1011, "The server closed the connection (1011: data provider failed)");
    CHECK(strstr(rex_state(target), "\"state\":\"ended\"") != NULL);
    CHECK(portal_fake_socket_last() == id);
    CHECK(portal_views_close(text(target), &error));
    free(target);
    CHECK(portal_rex_close(id, &error));
    sent();
}

static void test_coming_back(void)
{
    portal_text error = {0};
    char lisp[32], record[64], expected[512];
    unsigned char renewed[32];
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    snprintf(lisp, sizeof lisp, "rex %llu\n", (unsigned long long) id);
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\",\"client\":{\"id\":\"client:1\","
                                   "\"reconnect_token\":\"secret-1\"}}");
    received(id);
    sent();
    int number = 1;
    char *target = fed_terminal(&error);
    snprintf(record, sizeof record, "rex-block %s\n", target);
    claim_answer = OWNED_BY("client:1");
    uint64_t data = show_live(id, target, &number, false, true, "P");
    /* The connection drops: Emacs hears of it among the server's messages,
       the block takes no typing and says so, and its stream goes on. */
    portal_fake_socket_deliver(id, "{\"type\":\"event\",\"seq\":1,\"payload\":{}}");
    portal_fake_socket_end(id, "The connection to the server was lost");
    snprintf(expected, sizeof expected, "%s%s", lisp, record);
    CHECK(is_text(sent(), expected));
    CHECK(is_text(received(id), "{\"type\":\"event\",\"seq\":1,\"payload\":{}}\n"
                                "{\"type\":\"portal_lost\",\"reason\":\"The connection to the "
                                "server was lost\"}"));
    CHECK(!*portal_fake_socket_address(id));
    CHECK(strstr(rex_state(target), "\"state\":\"disconnected\"") != NULL);
    CHECK(!request(id, "session.list", "{}", &error));
    CHECK(says(&error, "The Rex connection is lost, and connects again by itself"));
    bool ready = true;
    CHECK(portal_rex_wait(id, 10, &ready, &error) && !ready);
    portal_terminal_input(text(target), "x", 1);
    CHECK(is_text(sent(), record));
    CHECK(strstr(rex_state(target), "\"state\":\"disconnected\",\"typed\":true") != NULL);
    CHECK(strstr(rex_state(target), "typed") == NULL);
    portal_fake_socket_deliver(data, "still");
    CHECK(is_text(fresh(target), "still"));
    /* It comes back by itself, after a while: a try whose server is not
       there yet fails quietly, and the next is longer coming. */
    CHECK(portal_fake_timers() == 1);
    portal_fake_fire_timers();
    uint64_t again = portal_fake_socket_last();
    CHECK(again > data);
    CHECK(is_text(portal_fake_socket_address(again),
                  "/tmp/rex/server.sock /api/control rex.control.v1"));
    snprintf(expected, sizeof expected, "%.*s,\"reconnect_token\":\"secret-1\"}",
             (int) strlen(HELLO("Portal", "0.1.0")) - 1, HELLO("Portal", "0.1.0"));
    CHECK(is_text(portal_fake_socket_sent(again), expected));
    portal_fake_socket_end(again, "Nothing is listening on that socket");
    CHECK(is_text(sent(), ""));
    CHECK(!*portal_fake_socket_address(again));
    CHECK(portal_fake_timers() == 2); /* The late welcome's, which counts for nothing, and the next try. */
    portal_fake_fire_timers();
    again = portal_fake_socket_last();
    CHECK(is_text(portal_fake_socket_sent(again), expected));
    /* The stream drops meanwhile: it waits for the connection.  The pane
       changes size too, which nothing can tell the server yet. */
    portal_fake_socket_end(data, "The connection to the server was lost");
    CHECK(portal_fake_socket_last() == again);
    CHECK(portal_views_place(text(target), (portal_edges) {0, 0, 400, 160}, text("frame"), &error));
    portal_input_focus(text(target), true);
    sent(); /* The focus record. */
    CHECK(is_text(portal_fake_socket_sent(again), ""));
    /* Back as the same client: Emacs gets the welcome, with what came
       after it, and the core's messages from before it are dropped. */
    portal_fake_socket_deliver(again, "{\"type\":\"event\",\"seq\":9}");
    portal_fake_socket_deliver(again, "{\"type\":\"welcome\",\"client\":{\"id\":\"client:1\","
                                      "\"reconnect_token\":\"secret-2\",\"resumed\":true}}");
    CHECK(is_text(sent(), lisp));
    CHECK(is_text(received(id), "{\"type\":\"welcome\",\"client\":{\"id\":\"client:1\","
                                "\"reconnect_token\":\"secret-2\",\"resumed\":true}}"));
    CHECK(request(id, "session.attach_all", "{}", &error) == (uint64_t) number);
    CHECK(asked(again, number++, "session.attach_all", "{}"));
    /* Still disconnected until Emacs resumes it, which it does once the
       buffers match the server. */
    CHECK(strstr(rex_state(target), "\"state\":\"disconnected\"") != NULL);
    CHECK(portal_rex_resume(id, &error));
    CHECK(is_text(sent(), record));
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    /* It asks again what the terminal reports, sizes the block to the
       pane it has now, and resumes the stream. */
    CHECK(strstr(portal_fake_socket_sent(again),
                 "\"method\":\"com.superlogical.terminal.resize\",\"payload\":" ON_BLOCK
                 ",\"args\":{\"columns\":50,\"rows\":10,") != NULL);
    data = portal_fake_socket_last();
    CHECK(is_text(portal_fake_socket_sent(data), resume_hex(0, TAKEN(5))));
    welcome_with(renewed, 9);
    portal_fake_socket_deliver_bytes(data, renewed, sizeof renewed);
    portal_fake_socket_deliver(data, "!");
    CHECK(is_text(fresh(target), "!"));
    number += 3;
    answer_with(again, number++, "{}", NULL);
    /* Then that it has the keyboard, which it gained meanwhile. */
    CHECK(asked(again, number, "block.event",
                ON_BLOCK ",\"event\":{\"type\":\"focus\",\"payload\":{\"action\":\"in\"}}}"));
    answer_with(again, number++, "{}", NULL);
    portal_terminal_input(text(target), "y", 1);
    CHECK(asked(again, number++, "com.superlogical.terminal.write", ON_BLOCK ",\"args\":{\"data\":\"y\"}}"));

    /* Lost again, and back as a new client, as from a server that
       restarted: the block starts again from the beginning, and is
       painted afresh. */
    portal_fake_socket_end(again, "The connection to the server was lost");
    received(id);
    portal_fake_fire_timers();
    again = portal_fake_socket_last();
    snprintf(expected, sizeof expected, "%.*s,\"reconnect_token\":\"secret-2\"}",
             (int) strlen(HELLO("Portal", "0.1.0")) - 1, HELLO("Portal", "0.1.0"));
    CHECK(is_text(portal_fake_socket_sent(again), expected));
    portal_fake_socket_deliver(again, "{\"type\":\"welcome\",\"client\":{\"id\":\"client:2\","
                                      "\"reconnect_token\":\"secret-3\",\"resumed\":false}}");
    received(id);
    /* Its old stream is ended, as the new client does not own it. */
    CHECK(!*portal_fake_socket_address(data));
    CHECK(!portal_rex_resume(12345, &error));
    free(error.data);
    error = (portal_text) {0};
    CHECK(portal_rex_resume(id, &error));
    CHECK(asked(again, number, "session.attach", "{\"session_id\":\"" SESSION "\"}"));
    sent();
    claim_answer = OWNED_BY("client:2");
    data = show_on(id, again, target, &number, true, true, "FRESH");
    claim_answer = "{}";
    CHECK(is_text(show_fed, "\x1b" "c\x1b[3JFRESH"));
    /* Disconnecting while lost ends it all for good. */
    portal_fake_socket_end(again, "The connection to the server was lost");
    CHECK(!portal_rex_resume(id, &error));
    CHECK(says(&error, "The Rex connection is not back yet"));
    CHECK(portal_rex_close(id, &error));
    CHECK(strstr(rex_state(target), "\"state\":\"ended\"") != NULL);
    /* Its stream with it, and no try comes after. */
    CHECK(portal_fake_sockets() == 0);
    portal_fake_fire_timers();
    CHECK(portal_fake_sockets() == 0);
    CHECK(portal_views_close(text(target), &error));
    free(target);
    sent();
}

static void test_giving_up(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_deliver(id, "{\"type\":\"welcome\",\"client\":{\"reconnect_token\":\"t\"}}");
    received(id);
    char *target = fed_terminal(&error);
    int number = 1;
    show_live(id, target, &number, false, true, "P");
    /* Lost; then a try the server refuses for good, as one restarted with
       no revision in common: the connection ends, and no try follows. */
    portal_fake_socket_end(id, "The connection to the server was lost");
    received(id);
    portal_fake_fire_timers();
    uint64_t again = portal_fake_socket_last();
    portal_fake_socket_closed(again, 1008, "The server closed the connection (1008: no common API revision)");
    CHECK(is_text(received(id), "ended: The server closed the connection (1008: no common API revision)"));
    CHECK(strstr(rex_state(target), "\"state\":\"ended\"") != NULL);
    CHECK(portal_fake_sockets() == 0);
    portal_fake_fire_timers();
    CHECK(portal_fake_sockets() == 0);
    CHECK(portal_views_close(text(target), &error));
    free(target);
    sent();
}

static void test_fresh_streams(void)
{
    portal_text error = {0};
    uint64_t id = open_connection("/tmp/rex/server.sock", &error);
    portal_fake_socket_sent(id);
    char *target = fed_terminal(&error);
    CHECK(portal_rex_show(id, text(target), text(SESSION), text(BLOCK), &error));
    answer_with(id, 1, "{}", NULL);
    answer_with(id, 2, "{}", NULL);
    portal_fake_fire_timers();
    answer_with(id, 6, "{}", NULL);
    answer_with(id, 7, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    uint64_t data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    /* A record of 30 bytes walked, and the stream ends before the
       snapshot does: the next stream's snapshot is walked from its own
       start. */
    static const char first[] = "GHOSTSNP\x01\x00\x01\x00\x1e\x00\x00\x00\x00\x00\x00\x00"
                                "0123456789012345678901234567890123456789";
    portal_fake_socket_deliver_bytes(data, first, 10 + 10 + 30);
    portal_fake_socket_sent(id);
    portal_fake_socket_closed(data, 1013, "The server closed the connection (1013: data reconnect required)");
    CHECK(asked(id, 8, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    answer_with(id, 8, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    CHECK(strstr(portal_fake_socket_sent(id), "\"id\":\"9\",\"method\":\"com.superlogical.terminal.format\"")
          != NULL);
    /* The stream ends again while its paint is asked: the old paint's
       answer, when it comes, paints nothing and starts nothing. */
    portal_fake_socket_closed(data, 1013, "The server closed the connection (1013: data reconnect required)");
    CHECK(asked(id, 10, "data.connect",
                ON_BLOCK ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"rex.data.terminal.v1\"}"));
    answer_with(id, 9, "{\"content\":\"OLD\"}", NULL);
    CHECK(is_text(fresh(target), ""));
    CHECK(strstr(rex_state(target), "\"state\":\"starting\"") != NULL);
    answer_with(id, 10, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
    data = portal_fake_socket_last();
    portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
    portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
    portal_fake_socket_deliver(data, grid_message);
    portal_fake_socket_deliver(data, "after");
    answer_with(id, 11, "{\"content\":\"NEW\"}", NULL);
    CHECK(is_text(fresh(target), "<grid 80x24>NEWafter"));
    CHECK(strstr(rex_state(target), "\"state\":\"live\"") != NULL);
    /* Streams that keep ending after their snapshots, before their paints,
       show nothing, and the show gives up after three. */
    int number = 12;
    portal_fake_socket_sent(id);
    for (int i = 0; i < 4; i++) {
        portal_fake_socket_closed(portal_fake_socket_last(), 1013,
                                  "The server closed the connection (1013: data reconnect required)");
        if (i == 3)
            break;
        answer_with(id, number, "{\"ticket\":\"AAECAwQFBgcICQoLDA0ODw\"}", NULL);
        data = portal_fake_socket_last();
        portal_fake_socket_deliver_bytes(data, welcome, sizeof welcome);
        portal_fake_socket_deliver_bytes(data, snapshot, sizeof snapshot - 1);
        number += 2;
    }
    CHECK(strstr(rex_state(target), "\"state\":\"failed\"") != NULL);
    CHECK(strstr(rex_state(target), "keeps ending") != NULL);
    CHECK(portal_views_close(text(target), &error));
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
    test_details();
    test_owning();
    test_resizing_while_painting();
    test_backlog();
    test_resuming();
    test_coming_back();
    test_giving_up();
    test_fresh_streams();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Rex connections passed");
    return 0;
}
