#!/usr/bin/env node
// Difficulty probe (PLAN.md M7 "Probe (track D)"): plays a fresh game per bot
// headlessly in endless probe mode (hits are counted and charged but never
// end the game) until the game has gone through --stages stages, sampling the
// cart's debug exports after every update, and prints one table: per bot and
// stage, hits, seconds in the stage, boss seconds, boss killed or escaped,
// rank at the stage's end, the weapon when the boss arrived and at the end,
// and forks at the end.
//
//   node tools/difficulty.mjs [--wasm FILE] [--bots 1,2,3] [--stages N]
//                             [--frames CAP] [--seed N] [--json OUT.json] [--out DIR]
//
// Usually run through tools/difficulty.sh, which builds first. Each bot is
// one run of the shared ../../tools/preview.mjs (in parallel): --call
// debug_probe and --call debug_bot:N before the first update (the bot holds A,
// so it starts the game from the title on update 0), --sample for the per-tick
// trace and --until to stop once the stage index reaches N. Same build, same
// seed, same table.
//
// Exports used: debug_probe, debug_bot(n), debug_hits, debug_stage_index
// (stage + 4 * loop; falls back to debug_stage, the loop counter, on carts
// before M7), and when present debug_rank, debug_boss_hp, debug_stage_clears,
// debug_weapon (kind * 10 + level), debug_forks, debug_state. A missing
// optional export shows as "-".
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const cartDir = path.resolve(here, "..");
const preview = path.resolve(cartDir, "../../tools/preview.mjs");
const BOT_NAMES = { 1: "turret", 2: "sweep", 3: "dodger" };
const WEAPON = ["F", "A", "B"];

function usage(msg) {
    if (msg) console.error(`difficulty: ${msg}`);
    console.error("usage: node tools/difficulty.mjs [--wasm FILE] [--bots 1,2,3] [--stages N] [--frames CAP] [--seed N] [--json OUT.json] [--out DIR]\n" +
        "  --stages N: stop once the stage index (stage + 4 * loop) reaches N; default 5 = the four stages and loop 2's stage 1\n" +
        "  --frames CAP: updates per bot at most (default 15000 per stage)");
    process.exit(2);
}

const opts = { wasm: path.resolve(cartDir, "../../zig-out/bin/snouty-bugs.wasm"), bots: [1, 2, 3], stages: 5, frames: null,
    seed: 1, json: null, out: path.resolve(cartDir, "out/difficulty") };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = (lo) => { const s = val(); const n = Number(s); if (!Number.isInteger(n) || n < lo) usage(`${a}: bad integer '${s}'`); return n; };
    switch (a) {
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "--bots": opts.bots = val().split(",").map((s) => { const n = Number(s.trim()); if (!(n in BOT_NAMES)) usage(`--bots: unknown bot '${s}' (1 turret, 2 sweep, 3 dodger)`); return n; }); break;
        case "--stages": opts.stages = int(1); break;
        case "--frames": opts.frames = int(1); break;
        case "--seed": opts.seed = int(0); break;
        case "--json": opts.json = path.resolve(val()); break;
        case "--out": opts.out = path.resolve(val()); break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}
if (opts.frames === null) opts.frames = 15000 * opts.stages;

let wasmBuf;
try { wasmBuf = fs.readFileSync(opts.wasm); } catch (e) { console.error(`difficulty: cannot read ${opts.wasm}: ${e.message}`); process.exit(1); }
const exportNames = new Set(WebAssembly.Module.exports(new WebAssembly.Module(wasmBuf)).map((e) => e.name));
for (const need of ["debug_probe", "debug_bot", "debug_hits"]) {
    if (!exportNames.has(need)) { console.error(`difficulty: ${opts.wasm} does not export ${need} (the probe needs PLAN.md M7's debug exports)`); process.exit(1); }
}
const stageExport = exportNames.has("debug_stage_index") ? "debug_stage_index" : exportNames.has("debug_stage") ? "debug_stage" : null;
if (!stageExport) { console.error(`difficulty: ${opts.wasm} exports neither debug_stage_index nor debug_stage`); process.exit(1); }
const optional = ["debug_rank", "debug_boss_hp", "debug_stage_clears", "debug_weapon", "debug_forks", "debug_state"].filter((n) => exportNames.has(n));
const sampled = [stageExport, "debug_hits", ...optional];

function runBot(bot) {
    const out = path.join(opts.out, `bot${bot}`);
    const args = [preview, opts.wasm, "--frames", String(opts.frames), "--quiet", "--out", out, "--seed", String(opts.seed),
        "--call", "debug_probe", "--call", `debug_bot:${bot}`, "--sample", sampled.join(","), "--until", `${stageExport} >= ${opts.stages}`];
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, args, { stdio: ["ignore", "ignore", "pipe"] });
        let err = "";
        child.stderr.on("data", (d) => { err += d; });
        child.on("error", reject);
        child.on("close", (code) => {
            fs.mkdirSync(out, { recursive: true });
            fs.writeFileSync(path.join(out, "preview.log"), err);
            if (code !== 0) { reject(new Error(`bot ${bot}: preview exited ${code}:\n${err.trim().split("\n").slice(-5).join("\n")}`)); return; }
            resolve(JSON.parse(fs.readFileSync(path.join(out, "frames.json"), "utf8")));
        });
    });
}

