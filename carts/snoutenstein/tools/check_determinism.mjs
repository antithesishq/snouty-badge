#!/usr/bin/env node
// Determinism check: runs the same scripted game twice and compares exports.
//
//   node tools/check_determinism.mjs <cart.wasm> --script FILE.json --frames F
//                                    [--exports debug_state_hash,debug_tick]
//                                    [--rewind-at T --rewind-for N]
//
// Plain mode: runs the shared ../../tools/preview.mjs twice (--quiet
// --dump-exports) into a temp dir, reads both frames.json "exports" and
// asserts every listed export equal. debug_desync is always added to the
// list when the wasm exports it.
//
// Rewind mode (--rewind-at T --rewind-for N, update indices, 0-based,
// T + N < F): run 1 is the script unchanged, sampling debug_tick and
// debug_gameplay_hash (--call-at) after every update in [max(0, T-1-N), T-1].
// Run 2 is a temp copy of the script with {"from": T, "to": T+N-1, "hold":
// ["B"]} appended, sampling debug_tick, debug_gameplay_hash, debug_mode,
// debug_rewinds and debug_desync after update T+N (the release frame, which
// commits and does not step). Asserts: run 2 at T+N is playing (debug_mode
// 1) with debug_rewinds >= 1; its tick is one run 1 sampled in the window,
// with the same debug_gameplay_hash; debug_desync == 0 after the last update
// of both runs. Fails with exit 2 if the script already holds B in [T, T+N-1].
//
// Prints one line: PASS/FAIL, then NAME=VALUE (NAME=RUN1|RUN2 when they differ).
// Exit codes: 0 pass, 2 usage, 3 mismatch or a failed run.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const preview = path.join(here, "../../../tools/preview.mjs"); // the shared tool at the repository root

let tmp = null; // temp dir, removed on every exit path
function usage(msg) {
    if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
    if (msg) console.error(`check_determinism: ${msg}`);
    console.error("usage: node tools/check_determinism.mjs <cart.wasm> --script FILE.json --frames N\n" +
        "                                   [--exports NAME[,NAME...]] [--rewind-at T --rewind-for N]");
    process.exit(2);
}

const argv = process.argv.slice(2);
let wasm = null, script = null, frames = null, exportsList = ["debug_state_hash", "debug_tick"];
let rewindAt = null, rewindFor = null;
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = (s) => { if (!/^\d+$/.test(s)) usage(`${a}: not a non-negative integer: ${s}`); return Number(s); };
    switch (a) {
        case "--script": script = val(); break;
        case "--frames": frames = int(val()); break;
        case "--exports": exportsList = val().split(",").map((s) => s.trim()).filter(Boolean); break;
        case "--rewind-at": rewindAt = int(val()); break;
        case "--rewind-for": rewindFor = int(val()); break;
        case "-h": case "--help": usage();
        default:
            if (a.startsWith("--")) usage(`unknown option ${a}`);
            if (wasm) usage(`unexpected argument ${a}`);
            wasm = a;
    }
}
if (!wasm) usage("missing <cart.wasm>");
if (!script) usage("missing --script");
if (!frames) usage("missing --frames (> 0)");
if (!exportsList.length) usage("--exports: empty list");
const rewinding = rewindAt !== null || rewindFor !== null;
if (rewinding) {
    if (rewindAt === null || rewindFor === null) usage("--rewind-at and --rewind-for go together");
    if (rewindFor < 1) usage("--rewind-for must be at least 1");
    if (rewindAt + rewindFor >= frames)
        usage(`--rewind-at ${rewindAt} --rewind-for ${rewindFor}: needs T + N < --frames (${rewindAt + rewindFor} >= ${frames}); the release frame T+N must run`);
}

// Which exports does the wasm have? (Compiling the module is cheap and needs no imports.)
let wasmExports;
try { wasmExports = WebAssembly.Module.exports(new WebAssembly.Module(fs.readFileSync(wasm))).map((e) => e.name); }
catch (e) { console.error(`check_determinism: cannot read ${wasm}: ${e.message}`); process.exit(2); }
const compared = [...exportsList];
if (wasmExports.includes("debug_desync") && !compared.includes("debug_desync")) compared.push("debug_desync");
if (rewinding) {
    const need = ["debug_tick", "debug_gameplay_hash", "debug_mode", "debug_rewinds", "debug_desync"];
    const missing = need.filter((n) => !wasmExports.includes(n));
    if (missing.length) { console.error(`check_determinism: --rewind-*: ${wasm} does not export ${missing.join(", ")}`); process.exit(2); }
}

tmp = fs.mkdtempSync(path.join(os.tmpdir(), "determinism-"));
// Runs preview.mjs and returns its frames.json; exits on a failed run.
function run(label, scriptFile, callAts) {
    const out = path.join(tmp, label);
    const args = [preview, wasm, "--quiet", "--out", out, "--script", scriptFile, "--frames", String(frames),
        "--dump-exports", compared.join(",")];
    for (const [t, n] of callAts) args.push("--call-at", String(t), n);
    const r = spawnSync(process.execPath, args, { encoding: "utf8", maxBuffer: 64 << 20 });
    if (r.status !== 0) {
        process.stderr.write(r.stderr || "");
        console.error(`check_determinism: ${label}: preview.mjs exited ${r.status ?? r.signal}`);
        fs.rmSync(tmp, { recursive: true, force: true });
        process.exit(r.status === 2 ? 2 : 3);
    }
    return JSON.parse(fs.readFileSync(path.join(out, "frames.json"), "utf8"));
}

