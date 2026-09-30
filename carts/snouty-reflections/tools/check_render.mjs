#!/usr/bin/env node
// Compare cart frames against reference frames (tools/reference.py) in RGB565
// units (PLAN.md M2 "Check frames", M3 "Reference and check").
//
//   node tools/check_render.mjs <preview.png> <ref.png> [--diff out.png] [--amp out.png]
//   node tools/check_render.mjs --variant full20|cut20|full15|half30 [--wasm cart.wasm] [--out DIR]
//                               [--frame F]... [--t T [--orbit O]]... [--view P:T[:O[:H]]]...
//                               [--preset P]... [--height H]... [--only] [--motion 0|1] [--ref-arg ARG]...
//   node tools/check_render.mjs --identity --wasm new.wasm --baseline m2.2.wasm [--variant V]
//                               [--from 0] [--to 600] [--step 50] [--dither none|bayer] [--out DIR]
//
// THE RULE. Both PNGs must be the same size, 8-bit RGB or RGBA,
// non-interlaced. Each channel is recovered to 5/6/5 units: round(v8 * 31 /
// 255) for red and blue, round(v8 * 63 / 255) for green. A pixel's
// difference is its largest per-channel difference. PASS if at most 1% of
// pixels differ by more than 1 unit AND at most 0.25% (51 of 20480 at
// 160x128) differ by more than 6 units (the outlier allowance for shore
// texel edges, shadow edges and grazing glass silhouettes, where f32 and f64
// legitimately pick different sides).
//
// --diff writes the outlier map: the preview frame dimmed to 30%, pixels off
// by 2..6 units in yellow, and pixels off by more than 6 units in bright
// magenta, so the outliers can be eyeballed.
// --amp writes the amplified difference image: per channel |d| * 40
// (clamped), so a 1-unit difference is dim and 6+ units is bright.
//
// --variant runs the whole check for one firmware variant (PLAN.md "M2.1
// Perf variants"; reference.py --variant sets the matching flags). The wasm
// defaults to dist/variants/<variant>.wasm (tools/build_variants.sh) when it
// exists, else ../../zig-out/bin/snouty-reflections.wasm (a warning says so:
// that build is whatever variant was last built). Output goes to --out
// (default out/check_<variant>). For half30 every pixel of the 2x2-upscaled
// frame is compared. Two paths, picked by the wasm's exports:
//
// * M3 (the wasm exports debug_set_view and debug_set_dither_mode): the cart
//   is loaded in-process (no preview.mjs). Per view it calls
//   debug_set_dither_mode(1) (none) and debug_set_view(preset, t, orbit,
//   height_mm), runs update() twice, checks the two frames are identical
//   (the view is frozen) and that debug_preset (and debug_state == 2,
//   frozen, when exported) agree, and compares the second frame with
//   reference.py --view P:T:O:H (motion on unless --motion 0). Views: the
//   M3 check set, each preset at t = 0, 150, 300, 450 (orbit = t), and sunset
//   and storm at heights 1.0 and 3.0 at t = 0 and 300; plus every --view; plus
//   every --frame F / --t T (orbit = --orbit O, else T) for each --preset
//   (default sunset) and each --height (default 1.6). --only drops the check
//   set. Files: cart_<name>.png, ref_<name>.png, diff_<name>.png with
//   name = <preset>_t<TTTT>_o<OOOO>_h<mm>.
// * Legacy (today's wasm, no debug_set_view): ../../tools/preview.mjs steps
//   the frames with B pressed on tick 0 (tools/scripts/m1_nodither.json,
//   dither `none`), reference.py renders them with --motion 0 (the M2.2
//   scene), frames 0, 1/4, 1/2 and 3/4 of the orbit plus every --frame F
//   (--only: just those). Files frame_FFFF.png, ref_FFFF.png, diff_FFFF.png.
//   --preset, --height, --t, --orbit and --view need the M3 exports.
//
// --ref-arg ARG (repeatable) appends ARG to the reference.py command line,
// for a cart built with non-default knobs, e.g. --ref-arg --rings --ref-arg 0.
// --motion 0 is the same as --ref-arg --motion --ref-arg 0 (a motion-off build).
//
// --identity (PLAN.md M3 "Legacy identity") compares debug_pixel_checksum of
// --wasm (built with the motion knob off) against --baseline (the m2.2 wasm)
// at frames --from..--to step --step (default 0..600 step 50). The baseline
// is stepped frame by frame with B on tick 0 (dither none). The new wasm is
// stepped the same way when it lacks debug_set_view; with it, each frame F is
// debug_set_view(sunset, F, F mod orbit_frames, 1600) and dither none through
// debug_set_dither_mode (--dither bayer leaves both carts in their default
// dither; that also needs the new cart's dither to see the same frame parity).
// orbit_frames comes from --variant (default cut20: 600). A mismatch writes
// both frames (identity_new_FFFF.png, identity_base_FFFF.png) to --out
// (default out/identity) and prints the differing-pixel count.
//
// Exit codes: 0 PASS (every frame), 3 FAIL, 2 usage or unreadable PNG, 1 a
// preview.mjs or reference.py run failed, or the cart trapped.
// No npm dependencies (PNG is decoded with node:zlib).
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const MAX_DIFF_FRACTION = 0.01;     // at most 1% of pixels may differ by > TOL_UNITS
const MAX_OUTLIER_FRACTION = 0.0025; // and at most 0.25% by > OUTLIER_UNITS
const TOL_UNITS = 1;
const OUTLIER_UNITS = 6;

