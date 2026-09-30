#!/usr/bin/env node
// Timeline regression for Snouty Scene: one full loop, headless.
//
//   node carts/snouty-scene/tools/check_timeline.mjs [--update] [--stride N]
//                                                   [--wasm zig-out/bin/snouty-scene.wasm]
//
// Reads the part lengths from cart/src/timeline.zig (`pub const bars`), then
// runs the cart once through the whole loop plus 60 frames with
//   node tools/preview.mjs <wasm> --frames L+60 --quiet --call-at T NAME ...
// and checks, from the exports it records:
//   - every N-th update (default 30), debug_part and debug_part_frame are the
//     part and frame the bar lengths predict;
//   - at every boundary the part index advances by one (wrapping to 0 after
//     the last part) and debug_part_frame drops from len - 1 to 0;
//   - debug_pixel_checksum of each part's frame 30 (after its fade-in)
//     matches tests/golden.json. --update writes golden.json from this run
//     instead (after the order checks pass).
// preview.mjs's --call-at T calls the export right after update #T; after
// update #T the clock already points at the frame update #T+1 renders, and
// debug_pixel_checksum is that of the frame update #T drew.
//
// Exit codes: 0 PASS (or updated), 1 golden.json missing (run --update),
// 2 usage error, 3 any FAIL (including a preview run that failed).
// No npm dependencies.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."); // this cart
const REPO = path.resolve(ROOT, "../.."); // repository root
const PREVIEW = path.join(REPO, "tools", "preview.mjs");
const TIMELINE = path.join(ROOT, "cart", "src", "timeline.zig");
const GOLDEN = path.join(ROOT, "tests", "golden.json");
const OUT = path.join(ROOT, "out", "check_timeline");
const FRAMES_PER_BAR = 120;
const GOLDEN_FRAME = 30;

function usage(msg) {
    if (msg) console.error(`check_timeline: ${msg}`);
    console.error("usage: node carts/snouty-scene/tools/check_timeline.mjs [--update] [--stride N] [--wasm FILE]");
    process.exit(2);
}

const opts = { update: false, stride: 30, wasm: path.join(REPO, "zig-out", "bin", "snouty-scene.wasm") };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    switch (a) {
        case "--update": opts.update = true; break;
        case "--stride": { const s = val(), n = Number(s); if (!Number.isInteger(n) || n < 1) usage(`--stride: bad integer '${s}'`); opts.stride = n; break; }
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}
if (!fs.existsSync(opts.wasm)) usage(`${path.relative(process.cwd(), opts.wasm)} not found (run zig build -Dcart=snouty-scene)`);

// ---------------------------------------------------------------- the plan
const src = fs.readFileSync(TIMELINE, "utf8");
const m = src.match(/pub const bars = \[_\]u8\{([^}]*)\}/);
if (!m) usage(`cannot find 'pub const bars' in ${path.relative(REPO, TIMELINE)}`);
const bars = m[1].split(",").map((s) => s.trim()).filter(Boolean).map(Number);
if (!bars.length || bars.some((b) => !Number.isInteger(b) || b < 1)) usage(`bad bars list '${m[1]}'`);
const lens = bars.map((b) => b * FRAMES_PER_BAR);
const starts = [];
let loop = 0;
for (const l of lens) { starts.push(loop); loop += l; }
const frames = loop + 60;

/** Part index and frame within it of global frame g (as rendered by update #g). */
function where(g) {
    let t = g % loop;
    for (let i = 0; i < lens.length; i++) {
        if (t < lens[i]) return { part: i, frame: t };
        t -= lens[i];
    }
    throw new Error("unreachable");
}

// Probes: [tick, export]. After update #T the clock names frame T + 1.
const probes = new Map(); // tick -> Set(names)
const probe = (tick, name) => { if (!probes.has(tick)) probes.set(tick, new Set()); probes.get(tick).add(name); };
for (let t = 0; t < frames; t += opts.stride) { probe(t, "debug_part"); probe(t, "debug_part_frame"); }
for (let i = 0; i <= lens.length; i++) {
    const s = i < lens.length ? starts[i] : loop; // boundary into part i (i == count: the wrap)
    if (s >= 2) { probe(s - 2, "debug_part"); probe(s - 2, "debug_part_frame"); }
    if (s >= 1) { probe(s - 1, "debug_part"); probe(s - 1, "debug_part_frame"); }
}
for (let i = 0; i < lens.length; i++) probe(starts[i] + GOLDEN_FRAME, "debug_pixel_checksum");

const args = [PREVIEW, opts.wasm, "--frames", String(frames), "--quiet", "--out", OUT];
for (const tick of [...probes.keys()].sort((a, b) => a - b)) for (const name of probes.get(tick)) args.push("--call-at", `${tick} ${name}`);

