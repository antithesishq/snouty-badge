#!/usr/bin/env node
// The ladder bot: Snouty Cycles' content gate (PLAN.md M1 Track P item 6,
// M2 Track R item 5, M2.1 Track F item 2).
//
//   node tools/ladder_bot.mjs [--wasm PATH] [--autopilot 3] [--levels 1-12]
//                             [--seeds 1-5] [--need 4] [--seeds2 6-15]
//                             [--need2 7] [--jobs N] [--options BITS]
//                             [--json FILE]
//
// For each level and seed: a fresh wasm instance, debug_set_seed(seed),
// debug_options(BITS) (OPTIONS, default 0: none), debug_autopilot(K),
// debug_set_level(level) (3 snapshots, the level's intro), then update()
// until the ladder moves past the level (cleared) or CORE DUMPED (failed),
// or a tick cap. Each derez rewinds 2 s while a snapshot is left (the
// autopilot rides as T1 for 5 s after one, so it does not repeat itself).
// A level passes when it is cleared on at least --need of --seeds and at
// least --need2 of --seeds2 (`--seeds2 none` drops the second group).
// Exit 0 when every level passes, 1 otherwise, 2 on a usage or load error.
// Seed lists take ranges: 1-5, 6-15, 1,3,9.
//
// Each level's line also gives the derezzes it cost, averaged over every
// seed run (a dumped run counts its 4): the difficulty curve, which should
// rise to PROD. The last line lists them in ladder order.
//
// The autopilot drives the player like the AI drives the programs: 3 is
// T3 SEARCH, 1 is T1, 2 T1 with slips. It decides after the programs from
// an AI pool of its own (ai.decide_apart, M2.1), so the programs play as
// they do against a human. Runs are deterministic: the same wasm, seed and
// level give the same result. Levels run in parallel worker processes
// (--jobs, default the CPU count).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fork } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
const STATE_GAME_OVER = 8; // game.State.game_over (docs/RUNNING.md section 6)
const TICK_CAP = 60 * 60 * 6; // a round ends by ~60 s; rewinds add 2 s each

function parseArgs(argv) {
    const o = { wasm: path.join(here, "../../../zig-out/bin/snouty-cycles.wasm"), autopilot: 3, levels: [], seeds: list("1-5"), need: 4,
        seeds2: list("6-15"), need2: 7, jobs: Math.max(1, os.cpus().length), json: null, worker: false, options: 0 };
    let levels = "1-12";
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i], v = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
        switch (a) {
            case "--wasm": o.wasm = v(); break;
            case "--autopilot": o.autopilot = Number(v()); break;
            case "--levels": levels = v(); break;
            case "--seeds": o.seeds = list(v()); break;
            case "--need": o.need = Number(v()); break;
            case "--seeds2": { const x = v(); o.seeds2 = x === "none" ? [] : list(x); break; }
            case "--need2": o.need2 = Number(v()); break;
            case "--jobs": o.jobs = Math.max(1, Number(v())); break;
            case "--json": o.json = v(); break;
            case "--options": o.options = Number(v()); break;
            case "--worker": o.worker = true; break;
            case "-h": case "--help": usage(null); break;
            default: usage(`unknown argument ${a}`);
        }
    }
    o.levels = list(levels);
    return o;
}

/// "1-5,9" -> [1, 2, 3, 4, 5, 9]
function list(spec) {
    const out = [];
    for (const part of spec.split(",")) {
        const m = part.match(/^(\d+)(?:-(\d+))?$/);
        if (!m) usage(`bad list ${spec}`);
        for (let n = Number(m[1]); n <= Number(m[2] ?? m[1]); n++) out.push(n);
    }
    return out;
}

function usage(msg) {
    if (msg) console.error(`ladder_bot: ${msg}`);
    console.error("usage: node tools/ladder_bot.mjs [--wasm PATH] [--autopilot K] [--levels 1-12] [--seeds 1-5] [--need 4] [--seeds2 6-15|none] [--need2 7] [--jobs N] [--options BITS] [--json FILE]");
    process.exit(msg ? 2 : 0);
}

