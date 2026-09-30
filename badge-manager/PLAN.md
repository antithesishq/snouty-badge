# badge-manager: a headless badge station for the expo table

Status: plan, 2026-09-29. Nothing built yet. Idea from Adrian's coworker:
"plug in badge, ask Claude to write you a game or whatever, have the thing
show up; also have a collection of carts ready to go". Adrian's priorities:
(1) deploy the existing carts with as little effort as possible, driven
from a phone; (2) build a cart on the fly with a CLI agent.

## 1. What the badge gives us (checked in `sycl-badge/src/os`, 2026-09-29)

- The badge is a USB mass-storage device and nothing else. Descriptors:
  VID:PID `0x04D2:0x04D2` (both literally `1234`), product string
  `SYCL Badge V2`, SCSI vendor/product `SYCL` / `BadgeCarts`, FAT12 volume
  label `SYCLBADGE`. No USB serial: the `SYCL>` console is on UART pins,
  so the station cannot tell the badge to run a cart. Copying files is the
  only channel.
- The drive is the OS `romfs`: 1280 KB FAT12, 512-byte clusters, **32 root
  directory entries**, long file names supported. Every file costs
  1 + ceil(len/13) entries (`snouty-bugs.uf2` = 3, `Sonic The Hedgehog
  (World).gg` = 4, `SONIC.GG` = 1), and the volume label takes one.
- The OS menu lists every file on the drive and re-scans it every 0.5 s
  while the menu is showing, so a file copied in appears without a reboot.
  Non-UF2 files (ROMs) show in the menu too and fail if picked (cosmetic).
- A UF2 costs twice its payload (256 B per 512 B block). Today's RAM
  builds: snouty 308 KB, snouty-bugs 151 KB, snoutenstein 376 KB,
  snouty-maze 300 KB, snouty-reflections 196 KB, snouty-boy 270 KB,
  snouty-gear 349 KB. Sum 1.95 MB, so **not every cart fits at once**;
  the station has to deal in sets. XIP builds are smaller but untested on
  hardware ([[badge-xip-cart-path]]); snouty-genesis is XIP-only.
- Emulator carts read ROMs by pointer from the drive (`docs/ROM_DRIVE.md`).
  A host writing while a cart reads can corrupt it, and a file copied onto
  a wiped volume is contiguous (the fast path). Both argue for the same
  rule: **every deploy wipes the drive and copies a whole set, then ejects**.
  The user plugs the badge in while it is on the menu, not inside a cart.

## 2. Shape

One Raspberry Pi (4 or 5; 8 GB if it is to run Zig itself, section 6) on
the table, USB-C cable dangling, no screen or keyboard. Adrian's phone
opens `http://snouty.local` and sees:

```
[ Badge: connected, 1.25 MB free, on it: snouty, snouty-bugs ]

Sets                                Library
 (*) Demo reel      1132 KB, 12/31   [ ] snouty            308 KB
 ( ) Game Gear Sonic 860 KB, 8/31    [ ] snouty-bugs       151 KB
 ( ) Game Boy        ...              [ ] snouty-gear + SONIC.GG
 ( ) Genesis (XIP)   ...              ...
                                     [ Upload a ROM from this phone ]
[ Deploy "Demo reel" ]   [ Wipe ]

log: wiped . copied snouty.uf2 . copied snouty-bugs.uf2 . ejected.
     Unplug the badge.
```

Pieces:

- `station.py`: one Python 3 process (stdlib `http.server` + a JSON API,
  no framework; the phone page is a single HTML file with fetch calls).
  Runs as a systemd service. Polls `/dev/disk/by-label/SYCLBADGE` (or a
  udev rule on VID:PID for instant detection); mounts it itself with
  `-o sync,flush,uid=`; unmounts and powers the port off with
  `udisksctl power-off` (or `eject`) after every write. The badge state,
  library and job log are served as JSON; the page polls once a second.
- `library/`: the station's collection. `library/carts/<name>.uf2`,
  `library/roms/*.gg|.gb|.gbc|.md`, and `library/manifest.toml` naming
  each cart (display name, mode ram/xip, which ROM extensions it reads)
  and each set (list of carts + ROMs). Filled by `sync.sh`, which rsyncs
  `zig-out/firmware/*.uf2` from the exe.dev VM (or from a laptop) and
  runs `tools/uf2_info.py` on each file as a gate. ROMs also arrive by
  phone upload (the page has a file input; iOS Files works).
- Fit check before any deploy: bytes against the volume's free space
  and root entries against 31, both computed from the manifest, shown in
  the set list and refused when over. ROMs are copied under short 8.3
  names (`SONIC.GG`) to save entries; UF2s keep their names because the
  badge menu shows them.
