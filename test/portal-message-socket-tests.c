/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Message sockets, native/Shared/message-socket.c, against a server this
   program plays on real Unix sockets in a directory of its own.  No Emacs
   and no backend: this thread is the module thread, which never waits for a
   server but in wait, so it plays the server too, between the calls.

   The file under test is included, not linked, to reach what it keeps to
   itself: its SHA-1, base64 and UTF-8 are checked against published values
   first, and the server here then answers upgrades with them. */
#include "message-socket.c"

#include <dirent.h>
#include <stdatomic.h>
#include <sys/stat.h>

static int failures;
/* How many checks ran: the program ends by printing it. */
static int checks;

#define CHECK(condition) check((condition), #condition, __LINE__)

static bool check(bool passed, const char *condition, int line)
{
    checks++;
    if (!passed) {
        fprintf(stderr, "%s:%d: FAIL: %s\n", __FILE__, line, condition);
        failures++;
    }
    return passed;
}

/* Check that CONDITION comes true within two seconds, looking again each
   millisecond. */
#define EVENTUALLY(condition) \
    do { \
        bool came_ = false; \
        for (int tries_ = 0; tries_ < 2000 && !(came_ = (condition)); tries_++) \
            nanosleep(&(struct timespec) {.tv_nsec = 1000000}, NULL); \
        check(came_, #condition, __LINE__); \
    } while (0)

/* The directory the servers listen in, and the path of the server NAME. */
static char directory[64];
static char path_buffer[128];

static portal_string string(const char *text)
{
    return (portal_string) {text, strlen(text)};
}

static const char *path_of(const char *name)
{
    snprintf(path_buffer, sizeof path_buffer, "%s/%s", directory, name);
    return path_buffer;
}

/* How often each socket's wake was called, by the socket's name. */
static atomic_int woken[64];

static void wake(uint64_t socket, void *context)
{
    (void) context;
    atomic_fetch_add(&woken[socket % 64], 1);
}

/* The server's side. */

static int listen_at(const char *name)
{
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof address.sun_path, "%s", path_of(name));
    unlink(address.sun_path);
    if (bind(listener, (struct sockaddr *) &address, sizeof address) || listen(listener, 8)) {
        perror("listen");
        exit(2);
    }
    return listener;
}

/* Accept a connection within two seconds, or -1. */
static int accept_one(int listener)
{
    struct pollfd wait = {.fd = listener, .events = POLLIN};
    if (poll(&wait, 1, 2000) <= 0)
        return -1;
    int connection = accept(listener, NULL, NULL);
    struct timeval patience = {.tv_sec = 2};
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &patience, sizeof patience);
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, sizeof patience);
    return connection;
}

/* Read exactly LENGTH bytes from the client, or fewer at its end or after
   two seconds; return how many. */
static size_t server_read(int connection, void *bytes, size_t length)
{
    size_t have = 0;
    while (have < length) {
        ssize_t count = read(connection, (char *) bytes + have, length - have);
        if (count <= 0)
            break;
        have += (size_t) count;
    }
    return have;
}

static bool server_write(int connection, const void *bytes, size_t length)
{
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = send(connection, (const char *) bytes + sent, length - sent, MSG_NOSIGNAL);
        if (count <= 0)
            return false;
        sent += (size_t) count;
    }
    return true;
}

/* Read the client's upgrade request into REQUEST, NUL-terminated; false
   if none came whole. */
static bool server_request(int connection, char *request, size_t capacity)
{
    size_t length = 0;
    while (length + 1 < capacity) {
        if (server_read(connection, request + length, 1) != 1)
            return false;
        request[++length] = '\0';
        if (length >= 4 && !strcmp(request + length - 4, "\r\n\r\n"))
            return true;
    }
    return false;
}

/* Accept a connection and answer its upgrade for PROTOCOL as a WebSocket
   server does; the connection, or -1.  REQUEST, if not NULL, gets what the
   client asked, in 1024 bytes. */
static int server_upgrade(int listener, const char *protocol, char *request)
{
    char asked[1024], accept[29], answer[512];
    int connection = accept_one(listener);
    if (connection < 0 || !server_request(connection, asked, sizeof asked))
        return -1;
    const char *key = strstr(asked, "Sec-WebSocket-Key: ");
    if (!key)
        return -1;
    accept_of(key + strlen("Sec-WebSocket-Key: "), accept);
    int length = snprintf(answer, sizeof answer,
                          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n"
                          "Sec-WebSocket-Protocol: %s\r\n\r\n",
                          accept, protocol);
    if (!server_write(connection, answer, (size_t) length))
        return -1;
    if (request)
        memcpy(request, asked, sizeof asked);
    return connection;
}

