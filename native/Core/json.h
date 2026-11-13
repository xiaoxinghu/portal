/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Reading JSON the core is sent: the few values it needs from a Rex
   server's responses and stream messages (rex.c).  core.h writes JSON;
   this reads it.  Nothing is parsed ahead of need: a value is a span of
   the text it came in, found by skipping over what comes before it, and
   decoded only when asked.  Only the core and its tests include this
   header. */
#ifndef PORTAL_JSON_H
#define PORTAL_JSON_H

#include "portal.h"

/* Set *VALUE to the span of the member NAME of OBJECT, a JSON object,
   whitespace around it left out.  False when OBJECT is not an object, is
   malformed before the member, or has no such member.  A later duplicate
   is not looked for. */
bool portal_json_member(portal_string object, const char *name, portal_string *value);
/* Set *VALUE to the span of the element at INDEX, from 0, of ARRAY, a JSON
   array, whitespace around it left out.  False when ARRAY is not an
   array, is malformed before the element, or is shorter. */
bool portal_json_element(portal_string array, size_t index, portal_string *value);

/* Whether VALUE, a span such as portal_json_member sets, is the JSON string
   whose contents are LITERAL, written without escapes. */
bool portal_json_is(portal_string value, const char *literal);

/* Decode VALUE, a JSON string, into *TEXT, allocated with malloc for the
   caller to free: its escapes resolved, a \u escape of a lone surrogate
   as U+FFFD.  False, setting nothing, for anything else or no memory. */
bool portal_json_string(portal_string value, portal_text *text);

/* Set *NUMBER to VALUE, a JSON integer that fits in 64 signed bits.  False
   for anything else, a fraction or an exponent included. */
bool portal_json_integer(portal_string value, int64_t *number);

#endif