- Deploy = wipe (delete every file), copy UF2s then ROMs, `sync`,
  unmount, eject. Deterministic drive state, contiguous files, ~2 s.
- Network: the Pi joins Adrian's phone hotspot (SSID in a config file),
  advertises `snouty.local` via avahi, and falls back to running its own
  access point `snouty-badge` if the hotspot is absent. Hotspot first
  because that is what gives the CLI agent internet (section 6).

## 3. Testing without a badge

Hardware arrives on show day ([[hardware-gate-deferred]]), so the station
must be proven before then on two stand-ins:

- `--fake-badge IMG`: a 1280 KB FAT12 image made by `tools/make_romfs.py`
  with the badge's geometry, loop-mounted (or written through the
  station's own FAT code in tests). Exercises wipe/copy/fit/eject logic
  and the web UI on the VM and in CI.
- Any USB stick formatted FAT12 with label `SYCLBADGE` on the real Pi
  (`mkfs.vfat -F 12 -n SYCLBADGE -s 1 -r 32 -S 512` on a 1280 KB
  partition reproduces the badge's limits exactly). Detection matches on
  label or VID:PID, so the stick takes the badge's place end to end.

Show-day check: plug the real badge in on the menu, deploy the demo set,
watch the menu re-scan, run a cart, come back, deploy the Sonic set.

## 4. Milestones

- **M0 station**: `station.py` with detection, mount, wipe/deploy/eject,
  JSON API, phone page, systemd unit, `setup.sh` for a fresh Raspberry
  Pi OS Lite (packages, avahi, hotspot config, service). Fake-badge test
  on the VM. Deliverable: deploy a set to a FAT12 USB stick from a phone.
- **M1 library**: manifest, sets, fit check with root-entry accounting,
  `sync.sh` from the VM, ROM upload from the phone, per-cart RAM/XIP
  toggle, "what is on the badge now" view (read the root directory).
- **M2 build on the fly**: section 6.
- **M3 table polish**: badge LED/menu hints in the UI text, one-tap
  "same set again", deploy history, optional read-only kiosk page on a
  spare tablet. Only if there is time.

## 5. Decisions taken in this plan

- Python stdlib over a web framework: the Pi image stays a `git clone`
  plus `apt install python3 avahi-daemon udisks2`; tools/ is already Python.
- Wipe-and-copy sets rather than adding/removing single files: matches
  the contiguity and root-entry constraints, and a phone tap should never
  leave the badge half-updated.
- Library lives on the Pi, not fetched at the show: expo internet is not
  a dependency for feature 1. `sync.sh` runs the night before.
- No badge-side changes. Everything here works with the stock OS.

## 6. M2: build a cart on the fly

The phone page gets a prompt box ("a Snouty cart where ..."). The station
starts a job: `claude -p` in a checkout of this repository with a skill
(`.claude/skills/new-cart`) that copies a template cart, edits it to the
prompt, runs `zig build -Dcart=<name>`, `tools/preview.mjs` for a GIF the
phone can see, `badge-bench` for the ms figure, and drops the UF2 into
the library with a manifest entry. Job output streams to the phone (the
page tails the log); when it ends there is a "Deploy" button next to the
new cart. Expect 3-10 minutes per job.

Where the build runs:
- On the Pi: needs the pinned Zig nightly for aarch64 Linux (exists), Node
  20, Python venv for badge-bench, `claude` CLI logged in. A Pi 5 8 GB
  compiles a small cart in a couple of minutes; the comptime-heavy carts
  may OOM the way Adrian's Mac does ([[mac-zig-comptime-oom]]), so the
  template cart must stay light.
- Remote fallback: `BUILD_HOST=exedev@animated-badge.exe.xyz` makes the
  job run over ssh on the VM and scp the UF2 back. Needs internet either
  way (the agent does), which is why the Pi joins the phone hotspot.

Guardrails: one job at a time, a wall-clock limit, jobs run under a
separate user with the library as the only writable path, and the phone
page shows the diff summary and the preview GIF before anything is
deployed.

## 7. Open questions for Adrian

1. Which Pi and how much RAM? Decides whether M2 builds locally.
2. Hotspot from the phone (agent gets internet) or the Pi as its own AP
   (works with no phone data)? Plan assumes hotspot first, AP fallback.
3. Which sets for show day? A first guess: Demo reel (snouty, bugs,
   snoutenstein, maze = 1135 KB), Game Gear (gear + SONIC.GG + bugs),
   Game Boy (boy + two .gb), Genesis XIP (genesis-xip + a .md).
4. Should ROM uploads from strangers' phones be allowed, or only from a
   logged-in page? Plan assumes the page has no auth on a private hotspot.