function usage(msg) {
    if (msg) console.error(`check_render: ${msg}`);
    console.error("usage: node tools/check_render.mjs <preview.png> <ref.png> [--diff out.png] [--amp out.png]\n" +
        "       node tools/check_render.mjs --variant full20|cut20|full15|half30 [--wasm cart.wasm] [--out DIR]\n" +
        "              [--frame F]... [--t T [--orbit O]]... [--view P:T[:O[:H]]]... [--preset P]... [--height H]...\n" +
        "              [--only] [--motion 0|1] [--ref-arg ARG]...\n" +
        "       node tools/check_render.mjs --identity --wasm new.wasm --baseline m2.2.wasm [--variant V]\n" +
        "              [--from 0] [--to 600] [--step 50] [--dither none|bayer] [--out DIR]");
    process.exit(2);
}


// ---------------------------------------------------------------- PNG decode
function decodePNG(file) {
    const buf = fs.readFileSync(file);
    const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    if (buf.length < 8 || !buf.subarray(0, 8).equals(sig)) throw new Error("not a PNG");
    let o = 8, ihdr = null;
    const idat = [];
    while (o + 8 <= buf.length) {
        const len = buf.readUInt32BE(o), type = buf.toString("ascii", o + 4, o + 8);
        const data = buf.subarray(o + 8, o + 8 + len);
        if (type === "IHDR") ihdr = data;
        else if (type === "IDAT") idat.push(data);
        else if (type === "IEND") break;
        o += 12 + len;
    }
    if (!ihdr) throw new Error("no IHDR");
    const w = ihdr.readUInt32BE(0), h = ihdr.readUInt32BE(4);
    const depth = ihdr[8], ctype = ihdr[9], interlace = ihdr[12];
    if (depth !== 8 || (ctype !== 2 && ctype !== 6)) throw new Error(`unsupported format (bit depth ${depth}, color type ${ctype}); need 8-bit RGB or RGBA`);
    if (interlace !== 0) throw new Error("interlaced PNGs are not supported");
    const bpp = ctype === 6 ? 4 : 3, stride = w * bpp;
    const raw = zlib.inflateSync(Buffer.concat(idat));
    if (raw.length < (stride + 1) * h) throw new Error("truncated image data");
    const px = Buffer.alloc(stride * h);
    for (let y = 0; y < h; y++) {
        const f = raw[y * (stride + 1)], src = y * (stride + 1) + 1, dst = y * stride;
        for (let i = 0; i < stride; i++) {
            const x = raw[src + i];
            const a = i >= bpp ? px[dst + i - bpp] : 0;
            const b = y > 0 ? px[dst - stride + i] : 0;
            const c = i >= bpp && y > 0 ? px[dst - stride + i - bpp] : 0;
            let v;
            switch (f) {
                case 0: v = x; break;
                case 1: v = x + a; break;
                case 2: v = x + b; break;
                case 3: v = x + ((a + b) >> 1); break;
                case 4: {
                    const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
                    v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
                    break;
                }
                default: throw new Error(`bad filter type ${f} on row ${y}`);
            }
            px[dst + i] = v & 0xff;
        }
    }
    // Drop alpha: return packed RGB.
    const rgb = Buffer.alloc(w * h * 3);
    for (let i = 0; i < w * h; i++) for (let k = 0; k < 3; k++) rgb[i * 3 + k] = px[i * bpp + k];
    return { w, h, rgb };
}

