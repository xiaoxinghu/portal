/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Connections to Rex servers: Portal's end of Rex's control protocol, on the
   platform's message socket primitives, and the blocks the core shows in
   fed terminals.  The platform carries messages to and from a Unix socket
   and knows nothing of Rex.  The core keeps each connection's identity,
   asks for the control endpoint, writes the hello that opens the protocol
   and the envelope of every request, and tells Emacs, with one record at a
   time, that messages wait.  Lisp parses the server's welcome, responses
   and events, and decides what a session or a block is (portal-rex.el).

   The core reads the responses to its own requests, which it takes out of
   what the server sends before Emacs sees it: those that show a block in a
   terminal.  It also reads the events of the blocks it shows, for what
   their terminals report, and passes them on to Emacs.  A block's bytes,
   its first paint and its typing never cross Emacs.  The order of that work, and what each step guards
   against, is in rex.h; the protocol is the server's own documentation
   ("Data Connections" in the server's /llms.txt). */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#include "channel.h"
#include "core.h"
#include "json.h"
#include "rex.h"
#include "views.h"

/* Where a Rex server speaks its control protocol, and the name of the
   protocol, which the server must agree to; and the same for a terminal's
   data stream. */
#define CONTROL_RESOURCE "/api/control"
#define CONTROL_PROTOCOL "rex.control.v1"
#define DATA_RESOURCE "/api/data"
#define DATA_PROTOCOL "rex.data.terminal.v1"

/* The platform the hello reports, as Rex names platforms. */
#ifdef __APPLE__
#define CLIENT_PLATFORM "macos"
#else
#define CLIENT_PLATFORM "linux"
#endif

enum {
    /* How long a terminal's grid must stay the same before the block is
       sized to it: a view placed in a pane reports a grid or two on the
       way, and a block resized while its stream starts redraws twice. */
    SETTLE_MILLISECONDS = 100,
    /* The most of the first paint to ask for at once: the server lowers
       anything larger to this. */
    PAINT_BYTES = 983040,
    /* A Rex message longer than this is a program's look-alike that never
       ends, and is shown as output. */
    LONGEST_MESSAGE = 1 << 20,
    /* How long a block whose program exited is given to close before its
       terminal says it has exited: a block closes when its program ends,
       unless it was made to stay, and the server sends the two events one
       after the other. */
    EXIT_MILLISECONDS = 250,
    /* The first wait before connecting again to a server that was lost,
       doubled at each try that fails, up to the longest; and how long a
       try has for the server's welcome. */
    RETRY_MILLISECONDS = 200,
    LONGEST_RETRY_MILLISECONDS = 5000,
    WELCOME_MILLISECONDS = 5000,
    /* The most of a stream's output held while the first paint is made:
       past it, the stream waits unread, and so does the server. */
    HELD_MOST = 4 << 20,
    /* How many times in a row a block's stream may end before it shows
       anything, before the show gives up. */
    STREAM_TRIES = 3,
};

/* Bytes that grow. */
struct bytes {
    char *data;
    size_t length, size;
    bool failed; /* Out of memory once: the rest is lost. */
};

static void append(struct bytes *bytes, const char *data, size_t length)
{
    if (!length || bytes->failed)
        return;
    if (bytes->length + length > bytes->size) {
        size_t size = bytes->size ? bytes->size : 4096;
        while (size < bytes->length + length)
            size *= 2;
        char *grown = realloc(bytes->data, size);
        if (!grown) {
            bytes->failed = true;
            return;
        }
        bytes->data = grown;
        bytes->size = size;
    }
    memcpy(bytes->data + bytes->length, data, length);
    bytes->length += length;
}

static void clear(struct bytes *bytes)
{
    free(bytes->data);
    *bytes = (struct bytes) {0};
}

/* A request the core made itself: ANSWER is called with the response, or
   with a NULL one when the connection ends first, for the show SHOWN. */
struct shown;
typedef void answer(struct shown *shown, const char *response, size_t length);
struct pending {
    uint64_t number;
    answer *answer;
    uint64_t shown; /* By ID: the show may be gone by the time it is answered. */
    uint64_t paint; /* The show's paint it was asked for, which a later one discards. */
    uint64_t generation; /* The show's stream when asked: see struct shown. */
};

/* A connection.  Its first socket has its number; one that connects again
   after a loss has a new socket each time. */
struct connection {
    uint64_t id;
    uint64_t socket;   /* The platform's socket, or 0 between tries. */
    uint64_t requests; /* The last request number given out, to Emacs or the core. */
    bool announced;    /* Whether a record went out for what waits. */
    char *path;        /* The server's socket, for its data streams. */
    portal_text *inbox; /* Messages for Emacs, oldest first. */
    size_t waiting;
    bool ended;         /* The connection has ended: REASON says why. */
    portal_text reason;
    struct pending *pending; /* The core's requests without a response. */
    size_t asked;
    char **attached; /* Sessions attached with session.attach. */
    size_t sessions;
    char *client; /* Its client's ID, from the welcome, or NULL until then. */
    /* Coming back: a connection lost once it had a welcome is tried again,
       as the client the welcome named, until a try has a welcome too. */
    portal_text name, version; /* The client's, for each hello. */
    portal_text token;         /* The last welcome's reconnect token. */
    bool welcomed;             /* This socket has had its welcome. */
    bool ever;                 /* Some socket has: a loss is tried again. */
    bool lost;                 /* Lost, and not welcomed back yet. */
    uint64_t retry;            /* The timer of the next try, or of a try's welcome. */
    unsigned tries;            /* Tries since the loss. */
};

static struct {
    struct connection *items; /* Oldest first. */
    size_t count;
    uint64_t last; /* The last ID given out, to a connection or a data stream. */
} connections;

/* What a show does next, in order; FAILED and ENDED end it. */
enum stage {
    ATTACHING,  /* The connection attaches to the block's session. */
    OWNING,     /* It claims the block. */
    SIZING,     /* The terminal's grid settles. */
    RESIZING,   /* The block takes that size. */
    CONNECTING, /* A ticket for the block's stream. */
    GREETING,   /* The stream's handshake. */
    SKIPPING,   /* The stream's snapshot. */
    PAINTING,   /* The first paint, while the stream's bytes are held. */
    LIVE,       /* The stream's bytes reach the terminal. */
    FAILED,
    ENDED,
};

/* Something to send for the terminal, one at a time, in order. */
struct operation {
    enum { WRITE, FOCUS, RESIZE, TAKE } kind;
    struct bytes bytes; /* WRITE's. */
    bool in;            /* FOCUS's. */
};

/* A block shown in a fed terminal. */
struct shown {
    uint64_t id; /* Never reused: requests name their show by it. */
    portal_text target, session, block;
    uint64_t connection;
    enum stage stage;
    portal_text reason; /* Why it failed or ended. */
    bool announced;     /* A "rex-block" record waits for a description. */
    uint64_t timer;     /* The settling grid's timer, or 0. */
    uint32_t sized[4];  /* The grid last sent to the server, cells first. */
    uint32_t columns, rows; /* The grid the stream last gave. */
    uint64_t data;          /* The stream's socket, or 0. */
    char marker[40];        /* "ESC _ rex1;NONCE;", which starts a Rex message. */
    size_t marker_length;
    struct bytes snapshot; /* SKIPPING: what has come of it. */
    size_t walked;         /* How far its records have been walked. */
    struct bytes tail;     /* What may start a Rex message, for the next bytes. */
    struct bytes held;     /* PAINTING: the stream's bytes, for after the paint. */
    struct bytes paint;    /* PAINTING: the paint so far. */
    int64_t blob;          /* The paint's result on the server, while read in parts. */
    struct operation *operations;
    size_t queued;
    bool sending; /* An operation's request is out. */
    /* What the block's terminal reports, from its events and, once, from
       its own methods; each kept with the seq of the message that last set
       it, since an event can overtake the response to an earlier request. */
    portal_text title;    /* As a program last set it. */
    portal_text reported; /* The last directory reported from this Mac. */
    portal_text cwd;      /* The foreground process's working directory. */
    portal_text program;  /* The foreground process, as Rex labels one. */
    uint64_t seqs[4];     /* Of the title, the reported directory, the process, the owner. */
    bool exited;          /* Its program has exited, and the block stays. */
    bool child_exited;    /* The server said its program exited. */
    bool closed;          /* The server said the block closed. */
    bool exiting;         /* Either: EXIT_TIMER runs, and the stream's end waits. */
    bool end_waits;       /* The stream ended while exiting: told after it. */
    uint64_t exit_timer;
    /* Who owns the block, as the server last said: a client's ID, "" for
       no client, unknown until the server has said. */
    portal_text owner;
    bool owner_known;
    portal_text owner_name; /* What the owner calls itself, "" until known. */
    bool taking;            /* A take is queued or unanswered. */
    uint32_t drawn[2];      /* The grid last given the terminal, 0 by 0 before any. */
    uint64_t paints;        /* How many first paints were asked for: the last counts. */
    uint32_t painted[2];    /* PAINTING: the grid the paint is for, 0 by 0 until known. */
    bool paint_waits;       /* PAINTING: the paint has come, before the stream's grid. */
    /* Holding up: flow control, and coming back from a stream or a
       connection that ended. */
    bool backlogged;          /* The terminal has too much to parse. */
    bool deferred;            /* The stream has something unread meanwhile. */
    unsigned char token[16];  /* The latest WELCOME's reconnect token. */
    bool tokened;             /* A WELCOME gave it. */
    uint64_t received;        /* The stream's bytes taken since its HELLO, for a RESUME. */
    bool resuming;            /* A RESUME is out: the next message is its answer. */
    bool waiting;             /* The stream dropped while the connection was lost. */
    bool restart;             /* It starts over once the connection is back. */
    bool offline;             /* The connection is lost: typing goes nowhere. */
    bool typed;               /* Something was typed meanwhile, since described. */
    bool painted_once;        /* The terminal has had a paint, which a new one resets. */
    unsigned tries;           /* Stream ends in a row before it showed anything. */
    /* Counts the streams the show has started: an answer to a request made
       for an earlier one, such as a paint, drives nothing. */
    uint64_t generation;
};

/* Which of a shown block's details a seq is for. */
enum detail { TITLE, DIRECTORY, PROCESS, OWNER };

static struct {
    struct shown **items;
    size_t count;
    uint64_t last;
} shows;

static portal_string literal(const char *text)
{
    return (portal_string) {text, strlen(text)};
}

static portal_string view(portal_text text)
{
    return (portal_string) {text.data, text.length};
}

static bool same(portal_text text, portal_string string)
{
    return text.length == string.length && !memcmp(text.data, string.data, string.length);
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

static void put_number(struct json *json, uint64_t value)
{
    char word[24];
    portal_string written = number(value, word);
    put(json, written.data, written.length);
}

/* A copy of STRING, NUL-terminated. */
static bool copy(portal_string string, portal_text *text)
{
    char *data = malloc(string.length + 1);
    if (!data)
        return false;
    memcpy(data, string.data, string.length);
    data[string.length] = '\0';
    *text = (portal_text) {data, string.length};
    return true;
}

/* The connection whose socket is SOCKET, or NULL. */
static struct connection *on_socket(uint64_t socket)
{
    for (size_t i = 0; socket && i < connections.count; i++)
        if (connections.items[i].socket == socket)
            return &connections.items[i];
    return NULL;
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

static void free_connection(struct connection *connection)
{
    free(connection->path);
    for (size_t i = 0; i < connection->waiting; i++)
        free(connection->inbox[i].data);
    free(connection->inbox);
    free(connection->reason.data);
    free(connection->pending);
    for (size_t i = 0; i < connection->sessions; i++)
        free(connection->attached[i]);
    free(connection->attached);
    free(connection->client);
    free(connection->name.data);
    free(connection->version.data);
    free(connection->token.data);
}

static void forget(struct connection *connection)
{
    free_connection(connection);
    size_t index = (size_t) (connection - connections.items);
    memmove(connection, connection + 1, (--connections.count - index) * sizeof *connection);
}

/* The show with ID, or NULL. */
static struct shown *shown_by_id(uint64_t id)
{
    for (size_t i = 0; i < shows.count; i++)
        if (shows.items[i]->id == id)
            return shows.items[i];
    return NULL;
}

/* The show in TARGET, or NULL. */
static struct shown *shown_in(portal_string target)
{
    for (size_t i = 0; i < shows.count; i++)
        if (same(shows.items[i]->target, target))
            return shows.items[i];
    return NULL;
}

/* The hello: one API revision as both the oldest and the newest Portal
   speaks, so the server translates and Portal never sees another; with
   TOKEN, if it is not empty, to continue that client. */
static void put_hello(struct json *json, portal_string name, portal_string version,
                      portal_string token)
{
    put_text(json, "{\"type\":\"hello\",\"api_revision\":");
    put_number(json, PORTAL_REX_API_REVISION);
    put_text(json, ",\"api_min_revision\":");
    put_number(json, PORTAL_REX_API_REVISION);
    put_text(json, ",\"client\":{\"kind\":\"other\",\"platform\":");
    put_string(json, literal(CLIENT_PLATFORM));
    put_text(json, ",\"name\":");
    put_string(json, name);
    put_text(json, ",\"version\":");
    put_string(json, version);
    put_text(json, "}");
    if (token.length) {
        put_text(json, ",\"reconnect_token\":");
        put_string(json, token);
    }
    put_text(json, "}");
}

bool portal_rex_open(portal_string path, portal_string name, portal_string version, uint64_t *id,
                     portal_text *error)
{
    if (!path.length || path.data[0] != '/' || memchr(path.data, '\0', path.length))
        return fail(error, "A Rex server's socket is an absolute file name, not ", path);
    if (!name.length || !version.length)
        return fail_with(error, "A Rex client needs a name and a version");
    struct json hello = {0};
    put_hello(&hello, name, version, literal(""));
    portal_text kept = {0}, named = {0}, versioned = {0};
    struct connection *grown =
        hello.failed || !copy(path, &kept) || !copy(name, &named) || !copy(version, &versioned)
        ? NULL
        : realloc(connections.items, (connections.count + 1) * sizeof *grown);
    if (!grown) {
        free(hello.data);
        free(kept.data);
        free(named.data);
        free(versioned.data);
        return out_of_memory(error);
    }
    connections.items = grown;
    /* A failed open uses its number up too, so no report can name a later one. */
    uint64_t socket = ++connections.last;
    bool opened = portal_socket_open(socket, path, literal(CONTROL_RESOURCE),
                                     literal(CONTROL_PROTOCOL), false, error);
    if (opened && !portal_socket_send(socket, (portal_string) {hello.data, hello.length}, error)) {
        portal_text ignored = {0};
        portal_socket_close(socket, &ignored);
        free(ignored.data);
        opened = false;
    }
    free(hello.data);
    if (!opened) {
        free(kept.data);
        free(named.data);
        free(versioned.data);
        return false;
    }
    connections.items[connections.count++] = (struct connection) {
        .id = socket, .socket = socket, .path = kept.data, .name = named, .version = versioned};
    *id = socket;
    return true;
}

/* Send METHOD with PAYLOAD, a JSON object, on CONNECTION, and set *REQUEST
   to its number. */
static bool send_request(struct connection *connection, portal_string method,
                         portal_string payload, uint64_t *request, portal_text *error)
{
    if (connection->lost)
        return fail_with(error, "The Rex connection is lost, and connects again by itself");
    struct json json = {0};
    put_text(&json, "{\"type\":\"request\",\"id\":\"");
    put_number(&json, connection->requests + 1);
    put_text(&json, "\",\"method\":");
    put_string(&json, method);
    put_text(&json, ",\"payload\":");
    put(&json, payload.data, payload.length);
    put_text(&json, "}");
    bool sent = json.failed
        ? out_of_memory(error)
        : portal_socket_send(connection->socket, (portal_string) {json.data, json.length}, error);
    free(json.data);
    if (sent)
        *request = ++connection->requests;
    return sent;
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
    return send_request(connection, method, payload, request, error);
}

/* Shows. */

static void stop_stream(struct shown *shown);
static void start_over(struct shown *shown, portal_string why);
static void free_operation(struct operation *operation);
static void end_show(struct shown *shown, enum stage stage, const char *reason,
                     portal_string detail);
static void next_operation(struct shown *shown);
static bool ask_paint(struct shown *shown);
static void paint(struct shown *shown);

/* Ask SHOWN's connection to run METHOD with PAYLOAD, for ANSWER.  A request
   that cannot go fails the show. */
static bool ask(struct shown *shown, const char *method, struct json *payload, answer *answer)
{
    struct connection *connection = find(shown->connection, NULL);
    portal_text error = {0};
    /* A lost connection holds the show until it is back. */
    if (connection && connection->lost) {
        free(payload->data);
        *payload = (struct json) {0};
        shown->restart = true;
        stop_stream(shown);
        return false;
    }
    uint64_t request;
    struct pending *grown =
        !connection || connection->ended || payload->failed
        ? NULL
        : realloc(connection->pending, (connection->asked + 1) * sizeof *grown);
    if (grown)
        connection->pending = grown;
    bool sent = grown
        && send_request(connection, literal(method), (portal_string) {payload->data, payload->length},
                        &request, &error);
    free(payload->data);
    *payload = (struct json) {0};
    if (!sent) {
        char prefix[96];
        snprintf(prefix, sizeof prefix, "%s: ", method);
        end_show(shown, FAILED, prefix,
                 literal(error.data ? error.data
                         : connection && !connection->ended ? "Portal is out of memory"
                                                            : "not connected"));
        free(error.data);
        return false;
    }
    connection->pending[connection->asked++] = (struct pending) {
        .number = request, .answer = answer, .shown = shown->id, .paint = shown->paints,
        .generation = shown->generation};
    return true;
}

/* The start of a block method's payload, up to its arguments' opening. */
static void put_block(struct json *json, struct shown *shown)
{
    put_text(json, "{\"session_id\":");
    put_string(json, view(shown->session));
    put_text(json, ",\"block_id\":");
    put_string(json, view(shown->block));
}

/* RESPONSE's error message, or NULL with *ERROR unset if it succeeded.  A
   response the connection's end stands for has the message "the connection
   ended". */
static bool refused(const char *response, size_t length, portal_text *error)
{
    portal_string whole = {response, length}, failure, message;
    if (!response) {
        copy(literal("the connection to the server ended"), error);
        return true;
    }
    if (!portal_json_member(whole, "error", &failure))
        return false;
    if (!portal_json_member(failure, "message", &message) || !portal_json_string(message, error))
        copy(failure, error);
    return true;
}

/* RESPONSE's payload, or false having failed SHOWN for METHOD. */
static bool succeeded(struct shown *shown, const char *method, const char *response,
                      size_t length, portal_string *payload)
{
    portal_text error = {0};
    if (refused(response, length, &error)) {
        char prefix[96];
        snprintf(prefix, sizeof prefix, "%s: ", method);
        end_show(shown, FAILED, prefix, view(error));
        free(error.data);
        return false;
    }
    if (!portal_json_member((portal_string) {response, length}, "payload", payload))
        *payload = literal("{}");
    return true;
}

/* Feed BYTES to SHOWN's terminal. */
static void feed(struct shown *shown, const char *bytes, size_t length)
{
    portal_view *terminal = portal_views_find(view(shown->target), PORTAL_TERMINAL, NULL);
    portal_text error = {0};
    if (length && terminal && !portal_terminal_feed(terminal, bytes, length, &error))
        free(error.data);
}

/* Tell Emacs that SHOWN's state changed, unless a record already waits. */
static void announce(struct shown *shown)
{
    if (!shown->announced)
        shown->announced = portal_channel_send(literal("rex-block"), view(shown->target), NULL, 0);
}

/* SHOWN's stream will bring nothing more, as STAGE says, because of REASON
   followed by DETAIL. */
static void end_show(struct shown *shown, enum stage stage, const char *reason,
                     portal_string detail)
{
    if (shown->stage >= FAILED)
        return;
    shown->stage = stage;
    free(shown->reason.data);
    shown->reason = (portal_text) {0};
    size_t length = strlen(reason);
    char *text = malloc(length + detail.length + 1);
    if (text) {
        memcpy(text, reason, length);
        if (detail.length)
            memcpy(text + length, detail.data, detail.length);
        text[length + detail.length] = '\0';
        shown->reason = (portal_text) {text, length + detail.length};
    }
    stop_stream(shown);
    /* Nothing more is shown, so nothing more is typed: a frozen screen
       must not take commands. */
    for (size_t k = 0; k < shown->queued; k++)
        free_operation(&shown->operations[k]);
    shown->queued = 0;
    clear(&shown->snapshot);
    clear(&shown->held);
    clear(&shown->paint);
    clear(&shown->tail);
    /* A block whose program has exited closes, and its buffer goes: its
       stream's end is news only if it stays. */
    if (shown->exiting)
        shown->end_waits = true;
    else
        announce(shown);
}

/* Close SHOWN's stream, if open; a close says the stream is done with. */
static void stop_stream(struct shown *shown)
{
    if (!shown->data)
        return;
    portal_text ignored = {0};
    if (!portal_socket_close(shown->data, &ignored))
        free(ignored.data);
    shown->data = 0;
}

/* The grid views.c holds for SHOWN's terminal, cells and pixels. */
static bool grid(struct shown *shown, uint32_t values[static 4])
{
    return portal_views_grid(view(shown->target), values) && values[0] && values[1];
}

static void settle(struct shown *shown)
{
    shown->timer = portal_channel_timer(SETTLE_MILLISECONDS);
}

/* The arguments of a resize to VALUES. */
static void put_resize(struct json *json, struct shown *shown, const uint32_t values[static 4])
{
    put_block(json, shown);
    put_text(json, ",\"args\":{\"columns\":");
    put_number(json, values[0]);
    put_text(json, ",\"rows\":");
    put_number(json, values[1]);
    if (values[2] && values[3]) {
        put_text(json, ",\"cell_width_px\":");
        put_number(json, values[2]);
        put_text(json, ",\"cell_height_px\":");
        put_number(json, values[3]);
    }
    put_text(json, "}}");
    memcpy(shown->sized, values, sizeof shown->sized);
}

/* What the block's terminal reports. */

/* Tell Emacs that what SHOWN's terminal describes changed, as any
   terminal's platform does. */
static void changed(struct shown *shown)
{
    portal_views_announce(view(shown->target), PORTAL_TERMINAL, "terminal");
}

/* Set *FIELD to VALUE; whether that changed it. */
static bool set_text(portal_text *field, portal_string value)
{
    if (same(*field, value) || (!field->data && !value.length))
        return false;
    portal_text copied = {0};
    if (!copy(value, &copied))
        return false;
    free(field->data);
    *field = copied;
    return true;
}

/* Whether HOST, the host of a file:// URL, is this Mac: empty, localhost,
   or its name, with or without ".local". */
static bool this_host(portal_string host)
{
    char name[256] = {0};
    if (!host.length || (host.length == 9 && !strncasecmp(host.data, "localhost", 9)))
        return true;
    if (gethostname(name, sizeof name - 1))
        return false;
    size_t length = strlen(name);
    if (length > 6 && !strcasecmp(name + length - 6, ".local"))
        length -= 6;
    if (host.length > 6 && !strncasecmp(host.data + host.length - 6, ".local", 6))
        host.length -= 6;
    return host.length == length && !strncasecmp(host.data, name, length);
}

static int hex_digit(char c)
{
    return c >= '0' && c <= '9' ? c - '0'
        : c >= 'a' && c <= 'f'  ? c - 'a' + 10
        : c >= 'A' && c <= 'F'  ? c - 'A' + 10
                                : -1;
}

/* PWD, a directory a program reported, as a path on this Mac in *PATH:
   a file:// URL from this Mac, percent-decoded, or an absolute path as it
   is.  False for any other, such as a URL from a shell reached by ssh. */
static bool local_path(portal_string pwd, portal_text *path)
{
    static const char scheme[] = "file://";
    if (pwd.length && pwd.data[0] == '/')
        return copy(pwd, path);
    if (pwd.length <= sizeof scheme - 1 || strncasecmp(pwd.data, scheme, sizeof scheme - 1))
        return false;
    const char *host = pwd.data + sizeof scheme - 1, *end = pwd.data + pwd.length;
    const char *slash = memchr(host, '/', (size_t) (end - host));
    if (!slash || !this_host((portal_string) {host, (size_t) (slash - host)}))
        return false;
    char *decoded = malloc((size_t) (end - slash) + 1);
    if (!decoded)
        return false;
    size_t length = 0;
    for (const char *at = slash; at < end; at++) {
        int high, low;
        if (*at == '%' && end - at > 2 && (high = hex_digit(at[1])) >= 0
            && (low = hex_digit(at[2])) >= 0) {
            decoded[length++] = (char) (high << 4 | low);
            at += 2;
        } else {
            decoded[length++] = *at;
        }
    }
    decoded[length] = '\0';
    /* A path holds no NUL. */
    if (memchr(decoded, '\0', length)) {
        free(decoded);
        return false;
    }
    *path = (portal_text) {decoded, length};
    return true;
}

/* The directory SHOWN's block is in: the last its program reported from
   this Mac, and until one does, its foreground process's. */
static portal_string directory(struct shown *shown)
{
    return shown->reported.length ? view(shown->reported)
        : shown->cwd.data         ? view(shown->cwd)
                                  : literal("");
}

/* The title TITLE, a JSON string, set at SEQ. */
static bool take_title(struct shown *shown, portal_string title, uint64_t seq)
{
    portal_text text = {0};
    if (seq < shown->seqs[TITLE] || !portal_json_string(title, &text))
        return false;
    shown->seqs[TITLE] = seq;
    bool moved = set_text(&shown->title, view(text));
    free(text.data);
    return moved;
}

/* The directory PWD, a JSON string, reported at SEQ. */
static bool take_directory(struct shown *shown, portal_string pwd, uint64_t seq)
{
    portal_text text = {0}, path = {0};
    if (seq < shown->seqs[DIRECTORY] || !portal_json_string(pwd, &text))
        return false;
    shown->seqs[DIRECTORY] = seq;
    bool moved = local_path(view(text), &path) && set_text(&shown->reported, view(path));
    free(text.data);
    free(path.data);
    return moved;
}

/* The foreground process FOREGROUND, a JSON object or null, at SEQ.  It
   is labelled by Rex's own rule: its script, else its argv0, else its
   name; a login shell's argv0 without its "-". */
static bool take_process(struct shown *shown, portal_string foreground, uint64_t seq)
{
    static const char *const names[] = {"script", "argv0", "name"};
    if (seq < shown->seqs[PROCESS])
        return false;
    shown->seqs[PROCESS] = seq;
    portal_string value;
    portal_text label = {0}, cwd = {0};
    for (size_t i = 0; !label.length && i < sizeof names / sizeof *names; i++) {
        free(label.data);
        label = (portal_text) {0};
        if (portal_json_member(foreground, names[i], &value))
            portal_json_string(value, &label);
    }
    portal_string name = label.data ? view(label) : literal("");
    if (name.length > 1 && name.data[0] == '-') {
        name.data++;
        name.length--;
    }
    bool moved = !shown->exited && set_text(&shown->program, name);
    if (portal_json_member(foreground, "cwd", &value) && portal_json_string(value, &cwd)
        && cwd.length && cwd.data[0] == '/')
        moved = set_text(&shown->cwd, view(cwd)) || moved;
    free(label.data);
    free(cwd.data);
    return moved;
}

/* SHOWN's program has exited, or its block closed: give the block a
   moment to close before its terminal says the program exited, so that a
   buffer about to go never shows it. */
static void exit_later(struct shown *shown)
{
    if (!shown->exiting) {
        shown->exiting = true;
        shown->exit_timer = portal_channel_timer(EXIT_MILLISECONDS);
    }
}

/* The moment is over: a block that stayed says its program exited. */
static void exited(struct shown *shown)
{
    shown->exiting = false;
    shown->exit_timer = 0;
    if (shown->child_exited && !shown->closed && !shown->exited) {
        shown->exited = true;
        set_text(&shown->program, literal(""));
        changed(shown);
    }
    if (shown->end_waits) {
        shown->end_waits = false;
        announce(shown);
    }
}

/* The seq of MESSAGE, a response or an event, or 0. */
static uint64_t seq_of(portal_string message)
{
    portal_string value;
    int64_t seq = 0;
    return portal_json_member(message, "seq", &value) && portal_json_integer(value, &seq) && seq > 0
        ? (uint64_t) seq
        : 0;
}

/* An answer to one of the terminal's methods asked when the show began:
   its payload, or false for a refusal, which leaves the details to the
   events, as for an older server. */
static bool told(const char *response, size_t length, portal_string *payload)
{
    portal_text error = {0};
    if (refused(response, length, &error)) {
        free(error.data);
        return false;
    }
    return portal_json_member((portal_string) {response, length}, "payload", payload);
}

static void told_title(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, title;
    if (told(response, length, &payload) && portal_json_member(payload, "title", &title)
        && take_title(shown, title, seq_of((portal_string) {response, length})))
        changed(shown);
}

static void told_directory(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, pwd;
    if (told(response, length, &payload) && portal_json_member(payload, "pwd", &pwd)
        && take_directory(shown, pwd, seq_of((portal_string) {response, length})))
        changed(shown);
}

static void told_process(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, foreground, last_exit;
    if (!told(response, length, &payload))
        return;
    if (!portal_json_member(payload, "foreground", &foreground))
        foreground = literal("null");
    if (take_process(shown, foreground, seq_of((portal_string) {response, length})))
        changed(shown);
    /* A block made to stay after its program ends, shown since. */
    if (portal_json_member(payload, "last_exit", &last_exit) && !is(last_exit, "null")) {
        shown->child_exited = true;
        exit_later(shown);
    }
}

/* Ask for what SHOWN's terminal reports now: its title, the directory it
   reported and its processes.  Events tell of each change from here on. */
static void ask_details(struct shown *shown)
{
    static const struct {
        const char *method;
        answer *answer;
    } details[] = {
        {"com.superlogical.terminal.title", told_title},
        {"com.superlogical.terminal.pwd", told_directory},
        {"com.superlogical.terminal.process", told_process},
    };
    for (size_t i = 0; i < sizeof details / sizeof *details && shown->stage < FAILED; i++) {
        struct json json = {0};
        put_block(&json, shown);
        put_text(&json, ",\"args\":{}}");
        ask(shown, details[i].method, &json, details[i].answer);
    }
}

/* Who owns the block. */

/* Whether this connection's client owns SHOWN's block, as far as the
   server has said. */
static bool mine(struct shown *shown)
{
    struct connection *connection = find(shown->connection, NULL);
    return shown->owner_known && connection && connection->client
        && same(shown->owner, literal(connection->client));
}

static answer named;

/* OWNER, a block's "owner" member, a client's ID, or NULL for a block
   without one, as the server said at SEQ: whether that changed who owns
   SHOWN's block.  Another client's name is asked of the server, which
   knows it while that client is connected. */
static bool take_owner(struct shown *shown, const portal_string *owner, uint64_t seq)
{
    portal_text id = {0};
    if (seq < shown->seqs[OWNER] || (owner && !portal_json_string(*owner, &id)))
        return false;
    shown->seqs[OWNER] = seq;
    bool moved = !shown->owner_known || !same(shown->owner, id.data ? view(id) : literal(""));
    if (moved) {
        free(shown->owner.data);
        shown->owner = id;
        id = (portal_text) {0};
        if (!shown->owner.data)
            copy(literal(""), &shown->owner);
        shown->owner_known = shown->owner.data != NULL;
        set_text(&shown->owner_name, literal(""));
        if (shown->owner.length && !mine(shown)) {
            struct json json = {0};
            put_text(&json, "{\"client_id\":");
            put_string(&json, view(shown->owner));
            put_text(&json, "}");
            ask(shown, "client.inspect", &json, named);
        }
    }
    free(id.data);
    return moved;
}

/* PAYLOAD, the result of a claim, lists each block's owner: SHOWN's, at
   SEQ, the result's. */
static void take_owners(struct shown *shown, portal_string payload, uint64_t seq)
{
    portal_string blocks, entry, block, owner;
    if (!portal_json_member(payload, "blocks", &blocks))
        return;
    for (size_t i = 0; portal_json_element(blocks, i, &entry); i++) {
        if (!portal_json_member(entry, "block_id", &block) || !portal_json_is(block, shown->block.data))
            continue;
        bool owned = portal_json_member(entry, "owner", &owner) && !is(owner, "null");
        if (take_owner(shown, owned ? &owner : NULL, seq))
            changed(shown);
        return;
    }
}

/* The owner's own description: what it calls itself, its label or else
   its program's name, while it still owns the block. */
static void named(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, client, info, id, value;
    portal_text name = {0};
    if (!told(response, length, &payload) || !portal_json_member(payload, "client", &client)
        || !portal_json_member(client, "client_id", &id) || !portal_json_is(id, shown->owner.data)
        || !portal_json_member(client, "info", &info))
        return;
    if (portal_json_member(info, "label", &value))
        portal_json_string(value, &name);
    if (!name.length && portal_json_member(info, "name", &value)) {
        free(name.data);
        name = (portal_text) {0};
        portal_json_string(value, &name);
    }
    if (name.length && set_text(&shown->owner_name, view(name)))
        changed(shown);
    free(name.data);
}

/* EVENT, a block event's payload with its "name" and "payload", from the
   block SHOWN shows, at SEQ. */
static void terminal_event(struct shown *shown, portal_string event, uint64_t seq)
{
    portal_string creator, name, fields, value;
    if (!portal_json_member(event, "creator_name", &creator)
        || !portal_json_is(creator, "com.superlogical.terminal")
        || !portal_json_member(event, "name", &name)
        || !portal_json_member(event, "payload", &fields))
        return;
    bool moved = false;
    if (portal_json_is(name, "title_changed"))
        moved = portal_json_member(fields, "title", &value) && take_title(shown, value, seq);
    else if (portal_json_is(name, "pwd_changed"))
        moved = portal_json_member(fields, "pwd", &value) && take_directory(shown, value, seq);
    else if (portal_json_is(name, "process_changed"))
        moved = take_process(shown, portal_json_member(fields, "foreground", &value)
                                        ? value
                                        : literal("null"),
                             seq);
    else if (portal_json_is(name, "child_exited")) {
        shown->child_exited = true;
        exit_later(shown);
    }
    if (moved)
        changed(shown);
}

static answer attached, owned, resized, connected, painted, read_part, operated, taken;
static answer told_title, told_directory, told_process;
static bool open_stream(struct shown *shown, const unsigned char *handshake, size_t length);

/* The arguments of a claim of SHOWN's block in MODE, "request" or "take". */
static void put_claim(struct json *json, struct shown *shown, const char *mode)
{
    put_text(json, "{\"session_id\":");
    put_string(json, view(shown->session));
    put_text(json, ",\"block_ids\":[");
    put_string(json, view(shown->block));
    put_text(json, "],\"mode\":");
    put_string(json, literal(mode));
    put_text(json, "}");
}

/* Claim the block with "request": Emacs owns it only if no other client
   does, and is in line for it otherwise.  A take, when Emacs is used,
   follows as an operation. */
static void own(struct shown *shown)
{
    struct json json = {0};
    put_claim(&json, shown, "request");
    shown->stage = OWNING;
    ask(shown, "session.own_block", &json, owned);
    ask_details(shown);
}

static void attached(struct shown *shown, const char *response, size_t length)
{
    portal_string payload;
    if (!succeeded(shown, "session.attach", response, length, &payload))
        return;
    struct connection *connection = find(shown->connection, NULL);
    char *session = connection ? malloc(shown->session.length + 1) : NULL;
    char **grown = session ? realloc(connection->attached,
                                     (connection->sessions + 1) * sizeof *grown)
                           : NULL;
    if (grown) {
        memcpy(session, shown->session.data, shown->session.length + 1);
        grown[connection->sessions++] = session;
        connection->attached = grown;
    } else {
        /* It attaches again next time, which a server allows. */
        free(session);
    }
    own(shown);
}

static void owned(struct shown *shown, const char *response, size_t length)
{
    portal_string payload;
    if (!succeeded(shown, "session.own_block", response, length, &payload))
        return;
    take_owners(shown, payload, seq_of((portal_string) {response, length}));
    shown->stage = SIZING;
    settle(shown);
    /* What waited for the claim, such as a take. */
    next_operation(shown);
}

/* The terminal's grid has settled: size the block to it. */
static void size(struct shown *shown)
{
    uint32_t values[4];
    if (!grid(shown, values))
        return; /* Its first grid settles again. */
    struct json json = {0};
    put_resize(&json, shown, values);
    shown->stage = RESIZING;
    ask(shown, "com.superlogical.terminal.resize", &json, resized);
}

static void resized(struct shown *shown, const char *response, size_t length)
{
    portal_string payload;
    if (!succeeded(shown, "com.superlogical.terminal.resize", response, length, &payload))
        return;
    struct json json = {0};
    put_block(&json, shown);
    put_text(&json, ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"" DATA_PROTOCOL "\"}");
    shown->stage = CONNECTING;
    ask(shown, "data.connect", &json, connected);
    /* The grid moved while the block took the last one. */
    portal_rex_grid(view(shown->target));
}

/* Decode TEXT, base64url without padding, into exactly COUNT BYTES. */
static bool base64url(portal_string text, unsigned char *bytes, size_t count)
{
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    uint32_t bits = 0;
    size_t held = 0, written = 0;
    for (size_t i = 0; i < text.length; i++) {
        const char *found = text.data[i] ? strchr(alphabet, text.data[i]) : NULL;
        if (!found)
            return false;
        bits = bits << 6 | (uint32_t) (found - alphabet);
        held += 6;
        if (held >= 8) {
            if (written == count)
                return false;
            held -= 8;
            bytes[written++] = (unsigned char) (bits >> held);
        }
    }
    return written == count;
}

static void connected(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, ticket;
    portal_text decoded = {0};
    unsigned char hello[17] = {0x01};
    if (!succeeded(shown, "data.connect", response, length, &payload))
        return;
    bool usable = portal_json_member(payload, "ticket", &ticket)
        && portal_json_string(ticket, &decoded) && base64url(view(decoded), hello + 1, 16);
    free(decoded.data);
    if (!usable) {
        end_show(shown, FAILED, "data.connect gave no ticket of 16 bytes", literal(""));
        return;
    }
    shown->stage = GREETING;
    shown->received = 0;
    shown->tokened = false;
    open_stream(shown, hello, sizeof hello);
}

/* Open a data connection for SHOWN's block and send it HANDSHAKE, a HELLO
   or a RESUME; false having failed the show. */
static bool open_stream(struct shown *shown, const unsigned char *handshake, size_t length)
{
    struct connection *connection = find(shown->connection, NULL);
    portal_text error = {0};
    uint64_t socket = ++connections.last;
    bool opened = connection
        && portal_socket_open(socket, literal(connection->path), literal(DATA_RESOURCE),
                              literal(DATA_PROTOCOL), true, &error);
    if (opened) {
        shown->data = socket;
        opened = portal_socket_send(socket, (portal_string) {(const char *) handshake, length},
                                    &error);
    }
    if (!opened)
        end_show(shown, FAILED, "Cannot open the block's stream: ",
                 literal(error.data ? error.data : "not connected"));
    free(error.data);
    return opened;
}

/* Where NEEDLE starts in HAY from FROM, or HAY's length. */
static size_t search(const char *hay, size_t length, size_t from, const char *needle,
                     size_t count)
{
    while (from + count <= length) {
        const char *found = memchr(hay + from, needle[0], length - count + 1 - from);
        if (!found)
            break;
        size_t at = (size_t) (found - hay);
        if (!memcmp(found, needle, count))
            return at;
        from = at + 1;
    }
    return length;
}

/* The program's output, between Rex's messages: held until the first paint
   has gone, then fed. */
static void output(struct shown *shown, const char *bytes, size_t length)
{
    if (shown->stage == PAINTING)
        append(&shown->held, bytes, length);
    else if (shown->stage == LIVE)
        feed(shown, bytes, length);
}

/* Give SHOWN's terminal the block's grid, as the stream last gave it,
   unless it has that grid: the output fed from now on is laid out for it,
   whichever client sized the block. */
static void hold(struct shown *shown)
{
    portal_view *terminal = portal_views_find(view(shown->target), PORTAL_TERMINAL, NULL);
    portal_text error = {0};
    if (!shown->columns || !shown->rows
        || (shown->drawn[0] == shown->columns && shown->drawn[1] == shown->rows) || !terminal)
        return;
    if (portal_terminal_hold_grid(terminal, shown->columns, shown->rows, &error)) {
        shown->drawn[0] = shown->columns;
        shown->drawn[1] = shown->rows;
    }
    free(error.data);
}

/* One of Rex's own messages, a JSON object, from SHOWN's stream.  A resize
   gives the block's grid, which the terminal takes at its place in the
   stream: the output after it is laid out for it.  Before the first paint,
   the paint takes the grid the stream gave last.  A child_exited says the
   block's program has ended.  Its theme is left out: the terminal keeps
   Portal's theme. */
static void message(struct shown *shown, portal_string json)
{
    portal_string type, value;
    int64_t columns, rows;
    if (!portal_json_member(json, "type", &type))
        return;
    /* The stream says so as well as an event, in either order. */
    if (portal_json_is(type, "child_exited")) {
        shown->child_exited = true;
        return exit_later(shown);
    }
    if (!portal_json_is(type, "resize"))
        return;
    if (portal_json_member(json, "cols", &value) && portal_json_integer(value, &columns)
        && portal_json_member(json, "rows", &value) && portal_json_integer(value, &rows)
        && columns >= 0 && rows >= 0 && columns <= UINT32_MAX && rows <= UINT32_MAX) {
        shown->columns = (uint32_t) columns;
        shown->rows = (uint32_t) rows;
        if (shown->stage == LIVE) {
            hold(shown);
        } else if (shown->stage == PAINTING) {
            /* The stream's first resize says the grid the paint is for.  A
               later one, to another grid, comes between output laid out for
               two grids, and the paint may be for either: it is asked for
               again, and only output from here on is held for after it. */
            if (!shown->painted[0] && !shown->painted[1]) {
                shown->painted[0] = shown->columns;
                shown->painted[1] = shown->rows;
                if (shown->paint_waits)
                    paint(shown);
            } else if (shown->painted[0] != shown->columns || shown->painted[1] != shown->rows) {
                clear(&shown->held);
                ask_paint(shown);
            }
        }
    }
}

/* Bytes of the stream after its snapshot: the program's output with Rex's
   messages among it, each "ESC _ rex1;NONCE;JSON ESC \".  A message may be
   split across the stream's messages, so what could start one waits for
   the next bytes.  A look-alike with another nonce is output. */
static void stream_bytes(struct shown *shown, const char *bytes, size_t length)
{
    const char *data = bytes;
    struct bytes joined = {0};
    if (shown->tail.length) {
        append(&joined, shown->tail.data, shown->tail.length);
        append(&joined, bytes, length);
        clear(&shown->tail);
        if (joined.failed) {
            clear(&joined);
            return end_show(shown, FAILED, "Portal is out of memory", literal(""));
        }
        data = joined.data;
        length = joined.length;
    }
    const char *marker = shown->marker;
    size_t count = shown->marker_length, at = 0;
    while (at < length && shown->stage < FAILED) {
        size_t start = search(data, length, at, marker, count);
        if (start == length) {
            /* Keep the longest end that could begin the marker. */
            size_t keep = count - 1 < length - at ? count - 1 : length - at;
            while (keep && memcmp(data + length - keep, marker, keep))
                keep--;
            output(shown, data + at, length - at - keep);
            append(&shown->tail, data + length - keep, keep);
            break;
        }
        output(shown, data + at, start - at);
        size_t body = start + count, end = search(data, length, body, "\x1b\\", 2);
        if (end == length) {
            if (length - start > LONGEST_MESSAGE)
                output(shown, data + start, length - start);
            else
                append(&shown->tail, data + start, length - start);
            break;
        }
        message(shown, (portal_string) {data + body, end - body});
        at = end + 2;
    }
    clear(&joined);
}

/* Ask for the first paint, the screen in VT form, for the grid the block
   has now: any paint asked for before is discarded. */
static bool ask_paint(struct shown *shown)
{
    struct json json = {0};
    shown->paints++;
    shown->paint_waits = false;
    shown->painted[0] = shown->columns;
    shown->painted[1] = shown->rows;
    clear(&shown->paint);
    shown->blob = 0;
    put_block(&json, shown);
    put_text(&json, ",\"args\":{\"format\":\"vt\",\"extra_charsets\":true,\"extra_cursor\":true,"
                    "\"extra_hyperlink\":true,\"extra_keyboard\":true,"
                    "\"extra_kitty_keyboard\":true,\"extra_modes\":true,"
                    "\"extra_protection\":true,\"extra_pwd\":true,"
                    "\"extra_scrolling_region\":true,\"extra_style\":true,"
                    "\"extra_tabstops\":true,\"unwrap\":true,\"max_bytes\":");
    put_number(&json, PAINT_BYTES);
    put_text(&json, "}}");
    return ask(shown, "com.superlogical.terminal.format", &json, painted);
}

/* Read the stream's snapshot as far as it has come: "GHOSTSNP", a version
   of two bytes, then records with a header of ten bytes, a tag of two and a
   length of four among them, up to and including the one tagged 6.  It is
   skipped, not decoded: the first paint comes from "format". */
static void skip_snapshot(struct shown *shown)
{
    struct bytes *snapshot = &shown->snapshot;
    const unsigned char *bytes = (const unsigned char *) snapshot->data;
    if (snapshot->length >= 8 && memcmp(bytes, "GHOSTSNP", 8)) {
        /* No snapshot: all of it is the program's. */
        shown->walked = 0;
        goto done;
    }
    if (!shown->walked)
        shown->walked = 10;
    while (shown->walked + 10 <= snapshot->length) {
        const unsigned char *header = bytes + shown->walked;
        uint32_t tag = header[0] | (uint32_t) header[1] << 8;
        uint64_t length = header[2] | (uint64_t) header[3] << 8 | (uint64_t) header[4] << 16
            | (uint64_t) header[5] << 24;
        if (shown->walked + 10 + length > snapshot->length)
            return;
        shown->walked += 10 + (size_t) length;
        if (tag == 6)
            goto done;
    }
    return;
done:;
    struct bytes rest = *snapshot;
    size_t from = shown->walked;
    *snapshot = (struct bytes) {0};
    shown->walked = 0;
    shown->stage = PAINTING;
    if (ask_paint(shown))
        stream_bytes(shown, rest.data + from, rest.length - from);
    clear(&rest);
}

/* The handshake's answer, to a HELLO or a RESUME: a WELCOME of 32 bytes,
   a reconnect token in bytes 1 to 16 and the channel's nonce, little-endian,
   in the last 8; or a REJECT with its reason.  A refused RESUME starts
   over, as the server asks. */
static void greeted(struct shown *shown, const unsigned char *bytes, size_t length)
{
    bool resuming = shown->resuming;
    shown->resuming = false;
    if (length == 32 && bytes[0] == 0x81) {
        uint64_t nonce = 0;
        for (int i = 31; i >= 24; i--)
            nonce = nonce << 8 | bytes[i];
        int written = snprintf(shown->marker, sizeof shown->marker, "\x1b_rex1;%" PRIu64 ";", nonce);
        shown->marker_length = (size_t) written;
        memcpy(shown->token, bytes + 1, sizeof shown->token);
        shown->tokened = true;
        if (!resuming)
            shown->stage = SKIPPING;
        return;
    }
    char reason[64];
    if (length == 2 && bytes[0] == 0x82)
        snprintf(reason, sizeof reason, "reason 0x%02x", bytes[1]);
    else
        snprintf(reason, sizeof reason, "an answer of %zu bytes", length);
    if (resuming)
        return start_over(shown, literal(reason));
    end_show(shown, FAILED, "The server refused the block's stream: ", literal(reason));
}

/* Drop all SHOWN has of its stream, for a new one: what came of its
   snapshot, its cursor in it, what was held for a paint and the paint so
   far, and its token.  Answers to what the old stream asked drive
   nothing from here on. */
static void fresh_stream(struct shown *shown)
{
    stop_stream(shown);
    shown->resuming = shown->waiting = shown->tokened = false;
    /* The new stream says its grid again, which its paint is for. */
    shown->columns = shown->rows = 0;
    shown->walked = 0;
    shown->received = 0;
    shown->blob = 0;
    clear(&shown->snapshot);
    clear(&shown->tail);
    clear(&shown->held);
    clear(&shown->paint);
    shown->generation++;
}

/* SHOWN's stream is to continue on a new data connection, from the byte
   after those it has taken, once its connection is up; else it starts
   over. */
static void resume_stream(struct shown *shown)
{
    struct connection *connection = find(shown->connection, NULL);
    stop_stream(shown);
    if (connection && connection->lost) {
        shown->waiting = true;
        return;
    }
    shown->waiting = false;
    if (!shown->tokened)
        return start_over(shown, literal("it had no token to resume with"));
    if (++shown->tries > STREAM_TRIES)
        return end_show(shown, FAILED, "The block's stream keeps ending", literal(""));
    unsigned char resume[25] = {0x02};
    memcpy(resume + 1, shown->token, sizeof shown->token);
    for (int i = 0; i < 8; i++)
        resume[17 + i] = (unsigned char) (shown->received >> (8 * i));
    shown->resuming = true;
    open_stream(shown, resume, sizeof resume);
}

/* SHOWN's stream cannot go on, because of WHY: ask for a new one, which
   paints the terminal afresh.  A lost connection waits until it is back,
   and a stream that keeps ending before it shows anything fails. */
static void start_over(struct shown *shown, portal_string why)
{
    struct connection *connection = find(shown->connection, NULL);
    fresh_stream(shown);
    if (connection && connection->lost) {
        shown->restart = true;
        return;
    }
    if (++shown->tries > STREAM_TRIES)
        return end_show(shown, FAILED, "The block's stream keeps ending: ", why);
    struct json json = {0};
    put_block(&json, shown);
    put_text(&json, ",\"data_ref_id\":\"terminal\",\"subprotocol\":\"" DATA_PROTOCOL "\"}");
    shown->stage = CONNECTING;
    ask(shown, "data.connect", &json, connected);
}

/* SHOWN's stream ended, the server's close frame giving CODE, or 0, and
   REASON.  The block's end, or one the server gives as final, ends the
   show; a stream the server wants started again starts over, and any
   other end resumes. */
static void stream_ended(struct shown *shown, int code, portal_string reason)
{
    bool resuming = shown->resuming;
    stop_stream(shown);
    shown->resuming = false;
    if (code == 1000 || code == 1008 || code == 1011 || code >= 4000)
        end_show(shown, shown->stage == LIVE ? ENDED : FAILED, "The block's stream ended: ", reason);
    else if (code == 1013 || resuming || !shown->tokened || shown->stage < SKIPPING)
        start_over(shown, reason);
    else
        resume_stream(shown);
}

static void stream_message(struct shown *shown, const char *bytes, size_t length)
{
    if (shown->resuming)
        return greeted(shown, (const unsigned char *) bytes, length);
    /* Every byte after a WELCOME is the stream's, and counts for a RESUME. */
    if (shown->stage > GREETING) {
        shown->received += length;
        shown->tries = 0;
    }
    switch (shown->stage) {
    case GREETING:
        return greeted(shown, (const unsigned char *) bytes, length);
    case SKIPPING:
        append(&shown->snapshot, bytes, length);
        if (shown->snapshot.failed)
            return end_show(shown, FAILED, "Portal is out of memory", literal(""));
        return skip_snapshot(shown);
    case PAINTING:
    case LIVE:
        return stream_bytes(shown, bytes, length);
    default:
        return;
    }
}

/* SHOWN's stream has something to read.  While its terminal has too much
   to parse, or the first paint holds too much, it waits unread, and so
   does the server, as the platform stops reading the socket. */
static void stream_ready(struct shown *shown)
{
    portal_text *messages = NULL, reason = {0}, error = {0};
    size_t count = 0;
    bool ended = false;
    int code = 0;
    uint64_t socket = shown->data, id = shown->id;
    shown->deferred = shown->backlogged || (shown->stage == PAINTING && shown->held.length >= HELD_MOST);
    if (shown->deferred || !socket)
        return;
    if (!portal_socket_read(socket, &messages, &count, &ended, &code, &reason, &error)) {
        free(error.data);
        return;
    }
    for (size_t i = 0; i < count; i++) {
        /* A message can end the show, which closes the socket; the rest are
           dropped with it. */
        if (shown_by_id(id) == shown && shown->data == socket)
            stream_message(shown, messages[i].data, messages[i].length);
        free(messages[i].data);
    }
    free(messages);
    if (ended && shown_by_id(id) == shown && shown->data == socket)
        stream_ended(shown, code, view(reason));
    free(reason.data);
}

/* The paint so far is complete: feed it, then what the stream brought
   meanwhile.  Output written between the snapshot and the "format" is in
   both; only a snapshot restore, which follows the stream exactly, would
   avoid that.  A terminal painted before, for a stream that started over,
   is reset first, its history with it. */
static void paint(struct shown *shown)
{
    /* The paint is laid out for the block's grid, which the stream gives,
       on a connection of its own that may be behind the paint's. */
    shown->paint_waits = !shown->columns || !shown->rows;
    if (shown->paint_waits)
        return;
    struct bytes held = shown->held;
    shown->held = (struct bytes) {0};
    if (shown->paint.failed || held.failed) {
        clear(&held);
        return end_show(shown, FAILED, "Portal is out of memory", literal(""));
    }
    if (shown->painted_once)
        feed(shown, "\x1b" "c\x1b[3J", 6);
    shown->painted_once = true;
    hold(shown);
    feed(shown, shown->paint.data, shown->paint.length);
    clear(&shown->paint);
    shown->stage = LIVE;
    feed(shown, held.data, held.length);
    clear(&held);
    announce(shown);
    /* The stream waited while the paint held too much. */
    if (shown->deferred)
        stream_ready(shown);
}

/* Add the string member NAME of PAYLOAD to the paint; false having failed
   SHOWN if there is none. */
static bool take_part(struct shown *shown, portal_string payload, const char *name)
{
    portal_string value;
    portal_text part = {0};
    if (!portal_json_member(payload, name, &value) || !portal_json_string(value, &part)) {
        end_show(shown, FAILED, "The server's paint has no text", literal(""));
        return false;
    }
    append(&shown->paint, part.data, part.length);
    free(part.data);
    return true;
}

/* Ask for the paint's next part, from where it has come to. */
static void read_next(struct shown *shown)
{
    struct json json = {0};
    put_block(&json, shown);
    put_text(&json, ",\"args\":{\"id\":");
    put_number(&json, (uint64_t) shown->blob);
    put_text(&json, ",\"offset\":");
    put_number(&json, shown->paint.length);
    put_text(&json, ",\"max_bytes\":");
    put_number(&json, PAINT_BYTES);
    put_text(&json, "}}");
    ask(shown, "com.superlogical.terminal.blob_read", &json, read_part);
}

static void painted(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, value;
    if (!succeeded(shown, "com.superlogical.terminal.format", response, length, &payload)
        || !take_part(shown, payload, "content"))
        return;
    /* A reply with an id holds only the first part. */
    if (portal_json_member(payload, "id", &value) && portal_json_integer(value, &shown->blob))
        return read_next(shown);
    paint(shown);
}

static void read_part(struct shown *shown, const char *response, size_t length)
{
    portal_string payload, value;
    if (!succeeded(shown, "com.superlogical.terminal.blob_read", response, length, &payload))
        return;
    size_t before = shown->paint.length;
    if (!take_part(shown, payload, "data"))
        return;
    bool eof = portal_json_member(payload, "eof", &value) && is(value, "true");
    if (eof)
        return paint(shown);
    if (shown->paint.length == before)
        return end_show(shown, FAILED, "The server's paint stopped short", literal(""));
    read_next(shown);
}

/* Operations: typing, focus, size and takes, one request at a time. */

static void free_operation(struct operation *operation)
{
    clear(&operation->bytes);
}

/* Queue OPERATION for SHOWN, joining it to the last one where they are
   alike: typing to typing, a size to the size it replaces, and a take to a
   take. */
static void queue(struct shown *shown, struct operation operation)
{
    if (shown->stage >= FAILED)
        return free_operation(&operation);
    struct operation *last = shown->queued ? &shown->operations[shown->queued - 1] : NULL;
    if (last && last->kind == WRITE && operation.kind == WRITE) {
        append(&last->bytes, operation.bytes.data, operation.bytes.length);
        free_operation(&operation);
    } else if (last && last->kind == operation.kind
               && (operation.kind == RESIZE || operation.kind == TAKE)) {
        free_operation(&operation);
    } else {
        struct operation *grown =
            realloc(shown->operations, (shown->queued + 1) * sizeof *grown);
        if (!grown) {
            free_operation(&operation);
            return;
        }
        shown->operations = grown;
        shown->operations[shown->queued++] = operation;
    }
    next_operation(shown);
}

/* LENGTH BYTES as a JSON string: valid UTF-8 as it is, anything else as
   U+FFFD, since a write takes a string.  A legacy mouse report past column
   95 has such a byte, and arrives wrong. */
static void put_bytes(struct json *json, const char *bytes, size_t length)
{
    struct json valid = {0};
    const unsigned char *at = (const unsigned char *) bytes, *end = at + length;
    while (at < end) {
        size_t count = *at < 0x80 ? 1 : *at >= 0xc2 && *at < 0xe0 ? 2
            : *at >= 0xe0 && *at < 0xf0                       ? 3
            : *at >= 0xf0 && *at < 0xf5                       ? 4
                                                              : 0;
        bool good = count && (size_t) (end - at) >= count;
        for (size_t i = 1; good && i < count; i++)
            good = (at[i] & 0xc0) == 0x80;
        if (good && count == 3)
            good = !(at[0] == 0xe0 && at[1] < 0xa0) && !(at[0] == 0xed && at[1] >= 0xa0);
        if (good && count == 4)
            good = !(at[0] == 0xf0 && at[1] < 0x90) && !(at[0] == 0xf4 && at[1] >= 0x90);
        if (good) {
            put(&valid, (const char *) at, count);
            at += count;
        } else {
            put(&valid, "\xef\xbf\xbd", 3);
            at++;
        }
    }
    put_string(json, (portal_string) {valid.data ? valid.data : "", valid.length});
    if (valid.failed)
        json->failed = true;
    free(valid.data);
}

static void next_operation(struct shown *shown)
{
    /* Nothing goes before the block is claimed: a take or a key could
       reach the server before the session is attached. */
    if (shown->sending || !shown->queued || shown->stage < SIZING)
        return;
    struct operation operation = shown->operations[0];
    memmove(shown->operations, shown->operations + 1, --shown->queued * sizeof *shown->operations);
    struct json json = {0};
    const char *method;
    uint32_t values[4];
    int kind = operation.kind;
    switch (operation.kind) {
    case WRITE:
        method = "com.superlogical.terminal.write";
        put_block(&json, shown);
        put_text(&json, ",\"args\":{\"data\":");
        put_bytes(&json, operation.bytes.data, operation.bytes.length);
        put_text(&json, "}}");
        break;
    case FOCUS:
        method = "block.event";
        put_block(&json, shown);
        put_text(&json, operation.in
                     ? ",\"event\":{\"type\":\"focus\",\"payload\":{\"action\":\"in\"}}}"
                     : ",\"event\":{\"type\":\"focus\",\"payload\":{\"action\":\"out\"}}}");
        break;
    case TAKE:
        method = "session.own_block";
        put_claim(&json, shown, "take");
        break;
    case RESIZE:
    default:
        method = "com.superlogical.terminal.resize";
        if (!grid(shown, values) || !memcmp(values, shown->sized, sizeof values)) {
            free_operation(&operation);
            return next_operation(shown);
        }
        put_resize(&json, shown, values);
        break;
    }
    free_operation(&operation);
    struct connection *connection = find(shown->connection, NULL);
    uint64_t request;
    portal_text error = {0};
    struct pending *grown = !connection || connection->ended || json.failed
        ? NULL
        : realloc(connection->pending, (connection->asked + 1) * sizeof *grown);
    if (grown)
        connection->pending = grown;
    /* Typing that cannot go is lost, as typing into a closed pty is. */
    if (grown && send_request(connection, literal(method), (portal_string) {json.data, json.length},
                              &request, &error)) {
        connection->pending[connection->asked++] =
            (struct pending) {.number = request, .answer = kind == TAKE ? taken : operated,
                              .shown = shown->id};
        shown->sending = true;
    } else if (kind == TAKE) {
        shown->taking = false;
    }
    free(error.data);
    free(json.data);
    if (!shown->sending)
        next_operation(shown);
}

/* An operation's answer: the next may go.  A refused one is dropped, as
   the server has already moved on from it. */
static void operated(struct shown *shown, const char *response, size_t length)
{
    (void) response;
    (void) length;
    shown->sending = false;
    next_operation(shown);
}

/* A take's answer, which says who owns the block now: Emacs, unless a
   take of another client's overtook it. */
static void taken(struct shown *shown, const char *response, size_t length)
{
    portal_string payload;
    shown->taking = false;
    if (told(response, length, &payload))
        take_owners(shown, payload, seq_of((portal_string) {response, length}));
    operated(shown, response, length);
}

/* Whether BYTES are a report the terminal makes of its own state, which the
   server makes for itself: focus in or out (mode 1004), the size in pixels
   (mode 2048), or the colour scheme (mode 2031).  Each is written alone. */
static bool own_report(const char *bytes, size_t length)
{
    if ((length == 3 && (!memcmp(bytes, "\x1b[I", 3) || !memcmp(bytes, "\x1b[O", 3)))
        || (length == 9 && (!memcmp(bytes, "\x1b[?997;1n", 9) || !memcmp(bytes, "\x1b[?997;2n", 9))))
        return true;
    /* ESC [ 48 ; ROWS ; COLUMNS ; HEIGHT ; WIDTH t */
    if (length < 13 || memcmp(bytes, "\x1b[48;", 5) || bytes[length - 1] != 't')
        return false;
    int fields = 1;
    bool digit = false;
    for (size_t i = 5; i < length - 1; i++) {
        if (bytes[i] >= '0' && bytes[i] <= '9') {
            digit = true;
        } else if (bytes[i] == ';' && digit) {
            fields++;
            digit = false;
        } else {
            return false;
        }
    }
    return digit && fields == 4;
}

/* Claim SHOWN's block with "take", once for as long as a take waits. */
static void take(struct shown *shown)
{
    if (shown->taking || shown->stage >= FAILED)
        return;
    shown->taking = true;
    queue(shown, (struct operation) {.kind = TAKE});
}

void portal_rex_input(portal_string target, const char *bytes, size_t length)
{
    struct shown *shown = shown_in(target);
    if (!shown || !length || own_report(bytes, length))
        return;
    /* Typing into a block whose connection is lost goes nowhere, and Emacs
       says so. */
    if (shown->offline) {
        shown->typed = true;
        return announce(shown);
    }
    /* Typing is using the block, as in Rex's app: a block another client
       took meanwhile, such as a phone, comes back first. */
    if (!mine(shown))
        take(shown);
    struct operation operation = {.kind = WRITE};
    append(&operation.bytes, bytes, length);
    if (!operation.bytes.failed)
        queue(shown, operation);
}

void portal_rex_focus(portal_string target, bool focused)
{
    struct shown *shown = shown_in(target);
    if (shown && !shown->offline)
        queue(shown, (struct operation) {.kind = FOCUS, .in = focused});
}

bool portal_rex_take(portal_string target, portal_text *error)
{
    struct shown *shown = shown_in(target);
    if (!shown)
        return fail(error, "No block is shown in ", target);
    take(shown);
    return true;
}

void portal_rex_backlog(portal_string target, bool backlogged)
{
    struct shown *shown = shown_in(target);
    if (!shown)
        return;
    shown->backlogged = backlogged;
    if (!backlogged && shown->deferred)
        stream_ready(shown);
}

void portal_rex_grid(portal_string target)
{
    struct shown *shown = shown_in(target);
    if (!shown)
        return;
    if (shown->stage == SIZING)
        settle(shown);
    else if (shown->stage > RESIZING && shown->stage < FAILED)
        queue(shown, (struct operation) {.kind = RESIZE});
}

/* Start SHOWN: attach to its session unless the connection has, then
   claim the block, and the rest follows. */
static void begin(struct shown *shown)
{
    struct connection *connection = find(shown->connection, NULL);
    bool joined = false;
    for (size_t i = 0; connection && !joined && i < connection->sessions; i++)
        joined = strlen(connection->attached[i]) == shown->session.length
            && !memcmp(connection->attached[i], shown->session.data, shown->session.length);
    if (joined) {
        own(shown);
    } else {
        struct json json = {0};
        put_text(&json, "{\"session_id\":");
        put_string(&json, view(shown->session));
        put_text(&json, "}");
        shown->stage = ATTACHING;
        ask(shown, "session.attach", &json, attached);
    }
}

/* Start SHOWN again from the beginning, on the terminal it has, for a
   connection that is back: what the server knew of Emacs may be gone. */
static void restart_show(struct shown *shown)
{
    fresh_stream(shown);
    shown->restart = false;
    shown->sending = false;
    shown->timer = 0;
    shown->tries = 0;
    begin(shown);
}

bool portal_rex_show(uint64_t id, portal_string target, portal_string session,
                     portal_string block, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection)
        return false;
    if (connection->ended)
        return fail_with(error, "The Rex connection has ended");
    if (connection->lost)
        return fail_with(error, "The Rex connection is lost, and connects again by itself");
    if (!portal_views_fed(target))
        return fail(error, "No fed terminal ", target);
    if (shown_in(target))
        return fail(error, "A block is shown already in ", target);
    if (!session.length || !block.length)
        return fail_with(error, "A block to show needs a session and a block ID");
    for (size_t i = 0; i < shows.count; i++)
        if (shows.items[i]->connection == id && same(shows.items[i]->block, block)
            && shows.items[i]->stage < FAILED)
            return fail(error, "The block is shown already: ", block);
    struct shown *shown = calloc(1, sizeof *shown);
    struct shown **grown = shown ? realloc(shows.items, (shows.count + 1) * sizeof *grown) : NULL;
    if (grown)
        shows.items = grown;
    if (!grown || !copy(target, &shown->target) || !copy(session, &shown->session)
        || !copy(block, &shown->block)) {
        if (shown) {
            free(shown->target.data);
            free(shown->session.data);
            free(shown->block.data);
        }
        free(shown);
        return out_of_memory(error);
    }
    shown->id = ++shows.last;
    shown->connection = id;
    shows.items[shows.count++] = shown;
    begin(shown);
    return true;
}

static const char *const states[] = {
    [ATTACHING] = "starting", [OWNING] = "starting",   [SIZING] = "starting",
    [RESIZING] = "starting",  [CONNECTING] = "starting", [GREETING] = "starting",
    [SKIPPING] = "starting",  [PAINTING] = "starting", [LIVE] = "live",
    [FAILED] = "failed",      [ENDED] = "ended",
};

void portal_rex_describe(portal_string target, struct json *json)
{
    struct shown *shown = shown_in(target);
    if (!shown)
        return;
    shown->announced = false;
    /* Every server Portal reaches is on this Mac, so the block's directory
       is the terminal's. */
    put_text(json, ",\"title\":");
    put_string(json, shown->title.data ? view(shown->title) : literal(""));
    put_text(json, ",\"pwd\":");
    put_string(json, directory(shown));
    put_text(json, ",\"program\":");
    put_string(json, shown->program.data ? view(shown->program) : literal(""));
    put_text(json, shown->exited ? ",\"exited\":true" : ",\"exited\":false");
    put_text(json, ",\"rex\":{\"state\":");
    put_string(json, literal(shown->offline && shown->stage < FAILED ? "disconnected"
                                                                      : states[shown->stage]));
    if (shown->typed)
        put_text(json, ",\"typed\":true");
    shown->typed = false;
    put_text(json, ",\"columns\":");
    put_number(json, shown->columns);
    put_text(json, ",\"rows\":");
    put_number(json, shown->rows);
    put_text(json, ",\"owner\":");
    put_string(json, literal(!shown->owner_known ? "unknown"
                             : mine(shown)       ? "self"
                             : shown->owner.length ? "other"
                                                   : "none"));
    put_text(json, ",\"owner_name\":");
    put_string(json, shown->owner_name.data ? view(shown->owner_name) : literal(""));
    put_text(json, ",\"directory\":");
    put_string(json, directory(shown));
    if (shown->stage >= FAILED) {
        put_text(json, ",\"reason\":");
        put_string(json, shown->reason.data ? view(shown->reason) : literal(""));
    }
    put_text(json, "}");
}

void portal_rex_closed(portal_string target)
{
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (!same(shown->target, target))
            continue;
        stop_stream(shown);
        memmove(shows.items + i, shows.items + i + 1, (--shows.count - i) * sizeof *shows.items);
        for (size_t k = 0; k < shown->queued; k++)
            free_operation(&shown->operations[k]);
        free(shown->operations);
        clear(&shown->snapshot);
        clear(&shown->tail);
        clear(&shown->held);
        clear(&shown->paint);
        free(shown->target.data);
        free(shown->session.data);
        free(shown->block.data);
        free(shown->reason.data);
        free(shown->title.data);
        free(shown->reported.data);
        free(shown->cwd.data);
        free(shown->program.data);
        free(shown->owner.data);
        free(shown->owner_name.data);
        free(shown);
        return;
    }
}

/* Reading the control connection. */

static uint64_t shown_paints(struct shown *shown)
{
    return shown ? shown->paints : 0;
}

/* The response MESSAGE answers one of CONNECTION's own requests: take it
   out, and give it to its show.  False for anything else. */
static bool own_response(struct connection *connection, portal_text message)
{
    portal_string type, id;
    portal_text decoded = {0};
    if (!connection->asked || !portal_json_member(view(message), "type", &type)
        || !portal_json_is(type, "response") || !portal_json_member(view(message), "id", &id)
        || !portal_json_string(id, &decoded))
        return false;
    int64_t request = 0;
    bool numbered = portal_json_integer(view(decoded), &request);
    free(decoded.data);
    for (size_t i = 0; numbered && i < connection->asked; i++) {
        if (connection->pending[i].number != (uint64_t) request)
            continue;
        struct pending pending = connection->pending[i];
        memmove(connection->pending + i, connection->pending + i + 1,
                (--connection->asked - i) * sizeof *connection->pending);
        struct shown *shown = shown_by_id(pending.shown);
        /* A show that has failed takes no more answers, but its typing's;
           nor does a paint that a later one replaced; and one that started
           a new stream none of the old one's steps: what its terminal
           reports, who owns it, and its typing hold for either. */
        bool stale = (pending.answer == painted || pending.answer == read_part)
            && pending.paint != shown_paints(shown);
        bool current = shown && shown->generation == pending.generation;
        bool lasting = pending.answer == operated || pending.answer == taken
            || pending.answer == named || pending.answer == told_title
            || pending.answer == told_directory || pending.answer == told_process;
        if (shown && !stale && (current || lasting)
            && (shown->stage < FAILED || pending.answer == operated || pending.answer == taken))
            pending.answer(shown, message.data, message.length);
        return true;
    }
    return false;
}

/* MESSAGE, if it is an event of a block shown on CONNECTION, tells the
   show what the block reported: what its terminal says of itself, that
   another client owns it now, or that the block closed.  It goes on to
   Emacs all the same. */
static void block_event(struct connection *connection, portal_text message)
{
    bool showing = false;
    for (size_t i = 0; !showing && i < shows.count; i++)
        showing = shows.items[i]->connection == connection->id;
    portal_string whole = view(message), type, payload, fields, event, kind, block;
    portal_text id = {0};
    if (!showing || !portal_json_member(whole, "type", &type) || !portal_json_is(type, "event")
        || !portal_json_member(whole, "payload", &payload)
        || !portal_json_member(payload, "type", &type) || !portal_json_is(type, "session_event")
        || !portal_json_member(payload, "payload", &fields)
        || !portal_json_member(fields, "event", &event)
        || !portal_json_member(event, "type", &kind)
        || !portal_json_member(event, "payload", &fields)
        || !portal_json_member(fields, "block_id", &block) || !portal_json_string(block, &id))
        return;
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->connection != connection->id || !same(shown->block, view(id)))
            continue;
        if (portal_json_is(kind, "block_event")) {
            terminal_event(shown, fields, seq_of(whole));
        } else if (portal_json_is(kind, "block_owner_changed")) {
            portal_string owner;
            bool owned = portal_json_member(fields, "owner", &owner) && !is(owner, "null");
            if (take_owner(shown, owned ? &owner : NULL, seq_of(whole)))
                changed(shown);
        } else if (portal_json_is(kind, "block_closed")) {
            shown->closed = true;
            exit_later(shown);
        }
    }
    free(id.data);
}

