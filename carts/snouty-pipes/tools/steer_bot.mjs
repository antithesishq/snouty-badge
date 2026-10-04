#!/usr/bin/env node
// Steer mode bot (M3): plays a steer run headless, driving the cart's wasm
// directly through its debug exports, and writes what it pressed as an input
// script for ../../tools/preview.mjs --script and badge-bench --script.
//
//   node tools/steer_bot.mjs [--wasm ../../zig-out/bin/snouty-pipes.wasm] [--seed S]
//        [--frames N] [--enter T] [--idle T1-T2]... [--press BTN:T1-T2]...
//        [--out tools/scripts/steer_x.json] [--quiet]
//
// Select is pressed at update --enter (default 150); once the run is on
// (debug_state 4, steer) the bot decides every time the player's head enters
// a new cell, before its centre where the exit is picked: of the directions
// that are not a reversal and lead to a free cell (debug_occupied), the one
// with the most room behind it (a flood fill, capped), straight on winning
// ties by a small bonus. If that is not straight on, it taps the control the
// cart maps to it (debug_steer_map: Up/Down/Left/Right, A into, B out) for
// one update. --idle ranges are updates where it steers nothing (to crash on
// purpose); --press items are extra button presses (e.g. A:900-900 at the
// game-over card) merged into the script. The cart is deterministic given
// the seed and the input, so preview.mjs replays the written script exactly
// (same --seed). The badge build mixes its clock into the seed, so on
// badge-bench the same script plays another run (still a valid input load).
//
// Prints a line per crash and a summary: score, best, crashes, state.
// Exit codes: 0 ok, 2 usage error. No npm dependencies.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO = path.resolve(ROOT, "../..");
const BITS = { START: 0, SELECT: 1, A: 2, B: 3, UP: 5, DOWN: 6, LEFT: 7, RIGHT: 8 };
// steer.Control order -> button.
const CONTROL_BUTTON = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B"];
const N = [12, 10, 12]; // grid.nx, ny, nz
const STEPS = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]; // grid.Dir order
const FILL_CAP = 120;

function usage(msg) {
    if (msg) console.error(`steer_bot: ${msg}`);
    console.error("usage: node tools/steer_bot.mjs [--wasm FILE] [--seed S] [--frames N] [--enter T] [--idle T1-T2]... [--press BTN:T1-T2]... [--out FILE] [--quiet]");
    process.exit(2);
}

const opts = { wasm: path.join(REPO, "zig-out", "bin", "snouty-pipes.wasm"), seed: 1, frames: 1800, enter: 150, idle: [], press: [], out: null, quiet: false };
const argv = process.argv.slice(2);
const range = (s, a) => { const m = /^(\d+)-(\d+)$/.exec(s); if (!m) usage(`${a}: bad range '${s}'`); return [Number(m[1]), Number(m[2])]; };
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = (s) => { const n = Number(s); if (!Number.isInteger(n) || n < 0) usage(`${a}: bad integer '${s}'`); return n; };
    switch (a) {
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "--seed": opts.seed = int(val()); break;
        case "--frames": opts.frames = int(val()); break;
        case "--enter": opts.enter = int(val()); break;
        case "--idle": opts.idle.push(range(val(), a)); break;
        case "--press": {
            const m = /^([A-Za-z]+):(\d+)-(\d+)$/.exec(val());
            if (!m || !(m[1].toUpperCase() in BITS)) usage(`--press: want BTN:T1-T2`);
            opts.press.push({ btn: m[1].toUpperCase(), from: Number(m[2]), to: Number(m[3]) });
            break;
        }
        case "--out": opts.out = path.resolve(val()); break;
        case "--quiet": opts.quiet = true; break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}
if (!fs.existsSync(opts.wasm)) usage(`${opts.wasm} not found (zig build -Dcart=snouty-pipes at the repository root)`);

// The same host as preview.mjs for what this cart imports: memory and rand.
const memory = new WebAssembly.Memory({ initial: 64, maximum: 64 });
let rngState = (opts.seed >>> 0) || 1;
function rand() { let x = rngState; x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; rngState = x; return x | 0; }
const module = new WebAssembly.Module(fs.readFileSync(opts.wasm));
const env = { memory, rand };
for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== "env" || !(imp.name in env)) usage(`the cart imports ${imp.module}.${imp.name}, which this bot does not provide`);
}
const X = new WebAssembly.Instance(module, { env }).exports;
const dv = new DataView(memory.buffer);
X.start();