// ---------------------------------------------------------------- PNG encode (for --diff, --amp)
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

// ---------------------------------------------------------------- compare
const MAXV = [31, 63, 31], NAMES = ["r", "g", "b"];
const to565 = (v8, k) => Math.round((v8 * MAXV[k]) / 255);

// Compares two decoded PNGs, prints the report, writes --diff/--amp images;
// returns true on PASS.
function compare(a, b, nameA, nameB, diffOut, ampOut) {
    const n = a.w * a.h;
    let differing = 0, outliers = 0, maxDiff = 0, maxAt = null;
    const ampImg = Buffer.alloc(n * 3);
    const diffImg = Buffer.alloc(n * 3);
    for (let i = 0; i < n; i++) {
        let worst = 0, worstCh = 0;
        const units = [];
        for (let k = 0; k < 3; k++) {
            const pa = to565(a.rgb[i * 3 + k], k), pb = to565(b.rgb[i * 3 + k], k);
            const d = Math.abs(pa - pb);
            units.push([pa, pb]);
            ampImg[i * 3 + k] = Math.min(255, d * 40);
            if (d > worst) { worst = d; worstCh = k; }
        }
        if (worst > maxDiff) { maxDiff = worst; maxAt = { x: i % a.w, y: Math.floor(i / a.w), ch: NAMES[worstCh], units }; }
        if (worst > TOL_UNITS) differing++;
        if (worst > OUTLIER_UNITS) outliers++;
        const mark = worst > OUTLIER_UNITS ? [255, 0, 255] : worst > TOL_UNITS ? [255, 220, 0] : null;
        for (let k = 0; k < 3; k++) diffImg[i * 3 + k] = mark ? mark[k] : Math.round(a.rgb[i * 3 + k] * 0.3);
    }

    const limit = Math.floor(n * MAX_DIFF_FRACTION);
    const outlierLimit = Math.floor(n * MAX_OUTLIER_FRACTION);
    const pass = differing <= limit && outliers <= outlierLimit;
    const pct = (c) => ((100 * c) / n).toFixed(2);
    console.log(`check_render: ${nameA} vs ${nameB} (${a.w}x${a.h}, ${n} pixels)`);
    console.log(`  pixels differing by > ${TOL_UNITS} unit: ${differing} (${pct(differing)}%, limit ${limit} = 1%)${differing > limit ? "  OVER" : ""}`);
    console.log(`  pixels differing by > ${OUTLIER_UNITS} units: ${outliers} (${pct(outliers)}%, limit ${outlierLimit} = 0.25%)${outliers > outlierLimit ? "  OVER" : ""}`);
    if (maxAt) {
        const fmt = (s) => maxAt.units.map((u) => u[s]).join(",");
        console.log(`  max difference: ${maxDiff} units in ${maxAt.ch} at (${maxAt.x}, ${maxAt.y}); preview r,g,b = ${fmt(0)}, reference = ${fmt(1)}`);
    } else console.log("  max difference: 0 units (identical in 565)");
    if (diffOut) { fs.writeFileSync(diffOut, encodePNG(diffImg, a.w, a.h)); console.log(`  diff image: ${diffOut} (magenta > ${OUTLIER_UNITS} units, yellow > ${TOL_UNITS})`); }
    if (ampOut) { fs.writeFileSync(ampOut, encodePNG(ampImg, a.w, a.h)); console.log(`  amplified diff: ${ampOut}`); }
    console.log(pass ? "PASS" : "FAIL");
    return pass;
}

