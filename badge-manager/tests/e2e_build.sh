#!/bin/bash
# End-to-end: build-job.sh on this checkout, without the agent.
#
#   badge-manager/tests/e2e_build.sh
#
# 1. `build-job.sh --self-test` (the template copied, registered and built in
#    RAM and XIP modes, previewed, benchmarked, packaged).
# 2. A full `--no-agent` job with this checkout as the repo into a temp out
#    dir, then checks out/: the UF2 passes tools/uf2_info.py as a RAM cart,
#    preview.gif is a GIF, bench.txt has the busy-ms summary, summary.json
#    has every key of PLAN.md 9.3 step 9 and names the cart, and the local
#    branch build/ID exists with the cart on it. Cleans up the branch and
#    build-jobs/ID. Needs Zig, Node and Python 3 (Pillow); a few minutes on
#    a warm cache.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)     # badge-manager/
repo=$(cd "$here/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/badge-e2e-build.XXXXXX")
id="e2e-$(date +%Y%m%d-%H%M%S)-$$"
name="snouty-e2e-$$"
name=${name:0:24}
cleanup() {
    git -C "$repo" branch -D "build/$id" >/dev/null 2>&1
    rm -rf "$repo/build-jobs/$id" "$t"
}
trap cleanup EXIT
fail() { echo "e2e: FAIL: $*"; exit 1; }

echo "e2e: self-test"
bash "$here/build-job.sh" --self-test || fail "build-job.sh --self-test"

echo "e2e: --no-agent job $id ($name)"
echo "a Snouty cart where a square dodges falling blocks" > "$t/prompt.txt"
t0=$(date +%s)
bash "$here/build-job.sh" --id "$id" --out "$t/out" --prompt-file - --name "$name" \
    --no-agent < "$t/prompt.txt" | tee "$t/job.log"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || fail "build-job.sh exited $rc"
echo "e2e: job took $(( $(date +%s) - t0 )) s"

out=$t/out
for f in "$name.uf2" preview.gif preview.png bench.txt summary.json cart.tar.gz; do
    [ -s "$out/$f" ] || fail "out/$f is missing or empty"
done
python3 "$repo/tools/uf2_info.py" "$out/$name.uf2" | tee "$t/uf2.txt" || fail "uf2_info rejects the UF2"
grep -q "RAM cart" "$t/uf2.txt" || fail "the UF2 is not a RAM cart"
[ "$(head -c 6 "$out/preview.gif")" = GIF89a ] || fail "preview.gif is not a GIF"
grep -q "busy ms" "$out/bench.txt" || fail "bench.txt has no busy ms summary"
grep -q '^step: agent' "$t/job.log" && fail "--no-agent ran the agent"
for s in worktree name "template builds" build preview bench package; do
    grep -Eq "^step: $s ok \([0-9]+ s\)$" "$t/job.log" || fail "no 'step: $s ok' line"
done
python3 - "$out/summary.json" "$name" "$id" <<'PY' || fail "summary.json"
import json, sys
s, name, job = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
want = {"name", "title", "description", "prompt", "where", "seconds", "agent_turns",
        "agent_usd", "bench_ms", "size", "files", "branch"}
missing = want - set(s)
assert not missing, f"missing keys {sorted(missing)}"
assert s["name"] == name, s["name"]
assert s["branch"] == f"build/{job}", s["branch"]
assert s["title"] == name and s["description"].startswith("a Snouty cart"), (s["title"], s["description"])
assert s["agent_turns"] is None and s["agent_usd"] is None
assert isinstance(s["bench_ms"], float) and 0 < s["bench_ms"] < 16.7, s["bench_ms"]
assert s["size"] > 512 and s["size"] % 512 == 0, s["size"]
assert f"carts/{name}/cart/src/main.zig" in s["files"], s["files"]
print(f"e2e: summary ok: bench {s['bench_ms']} ms, {s['size']} bytes, {len(s['files'])} files, {s['seconds']} s")
PY
git -C "$repo" rev-parse --verify --quiet "refs/heads/build/$id" >/dev/null || fail "no branch build/$id"
git -C "$repo" cat-file -e "build/$id:carts/$name/cart/src/main.zig" || fail "the cart is not on build/$id"
git -C "$repo" show "build/$id:build.zig" | grep -q "\"$name\"" || fail "build.zig on build/$id does not register $name"
tar -tzf "$out/cart.tar.gz" | grep -q "carts/$name/cart/src/main.zig" || fail "cart.tar.gz lacks main.zig"
[ -e "$repo/build-jobs/$id/src" ] && fail "the job worktree was not removed"
git -C "$repo" worktree list | grep -q "build-jobs/$id" && fail "the job worktree is still registered"
echo "e2e: PASS"
