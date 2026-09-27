#!/usr/bin/env node
// Screensaver-loop check (M2, extended in M3): runs the cart headless through
// preview.mjs and asserts on the debug exports after the last update.
//
//   node tools/check_cycle.mjs [--wasm zig-out/bin/snouty-maze.wasm] [--only A,B,C,D,E,F]
//                              [--frames N] [--seed S]
//
// Runs (each one `node tools/preview.mjs <wasm> --quiet --seed S --frames F
// [--call ...] [--press ...] --dump-exports ... --expect ...`):
//   A  unattended: no input, F = --frames (default 9000, 2.5 minutes of
//      60 Hz ticks); expects debug_cycles >= 1 (walked a maze to the finish,
//      rose, swapped mazes and descended). Teleports (M3) restart the walk
//      from a random cell, so the first finish moves; docs/RUNNING.md has the
//      measured first-finish tick per seed.
//   B  skip: A pressed at tick 0, 241 updates. 30 PAUSE + 150 RISE ticks
//      make OVERHEAD ticks 180..299 (120 ticks; tick 300 is already DESCEND
//      tick 0), so the last update, tick 240, is mid-OVERHEAD: expects
//      debug_state == 4 (OVERHEAD) and debug_name_strip == 1.
//   C  skip then resume: A at tick 0, 1000 updates; expects debug_cycles >= 1.
//      (The state at tick 1000 is WALK or TURN, so it is not asserted.)
//   D  flip: --call debug_place:10100 puts the smiley in cell (1, 0), the
//      first cell the seed 1 camera enters (east from (0, 0)); 100 updates;
//      expects debug_flips == 1, debug_roll_deg == 180, and (checked here,
//      since --expect has no "or") debug_smiley_x != 1 || debug_smiley_z != 0
//      (the smiley respawned elsewhere).
//   E  teleport: --call debug_place:20100 puts the sphere in (1, 0); 100
//      updates; expects debug_teleports == 1, debug_state < 2 (WALK or TURN
//      again) and debug_fade_level == 0 (the dissolve is over).
//   F  leds: Select at tick 0 (autopilot state, so it toggles the LEDs); 10
//      updates; expects debug_leds == 1, 0 < debug_led_max <= 10.
// // debug_state, debug_state_tick, debug_cycles, debug_cell_x/z and
// debug_heading are dumped in every run and printed with the result.
//
// Exit codes: 0 all PASS, 2 usage error, 3 any FAIL (including a preview run
// that exited non-zero for another reason, e.g. a missing export).
// No npm dependencies.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PREVIEW = path.join(ROOT, "tools", "preview.mjs");
const STATE_NAMES = ["WALK", "TURN", "PAUSE", "RISE", "OVERHEAD", "DESCEND", "TELEPORT", "FLY"];
const DUMP = ["debug_state", "debug_state_tick", "debug_cycles", "debug_cell_x", "debug_cell_z", "debug_heading"];

function usage(msg) {
    if (msg) console.error(`check_cycle: ${msg}`);
    console.error("usage: node tools/check_cycle.mjs [--wasm FILE] [--only A,B,C,D,E,F] [--frames N] [--seed S]");
    process.exit(2);
}

const opts = { wasm: path.join(ROOT, "zig-out", "bin", "snouty-maze.wasm"), only: null, frames: 9000, seed: 1 };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = (s, min) => { const n = Number(s); if (!Number.isInteger(n) || n < min) usage(`${a}: bad integer '${s}'`); return n; };
    switch (a) {
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "--only": (opts.only ??= []).push(...val().split(",").map((s) => s.trim().toUpperCase()).filter(Boolean)); break;
        case "--frames": opts.frames = int(val(), 1); break;
        case "--seed": opts.seed = int(val(), 0); break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}