function load(file) {
    try { return decodePNG(file); } catch (e) { usage(`${file}: ${e.message}`); }
}

// ---------------------------------------------------------------- variants and presets
// PLAN.md "M2.1 Perf variants": frame rate per variant (the orbit is 30 s).
// The reference flags live in reference.py's VARIANTS, selected with --variant.
const VARIANTS = { full20: { fps: 20 }, cut20: { fps: 20 }, full15: { fps: 15 }, half30: { fps: 30 } };
// scene.Preset order (PLAN.md M3 "Fixed interfaces").
const PRESETS = ["sunset", "midnight", "noon", "storm"];
const DEFAULT_HEIGHT_MM = 1600, MIN_HEIGHT_MM = 1000, MAX_HEIGHT_MM = 3000;
const CART_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REFERENCE = path.join(CART_DIR, "tools", "reference.py");

function parsePreset(s) {
    const t = String(s).trim().toLowerCase();
    if (/^\d$/.test(t) && Number(t) < PRESETS.length) return Number(t);
    const i = PRESETS.indexOf(t);
    if (i < 0) usage(`unknown preset '${s}' (want ${PRESETS.join(", ")} or 0..3)`);
    return i;
}
function parseHeightMm(s) {
    const h = Number(s);
    const mm = Math.round(h * 1000);
    if (!Number.isFinite(h) || mm < MIN_HEIGHT_MM || mm > MAX_HEIGHT_MM) usage(`height '${s}' must be in [1.0, 3.0] metres`);
    return mm;
}
const pad4 = (n) => String(n).padStart(4, "0");
const viewName = (v) => `${PRESETS[v.preset]}_t${pad4(v.t)}_o${pad4(v.orbit)}_h${pad4(v.mm)}`;
const viewArg = (v) => `${PRESETS[v.preset]}:${v.t}:${v.orbit}:${(v.mm / 1000).toFixed(3)}`;

function run(cmd, argv) {
    console.log(`$ ${cmd} ${argv.join(" ")}`);
    const r = spawnSync(cmd, argv, { stdio: ["ignore", "inherit", "inherit"] });
    if (r.error) { console.error(`check_render: ${cmd}: ${r.error.message}`); process.exit(1); }
    if (r.status !== 0) { console.error(`check_render: ${cmd} exited with ${r.status}`); process.exit(1); }
}

function defaultWasm(name) {
    const built = path.join(CART_DIR, "dist", "variants", `${name}.wasm`);
    if (fs.existsSync(built)) return built;
    const wasm = path.resolve(CART_DIR, "..", "..", "zig-out", "bin", "snouty-reflections.wasm");
    console.error(`check_render: warning: ${path.relative(process.cwd(), built)} not found; using ${path.relative(process.cwd(), wasm)}, ` +
        `which must be a ${name} build (zig build -Dcart=snouty-reflections -Dreflections_variant=${name})`);
    return wasm;
}