/* Send a server's frame: never masked.  FIRST is its first byte, the
   opcode with 0x80 for a final frame. */
static bool server_frame(int connection, unsigned first, const void *payload, size_t length)
{
    unsigned char header[10] = {(unsigned char) first};
    size_t size = 2;
    if (length < 126) {
        header[1] = (unsigned char) length;
    } else if (length < 65536) {
        header[1] = 126;
        header[2] = (unsigned char) (length >> 8);
        header[3] = (unsigned char) length;
        size = 4;
    } else {
        header[1] = 127;
        for (int i = 0; i < 8; i++)
            header[2 + i] = (unsigned char) ((uint64_t) length >> (56 - 8 * i));
        size = 10;
    }
    return server_write(connection, header, size) && server_write(connection, payload, length);
}

/* Read one frame of the client's: its first byte, or -1 at the end of the
   connection or for a frame no client may send.  PAYLOAD gets it unmasked
   and NUL-terminated, at most CAPACITY - 1 bytes, and *LENGTH its length. */
static int client_frame(int connection, char *payload, size_t capacity, size_t *length)
{
    unsigned char header[2], wide[8], mask[4];
    if (server_read(connection, header, 2) != 2)
        return -1;
    /* A client masks every frame. */
    if (!(header[1] & 0x80))
        return -1;
    uint64_t size = header[1] & 0x7f;
    if (size >= 126) {
        size_t count = size == 126 ? 2 : 8;
        if (server_read(connection, wide, count) != count)
            return -1;
        size = 0;
        for (size_t i = 0; i < count; i++)
            size = size << 8 | wide[i];
    }
    if (size >= capacity || server_read(connection, mask, 4) != 4
        || server_read(connection, payload, (size_t) size) != size)
        return -1;
    for (size_t i = 0; i < size; i++)
        payload[i] ^= (char) mask[i & 3];
    payload[size] = '\0';
    *length = (size_t) size;
    return header[0];
}

/* The client's side. */

/* What a read of a socket gave. */
struct taken {
    portal_text *messages;
    size_t count;
    bool ended;
    int code;
    portal_text reason;
};

static void drop(struct taken *taken)
{
    for (size_t i = 0; i < taken->count; i++)
        free(taken->messages[i].data);
    free(taken->messages);
    free(taken->reason.data);
    *taken = (struct taken) {0};
}

static bool open_socket(uint64_t socket, const char *name, const char *protocol, bool binary)
{
    portal_text error = {0};
    bool opened = portal_message_socket_open(socket, string(path_of(name)), string("/api/test"),
                                             string(protocol), binary, wake, NULL, &error);
    if (!opened)
        fprintf(stderr, "open: %s\n", error.data);
    free(error.data);
    return opened;
}

static bool send_text(uint64_t socket, const char *text, size_t length)
{
    portal_text error = {0};
    bool sent = portal_message_socket_send(socket, (portal_string) {text, length}, &error);
    free(error.data);
    return sent;
}

static bool ready_within(uint64_t socket, uint64_t milliseconds)
{
    portal_text error = {0};
    bool ready = false;
    return portal_message_socket_wait(socket, milliseconds, &ready, &error) && ready;
}

/* Read SOCKET once something is there, within two seconds. */
static struct taken take(uint64_t socket)
{
    struct taken taken = {0};
    portal_text error = {0};
    ready_within(socket, 2000);
    if (!portal_message_socket_read(socket, &taken.messages, &taken.count, &taken.ended,
                                    &taken.code, &taken.reason, &error)) {
        fprintf(stderr, "read: %s\n", error.data);
        free(error.data);
    }
    return taken;
}

static bool close_socket(uint64_t socket)
{
    portal_text error = {0};
    bool closed_ = portal_message_socket_close(socket, &error);
    free(error.data);
    return closed_;
}

/* Whether TAKEN is one message, the LENGTH bytes at TEXT. */
static bool is_message(const struct taken *taken, const char *text, size_t length)
{
    return taken->count == 1 && taken->messages[0].length == length
        && !memcmp(taken->messages[0].data, text, length)
        && taken->messages[0].data[length] == '\0';
}

