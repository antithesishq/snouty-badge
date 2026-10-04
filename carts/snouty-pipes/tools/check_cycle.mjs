#!/usr/bin/env node
// Screensaver-loop and steer mode check (M1..M3): runs the cart headless through the shared
// ../../tools/preview.mjs and asserts on the debug exports (PLAN.md Track B
// item 4) after the last update, at fixed ticks, and over per-tick samples.
//
//   node tools/check_cycle.mjs [--wasm ../../zig-out/bin/snouty-pipes.wasm] [--only A,B,...]
//                              [--seed S] [--cap N]
//
// Runs (each one `node ../../tools/preview.mjs <wasm> --quiet --seed S --frames F
// [--call ...] [--press ...] [--sample ...] --dump-exports ... --expect ...`):
//   A  boot: 2 updates; debug_state == 0 (BOOT), debug_scene == 1, the name
//      strip is up (debug_name_strip == 1).
//   B  boot -> grow: 150 updates (the boot state lasts 120 ticks while the
//      first pipes grow); debug_state == 1 (GROW), name strip gone, at least
//      one living pipe, cells filled, pipes started.
//   C  unattended scene cycle: no input, runs until debug_scene >= 2 (cap
//      --cap, default 5000 updates: the 75 s scene cap is 4500 ticks, plus
//      the 60-tick dissolve and slack). Samples every tick: a DISSOLVE (2)
//      state comes before the second scene, the new scene grows (state 1)
//      with another view, debug_filled never exceeds the 1440 cells and
//      debug_cmds never exceeds the 64-entry command list.
//   D  A dissolves now: A at tick 200 (GROW); DISSOLVE at tick 230; at tick
//      299 the next scene grows (debug_scene == 2, state 1) from a nearly
//      empty grid with another view.
//   E  forced teapot: --call debug_force_teapot, 900 updates; debug_teapots
//      >= 1 (the next turn of any pipe is a teapot and gets drawn).
//   F  determinism: two 400-update runs with seed S give the same
//      debug_pixel_checksum; seed S + 1 gives another picture.
// The SPEC section 6 controls (M2 in the SPEC, built with M1's director):
//   G  pause: Start at 200 and 300; paused at 250, debug_filled frozen from
//      201 to 299, growing again by 399.
//   H  the OS chord: Start+Select held 200..260 neither pauses nor anything
//      else (newer firmware opens its settings box over the cart).
//   I  orbit: Right at 300; REBUILD (3) with orbit 1 at 301, GROW again by
//      449 with no cells lost.
//   J  B shows the nametag (the joint style stays mixed, 0); Up, Up, Down:
//      debug_speed 2 (2x).
// The nametag (B in the screensaver, M3):
//   K  B at tick 60, over the boot strip: the nametag replaces it
//      (debug_nametag 1, debug_name_strip 0); its Iris mark flips like a
//      coin 45 ticks later (debug_iris_width < 24 somewhere in 105..135, 24
//      before); A at 150 dissolves and the nametag stays; B at 300 hides it.
// Steer mode (M3; states 4 steer, 5 rewind, 6 game over):
//   L  Select at 150: DISSOLVE, then a run in READY by 215 (debug_steer 1,
//      score 0, one rewind) with debug_steer_map a permutation of the six
//      grid directions, opposite controls opposite.
//   M  a scripted path survives: tools/scripts/steer_survive.json (written
//      by tools/steer_bot.mjs for seed 1) steers 1400 ticks with no crash,
//      score >= 60.
//   N  no steering: the pipe hits the wall, REWIND (5), steers again (4)
//      with the score back by up to 6 cells and the rewind spent, hits the
//      wall again: GAME OVER (6), best = score; A at 900 starts a fresh run
//      (score 0, rewind back, 0 crashes); Select at 1100 leads back to the
//      screensaver (GROW by 1170, debug_steer 0).
// Every run dumps state, tick, scene, filled, alive, pipes, view, teapots
// and prints them with the result.
//
// Exit codes: 0 all PASS, 2 usage error, 3 any FAIL (including a preview run
// that exited non-zero for another reason, e.g. a missing export).
// No npm dependencies.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."); // this cart
const REPO = path.resolve(ROOT, "../.."); // repository root, where zig build writes zig-out/
const PREVIEW = path.join(REPO, "tools", "preview.mjs");
const OUT_DIR = path.join(ROOT, "out", "cycle");
const STATE_NAMES = ["BOOT", "GROW", "DISSOLVE", "REBUILD", "STEER", "REWIND", "GAME_OVER"];
const CELLS = 12 * 10 * 12; // grid.cell_count
const MAX_CMDS = 64; // director.max_cmds
const DUMP = ["debug_state", "debug_tick", "debug_scene", "debug_filled", "debug_alive", "debug_pipes", "debug_view", "debug_teapots"];