// ---------------------------------------------------------------- in-process cart runner
// The subset of ../../tools/preview.mjs this cart needs: the same 64-page
// memory, controls at 0x04, and the frame read from the simulator region at
// 0x20 (the cart's present_wasm() copies it there with red and blue swapped),
// right after update() and before any other export call (the shadow stack
// overlaps that region).
const SIM_FB = 0x20, ADDR_CONTROLS = 0x04, WIDTH = 160, HEIGHT = 128;
const BTN_B = 1 << 3;
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
            if (imp.module !== "env" || !(imp.name in stubs)) usage(`${file}: imports ${imp.module}.${imp.name}, which this runner does not provide (use preview.mjs)`);
            env[imp.name] = stubs[imp.name];
        }
        this.file = file;
        this.ex = new WebAssembly.Instance(module, { env }).exports;
        for (const need of ["start", "update", "debug_pixel_checksum"]) if (typeof this.ex[need] !== "function") usage(`${file}: does not export ${need}()`);
        for (const init of ["_start", "_initialize"]) if (typeof this.ex[init] === "function") this.call(init);
        this.setControls(0);
        this.call("start");
    }
    has(name) { return typeof this.ex[name] === "function"; }
    call(name, ...args) {
        try { return this.ex[name](...args); } catch (e) { console.error(`check_render: ${this.file}: ${name}() trapped: ${e.message}`); process.exit(1); }
    }
    setControls(bits) { new DataView(this.memory.buffer).setUint16(ADDR_CONTROLS, bits, true); }
    // update() and the frame it presented.
    update() { this.call("update"); return this.frame(); }
    frame() {
        const m = new Uint8Array(this.memory.buffer), rgb = Buffer.alloc(WIDTH * HEIGHT * 3);
        for (let x = 0; x < WIDTH; x++) for (let y = 0; y < HEIGHT; y++) {
            const o = SIM_FB + (x * HEIGHT + y) * 2;
            const c = (m[o] << 8) | m[o + 1];
            const b = c & 0x1f, g = (c >> 5) & 0x3f, r = (c >> 11) & 0x1f;  // pre-swapped for the simulator
            const i = (y * WIDTH + x) * 3;
            rgb[i] = (r << 3) | (r >> 2); rgb[i + 1] = (g << 2) | (g >> 4); rgb[i + 2] = (b << 3) | (b >> 2);
        }
        return { w: WIDTH, h: HEIGHT, rgb };
    }
    checksum() { return this.call("debug_pixel_checksum") >>> 0; }
}
const hasViewExports = (cart) => cart.has("debug_set_view") && cart.has("debug_set_dither_mode");

// ---------------------------------------------------------------- legacy check (preview.mjs, frame stepping)
function checkLegacy(name, wasm, extraFrames, only, outDir, refArgs) {
    const v = VARIANTS[name];
    const orbit = 30 * v.fps;
    const base = only ? [] : [0, 1, 2, 3].map((q) => Math.floor((q * orbit) / 4));
    const frames = [...new Set([...base, ...extraFrames])].sort((x, y) => x - y);
    if (frames.length === 0) usage("no frames to check (--only needs --frame)");
    console.log(`check_render: variant ${name} (${v.fps} fps, orbit ${orbit} frames), wasm ${wasm}, legacy path (no debug_set_view), frames ${frames.join(", ")}`);

    // One preview run covers every frame: stride = gcd of the frames.
    const gcd = (x, y) => (y === 0 ? x : gcd(y, x % y));
    const every = Math.max(1, frames.reduce(gcd, 0));
    const last = frames[frames.length - 1];
    run(process.execPath, [path.join(CART_DIR, "..", "..", "tools", "preview.mjs"), wasm,
        "--frames", String(last + 1), "--every", String(every),
        "--script", path.join(CART_DIR, "tools", "scripts", "m1_nodither.json"),
        "--dump-exports", "debug_dither_mode", "--expect", "debug_dither_mode == 1", "--out", outDir]);
    run("python3", [REFERENCE, ...frames.flatMap((f) => ["--frame", String(f)]),
        "--variant", name, "--motion", "0", ...refArgs, "--out", outDir]);

    const results = [];
    for (const f of frames) {
        const tag = pad4(f);
        const pv = path.join(outDir, `frame_${tag}.png`), rf = path.join(outDir, `ref_${tag}.png`);
        const a = load(pv), b = load(rf);
        if (a.w !== b.w || a.h !== b.h) usage(`size mismatch: ${a.w}x${a.h} vs ${b.w}x${b.h}`);
        results.push([String(f), compare(a, b, pv, rf, path.join(outDir, `diff_${tag}.png`), null)]);
    }
    return results;
}

