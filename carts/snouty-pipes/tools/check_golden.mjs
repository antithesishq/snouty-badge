#!/usr/bin/env node
// Golden-image regression: fixed seeds at fixed tick counts.
//
//   node tools/check_golden.mjs [--update] [--tolerance N] [--only NAME[,NAME...]]
//                               [--wasm ../../zig-out/bin/snouty-pipes.wasm]
//
// Reads tests/golden/poses.json, an array of
//   { "name": "grow_s1_t300", "seed": 1, "frames": 300,
//     "calls": ["debug_force_teapot"], "press": ["A:200-200"] }
// (calls, press optional; frames defaults to 1). For each entry it runs
//   node ../../tools/preview.mjs <wasm> --seed S [--call C]... [--press P]...
//        --frames F --start-skip F-1 --out out/golden/<name>/
// so only the last frame is written (the frame shown after update F-1), and
// compares that PNG pixel-exactly with tests/golden/<name>.png. The picture
// is persistent (.copy_forward: every frame adds to the last), so a golden
// pins the renderer and the director together: any change to the walk, the
// timing or the shading moves it. --tolerance N allows up to N differing
// pixels (default 0). On a FAIL, out/golden/<name>/diff.png marks differing
// pixels in red over a dimmed copy of the golden. --update copies the
// rendered frame over the golden instead of comparing (review the new PNGs
// before committing them).
//
// Exit codes: 0 all PASS (or updated), 1 a golden is missing (run --update),
// 2 usage error, 3 any FAIL (including a preview run that failed).
// No npm dependencies (PNG via node:zlib).

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."); // this cart
const REPO = path.resolve(ROOT, "../.."); // repository root, where zig build writes zig-out/
const PREVIEW = path.join(REPO, "tools", "preview.mjs");
const POSES = path.join(ROOT, "tests", "golden", "poses.json");
const GOLDEN_DIR = path.join(ROOT, "tests", "golden");
const OUT_DIR = path.join(ROOT, "out", "golden");

function usage(msg) {
    if (msg) console.error(`check_golden: ${msg}`);
    console.error("usage: node tools/check_golden.mjs [--update] [--tolerance N] [--only NAME[,NAME...]] [--wasm FILE]");
    process.exit(2);
}

const opts = { update: false, tolerance: 0, only: null, wasm: path.join(REPO, "zig-out", "bin", "snouty-pipes.wasm") };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    switch (a) {
        case "--update": opts.update = true; break;
        case "--tolerance": { const s = val(), n = Number(s); if (!Number.isInteger(n) || n < 0) usage(`--tolerance: bad integer '${s}'`); opts.tolerance = n; break; }
        case "--only": (opts.only ??= []).push(...val().split(",").map((s) => s.trim()).filter(Boolean)); break;
        case "--wasm": opts.wasm = path.resolve(val()); break;
        case "-h": case "--help": usage();
        default: usage(`unexpected argument '${a}'`);
    }
}

// ---------------------------------------------------------------- poses.json
let poses;
try { poses = JSON.parse(fs.readFileSync(POSES, "utf8")); } catch (e) { usage(`cannot read ${path.relative(ROOT, POSES)}: ${e.message}`); }
if (!Array.isArray(poses)) usage("poses.json must be an array");
const seen = new Set();
for (const [i, p] of poses.entries()) {
    const where = `poses.json[${i}]`;
    if (!p || typeof p.name !== "string" || !/^[\w.-]+$/.test(p.name)) usage(`${where}: bad or missing "name"`);
    if (seen.has(p.name)) usage(`${where}: duplicate name '${p.name}'`);
    seen.add(p.name);
    if (!Number.isInteger(p.seed) || p.seed < 0) usage(`${where} (${p.name}): "seed" must be a non-negative integer`);
    if (p.press !== undefined && !(Array.isArray(p.press) && p.press.every((c) => typeof c === "string"))) usage(`${where} (${p.name}): "press" must be an array of strings`);
    if (p.calls !== undefined && !(Array.isArray(p.calls) && p.calls.every((c) => typeof c === "string"))) usage(`${where} (${p.name}): "calls" must be an array of strings`);
    if (p.frames !== undefined && !(Number.isInteger(p.frames) && p.frames >= 1)) usage(`${where} (${p.name}): "frames" must be an integer >= 1`);
}
if (opts.only) {
    const unknown = opts.only.filter((n) => !seen.has(n));
    if (unknown.length) usage(`--only: unknown pose(s) ${unknown.join(", ")} (have ${[...seen].join(", ")})`);
    poses = poses.filter((p) => opts.only.includes(p.name));
}
if (!fs.existsSync(opts.wasm)) usage(`${path.relative(ROOT, opts.wasm)} not found (run zig build -Dcart=snouty-pipes at the repository root)`);

