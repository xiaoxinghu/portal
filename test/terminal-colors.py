# SPDX-License-Identifier: GPL-3.0-or-later
"""Query a terminal's actual background color over its PTY for the graphical ERT tests."""

import json
import os
import re
import select
import sys
import termios
import time
import tty


def query(fd, sequence):
    os.write(fd, sequence)
    response = b""
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            response += os.read(fd, 1024)
            match = re.search(rb"rgb:([0-9a-f]+)/([0-9a-f]+)/([0-9a-f]+)(?:\x07|\x1b\\)", response)
            if match:
                return "".join(f"{round(int(c, 16) * 255 / (16 ** len(c) - 1)):02x}" for c in match.groups())
    raise RuntimeError(f"No color response: {response!r}")


with open("/dev/tty", "r+b", buffering=0) as terminal:
    fd = terminal.fileno()
    previous = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        colors = {"background": query(fd, b"\x1b]11;?\x07")}
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, previous)
colors["pid"] = os.getppid()
with open(sys.argv[1] + ".tmp", "w") as receipt:
    json.dump(colors, receipt)
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
