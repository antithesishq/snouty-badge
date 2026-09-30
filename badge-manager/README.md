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
NetworkManager profiles, and enables the services. Without a clone,
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

- `http://snouty.local/` on the same network (mDNS; iOS resolves it,
  Android often does not).
- On the Pi's own network: join `snouty-badge`; the phone shows a "sign in
  to network" pop-up that opens the page. Otherwise go to
  `http://10.42.0.1/`.
- On a phone hotspot: the Pi's address is in the hotspot's client list;
  the page footer shows it so it can be bookmarked.

The page shows the badge (plug it in while it is on its menu), the sets
with Deploy buttons or the reasons a set does not fit, Wipe (tap twice),
the library, a ROM upload, and the log.

## ssh

```
ssh badge@snouty.local badge status
ssh badge@snouty.local badge deploy demo
ssh badge@snouty.local badge log
```

The `badge` command runs `python3 -m badge_manager` as root through a
sudoers rule that allows only that command. `badge --help` lists the rest.

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

Sets live in `/var/lib/badge-station/library/manifest.toml` (format in
`badge_manager/library.py`). ROMs can also be uploaded from the page
(.gg .sms .gb .gbc .md .bin, up to 4 MB).

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

The demo badge plugs in after 3 s, has two sets (one too big), deploys in
about 2 s and then asks to be unplugged, and re-plugs itself 10 s later.
`BADGE_STATION_DEMO=1` does the same. The server also falls back to the
demo when the real station cannot start.

## HTTP API

`GET /api/status` (the contract in `badge_manager/__init__.py`, plus
`seq`); `GET /api/status?since=SEQ&wait=25` waits for a change;
`POST /api/deploy` `{"set": "demo"}`, `POST /api/wipe`, `POST /api/sync`
return `{"ok": true}` at once, 409 when busy; `POST /api/upload` (multipart,
or the raw file with an `X-Filename` header); `GET /api/log?n=200`.

## Where things live on the Pi

| Path | What |
|---|---|
| `/opt/badge-station/badge-manager`, `/opt/badge-station/tools` | the code (`setup.sh` rsyncs it) |
| `/etc/badge-station/station.toml` | configuration |
| `/var/lib/badge-station/library/` | `manifest.toml`, `carts/*.uf2`, `roms/` |
| `/run/badge-station/` | the badge mount point |
| `/usr/local/bin/badge`, `/etc/sudoers.d/badge-station` | the ssh command |
| `/etc/systemd/system/badge-station.service` | the web server (`journalctl -u badge-station`) |
| `/etc/systemd/system/badge-net-watchdog.{service,timer}` | hotspot or access point |
| `/etc/NetworkManager/dnsmasq-shared.d/snouty.conf` | captive DNS on the access point |
| `/etc/avahi/services/badge-station.service` | `snouty.local` web service advert |