/* Whether TAKEN is the end of a connection with no message, for REASON
   with CODE. */
static bool is_end(const struct taken *taken, const char *reason, int code)
{
    bool is = taken->count == 0 && taken->ended && taken->code == code && taken->reason.data
        && !strcmp(taken->reason.data, reason);
    if (!is)
        fprintf(stderr, "  got %zu messages, ended %d, code %d, reason %s\n", taken->count,
                taken->ended, taken->code, taken->reason.data ? taken->reason.data : "(none)");
    return is;
}

/* The descriptors this program started with, which whoever ran it left
   open, and how many it has open now beyond them. */
static bool inherited[256];

static int open_descriptors(void)
{
    int count = 0;
    for (int descriptor = 0; descriptor < 256; descriptor++)
        if (!inherited[descriptor] && fcntl(descriptor, F_GETFD) != -1)
            count++;
    return count;
}

/* The tests. */

static void hex(const unsigned char *bytes, size_t length, char *out)
{
    for (size_t i = 0; i < length; i++)
        sprintf(out + 2 * i, "%02x", bytes[i]);
}

static bool utf8_gives(const char *bytes, size_t length, const char *expected)
{
    struct bytes out = {0};
    put_utf8(&out, bytes, length);
    bool same = !out.failed && out.length == strlen(expected)
        && !memcmp(out.data ? out.data : "", expected, out.length);
    free(out.data);
    return same;
}

static void test_published_values(void)
{
    unsigned char digest[20];
    char text[41], encoded[32], accept[29];
    /* FIPS 180-4's examples, and one that needs a second block for its length. */
    sha1((const unsigned char *) "abc", 3, digest);
    hex(digest, 20, text);
    CHECK(!strcmp(text, "a9993e364706816aba3e25717850c26c9cd0d89d"));
    sha1((const unsigned char *) "", 0, digest);
    hex(digest, 20, text);
    CHECK(!strcmp(text, "da39a3ee5e6b4b0d3255bfef95601890afd80709"));
    const char *two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    sha1((const unsigned char *) two, strlen(two), digest);
    hex(digest, 20, text);
    CHECK(!strcmp(text, "84983e441c3bd26ebaae4aa1f95129e5e54670f1"));
    /* RFC 4648's. */
    static const char *const plain[] = {"", "f", "fo", "foo", "foob", "fooba", "foobar"};
    static const char *const coded[] = {"",         "Zg==",     "Zm8=",    "Zm9v",
                                        "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"};
    for (size_t i = 0; i < 7; i++) {
        base64((const unsigned char *) plain[i], strlen(plain[i]), encoded);
        CHECK(!strcmp(encoded, coded[i]));
    }
    /* RFC 6455's, section 1.3. */
    accept_of("dGhlIHNhbXBsZSBub25jZQ==", accept);
    CHECK(!strcmp(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));

    /* Well-formed text stays; each ill-formed stretch is one U+FFFD. */
#define BAD "\xef\xbf\xbd"
    CHECK(utf8_gives("plain", 5, "plain"));
    CHECK(utf8_gives("\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80", 9,
                     "\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80"));
    CHECK(utf8_gives("a\xff" "b", 3, "a" BAD "b"));
    /* A sequence cut short is one stretch, whatever follows it. */
    CHECK(utf8_gives("\xe2\x82", 2, BAD));
    CHECK(utf8_gives("\xf0\x9f\x98" "a", 4, BAD "a"));
    /* An overlong form, a surrogate and a lone continuation byte start no
       sequence: each byte is a stretch. */
    CHECK(utf8_gives("\xc0\xaf", 2, BAD BAD));
    CHECK(utf8_gives("\xed\xa0\x80", 3, BAD BAD BAD));
    CHECK(utf8_gives("\x80", 1, BAD));
    CHECK(utf8_gives("\xf4\x90\x80\x80", 4, BAD BAD BAD BAD));
#undef BAD
    /* A NUL is a character like another. */
    struct bytes out = {0};
    put_utf8(&out, "a\0b", 3);
    CHECK(out.length == 3 && !memcmp(out.data, "a\0b", 3));
    free(out.data);
}