/// One level on one seed: cleared or not, and how.
function runOne(module, autopilot, level, seed, options) {
    const memory = new WebAssembly.Memory({ initial: 64, maximum: 64 });
    let r = seed >>> 0 || 1;
    const rand = () => { r ^= r << 13; r >>>= 0; r ^= r >>> 17; r ^= r << 5; r >>>= 0; return r | 0; };
    const inst = new WebAssembly.Instance(module, { env: { memory, rand } });
    const x = inst.exports;
    x.start();
    x.debug_set_seed(seed);
    x.debug_options(options);
    x.debug_autopilot(autopilot);
    x.debug_set_level(level);
    let t = 0;
    while (t < TICK_CAP) {
        x.update();
        t++;
        if (x.debug_level() !== level || x.debug_state() === STATE_GAME_OVER) break;
    }
    const cleared = x.debug_level() > level;
    return { level, seed, cleared, derezzes: x.debug_losses(), rewinds: x.debug_rewinds(), attempts: x.debug_round(), ticks: t, timeout: t >= TICK_CAP, score: x.debug_score() };
}

const opts = parseArgs(process.argv.slice(2));
let module;
try { module = new WebAssembly.Module(fs.readFileSync(opts.wasm)); } catch (e) { console.error(`ladder_bot: ${opts.wasm}: ${e.message}`); process.exit(2); }

if (opts.worker) {
    // One level, every seed; the result goes back to the parent.
    const level = opts.levels[0];
    process.send(opts.seeds.map((s) => runOne(module, opts.autopilot, level, s, opts.options)));
    process.exit(0);
}

const t0 = Date.now();
const results = new Map();
const queue = [...opts.levels];
await new Promise((resolve) => {
    let running = 0;
    const next = () => {
        if (queue.length === 0 && running === 0) return resolve();
        while (running < opts.jobs && queue.length) {
            const level = queue.shift();
            running++;
            const child = fork(fileURLToPath(import.meta.url), ["--worker", "--wasm", opts.wasm, "--autopilot", String(opts.autopilot),
                "--levels", String(level), "--seeds", [...opts.seeds, ...opts.seeds2].join(","), "--options", String(opts.options)]);
            child.on("message", (m) => results.set(level, m));
            child.on("exit", (code) => {
                if (code !== 0 || !results.has(level)) results.set(level, null);
                running--;
                next();
            });
        }
    };
    next();
});

let pass = true;
const rows = [];
const groups = [{ seeds: opts.seeds, need: opts.need }];
if (opts.seeds2.length) groups.push({ seeds: opts.seeds2, need: opts.need2 });
const fmt = (g) => `${g.need} of ${g.seeds.length} (seeds ${g.seeds[0]}-${g.seeds[g.seeds.length - 1]})`;
console.log(`ladder bot: autopilot ${opts.autopilot}, options ${opts.options}; a level passes when cleared on >= ${groups.map(fmt).join(" and >= ")}`);
const curve = [];
for (const level of opts.levels) {
    const rs = results.get(level);
    if (!rs) { console.log(`FAIL level ${String(level).padStart(2)}: worker crashed`); pass = false; continue; }
    const counts = groups.map((g) => rs.filter((x) => g.seeds.includes(x.seed) && x.cleared).length);
    const ok = groups.every((g, k) => counts[k] >= g.need);
    if (!ok) pass = false;
    const derez = rs.reduce((a, x) => a + x.derezzes, 0) / rs.length;
    const rewinds = rs.reduce((a, x) => a + x.rewinds, 0) / rs.length;
    curve.push(derez.toFixed(2));
    const detail = rs.map((x) => `${x.seed}:${x.cleared ? (x.derezzes ? `clear(${x.derezzes})` : "clear") : x.timeout ? "cap" : "dumped"}`).join(" ");
    const mean = Math.round(rs.reduce((a, x) => a + x.ticks, 0) / rs.length / 60);
    console.log(`${ok ? "ok  " : "FAIL"} level ${String(level).padStart(2)}: ${counts.map((n, k) => `${n}/${groups[k].seeds.length}`).join(" + ")} cleared, derezzes ${derez.toFixed(2)}, rewinds ${rewinds.toFixed(2)}, mean ${mean} s  [${detail}]`);
    rows.push({ level, cleared: counts, of: groups.map((g) => g.seeds.length), derezzes: derez, rewinds, pass: ok, runs: rs });
}
console.log(`ladder bot: derezzes per level ${curve.join(" ")}`);
console.log(`ladder bot: ${pass ? "PASS" : "FAIL"} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
if (opts.json) fs.writeFileSync(opts.json, JSON.stringify({ autopilot: opts.autopilot, options: opts.options, groups, pass, levels: rows }, null, 1));
process.exit(pass ? 0 : 1);
