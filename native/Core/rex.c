/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Connections to Rex servers: Portal's end of Rex's control protocol, on the
   platform's message socket primitives.  The platform carries text messages
   to and from a Unix socket and knows nothing of Rex.  The core keeps each
   connection's identity, asks for the control endpoint, writes the hello
   that opens the protocol and the envelope of every request, and tells
   Emacs, with one record at a time, that messages wait.  It never reads a
   message: Lisp parses the server's welcome, responses and events, and
   decides what a session or a block is (portal-rex.el). */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "rex.h"

/* Where a Rex server speaks its control protocol, and the name of the
   protocol, which the server must agree to. */
#define CONTROL_RESOURCE "/api/control"
#define CONTROL_PROTOCOL "rex.control.v1"

/* The platform the hello reports, as Rex names platforms. */
#ifdef __APPLE__
#define CLIENT_PLATFORM "macos"
#else
#define CLIENT_PLATFORM "linux"
#endif

/* A connection.  The platform knows it by the same number, as a socket. */
struct connection {
    uint64_t id;
    uint64_t requests; /* The last request number given out. */
    bool announced;    /* Whether a record went out for what waits. */
};

static struct {
    struct connection *items; /* Oldest first. */
    size_t count;
    uint64_t last; /* The last ID given out. */
} connections;

static portal_string literal(const char *text)
{
    return (portal_string) {text, strlen(text)};
}

static bool out_of_memory(portal_text *error)
{
    return fail_with(error, "Portal is out of memory");
}

static void put_text(struct json *json, const char *text)
{
    put(json, text, strlen(text));
}

/* ID in decimal, in WORD. */
static portal_string number(uint64_t id, char word[static 24])
{
    int length = snprintf(word, 24, "%" PRIu64, id);
    return (portal_string) {word, (size_t) length};
}

/* The open connection ID, or NULL with *ERROR set unless ERROR is NULL. */
static struct connection *find(uint64_t id, portal_text *error)
{
    for (size_t i = 0; i < connections.count; i++)
        if (connections.items[i].id == id)
            return &connections.items[i];
    if (error) {
        char word[24];
        fail(error, "No Rex connection ", number(id, word));
    }
    return NULL;
}

static void forget(struct connection *connection)
{
    size_t index = (size_t) (connection - connections.items);
    memmove(connection, connection + 1, (--connections.count - index) * sizeof *connection);
}

/* The hello: one API revision as both the oldest and the newest Portal
   speaks, so the server translates and Portal never sees another. */
static void put_hello(struct json *json, portal_string name, portal_string version)
{
    char revision[24];
    portal_string spoken = number(PORTAL_REX_API_REVISION, revision);
    put_text(json, "{\"type\":\"hello\",\"api_revision\":");
    put(json, spoken.data, spoken.length);
    put_text(json, ",\"api_min_revision\":");
    put(json, spoken.data, spoken.length);
    put_text(json, ",\"client\":{\"kind\":\"other\",\"platform\":");
    put_string(json, literal(CLIENT_PLATFORM));
    put_text(json, ",\"name\":");
    put_string(json, name);
    put_text(json, ",\"version\":");
    put_string(json, version);
    put_text(json, "}}");
}

bool portal_rex_open(portal_string path, portal_string name, portal_string version, uint64_t *id,
                     portal_text *error)
{
    if (!path.length || path.data[0] != '/' || memchr(path.data, '\0', path.length))
        return fail(error, "A Rex server's socket is an absolute file name, not ", path);
    if (!name.length || !version.length)
        return fail_with(error, "A Rex client needs a name and a version");
    struct json hello = {0};
    put_hello(&hello, name, version);
    struct connection *grown =
        hello.failed ? NULL
                     : realloc(connections.items, (connections.count + 1) * sizeof *grown);
    if (!grown) {
        free(hello.data);
        return out_of_memory(error);
    }
    connections.items = grown;
    /* A failed open uses its number up too, so no report can name a later one. */
    uint64_t socket = ++connections.last;
    bool opened = portal_socket_open(socket, path, literal(CONTROL_RESOURCE),
                                     literal(CONTROL_PROTOCOL), error);
    if (opened && !portal_socket_send(socket, (portal_string) {hello.data, hello.length}, error)) {
        portal_text ignored = {0};
        portal_socket_close(socket, &ignored);
        free(ignored.data);
        opened = false;
    }
    free(hello.data);
    if (!opened)
        return false;
    connections.items[connections.count++] = (struct connection) {.id = socket};
    *id = socket;
    return true;
}

bool portal_rex_request(uint64_t id, portal_string method, portal_string payload,
                        uint64_t *request, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection)
        return false;
    if (!method.length)
        return fail_with(error, "A Rex request needs a method");
    if (payload.length < 2 || payload.data[0] != '{' || payload.data[payload.length - 1] != '}')
        return fail(error, "A Rex request's payload must be a JSON object, not ", payload);
    char word[24];
    portal_string serial = number(connection->requests + 1, word);
    struct json json = {0};
    put_text(&json, "{\"type\":\"request\",\"id\":\"");
    put(&json, serial.data, serial.length);
    put_text(&json, "\",\"method\":");
    put_string(&json, method);
    put_text(&json, ",\"payload\":");
    put(&json, payload.data, payload.length);
    put_text(&json, "}");
    bool sent = json.failed ? out_of_memory(error)
                            : portal_socket_send(id, (portal_string) {json.data, json.length},
                                                 error);
    free(json.data);
    if (sent)
        *request = ++connection->requests;
    return sent;
}

bool portal_rex_receive(uint64_t id, portal_text **messages, size_t *count, bool *ended,
                        portal_text *reason, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection || !portal_socket_read(id, messages, count, ended, reason, error))
        return false;
    connection->announced = false;
    if (*ended) {
        /* The socket has nothing more to say; a platform that cannot close
           it now has ended it all the same. */
        portal_text ignored = {0};
        portal_socket_close(id, &ignored);
        free(ignored.data);
        forget(connection);
    }
    return true;
}

bool portal_rex_wait(uint64_t id, uint64_t milliseconds, bool *ready, portal_text *error)
{
    return find(id, error) && portal_socket_wait(id, milliseconds, ready, error);
}

bool portal_rex_close(uint64_t id, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection || !portal_socket_close(id, error))
        return false;
    forget(connection);
    return true;
}

/* The platform's call, from portal.h. */

void portal_socket_ready(uint64_t socket)
{
    struct connection *connection = find(socket, NULL);
    char word[24];
    /* A record the pipe refuses is tried again with the next report. */
    if (connection && !connection->announced)
        connection->announced =
            portal_channel_send(literal("rex"), number(socket, word), NULL, 0);
}
