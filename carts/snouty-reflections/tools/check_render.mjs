#!/usr/bin/env node
// Compare a cart frame (../../tools/preview.mjs) against a reference frame
// (tools/reference.py) in RGB565 units (PLAN.md M2 "Check frames").
//
//   node tools/check_render.mjs <preview.png> <ref.png> [--diff out.png] [--amp out.png]
//   node tools/check_render.mjs --variant full20|cut20|full15|half30 [--wasm cart.wasm]
//                               [--frame F]... [--only] [--out DIR]
//
// Both PNGs must be the same size, 8-bit RGB or RGBA, non-interlaced. Each
// channel is recovered to 5/6/5 units: round(v8 * 31 / 255) for red and blue,
// round(v8 * 63 / 255) for green. A pixel's difference is its largest
// per-channel difference. PASS if at most 1% of pixels differ by more than 1
// unit AND at most 0.25% (51 of 20480 at 160x128) differ by more than 6 units
// (the outlier allowance for shore texel edges, shadow edges and grazing glass
// silhouettes, where f32 and f64 legitimately pick different sides).
//
// --diff writes the outlier map: the preview frame dimmed to 30%, pixels off
// by 2..6 units in yellow, and pixels off by more than 6 units in bright
// magenta, so the outliers can be eyeballed.
// --amp writes the amplified difference image: per channel |d| * 40
// (clamped), so a 1-unit difference is dim and 6+ units is bright.
//
// --variant (PLAN.md "M2.1 Perf variants") runs the whole check for one
// firmware variant: ../../tools/preview.mjs renders the frames in dither mode
// `none` (tools/scripts/m1_nodither.json), tools/reference.py renders them
// with the variant's flags, and each pair is compared with the rule above:
//
//   full20  (defaults)                                   orbit 600 frames
//   cut20   --no-glass --water-shadows off               orbit 600
//   full15  --fps 15 --glass-primary env                 orbit 450
//   half30  --fps 30 --scale 2                           orbit 900
//
// Frames: 0, 1/4, 1/2 and 3/4 of the orbit (rounded down), plus every --frame
// F (for example the bench's worst frame); with --only just the --frame ones.
// The wasm defaults to dist/variants/<variant>.wasm (tools/build_variants.sh)
// when it exists, else ../../zig-out/bin/snouty-reflections.wasm (a warning
// says so: that build is whatever variant was last built). Frames, references
// and diff_FFFF.png go to --out (default out/check_<variant>). For half30 every
// pixel of the 2x2-upscaled frame is compared.
//
// Exit codes: 0 PASS (every frame), 3 FAIL, 2 usage or unreadable PNG, 1 a
// preview.mjs or reference.py run failed.
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
        "       node tools/check_render.mjs --variant full20|cut20|full15|half30 [--wasm cart.wasm] [--frame F]... [--only] [--out DIR]");
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

// ---------------------------------------------------------------- variants
// PLAN.md "M2.1 Perf variants": reference.py flags and frame rate per variant.
const VARIANTS = {
    full20: { fps: 20, ref: [] },
    cut20: { fps: 20, ref: ["--no-glass", "--water-shadows", "off"] },
    full15: { fps: 15, ref: ["--fps", "15", "--glass-primary", "env"] },
    half30: { fps: 30, ref: ["--fps", "30", "--scale", "2"] },
};
const CART_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function run(cmd, argv) {
    console.log(`$ ${cmd} ${argv.join(" ")}`);
    const r = spawnSync(cmd, argv, { stdio: ["ignore", "inherit", "inherit"] });
    if (r.error) { console.error(`check_render: ${cmd}: ${r.error.message}`); process.exit(1); }
    if (r.status !== 0) { console.error(`check_render: ${cmd} exited with ${r.status}`); process.exit(1); }
}