static void test_text_both_ways(void)
{
    char request[1024], payload[256];
    size_t length;
    int listener = listen_at("text");
    int before = atomic_load(&woken[1]);
    CHECK(open_socket(1, "text", "test.v1", false));
    /* Sent before the connection is up: they go out first, in order. */
    CHECK(send_text(1, "one", 3));
    CHECK(send_text(1, "two", 3));
    int server = server_upgrade(listener, "test.v1", request);
    CHECK(server >= 0);
    CHECK(strstr(request, "GET /api/test HTTP/1.1\r\n") == request);
    CHECK(strstr(request, "\r\nUpgrade: websocket\r\n") != NULL);
    CHECK(strstr(request, "\r\nSec-WebSocket-Version: 13\r\n") != NULL);
    CHECK(strstr(request, "\r\nSec-WebSocket-Protocol: test.v1\r\n") != NULL);
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x81);
    CHECK(!strcmp(payload, "one"));
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x81);
    CHECK(!strcmp(payload, "two"));
    CHECK(send_text(1, "three", 5));
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x81);
    CHECK(!strcmp(payload, "three"));
    /* A long message, with a 16-bit length, and a longer one, with 64. */
    static char big[70000];
    memset(big, 'x', sizeof big);
    static char back[70001];
    CHECK(send_text(1, big, 300));
    CHECK(client_frame(server, back, sizeof back, &length) == 0x81 && length == 300);
    CHECK(send_text(1, big, sizeof big));
    CHECK(client_frame(server, back, sizeof back, &length) == 0x81 && length == sizeof big
          && !memcmp(back, big, sizeof big));

    /* Nothing has arrived: a wait runs out, and a read is empty. */
    CHECK(!ready_within(1, 30));
    CHECK(atomic_load(&woken[1]) == before);
    CHECK(server_frame(server, 0x81, "hello", 5));
    struct taken taken = take(1);
    CHECK(is_message(&taken, "hello", 5) && !taken.ended && taken.code == 0);
    drop(&taken);
    /* One wake for a socket that had nothing to read. */
    EVENTUALLY(atomic_load(&woken[1]) == before + 1);
    /* Two more before a read are one wake, and one read. */
    CHECK(server_frame(server, 0x81, "a", 1) && server_frame(server, 0x81, big, 300));
    CHECK(ready_within(1, 2000));
    struct taken both = {0};
    for (int tries = 0; tries < 2000 && both.count < 2; tries++) {
        struct taken more = take(1);
        both.messages =
            realloc(both.messages, (both.count + more.count + 1) * sizeof *more.messages);
        for (size_t i = 0; i < more.count; i++)
            both.messages[both.count++] = more.messages[i];
        free(more.messages);
        free(more.reason.data);
    }
    CHECK(both.count == 2 && both.messages[0].length == 1 && both.messages[1].length == 300);
    drop(&both);

    /* A message in fragments with a ping between them: one message, and a
       pong that carries what the ping did. */
    CHECK(server_frame(server, 0x01, "ab", 2) && server_frame(server, 0x89, "ping!", 5)
          && server_frame(server, 0x00, "", 0) && server_frame(server, 0x80, "cd", 2));
    taken = take(1);
    CHECK(is_message(&taken, "abcd", 4));
    drop(&taken);
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x8a);
    CHECK(!strcmp(payload, "ping!"));
    /* A pong nobody asked for is nothing; an empty message is a message. */
    CHECK(server_frame(server, 0x8a, "", 0) && server_frame(server, 0x81, "", 0));
    taken = take(1);
    CHECK(is_message(&taken, "", 0));
    drop(&taken);
    /* Text that is not UTF-8 arrives as text. */
    CHECK(server_frame(server, 0x81, "a\xff\xe2\x82" "b", 5));
    taken = take(1);
    CHECK(is_message(&taken, "a\xef\xbf\xbd\xef\xbf\xbd" "b", 8));
    drop(&taken);

    /* The server closes: the client answers with its status, and says why. */
    CHECK(server_frame(server, 0x88, "\x03\xe8" "bye", 5));
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x88 && length == 2
          && !memcmp(payload, "\x03\xe8", 2));
    CHECK(server_read(server, payload, 1) == 0);
    taken = take(1);
    CHECK(is_end(&taken, "The server closed the connection (1000: bye)", 1000));
    drop(&taken);
    /* Ended, it stays so, and takes what is sent without sending it. */
    CHECK(send_text(1, "late", 4));
    taken = take(1);
    CHECK(is_end(&taken, "The server closed the connection (1000: bye)", 1000));
    drop(&taken);
    CHECK(close_socket(1));
    CHECK(!close_socket(1));
    close(server);
    close(listener);
}