/* CONNECTION's end, for the core's own requests and shows. */
static void ended(struct connection *connection)
{
    while (connection->asked) {
        struct pending pending = connection->pending[--connection->asked];
        struct shown *shown = shown_by_id(pending.shown);
        if (shown && (pending.answer == operated || pending.answer == taken))
            shown->sending = false;
    }
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->connection == connection->id) {
            for (size_t k = 0; k < shown->queued; k++)
                free_operation(&shown->operations[k]);
            shown->queued = 0;
            shown->offline = false;
            end_show(shown, shown->stage == LIVE ? ENDED : FAILED,
                     "The connection to the server ended", literal(""));
        }
    }
}

/* Coming back. */

/* Whether a connection that ended with the close frame CODE, for REASON,
   is not to be tried again: the server will refuse a client like this
   one each time. */
static bool final(int code, portal_string reason)
{
    static const char backlog[] = "event backlog exceeded";
    bool behind = false;
    for (size_t i = 0; i + sizeof backlog - 1 <= reason.length && !behind; i++)
        behind = !memcmp(reason.data + i, backlog, sizeof backlog - 1);
    return code == 1002 || code == 1003 || code == 1007 || code == 1009
        || (code == 1008 && !behind);
}

/* Put MESSAGE, which the core made, among CONNECTION's messages for Emacs. */
static void tell(struct connection *connection, struct json *message)
{
    portal_text *grown = message->failed
        ? NULL
        : realloc(connection->inbox, (connection->waiting + 1) * sizeof *grown);
    if (grown) {
        connection->inbox = grown;
        connection->inbox[connection->waiting++] = (portal_text) {message->data, message->length};
    } else {
        free(message->data);
    }
    *message = (struct json) {0};
}

