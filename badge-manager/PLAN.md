# badge-manager: a headless badge station for the expo table

Status: plan, 2026-09-29, revised 2026-09-30 with Adrian's answers
(section 7). M0 built 2026-09-30 (tag `badge-manager/m0`): the package,
`badge` CLI, server and phone page, systemd units, network scripts,
`setup.sh`, `sync.sh`, 48 unit tests and `tests/e2e_loop.sh`. The real
block-device mount/eject path and `setup.sh` have not run anywhere yet
(this VM's kernel has no vfat); first run is on a Pi with a FAT12 stick
(section 3). M1 built 2026-09-30 (tag `badge-manager/m1`, section 8):
cart variants with a RAM/XIP toggle, ad-hoc selections and sets saved
from the phone, ROM globs in sets, default show-day sets, the badge
contents identified by set, nightly sync timer, QR share codes, iOS and
Android both supported; 89 unit tests. M2 (build on the fly) next. Idea
from Adrian's coworker:
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

Any 64-bit Raspberry Pi (Zero 2 W, 3, 4, 5) running Raspberry Pi OS
Lite 64-bit, on the table with a USB-C cable dangling, no screen or
keyboard. The station itself needs nothing beyond Python 3; only building
carts locally needs a big Pi (section 6). Adrian's phone
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
- Interfaces, no phone app ever: a browser page and an ssh command line,
  both driving the same Python module.
  - Browser: `http://snouty.local` (mDNS via avahi; iOS Safari resolves
    it, Android Chrome often does not). Every mode therefore also has a
    fixed address, `http://10.42.0.1`, which is what the Pi's own access
    point hands out, and a QR sticker on the Pi points at it. In access
    point mode the Pi's dnsmasq answers every name with itself, so a phone
    joining the network gets the "sign in to network" pop-up and the page
    opens without typing anything. On a phone hotspot the Pi's address
    shows in the hotspot's client list; the page also prints it so it can
    be bookmarked once.
  - ssh: `ssh badge@snouty.local` and the `badge` command (`status`,
    `sets`, `deploy <set>`, `wipe`, `sync`, `build "<prompt>"`, `log`).
    Same functions the page calls, so anything works from a laptop or a
    phone ssh client with no page at all. Also the debug path.
- Network: NetworkManager (stock on Raspberry Pi OS) with two profiles.
  A client profile for Adrian's phone hotspot (SSID/password in
  `station.toml`, several allowed) at high autoconnect priority, and an
  access point profile `snouty-badge` (WPA2, shared IPv4, `10.42.0.1`).
  A small watchdog brings the access point up when no hotspot has
  connected 45 s after boot, and retries the hotspot every five minutes
  while nobody is attached to the access point. Pi Zero 2 W / 3 / 4 / 5
  each have one radio, so it is one or the other, never both; ethernet,
  if plugged in, is used for internet in either mode. Hotspot mode is
  what gives the build agent (section 6) internet; in access point mode
  without ethernet the page says builds are offline and everything else
  still works.

## 3. Testing without a badge

Hardware arrives on show day ([[hardware-gate-deferred]]), so the station
must be proven before then on two stand-ins:

- `--fake-badge IMG`: a 1280 KB FAT12 image made by `tools/make_romfs.py`
  with the badge's geometry, loop-mounted (or written through the
  station's own FAT code in tests). Exercises wipe/copy/fit/eject logic
  and the web UI on the VM and in CI.
- Use `--fake-badge` with a FAT12 image or directory for Pi tests without
  the real badge. Production detection requires the badge's USB VID:PID,
  label, and geometry; a label-only USB stick is deliberately ignored.

Show-day check: plug the real badge in on the menu, deploy the demo set,
watch the menu re-scan, run a cart, come back, deploy the Sonic set.

## 4. Milestones

