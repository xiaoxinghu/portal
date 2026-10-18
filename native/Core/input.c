/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Input: who gets each key pressed in a view, and each handoff to Emacs from
   its trigger to the end of its command.  Emacs is the system and the view
   an app in it, as a page is in a browser.  A key goes, in order:

   1. With the configured escape (Super-period by default), back to Emacs,
      which keeps the keyboard. The platform checks portal_input_is_escape
      before holding events and returns focus itself (portal_input_focus),
      without waiting for Lisp or the app.
   2. To Emacs, when it is the first chord of a native binding: a key the
      user claimed for Emacs in a terminal.
   3. To the view's app.  Only a chord can go further: a key that types a
      character, pressed with Control, Meta or Super.  Plain and Shift keys,
      and keys that type no character, stay with the app.  A terminal's app
      never uses a Super chord, and uses every other; a web view's page is
      offered each chord, and the platform reports one it did not use
      (portal_input_unused).
   4. To the view's shortcuts: Super-C copies and Super-V pastes in every
      view.
   5. To Emacs, which reads the rest of the key sequence with the view's
      buffer's keymaps and runs its command.

   Records tell Emacs what happened, and Emacs answers with portal--input
   actions.  The platform keeps the native events: this file sees only
   chords, and asks the platform to replay, discard or deliver what it holds.

   A focus change the platform reports while Emacs or the core is calling it
   is their own doing.  Any other is the user's: it abandons the view's
   handoff.  Every change of whether a view has the keyboard goes to Emacs as
   a "focus" record, which its buffer's mode line shows. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "channel.h"
#include "core.h"
#include "input.h"
#include "views.h"

enum { MODIFIERS = PORTAL_SHIFT | PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER };

/* A binding profile: normalized chords. */
struct profile {
    portal_binding *bindings;
    size_t count;
};

static struct {
    struct profile regular, quick;
    int64_t serials;   /* The last serial given out. */
    unsigned requests; /* How many calls for Emacs or the core are running. */
} input;

/* C-g, which cancels the key sequence Emacs is reading. */
static const portal_chord cancel = {'g', PORTAL_CONTROL};
static portal_chord escape = {'.', PORTAL_SUPER};

/* CHORD as the core compares chords: only the known modifiers, a letter in
   lower case, and no Shift on another printable ASCII character, which
   Shift already made.  Shift stays on letters and space, as Emacs's S-a and
   S-SPC. */
static portal_chord normalize(portal_chord chord)
{
    uint32_t character = chord.character, modifiers = chord.modifiers & MODIFIERS;
    if (character >= 'A' && character <= 'Z')
        character += 'a' - 'A';
    else if (character > ' ' && character < 0x80 && !(character >= 'a' && character <= 'z'))
        modifiers &= ~(uint32_t) PORTAL_SHIFT;
    return (portal_chord) {character, modifiers};
}

static bool same(portal_chord a, portal_chord b)
{
    return a.character == b.character && a.modifiers == b.modifiers;
}

/* Whether CHORD can be a native binding's first chord: one printable ASCII
   character and modifiers the core knows, other than Shift alone on
   punctuation. */
static bool first_chord(portal_chord chord)
{
    return chord.character >= ' ' && chord.character <= '~' && chord.modifiers
        && !(chord.modifiers & ~(uint32_t) MODIFIERS) && normalize(chord).modifiers;
}

bool portal_input_set_escape(portal_chord chord, portal_text *error)
{
    if ((!first_chord(chord) && chord.character != 27)
        || !(chord.modifiers & (PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER))
        || (chord.modifiers & ~(uint32_t) MODIFIERS))
        return fail_with(error, "Escape must be modified ASCII or Escape with Control, Meta or Super");
    escape = normalize(chord);
    return true;
}

bool portal_input_is_escape(portal_chord chord)
{
    return same(normalize(chord), escape);
}

/* Whether KEY, normalized, is a chord, which can leave the view's app: a key
   that types a character, pressed with Control, Meta or Super. */