/* Try CONNECTION's server again after a while, longer at each try. */
static void try_later(struct connection *connection)
{
    uint64_t wait = RETRY_MILLISECONDS;
    for (unsigned i = 0; i < connection->tries && wait < LONGEST_RETRY_MILLISECONDS; i++)
        wait *= 2;
    connection->tries++;
    connection->retry = portal_channel_timer(wait < LONGEST_RETRY_MILLISECONDS
                                             ? wait : LONGEST_RETRY_MILLISECONDS);
}

/* Give up CONNECTION's socket, if it has one. */
static void hang_up(struct connection *connection)
{
    if (!connection->socket)
        return;
    portal_text ignored = {0};
    if (!portal_socket_close(connection->socket, &ignored))
        free(ignored.data);
    connection->socket = 0;
    connection->welcomed = false;
}

/* CONNECTION, which had a welcome, has lost its socket because of REASON.
   The server keeps the client a while, so the connection tries it again,
   until a try has a welcome.  Meanwhile Emacs's requests fail, as do the
   core's: a block shown starts again once the connection is back, and one
   live keeps its stream, which may still be up, but takes no typing.
   Emacs hears of the loss as a message of the core's, among the server's,
   {"type":"portal_lost","reason":REASON}. */
static void lose(struct connection *connection, portal_string reason)
{
    hang_up(connection);
    connection->lost = true;
    connection->tries = 0;
    connection->asked = 0;
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->connection != connection->id || shown->stage >= FAILED)
            continue;
        for (size_t k = 0; k < shown->queued; k++)
            free_operation(&shown->operations[k]);
        shown->queued = 0;
        shown->sending = false;
        shown->taking = false;
        shown->offline = true;
        if (shown->stage < LIVE) {
            shown->restart = true;
            shown->timer = 0;
            stop_stream(shown);
        }
        announce(shown);
    }
    struct json json = {0};
    put_text(&json, "{\"type\":\"portal_lost\",\"reason\":");
    put_string(&json, reason);
    put_text(&json, "}");
    tell(connection, &json);
    try_later(connection);
}