static void test_binary_and_its_bound(void)
{
    char payload[256];
    size_t length;
    int listener = listen_at("binary");
    CHECK(open_socket(2, "binary", "bytes.v1", true));
    int server = server_upgrade(listener, "bytes.v1", NULL);
    CHECK(server >= 0);
    /* Any bytes, both ways, as binary messages. */
    CHECK(send_text(2, "\0\xff\x01", 3));
    CHECK(client_frame(server, payload, sizeof payload, &length) == 0x82 && length == 3
          && !memcmp(payload, "\0\xff\x01", 3));
    CHECK(server_frame(server, 0x82, "\xff\0\xfe", 3));
    struct taken taken = take(2);
    CHECK(is_message(&taken, "\xff\0\xfe", 3));
    drop(&taken);

    /* A server that floods is held back while the core does not read: it
       gets rid of the bound and what the two ends' buffers hold, no more.
       Then each read lets more through, and every byte arrives in order. */
    enum { MESSAGE = 32768, MESSAGES = 1024 };
    static unsigned char block[MESSAGE];
    fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK);
    size_t sent = 0, received = 0, stalled_at = 0;
    bool ordered = true, bounded = false;
    unsigned char header[10] = {0x82, 127};
    for (int i = 0; i < 8; i++)
        header[2 + i] = (unsigned char) ((uint64_t) MESSAGE >> (56 - 8 * i));
    size_t in_message = 0; /* Of the frame being written, header first. */
    int64_t deadline = now_milliseconds() + 20000, quiet_since = 0;
    while (received < (size_t) MESSAGE * MESSAGES && now_milliseconds() < deadline) {
        bool wrote = false;
        while (sent < (size_t) MESSAGE * MESSAGES) {
            size_t message = sent / MESSAGE;
            ssize_t count;
            if (in_message < sizeof header) {
                count = send(server, header + in_message, sizeof header - in_message, MSG_NOSIGNAL);
            } else {
                size_t at = in_message - sizeof header;
                for (size_t i = at; i < MESSAGE; i++)
                    block[i] = (unsigned char) (message * 31 + i);
                count = send(server, block + at, MESSAGE - at, MSG_NOSIGNAL);
            }
            if (count <= 0)
                break;
            wrote = true;
            in_message += (size_t) count;
            if (in_message == sizeof header + MESSAGE) {
                in_message = 0;
                sent += MESSAGE;
            }
        }
        if (wrote) {
            quiet_since = 0;
        } else if (!quiet_since) {
            quiet_since = now_milliseconds();
        } else if (now_milliseconds() - quiet_since > 300 && !bounded) {
            /* The server could send nothing for a while: it is held. */
            bounded = true;
            stalled_at = sent;
        }
        if (bounded || sent == (size_t) MESSAGE * MESSAGES) {
            struct taken more = take(2);
            for (size_t i = 0; i < more.count; i++) {
                size_t message = received / MESSAGE;
                ordered = ordered && more.messages[i].length == MESSAGE
                    && (unsigned char) more.messages[i].data[0] == (unsigned char) (message * 31)
                    && (unsigned char) more.messages[i].data[MESSAGE - 1]
                        == (unsigned char) (message * 31 + MESSAGE - 1);
                received += more.messages[i].length;
            }
            drop(&more);
        } else {
            nanosleep(&(struct timespec) {.tv_nsec = 5000000}, NULL);
        }
    }
    CHECK(bounded);
    CHECK(stalled_at >= PORTAL_SOCKET_UNREAD && stalled_at < 8 * (size_t) PORTAL_SOCKET_UNREAD);
    CHECK(received == (size_t) MESSAGE * MESSAGES);
    CHECK(ordered);
    fcntl(server, F_SETFL, fcntl(server, F_GETFL) & ~O_NONBLOCK);

    /* Held back again, a close still gets through, and soon. */
    for (int i = 0; i < 64; i++) {
        memset(block, 0, sizeof block);
        if (!server_frame(server, 0x82, block, MESSAGE))
            break;
    }
    int64_t start = now_milliseconds();
    CHECK(close_socket(2));
    int first = -1;
    while ((first = client_frame(server, payload, sizeof payload, &length)) >= 0 && first != 0x88)
        continue;
    CHECK(first == 0x88 && length == 2 && !memcmp(payload, "\x03\xe8", 2));
    CHECK(server_read(server, payload, 1) == 0);
    CHECK(now_milliseconds() - start < 1500);
    close(server);

    /* Text on a binary socket ends it, and binary on a text one. */
    CHECK(open_socket(3, "binary", "bytes.v1", true));
    server = server_upgrade(listener, "bytes.v1", NULL);
    CHECK(server_frame(server, 0x81, "text", 4));
    taken = take(3);
    CHECK(is_end(&taken, "The server sent a message that is not binary", 1002));
    drop(&taken);
    CHECK(close_socket(3));
    close(server);
    CHECK(open_socket(3, "binary", "bytes.v1", false));
    server = server_upgrade(listener, "bytes.v1", NULL);
    CHECK(server_frame(server, 0x82, "bytes", 5));
    taken = take(3);
    CHECK(is_end(&taken, "The server sent a message that is not text", 1002));
    drop(&taken);
    CHECK(close_socket(3));
    close(server);
    close(listener);
}

