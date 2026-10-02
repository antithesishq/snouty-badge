#!/bin/bash
# Install or update the Snouty badge station on Raspberry Pi OS Lite 64-bit
# (Bookworm or later). Run as root; safe to re-run.
#
#   sudo ./badge-manager/setup.sh [--build-tools]          from a clone
#   curl -fsSL <raw url of this file> | sudo bash -s -- [--build-tools]
#
# Without a clone next to it, the script clones REPO_URL (badge-manager/ and
# tools/ only). --build-tools also installs the pinned Zig, Node 20 and,
# on a Pi with 6 GB or more, the badge-bench venv (PLAN.md section 6).
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/antithesishq/snouty-badge.git}
REPO_BRANCH=${REPO_BRANCH:-main}
PREFIX=/opt/badge-station
ETC=/etc/badge-station
LIB=/var/lib/badge-station/library
ZIG_VERSION=0.17.0-dev.1936+5a625d5f3
ZIG_TARBALL=zig-aarch64-linux-$ZIG_VERSION.tar.xz
ZIG_URLS=("https://ziglang.org/builds/$ZIG_TARBALL"
          "https://pkg.machengine.org/zig/$ZIG_TARBALL")

BUILD_TOOLS=0
for arg in "$@"; do
    case $arg in
        --build-tools) BUILD_TOOLS=1 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "setup.sh: unknown option $arg" >&2; exit 2 ;;
    esac
done

step() { echo; echo "== $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "setup.sh: run as root (sudo)" >&2
    exit 1
fi

step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q python3 avahi-daemon udisks2 rsync network-manager iw git dosfstools curl xz-utils \
    qrencode
python3 -c 'import sys, tomllib; sys.exit(sys.version_info < (3, 11))' ||
    { echo "setup.sh: python3 3.11 or newer is required" >&2; exit 1; }

step "Station code in $PREFIX"
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "$here/badge_manager/__init__.py" ] && [ -f "$here/../tools/make_romfs.py" ]; then
        SRC=$(cd "$here/.." && pwd)
    fi
fi
if [ -z "$SRC" ]; then
    SRC=$PREFIX/src
    if [ -d "$SRC/.git" ]; then
        git -C "$SRC" fetch -q --depth 1 origin "$REPO_BRANCH"
        git -C "$SRC" checkout -q -B "$REPO_BRANCH" FETCH_HEAD
    else
        rm -rf "$SRC"
        git clone -q --depth 1 --branch "$REPO_BRANCH" --filter=blob:none --sparse "$REPO_URL" "$SRC"
        git -C "$SRC" sparse-checkout set badge-manager tools badge-bench
    fi
fi
echo "source: $SRC"
revision=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$revision" != unknown ] && [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
    revision="$revision (dirty source)"
fi
mkdir -p "$PREFIX"
printf '%s\n' "$revision" > "$PREFIX/REVISION"
echo "installed revision: $revision"
rsync -a --delete --exclude __pycache__ --exclude '*.pyc' "$SRC/badge-manager/" "$PREFIX/badge-manager/"
rsync -a --delete --exclude __pycache__ --exclude '*.pyc' "$SRC/tools/" "$PREFIX/tools/"
if [ $BUILD_TOOLS -eq 1 ] && [ -d "$SRC/badge-bench" ]; then
    rsync -a --delete --exclude .venv --exclude __pycache__ "$SRC/badge-bench/" "$PREFIX/badge-bench/"
fi
# rsync -a preserves checkout ownership. Service code must remain trusted
# even when an administrator installs it from the builder's checkout.
chown -R root:root "$PREFIX/badge-manager" "$PREFIX/tools"
chmod -R go-w "$PREFIX/badge-manager" "$PREFIX/tools"
chmod +x "$PREFIX/badge-manager/"*.sh "$PREFIX/badge-manager/net/"*.sh

step "Configuration and library"
mkdir -p "$ETC" "$LIB/carts" "$LIB/roms"
if [ ! -f "$ETC/station.toml" ]; then
    install -m 600 "$PREFIX/badge-manager/station.example.toml" "$ETC/station.toml"
    echo "created $ETC/station.toml (edit the [[hotspots]] entries)"
else
    echo "kept $ETC/station.toml"
fi
if [ ! -f "$LIB/manifest.toml" ]; then
    if [ -f "$PREFIX/badge-manager/sets.default.toml" ]; then
        install -m 644 "$PREFIX/badge-manager/sets.default.toml" "$LIB/manifest.toml"
        echo "created $LIB/manifest.toml from sets.default.toml"
    else
        printf '# Carts, ROMs and sets; see badge_manager/library.py.\n' > "$LIB/manifest.toml"
        echo "created an empty $LIB/manifest.toml"
    fi