const presses = []; // { from, to, hold: [BTN] }
for (const p of opts.press) presses.push({ from: p.from, to: p.to, hold: [p.btn] });
presses.push({ from: opts.enter, to: opts.enter, hold: ["SELECT"] });
const idle = (t) => opts.idle.some(([a, b]) => t >= a && t <= b);

function occupancy() {
    const occ = new Uint8Array(N[0] * N[1] * N[2]);
    for (let z = 0; z < N[2]; z++) for (let y = 0; y < N[1]; y++) for (let x = 0; x < N[0]; x++) occ[(z * N[1] + y) * N[0] + x] = X.debug_occupied(x, y, z);
    return occ;
}
const inside = (c) => c[0] >= 0 && c[1] >= 0 && c[2] >= 0 && c[0] < N[0] && c[1] < N[1] && c[2] < N[2];
const idx = (c) => (c[2] * N[1] + c[1]) * N[0] + c[0];
const add = (c, d) => [c[0] + STEPS[d][0], c[1] + STEPS[d][1], c[2] + STEPS[d][2]];
function room(occ, start) {
    const seen = new Uint8Array(occ.length);
    const q = [start];
    seen[idx(start)] = 1;
    let n = 0;
    while (q.length && n < FILL_CAP) {
        const c = q.shift();
        n++;
        for (let d = 0; d < 6; d++) {
            const m = add(c, d);
            if (!inside(m) || occ[idx(m)] || seen[idx(m)]) continue;
            seen[idx(m)] = 1;
            q.push(m);
        }
    }
    return n;
}

// Picks the exit for the head cell; returns a grid.Dir.
function decide(head, heading) {
    const occ = occupancy();
    occ[idx(head)] = 1;
    let best = -1, bestScore = -1;
    for (let d = 0; d < 6; d++) {
        if (d === (heading ^ 1)) continue;
        const n = add(head, d);
        if (!inside(n) || occ[idx(n)]) continue;
        occ[idx(n)] = 1;
        let s = room(occ, n) * 4 + (d === heading ? 6 : 0);
        // Look one more cell ahead in that direction: a free run is nicer.
        const n2 = add(n, d);
        if (inside(n2) && !occ[idx(n2)]) s += 3;
        occ[idx(n)] = 0;
        if (s > bestScore) { bestScore = s; best = d; }
    }
    return best < 0 ? heading : best;
}

let lastHead = null, tapUntil = -1, tapBits = 0, crashes = 0, lastState = -1;
for (let t = 0; t < opts.frames; t++) {
    let bits = 0;
    for (const p of presses) if (t >= p.from && t <= p.to) for (const b of p.hold) bits |= 1 << BITS[b];
    if (t <= tapUntil) bits |= tapBits;
    dv.setUint16(0x04, bits, true);
    X.update();
    const state = X.debug_state();
    if (X.debug_crashes() > crashes) {
        crashes = X.debug_crashes();
        if (!opts.quiet) console.log(`steer_bot: crash ${crashes} at update ${t}, score ${X.debug_score()}`);
    }
    if (state !== 4) { if (state !== lastState) lastHead = null; lastState = state; continue; }
    lastState = state;
    const head = [X.debug_head_x(), X.debug_head_y(), X.debug_head_z()];
    const key = head.join(",");
    if (key === lastHead) continue;
    lastHead = key;
    if (idle(t + 1)) continue;
    const heading = X.debug_heading();
    const d = decide(head, heading);
    if (d === heading) continue;
    const map = X.debug_steer_map();
    let control = -1;
    for (let c = 0; c < 6; c++) if (((map >> (3 * c)) & 7) === d) control = c;
    if (control < 0) continue;
    const btn = CONTROL_BUTTON[control];
    tapBits = 1 << BITS[btn];
    tapUntil = t + 1;
    presses.push({ from: t + 1, to: t + 1, hold: [btn] });
}

presses.sort((a, b) => a.from - b.from || a.to - b.to);
const summary = `steer_bot: seed ${opts.seed}, ${opts.frames} updates: state ${X.debug_state()}, score ${X.debug_score()}, best ${X.debug_best()}, crashes ${X.debug_crashes()}, rewinds left ${X.debug_rewinds_left()}, ${presses.length} presses`;
console.log(summary);
if (opts.out) {
    fs.writeFileSync(opts.out, "[\n" + presses.map((p) => `  ${JSON.stringify(p)}`).join(",\n") + "\n]\n");
    console.log(`steer_bot: wrote ${path.relative(process.cwd(), opts.out)}`);
}
