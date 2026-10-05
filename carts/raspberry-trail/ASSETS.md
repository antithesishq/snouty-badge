# The Raspberry Trail: assets

Every picture is painted in code by `tools/gen_art.py` (Python 3; PIL only
for the contact sheet) and committed as generated data. Code-drawn art is
final (root CLAUDE.md). The contact sheet `docs/art_sheet.png` shows every
frame at 1x and 3x, plus the title screen as composed.

```
tools/gen_art.py            # repaint: cart/src/art/gen/* and docs/art_sheet.png
tools/gen_art.py --check    # exit 1 if cart/src/art/gen/ is stale (the gate)
tools/gen_art.py --table    # print the picture table below
tools/gen_art.py --png DIR  # every frame at 4x, plus the composed title
```

## Files

- `cart/src/art/art.zig`: the draw API (no cart API, host testable).
- `cart/src/art/gen/art_data.zig`: the `Pic` enum, per-picture size, frame
  and palette tables, `layout` rectangles, the `master` palette.
- `cart/src/art/gen/art.bin`: every frame's pixel stream (`@embedFile`).
- `cart/src/art/gen/art_check.zig`: expected decode results for the tests.
- `cart/src/art/tests.zig`: host tests (`zig test
  carts/raspberry-trail/cart/src/art/tests.zig`).

## Format

Each picture has up to 15 colours plus index 0 = transparent, picked from
one master palette, and 1 to 3 frames of the same size. A frame is stored
either run-length encoded or as raw 4-bit pixels, whichever is smaller:

- RLE: bytes `(n << 4) | index`; `n < 15` is a run of `n + 1`, `n == 15`
  a run of `16 + next byte` (16..271). Runs continue across rows.
- Raw: 4 bits per pixel, row-major, low nibble first, no row padding.

Palettes are stored as `DisplayColor` bits (r in bits 0-4, g 5-10, b 11-15),
so the draw loop does no colour work. Nothing is decoded at comptime.

## API (`art.zig`)

```zig
pub const Pic = enum(u8) { title_bg, title_wagon, ... };  // table below
pub const Color = packed struct(u16) { r: u5, g: u6, b: u5 };  // = DisplayColor layout
pub fn size(p: Pic) Size                     // .{ .w, .h }
pub fn frames(p: Pic) u8
pub fn draw(p: Pic, x: i32, y: i32, frame: u32, sink: anytype) void        // clipped to 160x128
pub fn drawClipped(p: Pic, x: i32, y: i32, frame: u32, clip: Rect, sink: anytype) void
pub fn pixel(p: Pic, frame: u32, x: i32, y: i32) ?Color                    // slow, for tests
pub fn color(comptime name: []const u8) Color  // master palette, e.g. color("rasp")
pub fn vignette(tag: anytype) ?Pic            // game Tag -> vignette, by tag name
pub fn vignetteForLine(tag: anytype, text: []const u8) ?Pic  // + DOCTOR'S BILL -> v_doctor
pub fn shootScene(reason: anytype) Pic        // game ShotReason -> shoot_*
pub fn endScene(outcome: anytype) ?Pic        // game Outcome -> arrival / tombstone / null
pub fn button(b: anytype) Pic                 // art.Button (or any enum named up..b) -> btn_*
pub const ButtonState = enum(u8) { normal = 0, highlighted = 1, done = 2 };  // btn_* frame
pub const markers: [4]Marker                  // strip markers with their mileage
pub const layout                              // placement rectangles, below
```

The sink is any value or pointer with `pub fn put(self, x: i32, y: i32, c:
art.Color) void`, and optionally `pub fn span(self, x0: i32, x1: i32, y:
i32, c: art.Color) void` (x1 exclusive) that RLE runs use instead. Every
call is already clipped and transparent pixels never reach it, so a sink is
one store: `cart.framebuffer[x][y] = Pixel.from_color(@bitCast(c))`.
`frame` wraps modulo the picture's frame count, so passing `tick / 15`
animates the 2-frame pictures at 4 fps. A full-screen picture is at most
20,480 sink calls; small pictures skip their transparent runs in bulk.

