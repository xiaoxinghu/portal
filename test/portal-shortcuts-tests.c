/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's system-wide shortcuts and posted chords, native/Core/shortcuts.c,
   with the fake platform's hot keys and key posts and a real pipe standing in
   for Emacs's.  The test plays the platform, reporting presses and releases
   to the core. */
#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <unistd.h>

#include "channel.h"
#include "portal-core-tests.h"
#include "shortcuts.h"

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

/* CHORD as the core writes it, or NULL when it is invalid. */
static char *chord(const char *written)
{
    portal_text normalized = {0}, error = {0};
    if (!portal_shortcuts_chord(text(written), &normalized, &error)) {
        free(error.data);
        return NULL;
    }
    return normalized.data;
}

static bool normalizes(const char *written, const char *expected)
{
    char *normalized = chord(written);
    bool same = normalized && is_text(normalized, expected);
    free(normalized);
    return same;
}

/* Register CHORD in place of REPLACING; return its ID, or 0 with *ERROR set. */
static uint64_t set(uint64_t replacing, const char *chord, portal_text *error)
{
    uint64_t id = 0;
    return portal_shortcuts_set(replacing, text(chord), &id, error) ? id : 0;
}

static bool removed(uint64_t id)
{
    portal_text error = {0};
    bool done = portal_shortcuts_remove(id, &error);
    free(error.data);
    return done;
}

/* The registrations as JSON, to compare. */
static const char *described(void)
{
    static char text[4096];
    portal_text json = {0}, error = {0};
    if (!portal_shortcuts_describe(&json, &error)) {
        free(error.data);
        return "";
    }
    snprintf(text, sizeof text, "%s", json.data);
    free(json.data);
    return text;
}

static void test_chords(void)
{
    CHECK(normalizes("Control-Option-Command-P", "Control-Option-Command-P"));
    CHECK(normalizes("command-control-option-p", "Control-Option-Command-P"));
    CHECK(normalizes("COMMAND-shift-OPTION-control-p", "Control-Option-Shift-Command-P"));
    CHECK(normalizes("Shift-Control-1", "Control-Shift-1"));
    CHECK(normalizes("option-space", "Option-Space"));
    CHECK(normalizes("Command-f1", "Command-F1"));
    CHECK(normalizes("Control-F20", "Control-F20"));
    /* Escape is the one key that needs no modifier, to post; portal_shortcuts_set
       still refuses it alone. */
    CHECK(normalizes("escape", "Escape"));
    CHECK(normalizes("Shift-ESCAPE", "Shift-Escape"));
    CHECK(normalizes("command-option-escape", "Option-Command-Escape"));
    const char *invalid[] = {
        "", "P", "Shift-P", "Hyper-P", "Control-Control-P", "Control-", "-P", "Control--P",
        "Control-F21", "Control-F0", "Control-F01", "Control-!", "Control-P Q", "Control-PP",
        "Control-Option", "Ctrl-P", "Control-É", "Control- P", "Space", "F1", "Shift-Space",
        "Esc", "Escape-P", "Escape-Escape", "Escape ",
    };
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        char *normalized = chord(invalid[i]);
        if (normalized)
            fprintf(stderr, "Accepted \"%s\" as \"%s\"\n", invalid[i], normalized);
        CHECK(!normalized);
        free(normalized);
    }
    /* NUL bytes are not part of any name. */
    portal_text normalized = {0}, error = {0};
    CHECK(!portal_shortcuts_chord((portal_string) {"Control-P\0", 10}, &normalized, &error));
    free(error.data);
    CHECK(!portal_shortcuts_chord(text("Hyper-P"), &normalized, &error));
    CHECK(says(&error, "A shortcut's modifiers are Control, Option, Command and Shift, each at "
                       "most once, not: Hyper"));
    CHECK(!portal_shortcuts_chord(text("Control-F21"), &normalized, &error));
    CHECK(says(&error, "A shortcut is Control, Option or Command, then A-Z, 0-9, Space or "
                       "F1-F20, or Escape with any modifiers or none, as in "
                       "Control-Option-Command-P, not: Control-F21"));
}

