#!/usr/bin/env bash
# The oracle gate: every action script in tools/oracle/scripts/ through the
# original JS (tools/js_oracle.mjs) and the Zig port (paperclips-oracle,
# tools/oracle_runner.zig), then tools/compare.mjs on each pair.
#
#   tools/oracle/run.sh [--quick] [--no-build] [SCRIPT_NAME...]
#
#   --quick     skip the long scripts (deep*)
#   --no-build  use the runner already in zig-out/bin (or out/oracle/)
#   names       only these scripts (file names without .json)
#
# Outputs land in out/oracle/ (gitignored): <name>.js.json, <name>.zig.json.
# Exit status 0 when every script matches.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tools="$(dirname "$here")"
cart="$(dirname "$tools")"
root="$(cd "$cart/../.." && pwd)"
out="$cart/out/oracle"
export PATH="$HOME/.local/bin:$PATH"

quick=0
build=1
names=()
for a in "$@"; do
    case "$a" in
        --quick) quick=1 ;;
        --no-build) build=0 ;;
        -*) echo "run.sh: unknown option $a" >&2; exit 2 ;;
        *) names+=("$a") ;;
    esac
done
mkdir -p "$out"

# The Zig side: `zig build paperclips-oracle` (track U's step) when it builds
# against the real game module, else a direct build-exe of the runner.
runner="$root/zig-out/bin/paperclips-oracle"
if [ $build -eq 1 ]; then
    if (cd "$root" && zig build paperclips-oracle -Dcart=paperclips) >"$out/build.log" 2>&1; then
        :
    else
        echo "run.sh: zig build paperclips-oracle failed (see $out/build.log); building the runner directly"
        runner="$out/paperclips-oracle"
        (cd "$cart" && zig build-exe -OReleaseSafe --dep game -Mroot=tools/oracle_runner.zig \
            -Mgame=cart/src/game/game.zig -femit-bin="$runner") || { echo "run.sh: runner build FAILED"; exit 1; }
    fi
elif [ ! -x "$runner" ]; then
    runner="$out/paperclips-oracle"
fi

scripts=()
if [ ${#names[@]} -gt 0 ]; then
    for n in "${names[@]}"; do scripts+=("$here/scripts/$n.json"); done
else
    for f in "$here"/scripts/*.json; do
        b="$(basename "$f" .json)"
        [ $quick -eq 1 ] && [[ "$b" == deep* ]] && continue
        scripts+=("$f")
    done
fi
[ ${#scripts[@]} -eq 0 ] && { echo "run.sh: no scripts"; exit 2; }

# JS sides in parallel (they are the slow ones), Zig sides meanwhile.
pids=()
for f in "${scripts[@]}"; do
    b="$(basename "$f" .json)"
    node "$tools/js_oracle.mjs" "$f" -o "$out/$b.js.json" 2>"$out/$b.js.log" &
    pids+=($!)
done
zfail=0
for f in "${scripts[@]}"; do
    b="$(basename "$f" .json)"
    "$runner" "$f" -o "$out/$b.zig.json" 2>"$out/$b.zig.log" || { echo "$b: zig runner FAILED (see $out/$b.zig.log)"; zfail=1; }
done
jfail=0
for p in "${pids[@]}"; do wait "$p" || jfail=1; done
[ $jfail -eq 1 ] && echo "run.sh: a JS oracle run FAILED (see $out/*.js.log)"

status=$((zfail | jfail))
for f in "${scripts[@]}"; do
    b="$(basename "$f" .json)"
    [ -s "$out/$b.js.json" ] && [ -s "$out/$b.zig.json" ] || { status=1; continue; }
    node "$tools/compare.mjs" "$out/$b.js.json" "$out/$b.zig.json" || status=1
done
if [ $status -eq 0 ]; then echo "oracle: all ${#scripts[@]} scripts match"; else echo "oracle: MISMATCH (outputs in $out)"; fi
exit $status