The lookups take the game's enum values and match on `@tagName`, so the art
module never imports the game module.

## Layout (`art.layout`, generated with the pictures)

| Name | Rect (x, y, w, h) | Meaning |
|---|---|---|
| `title_logo` | 22, 3, 116, 40 | screen position of `title_logo` |
| `title_wagon` | 14, 59, 90, 36 | screen position of `title_wagon` |
| `title_menu` | 34, 100, 92, 28 | clear dark-green band for the 3-row menu (cream text reads well) |
| `shoot_cue` | 4, 1, 152, 20 | quiet sky band of each `shoot_*`, relative to the picture: cue word and button glyphs |
| `tomb_text` | 50, 40, 60, 40 | blank face of the stone, relative to `tombstone`: 10 columns x 5 rows of the 6x8 font |

Title screen: `title_bg` at (0, 0), `title_wagon` (frame = tick / 15 for the
rolling wheels and walking oxen), `title_logo`, then the menu text.

Text colours that read on each picture: menu on `title_bg` paper or
gold_l (raspberry for the cursor); cue text on `shoot_hunt` ink, on
`shoot_riders`, `shoot_bandits`, `shoot_animals` paper; cause on the
tombstone ink or grey_d.

## Pictures

| Pic | Size | Frames | Colours | Bytes | Depicts |
|---|---|---|---|---|---|
| `title_bg` | 160x128 | 1 | 15 | 1843 | Title background: sunset prairie, mountains, trail ruts |
| `title_wagon` | 90x36 | 2 | 10 | 1482 | Title sprite: the wagon and two oxen, wheels and legs in 2 frames |
| `title_logo` | 116x40 | 1 | 7 | 985 | Title words THE RASPBERRY TRAIL, raspberry and cream woodtype |
| `strip_wagon` | 12x9 | 2 | 6 | 115 | Trail strip wagon icon facing right, 2 wheel frames |
| `mark_start` | 7x9 | 1 | 3 | 31 | Trail strip marker: Independence (a signpost) |
| `mark_pass` | 11x9 | 1 | 3 | 46 | Trail strip marker: South Pass (a grassy saddle, no snow) |
| `mark_mountains` | 11x9 | 1 | 3 | 44 | Trail strip marker: Blue Mountains (snowy blue peaks) |
| `mark_fort` | 9x9 | 1 | 3 | 40 | Trail strip marker: a fort (palisade and flag) |
| `mark_city` | 11x9 | 1 | 4 | 60 | Trail strip marker: Oregon City (cabin under a pine) |
| `btn_up` | 14x14 | 3 | 5 | 199 | Shooting cue button UP: frame 0 normal, 1 highlighted, 2 done |
| `btn_down` | 14x14 | 3 | 5 | 199 | Shooting cue button DOWN: frame 0 normal, 1 highlighted, 2 done |
| `btn_left` | 14x14 | 3 | 5 | 199 | Shooting cue button LEFT: frame 0 normal, 1 highlighted, 2 done |
| `btn_right` | 14x14 | 3 | 5 | 199 | Shooting cue button RIGHT: frame 0 normal, 1 highlighted, 2 done |
| `btn_a` | 14x14 | 3 | 5 | 229 | Shooting cue button A: frame 0 normal, 1 highlighted, 2 done |
| `btn_b` | 14x14 | 3 | 5 | 223 | Shooting cue button B: frame 0 normal, 1 highlighted, 2 done |
| `v_wagon_breaks` | 64x40 | 1 | 12 | 452 | Vignette: wagon breakdown, the front wheel off and broken |
| `v_ox_injured` | 64x40 | 1 | 11 | 410 | Vignette: an injured ox lying down, a bandaged leg |
| `v_ox_wanders` | 64x40 | 1 | 11 | 370 | Vignette: an ox wanders off; an empty yoke and a question mark |
| `v_daughter_arm` | 64x40 | 1 | 10 | 708 | Vignette: a broken arm in a white sling (no gore) |
| `v_son_lost` | 64x40 | 2 | 11 | 1060 | Vignette: searching for the lost son at night, lantern and footprints |
| `v_bad_water` | 64x40 | 1 | 12 | 746 | Vignette: a murky pond with bubbles and a warning sign |
| `v_heavy_rain` | 64x40 | 2 | 12 | 1062 | Vignette: heavy rain over the wagon, 2 frames |
| `v_hail` | 64x40 | 2 | 12 | 961 | Vignette: hail stones bouncing around the wagon, 2 frames |
| `v_fire` | 64x40 | 2 | 13 | 1198 | Vignette: fire in the wagon, flames and smoke, 2 frames |
| `v_fog` | 64x40 | 1 | 5 | 883 | Vignette: the wagon fading into fog |
| `v_snake` | 64x40 | 1 | 11 | 516 | Vignette: a coiled rattlesnake, head up |
| `v_river` | 64x40 | 2 | 12 | 911 | Vignette: the wagon swamped in a river crossing, 2 frames |
| `v_wild_animals` | 64x40 | 1 | 7 | 297 | Vignette: wolves on a ridge at dusk, one howling at the moon |
| `v_cold` | 64x40 | 1 | 6 | 508 | Vignette: bitter cold, icicles and a low thermometer |
| `v_blizzard` | 64x40 | 2 | 10 | 811 | Vignette: a blizzard burying the wagon, 2 frames |
| `v_mountains` | 64x40 | 1 | 9 | 541 | Vignette: rugged mountains and a switchback trail |
| `v_fort` | 64x40 | 1 | 12 | 839 | Vignette: a frontier fort, palisade, blockhouse and flag |
| `v_riders` | 64x40 | 1 | 8 | 508 | Vignette: riders ahead, horse-and-rider silhouettes at sunset |
| `v_bandits` | 64x40 | 1 | 8 | 516 | Vignette: masked bandits in the moonlight |
| `v_illness` | 64x40 | 1 | 10 | 449 | Vignette: illness, a medicine bottle and spoon |
| `v_helpful_food` | 64x40 | 1 | 12 | 730 | Vignette: a basket of wild raspberries and berries (no people) |
| `v_hunt_result` | 64x40 | 1 | 8 | 432 | Vignette: the hunt's result, a roast drumstick and the rifle |
| `v_south_pass` | 64x40 | 1 | 10 | 365 | Vignette: South Pass, a wide grassy saddle with no snow |
| `v_doctor` | 64x40 | 1 | 10 | 396 | Vignette: the doctor's bag and a bandage roll |
| `shoot_hunt` | 160x80 | 1 | 13 | 1290 | Shooting scene: hunting, a buffalo and a deer on the prairie |
| `shoot_riders` | 160x80 | 1 | 9 | 1596 | Shooting scene: riders charging out of the sunset |
| `shoot_bandits` | 160x80 | 1 | 12 | 1082 | Shooting scene: bandits behind the rocks at night |
| `shoot_animals` | 160x80 | 1 | 8 | 1056 | Shooting scene: wild animals, wolves at dusk |
| `muzzle_flash` | 18x18 | 2 | 3 | 140 | Shot sprite: muzzle flash, 2 frames |
| `mark_hit` | 17x17 | 1 | 4 | 131 | Shot result: a hit, raspberry starburst |
| `mark_miss` | 18x14 | 1 | 5 | 76 | Shot result: a miss, a puff of dust |
| `tombstone` | 160x96 | 1 | 15 | 1239 | Death: a tombstone on the prairie at dusk; the UI writes the cause on it |
| `arrival` | 160x96 | 1 | 15 | 1437 | Arrival: Oregon City, cabins by the river under Mt Hood |
| total | | | | 29610 | |