// ---------------------------------------------------------------- PNG
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
    // Normalise to RGB.
    if (bpp === 3) return { w, h, rgb: px };
    const rgb = Buffer.alloc(w * h * 3);
    for (let i = 0; i < w * h; i++) { rgb[i * 3] = px[i * 4]; rgb[i * 3 + 1] = px[i * 4 + 1]; rgb[i * 3 + 2] = px[i * 4 + 2]; }
    return { w, h, rgb };
}

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

// ---------------------------------------------------------------- run
const rel = (p) => path.relative(ROOT, p) || ".";
let fails = 0, missing = 0, passes = 0, updated = 0;
for (const p of poses) {
    const frames = p.frames ?? 1;
    const out = path.join(OUT_DIR, p.name);
    const args = [PREVIEW, opts.wasm, "--seed", String(p.seed)];
    for (const c of p.calls ?? []) args.push("--call", c);
    for (const b of p.press ?? []) args.push("--press", b);
    args.push("--frames", String(frames), "--start-skip", String(frames - 1), "--every", "1", "--out", out);
    fs.rmSync(out, { recursive: true, force: true });
    const r = spawnSync(process.execPath, args, { cwd: ROOT, encoding: "utf8" });
    const frameFile = path.join(out, `frame_${String(frames - 1).padStart(4, "0")}.png`);
    const label = p.name.padEnd(16);
    if (r.status !== 0 || !fs.existsSync(frameFile)) {
        fails++;
        const err = (r.stderr || "").trim().split("\n").filter((l) => !/^preview: cart copies its frame/.test(l)).slice(0, 4).join("\n    ");
        console.log(`FAIL ${label} preview exited ${r.status ?? r.signal}${err ? `:\n    ${err}` : ""}`);
        continue;
    }
    const golden = path.join(GOLDEN_DIR, `${p.name}.png`);
    if (opts.update) {
        fs.copyFileSync(frameFile, golden);
        updated++;
        console.log(`UPD  ${label} -> ${rel(golden)}`);
        continue;
    }
    if (!fs.existsSync(golden)) {
        missing++;
        console.log(`MISS ${label} no ${rel(golden)} (run node tools/check_golden.mjs --update${opts.only ? ` --only ${p.name}` : ""})`);
        continue;
    }
    let got, want;
    try { got = decodePNG(frameFile); want = decodePNG(golden); } catch (e) { fails++; console.log(`FAIL ${label} cannot decode PNG: ${e.message}`); continue; }
    if (got.w !== want.w || got.h !== want.h) { fails++; console.log(`FAIL ${label} size ${got.w}x${got.h}, golden ${want.w}x${want.h}`); continue; }
    let diff = 0, first = null;
    const vis = Buffer.alloc(want.w * want.h * 3);
    for (let i = 0; i < want.w * want.h; i++) {
        const o = i * 3;
        const same = got.rgb[o] === want.rgb[o] && got.rgb[o + 1] === want.rgb[o + 1] && got.rgb[o + 2] === want.rgb[o + 2];
        if (same) { vis[o] = want.rgb[o] >> 2; vis[o + 1] = want.rgb[o + 1] >> 2; vis[o + 2] = want.rgb[o + 2] >> 2; }
        else { vis[o] = 255; vis[o + 1] = 0; vis[o + 2] = 0; if (!first) first = [i % want.w, (i / want.w) | 0]; diff++; }
    }
    const where = first ? `, first at (${first[0]},${first[1]})` : "";
    if (diff <= opts.tolerance) {
        passes++;
        console.log(`PASS ${label} ${diff} px differ${where}`);
    } else {
        fails++;
        fs.writeFileSync(path.join(out, "diff.png"), encodePNG(vis, want.w, want.h));
        console.log(`FAIL ${label} ${diff} px differ (tolerance ${opts.tolerance})${where}; see ${rel(path.join(out, "diff.png"))}`);
    }
}
if (opts.update) console.log(`check_golden: updated ${updated} golden(s), ${fails} failed to render`);
else console.log(`check_golden: ${passes} pass, ${fails} fail, ${missing} missing`);
process.exit(fails ? 3 : missing ? 1 : 0);
