#!/usr/bin/env python3
"""The neopixel regression guard (docs/NEOPIXELS.md section 4.3), no cart needed.

    .venv/bin/python tests/test_neopixel_warning.py    (after one ./bench.sh run made .venv)

Feeds synthetic frame lists through run.neopixel_warning and checks that a
dark run gives no warning and a lit run gives exactly one naming the first
offending frame and the brightest channel. Exit 0 pass, 1 fail.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from badge_bench.run import neopixel_warning  # noqa: E402

DARK = [(0, 0, 0)] * 5


def frame(i, px=DARK):
    return dict(frame=i, neopixels=list(px), user_led=0)


def check(name, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got!r}")
    return ok


lit3 = [(0, 0, 0), (0, 3, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0)]
lit10 = [(10, 0, 0)] + [(0, 0, 1)] * 4
msg = "(carts must leave the LEDs dark, docs/NEOPIXELS.md)"
results = [
    check("empty run", neopixel_warning([]), None),
    check("dark run", neopixel_warning([frame(i) for i in range(20)]), None),
    check("lit from frame 7, peak 10 at frame 12",
          neopixel_warning([frame(i) for i in range(7)] + [frame(7, lit3)]
                           + [frame(i) for i in range(8, 12)] + [frame(12, lit10), frame(13)]),
          f"neopixels written: frame 7, max channel 10 {msg}"),
    check("single byte in the last frame",
          neopixel_warning([frame(0), frame(1, [(0, 0, 0)] * 4 + [(0, 0, 255)])]),
          f"neopixels written: frame 1, max channel 255 {msg}"),
]
sys.exit(0 if all(results) else 1)
