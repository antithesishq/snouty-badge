#!/usr/bin/env node
// M4 app state machine test (PLAN.md M4 "App"): runs the cart in-process
// with input scripts and checks the frozen-mode behaviour against an M3
// baseline wasm.
//
//   node tools/test_app_m4.mjs --wasm new.wasm --baseline m3.wasm
//
// The baseline is the same cart before M4 (e.g. built at the M4 plan
// commit). The key property: an update that draws the real-time frame
// (unfrozen, stick held while frozen, and the first update of every
// accumulation) must produce the same debug_pixel_checksum as the baseline
// under the same input, since the M4 app only changes what frozen updates
// without the stick draw. With debug_set_pt(0) every update must match.
//
// Timing checks assume the knobs of the build (read from the cart where
// possible): max_passes = 256, wasm_columns_per_update = 40 (4 updates per
// pass), frozen_resume_s = 60 at 20 fps (1200 updates); pass --cols and
// --resume to override. Exit 0 all PASS, 1 any FAIL.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CART_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const wasmFile = opt("--wasm", path.resolve(CART_DIR, "../../zig-out/bin/snouty-reflections.wasm"));
const baseFile = opt("--baseline");
const COLS = Number(opt("--cols", 40));
const MAX_PASSES = Number(opt("--max-passes", 256));
const RESUME = Number(opt("--resume", 1200));
const UPDATES_PER_PASS = Math.ceil(160 / COLS);
if (!baseFile) { console.error("usage: test_app_m4.mjs [--wasm new.wasm] --baseline m3.wasm"); process.exit(2); }

const BTN = { START: 1 << 0, SELECT: 1 << 1, A: 1 << 2, B: 1 << 3, UP: 1 << 5, DOWN: 1 << 6, LEFT: 1 << 7, RIGHT: 1 << 8 };
const SIM_FB = 0x20, WIDTH = 160, HEIGHT = 128;

class Cart {
    constructor(file) {
        const module = new WebAssembly.Module(fs.readFileSync(file));
        this.memory = new WebAssembly.Memory({ initial: 64, maximum: 64 });
        const stubs = { memory: this.memory, tone() {}, trace() {}, rand: () => 4, read_flash: () => 0, write_flash_page() {},
            rect() {}, oval() {}, line() {}, hline() {}, vline() {}, text() {}, blit() {} };
        const env = {};
        for (const imp of WebAssembly.Module.imports(module)) env[imp.name] = stubs[imp.name];
        this.ex = new WebAssembly.Instance(module, { env }).exports;
        for (const init of ["_start", "_initialize"]) if (this.ex[init]) this.ex[init]();
        this.set(0);
        this.ex.start();
    }
    has(n) { return typeof this.ex[n] === "function"; }
    set(bits) { new DataView(this.memory.buffer).setUint16(0x04, bits, true); }
    // Simulator frame (0x20) as a Uint16Array copy, read before any other call.
    fb() { return new Uint16Array(this.memory.buffer.slice(SIM_FB, SIM_FB + WIDTH * HEIGHT * 2)); }
    step(bits) {
        this.set(bits);
        this.ex.update();
        const fb = this.fb();
        const q = (n) => (this.has(n) ? this.ex[n]() >>> 0 : null);
        return { sum: this.ex.debug_pixel_checksum() >>> 0, state: q("debug_state"), preset: q("debug_preset"), t: q("debug_t"),
            orbit: q("debug_orbit"), kind: q("debug_frame_kind"), dither: q("debug_dither_mode"), passes: q("debug_pt_passes"), fb };
    }
}

function bitsAt(script, i) {
    let b = 0;
    for (const e of script) if (i >= e.from && i <= e.to) for (const h of e.hold) b |= BTN[h.toUpperCase()];
    return b;
}
function loadScript(name) { return JSON.parse(fs.readFileSync(path.join(CART_DIR, "tools", "scripts", name), "utf8")); }
function run(file, script, n, setup) {
    const c = new Cart(file);
    if (setup) setup(c);
    const out = [];
    for (let i = 0; i < n; i++) { const r = step(c, script, i); out.push(r); }
    return { cart: c, frames: out };
}
function step(c, script, i) { const r = c.step(bitsAt(script, i)); delete r.fb; return r; }

let fails = 0;
function check(ok, what) { console.log(`${ok ? "PASS" : "FAIL"} ${what}`); if (!ok) fails++; }

// Updates whose checksum must equal the baseline's: the new cart drew the
// real-time frame (debug_frame_kind 0, or 1: the begin update, whose display
// is the real-time frame).
function realtimeMatches(a, b, from, to, label) {
    let bad = [];
    for (let i = from; i <= to; i++) {
        const r = a[i];
        const rt = r.kind !== 2;
        if (rt && r.sum !== b[i].sum) bad.push(i);
    }
    check(bad.length === 0, `${label}: real-time updates ${from}..${to} match the baseline${bad.length ? ` (differ at ${bad.slice(0, 8).join(", ")}${bad.length > 8 ? ", ..." : ""})` : ""}`);
}
function firstIndex(frames, pred, from = 0) { for (let i = from; i < frames.length; i++) if (pred(frames[i], i)) return i; return -1; }