static bool is_chord(portal_chord key)
{
    uint32_t character = key.character;
    return character >= ' ' && !(character >= 0x7f && character < 0xa0)
        && !(character >= 0xd800 && character <= 0xdfff) && character <= 0x10ffff
        && (key.modifiers & (PORTAL_CONTROL | PORTAL_META | PORTAL_SUPER));
}

/* The event PROFILE binds normalized KEY to, or 0. */
static int64_t lookup(const struct profile *profile, portal_chord key)
{
    for (size_t i = 0; profile && i < profile->count; i++)
        if (same(profile->bindings[i].chord, key))
            return profile->bindings[i].event;
    return 0;
}

static const struct profile *profile(const struct portal_input *view)
{
    return view->bindings == PORTAL_QUICK_BINDINGS     ? &input.quick
         : view->bindings == PORTAL_REGULAR_BINDINGS ? &input.regular
                                                     : NULL;
}

/* Send Emacs the record "TYPE TARGET SERIAL VALUE...", with COUNT values. */
static bool send_values(const char *type, const struct portal_input *view, int64_t serial,
                        const int64_t *values, size_t count)
{
    char numbers[3][24];
    portal_string fields[3];
    for (size_t i = 0; i <= count && i < 3; i++) {
        int length = snprintf(numbers[i], sizeof numbers[i], "%" PRId64, i ? values[i - 1] : serial);
        fields[i] = (portal_string) {numbers[i], (size_t) length};
    }
    return portal_channel_send((portal_string) {type, strlen(type)}, view->target, fields,
                               count + 1);
}

/* Send Emacs the record "TYPE TARGET SERIAL KEY". */
static bool send(const char *type, const struct portal_input *view, int64_t serial, int64_t key)
{
    return send_values(type, view, serial, &key, 1);
}

/* Tell Emacs whether VIEW has the keyboard: the record "focus TARGET 1" or
   "focus TARGET 0", which its buffer's mode line shows. */
static void report(const struct portal_input *view)
{
    portal_string field = {view->focused ? "1" : "0", 1};
    portal_channel_send((portal_string) {"focus", 5}, view->target, &field, 1);
}

/* Free the error of a primitive the platform asked for, which has no one to
   report it to.  Called on the thread the platform must use, a primitive
   fails only when that is broken. */
static void ignore(bool done, portal_text *error)
{
    if (!done)
        free(error->data);
}

/* End VIEW's handoff, if any: the platform drops the events it holds. */
static bool end(struct portal_input *view, portal_text *error)
{
    enum portal_handoff was = view->handoff;
    view->handoff = PORTAL_IDLE;
    return was == PORTAL_IDLE || portal_view_replay(view->view, false, error);
}

/* The user took the keyboard during VIEW's handoff: end it, and tell Emacs,
   which may be reading its key sequence. */
static void abandon(struct portal_input *view)
{
    if (view->handoff == PORTAL_IDLE)
        return;
    portal_text error = {0};
    ignore(end(view, &error), &error);
    send("escape", view, view->serial, 0);
}

void portal_input_open(struct portal_input *view, portal_view *native, portal_string target,
                       portal_kind kind, const portal_option *options, size_t count)
{
    bool quick = false;
    for (size_t i = 0; i < count; i++)
        if (is(options[i].name, "quick"))
            quick = options[i].is_string || options[i].flag;
    *view = (struct portal_input) {
        .view = native,
        .target = target,
        .kind = kind,
        .bindings = kind == PORTAL_WEB ? PORTAL_NO_BINDINGS
                  : quick              ? PORTAL_QUICK_BINDINGS
                                       : PORTAL_REGULAR_BINDINGS,
    };
}

bool portal_input_close(struct portal_input *view, portal_text *error)
{
    input.requests++;
    bool done = end(view, error);
    input.requests--;
    return done;
}

/* Start a handoff of VIEW to Emacs, whose record is TYPE with COUNT VALUES
   after its serial, from KEY, a normalized chord: Emacs reads the rest of
   its key sequence, and the platform holds it meanwhile. */
