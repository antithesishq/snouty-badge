#!/usr/bin/env bash
# badge-bench entry point: emulated cycle benchmark for SYCL Badge V2 carts.
#
#   ./bench.sh <cart.elf> [--script FILE.json] [--frames N] [--every K]
#              [--budget-ms 16.7] [--out DIR] [--png [K]] [--listing] [--symbols]
#              [--poke SYM=VALUE ...] [--json] [--help]
#
# The first run creates .venv next to this script and installs
# requirements.txt into it; later runs reuse it and reinstall only when
# requirements.txt changes (delete .venv to start over). Needs python3 3.9+
# with the venv module. Relative paths are taken from the current directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/.venv"
REQ="$HERE/requirements.txt"
STAMP="$VENV/.badge-bench-requirements"

die() { echo "badge-bench: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "python3 is $(python3 -c 'import sys; print(sys.version.split()[0])'); need 3.9 or newer"

if [ -x "$VENV/bin/python" ] && [ -f "$STAMP" ] && cmp -s "$REQ" "$STAMP"; then
    :
else
    if [ ! -x "$VENV/bin/python" ]; then
        echo "badge-bench: creating Python venv at $VENV" >&2
        python3 -m venv "$VENV" || {
            rm -rf "$VENV"
            die "python3 -m venv failed; install the venv module (Debian/Ubuntu: apt install python3-venv)"
        }
        "$VENV/bin/python" -m pip install --quiet --upgrade pip \
            || echo "badge-bench: (pip self-upgrade failed; continuing with the bundled pip)" >&2
    fi
    echo "badge-bench: installing requirements.txt into the venv (unicorn, capstone, pyelftools)" >&2
    "$VENV/bin/python" -m pip install --quiet -r "$REQ" || die "pip install -r requirements.txt failed"
    cp "$REQ" "$STAMP"
fi

export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
exec "$VENV/bin/python" -m badge_bench "$@"