// ---- 1. Untouched attract: identical to the baseline, every update 0..600.
{
    const a = run(wasmFile, [], 601).frames, b = run(baseFile, [], 601).frames;
    const bad = a.map((r, i) => (r.sum === b[i].sum ? -1 : i)).filter((i) => i >= 0);
    check(bad.length === 0, `attract: debug_pixel_checksum identical to baseline for updates 0..600 (${[0, 50, 100, 300, 600].map((i) => a[i].sum).join(" ")})`);
    check(a.every((r) => r.state === 0 && r.passes === 0), "attract: never frozen, pt never active");
}

// ---- 2. debug_set_pt(0): every script identical to the baseline.
for (const name of ["m4_freeze_sunset.json", "m4_frozen_stick.json", "m4_controls.json"]) {
    const s = loadScript(name);
    const a = run(wasmFile, s, 700, (c) => c.ex.debug_set_pt(0)).frames, b = run(baseFile, s, 700).frames;
    const bad = a.map((r, i) => (r.sum === b[i].sum && r.state === b[i].state && r.t === b[i].t ? -1 : i)).filter((i) => i >= 0);
    check(bad.length === 0 && a.every((r) => r.passes === 0), `debug_set_pt(0) ${name}: M3 behaviour, all 700 updates match the baseline`);
}

// ---- 3. Freeze in each preset, accumulation, convergence and auto-resume.
const doneAt = 100 + MAX_PASSES * UPDATES_PER_PASS; // last stepping update is doneAt
for (const [name, preset] of [["m4_freeze_sunset.json", 0], ["m4_freeze_midnight.json", 1], ["m4_freeze_noon.json", 2]]) {
    const s = loadScript(name);
    const n = doneAt + RESUME + 20;
    const a = run(wasmFile, s, n).frames, b = run(baseFile, s, 110).frames;
    check(a[99].state === 0 && a[100].state === 2 && a[100].preset === preset && a[100].t === 100,
        `${name}: frozen at update 100 in preset ${preset}, t = 100 (state ${a[100].state}, preset ${a[100].preset}, t ${a[100].t})`);
    check(a[100].sum === b[100].sum && a[100].passes === 0, `${name}: update 100 shows the real-time frame (pt begun, 0 passes)`);
    check(a[100 + UPDATES_PER_PASS].passes === 1 && a[100 + 10 * UPDATES_PER_PASS].passes === 10, `${name}: ${UPDATES_PER_PASS} updates per pass`);
    const d = firstIndex(a, (r) => r.passes === MAX_PASSES);
    check(d === doneAt, `${name}: ${MAX_PASSES} passes (done) at update ${d} (expected ${doneAt})`);
    const frozenT = a.slice(100, doneAt + RESUME).every((r) => r.state === 2 && r.t === 100 && r.preset === preset);
    check(frozenT, `${name}: time, preset and frozen state hold until the resume`);
    const resume = firstIndex(a, (r) => r.state !== 2, 100);
    check(resume === doneAt + RESUME, `${name}: auto-resume to attract at update ${resume} (expected ${doneAt + RESUME} = done + ${RESUME})`);
    if (resume > 0) check(a[resume].state === 0 && a[resume].passes === 0 && a[resume].t === 101 && a[resume + 1].t === 102,
        `${name}: resumed into attract, pt released, time runs on from 100`);
    check(a[doneAt + 5].sum === a[doneAt + 100].sum, `${name}: converged frames repeat`);
}

// ---- 4. Input after done() postpones the auto-resume.
{
    const s = [...loadScript("m4_freeze_sunset.json"), { from: doneAt + 500, to: doneAt + 500, hold: ["B"] }];
    const a = run(wasmFile, s, doneAt + 500 + RESUME + 10).frames;
    const resume = firstIndex(a, (r) => r.state !== 2, 100);
    check(resume === doneAt + 500 + RESUME, `auto-resume: a B press at done + 500 moves it to ${resume} (expected ${doneAt + 500 + RESUME})`);
    check(a[doneAt + 500].passes === MAX_PASSES, "auto-resume: B after done keeps the converged accumulation");
}