/* Try CONNECTION's server again: a new socket, and a hello that continues
   the client with the last welcome's token.  The try has a while for its
   welcome. */
static void try_again(struct connection *connection)
{
    struct json hello = {0};
    put_hello(&hello, view(connection->name), view(connection->version), view(connection->token));
    uint64_t socket = ++connections.last;
    portal_text error = {0};
    bool opened = !hello.failed
        && portal_socket_open(socket, literal(connection->path), literal(CONTROL_RESOURCE),
                              literal(CONTROL_PROTOCOL), false, &error);
    if (opened) {
        connection->socket = socket;
        if (!portal_socket_send(socket, (portal_string) {hello.data, hello.length}, &error))
            hang_up(connection);
    }
    free(hello.data);
    free(error.data);
    if (!connection->socket)
        return try_later(connection);
    connection->retry = portal_channel_timer(WELCOME_MILLISECONDS);
}

/* MESSAGE is the welcome of CONNECTION's socket: keep its reconnect token.
   After a loss, the connection is back, as the same client if the welcome
   says it resumed; a new client has no sessions attached and owns no
   block, and each block shown starts again once Emacs resumes them.
   Every seq starts again at 1. */
static void welcomed(struct connection *connection, portal_string message)
{
    portal_string client, value;
    portal_text token = {0}, id = {0};
    connection->welcomed = true;
    /* Which client this is, for telling the blocks Emacs owns from those
       other clients do: a new one after a loss, unless resumed. */
    if (portal_json_member(message, "client", &client) && portal_json_member(client, "id", &value)
        && portal_json_string(value, &id)) {
        free(connection->client);
        connection->client = id.data;
    }
    if (portal_json_member(message, "client", &client)
        && portal_json_member(client, "reconnect_token", &value)
        && portal_json_string(value, &token)) {
        free(connection->token.data);
        connection->token = token;
    }
    bool resumed = portal_json_member(message, "client", &client)
        && portal_json_member(client, "resumed", &value) && is(value, "true");
    if (!connection->ever) {
        connection->ever = true;
        return;
    }
    connection->lost = false;
    connection->retry = 0;
    connection->tries = 0;
    if (!resumed) {
        for (size_t i = 0; i < connection->sessions; i++)
            free(connection->attached[i]);
        connection->sessions = 0;
    }
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->connection != connection->id)
            continue;
        memset(shown->seqs, 0, sizeof shown->seqs);
        if (!resumed) {
            shown->restart = true;
            stop_stream(shown);
        }
    }
}

