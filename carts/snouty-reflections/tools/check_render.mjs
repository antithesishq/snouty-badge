#!/usr/bin/env node
// Compare a cart frame (../../tools/preview.mjs) against a reference frame
// (tools/reference.py) in RGB565 units (PLAN.md M2 "Check frames").
//
//   node tools/check_render.mjs <preview.png> <ref.png> [--diff out.png] [--amp out.png]
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
// Exit codes: 0 PASS, 3 FAIL, 2 usage or unreadable PNG.
// No npm dependencies (PNG is decoded with node:zlib).
import fs from "node:fs";
import zlib from "node:zlib";

const MAX_DIFF_FRACTION = 0.01;     // at most 1% of pixels may differ by > TOL_UNITS
const MAX_OUTLIER_FRACTION = 0.0025; // and at most 0.25% by > OUTLIER_UNITS
const TOL_UNITS = 1;
const OUTLIER_UNITS = 6;

function usage(msg) {
    if (msg) console.error(`check_render: ${msg}`);
    console.error("usage: node tools/check_render.mjs <preview.png> <ref.png> [--diff out.png] [--amp out.png]");
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

// ---------------------------------------------------------------- main
const args = process.argv.slice(2);
const files = [];
let diffOut = null, ampOut = null;
for (let i = 0; i < args.length; i++) {
    if (args[i] === "--diff") { diffOut = args[++i]; if (!diffOut) usage("--diff needs a file name"); }
    else if (args[i] === "--amp") { ampOut = args[++i]; if (!ampOut) usage("--amp needs a file name"); }
    else if (args[i] === "-h" || args[i] === "--help") usage();
    else if (args[i].startsWith("--")) usage(`unknown option ${args[i]}`);
    else files.push(args[i]);
}
if (files.length !== 2) usage();

let a, b;
try { a = decodePNG(files[0]); } catch (e) { usage(`${files[0]}: ${e.message}`); }
try { b = decodePNG(files[1]); } catch (e) { usage(`${files[1]}: ${e.message}`); }
if (a.w !== b.w || a.h !== b.h) usage(`size mismatch: ${a.w}x${a.h} vs ${b.w}x${b.h}`);

const MAXV = [31, 63, 31], NAMES = ["r", "g", "b"];
const to565 = (v8, k) => Math.round((v8 * MAXV[k]) / 255);
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
console.log(`check_render: ${files[0]} vs ${files[1]} (${a.w}x${a.h}, ${n} pixels)`);
console.log(`  pixels differing by > ${TOL_UNITS} unit: ${differing} (${pct(differing)}%, limit ${limit} = 1%)${differing > limit ? "  OVER" : ""}`);
console.log(`  pixels differing by > ${OUTLIER_UNITS} units: ${outliers} (${pct(outliers)}%, limit ${outlierLimit} = 0.25%)${outliers > outlierLimit ? "  OVER" : ""}`);
if (maxAt) {
    const fmt = (s) => maxAt.units.map((u) => u[s]).join(",");
    console.log(`  max difference: ${maxDiff} units in ${maxAt.ch} at (${maxAt.x}, ${maxAt.y}); preview r,g,b = ${fmt(0)}, reference = ${fmt(1)}`);
} else console.log("  max difference: 0 units (identical in 565)");
if (diffOut) { fs.writeFileSync(diffOut, encodePNG(diffImg, a.w, a.h)); console.log(`  diff image: ${diffOut} (magenta > ${OUTLIER_UNITS} units, yellow > ${TOL_UNITS})`); }
if (ampOut) { fs.writeFileSync(ampOut, encodePNG(ampImg, a.w, a.h)); console.log(`  amplified diff: ${ampOut}`); }
console.log(pass ? "PASS" : "FAIL");
process.exit(pass ? 0 : 3);