- **M0 station**: the `badge_manager` Python package: detection, mount,
  wipe/deploy/eject, the `badge` CLI, JSON API and phone page, systemd
  unit, `setup.sh` for a fresh Raspberry Pi OS Lite 64-bit (packages,
  avahi, the two NetworkManager profiles and the watchdog, the `badge`
  user for ssh, service). Fake-badge test on the VM. Deliverable: deploy
  a set to the real badge (or an explicit fake image during development)
  from a phone browser and from ssh, on a Pi
  that found the hotspot and on one that had to make its own network.
- **M1 library**: manifest, sets, fit check with root-entry accounting,
  `sync.sh` from the VM, ROM upload from the phone, per-cart RAM/XIP
  toggle, "what is on the badge now" view (read the root directory).
  Much of this landed with M0; what M1 adds is in section 8.
- **M2 build on the fly**: section 6, remote path first (works on every
  Pi), local path second. Built 2026-09-30 to the section 9 contract
  (tag `badge-manager/m2`); the ssh path still waits for a Pi.
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
- Any Pi is supported (Adrian, 2026-09-30): the station does no work a
  Pi Zero 2 W cannot do; builds probe the machine and fall back to a
  cloud VM. Networking is hotspot first, own access point otherwise.
  Interfaces are a browser page and ssh, never an app (Adrian,
  2026-09-30).

## 6. M2: build a cart on the fly

The phone page gets a prompt box ("a Snouty cart where ..."). The station
starts a job: `claude -p` in a checkout of this repository with a skill
(`.claude/skills/new-cart`) that copies a template cart, edits it to the
prompt, runs `zig build -Dcart=<name>`, `tools/preview.mjs` for a GIF the
phone can see, `badge-bench` for the ms figure, and drops the UF2 into
the library with a manifest entry. Job output streams to the phone (the
page tails the log); when it ends there is a "Deploy" button next to the
new cart. Expect 3-10 minutes per job.

Where the build runs, decided by a probe at job start, shown on the page:
- Local, when the Pi has >= 6 GB RAM (`MemTotal`), the pinned Zig nightly
  for aarch64 Linux at `~/.local/zig`, Node 20 and a badge-bench venv
  (`setup.sh --build-tools` installs them on a Pi 5 8 GB; a Pi 4 8 GB
  qualifies too, slower). A small template cart compiles in a couple of
  minutes there; the comptime-heavy carts may OOM the way Adrian's Mac
  does ([[mac-zig-comptime-oom]]), so the template stays light.
- Cloud VM otherwise, or whenever the local probe fails or the local
  build errors with OutOfMemory: the job runs the same script over ssh on
  `build_host` from `station.toml` (default the exe.dev VM,
  `exedev@animated-badge.exe.xyz`, repo at `/home/exedev/snouty-badge`),
  streams its log back, and scps the UF2, GIF and bench line into the
  library. The ssh key lives on the Pi; `badge build --remote` forces it.
  Both paths run the same `badge-manager/build-job.sh`, so the Pi is only
  ever a thin client for anything Zig-sized.
- `claude` itself runs wherever the build runs (it needs the checkout),
  logged in ahead of time on each; the job carries the prompt over ssh.
Internet is needed for either path (the agent talks to the API), hence
hotspot first in section 2.

Guardrails: one job at a time, a wall-clock limit, local jobs run under the
unprivileged `badge` account (which owns its checkout and each job's output
directory while the service owns the library), and the phone
page shows the diff summary and the preview GIF before anything is
deployed.

## 7. Questions and answers

Answered by Adrian 2026-09-30:
1. Which Pi? Any we reasonably can; fall back to a cloud VM when the Pi
   lacks the resources for Zig. (Section 6 probe + `build_host`.)
2. Hotspot or access point? Phone hotspot when available, broadcast our
   own network otherwise. (Section 2.)
3. Phone side: no special app, must work from a normal browser window or
   ssh. (Section 2 interfaces; the `badge` CLI is first-class, not a
   debug aid.)

Answered by Adrian 2026-09-30 (second round):
5. ROM upload: no passphrase. Anyone on the station's network can upload.
6. Adrian's phone is iOS, and the station must work from Android too; the
   phone OS is not allowed to be a limitation. Consequences in section 8.

