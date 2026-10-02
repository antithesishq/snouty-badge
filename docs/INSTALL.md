# Putting a cart on a badge

The one install recipe for every cart in this repository. Each cart's
`docs/RUNNING.md` links here and adds only what is specific to it (its
file name, an XIP variant, ROM files). The facts below come from the SDK's
own documentation (`sycl-badge/README.md`, the
[SYCL Badge V2 user manual](https://zigembeddedgroup.github.io/sycl-badge/),
source in `sycl-badge/manual/content/index.smd`) and from the badge OS
source (`sycl-badge/src/os/kernel.zig`, `src/os/loader/`). Lines marked
**to verify on the badge at show day** are read from the source but have
not been watched on a badge.

What has run on hardware: on 2026-09-29 a coworker built every cart that
existed at `main` `b9abad4` (Snouty Run, Bugs, Snoutenstein, Reflections,
Boy, Maze, Gear, Genesis) and launched each on a badge. That was a basic
boot check, not a play test, and later commits are unchecked. No XIP
build (`<binary>-xip.uf2`) is confirmed to have run on a badge. The root
`README.md` matrix has the per-cart status.

## 1. Get the UF2

Build from the repository root (`zig build` builds every cart, see
[RUNNING.md](RUNNING.md)) or take a prebuilt file from whoever built it.
The badge file is `zig-out/firmware/<binary>.uf2`:

| Cart | File to copy | Notes |
|---|---|---|
| snouty-run | `snouty.uf2` | |
| snouty-bugs | `snouty-bugs.uf2` | |
| snoutenstein | `snoutenstein.uf2` | |
| snouty-reflections | `snouty-reflections.uf2` | |
| snouty-boy | `snouty-boy.uf2` | `snouty-boy-xip.uf2` (with `-Dcart-mode=xip`) only for an embedded ROM over about 64 KB; ROMs: [Boy section 9](../carts/snouty-boy/docs/RUNNING.md#9-roms-from-the-badge-drive) |
| snouty-maze | `snouty-maze.uf2` | |
| snouty-gear | `snouty-gear.uf2` | ROMs: [Gear section 6](../carts/snouty-gear/docs/RUNNING.md#6-a-rom-on-the-badge-drive) |
| snouty-genesis | `snouty-genesis-xip.uf2` | XIP only, there is no RAM build; ROMs: [Genesis section 8](../carts/snouty-genesis/docs/RUNNING.md#8-a-rom-on-the-badge-drive) |
| snouty-lynx | `snouty-lynx.uf2` | the default build also writes `snouty-lynx-xip.uf2` (longer rewind history, never run on a badge); ROMs: [Lynx README](../carts/snouty-lynx/README.md#a-rom-on-the-badge-drive) |
| snouty-flyover | `snouty-flyover.uf2` | |
| demosnout | `demosnout.uf2` | |
| snouty-zero | `snouty-zero-xip.uf2` | XIP only, there is no RAM build |
| badge-calibrate | `badge-calibrate.uf2` | a measuring tool, not a game ([its README](../badge-bench/calibrate/README.md)) |

A plain `zig build` writes all of these, the XIP-only ones included.
`<binary>-xip.uf2` is an execute-in-place cart (code in the 256 KB cart
flash window, root `README.md`); it is installed exactly like a RAM cart.
`python3 tools/uf2_info.py FILE.uf2` prints which window a UF2 targets.

## 2. Copy it onto the badge's own drive

1. Connect the badge to the computer over USB-C and switch it on. The
   badge shows its menu, "Available Carts:", and the computer mounts a
   mass-storage drive named **`SYCLBADGE`** (the OS's 1280 KB cart drive
   in the badge's internal flash).
2. Copy the UF2 into the top directory of `SYCLBADGE`. Keep its name
   (`snouty-bugs.uf2`); the menu lists every file in the top directory by
   name, without `.uf2`. Several carts can sit side by side, each under
   its own name, as long as they fit: the carts' UF2s are 150 to 530 KB
   (a 2026-10-02 build: Bugs 147 KB, Demosnout 518 KB), so two to four
   carts fill the 1280 KB drive, less with ROM files on it. Delete old
   ones from the drive to make room.
3. Replacing `CURRENT.UF2`, as the SDK README says ("copy a `.uf2` ...
   onto the badge drive, replacing `CURRENT.UF2`. The new program starts
   immediately"), is the other way to do it: drop your file over that
   name. **To verify on the badge at show day:** the current OS source
   does not start a cart by itself (the single-cart auto-start in
   `kernel.zig` is commented out), so expect to pick `CURRENT` from the
   menu like any other cart; and how long the copy and the first launch
   take.
4. For an emulator cart, copy the ROM files next to the UF2 now (the
   cart's ROM section, linked in the table above).
5. **Eject the drive** in the computer's file manager (or `umount`) and
   wait for the copy to finish before playing. The OS writes the flash
   while a host still has the drive mounted, and the emulator carts read
   their ROM straight from that flash ([ROM_DRIVE.md](ROM_DRIVE.md)
   section 2).

## 3. Launch, play, exit

- On the badge menu, Up/Down move the cursor and **A** starts the cart.
  The OS shows "Loading Cart ... Please wait..." while it reads the UF2
  and programs it; every launch does this. An error ("Invalid UF2",
  "Wrong address", "UF2 too large", ...) shows for two seconds and the
  menu comes back.
- The menu also lists ROM files and anything else on the drive; picking
  one of those fails with an error. That is cosmetic.
- **Start + Select held together for half a second** stops the cart and
  returns to the menu (the OS owns this chord).
- A joystick click toggles the OS FPS overlay (fps, and for XIP carts the
  flash cache hit rate) in the menu and in every cart.
- Carts boot silent; each has its own sound toggle ([SOUND.md](SOUND.md)).

## 4. The wrong drive: the RP2350 bootloader

Holding **RESET** and **BOOT_SEL** on the back of the badge, releasing
RESET first, starts the chip's ROM bootloader instead of the badge OS.
The computer then mounts a drive named **`RP2350`** (Linux may need it
mounted by hand), not `SYCLBADGE`; an RP2350 boot drive normally holds
just `INDEX.HTM` and `INFO_UF2.TXT`, and the badge screen does not show
the cart menu. That drive is only for flashing the badge OS itself
(`sycl-os-kernel.uf2`, built in `sycl-badge/`; user manual, "Flashing the
Operating System"). Badges come with the OS installed, so a cart user
never needs it.

A cart UF2 dropped there does not become a cart: the drive vanishes, the
badge resets, and the cart is not in the menu, because the menu lists
only files on `SYCLBADGE`. Neither kind of cart UF2 targets the OS's
part of the flash (RAM carts target cart RAM at `0x20035100`, XIP carts
the cart flash window at `0x101C0000`; the OS lives at `0x10000000`), so
the OS survives: switch the badge off and on, wait for "Available
Carts:", and copy the file onto `SYCLBADGE` instead. Exactly what the boot
ROM does with a cart UF2 has not been tried (to verify on the badge at
show day). If the menu never appears after a power cycle, the OS itself
needs reflashing as above.

The debug probe route in the user manual is for the OS too; the manual
says it does not work for carts.