fi

step "Hostname snouty"
if [ "$(hostname)" != snouty ]; then
    hostnamectl set-hostname snouty
fi
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tsnouty/' /etc/hosts
else
    printf '127.0.1.1\tsnouty\n' >> /etc/hosts
fi

step "The badge user and command"
if ! id badge >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "Badge station" badge
    echo "created user badge"
fi
invoker=${SUDO_USER:-}
if [ -n "$invoker" ] && [ "$invoker" != root ] && [ -f "/home/$invoker/.ssh/authorized_keys" ]; then
    install -d -m 700 -o badge -g badge /home/badge/.ssh
    touch /home/badge/.ssh/authorized_keys
    # Append keys the badge user does not have yet.
    grep -vxF -f /home/badge/.ssh/authorized_keys "/home/$invoker/.ssh/authorized_keys" \
        >> /home/badge/.ssh/authorized_keys || true
    chown badge:badge /home/badge/.ssh/authorized_keys
    chmod 600 /home/badge/.ssh/authorized_keys
    echo "copied $invoker's ssh keys to badge"
fi
# The station's own key for the build host (badge build over ssh, PLAN 9.8).
# The exe.dev VM authenticates account keys, so the public key must be
# registered once: `ssh exe.dev ssh-key add '<pubkey>'` from any logged-in shell.
install -d -m 700 -o badge -g badge /home/badge/.ssh
if [ ! -f /home/badge/.ssh/id_ed25519 ]; then
    ssh-keygen -q -t ed25519 -N "" -C "badge-station@$(hostname)" -f /home/badge/.ssh/id_ed25519
    chown badge:badge /home/badge/.ssh/id_ed25519 /home/badge/.ssh/id_ed25519.pub
    echo "generated the station's ssh key /home/badge/.ssh/id_ed25519"
fi
echo "build host key to register (ssh exe.dev ssh-key add '...'):"
echo "  $(cat /home/badge/.ssh/id_ed25519.pub)"
cat > /usr/local/bin/badge <<EOF
#!/bin/sh
# The badge station command line (badge-manager/badge_manager/cli.py).
cd $PREFIX/badge-manager || exit 1
export BADGE_STATION_OPERATOR=\${BADGE_STATION_OPERATOR:-1}
exec /usr/bin/python3 -m badge_manager "\$@"
EOF
chmod 755 /usr/local/bin/badge
# Remove the old broad grant when upgrading an existing station.
rm -f /etc/sudoers.d/badge-station
# The root service owns library state. Writable job output is granted per
# build after the job directory is created; the SSH account cannot replace
# service-owned state files with symlinks.
chown -R root:root "$LIB"
chmod -R go-w "$LIB"

step "Network: NetworkManager profiles, captive DNS, mDNS"
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
install -m 644 "$PREFIX/badge-manager/net/dnsmasq-shared.d-snouty.conf" \
    /etc/NetworkManager/dnsmasq-shared.d/snouty.conf
if "$PREFIX/badge-manager/net/nm-profiles.sh" "$ETC/station.toml"; then :; else
    echo "setup.sh: NetworkManager profiles not written; fix $ETC/station.toml and run" >&2
    echo "          $PREFIX/badge-manager/net/nm-profiles.sh" >&2
fi
mkdir -p /etc/avahi/services
install -m 644 "$PREFIX/badge-manager/net/avahi-badge.service" /etc/avahi/services/badge-station.service
systemctl enable avahi-daemon >/dev/null 2>&1 || true
systemctl restart avahi-daemon || true

step "Services"
install -m 644 "$PREFIX/badge-manager/systemd/badge-station.service" /etc/systemd/system/
install -m 644 "$PREFIX/badge-manager/systemd/badge-net-watchdog.service" /etc/systemd/system/
install -m 644 "$PREFIX/badge-manager/systemd/badge-net-watchdog.timer" /etc/systemd/system/
install -m 644 "$PREFIX/badge-manager/systemd/badge-sync.service" /etc/systemd/system/
install -m 644 "$PREFIX/badge-manager/systemd/badge-sync.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable badge-station.service badge-net-watchdog.timer badge-sync.timer
# Merge any default set or cart title missing from the manifest (never overwrites),
# before the restart so the server starts with them.
BADGE_STATION_OPERATOR=0 /usr/local/bin/badge init-sets || echo "setup.sh: badge init-sets failed, default sets not merged" >&2
systemctl restart badge-station.service
systemctl start badge-net-watchdog.timer badge-sync.timer

