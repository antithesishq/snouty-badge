#!/usr/bin/env node
// Check the M4 path tracer (cart/src/pt.zig) against tools/reference.py --pt
// (PLAN.md M4 "Reference and check (Track C)").
//
//   node tools/check_pt.mjs [--wasm cart.wasm] [--variant cut20] [--view P:T[:O[:H]]]... [--only]
//                           [--checks 1,2,3] [--jobs N] [--out DIR] [--ref-only]
//
// Per view the cart is loaded in-process (as check_render.mjs does) and
// driven through its debug exports: debug_set_dither_mode(1) (none),
// debug_set_pt(1), debug_set_view(preset, t, orbit, height_mm), then:
//
//   3. Seed. The next update() draws the real-time frame and calls
//      pt.begin (no column traced yet). The accumulator (debug_pt_accum(),
//      160 x 128 u32, 11:11:10 over [0, 4)) is decoded, saturated and
//      quantised as display() does in dither `none` (floor(c * max + 1e-4)
//      in f32) and must reproduce that frame exactly, every pixel. Then one
//      more update() (step + display()): every column whose accumulator
//      words are still the seed must show exactly the real-time frame (at
//      least one such column must exist unless the update traced them all).
//   1. Same samples. debug_pt_restart(), debug_pt_run(16): the cart's 16
//      passes against reference.py --pt --passes 16: at least 98% of the
//      channel values within 3 units and the mean absolute difference at
//      most 0.5 (8-bit units of [0, 1], means saturated to [0, 1]). An
//      extra line (not gated) compares against reference.py --accum, the
//      simulated u32 accumulator with its stochastic rounding: identical
//      words there mean the same samples, bit for bit up to f32 rounding.
//   2. Convergence. Continuing to 64 and 256 passes (debug_pt_run(48),
//      debug_pt_run(192)): RMSE against the 1024-pass reference at 16, 64 and
//      256 passes decreases, RMSE(64) / RMSE(256) >= 1.6 and RMSE(256) <= 4.0
//      units.
//
// debug_pt_passes() must read 16, 64 and 256 after the runs. Check set
// (default; --only drops it and keeps the --view list): each preset at
// t = 0, orbit 0; sunset at t = 300 (orbit 300); noon at height 1.0.
// References come from out/pt_ref/ (reference.py caches them there; the
// first run renders the missing ones, about 30 s per 1024-pass view on two
// cores). --ref-only runs check 2 on the reference itself (its own 16, 64
// and 256-pass means against 1024), no cart needed: a sanity check of the
// thresholds.
//
// The accumulator layout is one constant, ACCUM_INDEX below: word index
// x * 128 + y (column-major, like the framebuffer). Exit codes: 0 PASS,
// 3 FAIL, 2 usage or missing exports, 1 reference.py failed or the cart
// trapped. Output: cart_<view>_nNNNN.png (the cart mean, dither none) and
// absdiff_<view>_n0016.png (|cart - ref| * 40) in --out (default
// out/check_pt).
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const WIDTH = 160, HEIGHT = 128;
// Accumulator word index of pixel (x, y). Column-major like cart.framebuffer
// (arena.words[x * 128 + y]); if pt.zig chooses row-major, change this line.
const ACCUM_INDEX = (x, y) => x * HEIGHT + y;

// PLAN.md M4 "Reference and check" limits.
const SAME_UNITS = 3, SAME_FRACTION = 0.98, SAME_MEAN_ABS = 0.5;
const RATIO_64_256 = 1.6, RMSE_256_MAX = 4.0;
const PASSES = [16, 64, 256], REF_PASSES = 1024;

const PRESETS = ["sunset", "midnight", "noon", "storm"];
const DEFAULT_HEIGHT_MM = 1600;
const CART_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REFERENCE = path.join(CART_DIR, "tools", "reference.py");
const NEED = ["start", "update", "debug_set_view", "debug_set_dither_mode", "debug_set_pt", "debug_pt_run",
    "debug_pt_passes", "debug_pt_accum", "debug_pt_restart"];