Still open:
4. Which sets for show day? Section 8 ships a first guess as the default
   manifest (Demo reel, Game Gear, Game Boy, Genesis XIP); the phone page
   can now save new sets, so this no longer needs a decision up front.

## 8. M1: what the phone can do with the library

Design 2026-09-30, on top of M0. Everything below is stdlib Python plus
the one HTML page; the `badge` CLI gains the same verbs.

### 8.1 Cart variants and the RAM/XIP toggle

`zig-out/firmware` holds every cart twice: `snouty.uf2` (RAM) and
`snouty-xip.uf2` (XIP). `sync.sh` copies both. M0 listed them as two
carts; M1 folds them into one cart *family* keyed by the stem without
`-xip`, with up to two variants:

- `carts/<key>.uf2` is the `ram` variant, `carts/<key>-xip.uf2` the `xip`
  variant. A manifest entry may name them explicitly (`file`, `xip_file`).
  `snouty-genesis-xip.uf2` alone gives family `snouty-genesis` with only an
  XIP variant.
- `[carts.<key>] use = "ram" | "xip"` picks the variant that sets deploy
  (default `ram`, or the only variant that exists). The page shows a
  RAM/XIP toggle on every cart with two variants; the CLI has `badge mode
  <cart> ram|xip` and `badge mode --all ram|xip`. The choice is per cart
  and persists in the manifest; fit numbers for every set follow it.
- The drive name is the variant's file name (`snouty-xip.uf2`), because
  that is what the badge menu shows; the fit check accounts for it.

### 8.2 Sets: patterns, ad-hoc selections, saving from the phone

- A set's `roms` list may hold glob patterns (`"*.gg"`, `"Sonic*"`)
  matched case-insensitively against ROM file names in the library, so
  "Game Gear = gear cart + every .gg ROM" stays true as ROMs are uploaded.
- The Library section of the page gets a checkbox per cart and per ROM,
  a live fit line (`3 carts, 1 ROM: 812 KB of 1,260 KB, 9 of 31 entries`,
  computed by `POST /api/fit`), a **Deploy selection** button and a
  **Save as set** button (asks for a title; key = slug of the title).
  `POST /api/sets` creates or replaces a set, `DELETE /api/sets/<key>`
  removes one, and `POST /api/deploy` accepts `{"carts": [...], "roms":
  [...]}` as well as `{"set": key}`. CLI: `badge deploy --carts a,b --roms
  x`, `badge set save KEY --title T --carts ... --roms ...`, `badge set
  rm KEY`.
- Each set row on the page can be expanded to list the drive names it
  would write and the reasons it does not fit.
- `badge-manager/sets.default.toml` holds the first-guess show-day sets
  and titles for the known carts. `setup.sh` installs it as the manifest
  when none exists; `badge init-sets` adds any default set or cart title
  that is missing from an existing manifest, never overwriting.

### 8.3 What is on the badge

`badge.files` entries gain `title` and `kind` (`cart`, `rom`, `other`) by
matching drive names against the library, and `badge.set` names the set
whose plan equals the files on the drive (case-insensitive), else null.
The page says "On it: Demo reel" when it can, and lists titles instead of
bare file names. The CLI's `badge status` does the same.

### 8.4 Nightly sync

`systemd/badge-sync.timer` runs `badge sync` at 03:00 local (persistent,
with a randomised 10 min delay) so the library follows main without
anyone touching the Pi. It needs internet and the ssh key from the README;
a failed sync is one log line and nothing else changes. `setup.sh`
installs and enables the timer.

### 8.5 iOS and Android

Both phone OSes are first-class. What changes:

- **Reaching the page.** iOS Safari resolves `snouty.local`; Android does
  natively from Android 12 on, older Android does not. The fixed address
  `http://10.42.0.1/` and the captive pop-up on the station's own network
  work on both (the server already answers Apple's and Android's
  connectivity probes with a redirect). On a phone hotspot the Pi's
  address is only discoverable from the hotspot's client list, so the
  page carries a **Share** section with two QR codes: one for the page's
  URL and one Wi-Fi QR (`WIFI:T:WPA;S:snouty-badge;P:...;;`) for the
  station's own network, shown only in access point mode. Both camera
  apps read both. A second phone joins by scanning the first one's
  screen; `badge qr` prints the same codes in the terminal for a sticker.
  QR codes come from the `qrencode` package (apt), served as SVG by
  `GET /qr/page.svg` and `GET /qr/wifi.svg`; without `qrencode` the Share
  section is hidden and nothing else changes.