static void test_registration(void)
{
    portal_text error = {0};
    CHECK(is_text(described(), "[]"));
    uint64_t first = set(0, "control-option-command-p", &error);
    CHECK(first);
    uint64_t second = set(0, "Control-Option-Command-L", &error);
    CHECK(second && second != first);
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 2:L+14"));
    /* Another registration's chord, however written, is refused. */
    CHECK(!set(0, "Command-Option-Control-P", &error));
    CHECK(says(&error, "Another Portal shortcut has Control-Option-Command-P"));
    CHECK(!set(second, "Control-Option-Command-P", &error));
    CHECK(says(&error, "Another Portal shortcut has Control-Option-Command-P"));
    /* So are an invalid chord, a chord the system refuses and a stale ID. */
    CHECK(!set(second, "Control-Option-Command-!", &error));
    free(error.data), error = (portal_text) {0};
    CHECK(!set(second, "Control-F19", &error));
    CHECK(says(&error, "Cannot register shortcut Control-F19: Another application has this chord"));
    CHECK(!set(12345, "Control-F12", &error));
    CHECK(says(&error, "That Portal shortcut was removed"));
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 2:L+14"));
    CHECK(is_text(described(),
                  "[{\"id\":1,\"chord\":\"Control-Option-Command-P\",\"hotkey\":1,\"held\":false},"
                  "{\"id\":2,\"chord\":\"Control-Option-Command-L\",\"hotkey\":2,\"held\":false}]"));

    /* The same chord restarts the platform's registration, so that a press
       still in the system's queue is stale there too, under a new ID. */
    uint64_t same = set(first, "Command-Control-Option-P", &error);
    CHECK(same > second);
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 2:L+14"));
    CHECK(portal_fake_hotkey_restarts() == 1);
    /* Another chord is registered before the old one is released. */
    uint64_t moved = set(second, "Control-Shift-F12", &error);
    CHECK(moved > same);
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 5:F12+3"));
    CHECK(!set(second, "Control-F11", &error)); /* Its old ID is gone. */
    free(error.data), error = (portal_text) {0};
    CHECK(is_text(described(),
                  "[{\"id\":4,\"chord\":\"Control-Option-Command-P\",\"hotkey\":1,\"held\":false},"
                  "{\"id\":5,\"chord\":\"Control-Shift-F12\",\"hotkey\":5,\"held\":false}]"));

    /* A chord whose release fails stays, and so does the one it replaced. */
    uint64_t stuck = set(0, "Control-F18", &error);
    CHECK(stuck);
    CHECK(!set(stuck, "Control-F17", &error));
    CHECK(says(&error, "The fake cannot release F18"));
    CHECK(!removed(stuck));
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 5:F12+3 6:F18+2"));
    CHECK(strstr(described(), "\"id\":6,\"chord\":\"Control-F18\""));
    /* While the platform refuses, nothing changes. */
    portal_fake_refuse(true);
    CHECK(!set(same, "Control-F11", &error));
    free(error.data), error = (portal_text) {0};
    CHECK(!set(same, "Control-Option-Command-P", &error));
    free(error.data), error = (portal_text) {0};
    CHECK(!removed(same));
    portal_fake_refuse(false);
    CHECK(portal_fake_hotkey_restarts() == 1);
    CHECK(strstr(described(), "\"id\":4,\"chord\":\"Control-Option-Command-P\""));
    CHECK(is_text(portal_fake_hotkeys(), "1:P+14 5:F12+3 6:F18+2"));

    /* Removing is harmless when repeated, and IDs are never reused. */
    CHECK(removed(same));
    CHECK(removed(same));
    CHECK(removed(0));
    CHECK(removed(999));
    CHECK(is_text(portal_fake_hotkeys(), "5:F12+3 6:F18+2"));
    uint64_t again = set(0, "Control-Option-Command-P", &error);
    CHECK(again > stuck + 1);
    CHECK(removed(again) && removed(moved));
    CHECK(is_text(portal_fake_hotkeys(), "6:F18+2"));

    /* Escape, like every key, takes Control, Option or Command to be a
       shortcut: alone or with Shift only, it is refused. */
    CHECK(!set(0, "escape", &error));
    CHECK(says(&error, "A shortcut is Control, Option or Command, then A-Z, 0-9, Space, Escape or "
                       "F1-F20, as in Control-Option-Command-P, not: escape"));
    CHECK(!set(0, "Shift-Escape", &error));
    free(error.data), error = (portal_text) {0};
    CHECK(is_text(portal_fake_hotkeys(), "6:F18+2"));
    uint64_t escape = set(0, "control-escape", &error);
    char hotkeys[64]; /* A new chord's ID is its hot key. */
    snprintf(hotkeys, sizeof hotkeys, "6:F18+2 %llu:Escape+2", (unsigned long long) escape);
    CHECK(escape);
    CHECK(is_text(portal_fake_hotkeys(), hotkeys));
    CHECK(strstr(described(), "\"chord\":\"Control-Escape\""));
    CHECK(removed(escape));
    CHECK(is_text(portal_fake_hotkeys(), "6:F18+2"));
}

