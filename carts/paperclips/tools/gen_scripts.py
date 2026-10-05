#!/usr/bin/env python3
"""Writes the input scripts in tools/scripts/ (preview.mjs and badge-bench
format: [{"from": T1, "to": T2, "hold": ["A"]}], inclusive frame ranges).

  tour.json   about 15 s: the title, making clips, the price, a walk
              through the pages, the message log. For the preview GIF.
  soak.json   10 minutes (36,000 frames): a bot that walks every page
              pressing and holding every row, opening the log and jumping
              to news. For the no-trap gate.
  cheats.json the title's code, then the CHEATS page's buttons.
  bench.json  600 frames on a prepared game (--poke paperclips_bench=N):
              cursor moves, presses, held repeats, a page change.

  tools/gen_scripts.py           # rewrite them
  tools/gen_scripts.py --check   # exit 1 if a committed script is stale
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "scripts")


class Script:
    def __init__(self):
        self.items = []
        self.t = 0

    def wait(self, n):
        self.t += n

    def tap(self, *buttons, hold=2, gap=4):
        self.items.append({"from": self.t, "to": self.t + hold - 1, "hold": list(buttons)})
        self.t += hold + gap

    def hold(self, frames, *buttons):
        self.items.append({"from": self.t, "to": self.t + frames - 1, "hold": list(buttons)})
        self.t += frames + 4


def tour():
    s = Script()
    s.wait(90)  # the title
    s.tap("A")  # start
    s.wait(30)
    for _ in range(14):  # make clips by hand
        s.tap("A", gap=6)
    s.wait(20)
    s.tap("DOWN")  # to the price row
    s.wait(10)
    for _ in range(3):
        s.tap("A", gap=10)  # raise
    for _ in range(4):
        s.tap("B", gap=10)  # lower
    s.wait(30)
    s.tap("UP")
    for _ in range(20):
        s.tap("A", gap=5)
    s.wait(40)
    for _ in range(3):
        s.tap("RIGHT")
        s.wait(70)
    s.tap("LEFT")
    s.wait(40)
    s.tap("START")
    s.wait(80)
    s.tap("START")
    s.wait(40)
    return s


def soak():
    s = Script()
    s.wait(30)
    s.tap("A")  # start the game (no cheats: the game unfolds at its own pace)
    s.wait(20)
    total = 36000
    k = 0
    while s.t < total - 400:
        k += 1
        # Make clips on the first page for a while.
        for _ in range(10):
            s.tap("A", gap=3)
        # Walk the rows of each page: press, and sometimes hold.
        for page in range(7):
            for row in range(1 + (k + page) % 6):
                s.tap("DOWN", gap=3)
                s.tap("A", gap=3)
                if (k + row) % 3 == 0:
                    s.hold(40, "A")
                if (k + row + page) % 4 == 0:
                    s.tap("B", gap=3)
            for _ in range(6):
                s.tap("UP", gap=2)
            s.tap("RIGHT", gap=6)
        if k % 3 == 0:
            s.tap("START")
            s.tap("UP")
            s.tap("UP")
            s.tap("START")
        if k % 2 == 0:
            s.tap("SELECT")
        # Let the game run a little.
        s.wait(120)
    return s


def bench():
    s = Script()
    s.wait(30)
    for _ in range(3):
        s.tap("DOWN", gap=8)
        s.tap("A", gap=8)
    s.hold(120, "A")
    s.tap("UP", gap=8)
    s.hold(60, "B")
    s.tap("RIGHT", gap=20)
    s.tap("START", gap=30)
    s.tap("START", gap=30)
    s.tap("LEFT", gap=20)
    return s


def cheats():
    s = Script()
    s.wait(30)
    for b in ["UP", "UP", "DOWN", "DOWN", "LEFT", "RIGHT", "LEFT", "RIGHT", "B", "A"]:
        s.tap(b)
    s.wait(60)
    s.tap("A")
    s.wait(20)
    s.tap("LEFT")  # CHEATS is the last page
    s.wait(20)
    s.tap("A")  # Free Clips
    s.tap("DOWN")
    s.tap("A")  # Free Money
    s.wait(30)
    return s


def gif():
    """The review GIF (docs/RUNNING.md section 7): the tour, then the
    stages through debug_autoplay calls made at fixed frames
    (gif_calls below), a walk over each stage's pages."""
    s = tour()
    # 980: stage 2 (debug_autoplay:9000 at 990), walk the pages.
    s.t = 1000
    for _ in range(7):
        s.tap("RIGHT")
        s.wait(34)
    # 1300: stage 3 (debug_autoplay:11000 at 1290).
    s.t = 1310
    for _ in range(9):
        s.tap("RIGHT")
        s.wait(34)
    # 1660: the end (debug_autoplay:8000 at 1650), the log.
    s.t = 1700
    s.tap("START")
    s.wait(60)
    s.tap("START")
    s.wait(30)
    return s


SCRIPTS = {"gif.json": gif, "cheats.json": cheats, "tour.json": tour, "soak.json": soak, "bench.json": bench}


def render(fn):
    s = fn()
    return json.dumps(s.items, separators=(",", ":")) + "\n", s.t


def main():
    check = "--check" in sys.argv
    stale = False
    for name, fn in SCRIPTS.items():
        text, frames = render(fn)
        path = os.path.join(OUT, name)
        if check:
            if not os.path.exists(path) or open(path).read() != text:
                print("gen_scripts: %s is stale" % name, file=sys.stderr)
                stale = True
        else:
            with open(path, "w") as f:
                f.write(text)
            print("%s: %d frames" % (name, frames))
    sys.exit(1 if stale else 0)


if __name__ == "__main__":
    main()
