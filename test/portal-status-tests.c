/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The core's status panel, native/Core/status.c, with the fake platform's
   screens and panel (test/portal-fake-backend.c): where the panel goes, how
   big it is, and on which screen.  The fake's default screen is a usable
   area of 1440 by 875 points at (0, 25), and its panel fits "Recording"
   in 104 by 30 points, or 124 by 30 with a tone's mark. */
#include "portal-core-tests.h"
#include "status.h"

static const portal_screen primary = {{0, 25, 1440, 875}, false};
static const portal_screen left = {{-1920, -200, 1920, 1050}, false};

/* A layout at POSITION moved by DX and DY, fitted to the text on one line. */
static portal_status_layout at(const char *position, int64_t dx, int64_t dy)
{
    return (portal_status_layout) {.position = text(position), .screen = -1, .dx = dx, .dy = dy,
                                   .lines = 1};
}

static bool show(const char *message, const char *tone, portal_status_layout layout)
{
    portal_text error = {0};
    if (portal_status_present(text(message), text(tone), &layout, &error))
        return true;
    fprintf(stderr, "Cannot show \"%s\": %s\n", message, error.data);
    free(error.data);
    return false;
}

/* Whether the panel shows with RECT. */
static bool placed(int64_t x, int64_t y, int64_t width, int64_t height)
{
    struct portal_fake_status status = portal_fake_status();
    portal_rect rect = status.rect;
    if (status.shown && rect.x == x && rect.y == y && rect.width == width && rect.height == height)
        return true;
    fprintf(stderr, "Expected %s panel at %lld,%lld %lldx%lld, got %lld,%lld %lldx%lld\n",
            status.shown ? "a shown" : "a hidden", (long long) x, (long long) y,
            (long long) width, (long long) height, (long long) rect.x, (long long) rect.y,
            (long long) rect.width, (long long) rect.height);
    return false;
}

static bool rejected(portal_status_layout layout, const char *message, const char *tone,
                     const char *expected)
{
    portal_text error = {0};
    size_t measured = portal_fake_status().measured;
    return !portal_status_present(text(message), text(tone), &layout, &error)
        && says(&error, expected) && portal_fake_status().measured == measured;
}

static void hide(void)
{
    portal_text error = {0};
    CHECK(portal_status_dismiss(&error));
    CHECK(!portal_fake_status().shown);
}

static void test_positions(void)
{
    /* Each anchor, 10 points in from its left or right edge and 20 from its
       top or bottom; a centered axis moves right or down. */
    CHECK(show("Recording", "neutral", at("top-left", 10, 20)) && placed(10, 45, 104, 30));
    CHECK(show("Recording", "neutral", at("top", 10, 20)) && placed(678, 45, 104, 30));
    CHECK(show("Recording", "neutral", at("top-right", 10, 20)) && placed(1326, 45, 104, 30));
    CHECK(show("Recording", "neutral", at("left", 10, 20)) && placed(10, 467, 104, 30));
    CHECK(show("Recording", "neutral", at("center", 10, 20)) && placed(678, 467, 104, 30));
    CHECK(show("Recording", "neutral", at("right", 10, 20)) && placed(1326, 467, 104, 30));
    CHECK(show("Recording", "neutral", at("bottom-left", 10, 20)) && placed(10, 850, 104, 30));
    CHECK(show("Recording", "neutral", at("bottom", 10, 20)) && placed(678, 850, 104, 30));
    CHECK(show("Recording", "neutral", at("bottom-right", 10, 20)) && placed(1326, 850, 104, 30));
    /* Offsets never take the panel out of the area. */
    CHECK(show("Recording", "neutral", at("top-left", -50, 100000)) && placed(0, 870, 104, 30));
    CHECK(show("Recording", "neutral", at("bottom", 100000, 0)) && placed(1336, 870, 104, 30));
    /* A tone's mark widens the panel; the platform gets the tone and lines. */
    CHECK(show("Recording", "success", at("bottom", 0, 24)) && placed(658, 846, 124, 30));
    CHECK(portal_fake_status().tone == PORTAL_STATUS_SUCCESS);
    CHECK(portal_fake_status().lines == 1 && !strcmp(portal_fake_status().text, "Recording"));
    CHECK(show("Recording", "recording", at("bottom", 0, 24)) && placed(658, 846, 124, 30));
    CHECK(portal_fake_status().tone == PORTAL_STATUS_RECORDING);
    hide();
    hide();
}

static void test_sizes(void)
{
    portal_status_layout layout = at("top-left", 0, 0);
    layout.width = 300;
    layout.height = 50;
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 300, 50));
    /* A fitted width keeps to its bounds. */
    layout = at("top-left", 0, 0);
    layout.min_width = 200;
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 200, 30));
    layout.min_width = 0;
    layout.max_width = 80;
    CHECK(show("Recording a long dictation", "neutral", layout) && placed(0, 25, 80, 30));
    /* Text wraps at the maximum width up to the lines allowed. */
    layout.lines = 3;
    CHECK(show("Recording a long dictation", "neutral", layout) && placed(0, 25, 80, 62));
    CHECK(portal_fake_status().lines == 3);
    layout.lines = 10;
    CHECK(show("Recording a long dictation", "neutral", layout) && placed(0, 25, 80, 94));
    /* The area bounds every size. */
    layout = at("top-left", 0, 0);
    layout.width = 5000;
    layout.height = 5000;
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 1440, 875));
    layout = at("top-left", 0, 0);
    layout.min_width = 3000;
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 1440, 30));
    hide();
}