const weaponText = (v) => (v === undefined || v === null ? "-" : `${WEAPON[Math.floor(v / 10)] ?? "?"}${v % 10}`);
const stageLabel = (idx) => `L${Math.floor(idx / 4) + 1}S${(idx % 4) + 1}`;

// Splits one bot's per-tick trace into stage rows.
function stageRows(frames) {
    const s = frames.samples, v = s.values, n = s.ticks.length;
    const get = (name, i) => (name in v && i >= 0 && i < n ? v[name][i] : null);
    const rows = [];
    let a = 0;
    while (a < n) {
        const idx = v[stageExport][a];
        if (idx >= opts.stages) break;                    // the --until tick that stopped the run
        let b = a;
        while (b + 1 < n && v[stageExport][b + 1] === idx) b++;
        const ended = b + 1 < n;                          // the next tick is the next stage
        const hitsBefore = a > 0 ? v.debug_hits[a - 1] : 0;
        let bossTicks = 0, bossStart = null;
        if ("debug_boss_hp" in v) for (let i = a; i <= b; i++) if (v.debug_boss_hp[i] > 0) { bossTicks++; if (bossStart === null) bossStart = i; }
        let boss = "-";
        if (!ended) boss = bossStart === null ? "not yet" : "fighting";
        else if ("debug_stage_clears" in v) boss = get("debug_stage_clears", b + 1) > (a > 0 ? get("debug_stage_clears", a - 1) : 0) ? "killed" : "escaped";
        rows.push({
            stage_index: idx, stage: stageLabel(idx), ended,
            hits: v.debug_hits[b] - hitsBefore,
            seconds: +(((b - a + 1) * s.every) / 60).toFixed(1),
            boss_seconds: "debug_boss_hp" in v ? +((bossTicks * s.every) / 60).toFixed(1) : null,
            boss,
            rank: get("debug_rank", b),
            weapon_at_boss: bossStart === null ? null : get("debug_weapon", bossStart),
            weapon: get("debug_weapon", b),
            forks: get("debug_forks", b),
            first_tick: s.ticks[a], last_tick: s.ticks[b],
        });
        a = b + 1;
    }
    return rows;
}

const t0 = Date.now();
let results;
try {
    results = await Promise.all(opts.bots.map(async (bot) => {
        const frames = await runBot(bot);
        const state = frames.samples.values.debug_state;
        if (state && state.some((x, i) => i > 0 && x === 0)) console.error(`difficulty: warning: bot ${bot} went back to the title (is probe mode on?)`);
        return { bot, name: BOT_NAMES[bot], updates: frames.ran, reached: frames.until !== null && frames.until !== undefined, rows: stageRows(frames) };
    }));
} catch (e) { console.error(`difficulty: ${e.message}`); process.exit(1); }

// ---------------------------------------------------------------- table
const cols = [
    ["bot", (r, b) => b.name], ["stage", (r) => r.stage + (r.ended ? "" : "*")], ["hits", (r) => r.hits],
    ["secs", (r) => r.seconds.toFixed(1)], ["boss s", (r) => (r.boss_seconds === null ? "-" : r.boss_seconds.toFixed(1))],
    ["boss", (r) => r.boss], ["rank", (r) => r.rank ?? "-"], ["wpn@boss", (r) => weaponText(r.weapon_at_boss)],
    ["wpn", (r) => weaponText(r.weapon)], ["forks", (r) => r.forks ?? "-"],
];
const lines = [];
for (const b of results) {
    for (const r of b.rows) lines.push(cols.map(([, f]) => String(f(r, b))));
    const hits = b.rows.reduce((t, r) => t + r.hits, 0), secs = b.rows.reduce((t, r) => t + r.seconds, 0);
    lines.push(cols.map(([h]) => (h === "bot" ? b.name : h === "stage" ? "total" : h === "hits" ? String(hits) : h === "secs" ? secs.toFixed(1) : "")));
}
const widths = cols.map(([h], i) => Math.max(h.length, ...lines.map((l) => l[i].length)));
const fmt = (cells) => cells.map((c, i) => (i < 2 || i === 5 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join("  ").trimEnd();
console.log(`difficulty: ${path.relative(process.cwd(), opts.wasm)} seed ${opts.seed}, ${opts.stages} stage(s), cap ${opts.frames} updates, stage export ${stageExport}`);
console.log(fmt(cols.map(([h]) => h)));
console.log(fmt(widths.map((w) => "-".repeat(w))));
let prev = null;
for (const [k, l] of lines.entries()) { if (prev !== null && l[0] !== prev) console.log(""); prev = l[0]; console.log(fmt(l)); }
const capped = results.filter((b) => !b.reached).map((b) => b.name);
console.log(`stage LxSy = loop x, stage y; * = still running at the cap${capped.length ? ` (${capped.join(", ")} hit the cap of ${opts.frames} updates)` : ""}; ` +
    `wpn = F/A/B and level; ${((Date.now() - t0) / 1000).toFixed(1)} s`);

if (opts.json) {
    const meta = { wasm: opts.wasm, wasm_sha256: crypto.createHash("sha256").update(wasmBuf).digest("hex"), seed: opts.seed,
        stages: opts.stages, frame_cap: opts.frames, stage_export: stageExport, sampled };
    fs.mkdirSync(path.dirname(opts.json), { recursive: true });
    fs.writeFileSync(opts.json, JSON.stringify({ meta, bots: results }, null, 2) + "\n");
    console.log(`difficulty: wrote ${path.relative(process.cwd(), opts.json)}`);
}