bool portal_rex_resume(uint64_t id, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection)
        return false;
    if (connection->lost)
        return fail_with(error, "The Rex connection is not back yet");
    for (size_t i = 0; i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->connection != id || !shown->offline)
            continue;
        shown->offline = false;
        if (shown->stage >= FAILED)
            continue;
        if (shown->restart) {
            restart_show(shown);
        } else {
            /* Events were lost meanwhile: ask again what they said. */
            ask_details(shown);
            if (shown->waiting)
                resume_stream(shown);
        }
        announce(shown);
    }
    return true;
}

/* Read what the platform has for CONNECTION: the core's answers it handles,
   the rest wait for Emacs.  A socket that ends is the connection's end,
   unless it had a welcome and the server may take the client back: then
   the connection is lost, and tries again. */
static void pump(struct connection *connection)
{
    if (connection->ended || !connection->socket)
        return;
    portal_text *messages = NULL, reason = {0}, error = {0};
    size_t count = 0;
    bool over = false;
    int code = 0;
    uint64_t socket = connection->socket;
    if (!portal_socket_read(socket, &messages, &count, &over, &code, &reason, &error)) {
        free(error.data);
        return;
    }
    for (size_t i = 0; i < count; i++) {
        portal_string type;
        /* A try's messages before its welcome are no one's. */
        if (connection->lost && !connection->welcomed
            && !(portal_json_member(view(messages[i]), "type", &type)
                 && portal_json_is(type, "welcome"))) {
            free(messages[i].data);
            continue;
        }
        if (!connection->welcomed && portal_json_member(view(messages[i]), "type", &type)
            && portal_json_is(type, "welcome"))
            welcomed(connection, view(messages[i]));
        /* An answer can make requests, but never opens or closes a
           connection, so CONNECTION stays where it is. */
        if (own_response(connection, messages[i])) {
            free(messages[i].data);
            continue;
        }
        block_event(connection, messages[i]);
        portal_text *grown = realloc(connection->inbox, (connection->waiting + 1) * sizeof *grown);
        if (!grown) {
            free(messages[i].data); /* No memory: lost, as the platform's limit loses one. */
            continue;
        }
        connection->inbox = grown;
        connection->inbox[connection->waiting++] = messages[i];
    }
    free(messages);
    if (!over) {
        free(reason.data);
    } else if (connection->lost && !connection->welcomed && !final(code, view(reason))) {
        /* A try that failed: the next comes later.  One the server refuses
           for good ends the connection, below. */
        free(reason.data);
        hang_up(connection);
        try_later(connection);
    } else if (connection->ever && !final(code, view(reason))) {
        lose(connection, view(reason));
        free(reason.data);
    } else {
        connection->ended = true;
        connection->reason = reason;
        ended(connection);
    }
}

