/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Reading JSON, as json.h describes: a member is found by skipping the
   values before it, with their strings and nesting, and only what is asked
   for is decoded. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "core.h"
#include "json.h"

/* How deeply arrays and objects may nest: deeper text is refused. */
enum { DEEPEST = 64 };

static const char *blank(const char *at, const char *end)
{
    while (at < end && (*at == ' ' || *at == '\t' || *at == '\n' || *at == '\r'))
        at++;
    return at;
}

/* The end of the string that starts at AT, past its closing quote, or NULL. */
static const char *skip_string(const char *at, const char *end)
{
    for (at++; at < end; at++) {
        if (*at == '"')
            return at + 1;
        if (*at == '\\' && ++at == end)
            return NULL;
        if ((unsigned char) *at < 0x20)
            return NULL;
    }
    return NULL;
}

/* The end of the value that starts at AT, or NULL if it is malformed. */
static const char *skip(const char *at, const char *end, int depth)
{
    if (at == end || depth > DEEPEST)
        return NULL;
    switch (*at) {
    case '"':
        return skip_string(at, end);
    case '{':
    case '[': {
        char close = *at == '{' ? '}' : ']';
        at = blank(at + 1, end);
        if (at < end && *at == close)
            return at + 1;
        while (at < end) {
            if (close == '}') {
                if (*at != '"' || !(at = skip_string(at, end)))
                    return NULL;
                at = blank(at, end);
                if (at == end || *at != ':')
                    return NULL;
                at = blank(at + 1, end);
            }
            if (!(at = skip(at, end, depth + 1)))
                return NULL;
            at = blank(at, end);
            if (at < end && *at == close)
                return at + 1;
            if (at == end || *at != ',')
                return NULL;
            at = blank(at + 1, end);
        }
        return NULL;
    }
    default: {
        /* A number, true, false or null: its characters, which the reader
           of the value checks. */
        const char *start = at;
        while (at < end && (strchr("+-.eE", *at) || (*at >= '0' && *at <= '9')
                            || (*at >= 'a' && *at <= 'z')))
            at++;
        return at > start ? at : NULL;
    }
    }
}

bool portal_json_member(portal_string object, const char *name, portal_string *value)
{
    const char *end = object.data + object.length;
    const char *at = blank(object.data, end);
    size_t length = strlen(name);
    if (at == end || *at != '{')
        return false;
    at = blank(at + 1, end);
    if (at < end && *at == '}')
        return false;
    while (at < end && *at == '"') {
        const char *key = at + 1, *after = skip_string(at, end);
        if (!after)
            return false;
        /* A name written with escapes is never one the core asks for. */
        bool match = (size_t) (after - 1 - key) == length && !memcmp(key, name, length);
        at = blank(after, end);
        if (at == end || *at != ':')
            return false;
        at = blank(at + 1, end);
        const char *stop = skip(at, end, 1);
        if (!stop)
            return false;
        if (match) {
            *value = (portal_string) {at, (size_t) (stop - at)};
            return true;
        }
        at = blank(stop, end);
        if (at == end || *at != ',')
            return false;
        at = blank(at + 1, end);
    }
    return false;
}

bool portal_json_is(portal_string value, const char *literal)
{
    size_t length = strlen(literal);
    return value.length == length + 2 && value.data[0] == '"'
        && !memcmp(value.data + 1, literal, length) && value.data[length + 1] == '"';
}

/* The four hex digits at AT as a number, or -1. */
static long hex4(const char *at)
{
    long number = 0;
    for (int i = 0; i < 4; i++) {
        char c = at[i];
        int digit = c >= '0' && c <= '9' ? c - '0'
            : c >= 'a' && c <= 'f'       ? c - 'a' + 10
            : c >= 'A' && c <= 'F'       ? c - 'A' + 10
                                         : -1;
        if (digit < 0)
            return -1;
        number = number * 16 + digit;
    }
    return number;
}

/* Write CODE, a Unicode scalar value, as UTF-8 at OUT; return the end. */
static char *utf8(char *out, uint32_t code)
{
    if (code < 0x80) {
        *out++ = (char) code;
    } else if (code < 0x800) {
        *out++ = (char) (0xc0 | code >> 6);
        *out++ = (char) (0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
        *out++ = (char) (0xe0 | code >> 12);
        *out++ = (char) (0x80 | (code >> 6 & 0x3f));
        *out++ = (char) (0x80 | (code & 0x3f));
    } else {
        *out++ = (char) (0xf0 | code >> 18);
        *out++ = (char) (0x80 | (code >> 12 & 0x3f));
        *out++ = (char) (0x80 | (code >> 6 & 0x3f));
        *out++ = (char) (0x80 | (code & 0x3f));
    }
    return out;
}

bool portal_json_string(portal_string value, portal_text *text)
{
    const char *at = value.data, *end = value.data + value.length;
    if (value.length < 2 || *at != '"' || skip_string(at, end) != end)
        return false;
    end--; /* The closing quote. */
    /* No escape decodes to more bytes than it takes. */
    char *decoded = malloc(value.length), *out = decoded;
    if (!decoded)
        return false;
    for (at++; at < end; at++) {
        if (*at != '\\') {
            *out++ = *at;
            continue;
        }
        char escaped = *++at;
        const char *simple = strchr("\"\\/bfnrt", escaped);
        if (simple && escaped) {
            *out++ = "\"\\/\b\f\n\r\t"[simple - "\"\\/bfnrt"];
            continue;
        }
        long code = escaped == 'u' && end - at > 4 ? hex4(at + 1) : -1;
        if (code < 0) {
            free(decoded);
            return false;
        }
        at += 4;
        if (code >= 0xd800 && code < 0xdc00 && end - at > 6 && at[1] == '\\' && at[2] == 'u') {
            long low = hex4(at + 3);
            if (low >= 0xdc00 && low < 0xe000) {
                code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                at += 6;
            }
        }
        if (code >= 0xd800 && code < 0xe000)
            code = 0xfffd;
        out = utf8(out, (uint32_t) code);
    }
    *out = '\0';
    *text = (portal_text) {decoded, (size_t) (out - decoded)};
    return true;
}

bool portal_json_integer(portal_string value, int64_t *number)
{
    const char *at = value.data, *end = value.data + value.length;
    bool negative = at < end && *at == '-';
    if (negative)
        at++;
    if (at == end || (*at == '0' && end - at > 1))
        return false;
    uint64_t magnitude = 0;
    for (; at < end; at++) {
        if (*at < '0' || *at > '9')
            return false;
        uint64_t digit = (uint64_t) (*at - '0');
        if (magnitude > (UINT64_MAX - digit) / 10)
            return false;
        magnitude = magnitude * 10 + digit;
    }
    if (magnitude > (uint64_t) INT64_MAX + negative)
        return false;
    *number = negative ? (int64_t) (0 - magnitude) : (int64_t) magnitude;
    return true;
}