static void test_presses(void)
{
    int fds[2];
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    records = fds[0];
    CHECK(portal_channel_connect(fds[1]));
    portal_text error = {0};
    uint64_t one = set(0, "Control-Option-Command-1", &error);
    uint64_t two = set(0, "Control-Option-Command-2", &error);
    uint64_t hotkey_one = one, hotkey_two = two; /* A new chord's ID is its hot key. */
    portal_hotkey_pressed(hotkey_one);
    portal_hotkey_pressed(hotkey_two);
    char expected[128];
    snprintf(expected, sizeof expected, "shortcut %llu\nshortcut %llu\n", (unsigned long long) one,
             (unsigned long long) two);
    CHECK(is_text(sent(), expected));
    /* Holding a chord sends nothing more, until it is released. */
    portal_hotkey_pressed(hotkey_one);
    portal_hotkey_pressed(hotkey_one);
    CHECK(is_text(sent(), ""));
    CHECK(strstr(described(), "\"held\":true"));
    portal_hotkey_released(hotkey_one);
    portal_hotkey_pressed(hotkey_one);
    snprintf(expected, sizeof expected, "shortcut %llu\n", (unsigned long long) one);
    CHECK(is_text(sent(), expected));
    portal_hotkey_released(hotkey_one);
    /* Unknown hot keys, such as 0, are ignored. */
    portal_hotkey_pressed(0);
    portal_hotkey_pressed(4242);
    portal_hotkey_released(4242);
    CHECK(is_text(sent(), ""));

    /* After the same chord is set again, a press carries the new ID; one held
       across the set still waits for its release. */
    portal_hotkey_pressed(hotkey_one);
    sent();
    uint64_t renewed = set(one, "Control-Option-Command-1", &error);
    portal_hotkey_pressed(hotkey_one);
    CHECK(is_text(sent(), ""));
    portal_hotkey_released(hotkey_one);
    portal_hotkey_pressed(hotkey_one);
    snprintf(expected, sizeof expected, "shortcut %llu\n", (unsigned long long) renewed);
    CHECK(is_text(sent(), expected));
    portal_hotkey_released(hotkey_one);

    /* A moved or removed shortcut's old hot key sends nothing. */
    uint64_t moved = set(two, "Control-Option-Command-3", &error);
    portal_hotkey_pressed(hotkey_two);
    CHECK(is_text(sent(), ""));
    portal_hotkey_pressed(moved);
    snprintf(expected, sizeof expected, "shortcut %llu\n", (unsigned long long) moved);
    CHECK(is_text(sent(), expected));
    CHECK(removed(renewed) && removed(moved));
    portal_hotkey_pressed(hotkey_one);
    portal_hotkey_pressed(moved);
    CHECK(is_text(sent(), ""));

    /* Records wait while Emacs has no pipe, and arrive in order. */
    CHECK(portal_channel_connect(-1));
    uint64_t later = set(0, "Control-Option-Command-4", &error);
    portal_hotkey_pressed(later);
    CHECK(portal_channel_send(text("select"), text("web:1"), NULL, 0));
    if (pipe(fds) || fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1)
        abort();
    close(records);
    records = fds[0];
    CHECK(portal_channel_connect(fds[1]));
    snprintf(expected, sizeof expected, "shortcut %llu\nselect web:1\n", (unsigned long long) later);
    CHECK(is_text(sent(), expected));
    CHECK(removed(later));
    CHECK(portal_channel_connect(-1));
    close(records);
}

static bool posts(const char *chord)
{
    portal_text error = {0};
    bool done = portal_shortcuts_post(text(chord), &error);
    free(error.data);
    return done;
}

static void test_posting(void)
{
    char registered[4096], hotkeys[1024];
    snprintf(registered, sizeof registered, "%s", described());
    snprintf(hotkeys, sizeof hotkeys, "%s", portal_fake_hotkeys());
    /* The parsed key and modifiers reach the platform, letters uppercase. */
    CHECK(posts("command-v"));
    CHECK(posts("Shift-Command-V"));
    CHECK(posts("Option-Command-7"));
    CHECK(posts("Control-Option-Shift-Command-Space"));
    CHECK(posts("control-f12"));
    CHECK(posts("escape"));
    CHECK(is_text(portal_fake_posted(), "V+8 V+9 7+12 Space+15 F12+2 Escape+0"));
    /* An invalid chord never does, and fails as it does for a shortcut. */
    const char *invalid[] = {"", "V", "Shift-V", "Command-!", "Command-V Q", "Command-F21"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++)
        CHECK(!posts(invalid[i]));
    portal_text error = {0};
    CHECK(!portal_shortcuts_post(text("Hyper-V"), &error));
    CHECK(says(&error, "A shortcut's modifiers are Control, Option, Command and Shift, each at "
                       "most once, not: Hyper"));
    CHECK(is_text(portal_fake_posted(), ""));
    /* The platform's refusal names the chord. */
    CHECK(!portal_shortcuts_post(text("shift-control-f19"), &error));
    CHECK(says(&error, "Cannot post Control-Shift-F19: The fake may not post F19+3"));
    portal_fake_refuse(true);
    CHECK(!portal_shortcuts_post(text("Command-V"), &error));
    CHECK(says(&error, "Cannot post Command-V: The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(is_text(portal_fake_posted(), ""));
    /* Posting changes no shortcut. */
    CHECK(is_text(described(), registered));
    CHECK(is_text(portal_fake_hotkeys(), hotkeys));
}

int main(void)
{
    test_chords();
    test_registration();
    test_presses();
    test_posting();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("System-wide shortcuts passed");
    return 0;
}