/* Open socket 4 on LISTENER's server, upgrade it, have the server send the
   LENGTH BYTES as they are, and check that the connection ends for REASON
   with CODE. */
static void ends_with(int listener, const char *name, const void *bytes, size_t length,
                      const char *reason, int code, int line)
{
    bool opened = open_socket(4, name, "test.v1", false);
    int server = opened ? server_upgrade(listener, "test.v1", NULL) : -1;
    bool wrote = server >= 0 && server_write(server, bytes, length);
    struct taken taken = take(4);
    check(opened && wrote && is_end(&taken, reason, code), reason, line);
    drop(&taken);
    close_socket(4);
    if (server >= 0)
        close(server);
}

static void test_broken_protocol(void)
{
    static const char broke[] = "The server broke the WebSocket protocol";
    static const char large[] = "The server sent a message that is too large";
    int listener = listen_at("broken");
#define ENDS(bytes, reason, code) \
    ends_with(listener, "broken", bytes, sizeof(bytes) - 1, reason, code, __LINE__)
    /* A reserved bit, a masked frame, an opcode nobody defined. */
    ENDS("\xc1\x01x", broke, 1002);
    ENDS("\x81\x81\0\0\0\0x", broke, 1002);
    ENDS("\x83\x01x", broke, 1002);
    /* A control frame in fragments, and one too long. */
    ENDS("\x09\x00", broke, 1002);
    ENDS("\x89\x7e\x00\x7e", broke, 1002);
    /* A continuation of nothing, and a new message inside another. */
    ENDS("\x80\x01x", broke, 1002);
    ENDS("\x01\x01x\x81\x01y", broke, 1002);
    /* A frame larger than any message, refused before its bytes come. */
    ENDS("\x81\x7f\0\0\0\0\x01\0\0\x01", large, 1009);
    /* A close with no status, with a status alone, and gone without one. */
    ENDS("\x88\x00", "The server closed the connection", 0);
    ENDS("\x88\x02\x03\xea", "The server closed the connection (1002)", 1002);
    ENDS("\x88\x10\x03\xea" "protocol error",
         "The server closed the connection (1002: protocol error)", 1002);
#undef ENDS
    /* Fragments that add up past the largest message. */
    CHECK(open_socket(4, "broken", "test.v1", false));
    int server = server_upgrade(listener, "test.v1", NULL);
    static char half[9 << 20];
    CHECK(server_frame(server, 0x01, half, sizeof half));
    CHECK(server_frame(server, 0x80, half, sizeof half));
    struct taken taken = take(4);
    CHECK(is_end(&taken, large, 1009));
    drop(&taken);
    CHECK(close_socket(4));
    close(server);

    /* A server that hangs up, with a message before it and none after. */
    CHECK(open_socket(4, "broken", "test.v1", false));
    server = server_upgrade(listener, "test.v1", NULL);
    CHECK(server_frame(server, 0x81, "last", 4));
    close(server);
    taken = take(4);
    if (!taken.ended) {
        CHECK(is_message(&taken, "last", 4));
        drop(&taken);
        taken = take(4);
        CHECK(is_end(&taken, gone, 0));
    } else {
        /* Both at once: the message, and the end with it. */
        CHECK(taken.count == 1 && taken.code == 0 && !strcmp(taken.reason.data, gone));
    }
    drop(&taken);
    /* Sending to it raises no SIGPIPE, which would end this program. */
    for (int i = 0; i < 64; i++)
        CHECK(send_text(4, "anyone?", 7));
    CHECK(close_socket(4));
    close(listener);
}