// ---- 5. Stick while frozen: real-time moving view, restart on release.
{
    const s = loadScript("m4_frozen_stick.json");
    const a = run(wasmFile, s, 600).frames, b = run(baseFile, s, 600).frames;
    realtimeMatches(a, b, 0, 599, "m4_frozen_stick");
    const pre = a[299].passes;
    check(pre === Math.floor(199 / UPDATES_PER_PASS), `stick: ${pre} passes before the stick`);
    check(a.slice(300, 340).every((r) => r.passes === 0 && r.state === 2 && r.t === 100), "stick: updates 300..339 real-time (pt released), still frozen at t = 100");
    check(a[300].orbit !== a[299].orbit && a[339].orbit !== a[300].orbit, `stick: the orbit moves (${a[299].orbit} -> ${a[300].orbit} -> ${a[339].orbit})`);
    check(a[340].passes === 0 && a[340].sum === b[340].sum && a[340].orbit === a[339].orbit, "stick: update 340 (released) draws the real-time frame and begins");
    check(a[340 + UPDATES_PER_PASS].passes === 1 && a[341].sum !== b[341].sum, "stick: accumulation restarted from 0 after the release");
    check(a[599].state === 2, "stick: no free-camera timeout while frozen");
    check(a[100].kind === 1 && a[101].kind === 2 && a.slice(300, 340).every((r) => r.kind === 0) && a[340].kind === 1 && a[341].kind === 2,
        "stick: debug_frame_kind begin at 100, step, real-time 300..339, begin at 340, step");
}

// ---- 6. Controls while frozen: B keeps, Select restarts, A resumes, Start attract.
{
    const s = loadScript("m4_controls.json");
    const a = run(wasmFile, s, 700).frames, b = run(baseFile, s, 700).frames;
    realtimeMatches(a, b, 0, 699, "m4_controls");
    check(a[200].dither !== a[199].dither && a[200].passes >= a[199].passes && a[200].passes > 0 && a[200].state === 2,
        `B: dither ${a[199].dither} -> ${a[200].dither}, accumulation kept (${a[199].passes} -> ${a[200].passes} passes)`);
    check(a[300].preset === (a[299].preset + 1) % 4 && a[300].passes === 0 && a[300].sum === b[300].sum && a[304].passes === 1,
        `Select: preset ${a[299].preset} -> ${a[300].preset}, accumulation restarted`);
    check(a[400].state !== 2 && a[400].passes === 0 && a[400].t === 101 && a[449].t === 150, `A frozen: unfrozen, time resumes (t ${a[400].t} .. ${a[449].t})`);
    check(a[450].state === 2 && a[450].passes === 0 && a[454].passes === 1, "A again: frozen, new accumulation");
    check(a[550].state === 0 && a[550].passes === 0 && a[551].t === a[550].t + 1, "Start frozen: attract, pt released, time runs");
}

// ---- 7. Debug exports: set_view, pt_run, passes, accum, restart.
{
    const c = new Cart(wasmFile);
    const need = ["debug_set_pt", "debug_pt_run", "debug_pt_passes", "debug_pt_accum", "debug_pt_restart", "debug_set_view", "debug_set_dither_mode"];
    check(need.every((n) => c.has(n)), "exports present");
    c.ex.debug_set_dither_mode(1);
    c.ex.debug_set_view(2, 150, 150, 1600);
    const f0 = c.step(0);
    check(f0.state === 2 && f0.preset === 2 && f0.passes === 0, "set_view (pt on): the next update is the real-time frame, pt begun");
    // Seed: the arena holds the real-time frame's RGB565 (stub layout: x * 128 + y).
    const addr = c.ex.debug_pt_accum() >>> 0;
    check(addr > 0 && addr % 8 === 0, `debug_pt_accum = 0x${addr.toString(16)}`);
    c.ex.debug_pt_run(3);
    check(c.ex.debug_pt_passes() === 3, `debug_pt_run(3) -> ${c.ex.debug_pt_passes()} passes`);
    const f1 = c.step(0);
    check(f1.passes === 3 || f1.passes === 4, `update after run keeps accumulating (${f1.passes})`);
    c.ex.debug_pt_restart();
    const f2 = c.step(0);
    check(f2.passes === 0 && f2.sum === f0.sum, "debug_pt_restart: the next update restarts from the real-time frame");
    // pt_run straight after set_view (no update in between) begins first.
    c.ex.debug_set_view(0, 300, 300, 1600);
    c.ex.debug_pt_run(2);
    check(c.ex.debug_pt_passes() === 2 && c.ex.debug_preset() === 0, "debug_pt_run right after set_view begins, then runs");
    c.ex.debug_set_pt(0);
    const f3 = c.step(0), f4 = c.step(0);
    check(f3.passes === 0 && f3.sum === f4.sum, "debug_set_pt(0) while frozen: real-time frames that repeat");
    c.ex.debug_set_pt(1);
    const f5 = c.step(0), f6 = c.step(0);
    check(f5.passes === 0 && f5.sum === f3.sum && f6.passes === 0 && f6.sum !== f5.sum, "debug_set_pt(1) while frozen: begins on the next update");
}

console.log(fails ? `${fails} FAIL` : "all PASS");
process.exit(fails ? 1 : 0);