// ---------------------------------------------------------------- M3 check (debug_set_view)
function m3CheckSet() {
    const views = [];
    for (let p = 0; p < PRESETS.length; p++) for (const t of [0, 150, 300, 450]) views.push({ preset: p, t, orbit: t, mm: DEFAULT_HEIGHT_MM });
    for (const p of [0, 3]) for (const mm of [1000, 3000]) for (const t of [0, 300]) views.push({ preset: p, t, orbit: t, mm });
    return views;
}

function checkViews(name, cart, views, outDir, refArgs) {
    const v = VARIANTS[name];
    const orbitFrames = 30 * v.fps;
    const seen = new Set();
    views = views.map((w) => ({ ...w, orbit: w.orbit % orbitFrames })).filter((w) => {
        const k = viewName(w);
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
    });
    if (views.length === 0) usage("no views to check (--only needs --frame, --t or --view)");
    console.log(`check_render: variant ${name} (${v.fps} fps, orbit ${orbitFrames} frames), wasm ${cart.file}, ${views.length} views via debug_set_view`);

    const problems = new Map();
    for (const w of views) {
        cart.setControls(0);
        cart.call("debug_set_dither_mode", 1);
        cart.call("debug_set_view", w.preset, w.t, w.orbit, w.mm);
        const f1 = cart.update();
        const f2 = cart.update();
        const why = [];
        if (!f1.rgb.equals(f2.rgb)) why.push("two updates after debug_set_view differ (the view is not frozen)");
        if (cart.has("debug_dither_mode") && cart.call("debug_dither_mode") !== 1) why.push(`debug_dither_mode = ${cart.call("debug_dither_mode")}, want 1 (none)`);
        if (cart.has("debug_preset") && cart.call("debug_preset") !== w.preset) why.push(`debug_preset = ${cart.call("debug_preset")}, want ${w.preset}`);
        if (cart.has("debug_state") && cart.call("debug_state") !== 2) why.push(`debug_state = ${cart.call("debug_state")}, want 2 (frozen)`);
        if (why.length) problems.set(viewName(w), why);
        fs.writeFileSync(path.join(outDir, `cart_${viewName(w)}.png`), encodePNG(f2.rgb, f2.w, f2.h));
    }
    run("python3", [REFERENCE, "--variant", name, ...views.flatMap((w) => ["--view", viewArg(w)]), ...refArgs, "--out", outDir]);

    const results = [];
    for (const w of views) {
        const n = viewName(w);
        const pv = path.join(outDir, `cart_${n}.png`), rf = path.join(outDir, `ref_${n}.png`);
        const a = load(pv), b = load(rf);
        let pass = compare(a, b, pv, rf, path.join(outDir, `diff_${n}.png`), null);
        for (const p of problems.get(n) || []) { console.log(`  FAIL: ${p}`); pass = false; }
        results.push([n, pass]);
    }
    return results;
}

