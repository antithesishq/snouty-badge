# badge-manager: the Snouty badge station

A headless Raspberry Pi that deploys sets of carts onto a SYCL badge from a
phone browser or ssh. The badge is a USB drive; every deploy wipes it,
copies a whole set and ejects it. Design and milestones: `PLAN.md`.

## Install on a Pi

Any 64-bit Pi (Zero 2 W, 3, 4, 5) with Raspberry Pi OS Lite 64-bit
(Bookworm or later). Set a user and ssh key in Raspberry Pi Imager, boot,
then:

```
sudo apt-get install -y git
git clone https://github.com/antithesishq/snouty-badge.git
sudo snouty-badge/badge-manager/setup.sh
```

`setup.sh` is safe to re-run (it is also how you update). It installs the
code into `/opt/badge-station`, sets the hostname to `snouty`, creates the
`badge` user (with your ssh keys) and the `badge` command, writes the
NetworkManager profiles, installs `qrencode` for the Share QR codes,
starts the library from `sets.default.toml` (or merges its missing sets
with `badge init-sets`), and enables the services and the nightly sync
timer. Without a clone,
`curl -fsSL <raw setup.sh url> | sudo bash` clones the repository itself.
`--build-tools` adds the pinned Zig, Node 20 and, on a Pi with 6 GB or
more, the badge-bench venv, for building carts on the Pi (PLAN section 6).

## Configure the hotspot

Edit `/etc/badge-station/station.toml`: one `[[hotspots]]` block per phone
(`ssid`, `password`), kept at the end of the file. Then:

```
sudo /opt/badge-station/badge-manager/net/nm-profiles.sh
sudo systemctl start badge-net-watchdog.service
```

At boot the Pi joins a hotspot if one is in range. If none has connected
45 s after boot it starts its own network, `snouty-badge` (password
`ap_password`, default `snoutysnouty`). Every 5 minutes, while nobody is on
that network, it tries the hotspots again. It never drops the access point
while a phone is attached.

## Reaching the page from a phone

iPhone and Android are both first-class; nothing needs an app.

| How | iOS (Safari, Chrome) | Android (Chrome) |
|---|---|---|
| `http://snouty.local/` on the same network (mDNS) | yes | Android 12 and later yes, older no |
| Join `snouty-badge` (the Pi's own network): "sign in to network" pop-up opens the page | yes | yes |
| `http://10.42.0.1/` on `snouty-badge` (the fixed address) | yes | yes |
| On a phone hotspot: the Pi's address from the hotspot's client list | yes | yes |
| Scan a Share QR code with the camera app | yes | yes |

- **Own network.** When no hotspot is around the Pi runs `snouty-badge`.
  Its DNS answers every name with the Pi and the server answers Apple's and
  Android's connectivity probes with a redirect, so the phone shows the
  "sign in to network" pop-up and the page opens in it. If the pop-up does
  not come, open `http://10.42.0.1/`.
- **Phone hotspot.** `snouty.local` works on iOS and on Android 12+. On
  older Android, read the Pi's address from the hotspot's connected-devices
  list once, then bookmark it; the page footer shows the address it was
  opened on.
- **Share.** The page has a Share section with a QR code for its own
  address and, on the Pi's own network, a Wi-Fi QR code (network name and
  password) that joins `snouty-badge` in one scan. A second phone gets on by
  pointing its camera at the first phone's screen. The section is hidden
  when `qrencode` is not installed (`setup.sh` installs it).
- **Sticker.** `ssh badge@snouty.local badge qr` prints the same codes in
  the terminal, for printing a sticker for the Pi.

## Using the page

- **Badge**: plug the badge in while it is on its menu. The card lists
  what is on the drive by title (drive name underneath) and says
  "On it: Demo reel" when the files are exactly one set's.