const name = path.basename(script);
try {
    if (!rewinding) {
        const [a, b] = [run("run1", script, []).exports, run("run2", script, []).exports];
        const bad = compared.filter((n) => a[n] !== b[n]);
        const cells = compared.map((n) => a[n] === b[n] ? `${n}=${a[n]}` : `${n}=${a[n]}|${b[n]}`);
        console.log(`check_determinism: ${bad.length ? "FAIL" : "PASS"} ${name} x${frames}: ${cells.join(" ")}` +
            (bad.length ? ` (differ: ${bad.join(", ")})` : ""));
        process.exitCode = bad.length ? 3 : 0;
    } else {
        const T = rewindAt, N = rewindFor, rel = T + N;
        // Temp script with the B hold appended; refuse if the script already holds B there.
        let list;
        try { list = JSON.parse(fs.readFileSync(script, "utf8")); } catch (e) { usage(`--script ${script}: ${e.message}`); }
        if (!Array.isArray(list)) usage(`--script ${script}: top level must be a JSON array`);
        const clash = list.find((e) => e && Array.isArray(e.hold) && e.hold.some((b) => String(b).toUpperCase() === "B") &&
            e.from <= T + N - 1 && e.to >= T);
        if (clash) usage(`--script ${script} already holds B in ${JSON.stringify(clash)}, overlapping the rewind hold ${T}..${T + N - 1}`);
        const script2 = path.join(tmp, "rewind_" + name);
        fs.writeFileSync(script2, JSON.stringify([...list, { from: T, to: T + N - 1, hold: ["B"] }]));

        const lo = Math.max(0, T - 1 - N), hi = T - 1;
        const calls1 = [];
        for (let f = lo; f <= hi; f++) calls1.push([f, "debug_tick"], [f, "debug_gameplay_hash"]);
        const probes = ["debug_tick", "debug_gameplay_hash", "debug_mode", "debug_rewinds", "debug_desync"];
        const r1 = run("run1", script, calls1);
        const r2 = run("run2", script2, probes.map((n) => [rel, n]));

        // Run 1 samples: frame -> {tick, hash}; run 2 probe values at the release frame.
        const samples = new Map();
        for (const c of r1.calls) {
            if (!samples.has(c.tick)) samples.set(c.tick, {});
            samples.get(c.tick)[c.name === "debug_tick" ? "tick" : "hash"] = c.value;
        }
        const p = Object.fromEntries(r2.calls.filter((c) => c.tick === rel).map((c) => [c.name, c.value]));
        const from = samples.get(hi)?.tick, to = p.debug_tick;
        const ticks = [...samples.values()].map((s) => s.tick);
        // The latest frame showing that tick: the live state just before it stepped on (title frames repeat tick 0).
        const match = [...samples.entries()].filter(([, s]) => s.tick === to).pop();
        const fails = [];
        if (p.debug_mode !== 1) fails.push(`debug_mode=${p.debug_mode} after release frame ${rel}, want 1 (playing)`);
        if (!(p.debug_rewinds >= 1)) fails.push(`debug_rewinds=${p.debug_rewinds} after release frame ${rel}, want >= 1`);
        if (!match) {
            const got = from - to;
            fails.push(`tick ${to} after release frame ${rel} is not among run 1's ticks ${Math.min(...ticks)}..${Math.max(...ticks)} ` +
                `(frames ${lo}..${hi}): the rewind went ${got} ticks back from tick ${from}, asked ${N}` +
                (got < N ? " (shorter than asked: meter or history bound)" : ""));
        } else if (match[1].hash !== p.debug_gameplay_hash) {
            fails.push(`debug_gameplay_hash=${match[1].hash}|${p.debug_gameplay_hash} at tick ${to} (run 1 frame ${match[0]} | run 2 frame ${rel})`);
        }
        const d1 = r1.exports.debug_desync, d2 = r2.exports.debug_desync;
        if (d1 !== 0 || d2 !== 0) fails.push(`debug_desync=${d1}|${d2} after the last update, want 0|0`);

        const head = `check_determinism: ${fails.length ? "FAIL" : "PASS"} ${name} x${frames} rewind@${T}+${N}:`;
        const got = match ? `rewound from tick ${from} to tick ${to}, ${from - to} ticks` +
            (from - to < N ? ` (shorter than the ${N} asked)` : "") +
            `; debug_gameplay_hash=${p.debug_gameplay_hash} debug_rewinds=${p.debug_rewinds}` +
            (fails.length ? "" : ` debug_desync=${d1}|${d2}`) : "";
        console.log(`${head} ${[got, ...fails].filter(Boolean).join("; ")}`);
        process.exitCode = fails.length ? 3 : 0;
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}
