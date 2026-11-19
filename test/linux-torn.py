# SPDX-License-Identifier: GPL-3.0-or-later
"""linux-torn.py RECORDING LEFT TOP RIGHT BOTTOM: whether any frame of a
recording shows a torn terminal.

The terminal's cells in the box LEFT TOP RIGHT BOTTOM, in the recording's
pixels, clear of its padding, are all red, then all blue, over and over, as
fast as its program writes (test/portal-linux-terminal-tests.el).  Ghostty
draws each frame from one state of the terminal, so a frame it made is all
red or all blue.  A frame that is both was drawn into while it was shown:
the renderer reused a texture the compositor still read.

A grid of 16 by 10 points inside the box is read in every frame, a frame at
a time, from a crop that ffmpeg decodes.  Prints how many frames were red,
blue, torn and neither (the terminal not flashing yet, or done), and exits
1 if any was torn, or if none was red or blue."""
import subprocess
import sys


def main(recording, left, top, right, bottom):
    width, height = right - left, bottom - top
    process = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-i', recording, '-vf',
         f'crop={width}:{height}:{left}:{top}', '-fps_mode', 'passthrough',
         '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    size = width * height * 3
    counts = {'red': 0, 'blue': 0, 'torn': 0, 'neither': 0}
    while True:
        frame = process.stdout.read(size)
        if len(frame) < size:
            break
        kinds = set()
        for gy in range(10):
            for gx in range(16):
                x, y = gx * (width - 1) // 15, gy * (height - 1) // 9
                r, g, b = frame[(y * width + x) * 3:(y * width + x) * 3 + 3]
                kinds.add('red' if r > 200 and g < 60 and b < 60 else
                          'blue' if b > 200 and r < 60 and g < 60 else 'other')
        if kinds in ({'red'}, {'blue'}):
            counts[kinds.pop()] += 1
        elif kinds == {'red', 'blue'}:
            counts['torn'] += 1
        else:
            counts['neither'] += 1
    process.stdout.close()
    process.wait()
    print(f"{counts['red']} red, {counts['blue']} blue, {counts['torn']} torn, "
          f"{counts['neither']} neither")
    return 1 if counts['torn'] or not (counts['red'] and counts['blue']) else 0


if __name__ == '__main__':
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], *map(int, sys.argv[2:])))
