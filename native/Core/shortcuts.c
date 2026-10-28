/* SPDX-License-Identifier: GPL-3.0-or-later */
/* System-wide shortcuts: Portal's rules for them, on the platform's hot key
   primitives.  Lisp names each shortcut and keeps the function it calls; the
   core keeps each registration's chord and ID, and turns a press into one
   record for Emacs.  The platform registers chords with the system and
   reports what the user presses, in any application.  The same notation
   names a chord that Lisp posts to the frontmost application. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "shortcuts.h"

/* A registration. */
struct shortcut {
    uint64_t id;     /* What Lisp and records know it by. */
    uint64_t hotkey; /* What the platform knows it by. */
    uint32_t key, modifiers;
    bool held; /* Pressed, and not released since. */
};

static struct {
    struct shortcut *items; /* Oldest first. */
    size_t count;
    uint64_t last; /* The last ID or hot key given out. */
} shortcuts;

/* The modifiers, in the order the core writes them. */
static const struct {
    const char *name;
    uint32_t bit;
} modifiers[] = {
    {"Control", PORTAL_CONTROL},
    {"Option", PORTAL_META},
    {"Shift", PORTAL_SHIFT},
    {"Command", PORTAL_SUPER},
};

static char upper(char c)
{
    return c >= 'a' && c <= 'z' ? (char) (c - 'a' + 'A') : c;
}

/* Whether WORD, LENGTH bytes, is NAME in any ASCII case. */
static bool named(const char *word, size_t length, const char *name)
{
    if (length != strlen(name))
        return false;
    for (size_t i = 0; i < length; i++)
        if (upper(word[i]) != upper(name[i]))
            return false;
    return true;
}

/* The key that WORD, LENGTH bytes, names, as portal_hotkey_register takes
   it, or 0 for none. */
static uint32_t key_named(const char *word, size_t length)
{
    if (length == 1) {
        char c = upper(word[0]);
        return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? (uint32_t) c : 0;
    }
    if (named(word, length, "Space"))
        return ' ';
    if (named(word, length, "Escape"))
        return PORTAL_ESCAPE_KEY;
    if ((length == 2 || length == 3) && upper(word[0]) == 'F' && word[1] != '0') {
        uint32_t number = 0;
        for (size_t i = 1; i < length; i++) {
            if (word[i] < '0' || word[i] > '9')
                return 0;
            number = number * 10 + (uint32_t) (word[i] - '0');
        }
        return number <= 20 ? PORTAL_FUNCTION_KEY + number : 0;
    }
    return 0;
}

/* Read CHORD into *KEY and the portal_modifier *BITS. */
static bool parse(portal_string chord, uint32_t *key, uint32_t *bits, portal_text *error)
{
    const char *word = chord.data, *end = chord.data + chord.length, *hyphen;
    *bits = 0;
    while ((hyphen = memchr(word, '-', (size_t) (end - word)))) {
        size_t length = (size_t) (hyphen - word);
        uint32_t bit = 0;
        for (size_t i = 0; i < sizeof modifiers / sizeof *modifiers; i++)
            if (named(word, length, modifiers[i].name))
                bit = modifiers[i].bit;
        if (!bit || *bits & bit)
            return fail(error,
                        "A shortcut's modifiers are Control, Option, Command and Shift, each "
                        "at most once, not: ",
                        (portal_string) {word, length});
        *bits |= bit;
        word = hyphen + 1;
    }
    *key = key_named(word, (size_t) (end - word));
    /* Escape is the one key that needs no modifier, to post as a person
       presses it; a shortcut still needs one (portal_shortcuts_set). */
    if (!*key
        || (*key != PORTAL_ESCAPE_KEY && !(*bits & (PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER))))
        return fail(error,
                    "A shortcut is Control, Option or Command, then A-Z, 0-9, Space or F1-F20, "
                    "or Escape with any modifiers or none, as in Control-Option-Command-P, not: ",
                    chord);
    return true;
}

/* KEY with BITS, as portal_shortcuts_chord writes it, in TEXT. */
static void write_chord(uint32_t key, uint32_t bits, char text[64])
{
    size_t length = 0;
    for (size_t i = 0; i < sizeof modifiers / sizeof *modifiers; i++)
        if (bits & modifiers[i].bit)
            length += (size_t) snprintf(text + length, 64 - length, "%s-", modifiers[i].name);
    if (key == ' ')
        snprintf(text + length, 64 - length, "Space");
    else if (key == PORTAL_ESCAPE_KEY)
        snprintf(text + length, 64 - length, "Escape");
    else if (key > PORTAL_FUNCTION_KEY)
        snprintf(text + length, 64 - length, "F%u", (unsigned) (key - PORTAL_FUNCTION_KEY));
    else
        snprintf(text + length, 64 - length, "%c", (char) key);
}

static struct shortcut *with_id(uint64_t id)
{
    for (size_t i = 0; i < shortcuts.count; i++)
        if (shortcuts.items[i].id == id)
            return &shortcuts.items[i];
    return NULL;
}

static struct shortcut *with_hotkey(uint64_t hotkey)
{
    for (size_t i = 0; i < shortcuts.count; i++)
        if (shortcuts.items[i].hotkey == hotkey)
            return &shortcuts.items[i];
    return NULL;
}

bool portal_shortcuts_chord(portal_string chord, portal_text *normalized, portal_text *error)
{
    uint32_t key, bits;
    if (!parse(chord, &key, &bits, error))
        return false;
    char text[64];
    write_chord(key, bits, text);
    size_t length = strlen(text);
    char *copy = malloc(length + 1);
    if (!copy)
        return fail_with(error, "Portal is out of memory");
    memcpy(copy, text, length + 1);
    *normalized = (portal_text) {copy, length};
    return true;
}