function usage(msg) {
    if (msg) console.error(`check_pt: ${msg}`);
    console.error("usage: node tools/check_pt.mjs [--wasm cart.wasm] [--variant cut20] [--view P:T[:O[:H]]]... [--only]\n" +
        "              [--checks 1,2,3] [--jobs N] [--out DIR] [--ref-only]");
    process.exit(2);
}

// ---------------------------------------------------------------- PNG encode
const CRC_TABLE = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(buf) { let c = 0xffffffff; for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
}
function encodePNG(rgb, w, h) {
    const raw = Buffer.alloc((w * 3 + 1) * h);
    for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; rgb.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3); }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
    return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr),
        chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

// ---------------------------------------------------------------- images
// A mean image is a Float64Array of H * W * 3, row-major (y * W + x) * 3 + c,
// the layout of reference.py's (128, 160, 3) .npy.
function readNpy(file) {
    const buf = fs.readFileSync(file);
    if (buf.toString("latin1", 1, 6) !== "NUMPY") throw new Error(`${file}: not a .npy file`);
    const major = buf[6];
    const hlen = major === 1 ? buf.readUInt16LE(8) : buf.readUInt32LE(8);
    const off = major === 1 ? 10 : 12;
    const header = buf.toString("latin1", off, off + hlen);
    if (!/'descr':\s*'<f8'/.test(header) || /'fortran_order':\s*True/.test(header)) throw new Error(`${file}: want C-order <f8, got ${header.trim()}`);
    const shape = header.match(/'shape':\s*\(([^)]*)\)/)[1].split(",").map((s) => s.trim()).filter(Boolean).map(Number);
    if (shape.join(",") !== `${HEIGHT},${WIDTH},3`) throw new Error(`${file}: shape (${shape}) is not (${HEIGHT}, ${WIDTH}, 3)`);
    const data = buf.subarray(off + hlen);
    const out = new Float64Array(HEIGHT * WIDTH * 3);
    for (let i = 0; i < out.length; i++) out[i] = data.readDoubleLE(i * 8);
    return out;
}

// 11:11:10 fixed point over [0, 4): r bits 0-10 / 512, g 11-21 / 512, b 22-31 / 256.
function decodeAccum(words) {
    const img = new Float64Array(HEIGHT * WIDTH * 3);
    for (let x = 0; x < WIDTH; x++) for (let y = 0; y < HEIGHT; y++) {
        const w = words[ACCUM_INDEX(x, y)] >>> 0, i = (y * WIDTH + x) * 3;
        img[i] = (w & 0x7ff) / 512; img[i + 1] = ((w >>> 11) & 0x7ff) / 512; img[i + 2] = (w >>> 22) / 256;
    }
    return img;
}

const sat8 = (v) => Math.min(1, Math.max(0, v)) * 255;

// Dither `none` as dither.quantise does it in f32: floor(c * max + 1e-4), c saturated.
const F = Math.fround, TH = F(1e-4), MAXV = [31, 63, 31];
function quantiseNone(img) {
    const q = new Uint8Array(HEIGHT * WIDTH * 3);
    for (let i = 0; i < q.length; i++) {
        const c = F(Math.min(1, Math.max(0, img[i])));
        q[i] = Math.floor(F(F(c * MAXV[i % 3]) + TH));
    }
    return q;
}
function to8(q565) {
    const rgb = Buffer.alloc(q565.length);
    for (let i = 0; i < q565.length; i++) rgb[i] = Math.round((q565[i] * 255) / MAXV[i % 3]);
    return rgb;
}

// Per-channel statistics in 8-bit units of [0, 1].
function compareMeans(a, b) {
    let within = 0, sumAbs = 0, sumSq = 0, maxAbs = 0, maxAt = 0;
    for (let i = 0; i < a.length; i++) {
        const d = Math.abs(sat8(a[i]) - sat8(b[i]));
        if (d <= SAME_UNITS) within++;
        sumAbs += d; sumSq += d * d;
        if (d > maxAbs) { maxAbs = d; maxAt = i; }
    }
    const n = a.length, p = Math.floor(maxAt / 3);
    return { within: within / n, meanAbs: sumAbs / n, rmse: Math.sqrt(sumSq / n), maxAbs, maxAt: { x: p % WIDTH, y: Math.floor(p / WIDTH), ch: "rgb"[maxAt % 3] } };
}

