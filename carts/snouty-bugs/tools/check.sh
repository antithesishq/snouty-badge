#!/usr/bin/env bash
# Regression gate: build the cart, then run every tools/scripts/*.json through
# tools/preview.mjs headlessly with its expectations, one line per script.
#
#   tools/check.sh [--no-build] [--only NAME]
#
# Each script NAME.json may have a sidecar NAME.args: extra preview arguments
# (--frames, --expect, --at, --call-at, --dump-exports, ...), shell-quoted as on
# a command line; lines starting with # are comments, the other lines are
# joined. A script without a sidecar runs with --frames 600. Output goes to
# out/check/NAME/ (frames.json, preview.log). Exit status is non-zero if any
# script fails. CART_WASM overrides the cart (default ../../zig-out/bin/snouty-bugs.wasm,
# the repository root's build output).
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."   # this cart's directory
repo="../.."               # repository root: zig build and zig-out/ live there

build=1
only=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) build=0 ;;
        --only) [ $# -ge 2 ] || { echo "check: --only needs a script name" >&2; exit 2; }; only="${2%.json}"; only="${only##*/}"; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check: unexpected argument '$1' (usage: tools/check.sh [--no-build] [--only NAME])" >&2; exit 2 ;;
    esac
    shift
done

wasm="${CART_WASM:-$repo/zig-out/bin/snouty-bugs.wasm}"
if [ "$build" = 1 ]; then (cd "$repo" && zig build -Dcart=snouty-bugs); fi
[ -f "$wasm" ] || { echo "check: $wasm not found" >&2; exit 1; }

scripts=()
for f in tools/scripts/*.json; do
    name="$(basename "$f" .json)"
    if [ -z "$only" ] || [ "$name" = "$only" ]; then scripts+=("$f"); fi
done
[ ${#scripts[@]} -gt 0 ] || { echo "check: no script matches '${only}' in tools/scripts/" >&2; exit 2; }

echo "check: $wasm"
fails=0
for f in "${scripts[@]}"; do
    name="$(basename "$f" .json)"
    sidecar="tools/scripts/$name.args"
    args=()
    if [ -f "$sidecar" ]; then
        # xargs does the shell-style quote splitting without eval.
        mapfile -d '' args < <(grep -v '^[[:space:]]*#' "$sidecar" | xargs -r printf '%s\0')
    else
        args=(--frames 600)
    fi
    out="out/check/$name"
    mkdir -p "$out"
    rm -f "$out/frames.json"
    rc=0
    node tools/preview.mjs "$wasm" --script "$f" --quiet --out "$out" "${args[@]}" 2>"$out/preview.log" || rc=$?
    if [ -f "$out/frames.json" ]; then
        summary="$(node -e '
            const m = require(require("path").resolve(process.argv[1]));
            const ex = Object.entries(m.exports).map(([k, v]) => `${k}=${v}`).join(" ");
            const checks = (m.expect || []).length + (m.at || []).length;
            const bad = [...(m.at || []).filter((r) => !r.pass).map((r) => `${r.expr} @${r.tick} (got ${r.actual})`),
                ...(m.expect || []).filter((r) => !r.pass).map((r) => `${r.expr} (got ${r.actual})`)];
            const calls = (m.calls || []).map((c) => `${c.name}@${c.tick}=${c.value}`).join(" ");
            console.log([ex, calls && `calls: ${calls}`, bad.length ? `failed ${bad.length}/${checks}: ${bad.join("; ")}` : `${checks} check(s)`].filter(Boolean).join(" | "));
        ' "$out/frames.json")"
    else
        summary="exit $rc: $(grep -m1 '^preview: ' "$out/preview.log" | sed -e 's/^preview: //' -e 's/\. Zero-arg function exports in .*/ (export list in preview.log)/' || true)"
    fi
    if [ "$rc" = 0 ]; then status=PASS; else status=FAIL; fails=$((fails + 1)); fi
    printf '%s %-10s %s\n' "$status" "$name" "$summary"
done

total=${#scripts[@]}
if [ "$fails" -gt 0 ]; then
    echo "check: $fails of $total script(s) failed (logs in out/check/NAME/preview.log)"
    exit 1
fi
echo "check: all $total script(s) passed"