function usage(msg) {
    if (msg) console.error(`check_cycle: ${msg}`);
    console.error("usage: node tools/check_cycle.mjs [--wasm FILE] [--only A,B,...,N] [--seed S] [--cap N]");
    process.exit(2);
}

const opts = { wasm: path.join(REPO, "zig-out", "bin", "snouty-pipes.wasm"), only: null, seed: 1, cap: 5000 };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = (s, min) => { const n = Number(s); if (!Number.isInteger(n) || n < min) usage(`${a}: bad integer '${s}'`); return n; };
    switch (a) {
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "--only": (opts.only ??= []).push(...val().split(",").map((s) => s.trim().toUpperCase()).filter(Boolean)); break;
        case "--seed": opts.seed = int(val(), 0); break;
        case "--cap": opts.cap = int(val(), 1); break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}

// Samples: frames.json "samples" = { every, ticks: [...], values: { NAME: [...] } }.
const series = (meta, name) => meta?.samples?.values?.[name] ?? null;
const max = (xs) => xs.reduce((m, x) => Math.max(m, x), -Infinity);

// Each run: frames, --call list, --press list, extra exports to dump, --expect
// and --at lists, --until, --sample list, and an optional `check(values,
// meta)` for what --expect cannot say (it returns an error string or null).
const RUNS = [
    {
        name: "A", what: "boot: name strip up, first scene", frames: 2, dump: ["debug_name_strip"],
        expect: ["debug_state == 0", "debug_scene == 1", "debug_name_strip == 1"],
    },
    {
        name: "B", what: "boot hands over to grow by tick 150", frames: 150, dump: ["debug_name_strip"],
        expect: ["debug_state == 1", "debug_name_strip == 0", "debug_alive >= 1", "debug_filled >= 1", "debug_pipes >= 1"],
    },
    {
        name: "C", what: `unattended: dissolve, then scene 2 grows (cap ${opts.cap} ticks)`, frames: opts.cap,
        until: "debug_scene >= 2", sample: ["debug_state", "debug_scene", "debug_filled", "debug_view", "debug_cmds"],
        expect: ["debug_scene >= 2"],
        check: (v, meta) => {
            const st = series(meta, "debug_state"), sc = series(meta, "debug_scene"), fi = series(meta, "debug_filled");
            const vw = series(meta, "debug_view"), cm = series(meta, "debug_cmds");
            if (!st || !sc || !fi || !vw || !cm) return "samples missing from frames.json";
            const first2 = sc.findIndex((s) => s >= 2);
            if (first2 < 0) return "scene 2 never started";
            if (!st.slice(0, first2).includes(2)) return "no DISSOLVE state before scene 2";
            if (st[st.length - 1] !== 1 && st[st.length - 1] !== 0) return `scene 2 starts in state ${st[st.length - 1]}, not GROW`;
            if (max(fi) > CELLS) return `debug_filled reached ${max(fi)} > ${CELLS} cells`;
            if (max(cm) > MAX_CMDS) return `debug_cmds reached ${max(cm)} > ${MAX_CMDS}`;
            if (vw[first2] === vw[0]) return `scene 2 reuses view ${vw[0]}`;
            const end1 = st.indexOf(2);
            return `info: scene 1 ended at tick ${end1} with ${fi[end1 - 1]} cells (${(100 * fi[end1 - 1] / CELLS).toFixed(0)}%), scene 2 at tick ${first2}, views ${vw[0]} -> ${vw[first2]}, max cmds ${max(cm)}`;
        },
    },
    {
        name: "D", what: "A at tick 200 dissolves, scene 2 grows by tick 299", frames: 300, press: ["A:200-200"],
        at: ["230 debug_state == 2"], sample: ["debug_view"],
        expect: ["debug_scene == 2", "debug_state == 1", "debug_filled < 100"],
        check: (v, meta) => {
            const vw = series(meta, "debug_view");
            if (!vw) return "samples missing from frames.json";
            return vw[199] === vw[299] ? `the new scene reuses view ${vw[199]}` : null;
        },
    },
    {
        name: "E", what: "debug_force_teapot: a teapot is drawn within 900 ticks", frames: 900, calls: ["debug_force_teapot"],
        expect: ["debug_teapots >= 1"],
    },
    {
        name: "G", what: "Start at tick 200 pauses: nothing grows until Start at 300", frames: 400,
        press: ["START:200-200", "START:300-300"], sample: ["debug_filled", "debug_paused"],
        at: ["250 debug_paused == 1"], expect: ["debug_paused == 0"],
        check: (v, meta) => {
            const fi = series(meta, "debug_filled");
            if (!fi) return "samples missing from frames.json";
            if (fi[201] !== fi[299]) return `filled moved while paused (${fi[201]} -> ${fi[299]})`;
            return fi[399] > fi[299] ? null : "nothing grew after unpausing";
        },
    },
    {
        name: "H", what: "Start+Select held 200..260 (the OS chord): the cart ignores both", frames: 300,
        press: ["START:200-260", "SELECT:200-260"], dump: ["debug_paused", "debug_steer"],
        expect: ["debug_paused == 0", "debug_state == 1", "debug_steer == 0"],
    },
    {
        name: "I", what: "Right at tick 300 orbits: REBUILD, then GROW again from orbit 1", frames: 450,
        press: ["RIGHT:300-300"], dump: ["debug_orbit", "debug_history"], sample: ["debug_filled"],
        at: ["301 debug_state == 3", "301 debug_orbit == 1"], expect: ["debug_state == 1", "debug_orbit == 1"],
        check: (v, meta) => {
            const fi = series(meta, "debug_filled");
            if (!fi) return "samples missing from frames.json";
            return fi[449] >= fi[299] ? null : `the orbit lost cells (${fi[299]} -> ${fi[449]})`;
        },
    },
    {
        name: "J", what: "B shows the nametag (joint style stays mixed), Up Up Down leaves 2x", frames: 100,
        press: ["B:10-10", "UP:20-20", "UP:30-30", "DOWN:40-40"], dump: ["debug_nametag", "debug_joint_style", "debug_speed"],
        expect: ["debug_nametag == 1", "debug_joint_style == 0", "debug_speed == 2"],
    },
    {
        name: "K", what: "B over the boot strip: nametag, coin flip at +45, kept through A, B hides it", frames: 320,
        press: ["B:60-60", "A:150-150", "B:300-300"], dump: ["debug_nametag", "debug_iris_width"],
        sample: ["debug_nametag", "debug_name_strip", "debug_iris_width", "debug_state"],
        at: ["59 debug_name_strip == 1", "61 debug_nametag == 1", "61 debug_name_strip == 0", "299 debug_nametag == 1"],
        expect: ["debug_nametag == 0", "debug_iris_width == 24"],
        check: (v, meta) => {
            const w = series(meta, "debug_iris_width"), st = series(meta, "debug_state");
            if (!w || !st) return "samples missing from frames.json";
            if (Math.min(...w.slice(60, 105)) !== 24) return `the mark flipped before tick 105 (${w.slice(60, 105)})`;
            const dip = Math.min(...w.slice(105, 136));
            if (dip >= 24) return "the mark never flipped in ticks 105..135";
            if (!st.slice(150, 300).includes(2)) return "A did not dissolve";
            return `info: iris width dips to ${dip}`;
        },
    },
    {
        name: "L", what: "Select at 150: a steer run in READY by tick 215, map a permutation", frames: 216,
        press: ["SELECT:150-150"], dump: ["debug_steer", "debug_score", "debug_rewinds_left", "debug_steer_map", "debug_head_x", "debug_head_y", "debug_head_z"],
        at: ["151 debug_state == 2", "151 debug_steer == 0"],
        expect: ["debug_state == 4", "debug_steer == 1", "debug_score == 0", "debug_rewinds_left == 1", "debug_crashes == 0"],
        check: (v) => {
            const m = v.debug_steer_map;
            const dirs = [0, 1, 2, 3, 4, 5].map((c) => (m >> (3 * c)) & 7);
            if (new Set(dirs).size !== 6 || dirs.some((d) => d > 5)) return `debug_steer_map ${m} is not a permutation (${dirs})`;
            for (const [a, b] of [[0, 1], [2, 3], [4, 5]]) if ((dirs[a] ^ 1) !== dirs[b]) return `controls ${a}/${b} are not opposite (${dirs})`;
            return `info: map up/down/left/right/A/B = ${dirs.map((d) => ["+x", "-x", "+y", "-y", "+z", "-z"][d]).join(" ")}`;
        },
    },
    {
        name: "M", what: "steer: tools/scripts/steer_survive.json flies 1400 ticks without a crash", frames: 1400,
        script: "tools/scripts/steer_survive.json", dump: ["debug_score", "debug_crashes", "debug_steer_rate"],
        expect: ["debug_state == 4", "debug_crashes == 0", "debug_score >= 60"],
    },
    {
        name: "N", what: "steer: wall, REWIND, wall, GAME OVER; A again; Select out", frames: 1170,
        press: ["SELECT:150-150", "A:900-900", "SELECT:1100-1100"],
        sample: ["debug_state", "debug_score", "debug_crashes", "debug_rewinds_left", "debug_best", "debug_steer"],
        expect: ["debug_state == 1", "debug_steer == 0"],
        at: ["960 debug_state == 4", "960 debug_score == 0", "960 debug_rewinds_left == 1", "960 debug_crashes == 0"],
        check: (v, meta) => {
            const st = series(meta, "debug_state"), sc = series(meta, "debug_score"), rw = series(meta, "debug_rewinds_left");
            const best = series(meta, "debug_best");
            if (!st || !sc || !rw || !best) return "samples missing from frames.json";
            const r1 = st.indexOf(5);
            if (r1 < 0) return "no REWIND";
            const back = st.indexOf(4, r1);
            if (back < 0) return "no STEER after the rewind";
            if (rw[back] !== 0) return "the rewind was not spent";
            if (sc[back] > sc[r1] || sc[r1] - sc[back] > 6) return `score went ${sc[r1]} -> ${sc[back]} over the rewind`;
            const go = st.indexOf(6, back);
            if (go < 0 || go > 899) return "no GAME OVER before tick 900";
            if (best[go] !== sc[go]) return `best ${best[go]} != score ${sc[go]} at game over`;
            if (st.slice(go, 900).some((x) => x !== 6)) return "left GAME OVER before A";
            return `info: rewind at ${r1} (score ${sc[r1]} -> ${sc[back]}), game over at ${go} (score ${sc[go]})`;
        },
    },
];