if [ $BUILD_TOOLS -eq 1 ]; then
    step "Build tools"
    BUILD_REPO=/home/badge/snouty-badge
    if [ ! -d "$BUILD_REPO/.git" ]; then
        runuser -u badge -- git clone -q "$REPO_URL" "$BUILD_REPO"
    else
        runuser -u badge -- git -C "$BUILD_REPO" fetch -q origin "$REPO_BRANCH"
        runuser -u badge -- git -C "$BUILD_REPO" checkout -q -B "$REPO_BRANCH" FETCH_HEAD
    fi
    # build_repo is the remote VM path; local builds use this checkout.
    python3 - "$ETC/station.toml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
values = {'build_local_repo': '/home/badge/snouty-badge',
          'build_user': 'badge', 'build_home': '/home/badge'}
missing = [f'{key} = "{value}"\n' for key, value in values.items()
           if not any(line.strip().startswith(key + ' =') for line in text.splitlines())]
if missing:
    first = text.find('[[hotspots]]')
    if first < 0:
        text += '\n' + ''.join(missing)
    else:
        text = text[:first] + ''.join(missing) + '\n' + text[first:]
    path.write_text(text)
PY
    ZIG_HOME=/home/badge/.local/zig
    if [ -x "$ZIG_HOME/zig" ] && [ "$("$ZIG_HOME/zig" version)" = "$ZIG_VERSION" ]; then
        echo "zig $ZIG_VERSION already installed"
    else
        tmp=$(mktemp -d)
        got=0
        for url in "${ZIG_URLS[@]}"; do
            if curl -fL --retry 2 -o "$tmp/$ZIG_TARBALL" "$url"; then got=1; break; fi
            echo "zig download failed from $url"
        done
        if [ $got -eq 1 ]; then
            rm -rf "$ZIG_HOME"
            mkdir -p "$ZIG_HOME"
            tar -xJf "$tmp/$ZIG_TARBALL" -C "$ZIG_HOME" --strip-components=1
            install -d -o badge -g badge /home/badge/.local /home/badge/.local/bin
            ln -sf "$ZIG_HOME/zig" /home/badge/.local/bin/zig
            chown -R badge:badge /home/badge/.local
            echo "zig $("$ZIG_HOME/zig" version) in $ZIG_HOME"
        else
            echo "setup.sh: could not download Zig $ZIG_VERSION" >&2
        fi
        rm -rf "$tmp"
    fi

    node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    if [ "$node_major" -ge 20 ]; then
        echo "node $(node --version) already installed"
    elif curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y -q nodejs; then
        echo "node $(node --version) from nodesource"
    else
        apt-get install -y -q nodejs npm
        echo "node $(node --version 2>/dev/null) from apt (20 or newer is wanted)"
    fi

    mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    if [ "$mem_kb" -ge $((6 * 1024 * 1024 - 256 * 1024)) ]; then
        apt-get install -y -q python3-venv
        if [ -f "$PREFIX/badge-bench/requirements.txt" ]; then
            python3 -m venv "$PREFIX/badge-bench/.venv"
            "$PREFIX/badge-bench/.venv/bin/pip" install -q -r "$PREFIX/badge-bench/requirements.txt"
            echo "badge-bench venv in $PREFIX/badge-bench/.venv"
        else
            echo "setup.sh: no badge-bench/requirements.txt in the source, venv skipped" >&2
        fi
    else
        echo "badge-bench venv skipped: this Pi has $((mem_kb / 1024)) MB, local builds need 6 GB;"
        echo "builds will run on build_host from $ETC/station.toml instead."
    fi
fi

# Build tools and checkout may have been added after the first service start.
systemctl restart badge-station.service

step "Done"
addrs=$(hostname -I 2>/dev/null || true)
echo "Station page:  http://snouty.local/"
for a in $addrs; do
    case $a in *:*) ;; *) echo "               http://$a/" ;; esac
done
echo "Access point:  wifi snouty-badge, then http://10.42.0.1/"
echo "ssh:           ssh badge@snouty.local badge status"
echo "QR codes:      badge qr   (the page and Wi-Fi codes in the terminal, for a sticker)"
echo "Nightly sync:  badge-sync.timer at 03:00 (systemctl list-timers badge-sync.timer)"
echo "Config:        $ETC/station.toml (re-run net/nm-profiles.sh after editing hotspots)"
