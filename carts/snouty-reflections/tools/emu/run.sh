#!/usr/bin/env bash
# Emulated cycle benchmark for the ray tracer: builds the bench ELF from
# cart/src, runs it under unicorn with a Cortex-M33 cycle model, checks the
# frames against tools/reference.py and prints the cost tables.
#
# usage: tools/emu/run.sh [--sweep] [--real] [--listing] [--mode none|bayer]
#   (no flags)  bench ELF frames 0 and 300 + reference check + tables
#   --sweep     also frames 0..575 step 25 (full orbit): min/max/worst frame
#   --real      also the real cart ELF (run `zig build` first)
#   --listing   annotated capstone listings in tools/emu/out/
#
# First run creates tools/emu/.venv and installs requirements.txt into it.
# Needs zig, node and python3 (3.9+, with the venv module) on PATH, e.g.
#   export PATH="$HOME/.local/bin:$PATH"
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VENV="$HERE/.venv"
REQ="$HERE/requirements.txt"
STAMP="$VENV/.emu-requirements"

die() { echo "emu: $*" >&2; exit 1; }

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
prev=""
for arg in "$@"; do
    if [ "$prev" = "--mode" ]; then
        case "$arg" in none|bayer) ;; *) die "--mode takes none or bayer" ;; esac
        prev=""; continue
    fi
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --sweep|--real|--listing|--mode=none|--mode=bayer) ;;
        --mode) prev="--mode" ;;
        *) usage >&2; die "unknown option: $arg" ;;
    esac
done
[ "$prev" = "--mode" ] && die "--mode takes none or bayer"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "python3 is $(python3 -c 'import sys; print(sys.version.split()[0])'); need 3.9 or newer"
command -v zig >/dev/null 2>&1 || die "zig not found on PATH (e.g. export PATH=\"\$HOME/.local/bin:\$PATH\")"
command -v node >/dev/null 2>&1 || die "node not found on PATH (Node.js 20+, used for tools/check_render.mjs)"

# ---- venv bootstrap (idempotent: redone only when requirements.txt changes)
if [ -x "$VENV/bin/python" ] && [ -f "$STAMP" ] && cmp -s "$REQ" "$STAMP"; then
    :
else
    if [ ! -x "$VENV/bin/python" ]; then
        echo "emu: creating Python venv at tools/emu/.venv"
        python3 -m venv "$VENV" || {
            rm -rf "$VENV"
            die "python3 -m venv failed; install the venv module (Debian/Ubuntu: apt install python3-venv)"
        }
        "$VENV/bin/python" -m pip install --quiet --upgrade pip \
            || echo "emu: (pip self-upgrade failed; continuing with the bundled pip)"
    fi
    echo "emu: installing tools/emu/requirements.txt into the venv"
    "$VENV/bin/python" -m pip install --quiet -r "$REQ" || die "pip install -r tools/emu/requirements.txt failed"
    cp "$REQ" "$STAMP"
fi

# ---- build and run
"$HERE/build.sh"
cd "$REPO"
exec "$VENV/bin/python" "$HERE/emu.py" "$@"