- **Uploading a ROM.** Android's file picker filters by MIME type and
  hides files whose extensions it does not know (`.gg`, `.gbc`, `.md`),
  so the `accept` attribute is dropped; the server keeps validating the
  extension and the page keeps the 4 MB check.
- Touch targets stay 44 px, the page uses no hover-only affordances,
  and the long-poll keeps working when Android Chrome throttles a
  background tab (it re-syncs on the next poll).

### 8.6 Status contract additions

See `badge_manager/__init__.py`: `badge.files[].title/kind`, `badge.set`,
`library.carts[].use/variants`, `sets[].files`, and `share`.

### 8.7 Tracks

- Track A (library, station, CLI, default manifest, unit tests):
  `library.py`, `station.py`, `cli.py`, `sets.default.toml`,
  `tests/test_library.py`, `tests/test_station.py`, `tests/test_cli.py`.
- Track B (server, page, QR, systemd, setup, README, server tests):
  `server.py`, `www/index.html`, `systemd/badge-sync.*`, `setup.sh`,
  `README.md`, `tests/test_server.py`.
- Then integration: full test run, `--fake-badge` directory walk-through
  of every new page action, tag `badge-manager/m1`.

## 9. M2: build a cart on the fly (design, 2026-09-30)

Section 6 is the sketch; this is the contract the M2 tracks build to.
Remote path first: a Pi Zero 2 W drives a build on the exe.dev VM over
ssh. The local path (a Pi 5 with `setup.sh --build-tools`) runs the very
same script on the Pi itself. Nothing in the badge OS changes.

### 9.1 Facts checked on the VM

- `claude` 2.1.x is installed and logged in on the VM (`claude -p`
  answers); `--print` mode takes `--allowedTools`, `--permission-mode`,
  `--max-turns`, `--max-budget-usd`, `--output-format stream-json`
  `--verbose`, `--append-system-prompt-file`.
- The VM's sshd is exe.dev's: keys are registered on the *account*
  (`ssh exe.dev ssh-key add '<pubkey>'`), there is no `authorized_keys`.
  The Pi's `badge` user therefore needs its key registered once by Adrian
  (`setup.sh` prints the public key and the command). VMs cannot reach
  each other; a Pi on a phone hotspot can reach `animated-badge.exe.xyz`.
- A `git worktree add` of the repo does not populate the `sycl-badge`
  submodule; the job must `git submodule update --init --reference
  <repo>/.git/modules/sycl-badge`. Zig caches: `.zig-cache/` and
  `zig-pkg/` are per checkout (1.5 GB and 534 MB in the main checkout);
  the job passes `--cache-dir <repo>/.zig-cache` so a fresh worktree does
  not rebuild the SDK. Timings measured in 9.9.
- The VM has 2 vCPUs and 7 GB RAM; a small cart builds in seconds once
  the cache is warm. Expect the agent, not Zig, to dominate a job.

### 9.2 Job model (on disk, shared by server and CLI)

A job lives in `<library>/builds/<id>/` with `id = YYYYMMDD-HHMMSS-<slug>`
(`slug` = the cart name without its `snouty-` prefix):

```
builds/<id>/job.json     {id, prompt, name, title, where: "local"|"remote", host,
                          state: "queued"|"running"|"done"|"failed"|"cancelled",
                          started, finished, seconds, exit, error,
                          result: {cart, uf2, size, preview, bench_ms, branch} | null}
builds/<id>/job.log      one line per event, appended while the job runs
builds/<id>/out/         what build-job.sh produced: <name>.uf2, preview.gif,
                         bench.txt, summary.json, cart.tar.gz
builds/.lock             flock: one job at a time, whoever runs it
```

