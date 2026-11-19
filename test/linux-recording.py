# SPDX-License-Identifier: GPL-3.0-or-later
"""linux-recording.py RECORDING: whether the view was where its pane was, in
every frame of a recording that test/linux-follow.sh made.

The recording is of Emacs as test/portal-linux-follow.el colors it: the
test pattern (a red edge, a magenta fill, a blue square) over its pane,
which is green underneath; every other pane yellow; fringes navy; the mode
line of a pane showing the view's buffer brown, every other one gray.  A
frame is in place when:

- no green shows: the view covers all of its pane, and is not gone while
  Emacs still draws its buffer;
- the view is one solid rectangle;
- the brown mode line is directly below it and as wide as it, with the
  fringes: the view is over its own buffer's pane and not over a pane or a
  mode line beside or below it, nor still there once Emacs draws another
  buffer;
- to the pixel, down one column and along one row through the view: the
  pattern's edge on the pixel after the fringe, the fringe on the pixel
  after its other edge, and the mode line on the pixel after its last row.

A compositor that has resized a window shows the window's last frame at
the new size, stretched, until the window draws one of that size, and GTK
first draws Emacs's last frame at that size, cut or padded, before Emacs
has drawn its own.  Emacs's pixels are then not where Emacs drew them, or
not all there, and no view can be over its pane.  Such frames are told by
the echo area's row, where the fringes are not as wide as Emacs draws them
or not both there, and are counted apart.

The frames are never held together: ffmpeg decodes the recording four
times at once, to an eighth of its size, to one column and to two rows, and
each is read a frame at a time.

Prints each frame that is out of place and why, then how many there were of
how many, how many times the view moved, and in how many frames the window
was between two sizes.  Exits 1 if any frame was out of place."""
import subprocess
import sys

COLUMN, ROW = 200, 60  # Device pixels, through the view wherever the run puts it.
ECHO = 20  # Device pixels above the frame's last row, in its echo area.
FRINGE = 16
CELL = 8


def kind(red, green, blue):
    """What a pixel is: G the pane, M the view, D and L the mode lines, F a fringe."""
    if red < 40 and green > 215 and blue < 40:
        return 'G'
    if red > 215 and green < 40 and blue < 40:
        return 'M'
    if abs(red - 217) < 12 and abs(green - 51) < 12 and 140 < blue < 200:
        return 'M'
    if red < 40 and blue > 215:
        return 'M'
    if abs(red - 128) < 12 and abs(green - 64) < 12 and blue < 12:
        return 'D'
    if abs(red - 160) < 12 and abs(green - 160) < 12 and abs(blue - 160) < 12:
        return 'L'
    if red < 40 and green < 40 and abs(blue - 128) < 12:
        return 'F'
    return '.'


def kinds(pixels):
    return [kind(pixels[i], pixels[i + 1], pixels[i + 2]) for i in range(0, len(pixels), 3)]


def runs(line):
    """The runs of one kind along a line of kinds, as (kind, first, last)."""
    found, start = [], 0
    for i in range(1, len(line) + 1):
        if i == len(line) or line[i] != line[start]:
            found.append((line[start], start, i - 1))
            start = i
    return found


def decode(recording, filter_, size):
    process = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-i', recording, '-vf', filter_, '-f', 'rawvideo',
         '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    while True:
        frame = process.stdout.read(size)
        if len(frame) < size:
            break
        yield frame
    process.stdout.close()
    process.wait()


def overview(frame, width, height):
    """What is wrong with a frame an eighth of the size, and the view's box in it."""
    rows = [kinds(frame[y * width * 3:(y + 1) * width * 3]) for y in range(height)]
    if any('G' in row for row in rows):
        return 'the pane shows beside the view', None
    seen = [(x, y) for y, row in enumerate(rows) for x, cell in enumerate(row) if cell == 'M']
    if not seen:
        # A mode line is a bar across a pane, not a dark pixel of some text.
        if any(''.join(row).count('D' * 20) for row in rows):
            return "the view's buffer is in a pane, and the view is nowhere", None
        return None, None
    left, right = min(x for x, _ in seen), max(x for x, _ in seen)
    top, bottom = min(y for _, y in seen), max(y for _, y in seen)
    box = (left, top, right, bottom)
    if len(seen) != (right - left + 1) * (bottom - top + 1):
        return 'the view is not one rectangle', box
    below = rows[bottom + 2] if bottom + 2 < height else []
    dark = [x for x, cell in enumerate(below) if cell == 'D']
    if not dark or any(below[x] != 'D' for x in range(left, right + 1)):
        return "the view's mode line is not below it", box
    # The mode line is as wide as the pane and its two fringes, 16 pixels each.
    if not (left - 3 <= min(dark) <= left and right <= max(dark) <= right + 3):
        return "the view is not as wide as its pane's mode line", box
    return None, box


def column(frame):
    line = runs(kinds(frame))
    for i, (what, _, _) in enumerate(line):
        if what == 'G':
            return 'the pane shows above or below the view'
        if what == 'M' and (i + 1 == len(line) or line[i + 1][0] != 'D'):
            return "the view's last row is not on its mode line"
        if what == 'D' and (i == 0 or line[i - 1][0] != 'M'):
            return "the view's mode line has no view on it"
    return None


def row(frame):
    line = runs(kinds(frame))
    for i, (what, first, last) in enumerate(line):
        if what == 'G':
            return 'the pane shows left or right of the view'
        if what != 'M':
            continue
        before = line[i - 1] if i else None
        after = line[i + 1] if i + 1 < len(line) else None
        if not before or before[0] != 'F' or before[2] - before[1] != FRINGE - 1:
            return "the view's left edge is not on its pane's"
        if not after or after[0] != 'F':
            return "the view's right edge is not on its pane's"
    return None


def resized(frame):
    """Whether the echo area's row is not as Emacs draws it: a fringe, the
    empty echo area, and a fringe, or two where a second frame's begins."""
    line = runs(kinds(frame))
    return (len(line) < 3 or line[0] != ('F', 0, FRINGE - 1) or line[1][0] != '.'
            or line[2][0] != 'F' or line[2][2] - line[2][1] + 1 not in (FRINGE, 2 * FRINGE))


def main(recording):
    width, height = map(int, subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries',
         'stream=width,height', '-of', 'csv=p=0', recording],
        capture_output=True, text=True, check=True).stdout.strip().split(','))
    small = (width // CELL, height // CELL)
    streams = zip(
        decode(recording, f'scale={small[0]}:{small[1]}:flags=neighbor', small[0] * small[1] * 3),
        decode(recording, f'crop=1:{height}:{COLUMN}:0', height * 3),
        decode(recording, f'crop={width}:1:0:{ROW}', width * 3),
        decode(recording, f'crop={width}:1:0:{height - ECHO}', width * 3))
    frames = shown = wrong = moves = resizing = 0
    last = None
    for whole, down, along, echo in streams:
        reason, box = overview(whole, *small)
        if not reason and box:
            reason = column(down) or row(along)
        if box:
            shown += 1
        if box != last:
            moves += 1
            last = box
        if resized(echo):
            resizing += 1
        elif reason:
            wrong += 1
            print(f'frame {frames:5d} at {frames / 60:7.3f} s: {reason}')
        frames += 1
    print(f'{frames} frames, the view in {shown}; it moved, came or went {moves} times; '
          f'the window was between two sizes in {resizing}; {wrong} out of place')
    return 1 if wrong or not frames or not shown else 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