/* Open socket 5 on a server that answers the upgrade with ANSWER, and check
   that the connection ends for REASON. */
static void refused_with(int listener, const char *answer, const char *reason, int line)
{
    char asked[1024];
    bool opened = open_socket(5, "refusing", "test.v1", false);
    int server = accept_one(listener);
    bool answered = server >= 0 && server_request(server, asked, sizeof asked)
        && server_write(server, answer, strlen(answer));
    struct taken taken = take(5);
    check(opened && answered && is_end(&taken, reason, 0), reason, line);
    drop(&taken);
    close_socket(5);
    if (server >= 0)
        close(server);
}

static void test_refusals(void)
{
    portal_text error = {0};
    bool ready = false;
    struct taken taken;
    int listener = listen_at("refusing");
#define REFUSED(answer, reason) refused_with(listener, answer, reason, __LINE__)
    REFUSED("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
            "The server refused the connection: HTTP/1.1 400 Bad Request");
    REFUSED("nonsense\r\n\r\n", "The server refused the connection: nonsense");
    /* An answer for another key, and one for no subprotocol or another. */
    REFUSED("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
            "Sec-WebSocket-Protocol: test.v1\r\n\r\n",
            "The server's answer is not a WebSocket's");
    REFUSED("HTTP/1.1 101 Switching Protocols\r\n\r\n", "The server's answer is not a WebSocket's");
#undef REFUSED
    CHECK(open_socket(5, "refusing", "test.v1", false));
    int server = server_upgrade(listener, "other.v2", NULL);
    taken = take(5);
    CHECK(is_end(&taken, "The server does not speak test.v1", 0));
    drop(&taken);
    CHECK(close_socket(5));
    close(server);
    /* Header names in any case, values with space around them. */
    {
        char asked[1024], accept[29], answer[512];
        CHECK(open_socket(5, "refusing", "test.v1", false));
        server = accept_one(listener);
        CHECK(server_request(server, asked, sizeof asked));
        accept_of(strstr(asked, "Sec-WebSocket-Key: ") + 19, accept);
        snprintf(answer, sizeof answer,
                 "HTTP/1.1 101 Fine\r\nSEC-WEBSOCKET-ACCEPT:%s  \r\n"
                 "sec-websocket-protocol: \t test.v1\r\n\r\n\x81\x02hi",
                 accept);
        /* The first message in the same write as the answer is not lost. */
        CHECK(server_write(server, answer, strlen(answer)));
        taken = take(5);
        CHECK(is_message(&taken, "hi", 2));
        drop(&taken);
        CHECK(close_socket(5));
        close(server);
    }

    /* A server that accepts and never answers holds nothing up: the open
       returned, and a close hangs up on it. */
    int64_t start = now_milliseconds();
    CHECK(open_socket(5, "refusing", "test.v1", false));
    server = accept_one(listener);
    char asked[1024], byte;
    CHECK(server_request(server, asked, sizeof asked));
    CHECK(!ready_within(5, 50));
    CHECK(close_socket(5));
    CHECK(server_read(server, &byte, 1) == 0);
    CHECK(now_milliseconds() - start < 1500);
    close(server);
    close(listener);

    /* Nothing listens, at a path that was a socket and at one that never
       was anything. */
    CHECK(open_socket(5, "refusing", "test.v1", false));
    taken = take(5);
    CHECK(is_end(&taken, "Nothing is listening on that socket", 0));
    drop(&taken);
    CHECK(close_socket(5));
    CHECK(open_socket(5, "nowhere", "test.v1", false));
    taken = take(5);
    CHECK(is_end(&taken, "Nothing is listening on that socket", 0));
    drop(&taken);
    /* What cannot start fails at once: a name in use, no name, and a path
       no socket address holds. */
    CHECK(!portal_message_socket_open(5, string(path_of("nowhere")), string("/"), string("p"),
                                      false, wake, NULL, &error));
    CHECK(error.data && !strcmp(error.data, "Message socket 5 is already open"));
    free(error.data);
    error = (portal_text) {0};
    CHECK(close_socket(5));
    CHECK(!portal_message_socket_open(0, string(path_of("nowhere")), string("/"), string("p"),
                                      false, wake, NULL, &error));
    free(error.data);
    error = (portal_text) {0};
    char far[300];
    memset(far, 'p', sizeof far - 1);
    far[0] = '/';
    far[sizeof far - 1] = '\0';
    char expected[64];
    snprintf(expected, sizeof expected,
             "A socket's path is at most %zu bytes, and this one is 299: /",
             sizeof ((struct sockaddr_un *) 0)->sun_path - 1);
    CHECK(!portal_message_socket_open(5, string(far), string("/"), string("p"), false, wake,
                                      NULL, &error));
    CHECK(error.data && !strncmp(error.data, expected, strlen(expected)));
    free(error.data);
    error = (portal_text) {0};
    /* A socket nobody opened, or closed already. */
    CHECK(!portal_message_socket_send(5, string("x"), &error));
    CHECK(error.data && !strcmp(error.data, "No message socket 5"));
    free(error.data);
    error = (portal_text) {0};
    CHECK(!portal_message_socket_wait(5, 0, &ready, &error));
    free(error.data);
}