`badge_manager/build.py` owns this: `Jobs(root)` with `start(prompt,
where, name=None) -> Job` (runs the command in the calling thread; the
server wraps it in a thread, the CLI runs it in the foreground and prints
the log), `current()`, `get(id)`, `list(n)`, `cancel()`, `tail(id, n)`.
The runner streams the command's stdout into `job.log` line by line
(each line also bumps the station's change counter so the page's long
poll wakes), enforces `build_max_minutes` (default 20) by killing the
process group, and on exit 0 reads `out/summary.json`, checks the UF2
with `tools/uf2_info.py`, copies it into `<library>/carts/<name>.uf2` and
registers it (`Library.add_uf2(key=name, title=summary.title,
build=id)`), so the new cart appears in the library with its GIF.
Manifest cart entries gain an optional `build = "<id>"`; the cart JSON
gains `"preview": "/builds/<id>/preview.gif" | null` and `"build": id |
null`.

The build lock is separate from the deploy lock: a deploy or wipe can run
while a build is in flight; only the final registration takes the
station's state lock for a moment. `busy`/`action` keep their meaning.

The command the runner starts, in order of precedence:

1. `build_command` from `station.toml` (tests point it at
   `tests/fake_build_job.sh`), a template with `{id}`, `{out}`,
   `{prompt_file}`, `{name}`, `{flags}`.
2. `where == "local"`: `bash <build_local_repo>/badge-manager/build-job.sh --id
   ID --out <library>/builds/ID/out --prompt-file <library>/builds/ID/prompt.txt
   [--name NAME] [--no-agent]`.
3. `where == "remote"`: `ssh -o BatchMode=yes -o ConnectTimeout=15 HOST
   bash <build_repo>/badge-manager/build-job.sh --id ID --out
   <build_repo>/build-jobs/ID/out --prompt-file - ... < prompt.txt`, then
   `ssh HOST tar -C <build_repo>/build-jobs/ID -cf - out | tar -x -C
   <library>/builds/ID`. Cleanup follows a successful transfer, UF2 gate,
   and registration. A failed fetch keeps the package for `badge build
   --retry-fetch ID`; completed remote job directories expire after seven
   days on the next build.
   Cancel runs `ssh HOST bash .../build-job.sh --cancel ID` and kills the
   local ssh.

`where == "auto"` picks local when the local probe passes (section 6:
RAM, Zig, and `build_local_repo` present on this machine), else remote
when `build_host` is set. `build.ready` in the status is false, with a
`why`, when neither applies or `network.internet` is false.

### 9.3 build-job.sh (runs at the repo, on whichever host builds)

```
build-job.sh --id ID --out DIR --prompt-file FILE|- [--name snouty-x]
             [--no-agent] [--max-turns 40] [--max-usd 5] [--minutes 15]
build-job.sh --cancel ID
build-job.sh --self-test          # template only, into a temp dir
```

Steps, each logged as `step: ...` with its seconds, so the phone sees
progress:

1. `git fetch origin main` (offline: fall back to local `main`), `git
   worktree add --detach build-jobs/ID/src origin/main`, submodule init
   with `--reference`, the cache-dir flag exported through `ZIG_FLAGS`.
2. Name: `--name`, else `snouty-` + a slug from the prompt's first words;
   must match `[a-z][a-z0-9-]{2,23}`, not exist under `carts/` or in
   the root `build.zig`. Binary name = directory name.
3. Copy `badge-manager/template-cart/` to `carts/NAME/`, replace
   `__NAME__`, insert the registry line before `badge-calibrate` in the
   root `build.zig`. `zig build -Dcart=NAME` once: proves the toolchain
   and warms the cache before the agent starts (`step: template builds`).
