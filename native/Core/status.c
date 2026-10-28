/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The status panel: Portal's rules for where it goes and how big it is, on
   the platform's screens and its panel, which measures and draws the text.
   Lisp decides what the panel says and when it hides. */
#include <stdlib.h>

#include "core.h"
#include "status.h"

static const char *const tones[] = {"neutral", "progress", "success", "warning", "error"};

/* Where an anchor puts the panel along one axis. */
enum side { START, MIDDLE, END };

static const struct {
    const char *name;
    enum side horizontal, vertical;
} anchors[] = {
    {"top-left", START, START},    {"top", MIDDLE, START},       {"top-right", END, START},
    {"left", START, MIDDLE},       {"center", MIDDLE, MIDDLE},   {"right", END, MIDDLE},
    {"bottom-left", START, END},   {"bottom", MIDDLE, END},      {"bottom-right", END, END},
};

/* The screen area the shown panel is on; none while it is hidden. */
static struct {
    bool shown;
    portal_rect area;
} panel;

/* Offsets and sizes beyond this are mistakes, and keep the arithmetic in
   range. */
enum { LIMIT = 1 << 20 };

static int64_t clamp(int64_t value, int64_t low, int64_t high)
{
    return value < low ? low : value > high ? high : value;
}

static bool same(portal_rect a, portal_rect b)
{
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

/* The start of a SIZE long panel along an axis of AREA_SIZE from START,
   placed at SIDE and moved by OFFSET, inside the area. */
static int64_t place(enum side side, int64_t start, int64_t area_size, int64_t size,
                     int64_t offset)
{
    int64_t room = area_size - size;
    int64_t at = side == START ? offset : side == END ? room - offset : room / 2 + offset;
    return start + clamp(at, 0, room);
}

/* The area of the screen LAYOUT asks for, among the platform's. */
static bool choose(const portal_status_layout *layout, portal_rect *area, portal_text *error)
{
    portal_screen *screens = NULL;
    size_t count = 0;
    if (!portal_screens(&screens, &count, error))
        return false;
    const portal_screen *chosen = NULL;
    if (layout->screen >= 0 && (size_t) layout->screen < count)
        chosen = &screens[layout->screen];
    for (size_t i = 0; !chosen && layout->screen < 0 && panel.shown && i < count; i++)
        if (same(screens[i].area, panel.area))
            chosen = &screens[i];
    for (size_t i = 0; !chosen && i < count; i++)
        if (screens[i].pointer)
            chosen = &screens[i];
    if (!chosen && count)
        chosen = &screens[0];
    bool found = chosen && chosen->area.width > 0 && chosen->area.height > 0;
    if (found)
        *area = chosen->area;
    free(screens);
    return found || fail_with(error, "The platform reported no usable screen");
}

static bool valid(const portal_status_layout *layout, portal_text *error)
{
    const int64_t sizes[] = {layout->width, layout->height, layout->min_width,
                             layout->max_width};
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++)
        if (sizes[i] < 0 || sizes[i] > LIMIT)
            return fail_with(error, "A status panel size is 0 or a positive number of points");
    if (layout->min_width && layout->max_width && layout->min_width > layout->max_width)
        return fail_with(error, "A status panel's minimum width exceeds its maximum");
    if (layout->dx < -LIMIT || layout->dx > LIMIT || layout->dy < -LIMIT || layout->dy > LIMIT)
        return fail_with(error, "A status panel offset is out of range");
    if (layout->screen < -1)
        return fail_with(error, "A status panel screen is -1 or a screen index");
    if (layout->lines < 1 || layout->lines > LIMIT)
        return fail_with(error, "A status panel shows at least one line");
    return true;
}

bool portal_status_present(portal_string text, portal_string tone_name,
                           const portal_status_layout *layout, portal_text *error)
{
    if (!text.length)
        return fail_with(error, "A status is not empty");
    size_t tone = 0;
    while (tone < sizeof tones / sizeof *tones && !is(tone_name, tones[tone]))
        tone++;
    if (tone == sizeof tones / sizeof *tones)
        return fail(error, "No such status tone: ", tone_name);
    size_t anchor = 0;
    while (anchor < sizeof anchors / sizeof *anchors && !is(layout->position, anchors[anchor].name))
        anchor++;
    if (anchor == sizeof anchors / sizeof *anchors)
        return fail(error, "No such status panel position: ", layout->position);
    portal_rect area;
    if (!valid(layout, error) || !choose(layout, &area, error))
        return false;

    int64_t limit = layout->max_width ? clamp(layout->max_width, 1, area.width) : area.width;
    int64_t width = layout->width ? clamp(layout->width, 1, area.width) : limit;
    int64_t fitted, height;
    if (!portal_status_measure(text, (portal_status_tone) tone, width, layout->lines, &fitted,
                               &height, error))
        return false;
    if (!layout->width)
        width = clamp(fitted > layout->min_width ? fitted : layout->min_width, 1, limit);
    height = clamp(layout->height ? layout->height : height, 1, area.height);

    portal_rect rect = {
        .x = place(anchors[anchor].horizontal, area.x, area.width, width, layout->dx),
        .y = place(anchors[anchor].vertical, area.y, area.height, height, layout->dy),
        .width = width,
        .height = height,
    };
    if (!portal_status_show(text, (portal_status_tone) tone, rect, layout->lines, error))
        return false;
    panel.shown = true;
    panel.area = area;
    return true;
}

bool portal_status_dismiss(portal_text *error)
{
    if (!portal_status_hide(error))
        return false;
    panel.shown = false;
    return true;
}