function checkVariant(name, wasm, sel, only, outDir, refArgs) {
    if (!VARIANTS[name]) usage(`unknown variant ${name} (want ${Object.keys(VARIANTS).join(", ")})`);
    wasm = wasm || defaultWasm(name);
    if (!fs.existsSync(wasm)) usage(`${wasm}: no such file`);
    outDir = outDir || path.join("out", `check_${name}`);
    fs.mkdirSync(outDir, { recursive: true });
    const cart = new Cart(wasm);
    let results;
    if (hasViewExports(cart)) {
        const presets = sel.presets.length ? sel.presets : [0];
        const heights = sel.heights.length ? sel.heights : [DEFAULT_HEIGHT_MM];
        const views = [...(only ? [] : m3CheckSet()), ...sel.views];
        for (const x of sel.times) for (const p of presets) for (const mm of heights) views.push({ preset: p, t: x.t, orbit: x.orbit ?? x.t, mm });
        results = checkViews(name, cart, views, outDir, refArgs);
    } else {
        if (sel.presets.some((p) => p !== 0) || sel.heights.some((h) => h !== DEFAULT_HEIGHT_MM) || sel.views.length ||
            sel.times.some((x) => x.orbit !== undefined && x.orbit !== x.t))
            usage(`${wasm} has no debug_set_view/debug_set_dither_mode exports: --preset, --height, --view and --orbit need an M3 cart`);
        results = checkLegacy(name, wasm, sel.times.map((x) => x.t), only, outDir, refArgs);
    }
    const allPass = results.every(([, p]) => p);
    const failed = results.filter(([, p]) => !p).map(([n]) => n);
    console.log(`check_render: variant ${name}: ${results.length - failed.length}/${results.length} PASS${failed.length ? `; FAIL: ${failed.join(", ")}` : ""}`);
    console.log(allPass ? "PASS" : "FAIL");
    return allPass;
}

// ---------------------------------------------------------------- identity (debug_pixel_checksum)
function checkIdentity(wasm, baseline, name, from, to, step, ditherMode, outDir) {
    if (!wasm || !baseline) usage("--identity needs --wasm and --baseline");
    if (!VARIANTS[name]) usage(`unknown variant ${name}`);
    const orbitFrames = 30 * VARIANTS[name].fps;
    outDir = outDir || path.join("out", "identity");
    fs.mkdirSync(outDir, { recursive: true });
    if (from > to) usage("--from must be <= --to");
    const frames = [];
    for (let f = from; f <= to; f += step) frames.push(f);
    const base = new Cart(baseline), cand = new Cart(wasm);
    const viaView = hasViewExports(cand);
    console.log(`check_render: identity ${wasm} vs ${baseline} (${name}, orbit ${orbitFrames}), dither ${ditherMode}, ` +
        `frames ${from}..${to} step ${step}; new wasm ${viaView ? "via debug_set_view(0, F, F mod orbit, 1600)" : "stepped"}`);
    const pressB = ditherMode === "none";
    // Step the baseline (and a legacy candidate) through every update, B on tick 0.
    const step1 = (cart, i) => { cart.setControls(pressB && i === 0 ? BTN_B : 0); return cart.update(); };
    let bi = 0, ci = 0, fails = 0;
    for (const f of frames) {
        let fb;
        while (bi <= f) { fb = step1(base, bi); bi++; }
        const sb = base.checksum();
        let fc;
        if (viaView) {
            cand.setControls(0);
            if (pressB) cand.call("debug_set_dither_mode", 1);
            cand.call("debug_set_view", 0, f, f % orbitFrames, DEFAULT_HEIGHT_MM);
            fc = cand.update();
        } else {
            while (ci <= f) { fc = step1(cand, ci); ci++; }
        }
        const sc = cand.checksum();
        if (sb === sc && fb.rgb.equals(fc.rgb)) { console.log(`  frame ${pad4(f)}: checksum ${sc} identical`); continue; }
        fails++;
        let n = 0;
        for (let i = 0; i < fb.rgb.length; i += 3) if (fb.rgb[i] !== fc.rgb[i] || fb.rgb[i + 1] !== fc.rgb[i + 1] || fb.rgb[i + 2] !== fc.rgb[i + 2]) n++;
        fs.writeFileSync(path.join(outDir, `identity_base_${pad4(f)}.png`), encodePNG(fb.rgb, fb.w, fb.h));
        fs.writeFileSync(path.join(outDir, `identity_new_${pad4(f)}.png`), encodePNG(fc.rgb, fc.w, fc.h));
        console.log(`  frame ${pad4(f)}: checksum ${sc} vs baseline ${sb}, ${n} pixels differ  FAIL (frames in ${outDir})`);
    }
    console.log(`check_render: identity: ${frames.length - fails}/${frames.length} frames identical`);
    console.log(fails ? "FAIL" : "PASS");
    return fails === 0;
}