function checkVariant(name, wasm, extraFrames, only, outDir) {
    const v = VARIANTS[name];
    if (!v) usage(`unknown variant ${name} (want ${Object.keys(VARIANTS).join(", ")})`);
    const orbit = 30 * v.fps;
    if (!wasm) {
        const built = path.join(CART_DIR, "dist", "variants", `${name}.wasm`);
        if (fs.existsSync(built)) wasm = built;
        else {
            wasm = path.resolve(CART_DIR, "..", "..", "zig-out", "bin", "snouty-reflections.wasm");
            console.error(`check_render: warning: ${path.relative(process.cwd(), built)} not found; using ${path.relative(process.cwd(), wasm)}, ` +
                `which must be a ${name} build (zig build -Dcart=snouty-reflections -Dreflections_variant=${name})`);
        }
    }
    if (!fs.existsSync(wasm)) usage(`${wasm}: no such file`);
    const base = only ? [] : [0, 1, 2, 3].map((q) => Math.floor((q * orbit) / 4));
    const frames = [...new Set([...base, ...extraFrames])].sort((x, y) => x - y);
    if (frames.length === 0) usage("no frames to check (--only needs --frame)");
    outDir = outDir || path.join("out", `check_${name}`);
    fs.mkdirSync(outDir, { recursive: true });
    console.log(`check_render: variant ${name} (${v.fps} fps, orbit ${orbit} frames), wasm ${wasm}, frames ${frames.join(", ")}`);

    // One preview run covers every frame: stride = gcd of the frames.
    const gcd = (x, y) => (y === 0 ? x : gcd(y, x % y));
    const every = Math.max(1, frames.reduce(gcd, 0));
    const last = frames[frames.length - 1];
    run(process.execPath, [path.join(CART_DIR, "..", "..", "tools", "preview.mjs"), wasm,
        "--frames", String(last + 1), "--every", String(every),
        "--script", path.join(CART_DIR, "tools", "scripts", "m1_nodither.json"),
        "--dump-exports", "debug_dither_mode", "--expect", "debug_dither_mode == 1", "--out", outDir]);
    run("python3", [path.join(CART_DIR, "tools", "reference.py"), ...frames.flatMap((f) => ["--frame", String(f)]),
        ...v.ref, "--out", outDir]);

    const results = [];
    for (const f of frames) {
        const tag = String(f).padStart(4, "0");
        const pv = path.join(outDir, `frame_${tag}.png`), rf = path.join(outDir, `ref_${tag}.png`);
        const a = load(pv), b = load(rf);
        if (a.w !== b.w || a.h !== b.h) usage(`size mismatch: ${a.w}x${a.h} vs ${b.w}x${b.h}`);
        results.push([f, compare(a, b, pv, rf, path.join(outDir, `diff_${tag}.png`), null)]);
    }
    const allPass = results.every(([, p]) => p);
    console.log(`check_render: variant ${name}: ${results.map(([f, p]) => `${f} ${p ? "PASS" : "FAIL"}`).join(", ")}`);
    console.log(allPass ? "PASS" : "FAIL");
    return allPass;
}

// ---------------------------------------------------------------- main
const args = process.argv.slice(2);
const files = [], extraFrames = [];
let diffOut = null, ampOut = null, variant = null, wasm = null, outDir = null, only = false;
for (let i = 0; i < args.length; i++) {
    if (args[i] === "--diff") { diffOut = args[++i]; if (!diffOut) usage("--diff needs a file name"); }
    else if (args[i] === "--amp") { ampOut = args[++i]; if (!ampOut) usage("--amp needs a file name"); }
    else if (args[i] === "--variant") { variant = args[++i]; if (!variant) usage("--variant needs a name"); }
    else if (args[i] === "--wasm") { wasm = args[++i]; if (!wasm) usage("--wasm needs a file name"); }
    else if (args[i] === "--out") { outDir = args[++i]; if (!outDir) usage("--out needs a directory"); }
    else if (args[i] === "--frame") {
        const f = Number(args[++i]);
        if (!Number.isInteger(f) || f < 0) usage("--frame needs a frame index >= 0");
        extraFrames.push(f);
    }
    else if (args[i] === "--only") only = true;
    else if (args[i] === "-h" || args[i] === "--help") usage();
    else if (args[i].startsWith("--")) usage(`unknown option ${args[i]}`);
    else files.push(args[i]);
}

if (variant) {
    if (files.length || diffOut || ampOut) usage("--variant takes no PNG files, --diff or --amp");
    process.exit(checkVariant(variant, wasm, extraFrames, only, outDir) ? 0 : 3);
}
if (wasm || outDir || extraFrames.length || only) usage("--wasm, --out, --frame and --only need --variant");
if (files.length !== 2) usage();

const a = load(files[0]), b = load(files[1]);
if (a.w !== b.w || a.h !== b.h) usage(`size mismatch: ${a.w}x${a.h} vs ${b.w}x${b.h}`);
process.exit(compare(a, b, files[0], files[1], diffOut, ampOut) ? 0 : 3);
