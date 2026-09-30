#!/usr/bin/env bash
# Build a cart on the fly: phone prompt -> agent-written cart -> UF2 + GIF.
#
#   build-job.sh --id ID --out DIR --prompt-file FILE|- [--name snouty-x]
#                [--no-agent] [--max-turns 40] [--max-usd 5] [--minutes 15]
#   build-job.sh --cancel ID
#   build-job.sh --self-test          # template only, into a temp dir
#
# The contract is badge-manager/PLAN.md section 9.3. The script lives in
# <repo>/badge-manager/ and works on <repo> (the main checkout or any git
# worktree of it). Everything it writes on this host goes under
# <repo>/build-jobs/ID/ (the worktree in src/, preview frames, the bench
# run, the pidfile) plus the --out directory and one local branch build/ID
# that is never pushed. Each step prints `step: <name>` when it starts and
# `step: <name> ok (<s> s)` when it ends; the agent's progress is printed as
# `agent: ...` lines. Exit codes: 0 done, 2 bad arguments or name, 3 the cart
# does not build, 4 the agent failed or hit its limits, 124 wall clock,
# 130 cancelled (1 for anything else, e.g. git failing).
#
# Caches. The worktree gets ZIG_LOCAL_CACHE_DIR=<repo>/.zig-cache (Zig reads
# the variable, so the agent's own `zig build` calls share it too) and a
# zig-pkg symlink to <repo>/zig-pkg when that exists. Zig's cache is
# content-addressed and takes file locks on its manifests, so several
# checkouts (and a concurrent build in <repo>) can share it; build.zig files
# in this repo decide only from -D options and LazyPaths, so the cached
# configure graph (keyed by build files + options) is valid for any
# checkout (docs: the zig-configure-cache note). zig-pkg holds unpacked
# packages named by their hash and is only read. Measured in PLAN 9.9: a
# cold worktree cache costs ~110 s for the first cart build, a shared warm
# one a few seconds. badge-bench's Python venv is shared the same way (a
# symlink to <repo>/badge-bench/.venv) so a job never pip-installs.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # <repo>/badge-manager
repo=$(cd "$here/.." && pwd)
export PATH="$HOME/.local/bin:$PATH"

usage() {
    sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

log() { printf '%s\n' "$*"; }
die() { local code=$1; shift; log "error: $*"; exit "$code"; }

# --- arguments ---------------------------------------------------------------

id="" out="" prompt_file="" name="" no_agent=0 max_turns=40 max_usd=5 minutes=15
mode=job cancel_id=""
while [ $# -gt 0 ]; do
    case $1 in
        --id) id=${2-}; shift 2 ;;
        --out) out=${2-}; shift 2 ;;
        --prompt-file) prompt_file=${2-}; shift 2 ;;
        --name) name=${2-}; shift 2 ;;
        --no-agent) no_agent=1; shift ;;
        --max-turns) max_turns=${2-}; shift 2 ;;
        --max-usd) max_usd=${2-}; shift 2 ;;
        --minutes) minutes=${2-}; shift 2 ;;
        --cancel) mode=cancel; cancel_id=${2-}; shift 2 ;;
        --self-test) mode=selftest; shift ;;
        -h|--help) usage ;;
        *) log "error: unknown argument: $1"; usage ;;
    esac
done

valid_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]; }
valid_name() { [[ $1 =~ ^[a-z][a-z0-9-]{2,23}$ ]]; }

# --- process tree helpers ----------------------------------------------------

descendants() {   # descendants PID: every descendant pid, deepest first
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do
        descendants "$c"
        echo "$c"
    done
}

kill_descendants() {   # kill_descendants PID [EXCEPT_PID]
    local p
    for p in $(descendants "$1"); do
        [ "$p" = "${2-}" ] && continue
        kill -TERM "$p" 2>/dev/null
    done
}

# --- --cancel ----------------------------------------------------------------