4. Agent (skipped with `--no-agent`): `claude -p` in the worktree with the
   prompt = `.claude/skills/new-cart/SKILL.md` + the request,
   `--allowedTools` for Read/Edit/Write/Glob/Grep plus `Bash(zig build
   *)`, `Bash(node tools/preview.mjs *)`, `Bash(python3 tools/make_gif.py *)`,
   `--permission-mode acceptEdits`, `--max-turns`, `--max-budget-usd`,
   `--output-format stream-json --verbose` piped through a small Python
   filter that prints `agent: <text>` and `agent: <tool> <target>` lines.
   Afterwards `git status --porcelain`: every change outside `carts/NAME/`
   and the one `build.zig` line is reverted and logged.
5. `zig build -Dcart=NAME` again (the job fails here if the agent left
   the cart broken; the Zig error is the last thing in the log).
6. `node tools/preview.mjs zig-out/bin/NAME.wasm --frames 240 --every 4
   --press A:60-120 --out build-jobs/ID/preview` + `tools/make_gif.py
   --scale 2 --ms 66` -> `out/preview.gif`.
7. `badge-bench/bench.sh zig-out/firmware/NAME.elf --frames 300 --json`
   -> `out/bench.txt` (the summary lines) and `bench_ms` = worst busy ms.
8. `tools/uf2_info.py` gate; copy `out/NAME.uf2`; `tar` the cart source
   into `out/cart.tar.gz`; commit the worktree to a local branch
   `build/ID` (never pushed) and remove the worktree.
9. `out/summary.json`: `{name, title, description, prompt, where, seconds,
   agent_turns, agent_usd, bench_ms, size, files: [...], branch}`. Title
   and description come from `carts/NAME/summary.json`, which the agent
   writes (falling back to the name and the prompt).

Exit codes: 0 done, 2 bad arguments/name, 3 the cart does not build, 4
the agent failed or hit its limits, 124 wall clock, 130 cancelled.