let runs = RUNS;
const names = [...RUNS.map((r) => r.name), "F"];
if (opts.only) {
    const unknown = opts.only.filter((n) => !names.includes(n));
    if (unknown.length) usage(`--only: unknown run(s) ${unknown.join(", ")} (have ${names.join(", ")})`);
    runs = RUNS.filter((r) => opts.only.includes(r.name));
}
if (!fs.existsSync(opts.wasm)) usage(`${path.relative(ROOT, opts.wasm)} not found (run zig build -Dcart=snouty-pipes at the repository root)`);

// preview prints "  NAME = V" lines for dumped exports and "PASS|FAIL NAME OP V (got X)"
// for expectations, both on stderr; parse loosely.
function parseExports(text) {
    const vals = {};
    for (const line of text.split("\n")) {
        if (/\b(PASS|FAIL)\b/.test(line)) continue;
        for (const m of line.matchAll(/\b(debug_\w+)\s*=\s*(-?\d+)/g)) vals[m[1]] = Number(m[2]);
    }
    return vals;
}

function preview(name, r, seed) {
    const out = path.join(OUT_DIR, name);
    fs.rmSync(out, { recursive: true, force: true });
    const args = [PREVIEW, opts.wasm, "--quiet", "--seed", String(seed), "--frames", String(r.frames), "--out", out];
    for (const c of r.calls ?? []) args.push("--call", c);
    for (const p of r.press ?? []) args.push("--press", p);
    if (r.script) args.push("--script", path.join(ROOT, r.script));
    if (r.sample?.length) args.push("--sample", r.sample.join(","), "--sample-every", "1");
    if (r.until) args.push("--until", r.until);
    args.push("--dump-exports", [...DUMP, ...(r.dump ?? [])].join(","));
    for (const e of r.expect ?? []) args.push("--expect", e);
    for (const e of r.at ?? []) args.push("--at", e);
    const t0 = Date.now();
    const res = spawnSync(process.execPath, args, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 << 20 });
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    let meta = null;
    try { meta = JSON.parse(fs.readFileSync(path.join(out, "frames.json"), "utf8")); } catch { /* reported below */ }
    return { res, secs, meta, v: parseExports(`${res.stdout || ""}\n${res.stderr || ""}`) };
}