if [ "$mode" = cancel ]; then
    valid_id "$cancel_id" || die 2 "--cancel needs a job id"
    pidfile=$repo/build-jobs/$cancel_id/pid
    [ -f "$pidfile" ] || die 1 "no running job $cancel_id"
    pid=$(cat "$pidfile")
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pidfile"
        die 1 "job $cancel_id is not running"
    fi
    : > "$repo/build-jobs/$cancel_id/cancelled"
    # The job's TERM trap runs as soon as its foreground child exits, so
    # signal the job first and then take its process tree down.
    kill -TERM "$pid" 2>/dev/null
    kill_descendants "$pid"
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || { log "cancelled $cancel_id"; exit 0; }
        sleep 0.5
    done
    for p in $(descendants "$pid") "$pid"; do kill -KILL "$p" 2>/dev/null; done
    log "cancelled $cancel_id (killed)"
    exit 0
fi

# --- --self-test: the template job with no agent into a temp dir -------------

if [ "$mode" = selftest ]; then
    t=$(mktemp -d "${TMPDIR:-/tmp}/build-job-selftest.XXXXXX")
    st_id="selftest-$(date +%Y%m%d-%H%M%S)-$$"
    echo "a Snouty self-test cart" > "$t/prompt.txt"
    BUILD_JOB_SELFTEST=1 bash "${BASH_SOURCE[0]}" --id "$st_id" --out "$t/out" \
        --prompt-file "$t/prompt.txt" --name snouty-selftest --no-agent --minutes 15
    rc=$?
    git -C "$repo" branch -D "build/$st_id" >/dev/null 2>&1
    rm -rf "$repo/build-jobs/$st_id"
    if [ $rc -eq 0 ]; then
        for f in snouty-selftest.uf2 preview.gif bench.txt summary.json cart.tar.gz; do
            [ -s "$t/out/$f" ] || { log "self-test: FAIL: out/$f missing"; rc=1; }
        done
    fi
    rm -rf "$t"
    if [ $rc -eq 0 ]; then log "self-test: PASS"; else log "self-test: FAIL (exit $rc)"; fi
    exit $rc
fi

# --- job: validate -----------------------------------------------------------

[ -n "$id" ] && [ -n "$out" ] && [ -n "$prompt_file" ] || usage
valid_id "$id" || die 2 "bad --id '$id' (letters, digits, . _ -)"
[[ $max_turns =~ ^[0-9]+$ ]] && [ "$max_turns" -gt 0 ] || die 2 "bad --max-turns '$max_turns'"
[[ $max_usd =~ ^[0-9]+([.][0-9]+)?$ ]] || die 2 "bad --max-usd '$max_usd'"
[[ $minutes =~ ^[0-9]+$ ]] && [ "$minutes" -gt 0 ] || die 2 "bad --minutes '$minutes'"
if [ -n "$name" ]; then
    valid_name "$name" || die 2 "bad --name '$name': must match [a-z][a-z0-9-]{2,23}"
fi

job=$repo/build-jobs/$id
if [ -f "$job/pid" ] && kill -0 "$(cat "$job/pid")" 2>/dev/null; then
    die 2 "job $id is already running"
fi
git -C "$repo" rev-parse --verify --quiet "refs/heads/build/$id" >/dev/null \
    && die 2 "branch build/$id already exists"
[ -e "$job/src" ] && die 2 "$job/src already exists (a previous job $id did not clean up)"

mkdir -p "$job" "$out" || die 1 "cannot create $job or $out"
out=$(cd "$out" && pwd)
if [ "$prompt_file" = - ]; then
    cat > "$job/prompt.txt"
elif [ -f "$prompt_file" ]; then
    cp "$prompt_file" "$job/prompt.txt"
else
    die 2 "no prompt file $prompt_file"
