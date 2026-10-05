#!/usr/bin/env python3
"""Draw Snouty GC's art sheets (code-drawn, final per the art policy).

  python3 carts/snouty-gc/tools/draw_art.py

Writes assets/gen/art/*.png (RGB, #FF00FF = transparent, <= 15 other colours
after the converter's RGB565 cut, horizontal strips of equal cells; see
ASSETS.md) and the review images docs/art_contact.png (every sheet at 3x,
labelled) and docs/art_select_mock.png (the racer select screen at 3x for
all six racers, bios in the cart's 8x8 font). Deterministic; Pillow only.
Every sheet is validated and the run exits non-zero on any violation.

Modules under tools/art/: raster (the canvas), portraits, cars, items,
hazards (M3: the Sweeper).
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))

from art import cars, hazards, items, portraits  # noqa: E402
from art.raster import KEY, Canvas, Font8  # noqa: E402

CART = Path(__file__).resolve().parent.parent
OUT = CART / "assets" / "gen" / "art"
DOCS = CART / "docs"
FONT = CART.parent / "snouty-zero" / "assets" / "gen" / "font.bin"

RACERS = ["snouty", "legacy", "kiddie", "sysadmin", "rootkit", "botnet"]


@dataclass(frozen=True)
class Sheet:
    name: str
    cell_w: int
    cell_h: int
    frames: int
    draw: object
    note: str
    opaque: bool = False    # portraits: no key pixels


def manifest() -> list[Sheet]:
    sheets = []
    pf = dict(portraits.PORTRAITS)
    for r in RACERS:
        sheets.append(Sheet(f"portrait_{r}.png", 48, 48, 1, pf[r], f"{r.upper()} portrait", opaque=True))
    cf = {n: (label, fn) for n, label, fn in cars.CARS}
    for r in RACERS:
        label, fn = cf[r]
        sheets.append(Sheet(f"car_{r}.png", 32, 16, 5, (lambda fn=fn: cars.draw_car(fn)[0]), f"{label} ({r.upper()})"))
    sheets += [
        Sheet("weapons.png", 8, 8, len(items.WEAPONS), items.draw_weapons, "weapons and world objects"),
        Sheet("decals.png", 16, 8, len(items.DECALS), items.draw_decals, "flat floor decals"),
        Sheet("pickups.png", 16, 16, len(items.PICKUP_CELLS), items.draw_pickups, "pickup icons and crates"),
        Sheet("fx.png", 24, 24, len(items.FX_CELLS), items.draw_fx, "effects"),
        Sheet("claw.png", 24, 32, 2, items.draw_claw, "GC claw (open, closed)"),
        Sheet("hud.png", 12, 12, len(items.HUD), items.draw_hud, "HUD bits"),
        Sheet("hazards.png", 48, 32, len(hazards.HAZARD_CELLS), hazards.draw_hazards, "track hazards: the Sweeper"),
    ]
    return sheets


# ------------------------------------------------------------- validation
def q565(c):
    """The converter's cut (cart/build/convert_gfx.zig): floor(31 r/255), floor(63 g/255), floor(31 b/255)."""
    return (c[0] * 31 // 255, c[1] * 63 // 255, c[2] * 31 // 255)


def validate(s: Sheet, cv: Canvas) -> list[str]:
    err = []
    if (cv.w, cv.h) != (s.cell_w * s.frames, s.cell_h):
        return [f"size {cv.w}x{cv.h}, expected {s.cell_w * s.frames}x{s.cell_h}"]
    key565 = q565(KEY)
    cols = set()
    keys = 0
    for row in cv.px:
        for c in row:
            if c is None:
                keys += 1
                continue
            if c == KEY or q565(c) == key565:
                err.append("an opaque colour collapses onto the key after RGB565")
                break
            cols.add(q565(c))
    if len(cols) > 15:
        err.append(f"{len(cols)} opaque colours after RGB565, max 15")
    if s.opaque and keys:
        err.append(f"{keys} transparent pixels in an opaque sheet")
    if not s.opaque and not keys:
        err.append("no key pixels")
    for i in range(s.frames):
        if not any(cv.px[y][x] is not None for y in range(s.cell_h) for x in range(i * s.cell_w, (i + 1) * s.cell_w)):
            err.append(f"cell {i} empty")
    print(f"{s.name:22s} {cv.w:3d}x{cv.h:<3d} {s.frames:2d} x {s.cell_w}x{s.cell_h}  colours {len(cols):2d}/15")
    for e in err:
        print(f"{'':22s} ERROR {e}")
    return err


# ------------------------------------------------------------- review images
BG = (22, 20, 28)
INK = (220, 216, 228)
DIM = (140, 136, 152)


def checker(w, h, k=6):
    im = Image.new("RGB", (w, h), (46, 42, 56))
    d = ImageDraw.Draw(im)
    for y in range(0, h, k):
        for x in range(0, w, k):
            if (x // k + y // k) % 2:
                d.rectangle([x, y, x + k - 1, y + k - 1], fill=(60, 56, 72))
    return im


def label_font(size=14):
    return ImageFont.load_default(size=size)


def write_contact(path: Path, sheets: list[tuple[Sheet, Canvas]]) -> None:
    z = 3
    pad, lh = 12, 20
    blocks = []
    pics = [(s, cv) for s, cv in sheets if s.name.startswith("portrait_")]
    row = Image.new("RGB", (len(pics) * (48 * z + 8) - 8, 48 * z), BG)
    for i, (s, cv) in enumerate(pics):
        row.paste(cv.to_image(z), (i * (48 * z + 8), 0))
    blocks.append(("portrait_<racer>.png  1 x 48x48 each, opaque: " + ", ".join(RACERS) + "; 3x", row))
    for s, cv in sheets:
        if s.name.startswith("portrait_"):
            continue
        w, h = cv.w * z, cv.h * z
        im = checker(w, h)
        big = cv.to_image(z)
        mask = Image.new("L", (cv.w, cv.h), 0)
        mask.putdata([255 if px is not None else 0 for row_ in cv.px for px in row_])
        im.paste(big, (0, 0), mask.resize(big.size, Image.NEAREST))
        d = ImageDraw.Draw(im)
        for i in range(1, s.frames):
            d.line([(i * s.cell_w * z, 0), (i * s.cell_w * z, h)], fill=(22, 20, 28))
        blocks.append((f"{s.name}  {s.frames} x {s.cell_w}x{s.cell_h}  ({s.note}), 3x", im))
    # portraits at half scale (nearest), the race taunt pop-up size
    row = Image.new("RGB", (len(RACERS) * (24 * z + 8), 24 * z), BG)
    for i, (s, cv) in enumerate([sc for sc in sheets if sc[0].name.startswith("portrait_")]):
        half = cv.to_image().resize((24, 24), Image.NEAREST).resize((24 * z, 24 * z), Image.NEAREST)
        row.paste(half, (i * (24 * z + 8), 0))
    blocks.append(("portraits at half scale (24x24 nearest, as in the taunt pop-up), 3x", row))
    W = max(im.width for _, im in blocks) + 2 * pad
    H = sum(im.height + lh + pad for _, im in blocks) + pad
    out = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(out)
    f = label_font()
    y = pad
    for label, im in blocks:
        d.text((pad, y), label, fill=INK, font=f)
        y += lh
        out.paste(im, (pad, y))
        y += im.height + pad
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, optimize=True)
    print(f"contact sheet {path.relative_to(CART)} {W}x{H}")


# The roster as SPEC 4.1 has it (bios possibly tightened; see ASSETS.md).
ROSTER = [
    ("SNOUTY", "ANTEATER", "WORKSTATION", "SPEAR PHISH", "LOGIC BOMB",
     ["ATE BUGS. NOW HUNTS", "THEM. LOST AN EYE", "TO A HEISENBUG IN", "PROD. IT KNOWS."]),
    ("LEGACY", "BIG IRON", "MAINFRAME", "BROADCAST", "FIREWALL",
     ["RACING SINCE THE", "MAINFRAMES. HAS", "DECLINED EVERY", "UPDATE. EVERY ONE."]),
    ("KIDDIE", "CTRL-V", "THIN CLIENT", "PING", "MEMORY LEAK",
     ["COPIED EVERY GUN", "FROM A FORUM. READ", "NONE OF THE DOCS.", "9 OF 10 FINGERS."]),
    ("SYSADMIN", "UPTIME", "WORKSTATION", "FIBER LANCE", "BIT ROT",
     ["NO SLEEP SINCE THE", "MACHINES WOKE UP.", "RUNS ON SPITE AND", "RECYCLED COFFEE."]),
    ("ROOTKIT", "PERSIST", "THIN CLIENT", "FIBER LANCE", "MEMORY LEAK",
     ["NOBODY SAW ROOTKIT", "GET IN THE CAR.", "ROOTKIT WAS ALWAYS", "IN THE CAR."]),
    ("BOTNET", "ZOMBIE", "MAINFRAME", "PING", "BIT ROT",
     ["14 COUSINS, ONE", "BUS, A MAJORITY", "VOTE ON EVERY TURN.", "TURNS ARE LATE."]),
]
# Mock stat bars (0..8): SPD and ARM from the chassis (SPEC 4.2), DMG a feel for the loadout.
STATS = {"WORKSTATION": (6, 5), "THIN CLIENT": (8, 3), "MAINFRAME": (4, 8)}
DMG = {"SNOUTY": 7, "LEGACY": 6, "KIDDIE": 4, "SYSADMIN": 6, "ROOTKIT": 5, "BOTNET": 4}
LIVERY = {"SNOUTY": 0x8E42DE, "LEGACY": 0x4A7AD0, "KIDDIE": 0x7CD040, "SYSADMIN": 0xE04040,
          "ROOTKIT": 0x40F070, "BOTNET": 0xF0C030}


def select_screen(i: int, font: Font8, sheets: dict) -> Canvas:
    """A 160x128 mock of the racer select (SPEC 8.1)."""
    name, car, chassis, front, rear, bio = ROSTER[i]
    racer = RACERS[i]
    liv = ((LIVERY[name] >> 16) & 255, (LIVERY[name] >> 8) & 255, LIVERY[name] & 255)
    bg, panel, ink, dim, line = (16, 14, 22), (34, 30, 44), (236, 232, 240), (150, 146, 164), (70, 64, 86)
    cv = Canvas(160, 128, bg)
    cv.rect(0, 0, 159, 127, bg)
    # portrait, framed in the livery colour
    cv.rect(3, 3, 52, 52, liv)
    cv.paste(sheets[f"portrait_{racer}.png"], 4, 4)
    # name, car, chassis
    font.draw(cv, name, 58, 5, liv)
    font.draw(cv, car, 58, 15, ink)
    # the car on its turntable: show the rear-quarter view on a little plinth
    carsheet = sheets[f"car_{racer}.png"]
    cv.ellipse(74, 44, 17, 4, panel)
    cell = Canvas(32, 16)
    for y in range(16):
        for x in range(32):
            cell.px[y][x] = carsheet.px[y][32 + x]
    cv.paste(cell, 58, 30)
    # stat bars
    spd, arm = STATS[chassis]
    for k, (lab, v) in enumerate((("SPD", spd), ("ARM", arm), ("DMG", DMG[name]))):
        y = 26 + k * 9
        font.draw(cv, lab, 96, y, dim)
        for j in range(8):
            cv.rect(121 + j * 4, y + 1, 123 + j * 4, y + 6, liv if j < v else line)
    # weapons: A fires the front gun, Down+A drops the rear one
    font.draw(cv, "A", 4, 56, liv)
    font.draw(cv, front, 24, 56, ink)
    cv.stamp(["..x..", "..x..", "..x..", "xxxxx", ".xxx.", "..x.."], 4, 66, {"x": liv})
    font.draw(cv, "A", 11, 65, liv)
    font.draw(cv, rear, 24, 65, ink)
    cv.hline(4, 155, 75, line)
    for k, ln in enumerate(bio):
        assert len(ln) <= 19, f"bio line too long ({len(ln)}): {ln}"
        font.draw(cv, ln, 4, 78 + k * 9, ink)
    # cycling arrows and the pick hint, 4 px clear of the bottom edge
    font.draw(cv, "<", 4, 116, dim)
    font.draw(cv, ">", 148, 116, dim)
    font.draw(cv, "A PICK", 56, 116, dim)
    return cv


def write_select_mock(path: Path, sheets: dict) -> None:
    font = Font8(FONT)
    z = 3
    gap, lh = 16, 20
    cols, rows = 2, 3
    W = cols * 160 * z + (cols + 1) * gap
    H = rows * (128 * z + lh) + (rows + 1) * gap
    out = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(out)
    f = label_font()
    for i in range(6):
        cx, cy = i % cols, i // cols
        x = gap + cx * (160 * z + gap)
        y = gap + cy * (128 * z + lh + gap)
        d.text((x, y), f"racer select mock: {ROSTER[i][0]} (160x128 at 3x)", fill=INK, font=f)
        out.paste(select_screen(i, font, sheets).to_image(z), (x, y + lh))
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, optimize=True)
    print(f"select mock {path.relative_to(CART)} {W}x{H}")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    errors = 0
    done = []
    for s in manifest():
        cv = s.draw()
        errs = validate(s, cv)
        errors += len(errs)
        if not errs:
            cv.to_image().save(OUT / s.name, optimize=True)
        done.append((s, cv))
    byname = {s.name: cv for s, cv in done}
    write_contact(DOCS / "art_contact.png", done)
    write_select_mock(DOCS / "art_select_mock.png", byname)
    print("OK" if not errors else f"{errors} error(s); failing sheets not written")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