// ---------------------------------------------------------------- main
const args = process.argv.slice(2);
const files = [], refArgs = [];
const sel = { presets: [], heights: [], times: [], views: [] };
let diffOut = null, ampOut = null, variant = null, wasm = null, outDir = null, only = false;
let identity = false, baseline = null, from = 0, to = 600, step = 50, ditherMode = "none";
const intArg = (flag, v, min = 0) => { const n = Number(v); if (!Number.isInteger(n) || n < min) usage(`${flag} needs an integer >= ${min}`); return n; };
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const val = () => { const v = args[++i]; if (v === undefined) usage(`${a} needs a value`); return v; };
    if (a === "--diff") diffOut = val();
    else if (a === "--amp") ampOut = val();
    else if (a === "--variant") variant = val();
    else if (a === "--wasm") wasm = val();
    else if (a === "--out") outDir = val();
    else if (a === "--frame" || a === "--t") sel.times.push({ t: intArg(a, val()) });
    else if (a === "--orbit") {
        if (!sel.times.length) usage("--orbit follows a --t");
        sel.times[sel.times.length - 1].orbit = intArg(a, val());
    }
    else if (a === "--preset") sel.presets.push(parsePreset(val()));
    else if (a === "--height") sel.heights.push(parseHeightMm(val()));
    else if (a === "--view") {
        const s = val(), p = s.split(":");
        if (p.length < 2 || p.length > 4) usage(`--view ${s}: want PRESET:T[:ORBIT[:HEIGHT]]`);
        const t = intArg("--view T", p[1]);
        sel.views.push({ preset: parsePreset(p[0]), t, orbit: p.length > 2 && p[2] !== "" ? intArg("--view ORBIT", p[2]) : t,
            mm: p.length > 3 ? parseHeightMm(p[3]) : DEFAULT_HEIGHT_MM });
    }
    else if (a === "--only") only = true;
    else if (a === "--motion") { const m = val(); if (m !== "0" && m !== "1") usage("--motion takes 0 or 1"); refArgs.push("--motion", m); }
    else if (a === "--ref-arg") refArgs.push(val());
    else if (a === "--identity") identity = true;
    else if (a === "--baseline") baseline = val();
    else if (a === "--from") from = intArg(a, val());
    else if (a === "--to") to = intArg(a, val());
    else if (a === "--step") step = intArg(a, val(), 1);
    else if (a === "--dither") { ditherMode = val(); if (ditherMode !== "none" && ditherMode !== "bayer") usage("--dither takes none or bayer"); }
    else if (a === "-h" || a === "--help") usage();
    else if (a.startsWith("--")) usage(`unknown option ${a}`);
    else files.push(a);
}

if (identity) {
    if (files.length || diffOut || ampOut) usage("--identity takes no PNG files, --diff or --amp");
    process.exit(checkIdentity(wasm, baseline, variant || "cut20", from, to, step, ditherMode, outDir) ? 0 : 3);
}
if (variant) {
    if (files.length || diffOut || ampOut) usage("--variant takes no PNG files, --diff or --amp");
    process.exit(checkVariant(variant, wasm, sel, only, outDir, refArgs) ? 0 : 3);
}
if (wasm || outDir || only || refArgs.length || sel.times.length || sel.presets.length || sel.heights.length || sel.views.length)
    usage("--wasm, --out, --frame, --t, --view, --preset, --height, --only, --motion and --ref-arg need --variant");
if (files.length !== 2) usage();

const a = load(files[0]), b = load(files[1]);
if (a.w !== b.w || a.h !== b.h) usage(`size mismatch: ${a.w}x${a.h} vs ${b.w}x${b.h}`);
process.exit(compare(a, b, files[0], files[1], diffOut, ampOut) ? 0 : 3);