/* Put ACTION and the chord in the platform's ERROR, which says why it
   refused KEY with BITS, and return false. */
static bool refused(portal_text *error, const char *action, uint32_t key, uint32_t bits)
{
    char chord[64], message[96];
    write_chord(key, bits, chord);
    snprintf(message, sizeof message, "Cannot %s %s: ", action, chord);
    portal_text reason = *error;
    *error = (portal_text) {0};
    fail(error, message, (portal_string) {reason.data ? reason.data : "", reason.length});
    free(reason.data);
    return false;
}

bool portal_shortcuts_set(uint64_t replacing, portal_string chord, uint64_t *id,
                          portal_text *error)
{
    uint32_t key, bits;
    if (!parse(chord, &key, &bits, error))
        return false;
    if (!(bits & (PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER)))
        return fail(error,
                    "A shortcut is Control, Option or Command, then A-Z, 0-9, Space, Escape or "
                    "F1-F20, as in Control-Option-Command-P, not: ",
                    chord);
    struct shortcut *old = NULL;
    if (replacing && !(old = with_id(replacing)))
        return fail_with(error, "That Portal shortcut was removed");
    for (size_t i = 0; i < shortcuts.count; i++) {
        if (&shortcuts.items[i] != old && shortcuts.items[i].key == key
            && shortcuts.items[i].modifiers == bits) {
            char text[64];
            write_chord(key, bits, text);
            return fail(error, "Another Portal shortcut has ", (portal_string) {text, strlen(text)});
        }
    }
    if (old && old->key == key && old->modifiers == bits) {
        /* Restarting the platform's registration keeps the chord, and makes a
           press from before this set stale there, even one still in the
           system's queue, as the new ID makes one stale here. */
        if (!portal_hotkey_register(old->hotkey, key, bits, error))
            return refused(error, "register shortcut", key, bits);
        *id = old->id = ++shortcuts.last;
        return true;
    }
    if (!old) {
        struct shortcut *grown =
            realloc(shortcuts.items, (shortcuts.count + 1) * sizeof *shortcuts.items);
        if (!grown)
            return fail_with(error, "Portal is out of memory");
        shortcuts.items = grown;
    }
    /* Register the new chord before releasing the old one, so that a failure
       leaves the old one registered. */
    uint64_t hotkey = ++shortcuts.last;
    if (!portal_hotkey_register(hotkey, key, bits, error))
        return refused(error, "register shortcut", key, bits);
    if (old && !portal_hotkey_unregister(old->hotkey, error)) {
        portal_text ignored = {0};
        portal_hotkey_unregister(hotkey, &ignored);
        free(ignored.data);
        return false;
    }
    if (!old)
        old = &shortcuts.items[shortcuts.count++];
    *old = (struct shortcut) {.id = hotkey, .hotkey = hotkey, .key = key, .modifiers = bits};
    *id = hotkey;
    return true;
}

bool portal_shortcuts_remove(uint64_t id, portal_text *error)
{
    struct shortcut *shortcut = with_id(id);
    if (!shortcut)
        return true;
    if (!portal_hotkey_unregister(shortcut->hotkey, error))
        return false;
    size_t after = shortcuts.count - (size_t) (shortcut - shortcuts.items) - 1;
    memmove(shortcut, shortcut + 1, after * sizeof *shortcut);
    if (!--shortcuts.count) {
        free(shortcuts.items);
        shortcuts.items = NULL;
    }
    return true;
}

bool portal_shortcuts_describe(portal_text *result, portal_text *error)
{
    struct json json = {0};
    put(&json, "[", 1);
    for (size_t i = 0; i < shortcuts.count; i++) {
        const struct shortcut *shortcut = &shortcuts.items[i];
        char chord[64], text[96];
        write_chord(shortcut->key, shortcut->modifiers, chord);
        int length = snprintf(text, sizeof text, "%s{\"id\":%" PRIu64 ",\"chord\":", i ? "," : "",
                              shortcut->id);
        put(&json, text, (size_t) length);
        put_string(&json, (portal_string) {chord, strlen(chord)});
        length = snprintf(text, sizeof text, ",\"hotkey\":%" PRIu64 ",\"held\":%s}",
                          shortcut->hotkey, shortcut->held ? "true" : "false");
        put(&json, text, (size_t) length);
    }
    put(&json, "]", 1);
    if (json.failed) {
        free(json.data);
        return fail_with(error, "Portal is out of memory");
    }
    *result = (portal_text) {json.data, json.length};
    return true;
}

bool portal_shortcuts_post(portal_string chord, portal_text *error)
{
    uint32_t key, bits;
    if (!parse(chord, &key, &bits, error))
        return false;
    return portal_key_post(key, bits, error) || refused(error, "post", key, bits);
}

/* A press sends one record, however long the chord is held: the platform
   may report repeats, and a held key must not run the function again. */
void portal_hotkey_pressed(uint64_t hotkey)
{
    struct shortcut *shortcut = with_hotkey(hotkey);
    if (!shortcut || shortcut->held)
        return;
    shortcut->held = true;
    char id[32];
    int length = snprintf(id, sizeof id, "%" PRIu64, shortcut->id);
    portal_channel_send((portal_string) {"shortcut", 8}, (portal_string) {id, (size_t) length},
                        NULL, 0);
}

void portal_hotkey_released(uint64_t hotkey)
{
    struct shortcut *shortcut = with_hotkey(hotkey);
    if (shortcut)
        shortcut->held = false;
}