function absDiffPNG(a, b) {
    const rgb = Buffer.alloc(a.length);
    for (let i = 0; i < a.length; i++) rgb[i] = Math.min(255, Math.round(Math.abs(sat8(a[i]) - sat8(b[i])) * 40));
    return encodePNG(rgb, WIDTH, HEIGHT);
}

// ---------------------------------------------------------------- views and references
function parsePreset(s) {
    const t = String(s).trim().toLowerCase();
    if (/^\d$/.test(t) && Number(t) < PRESETS.length) return Number(t);
    const i = PRESETS.indexOf(t);
    if (i < 0) usage(`unknown preset '${s}' (want ${PRESETS.join(", ")} or 0..3)`);
    return i;
}
const pad4 = (n) => String(n).padStart(4, "0");
const viewName = (v) => `${PRESETS[v.preset]}_t${pad4(v.t)}_o${pad4(v.orbit)}_h${pad4(v.mm)}`;
const viewArg = (v) => `${PRESETS[v.preset]}:${v.t}:${v.orbit}:${(v.mm / 1000).toFixed(3)}`;

function checkSet() {
    return [0, 1, 2, 3].map((p) => ({ preset: p, t: 0, orbit: 0, mm: DEFAULT_HEIGHT_MM }))
        .concat([{ preset: 0, t: 300, orbit: 300, mm: DEFAULT_HEIGHT_MM }, { preset: 2, t: 0, orbit: 0, mm: 1000 }]);
}