Vignettes are 64x40 postcards with a 1 px ink frame and clipped corners,
so they sit on the cream paper as they are. The `shoot_*` scenes are
160x80 with no frame; `tombstone` and `arrival` are 160x96.

## Game mapping (the UI does it; `art.vignette` etc. implement it)

| Game value | Picture |
|---|---|
| `Tag.wagon_breaks` | `v_wagon_breaks` |
| `Tag.ox_injured` | `v_ox_injured` |
| `Tag.daughter_arm` | `v_daughter_arm` |
| `Tag.ox_wanders` | `v_ox_wanders` |
| `Tag.son_lost` | `v_son_lost` |
| `Tag.bad_water` | `v_bad_water` |
| `Tag.heavy_rain` | `v_heavy_rain` |
| `Tag.bandits` | `v_bandits` |
| `Tag.fire` | `v_fire` |
| `Tag.fog` | `v_fog` |
| `Tag.snake` | `v_snake` |
| `Tag.river` | `v_river` |
| `Tag.wild_animals` | `v_wild_animals` |
| `Tag.cold` | `v_cold` |
| `Tag.hail` | `v_hail` |
| `Tag.illness` | `v_illness` |
| `Tag.helpful_food` | `v_helpful_food` (no people depicted) |
| `Tag.riders` | `v_riders` |
| `Tag.hunt_result` | `v_hunt_result` |
| `Tag.fort` | `v_fort` |
| `Tag.mountains` | `v_mountains` |
| `Tag.blizzard` | `v_blizzard` |
| `Tag.south_pass` | `v_south_pass` |
| `Tag.warning` "DOCTOR'S BILL IS $20" | `v_doctor` (`vignetteForLine`) |
| other tags (`plain`, `death`, `funeral`, `arrival`, `letter`, `bell`, ...) | none |
| `ShotReason.hunt` / `.riders` / `.bandits` / `.animals` | `shoot_hunt` / `shoot_riders` / `shoot_bandits` / `shoot_animals` |
| `Outcome.arrived` | `arrival` |
| every death `Outcome` | `tombstone` (the UI writes the cause in `tomb_text`) |
| shot fired / hit / miss | `muzzle_flash` (2 frames), `mark_hit`, `mark_miss` |
| strip: INDEPENDENCE 0, SOUTH PASS 950, BLUE MTNS 1700, OREGON CITY 2040 | `mark_start`, `mark_pass`, `mark_mountains`, `mark_city` (`art.markers`); `mark_fort` spare for a fort stop |
| strip wagon at `hud.mileage_true` | `strip_wagon` (2 wheel frames while it slides) |

