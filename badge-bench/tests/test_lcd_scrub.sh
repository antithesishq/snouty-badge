#!/usr/bin/env bash
# The scrubber reaches the screen (--lcd): after a scrub step the emulator
# menu collapses to a bar and the restored frame must be on the LCD, not
# just in the framebuffer. The menu runs in .copy_forward, where only marked
# rects are sent to the panel; a scrub step that forgets mark_dirty_rect
# leaves the old menu on the badge while the simulator (which shows the whole
# framebuffer) looks right.
#
#   tests/test_lcd_scrub.sh [path/to/snouty-lynx.elf]
#
# Default ELF: ../zig-out/firmware/snouty-lynx.elf (`zig build -Dcart=snouty-lynx`
# at the repository root). Snouty Lynx because its drive fixture and scrub
# script are committed; Boy, Gear and Genesis share the menu code path.
# m3_scrub.json opens the menu at update 314 and steps back at 330 and 345.
# Frame 332 (a scrub-bar frame) must be identical in the --lcd PNG and the
# plain framebuffer PNG. Exit 0 pass, 1 fail.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ELF="${1:-$ROOT/zig-out/firmware/snouty-lynx.elf}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

args=(--no-config --frames 340 --png 332
      --romfs "$ROOT/carts/snouty-lynx/tests/fixtures/m1_drive.img"
      --script "$ROOT/carts/snouty-lynx/tools/scripts/m3_scrub.json")
"$HERE/bench.sh" "$ELF" "${args[@]}" --out "$OUT/fb" >/dev/null
"$HERE/bench.sh" "$ELF" "${args[@]}" --out "$OUT/lcd" --lcd >/dev/null

if cmp -s "$OUT/fb/frame_0332.png" "$OUT/lcd/frame_0332.png"; then
    echo "ok   scrub frame 332 is on the LCD"
else
    echo "FAIL scrub frame 332: the LCD differs from the framebuffer (a scrub step without mark_dirty_rect?)"
    exit 1
fi