// Each run: frames, --call list, --press list, extra exports to dump, --expect
// list, and an optional `check(values)` for what --expect cannot say (it
// returns an error string or null).
const RUNS = [
    { name: "A", what: `unattended ${opts.frames} ticks`, frames: opts.frames, expect: ["debug_cycles >= 1"] },
    { name: "B", what: "A at tick 0, OVERHEAD + name strip at tick 240", frames: 241, press: ["A:0-0"], expect: ["debug_state == 4", "debug_name_strip == 1"] },
    { name: "C", what: "A at tick 0, maze done by tick 1000", frames: 1000, press: ["A:0-0"], expect: ["debug_cycles >= 1"] },
    {
        name: "D", what: "smiley at (1,0) flips the view", frames: 100, calls: ["debug_place:10100"],
        dump: ["debug_flips", "debug_roll_deg", "debug_smiley_x", "debug_smiley_z"],
        expect: ["debug_flips == 1", "debug_roll_deg == 180"],
        check: (v) => (v.debug_smiley_x === undefined || v.debug_smiley_z === undefined) ? "smiley cell not read"
            : (v.debug_smiley_x === 1 && v.debug_smiley_z === 0) ? "smiley still in (1, 0) (did not respawn)" : null,
    },
    {
        name: "E", what: "sphere at (1,0) teleports, walk resumes", frames: 100, calls: ["debug_place:20100"],
        dump: ["debug_teleports", "debug_fade_level", "debug_sphere_x", "debug_sphere_z"],
        expect: ["debug_teleports == 1", "debug_state < 2", "debug_fade_level == 0"],
    },
    {
        name: "F", what: "Select turns the LEDs on, all channels <= 10", frames: 10, press: ["SELECT:0-0"],
        dump: ["debug_leds", "debug_led_max"],
        expect: ["debug_leds == 1", "debug_led_max <= 10", "debug_led_max > 0"],
    },
];
let runs = RUNS;
if (opts.only) {
    const unknown = opts.only.filter((n) => !RUNS.some((r) => r.name === n));
    if (unknown.length) usage(`--only: unknown run(s) ${unknown.join(", ")} (have ${RUNS.map((r) => r.name).join(", ")})`);
    runs = RUNS.filter((r) => opts.only.includes(r.name));
}
if (!fs.existsSync(opts.wasm)) usage(`${path.relative(ROOT, opts.wasm)} not found (run zig build)`);

// preview prints "  NAME = V" lines for dumped exports and "PASS|FAIL NAME OP V (got X)"
// for expectations, both on stderr; parse loosely and fall back to raw lines.
function parseExports(text) {
    const vals = {};
    for (const line of text.split("\n")) {
        if (/\b(PASS|FAIL)\b/.test(line)) continue;
        for (const m of line.matchAll(/\b(debug_\w+)\s*=\s*(-?\d+)/g)) vals[m[1]] = Number(m[2]);
    }
    return vals;
}

let fails = 0;
for (const r of runs) {
    const args = [PREVIEW, opts.wasm, "--quiet", "--seed", String(opts.seed), "--frames", String(r.frames)];
    for (const c of r.calls ?? []) args.push("--call", c);
    for (const p of r.press ?? []) args.push("--press", p);
    args.push("--dump-exports", [...DUMP, ...(r.dump ?? [])].join(","));
    for (const e of r.expect) args.push("--expect", e);
    const t0 = Date.now();
    const res = spawnSync(process.execPath, args, { cwd: ROOT, encoding: "utf8", maxBuffer: 16 << 20 });
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    const out = `${res.stdout || ""}\n${res.stderr || ""}`;
    const v = parseExports(out);
    const st = v.debug_state;
    const extra = (r.dump ?? []).map((n) => `${n.replace(/^debug_/, "")} ${v[n] ?? "?"}`).join(", ");
    const summary = Object.keys(v).length
        ? `state ${st ?? "?"}${STATE_NAMES[st] ? ` ${STATE_NAMES[st]}` : ""} tick ${v.debug_state_tick ?? "?"}, cycles ${v.debug_cycles ?? "?"}, cell ${v.debug_cell_x ?? "?"},${v.debug_cell_z ?? "?"}, heading ${v.debug_heading ?? "?"}${extra ? `; ${extra}` : ""}`
        : "no exports read";
    const label = `${r.name}  ${r.what}`;
    const checkErr = res.status === 0 && r.check ? r.check(v) : null;
    if (checkErr) {
        fails++;
        console.log(`FAIL ${label} (${secs} s): ${checkErr}; ${summary}`);
        continue;
    }
    if (res.status === 0) {
        console.log(`PASS ${label} (${secs} s): ${summary}`);
        continue;
    }
    fails++;
    const why = res.status === 3 ? "expectation failed or cart trapped" : res.status === 2 ? "usage error (missing export?)" : `preview exited ${res.status ?? res.signal}`;
    console.log(`FAIL ${label} (${secs} s): ${why}; ${summary}`);
    const lines = (res.stderr || "").trim().split("\n")
        .filter((l) => l && !/^preview: cart copies its frame/.test(l) && (/FAIL|error|unknown|missing|trap|not /i.test(l) || res.status !== 3))
        .slice(0, 8);
    for (const l of lines) console.log(`    ${l}`);
}
console.log(`check_cycle: ${runs.length - fails} pass, ${fails} fail`);
process.exit(fails ? 3 : 0);