As built (Track B): step lines are `step: <name>` then `step: <name> ok
(<s> s)`; the template and the skill come from the repo the script runs
in (so a branch can test them before main has them); Zig's cache is
shared with `ZIG_LOCAL_CACHE_DIR` (the agent's own builds inherit it) plus
`zig-pkg` and badge-bench venv symlinks; `claude` also gets
`--permission-prompts none` (a denied call is logged, never a hang),
`--tools Read,Edit,Write,Glob,Grep,Bash`, `--strict-mcp-config`,
`--no-session-persistence` and `Bash(ls *)`; preview and bench also press
LEFT 130-165 and RIGHT 175-225 so a game's movement is on the GIF and in
the bench; `out/` also gets `preview.png` (the last frame) and
`agent.jsonl.gz` (the raw agent stream), `summary.json` also `controls`;
`where` is `remote` when the script runs under ssh; a job that fails or
is cancelled after the template step still commits what it has to
`build/ID`; `build-jobs/ID` is removed at the end unless `--out` is inside
it (the remote path copies and removes it).

### 9.4 The template cart and the skill

`badge-manager/template-cart/` is a minimal cart with no asset pipeline:
`build.zig` (`os_cart.add`, `ReleaseSmall`, no `custom_builder`),
`cart/src/main.zig` (~150 lines: `export_start_code`, the wasm
`present_wasm`/`read_controls` shims copied from snouty-run, `start()`
with vsync 60 fps and `.no_copy_full_frame`, an `update()` that draws a
"SNOUTY" title, a d-pad-moved square and an A-button colour change),
`CLAUDE.md` for the agent (what to edit, what not to touch), `.gitignore`.
No sound, no neopixels, no click binding, per the repository policies.
`build-job.sh --self-test` copies and builds it so the template is
checked by `tests/e2e_build.sh` and stays buildable.

`.claude/skills/new-cart/SKILL.md` at the repository root is the agent's
brief: where it is (a worktree, the cart already registered and
building), the edit scope (`carts/NAME/` only), the API cheat sheet from
the root `CLAUDE.md`, the budgets (16.7 ms per update, 307 KB RAM, light
comptime, the Mac OOM note), the loop (edit, `zig build -Dcart=NAME`,
`node tools/preview.mjs ... --frames 90 --every 30` and look at a PNG,
at most a handful of rounds), and the finish (`carts/NAME/summary.json`
with `title` (<= 20 characters, shown in the badge menu and on the page),
`description`, `controls`). It tells the agent to stop early with a
working cart rather than a broken ambitious one.

### 9.5 Status contract and routes

Additions to `Station.status()`:

```
"build": {"local": bool, "remote": str|None, "ready": bool, "why": str,
          "where": "local"|"remote"|None},           # what "auto" would pick
"job": None | {"id", "prompt", "name", "title", "where", "state",
               "started", "seconds", "exit", "error",
               "log": [str],                          # last 40 lines
               "result": {"cart", "preview", "bench_ms", "size"} | None},
"builds": [{"id", "name", "title", "state", "started", "seconds",
            "preview", "bench_ms", "error"}]          # newest first, last 10
```

Routes:

| Route | Body | Answer |
|---|---|---|
| `POST /api/build` | `{"prompt": str, "where"?: "auto"|"local"|"remote", "name"?: str}` | `{"ok": true, "id"}`; 400 empty/too long prompt (2000 chars), 409 a job is running, 503 `build.ready` false |
| `GET /api/build` | | the current or last job with its full log (`{"job": ...}`) |
| `GET /api/build/<id>` | | that job, full log |
| `POST /api/build/cancel` | | `{"ok": true}`; 404 when nothing runs |
| `GET /builds/<id>/preview.gif` | | the GIF (also `.png`, `bench.txt`, `summary.json` from `out/`) |

`DemoStation` fakes a job too: `POST /api/build` on the demo runs a
scripted 20-second job (step lines, a few `agent:` lines, a generated GIF)
that ends with a new cart in the demo library, so the page can be
developed without the VM.

### 9.6 The page

A "Build a cart" card between the library and Share: a textarea with a
placeholder ("a Snouty cart where ..."), a "Build" button showing where
it will run ("on the station" / "on the build VM"), disabled with the
`why` when not ready. While a job runs: state, elapsed, the log tail
(auto-scrolling, monospace, `agent:` lines highlighted), a Cancel button.
When it ends: the GIF, the title, the bench ms against the 16.7 budget,
the size, and the cart appears in the library with its checkbox ticked
so "Deploy selection" is one tap. Below, the last builds as small rows
with thumbnails. Everything works with the long poll that already
exists; `GET /api/build` is used only when the tail is not enough.

### 9.7 CLI

```
badge build "a Snouty cart where ..." [--remote|--local] [--name snouty-x] [--no-agent]
badge build --status            # the current or last job
badge build --cancel
badge build --log [ID]          # the whole job log
badge builds                    # the last builds
```

`badge build PROMPT` runs the job in the foreground, streaming the log,
and exits 0/1/2 like the other commands. Since state is on disk, the page
shows a CLI-started job and `badge build --status` shows a page-started
one.

### 9.8 Guardrails

One job at a time (the flock), a wall clock (`build_max_minutes`, 20),
`build_max_usd` (5) and `build_max_turns` (40) passed to the agent, the
agent confined to its cart directory (tools allow-list + the post-run
revert), prompt length <= 2000, generated code kept on a local branch and
never pushed, output written only under `build-jobs/ID` on the build
host and `builds/ID` in the library, and the new cart goes through the
normal fit check before it can be deployed. The ssh key on the Pi is a
dedicated one (`/home/badge/.ssh/id_ed25519`, `setup.sh` generates it).

### 9.9 Tracks and verification

- Track A (Python): `build.py`, `config.py` keys (`build_command`,
  `build_max_minutes`, `build_max_usd`, `build_max_turns`), `Station`
  glue, `server.py` routes, `cli.py`, `library.py` `build` field and
  `preview` URL, `tests/test_build.py` against `tests/fake_build_job.sh`,
  server and CLI tests, README + `__init__.py` contract.
- Track B (shell + Zig): `template-cart/`, `build-job.sh`,
  `.claude/skills/new-cart/SKILL.md`, `tests/e2e_build.sh` (self-test
  plus a `--no-agent` job through the CLI on the VM), timings.
- Track C (page): `www/index.html` build card, `DemoStation` job.
- Final check on the VM: one real `badge build --local` with a real
  prompt, GIF looked at, bench line read, the cart deployed to the loop
  image with `--fake-badge`. Timings and the verdict go here:

Track B timings (2026-09-30, the VM with 2 vCPUs, other sessions keeping
the load average between 10 and 18, so read them as upper bounds):

| Step | Seconds |
|---|---|
| worktree + submodule (`--reference`) | 3-6 (1 on an idle VM) |
| template build, cold cache (a worktree with its own empty `.zig-cache`) | 108 on an idle VM; ~840 under load 18 (it rebuilds microzig's regz and the SDK) |
| template build, shared warm cache (`ZIG_LOCAL_CACHE_DIR=<repo>/.zig-cache`, new cart name) | 2-11 |
| rebuild after the agent (nothing changed since its last build) | 0 |
| preview (240 updates) + GIF | 1-2 |
| bench, 300 frames | 37-61 |
| agent, real prompt (20-21 turns) | 178-181 |
| whole job, `--no-agent` | 50-77 |
| whole job with the agent | 237-250 |

Caches: sharing `<repo>/.zig-cache` through `ZIG_LOCAL_CACHE_DIR` (which the
agent's own `zig build` calls inherit, unlike a `--cache-dir` flag) plus a
`zig-pkg` symlink turns the first build from minutes into seconds. Zig's
cache takes file locks and is content-addressed, so concurrent use by a job
and a build in `<repo>` is safe; two jobs in different worktrees with the
same cart name reused the cached configure graph and still installed into
their own `zig-out/`. The badge-bench venv is shared by a symlink too, so a
job never pip-installs.

What the agent run produced ("a Snouty cart where a square dodges falling
blocks, d-pad to move, score at the top", `--max-turns 25 --max-usd 3`,
twice): both runs finished with `success` and a building cart on the first
try of the job. Run 1: "Snouty Dodges" (`snouty-square-dodges`), a score
and best-score band at the top, a coral square with eyes at the bottom,
coloured blocks falling faster as the score rises, a GAME OVER box and A
to restart; 20 turns, $1.20, 1.49 ms worst busy, 14336-byte UF2 (RAM cart,
27 KB in the window). Its only trouble was two denied Bash calls (an
`export PATH=... &&` prefix and one preview command), which the skill now
forbids explicitly. Run 2 with that fix: "Snouty Dodge", score plus three
lives, no denials, 21 turns, $1.15, 1.40 ms, 13312 bytes; it had committed
a second preview directory, so the template's `.gitignore` now ignores
every PNG, GIF and frames.json in the cart. The GIF frames show exactly
what the summaries describe.

Final check (2026-09-30, the merged branch, everything through the
Python side): `python3 -m badge_manager --config <tmp>/station.toml build
"a Snouty cart where you catch falling acorns in a basket, d-pad moves
the basket, score at the top, three misses and it is game over" --local`
with `build_repo` pointing at this checkout. Job
`20260930-221533-catch-falling`: agent 26 turns, $1.50, 249 s; whole
job 309 s; "Acorn Catch" (`snouty-catch-falling`), 16384-byte RAM UF2,
worst busy 2.17 ms of the 16.7 budget. The GIF frames show a SCORE band,
three acorn lives at the top right, a tree canopy dropping acorns, the
basket sliding left and right under the d-pad script and a miss marker
on the ground. Afterwards `badge builds`, `badge build --status` and
`badge library` all showed the job and the cart with its build id, the
real server served `/builds/<id>/preview.gif` (30268 bytes, 200) and
answered 404 to a `..` path, `/api/status` carried `build`, `job`,
`builds` and the cart's `preview`, and `badge --fake-badge badge.img
deploy --carts snouty-catch-falling --yes` put the UF2 on the loop image
as one contiguous file behind the label. 137 unit tests, `e2e_loop.sh`
and `e2e_build.sh` pass. The generated cart is on the local branch
`build/20260930-221533-catch-falling` of this repository.

Not run anywhere yet: the remote ssh path against the real VM from a Pi
(exercised only with a fake `ssh` on PATH), `setup.sh`, and any badge.