static portal_key start(struct portal_input *view, const char *type, portal_chord key,
                        const int64_t *values, size_t count)
{
    view->serial = ++input.serials;
    if (!send_values(type, view, view->serial, values, count))
        return PORTAL_KEY_TAKE;
    view->handoff = PORTAL_AWAITING;
    view->trigger = key;
    view->binding = !strcmp(type, "binding");
    portal_text error = {0};
    input.requests++;
    ignore(portal_view_unfocus(view->view, &error), &error);
    input.requests--;
    return PORTAL_KEY_HOLD;
}

/* Whether KEY, a normalized chord, is one of VIEW's shortcuts, which the core
   has acted on. */
static bool shortcut(struct portal_input *view, portal_chord key)
{
    if (key.modifiers == PORTAL_SUPER && (key.character == 'c' || key.character == 'v')) {
        portal_text error = {0};
        input.requests++;
        ignore(key.character == 'c' ? portal_view_copy(view->view, &error)
                                    : portal_view_paste(view->view, &error),
               &error);
        input.requests--;
        return true;
    }
    return false;
}

/* What happens to CHORD, pressed in VIEW, which its app did not use: a
   shortcut, or Emacs.  KEY is CHORD normalized. */
static portal_key unused(struct portal_input *view, portal_chord key, portal_chord chord,
                         bool repeat)
{
    /* The keyboard moved, or Emacs is already reading a key sequence. */
    if (!view->focused || view->handoff != PORTAL_IDLE)
        return PORTAL_KEY_TAKE;
    if (shortcut(view, key))
        return PORTAL_KEY_TAKE;
    /* A held key repeats until its release, which may come after Emacs has
       finished the handoff; only the press starts one. */
    if (repeat)
        return PORTAL_KEY_TAKE;
    /* Emacs gets the chord as typed: Shift made the character. */
    int64_t values[] = {chord.character, chord.modifiers & MODIFIERS};
    return start(view, "key", key, values, 2);
}

/* What VIEW's app does with KEY, a normalized chord that is CHORD as typed. */
static portal_key decide(struct portal_input *view, portal_chord key, portal_chord chord,
                         bool repeat)
{
    switch (view->handoff) {
    case PORTAL_AWAITING:
        return PORTAL_KEY_HOLD; /* The platform holds these without asking. */
    case PORTAL_READING: {
        const char *type = view->binding && view->first && same(key, view->trigger) ? "literal"
                         : same(key, cancel)                                        ? "cancel"
                                                                                    : NULL;
        if (!type) {
            /* The trigger, held down, repeats for none of the sequence. */
            if (repeat && same(key, view->trigger))
                return PORTAL_KEY_TAKE;
            view->first = false;
            return PORTAL_KEY_PASS;
        }
        if (!repeat)
            send(type, view, view->serial, 0);
        return PORTAL_KEY_TAKE;
    }
    case PORTAL_EXECUTING:
        return PORTAL_KEY_PASS;
    case PORTAL_IDLE:
        break;
    }
    int64_t event = lookup(profile(view), key);
    if (event)
        return repeat ? PORTAL_KEY_TAKE : start(view, "binding", key, &event, 1);
    if (!is_chord(key))
        return PORTAL_KEY_PASS;
    if (view->kind == PORTAL_WEB)
        return PORTAL_KEY_OFFER;
    if (!(key.modifiers & PORTAL_SUPER))
        return PORTAL_KEY_PASS;
    return unused(view, key, chord, repeat);
}

portal_key portal_input_key(portal_string target, portal_chord chord, bool repeat)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return PORTAL_KEY_PASS;
    return decide(view, normalize(chord), chord, repeat);
}

portal_key portal_input_unused(portal_string target, portal_chord chord, bool repeat)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return PORTAL_KEY_TAKE;
    return unused(view, normalize(chord), chord, repeat);
}

void portal_input_focus(portal_string target, bool focused)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return;
    bool changed = view->focused != focused;
    view->focused = focused;
    if (!input.requests)
        abandon(view);
    if (changed)
        report(view);
}