`v_doctor` also suits the `no_doctor_money` death before the tombstone.

## Palette

The master palette (names for `art.color`): `ink` #1A1410, `brown_d`
#3B2A20, `brown` #6B4A2F, `wood` #A0703F, `wood_l` #C9A06A, `paper`
#F4E9D0, `paper_d` #E2D2AE, `white` #FFFDF5, `grey_d` #4E4A44, `grey`
#8A8478, `grey_l` #BDB6A6, `rasp` #E30B5C, `rasp_d` #9E0842, `rasp_l`
#F2558C, `rasp_p` #F8A5C2, `leaf` #4C9A2A, `leaf_d` #2E6B1E, `leaf_l`
#8CC152, `pine` #1E4A2A, `gold` #C8B45A, `gold_l` #E6D482, `sun_o`
#F29A3A, `sun_y` #F7D46B, `sun_p` #E86A7A, `dusk_p` #6A4A7A, `dusk_v`
#3E2E5A, `night` #22284A, `sky` #8EC5E8, `sky_l` #CFE6F2, `water`
#3D7FB5, `water_d` #24527A, `mtn` #7A6A9A, `mtn_l` #A890B0, `fire_y`
#FFE070, `fire_o` #F28A1E, `fire_r` #D23A1A, `skin` #E0A878, `murk`
#6B7A3A, `murk_d` #4A522A, `ice` #DDEFF7, `ice_b` #A8D0E6, `storm`
#5A6478, `storm_l` #8A94A6.

## Changing a picture

Edit its painter in `tools/gen_art.py` (one `@pic` function each; shared
pieces: `covered_wagon`, `small_wagon`, `ox`, `galloper`, `buffalo`, the
`WOLF` sprites), run the script, look at `docs/art_sheet.png`, run the
tests, and commit the script, `cart/src/art/gen/` and the sheet together.
A picture over 15 colours stops the script with its colour list.