// The reference mean of passes 0 .. n-1 (rendered and cached by reference.py);
// accum: the simulated u32 accumulator instead (reference.py --accum).
function reference(v, n, jobs, accum = false) {
    const argv = [REFERENCE, "--pt", "--passes", String(n), "--view", viewArg(v)];
    if (accum) argv.push("--accum");
    if (jobs) argv.push("--jobs", String(jobs));
    const r = spawnSync("python3", argv, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8" });
    if (r.error || r.status !== 0) { console.error(`check_pt: python3 ${argv.join(" ")} failed${r.error ? `: ${r.error.message}` : ` (exit ${r.status})`}`); process.exit(1); }
    const file = r.stdout.trim().split("\n").pop();
    return readNpy(file);
}

// ---------------------------------------------------------------- in-process cart runner (as check_render.mjs)
const SIM_FB = 0x20, ADDR_CONTROLS = 0x04;
class Cart {
    constructor(file) {
        let buf;
        try { buf = fs.readFileSync(file); } catch (e) { usage(`cannot read ${file}: ${e.message}`); }
        const module = new WebAssembly.Module(buf);
        this.memory = new WebAssembly.Memory({ initial: 64, maximum: 64 });
        const stubs = { memory: this.memory, tone() {}, trace() {}, rand: () => 4, read_flash: () => 0, write_flash_page() {},
            rect() {}, oval() {}, line() {}, hline() {}, vline() {}, text() {}, blit() {} };
        const env = {};
        for (const imp of WebAssembly.Module.imports(module)) {
            if (imp.module !== "env" || !(imp.name in stubs)) usage(`${file}: imports ${imp.module}.${imp.name}, which this runner does not provide`);
            env[imp.name] = stubs[imp.name];
        }
        this.file = file;
        this.ex = new WebAssembly.Instance(module, { env }).exports;
        const missing = NEED.filter((n) => typeof this.ex[n] !== "function");
        if (missing.length) { console.error(`check_pt: ${file} does not export ${missing.join(", ")} (PLAN.md M4 "Fixed interfaces")`); process.exit(2); }
        for (const init of ["_start", "_initialize"]) if (typeof this.ex[init] === "function") this.call(init);
        this.setControls(0);
        this.call("start");
    }
    call(name, ...args) {
        try { return this.ex[name](...args); } catch (e) { console.error(`check_pt: ${this.file}: ${name}() trapped: ${e.message}`); process.exit(1); }
    }
    setControls(bits) { new DataView(this.memory.buffer).setUint16(ADDR_CONTROLS, bits, true); }
    // update() and the frame it presented, as 565 units (row-major, 3 per pixel),
    // read before any other export call (the shadow stack overlaps 0x20).
    update() {
        this.call("update");
        const m = new Uint8Array(this.memory.buffer), q = new Uint8Array(HEIGHT * WIDTH * 3);
        for (let x = 0; x < WIDTH; x++) for (let y = 0; y < HEIGHT; y++) {
            const o = SIM_FB + (x * HEIGHT + y) * 2;
            const c = (m[o] << 8) | m[o + 1];
            const i = (y * WIDTH + x) * 3;
            q[i] = (c >> 11) & 0x1f; q[i + 1] = (c >> 5) & 0x3f; q[i + 2] = c & 0x1f;   // pre-swapped for the simulator
        }
        return q;
    }
    accumWords() {
        const addr = this.call("debug_pt_accum") >>> 0;
        if (addr % 4 || addr + WIDTH * HEIGHT * 4 > this.memory.buffer.byteLength) { console.error(`check_pt: debug_pt_accum() = ${addr}: not an aligned 80 KB block in memory`); process.exit(1); }
        return new Uint32Array(this.memory.buffer.slice(addr, addr + WIDTH * HEIGHT * 4));
    }
    passes() { return this.call("debug_pt_passes") >>> 0; }
}

function defaultWasm(variant) {
    const built = path.join(CART_DIR, "dist", "variants", `${variant}.wasm`);
    if (fs.existsSync(built)) return built;
    const wasm = path.resolve(CART_DIR, "..", "..", "zig-out", "bin", "snouty-reflections.wasm");
    console.error(`check_pt: warning: ${path.relative(process.cwd(), built)} not found; using ${path.relative(process.cwd(), wasm)}`);
    return wasm;
}

// ---------------------------------------------------------------- checks
function checkSeed(cart, v, lines) {
    const frame = cart.update();                    // real-time frame + pt.begin
    const n0 = cart.passes();
    const seed = cart.accumWords();
    const shown = quantiseNone(decodeAccum(seed));
    let bad = 0, first = null;
    for (let i = 0; i < shown.length; i += 3) {
        if (shown[i] !== frame[i] || shown[i + 1] !== frame[i + 1] || shown[i + 2] !== frame[i + 2]) {
            bad++;
            if (!first) { const p = i / 3; first = `(${p % WIDTH}, ${Math.floor(p / WIDTH)}) seed ${shown[i]},${shown[i + 1]},${shown[i + 2]} frame ${frame[i]},${frame[i + 1]},${frame[i + 2]}`; }
        }
    }
    let ok = bad === 0 && n0 === 0;
    lines.push(`  3 seed: decoded accumulator in dither none vs the real-time frame: ${bad} pixels differ${first ? `, first ${first}` : ""}; passes ${n0}${n0 !== 0 ? " (want 0)" : ""}  ${ok ? "ok" : "FAIL"}`);
    // One step + display(): untouched columns must still show the real-time frame.
    const next = cart.update();
    const after = cart.accumWords();
    let untouched = 0, badCols = 0;
    for (let x = 0; x < WIDTH; x++) {
        let same = true;
        for (let y = 0; y < HEIGHT && same; y++) same = after[ACCUM_INDEX(x, y)] === seed[ACCUM_INDEX(x, y)];
        if (!same) continue;
        untouched++;
        for (let y = 0; y < HEIGHT; y++) {
            const i = (y * WIDTH + x) * 3;
            if (next[i] !== frame[i] || next[i + 1] !== frame[i + 1] || next[i + 2] !== frame[i + 2]) { badCols++; break; }
        }
    }
    const ok2 = badCols === 0 && (untouched > 0 || cart.passes() > 0);
    lines.push(`  3 seed: after one frozen update, ${WIDTH - untouched} columns traced, ${untouched} untouched; ${badCols} untouched columns differ from the real-time frame  ${ok2 ? "ok" : "FAIL"}`);
    return ok && ok2;
}

function runTo(cart, target) {
    const have = cart.passes();
    if (have < target) cart.call("debug_pt_run", target - have);
    const n = cart.passes();
    return n;
}

function checkView(cart, v, checks, jobs, outDir) {
    const lines = [], name = viewName(v);
    let pass = true;
    cart.setControls(0);
    cart.call("debug_set_dither_mode", 1);
    cart.call("debug_set_pt", 1);
    cart.call("debug_set_view", v.preset, v.t, v.orbit, v.mm);
    if (checks.has(3)) pass = checkSeed(cart, v, lines) && pass;
    else cart.update();
    if (checks.has(1) || checks.has(2)) {
        cart.call("debug_pt_restart");
        const rmse = [];
        const ref1024 = checks.has(2) ? reference(v, REF_PASSES, jobs) : null;
        for (const n of PASSES) {
            if (n > 16 && !checks.has(2)) break;
            const got = runTo(cart, n);
            if (got !== n) { lines.push(`  debug_pt_passes() = ${got} after running to ${n}  FAIL`); pass = false; break; }
            const mean = decodeAccum(cart.accumWords());
            fs.writeFileSync(path.join(outDir, `cart_${name}_n${pad4(n)}.png`), encodePNG(to8(quantiseNone(mean)), WIDTH, HEIGHT));
            if (n === 16 && checks.has(1)) {
                const ref16 = reference(v, 16, jobs);
                const s = compareMeans(mean, ref16);
                const ok = s.within >= SAME_FRACTION && s.meanAbs <= SAME_MEAN_ABS;
                lines.push(`  1 same samples (16 passes): ${(100 * s.within).toFixed(2)}% within ${SAME_UNITS} units (want >= ${100 * SAME_FRACTION}%), ` +
                    `mean |d| ${s.meanAbs.toFixed(3)} (want <= ${SAME_MEAN_ABS}), max ${s.maxAbs.toFixed(1)} at (${s.maxAt.x}, ${s.maxAt.y}) ${s.maxAt.ch}  ${ok ? "ok" : "FAIL"}`);
                fs.writeFileSync(path.join(outDir, `absdiff_${name}_n0016.png`), absDiffPNG(mean, ref16));
                pass = ok && pass;
                // Not gated: the same 16 passes through a simulation of the
                // accumulator (stochastic rounding included). Most of check 1's
                // mean |d| is the accumulator's own rounding (about 0.2 units
                // in r and g, 0.4 to 0.6 in b); this line shows the tracer's.
                const acc16 = reference(v, 16, null, true);
                let same = 0;
                for (let i = 0; i < mean.length; i++) if (mean[i] === acc16[i]) same++;
                const sa = compareMeans(mean, acc16);
                lines.push(`    (info) vs the simulated accumulator: ${(100 * same / mean.length).toFixed(2)}% of channel values identical, ` +
                    `mean |d| ${sa.meanAbs.toFixed(4)}, max ${sa.maxAbs.toFixed(1)} at (${sa.maxAt.x}, ${sa.maxAt.y}) ${sa.maxAt.ch}`);
            }
            if (ref1024) rmse.push([n, compareMeans(mean, ref1024).rmse]);
        }
        if (checks.has(2) && rmse.length === PASSES.length) pass = convergence(rmse, lines) && pass;
    }
    return { name, pass, lines };
}

function convergence(rmse, lines) {
    const r = Object.fromEntries(rmse);
    const dec = r[16] > r[64] && r[64] > r[256];
    const ratio = r[64] / r[256];
    const ok = dec && ratio >= RATIO_64_256 && r[256] <= RMSE_256_MAX;
    lines.push(`  2 convergence vs ${REF_PASSES} passes: RMSE ${rmse.map(([n, e]) => `${n}: ${e.toFixed(3)}`).join(", ")} units; ` +
        `${dec ? "decreasing" : "NOT decreasing"}, 64/256 ratio ${ratio.toFixed(2)} (want >= ${RATIO_64_256}), ` +
        `RMSE(256) ${r[256].toFixed(3)} (want <= ${RMSE_256_MAX})  ${ok ? "ok" : "FAIL"}`);
    return ok;
}

function refOnly(v, jobs) {
    const lines = [], ref1024 = reference(v, REF_PASSES, jobs);
    const rmse = PASSES.map((n) => [n, compareMeans(reference(v, n, jobs), ref1024).rmse]);
    return { name: viewName(v), pass: convergence(rmse, lines), lines };
}

// ---------------------------------------------------------------- main
const args = process.argv.slice(2);
let wasm = null, variant = "cut20", only = false, outDir = null, jobs = null, refOnlyMode = false;
let checks = new Set([1, 2, 3]);
const views = [];
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const val = () => { const v = args[++i]; if (v === undefined) usage(`${a} needs a value`); return v; };
    const int = (s) => { const n = Number(s); if (!Number.isInteger(n) || n < 0) usage(`${a}: '${s}' is not an integer >= 0`); return n; };
    if (a === "--wasm") wasm = val();
    else if (a === "--variant") variant = val();
    else if (a === "--out") outDir = val();
    else if (a === "--jobs") jobs = int(val());
    else if (a === "--only") only = true;
    else if (a === "--ref-only") refOnlyMode = true;
    else if (a === "--checks") {
        checks = new Set(val().split(",").map((s) => Number(s.trim())));
        if ([...checks].some((c) => ![1, 2, 3].includes(c))) usage("--checks takes a list of 1, 2, 3");
    } else if (a === "--view") {
        const s = val(), p = s.split(":");
        if (p.length < 2 || p.length > 4) usage(`--view ${s}: want PRESET:T[:ORBIT[:HEIGHT]]`);
        const t = int(p[1]);
        const mm = p.length > 3 ? Math.round(Number(p[3]) * 1000) : DEFAULT_HEIGHT_MM;
        if (!(mm >= 1000 && mm <= 1800)) usage(`--view ${s}: height must be in [1.0, 1.8] metres`);
        views.push({ preset: parsePreset(p[0]), t, orbit: (p.length > 2 && p[2] !== "" ? int(p[2]) : t) % 600, mm });
    } else if (a === "-h" || a === "--help") usage();
    else usage(`unknown option ${a}`);
}
const all = [...(only ? [] : checkSet()), ...views];
if (!all.length) usage("no views (--only needs --view)");
outDir = outDir || path.join("out", "check_pt");
fs.mkdirSync(outDir, { recursive: true });

let cart = null;
if (!refOnlyMode) {
    wasm = wasm || defaultWasm(variant);
    cart = new Cart(wasm);
    console.log(`check_pt: ${wasm}, checks ${[...checks].sort().join(",")}, ${all.length} views, accumulator index x * ${HEIGHT} + y`);
} else console.log(`check_pt: --ref-only: check 2 on the reference itself, ${all.length} views`);

const results = [];
for (const v of all) {
    const t0 = Date.now();
    const r = refOnlyMode ? refOnly(v, jobs) : checkView(cart, v, checks, jobs, outDir);
    console.log(`check_pt: ${r.name} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
    for (const l of r.lines) console.log(l);
    console.log(r.pass ? "  PASS" : "  FAIL");
    results.push(r);
}
const failed = results.filter((r) => !r.pass).map((r) => r.name);
console.log(`check_pt: ${results.length - failed.length}/${results.length} PASS${failed.length ? `; FAIL: ${failed.join(", ")}` : ""}`);
console.log(failed.length ? "FAIL" : "PASS");
process.exit(failed.length ? 3 : 0);