void portal_input_escape(portal_string target)
{
    struct portal_input *view = portal_views_input(target);
    if (!view)
        return;
    abandon(view);
    portal_text error = {0};
    input.requests++;
    ignore(portal_view_unfocus(view->view, &error), &error);
    input.requests--;
}

portal_owner portal_input_owner(portal_string target)
{
    const struct portal_input *view = portal_views_input(target);
    return !view                        ? PORTAL_OWNER_EMACS
         : view->handoff != PORTAL_IDLE ? PORTAL_OWNER_PENDING
         : !view->focused               ? PORTAL_OWNER_EMACS
                                        : PORTAL_OWNER_VIEW;
}

void portal_input_request(bool requesting)
{
    if (requesting)
        input.requests++;
    else
        input.requests--;
}

/* Perform ACTION on VIEW, for Emacs. */
static bool act(struct portal_input *view, portal_string action, int64_t serial, bool *result,
                portal_text *error)
{
    if (serial && (serial != view->serial || view->handoff == PORTAL_IDLE))
        return true;
    if (is(action, "pending")) {
        *result = view->handoff != PORTAL_IDLE;
    } else if (is(action, "focused")) {
        *result = view->focused;
    } else if (is(action, "focus")) {
        if (!portal_view_focus(view->view, error))
            return false;
        *result = view->focused;
    } else if (is(action, "unfocus")) {
        if (!end(view, error) || !portal_view_unfocus(view->view, error))
            return false;
        *result = true;
    } else if (is(action, "ack")) {
        if (view->handoff != PORTAL_AWAITING)
            return true;
        view->handoff = PORTAL_READING;
        view->first = true;
        if (!portal_view_replay(view->view, true, error))
            return false;
        *result = true;
    } else if (is(action, "command")) {
        if (view->handoff == PORTAL_READING)
            view->handoff = PORTAL_EXECUTING;
        *result = true;
    } else if (is(action, "finish")) {
        if (!end(view, error))
            return false;
        *result = true;
    } else if (is(action, "literal")) {
        if (view->handoff == PORTAL_IDLE || !view->binding)
            return fail_with(error, "No captured native binding key to send");
        if (!portal_view_focus(view->view, error))
            return false;
        if (!view->focused)
            return fail_with(error, "No captured native binding key to send");
        if (!portal_view_literal(view->view, error))
            return false;
        *result = true;
    } else {
        return fail(error, "Unknown Portal input action: ", action);
    }
    return true;
}

bool portal_input_perform(portal_string target, portal_string action, int64_t serial,
                          bool *result, portal_text *error)
{
    struct portal_input *view = portal_views_input(target);
    *result = false;
    if (!view)
        return true;
    input.requests++;
    bool done = act(view, action, serial, result, error);
    input.requests--;
    return done;
}

/* Normalize COUNT BINDINGS into *PROFILE, which the caller frees, or say
   why they cannot be a profile. */
static bool compile(const portal_binding *bindings, size_t count, struct profile *profile,
                    portal_text *error)
{
    profile->bindings = malloc((count ? count : 1) * sizeof *profile->bindings);
    if (!profile->bindings)
        return fail_with(error, "Portal is out of memory");
    for (size_t i = 0; i < count; i++) {
        if (!first_chord(bindings[i].chord) || bindings[i].event <= 0)
            return fail_with(error, "Invalid native terminal binding");
        portal_chord key = normalize(bindings[i].chord);
        if (lookup(profile, key))
            return fail_with(error, "Conflicting native terminal binding");
        profile->bindings[profile->count++] = (portal_binding) {key, bindings[i].event};
    }
    return true;
}

bool portal_input_bindings(const portal_binding *regular, size_t regular_count,
                           const portal_binding *quick, size_t quick_count, portal_text *error)
{
    struct profile profiles[2] = {{0}};
    if (!compile(regular, regular_count, &profiles[0], error)
        || !compile(quick, quick_count, &profiles[1], error)) {
        free(profiles[0].bindings);
        free(profiles[1].bindings);
        return false;
    }
    free(input.regular.bindings);
    free(input.quick.bindings);
    input.regular = profiles[0];
    input.quick = profiles[1];
    return true;
}