/* Several sockets at once, each its own connection, and what a socket
   leaves behind: no descriptor, and none a program Emacs starts inherits. */
static void test_descriptors(void)
{
    enum { COUNT = 6 };
    int servers[COUNT], listener = listen_at("many");
    char payload[64];
    size_t length;
    for (int i = 0; i < COUNT; i++) {
        CHECK(open_socket(10 + (uint64_t) i, "many", "test.v1", false));
        servers[i] = server_upgrade(listener, "test.v1", NULL);
        CHECK(servers[i] >= 0);
    }
    /* Every descriptor opened here but the listener and the servers' ends
       is a socket's own, and closes on exec. */
    bool private = true;
    int own = 0;
    for (int descriptor = 0; descriptor < 256; descriptor++) {
        bool ours = inherited[descriptor] || descriptor == listener;
        for (int i = 0; i < COUNT; i++)
            ours = ours || descriptor == servers[i];
        int flags = fcntl(descriptor, F_GETFD);
        if (flags == -1 || ours)
            continue;
        own++;
        private = private && (flags & FD_CLOEXEC);
    }
    CHECK(private);
    /* A connection and the two ends of a pipe, each. */
    CHECK(own == 3 * COUNT);
    for (int i = COUNT - 1; i >= 0; i--) {
        char text[16];
        snprintf(text, sizeof text, "socket %d", 10 + i);
        CHECK(send_text(10 + (uint64_t) i, text, strlen(text)));
    }
    for (int i = 0; i < COUNT; i++) {
        char text[16];
        snprintf(text, sizeof text, "socket %d", 10 + i);
        CHECK(client_frame(servers[i], payload, sizeof payload, &length) == 0x81);
        CHECK(!strcmp(payload, text));
        CHECK(server_frame(servers[i], 0x81, text, strlen(text)));
    }
    for (int i = 0; i < COUNT; i++) {
        char text[16];
        snprintf(text, sizeof text, "socket %d", 10 + i);
        struct taken taken = take(10 + (uint64_t) i);
        CHECK(is_message(&taken, text, strlen(text)));
        drop(&taken);
        CHECK(close_socket(10 + (uint64_t) i));
        CHECK(client_frame(servers[i], payload, sizeof payload, &length) == 0x88);
        close(servers[i]);
    }
    close(listener);
    /* Each socket's thread lets go of its descriptors once it has hung up. */
    EVENTUALLY(open_descriptors() == 0);
}

int main(void)
{
    for (int descriptor = 0; descriptor < 256; descriptor++)
        inherited[descriptor] = fcntl(descriptor, F_GETFD) != -1;
    snprintf(directory, sizeof directory, "/tmp/portal-msock.XXXXXX");
    if (!mkdtemp(directory)) {
        perror("mkdtemp");
        return 2;
    }
    test_published_values();
    test_text_both_ways();
    test_binary_and_its_bound();
    test_broken_protocol();
    test_refusals();
    test_descriptors();

    DIR *left = opendir(directory);
    for (struct dirent *entry; left && (entry = readdir(left));)
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, ".."))
            unlink(path_of(entry->d_name));
    if (left)
        closedir(left);
    rmdir(directory);
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Message sockets passed");
    printf("%d checks passed\n", checks);
    return 0;
}