fs.mkdirSync(OUT, { recursive: true });
const r = spawnSync(process.execPath, args, { cwd: REPO, encoding: "utf8", maxBuffer: 64 << 20 });
if (r.status !== 0) {
    console.log(`FAIL preview exited ${r.status ?? r.signal}:\n    ${(r.stderr || "").trim().split("\n").slice(-4).join("\n    ")}`);
    process.exit(3);
}
const meta = JSON.parse(fs.readFileSync(path.join(OUT, "frames.json"), "utf8"));
const got = new Map(); // "tick name" -> value
for (const c of meta.calls ?? []) got.set(`${c.tick} ${c.name}`, c.value >>> 0);
const value = (tick, name) => {
    const v = got.get(`${tick} ${name}`);
    if (v === undefined) throw new Error(`no recorded value for ${name} after update #${tick}`);
    return v;
};

// ---------------------------------------------------------------- checks
const failures = [];
let checks = 0;
const expect = (ok, msg) => { checks++; if (!ok) failures.push(msg); };

for (let t = 0; t < frames; t += opts.stride) {
    const w = where(t + 1);
    const p = value(t, "debug_part"), f = value(t, "debug_part_frame");
    expect(p === w.part && f === w.frame, `after update #${t}: part ${p} frame ${f}, expected part ${w.part} frame ${w.frame}`);
}
for (let i = 0; i <= lens.length; i++) {
    const s = i < lens.length ? starts[i] : loop;
    if (s < 2) continue;
    const prev = i === 0 ? lens.length - 1 : i - 1;
    const next = i % lens.length;
    const pb = value(s - 2, "debug_part"), fb = value(s - 2, "debug_part_frame");
    const pa = value(s - 1, "debug_part"), fa = value(s - 1, "debug_part_frame");
    expect(pb === prev && fb === lens[prev] - 1, `boundary into part ${next}: before it part ${pb} frame ${fb}, expected part ${prev} frame ${lens[prev] - 1}`);
    expect(pa === next && fa === 0, `boundary into part ${next}: part ${pa} frame ${fa}, expected part ${next} frame 0`);
    expect(pa === (pb + 1) % lens.length, `boundary into part ${next}: index went ${pb} -> ${pa}, not +1`);
}

const sums = lens.map((_, i) => value(starts[i] + GOLDEN_FRAME, "debug_pixel_checksum"));

console.log(`check_timeline: ${lens.length} parts, loop ${loop} frames (${loop / 60} s), ${frames} updates, stride ${opts.stride}`);
if (failures.length) {
    for (const f of failures) console.log(`FAIL ${f}`);
    console.log(`check_timeline: ${failures.length} of ${checks} order checks FAILED`);
    process.exit(3);
}
console.log(`PASS order: ${checks} checks (every part in order, frame counter resets at each boundary, wraps to 0)`);

if (opts.update) {
    fs.mkdirSync(path.dirname(GOLDEN), { recursive: true });
    const golden = { comment: "debug_pixel_checksum of each part's frame 30, one full loop from start(); written by tools/check_timeline.mjs --update", bars, frame: GOLDEN_FRAME, checksums: sums };
    fs.writeFileSync(GOLDEN, JSON.stringify(golden, null, 2) + "\n");
    console.log(`UPDATED ${path.relative(REPO, GOLDEN)}: ${sums.join(", ")}`);
    process.exit(0);
}
if (!fs.existsSync(GOLDEN)) { console.log(`check_timeline: ${path.relative(REPO, GOLDEN)} missing; run with --update`); process.exit(1); }
const golden = JSON.parse(fs.readFileSync(GOLDEN, "utf8"));
let bad = 0;
if (JSON.stringify(golden.bars) !== JSON.stringify(bars) || golden.frame !== GOLDEN_FRAME) {
    console.log(`FAIL golden.json was written for bars [${golden.bars}] (frame ${golden.frame}); the timeline now has [${bars}]: rerun with --update if the change is intended`);
    process.exit(3);
}
for (let i = 0; i < lens.length; i++) {
    const ok = golden.checksums[i] === sums[i];
    if (!ok) bad++;
    console.log(`${ok ? "PASS" : "FAIL"} part ${String(i).padStart(2)} frame ${GOLDEN_FRAME}: checksum ${sums[i]}${ok ? "" : ` (golden ${golden.checksums[i]})`}`);
}
if (bad) { console.log(`check_timeline: ${bad} checksum(s) differ from golden.json`); process.exit(3); }
console.log("check_timeline: PASS");