bool portal_rex_receive(uint64_t id, portal_text **messages, size_t *count, bool *ended_now,
                        portal_text *reason, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection)
        return false;
    pump(connection);
    portal_text *texts = connection->inbox;
    if (!texts && !(texts = malloc(sizeof *texts)))
        return out_of_memory(error);
    *messages = texts;
    *count = connection->waiting;
    connection->inbox = NULL;
    connection->waiting = 0;
    connection->announced = false;
    *ended_now = connection->ended;
    if (connection->ended) {
        *reason = connection->reason;
        connection->reason = (portal_text) {0};
        /* The socket has nothing more to say; a platform that cannot close
           it now has ended it all the same. */
        hang_up(connection);
        forget(connection);
    }
    return true;
}

/* Milliseconds on a clock that only goes forward. */
static uint64_t now(void)
{
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t) time.tv_sec * 1000 + (uint64_t) time.tv_nsec / 1000000;
}

bool portal_rex_wait(uint64_t id, uint64_t milliseconds, bool *ready, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection)
        return false;
    uint64_t deadline = now() + milliseconds;
    for (;;) {
        pump(connection);
        *ready = connection->waiting || connection->ended;
        /* One reading of the clock: two could straddle the deadline, and
           the difference would wrap to a wait of hours. */
        uint64_t time = now(), left = deadline > time ? deadline - time : 0;
        /* Between tries there is no socket to wait on. */
        if (*ready || !left || !connection->socket)
            return true;
        bool readable = false;
        if (!portal_socket_wait(connection->socket, left, &readable, error))
            return false;
        /* The core's own answers may be all that came: wait on for Emacs's. */
        if (!readable)
            return true;
    }
}

