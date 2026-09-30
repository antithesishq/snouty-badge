#!/bin/bash
# Stand-in for badge-manager/build-job.sh in the unit tests (PLAN.md 9.3).
#
#   fake_build_job.sh --id ID --out DIR --prompt-file FILE|- [--name NAME] [--no-agent]
#                     [--max-turns N] [--max-usd N] [--minutes N]
#   fake_build_job.sh --cancel ID
#
# Prints a few `step:` and `agent:` lines, then writes DIR/NAME.uf2 (a valid
# RAM cart), preview.gif, bench.txt and summary.json. Environment:
#   FAKE_BUILD_FAIL=N     exit N after the steps, writing nothing
#   FAKE_BUILD_SLOW=S     sleep S seconds before finishing (wall clock, cancel)
#   FAKE_BUILD_UF2=PATH   copy this UF2 instead of generating one
#   FAKE_BUILD_BAD_UF2=1  write a UF2 that fails tools/uf2_info.py
#   FAKE_BUILD_STEP=S     pause between lines (default 0.02)
set -euo pipefail

id="" out="" prompt_file="" name="" no_agent=0 cancel=""
while [ $# -gt 0 ]; do
    case "$1" in
        --id) id=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --prompt-file) prompt_file=$2; shift 2 ;;
        --name) name=$2; shift 2 ;;
        --no-agent) no_agent=1; shift ;;
        --max-turns|--max-usd|--minutes) shift 2 ;;
        --cancel) cancel=$2; shift 2 ;;
        *) echo "fake-build: unknown argument $1"; exit 2 ;;
    esac
done
if [ -n "$cancel" ]; then
    echo "fake-build: cancel $cancel"
    exit 0
fi
if [ -z "$id" ] || [ -z "$out" ] || [ -z "$prompt_file" ]; then
    echo "fake-build: need --id, --out and --prompt-file"
    exit 2
fi
if [ "$prompt_file" = - ]; then prompt=$(cat); else prompt=$(cat "$prompt_file"); fi
name=${name:-snouty-fake}

say() { echo "$*"; sleep "${FAKE_BUILD_STEP:-0.02}"; }
say "step: worktree ready (0 s)"
say "step: template builds (0 s)"
if [ "$no_agent" = 0 ]; then
    say "agent: reading the request: ${prompt:0:40}"
    say "agent: Edit carts/$name/cart/src/main.zig"
fi
if [ -n "${FAKE_BUILD_SLOW:-}" ]; then
    say "step: thinking for ${FAKE_BUILD_SLOW} s"
    sleep "$FAKE_BUILD_SLOW"
fi
if [ -n "${FAKE_BUILD_FAIL:-}" ]; then
    echo "error: fake failure"
    exit "$FAKE_BUILD_FAIL"
fi
say "step: cart builds (0 s)"

mkdir -p "$out"
if [ -n "${FAKE_BUILD_UF2:-}" ]; then
    cp "$FAKE_BUILD_UF2" "$out/$name.uf2"
fi
FAKE_OUT=$out FAKE_NAME=$name FAKE_ID=$id FAKE_PROMPT=$prompt python3 - <<'PY'
import json, os, struct
out, name = os.environ["FAKE_OUT"], os.environ["FAKE_NAME"]
uf2 = os.path.join(out, name + ".uf2")
if os.environ.get("FAKE_BUILD_BAD_UF2"):
    open(uf2, "wb").write(b"not a uf2" * 60)
elif not os.path.exists(uf2):
    blocks, data = 8, bytearray()
    for i in range(blocks):          # cart RAM window, like tests/helpers.make_uf2
        b = bytearray(512)
        struct.pack_into("<8I", b, 0, 0x0A324655, 0x9E5D5157, 0x2000,
                         0x20035100 + 256 * i, 256, i, blocks, 0xE48BFF59)
        struct.pack_into("<I", b, 508, 0x0AB16F30)
        data += b
    open(uf2, "wb").write(bytes(data))
gif = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00"
       b"\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
open(os.path.join(out, "preview.gif"), "wb").write(gif)
open(os.path.join(out, "bench.txt"), "w").write("worst busy 4.2 ms over 300 frames\n")
summary = {"name": name, "title": "Fake " + name[len("snouty-"):].title(),
           "description": os.environ["FAKE_PROMPT"], "prompt": os.environ["FAKE_PROMPT"],
           "where": "local", "seconds": 1, "agent_turns": 2, "agent_usd": 0.01,
           "bench_ms": 4.2, "size": os.path.getsize(uf2), "files": [name + ".uf2"],
           "branch": "build/" + os.environ["FAKE_ID"]}
open(os.path.join(out, "summary.json"), "w").write(json.dumps(summary, indent=1))
PY
say "step: preview and bench (0 s)"
echo "step: done"