fi
prompt=$(cat "$job/prompt.txt")
prompt_trim=$(printf '%s' "$prompt" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
[ -n "$prompt_trim" ] || die 2 "empty prompt"
[ ${#prompt} -le 2000 ] || die 2 "prompt is ${#prompt} characters (limit 2000)"

# Commits need an identity; a fresh Pi may have none configured.
if [ -z "$(git -C "$repo" config user.email)" ]; then
    export GIT_AUTHOR_NAME="badge station" GIT_AUTHOR_EMAIL="badge-station@localhost"
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
fi

echo $$ > "$job/pid"
rm -f "$job/cancelled" "$job/timeout"
job_t0=$(date +%s)
src=$job/src
worktree_added=0
committed=0
template_rev=""
agent_turns=None
agent_usd=None
bench_ms=None

# --- cleanup, cancel, wall clock ---------------------------------------------

commit_worktree() {   # commit_worktree MESSAGE: commit the cart to build/ID once
    [ $worktree_added -eq 1 ] && [ $committed -eq 0 ] || return 0
    [ -n "$template_rev" ] || return 0   # nothing of ours in the worktree yet
    git -C "$src" add -A -- "carts/$name" build.zig >/dev/null 2>&1
    git -C "$src" commit -q --no-verify -m "$1" >/dev/null 2>&1
    git -C "$repo" branch -f "build/$id" "$(git -C "$src" rev-parse HEAD)" >/dev/null 2>&1 \
        && committed=1 && log "branch: build/$id"
}

remove_worktree() {
    [ $worktree_added -eq 1 ] || return 0
    git -C "$repo" worktree remove --force "$src" >/dev/null 2>&1 || rm -rf "$src"
    git -C "$repo" worktree prune >/dev/null 2>&1
    worktree_added=0
}

finish() {   # finish CODE: keep what the agent wrote, drop the scratch, exit
    local code=$1
    trap - TERM INT HUP EXIT
    kill_descendants $$   # the watchdog and its sleep too
    commit_worktree "build $id: $name (failed, exit $code)" || true
    remove_worktree
    rm -rf "$job/preview" "$job/bench" "$job/agent.stream"
    rm -f "$job/pid"
    # A local job's out/ lives in the library: nothing here is needed any
    # more. A remote job's out/ is under build-jobs/ID and the station
    # removes the directory after copying it.
    case $out/ in "$job"/*) ;; *) rm -rf "$job" ;; esac
    exit "$code"
}

on_signal() {
    if [ -e "$job/timeout" ]; then
        log "error: wall clock: the job ran longer than --minutes $minutes"
        finish 124
    fi
    log "error: cancelled"
    finish 130
}
trap on_signal TERM INT HUP
trap 'finish $?' EXIT

(
    sleep $((minutes * 60))
    : > "$job/timeout"
    kill -TERM $$ 2>/dev/null
    kill_descendants $$ "$BASHPID"
) &
watchdog=$!

step_name="" step_t0=0
step() { step_name=$1; step_t0=$(date +%s); log "step: $1"; }
step_ok() { log "step: $step_name ok ($(( $(date +%s) - step_t0 )) s)"; }

# Runs a command in the background and waits, so a TERM from --cancel or the
# watchdog is handled at once instead of after the command ends.
run() { "$@" & local p=$!; wait "$p"; }

log "job: $id on $(hostname) repo $repo"
log "prompt: $(printf '%s' "$prompt_trim" | cut -c1-200)"

# --- 1. worktree -------------------------------------------------------------

step worktree
if run timeout 60 git -C "$repo" fetch -q origin main 2>&1; then
    base=origin/main
else
    log "git fetch origin main failed (offline?): building from local main"
    base=main
fi
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || base=origin/main
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die 1 "no main or origin/main in $repo"
log "base: $base $(git -C "$repo" rev-parse --short "$base")"
run git -C "$repo" worktree add -q --detach "$src" "$base" || die 1 "git worktree add failed"
worktree_added=1

common=$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)
gitdir=$(cd "$repo" && cd "$(git rev-parse --git-dir)" && pwd)
ref=""
for r in "$common/modules/sycl-badge" "$gitdir/modules/sycl-badge"; do
    [ -d "$r/objects" ] && { ref=$r; break; }
done
if [ -n "$ref" ]; then
    run git -C "$src" submodule update -q --init --reference "$ref" || die 1 "submodule update failed"
else
    log "no local sycl-badge objects to reference; cloning the submodule"
    run git -C "$src" submodule update -q --init || die 1 "submodule update failed"
fi

export ZIG_LOCAL_CACHE_DIR=$repo/.zig-cache
export ZIG_FLAGS="--cache-dir $ZIG_LOCAL_CACHE_DIR"
[ -d "$repo/zig-pkg" ] && ln -s "$repo/zig-pkg" "$src/zig-pkg"
[ -d "$repo/badge-bench/.venv" ] && ln -s "$repo/badge-bench/.venv" "$src/badge-bench/.venv"
step_ok

# --- 2. name -----------------------------------------------------------------

step name
taken() { [ -e "$src/carts/$1" ] || grep -q "\"$1\"" "$src/build.zig"; }
if [ -n "$name" ]; then
    taken "$name" && die 2 "cart name $name is taken (carts/$name or the root build.zig)"
else
    slug=$(printf '%s' "$prompt_trim" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' ' ' | python3 -c '
import sys
stop = set("""a an the and or of in on at to for with where that which who is are be
    it its as by from into this my your our me i we you snouty snout cart game
    badge make build create please some very little small simple""".split())
words = [w for w in sys.stdin.read().split() if w not in stop and w[0].isalpha()]
out = ""
for w in words[:3]:
    cand = (out + "-" + w) if out else w
    if len("snouty-" + cand) > 24:
        break
    out = cand
print(out or "cart")')
    base_name="snouty-$slug"
    base_name=${base_name:0:24}
    base_name=${base_name%-}
    name=$base_name
    n=2
    while taken "$name"; do
        suffix="-$n"
        name="${base_name:0:$((24 - ${#suffix}))}"
        name="${name%-}$suffix"
        n=$((n + 1))
    done
    valid_name "$name" || die 2 "could not derive a cart name from the prompt (got '$name'); pass --name"
fi
log "name: $name"
step_ok

# --- 3. template -------------------------------------------------------------

step "template builds"
cp -r "$here/template-cart" "$src/carts/$name" || die 1 "cannot copy the template"
rm -rf "$src/carts/$name/zig-out" "$src/carts/$name/.zig-cache" "$src/carts/$name/preview"
find "$src/carts/$name" -type f \( -name '*.zig' -o -name '*.md' -o -name '.gitignore' \) \
    -exec sed -i "s/__NAME__/$name/g" {} +
python3 - "$src/build.zig" "$name" <<'PY' || die 1 "cannot register $name in build.zig"
import sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
entry = f'    .{{ .dir = "{name}", .binary = "{name}", .add = &@import("carts/{name}/build.zig").add }},'
at = next(i for i, l in enumerate(lines) if '.dir = "badge-calibrate"' in l)
lines.insert(at, entry)
open(path, "w").write("\n".join(lines))
PY
# The template commit: the agent's changes are measured (and reverted) from here.
git -C "$src" add -A -- "carts/$name" build.zig
git -C "$src" commit -q --no-verify -m "build $id: $name from badge-manager/template-cart" \
    || die 1 "cannot commit the template"
template_rev=$(git -C "$src" rev-parse HEAD)
cart_modes=ram
[ -n "${BUILD_JOB_SELFTEST:-}" ] && cart_modes=both   # the self-test proves XIP too
(cd "$src" && run zig build -Dcart="$name" -Dcart-mode=$cart_modes 2>&1) || die 3 "the template does not build"
step_ok

# --- 4. agent ----------------------------------------------------------------

agent_filter=$(cat <<'PY'
import json, sys
result_path = sys.argv[1]
def say(s):
    s = " ".join(str(s).split())
    if s:
        print("agent: " + s[:200], flush=True)
def target(name, inp):
    for k in ("file_path", "path", "pattern", "command"):
        if k in inp:
            v = str(inp[k])
            return v.split("\n")[0][:160]
    return ""
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except ValueError:
        say(raw)
        continue
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        say(f"session {ev.get('model', '?')}, tools: {', '.join(ev.get('tools', []))}")
    elif t == "assistant":
        for block in ev.get("message", {}).get("content", []):
            if block.get("type") == "text":
                say(block.get("text", ""))
            elif block.get("type") == "tool_use":
                inp = block.get("input", {}) or {}
                say(f"{block.get('name')} {target(block.get('name'), inp)}")
    elif t == "user":
        content = ev.get("message", {}).get("content", [])
        if isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_result" and block.get("is_error"):
                    c = block.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                    say(f"tool error: {c}")
    elif t == "result":
        json.dump(ev, open(result_path, "w"))
        for d in ev.get("permission_denials", []) or []:
            say(f"denied {d.get('tool_name')} {target(d.get('tool_name'), d.get('tool_input', {}) or {})}")
        say(f"done: {ev.get('subtype')}, {ev.get('num_turns')} turns, "
            f"${ev.get('total_cost_usd', 0):.2f}, {ev.get('duration_ms', 0) / 1000:.0f} s")
PY
)

if [ $no_agent -eq 1 ]; then
    log "agent: skipped (--no-agent)"
else
    step agent
    skill=$repo/.claude/skills/new-cart/SKILL.md
    [ -f "$skill" ] || die 1 "no $skill"
    {
        # The brief without its frontmatter, then the request.
        awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$skill"
        printf '\n## The request\n\n%s\n' "$prompt"
    } | sed "s/__NAME__/$name/g; s/__ID__/$id/g" > "$job/agent-prompt.md"
    agent_rc=0
    (
        cd "$src" && claude -p \
            --output-format stream-json --verbose \
            --permission-mode acceptEdits --permission-prompts none \
            --tools "Read,Edit,Write,Glob,Grep,Bash" \
            --allowedTools "Read" "Edit" "Write" "Glob" "Grep" \
                "Bash(zig build *)" "Bash(node tools/preview.mjs *)" \
                "Bash(python3 tools/make_gif.py *)" "Bash(ls *)" \
            --strict-mcp-config --no-session-persistence \
            --max-turns "$max_turns" --max-budget-usd "$max_usd" \
            ${BUILD_JOB_MODEL:+--model "$BUILD_JOB_MODEL"} \
            < "$job/agent-prompt.md" 2> "$job/agent.stderr" \
            | tee "$job/agent.stream" | python3 -u -c "$agent_filter" "$job/agent-result.json"
        exit "${PIPESTATUS[0]}"
    ) &
    wait $! || agent_rc=$?
    if [ -s "$job/agent.stderr" ]; then
        sed 's/^/agent: stderr: /' "$job/agent.stderr" | tail -5 | cut -c1-220
    fi
    subtype=missing
    if [ -s "$job/agent-result.json" ]; then
        read -r agent_turns agent_usd subtype < <(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
print(r.get("num_turns"), r.get("total_cost_usd"), r.get("subtype") or "?")' "$job/agent-result.json")
    fi

    # Keep only the cart: revert every change outside carts/NAME/ (including
    # build.zig, whose registry line is already in the template commit).
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path=${line:3}
        case $path in
            "carts/$name"/*|zig-pkg|badge-bench/.venv) continue ;;
        esac
        if git -C "$src" cat-file -e "HEAD:$path" 2>/dev/null; then
            git -C "$src" checkout -q HEAD -- "$path"
            log "reverted: $path (outside carts/$name/)"
        else
            rm -rf "${src:?}/$path"
            log "removed: $path (outside carts/$name/)"
        fi
    done < <(git -C "$src" status --porcelain --untracked-files=all)

    if [ "$agent_rc" -ne 0 ] || [ "$subtype" != success ]; then
        die 4 "the agent stopped: ${subtype} (exit $agent_rc)"
    fi
    step_ok
fi

# --- 5. rebuild --------------------------------------------------------------

step build
(cd "$src" && run zig build -Dcart="$name" 2>&1) || die 3 "the cart does not build"
for f in "zig-out/bin/$name.wasm" "zig-out/firmware/$name.elf" "zig-out/firmware/$name.uf2"; do
    [ -s "$src/$f" ] || die 3 "the build did not produce $f"
done
step_ok

# --- 6. preview --------------------------------------------------------------

press=(--press A:60-120 --press LEFT:130-165 --press RIGHT:175-225)
step preview
rm -rf "$job/preview"
(cd "$src" && run node tools/preview.mjs "zig-out/bin/$name.wasm" --frames 240 --every 4 \
    "${press[@]}" --out "$job/preview" 2>&1 | tail -3) || die 3 "the preview failed"
ls "$job/preview"/frame_*.png >/dev/null 2>&1 || die 3 "the preview wrote no frames (the cart traps on wasm?)"
(cd "$src" && run python3 tools/make_gif.py "$job/preview" "$out/preview.gif" --scale 2 --ms 66 2>&1) \
    || die 3 "make_gif failed"
last=$(ls "$job/preview"/frame_*.png | tail -1)
cp "$last" "$out/preview.png"
step_ok

# --- 7. bench ----------------------------------------------------------------

step bench
(cd "$src" && run bash badge-bench/bench.sh "zig-out/firmware/$name.elf" --frames 300 --every 30 \
    "${press[@]}" --json --out "$job/bench" > "$job/bench.out" 2>&1) || {
    tail -5 "$job/bench.out"; die 3 "the bench failed"; }
cp "$job/bench.out" "$out/bench.txt"
bench_ms=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
frames = d.get("frames") or []
key = "busy_ms" if frames and "busy_ms" in frames[0] else "ms"
print(round(max(f[key] for f in frames), 2) if frames else None)' "$job/bench/bench.json") \
    || die 3 "cannot read bench.json"
grep -E '^ +(idle|busy) ms ' "$job/bench.out"
log "bench: worst $bench_ms ms (budget 16.7)"
step_ok

# --- 8. package --------------------------------------------------------------

step package
python3 "$src/tools/uf2_info.py" "$src/zig-out/firmware/$name.uf2" || die 3 "the UF2 fails uf2_info"
cp "$src/zig-out/firmware/$name.uf2" "$out/$name.uf2"
size=$(stat -c %s "$out/$name.uf2")
commit_worktree "build $id: $name

Prompt: $prompt_trim"
[ $committed -eq 1 ] || die 1 "cannot commit the cart to build/$id"
git -C "$repo" archive --format=tar.gz -o "$out/cart.tar.gz" "build/$id" "carts/$name" \
    || die 1 "cannot archive the cart"
files_json=$(git -C "$repo" ls-tree -r --name-only "build/$id" "carts/$name" \
    | python3 -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
agent_summary=$src/carts/$name/summary.json
[ -f "$agent_summary" ] && cp "$agent_summary" "$job/agent-summary.json"
remove_worktree
step_ok

# --- 9. summary --------------------------------------------------------------

where=local
[ -n "${SSH_CONNECTION:-}" ] && where=remote
seconds=$(( $(date +%s) - job_t0 ))
python3 - "$out/summary.json" "$job/agent-summary.json" <<PY || die 1 "cannot write summary.json"
import json, sys
out, agent_summary = sys.argv[1], sys.argv[2]
prompt = open("$job/prompt.txt").read().strip()
title, description, controls = "$name", prompt, None
try:
    s = json.load(open(agent_summary))
    title = str(s.get("title") or title)[:20]
    description = str(s.get("description") or description)
    controls = s.get("controls")
except (OSError, ValueError, AttributeError):
    pass
json.dump({
    "name": "$name", "title": title, "description": description, "controls": controls,
    "prompt": prompt, "where": "$where", "seconds": $seconds,
    "agent_turns": $agent_turns, "agent_usd": $agent_usd,
    "bench_ms": $bench_ms, "size": $size,
    "files": $files_json, "branch": "build/$id",
}, open(out, "w"), indent=2)
PY
log "done: $name in $seconds s, worst $bench_ms ms, $size bytes, branch build/$id"
finish 0