- **Sets**: each set shows its size and root entries, with Deploy when it
  fits. Tap a set's name to open it: the drive names it would write and,
  when it does not fit, why; **Remove set** (tap twice) deletes it from the
  manifest. **Wipe** (tap twice) empties the badge; **Sync library** pulls
  new UF2s from the build host.
- **Library**: every cart and ROM has a checkbox. The line above the list
  shows the selection's fit live (`3 carts, 1 ROM: 812 KB of 1,276 KB,
  9 of 31 entries`, in orange with the reason when it does not fit).
  **Deploy selection** (tap twice, it wipes the badge) writes exactly the
  ticked items; **Save as set** asks for a name and adds it to Sets (the
  key is the name's slug; the same name replaces that set).
- **RAM/XIP**: a cart built both ways (`snouty.uf2` and `snouty-xip.uf2` in
  `carts/`) is one library entry with a RAM|XIP toggle. The choice is per
  cart, stored in the manifest (`use = "xip"`), and every set and the fit
  numbers follow it. The drive gets the variant's file name
  (`snouty-xip.uf2`), which is what the badge menu shows.
- **Upload a ROM**: any file up to 4 MB; the server accepts .gg .sms .gb
  .gbc .md .bin. The file picker shows every file on purpose, since
  Android hides extensions it does not know when a page filters them.
  **There is no passphrase, by decision (PLAN 7, answer 5): anyone on the
  station's network can upload a ROM.**

## ssh

```
ssh badge@snouty.local badge status
ssh badge@snouty.local badge deploy demo
ssh badge@snouty.local badge deploy --carts snouty,snouty-gear --roms 'sonic*'
ssh badge@snouty.local badge mode snouty xip        # or: badge mode --all ram
ssh badge@snouty.local badge set save gg --title "Game Gear" --carts snouty-gear --roms '*.gg'
ssh badge@snouty.local badge set rm gg
ssh badge@snouty.local badge init-sets              # merge missing default sets
ssh badge@snouty.local badge qr
ssh badge@snouty.local badge log
ssh -t badge@snouty.local badge build "a Snouty cart where it rains frogs"
ssh -t badge@snouty.local badge build "a maze" --remote --name maze2 --no-agent
ssh badge@snouty.local badge build --status         # the running or last build
ssh badge@snouty.local badge build --log            # its whole log (or --log ID)
ssh badge@snouty.local badge build --cancel
ssh badge@snouty.local badge builds                 # the last builds
```

`badge build` streams the job's log and exits 0 when the cart is in the
library, 1 when the build failed or was cancelled, 2 when another build is
running or builds are not possible right now. Ctrl-C (or a dropped ssh
session) cancels the build. It does not need the badge plugged in.

The `badge` command runs `python3 -m badge_manager` as root through a
sudoers rule that allows only that command. `badge --help` lists the rest
(`fit`, `library`, `wipe`, `sync`, `add-rom`, `add-uf2`).

## Building a cart from the phone

The page's "Build a cart" box (or `badge build` over ssh) takes a prompt
like "a Snouty cart where it rains frogs" and makes a new cart from it
(PLAN section 9):

1. The station starts a job in `library/builds/<id>/` and picks where it
   runs. It builds on the Pi itself when the Pi has 6 GB of RAM or more,
   the Zig toolchain (`setup.sh --build-tools`) and a checkout at
   `build_repo`; otherwise on the build VM `build_host` over ssh. The page
   shows which one ("on the station" / "on the build VM") and why a build
   is not possible (no build VM set, no internet).
2. `badge-manager/build-job.sh` runs there: a fresh worktree, a template
   cart, `claude -p` editing it to the prompt (limited to
   `build_max_turns` turns and `build_max_usd` dollars), a Zig build, a
   preview GIF and a badge-bench figure. Every step streams to the page.
   The job is killed after `build_max_minutes` (20). Expect 3 to 10 minutes.
3. On success the UF2 is checked with `tools/uf2_info.py`, copied to
   `library/carts/<name>.uf2` and added to the manifest with
   `build = "<id>"`. The cart shows up in the library with its GIF, ready
   to tick and deploy. The generated source stays on a local `build/<id>`
   branch on the build host; nothing is pushed.

One build runs at a time. A deploy can still run while a cart builds.

**The build VM needs the Pi's ssh key.** The station runs as root and uses
`/home/badge/.ssh/id_ed25519` when it exists (else root's own key). The
exe.dev VM has no `authorized_keys`: keys are registered on the exe.dev
account (PLAN 9.1). Register the Pi's public key once, from a machine
that is logged in to exe.dev:

```
ssh exe.dev ssh-key add '<contents of /home/badge/.ssh/id_ed25519.pub>'
```

Then `ssh badge@snouty.local badge build "..." --remote --no-agent`
checks the whole path without spending anything on the agent.

## Filling the library

`sync.sh` pulls `zig-out/firmware/*.uf2` from `build_host`:`build_repo`
(station.toml) over ssh, checks each file with `tools/uf2_info.py`, and
registers new carts with `badge add-uf2`. Give root's ssh key on the Pi
access to the build host first (`sudo ssh-keygen`, then add
`/root/.ssh/id_ed25519.pub` to the host's `authorized_keys`).

```
sudo /opt/badge-station/badge-manager/sync.sh              # from station.toml
sudo /opt/badge-station/badge-manager/sync.sh user@laptop /path/to/snouty-badge
sudo /opt/badge-station/badge-manager/sync.sh local /home/badge/snouty-badge
```

The timer `badge-sync.timer` runs `badge sync` every night at 03:00 (up
to 10 minutes later at random, and at the next boot if the Pi was off), so
the library follows main without anyone touching the Pi. It needs internet
and the ssh key above; a failed sync is one log line and nothing else
changes. `systemctl list-timers badge-sync.timer` shows the next run,
`journalctl -u badge-sync` the last one.

Sets live in `/var/lib/badge-station/library/manifest.toml` (format in
`badge_manager/library.py`). A fresh install starts from
`sets.default.toml` (first-guess show-day sets and titles for the known
carts); `badge init-sets` adds any default set or cart title an existing
manifest lacks and never overwrites one. A set's `roms` may hold glob
patterns matched case-insensitively against ROM file names, so a set stays
current as ROMs are uploaded:

```
[sets.gear]
title = "Game Gear"
carts = ["snouty-gear"]
roms = ["*.gg", "*.sms"]
```

ROMs can also be uploaded from the page (.gg .sms .gb .gbc .md .bin, up to
4 MB).

## Testing without a badge

A USB stick with the badge's exact limits (1280 KB FAT12, 32 root entries,
label SYCLBADGE) takes the badge's place end to end:

```
sudo parted -s /dev/sdX mklabel msdos mkpart primary fat16 1MiB 2304KiB
sudo mkfs.vfat -F 12 -n SYCLBADGE -s 1 -r 32 -S 512 /dev/sdX1
```

Without any hardware, point the station at an image or a directory:

```
python3 ../tools/make_romfs.py /tmp/badge.img           # empty badge image
python3 -m badge_manager.server --port 8080 --fake-badge /tmp/badge.img
python3 -m badge_manager.server --port 8080 --fake-badge /tmp/badge-dir
```

An image is loop-mounted (needs root); a directory needs nothing and
simulates the badge's limits. `fake_badge` in station.toml does the same
for the service.

## Demo server

For working on the page with no station behind it:

```
cd badge-manager
python3 -m badge_manager.server --demo --port 8080 --bind 127.0.0.1
```

The demo badge plugs in after 3 s, has three sets (one too big) and a
library with RAM/XIP carts, deploys in about 2 s and then asks to be
unplugged, and re-plugs itself 10 s later. Every page control works against
it: the RAM/XIP toggle, selections, Save as set, Remove set, upload, and
the Share QR codes (it pretends to be on its own network).
`BADGE_STATION_DEMO=1` does the same. The server also falls back to the
demo when the real station cannot start.

## HTTP API

The page uses nothing else, so a laptop can script the station with curl.

| Route | Body | Answer |
|---|---|---|
| `GET /api/status` | | the contract in `badge_manager/__init__.py`, plus `seq` and `qr` (true when QR codes are available) |
| `GET /api/status?since=SEQ&wait=25` | | the same, once something changed (long poll) |
| `GET /api/log?n=200` | | `{"log": [...]}` |
| `POST /api/deploy` | `{"set": "demo"}` or `{"carts": [...], "roms": [...]}` | `{"ok": true}` at once; the log follows |
| `POST /api/wipe`, `POST /api/sync` | | `{"ok": true}` at once |
| `POST /api/fit` | `{"carts": [...], "roms": [...]}` | `{bytes, entries, bytes_capacity, entries_capacity, fits, why, files}` |
| `POST /api/sets` | `{"key"?, "title", "carts", "roms"}` | `{"ok": true, "key": ..., "set": {...}}` |
| `DELETE /api/sets/<key>` | | `{"ok": true}` |
| `POST /api/cart-mode` | `{"cart": "snouty", "mode": "xip"}` | `{"ok": true, "cart": {...}}` |
| `POST /api/upload` | multipart, or the raw file with an `X-Filename` header | `{"ok": true, "key", "name", "size"}` |
| `GET /qr/page.svg`, `GET /qr/wifi.svg` | | SVG QR codes; 404 without `qrencode` or off the Pi's own network (Wi-Fi) |
| `POST /api/build` | `{"prompt": "...", "where"?: "auto"\|"local"\|"remote", "name"?: "snouty-x"}` | `{"ok": true, "id"}` at once; 400 empty or too long prompt (2000 characters) or bad name, 409 a build is running, 503 builds not possible (`build.why` in the status) |
| `GET /api/build` | | `{"job": ...}`: the running or last build with its whole log, or `null` |
| `GET /api/build/<id>` | | `{"job": ...}` for that build; 404 unknown |
| `POST /api/build/cancel` | | `{"ok": true}`; 404 when no build runs |
| `GET /builds/<id>/preview.gif` | | the build's GIF; also `preview.png`, `bench.txt`, `summary.json`; 404 for anything else |

Bad input is a 400 with `{"ok": false, "error": "..."}`. Everything that
acts or edits answers 409 while a deploy, wipe or sync runs, so a deploy
never races a manifest rewrite. Builds are separate: they answer 409 only
while another build runs, and a deploy can run during a build.

## Where things live on the Pi

| Path | What |
|---|---|
| `/opt/badge-station/badge-manager`, `/opt/badge-station/tools` | the code (`setup.sh` rsyncs it) |
| `/etc/badge-station/station.toml` | configuration |
| `/var/lib/badge-station/library/` | `manifest.toml`, `carts/*.uf2`, `roms/` |
| `/var/lib/badge-station/library/builds/<id>/` | one cart build: `job.json`, `job.log`, `prompt.txt`, `out/` (UF2, `preview.gif`, `bench.txt`, `summary.json`); `builds/.lock` while one runs |
| `/home/badge/.ssh/id_ed25519` | the station's ssh key for the build VM |
| `/run/badge-station/` | the badge mount point |
| `/usr/local/bin/badge`, `/etc/sudoers.d/badge-station` | the ssh command |
| `/etc/systemd/system/badge-station.service` | the web server (`journalctl -u badge-station`) |
| `/etc/systemd/system/badge-net-watchdog.{service,timer}` | hotspot or access point |
| `/etc/systemd/system/badge-sync.{service,timer}` | nightly `badge sync` at 03:00 (`journalctl -u badge-sync`) |
| `/etc/NetworkManager/dnsmasq-shared.d/snouty.conf` | captive DNS on the access point |
| `/etc/avahi/services/badge-station.service` | `snouty.local` web service advert |