function summary(v, dump) {
    if (!Object.keys(v).length) return "no exports read";
    const st = v.debug_state;
    const extra = (dump ?? []).map((n) => `${n.replace(/^debug_/, "")} ${v[n] ?? "?"}`).join(", ");
    return `state ${st ?? "?"}${STATE_NAMES[st] ? ` ${STATE_NAMES[st]}` : ""} tick ${v.debug_tick ?? "?"}, scene ${v.debug_scene ?? "?"}, ` +
        `filled ${v.debug_filled ?? "?"}, alive ${v.debug_alive ?? "?"}, pipes ${v.debug_pipes ?? "?"}, view ${v.debug_view ?? "?"}, ` +
        `teapots ${v.debug_teapots ?? "?"}${extra ? `; ${extra}` : ""}`;
}

function failLines(res) {
    return (res.stderr || "").trim().split("\n")
        .filter((l) => l && !/^preview: cart copies its frame/.test(l) && (/FAIL|error|unknown|missing|trap|not /i.test(l) || res.status !== 3))
        .slice(0, 8);
}

let fails = 0, total = 0;
for (const r of runs) {
    total++;
    const { res, secs, meta, v } = preview(r.name, r, opts.seed);
    const label = `${r.name}  ${r.what}`;
    let checkMsg = res.status === 0 && r.check ? r.check(v, meta) : null;
    let info = null;
    if (checkMsg?.startsWith("info: ")) { info = checkMsg.slice(6); checkMsg = null; }
    if (checkMsg) {
        fails++;
        console.log(`FAIL ${label} (${secs} s): ${checkMsg}; ${summary(v, r.dump)}`);
        continue;
    }
    if (res.status === 0) {
        console.log(`PASS ${label} (${secs} s): ${summary(v, r.dump)}${info ? `\n     ${info}` : ""}`);
        continue;
    }
    fails++;
    const why = res.status === 3 ? "expectation failed or cart trapped" : res.status === 2 ? "usage error (missing export?)" : `preview exited ${res.status ?? res.signal}`;
    console.log(`FAIL ${label} (${secs} s): ${why}; ${summary(v, r.dump)}`);
    for (const l of failLines(res)) console.log(`    ${l}`);
}