static void test_invalid(void)
{
    CHECK(show("Recording", "neutral", at("bottom", 0, 24)));
    struct portal_fake_status before = portal_fake_status();
    CHECK(rejected(at("bottom", 0, 0), "", "neutral", "A status is not empty"));
    CHECK(rejected(at("bottom", 0, 0), "Recording", "loud", "No such status tone: loud"));
    CHECK(rejected(at("middle", 0, 0), "Recording", "neutral",
                   "No such status panel position: middle"));
    portal_status_layout layout = at("bottom", 0, 0);
    layout.width = -1;
    CHECK(rejected(layout, "Recording", "neutral",
                   "A status panel size is 0 or a positive number of points"));
    layout = at("bottom", 0, 0);
    layout.min_width = 300;
    layout.max_width = 200;
    CHECK(rejected(layout, "Recording", "neutral",
                   "A status panel's minimum width exceeds its maximum"));
    layout = at("bottom", 0, 0);
    layout.lines = 0;
    CHECK(rejected(layout, "Recording", "neutral", "A status panel shows at least one line"));
    layout = at("bottom", 0, 0);
    layout.screen = -2;
    CHECK(rejected(layout, "Recording", "neutral",
                   "A status panel screen is -1 or a screen index"));
    CHECK(rejected(at("bottom", 1 << 21, 0), "Recording", "neutral",
                   "A status panel offset is out of range"));
    /* A platform's refusal changes nothing. */
    portal_text error = {0};
    portal_status_layout bottom = at("bottom", 0, 0);
    CHECK(!portal_status_present(text("Refuse this"), text("neutral"), &bottom, &error));
    CHECK(says(&error, "The fake may not show \"Refuse this\""));
    struct portal_fake_status after = portal_fake_status();
    CHECK(after.shown && !strcmp(after.text, before.text));
    CHECK(placed(before.rect.x, before.rect.y, before.rect.width, before.rect.height));
    hide();
}

static void test_screens(void)
{
    portal_screen screens[] = {primary, left};
    screens[1].pointer = true;
    portal_fake_screens(screens, 2);
    /* The pointer's screen by default, or the one asked for. */
    CHECK(show("Recording", "neutral", at("top-left", 0, 0)) && placed(-1920, -200, 104, 30));
    portal_status_layout layout = at("top-left", 0, 0);
    layout.screen = 0;
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 104, 30));
    layout.screen = 1;
    CHECK(show("Recording", "neutral", layout) && placed(-1920, -200, 104, 30));
    /* A missing screen falls back to the pointer's. */
    layout.screen = 7;
    screens[0].pointer = true;
    screens[1].pointer = false;
    portal_fake_screens(screens, 2);
    CHECK(show("Recording", "neutral", layout) && placed(0, 25, 104, 30));
    hide();

    /* A shown panel stays on its screen while the pointer moves. */
    screens[0].pointer = false;
    screens[1].pointer = true;
    portal_fake_screens(screens, 2);
    CHECK(show("Recording", "neutral", at("top-left", 0, 0)) && placed(-1920, -200, 104, 30));
    screens[0].pointer = true;
    screens[1].pointer = false;
    portal_fake_screens(screens, 2);
    CHECK(show("Transcribing", "progress", at("top-left", 0, 0)) && placed(-1920, -200, 148, 30));
    /* Unless that screen is gone. */
    portal_fake_screens(screens, 1);
    CHECK(show("Transcribing", "progress", at("top-left", 0, 0)) && placed(0, 25, 148, 30));
    portal_fake_screens(screens, 2);
    /* Once hidden, it appears where the pointer is. */
    screens[0].pointer = false;
    screens[1].pointer = true;
    portal_fake_screens(screens, 2);
    hide();
    CHECK(show("Done", "success", at("top-left", 0, 0)) && placed(-1920, -200, 84, 30));
    hide();
    portal_fake_screens(&(portal_screen) {{0, 25, 1440, 875}, true}, 1);
}

static void test_refusing(void)
{
    portal_text error = {0};
    portal_fake_refuse(true);
    portal_status_layout layout = at("bottom", 0, 0);
    CHECK(!portal_status_present(text("Recording"), text("neutral"), &layout, &error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    CHECK(!portal_status_dismiss(&error));
    CHECK(says(&error, "The fake refuses to run view primitives"));
    portal_fake_refuse(false);
    CHECK(!portal_fake_status().shown);
}

int main(void)
{
    test_positions();
    test_sizes();
    test_invalid();
    test_screens();
    test_refusing();
    if (failures) {
        fprintf(stderr, "%d checks failed\n", failures);
        return 1;
    }
    puts("Status panel passed");
    return 0;
}