bool portal_rex_close(uint64_t id, portal_text *error)
{
    struct connection *connection = find(id, error);
    if (!connection || (connection->socket && !portal_socket_close(connection->socket, error)))
        return false;
    connection->socket = 0;
    connection->ended = true;
    ended(connection);
    forget(connection);
    return true;
}

/* A timer of CONNECTION's: a try is due, or a try's welcome is late. */
static void retried(struct connection *connection)
{
    connection->retry = 0;
    if (!connection->lost)
        return;
    if (!connection->socket)
        return try_again(connection);
    if (!connection->welcomed) {
        hang_up(connection);
        try_later(connection);
    }
}

void portal_rex_timer(uint64_t token)
{
    for (size_t i = 0; token && i < shows.count; i++) {
        struct shown *shown = shows.items[i];
        if (shown->timer == token) {
            shown->timer = 0;
            if (shown->stage == SIZING)
                size(shown);
            return;
        }
        if (shown->exit_timer == token)
            return exited(shown);
    }
    for (size_t i = 0; token && i < connections.count; i++)
        if (connections.items[i].retry == token)
            return retried(&connections.items[i]);
}

/* The platform's call, from portal.h. */

void portal_socket_ready(uint64_t socket)
{
    for (size_t i = 0; i < shows.count; i++)
        if (shows.items[i]->data == socket)
            return stream_ready(shows.items[i]);
    struct connection *connection = on_socket(socket);
    if (!connection)
        return;
    pump(connection);
    char word[24];
    /* A record the pipe refuses is tried again with the next report. */
    if ((connection->waiting || connection->ended) && !connection->announced)
        connection->announced =
            portal_channel_send(literal("rex"), number(connection->id, word), NULL, 0);
}