// F: determinism (two runs with one seed agree, another seed differs).
if (!opts.only || opts.only.includes("F")) {
    total++;
    const r = { frames: 400, dump: ["debug_pixel_checksum"] };
    const t0 = Date.now();
    const a = preview("F1", r, opts.seed), b = preview("F2", r, opts.seed), c = preview("F3", r, opts.seed + 1);
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    const ca = a.v.debug_pixel_checksum, cb = b.v.debug_pixel_checksum, cc = c.v.debug_pixel_checksum;
    const label = `F  determinism: seed ${opts.seed} twice, then seed ${opts.seed + 1}, 400 ticks`;
    let err = null;
    for (const x of [a, b, c]) if (x.res.status !== 0) err = `preview exited ${x.res.status ?? x.res.signal}`;
    if (!err && (ca === undefined || cb === undefined || cc === undefined)) err = "debug_pixel_checksum not read";
    else if (!err && ca !== cb) err = `same seed, different pictures (${ca} vs ${cb})`;
    else if (!err && ca === cc) err = `seeds ${opts.seed} and ${opts.seed + 1} draw the same picture (${ca})`;
    else if (!err && ca === 0) err = "blank screen at tick 399";
    if (err) {
        fails++;
        console.log(`FAIL ${label} (${secs} s): ${err}`);
    } else {
        console.log(`PASS ${label} (${secs} s): checksums ${ca}, ${cb}, ${cc}`);
    }
}
console.log(`check_cycle: ${total - fails} pass, ${fails} fail`);
process.exit(fails ? 3 : 0);
