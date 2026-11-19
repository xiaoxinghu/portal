/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Helpers that the core's own files share, for portal.h's strings and errors.
   Only the core includes this header, and a backend written in C, which
   uses them as the core does. */
#ifndef PORTAL_CORE_H
#define PORTAL_CORE_H

#include <stdlib.h>
#include <string.h>

#include "portal.h"

/* Whether STRING is LITERAL. */
static inline bool is(portal_string string, const char *literal)
{
    return string.length == strlen(literal) && !memcmp(string.data, literal, string.length);
}

/* Set *ERROR to MESSAGE followed by DETAIL, which may hold any bytes, and
   return false.  With no memory for it, leave *ERROR unset. */
static inline bool fail(portal_text *error, const char *message, portal_string detail)
{
    size_t length = strlen(message);
    char *text = malloc(length + detail.length + 1);
    if (text) {
        memcpy(text, message, length);
        if (detail.length)
            memcpy(text + length, detail.data, detail.length);
        text[length + detail.length] = '\0';
        *error = (portal_text) {text, length + detail.length};
    }
    return false;
}

static inline bool fail_with(portal_text *error, const char *message)
{
    return fail(error, message, (portal_string) {"", 0});
}

/* JSON the core writes: its own messages and results. */
struct json {
    char *data; /* NUL-terminated. */
    size_t length;
    bool failed; /* Out of memory. */
};

static inline void put(struct json *json, const char *data, size_t length)
{
    char *grown = json->failed ? NULL : realloc(json->data, json->length + length + 1);
    if (!grown) {
        json->failed = true;
        return;
    }
    json->data = grown;
    memcpy(json->data + json->length, data, length);
    json->length += length;
    json->data[json->length] = '\0';
}

/* STRING, which is UTF-8, as a JSON string. */
static inline void put_string(struct json *json, portal_string string)
{
    static const char hex[] = "0123456789abcdef";
    put(json, "\"", 1);
    for (size_t i = 0; i < string.length; i++) {
        unsigned char c = (unsigned char) string.data[i];
        if (c == '"' || c == '\\') {
            char escaped[] = {'\\', (char) c};
            put(json, escaped, 2);
        } else if (c < 0x20) {
            char escaped[] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
            put(json, escaped, sizeof escaped);
        } else {
            put(json, (const char *) &c, 1);
        }
    }
    put(json, "\"", 1);
}

#endif
