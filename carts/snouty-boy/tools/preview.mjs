#!/usr/bin/env node
// Headless SYCL Badge V2 cart runner: cart.wasm -> PNG frames.
//
//   node tools/preview.mjs <cart.wasm> --frames N [--every K] [--out DIR]
//                          [--start-skip S] [--fb-addr auto|dwarf|sim|0xADDR]
//                          [--seed N] [--controls BITS] [--press [BTN:]T1-T2[,...]] [--script FILE.json]
//                          [--dump-exports NAME[,NAME...]] [--expect "NAME OP VALUE"]...
//                          [--at "T NAME OP VALUE"]... [--call-at "T NAME"]... [--quiet] [--raw-colors]
//
// Runs start(), then N x update(). Every K-th update after the first S updates,
// the displayed framebuffer is decoded and written to DIR/frame_XXXX.png
// (XXXX = update index, 0-based). DIR/frames.json gets metadata.
// No npm dependencies (PNG is encoded with node:zlib).
//
// Input: the u16 at 0x04 (cart.Controls bits: start 0, select 1, a 2, b 3,
// click 4, up 5, down 6, left 7, right 8) is set before every update() to
//   --controls | every --press item covering the tick | every --script entry covering it.
// --press items are BTN:T1-T2 (BTN in A B START SELECT UP DOWN LEFT RIGHT, any
// case; bare T1-T2 means A), inclusive tick ranges; --press may be repeated.
// --script is a JSON array of { "from": T1, "to": T2, "hold": ["A", "UP"] },
// also inclusive. CLICK is refused (the OS owns it).
//
// Assertions: after the last update(), each --dump-exports name (a zero-arg
// function export, e.g. debug_state) is called and its result is recorded in
// frames.json "exports" and printed on stderr. --expect "debug_score > 0"
// (OP in == != < <= > >=, integer VALUE; implies dumping NAME) prints PASS or
// FAIL per expectation; any FAIL exits 3 after frames.json is written. Values
// are what the export returns to JS: a u32 >= 2^31 reads as negative (i32).
// --at T NAME OP VALUE is the same check made right after update #T (0-based;
// with --frames 1800, T = 1799 is the moment the end-of-run exports are read);
// results go to frames.json "at", and a FAIL also exits 3. --call-at T NAME
// calls NAME right after update #T and records {tick, name, value} under
// "calls". Both accept either separate arguments (--at 1799 debug_score '>' 0)
// or one quoted string (--at "1799 debug_score > 0"), are repeatable, and run
// in command-line order when they share a tick. T must be < N.
// --quiet writes no PNGs and skips framebuffer decoding (soak runs).
//
// Exit codes: 0 ok, 1 cart/load error, 2 usage error, 3 wasm trap or failed --expect/--at.
//
// ---------------------------------------------------------------------------
// Where is the framebuffer? (read this before trusting a preview)
// ---------------------------------------------------------------------------
// sycl-badge/src/os/cart/platform_wasm.zig (current upstream API) declares
//
//     var framebuffer_data: [2]Framebuffer align(0x2000) = undefined;
//
// i.e. the two framebuffers are ordinary wasm globals placed by the linker at
// some 0x2000-aligned address after global_base (0xa01e). All drawing (rect,
// text, blit, ...) is implemented in Zig on the wasm side and writes there;
// current carts import nothing but `env.memory`.
//
// The upstream simulator (simulator/src/framebuffer.ts) instead displays a
// FIXED region: 160*128 u16 at ADDR_FRAMEBUFFER = 0x20. With the current API
// nothing is drawn there (and 0x0..0x39a0 is the wasm shadow stack), so the
// simulator does not show current-API carts unless the cart copies its frame
// to 0x20 itself.
//
// Which of the two buffers is "displayed"? api.zig present() publishes the
// current draw buffer (`api.framebuffer`) and then swaps. On hardware the OS
// calls present() after every update(). On wasm, platform_wasm.zig's exported
// update() calls only root.update() and present_and_acquire() is a no-op, so
// present() never runs unless the cart calls it: draw_buffer_index stays 0 and
// the cart always draws into framebuffers[0]. Either way, the buffer to show
// after update() returns is the one `api.framebuffer` pointed at BEFORE that
// update() ran: if present() ran once during update() it published exactly
// that buffer; if it never ran, that is the buffer the cart drew into (and
// hardware would present it next). We therefore read `api.framebuffer` (from
// DWARF, when it still exists as a variable) before each update(); when it
// has been constant-folded away (it is never reassigned if present() is not
// referenced) it is framebuffers[0].
//
// Locating framebuffer_data: we read DWARF (.debug_info) for the variable
// `platform_wasm.framebuffer_data`. In ReleaseSmall wasm builds of carts that
// only STORE to the framebuffer (dvd, plasma, lcd-text) LLVM proves the global
// is never read and deletes it together with all pixel stores; DWARF then has
// the variable with no location, and this tool says so. Keeping the pointer
// observable (e.g. `export fn ...() usize { return @intFromPtr(cart.framebuffer); }`)
// prevents that.
//
// If the cart exports `cart_framebuffer_address() usize` (returning
// @intFromPtr(cart.framebuffer)), auto mode calls it before each update()
// instead; this works for stripped builds too.
//
// --fb-addr modes: auto (default: export, else sim-shim if the cart copies its
// frame to 0x20 (detected after the first update), else dwarf, else sim),
// dwarf, sim (0x20, what
// the upstream simulator displays), or an explicit address (buffer base).
//
// Pixel format: column-major framebuffer[x][y], u16 each. On wasm
// Pixel.from_color() byte-swaps DisplayColor (packed r:u5 g:u6 b:u5, r in the
// low bits), so memory holds the DisplayColor big-endian. The upstream
// simulator's WebGL compositor un-swaps the bytes and uploads the u16 as
// UNSIGNED_SHORT_5_6_5, which takes red from bits 15..11, where DisplayColor
// keeps blue: the browser shows DisplayColor's r and b swapped (the legacy
// badge-v1 API had b in the low bits, which the simulator was written for).
// By default this tool renders exactly what the simulator shows, so a cart
// that wants correct browser colors must pre-swap when it copies to 0x20 (our
// present_wasm() does). --raw-colors instead decodes DisplayColor as the cart
// wrote it, i.e. what the hardware shows for a cart's own framebuffer.

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const WIDTH = 160, HEIGHT = 128;
const FB_BYTES = WIDTH * HEIGHT * 2;
const SIM_ADDR_FRAMEBUFFER = 0x20;
const ADDR_CONTROLS = 0x04;
const FLASH_PAGE_SIZE = 256, FLASH_PAGE_COUNT = 16000;
const OPTIONAL_COLOR_NONE = -1;

// ---------------------------------------------------------------- args
function usage(msg) {
    if (msg) console.error(`preview: ${msg}`);
    console.error("usage: node tools/preview.mjs <cart.wasm> --frames N [--every K] [--out DIR] [--start-skip S]\n" +
        "                          [--fb-addr auto|dwarf|sim|0xADDR] [--seed N] [--controls BITS]\n" +
        "                          [--press [BTN:]T1-T2[,...]] [--script FILE.json] [--dump-exports NAME[,NAME...]]\n" +
        "                          [--expect \"NAME OP VALUE\"]... [--at \"T NAME OP VALUE\"]... [--call-at \"T NAME\"]...\n" +
        "                          [--quiet] [--raw-colors]\n" +
        "  BTN: A B START SELECT UP DOWN LEFT RIGHT (bare T1-T2 = A); OP: == != < <= > >=\n" +
        "  --at/--call-at: T is the 0-based update index (< N); also as separate args: --at T NAME OP VALUE, --call-at T NAME");
    process.exit(2);
}
// cart.Controls bit positions (sycl-badge src/os/cart/api.zig). CLICK (bit 4) is OS-owned and never set.
const BUTTONS = { START: 1 << 0, SELECT: 1 << 1, A: 1 << 2, B: 1 << 3, UP: 1 << 5, DOWN: 1 << 6, LEFT: 1 << 7, RIGHT: 1 << 8 };
const buttonBit = (name, where) => {
    const n = typeof name === "string" ? name.trim().toUpperCase() : null;
    if (n === "CLICK") return { error: `${where}: CLICK cannot be pressed (the OS owns the joystick click)` };
    if (n === null || !(n in BUTTONS)) return { error: `${where}: unknown button ${JSON.stringify(name)} (use ${Object.keys(BUTTONS).join(" ")})` };
    return { name: n, bit: BUTTONS[n] };
};
const isTick = (v) => Number.isInteger(v) && v >= 0;
function parsePressItem(item) {
    const m = /^\s*(?:([A-Za-z]+)\s*:)?\s*(\d+)\s*-\s*(\d+)\s*$/.exec(item);
    if (!m) usage(`bad --press item '${item}' (want BTN:T1-T2 or T1-T2)`);
    const btn = buttonBit(m[1] ?? "A", `--press '${item}'`);
    if (btn.error) usage(btn.error);
    const from = Number(m[2]), to = Number(m[3]);
    if (to < from) usage(`bad --press item '${item}': end ${to} < start ${from}`);
    return { button: btn.name, from, to };
}
function parseExpect(s) {
    const m = /^\s*([A-Za-z_$][\w$.]*)\s*(==|!=|<=|>=|<|>)\s*(-?\d+)\s*$/.exec(s);
    if (!m) usage(`bad --expect '${s}' (want "NAME OP VALUE", OP in == != < <= > >=, integer VALUE)`);
    return { expr: `${m[1]} ${m[2]} ${m[3]}`, name: m[1], op: m[2], value: Number(m[3]) };
}
// --at / --call-at take several words, either as one quoted argument or as
// separate arguments: consume arguments until the joined text parses (at most
// `max`), never swallowing the next --flag.
const AT_RE = /^\s*(\d+)\s+([A-Za-z_$][\w$.]*)\s*(==|!=|<=|>=|<|>)\s*(-?\d+)\s*$/;
const CALL_AT_RE = /^\s*(\d+)\s+([A-Za-z_$][\w$.]*)\s*$/;
function takeWords(flag, re, max, want) {
    const words = [];
    while (words.length < max && argIndex + 1 < argv.length && !argv[argIndex + 1].startsWith("--")) {
        words.push(argv[++argIndex]);
        const m = re.exec(words.join(" "));
        if (m) return m;
    }
    usage(words.length ? `bad ${flag} '${words.join(" ")}' (want ${want})` : `${flag} needs a value (${want})`);
}
let argIndex = 0;
const argv = process.argv.slice(2);
const opts = { frames: null, every: 1, out: "out", startSkip: 0, fbAddr: "auto", seed: 1, controls: 0, press: [], rawColors: false,
    script: null, dumpExports: [], expect: [], quiet: false, timed: [] };
let wasmPath = null;
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    argIndex = i;
    const val = () => { if (i + 1 >= argv.length) usage(`${a} needs a value`); return argv[++i]; };
    const int = () => { const s = val(); const n = Number(s); if (!Number.isInteger(n) || n < 0) usage(`${a}: bad integer '${s}'`); return n; };
    switch (a) {
        case "--frames": opts.frames = int(); break;
        case "--every": opts.every = int(); if (opts.every < 1) usage("--every must be >= 1"); break;
        case "--out": opts.out = val(); break;
        case "--start-skip": opts.startSkip = int(); break;
        case "--fb-addr": opts.fbAddr = val(); break;
        case "--seed": opts.seed = int(); break;
        case "--controls": opts.controls = int(); break;
        case "--press": opts.press.push(...val().split(",").map(parsePressItem)); break;
        case "--script": opts.script = val(); break;
        case "--dump-exports": for (const n of val().split(",").map((s) => s.trim())) { if (!n) usage("--dump-exports: empty name"); if (!opts.dumpExports.includes(n)) opts.dumpExports.push(n); } break;
        case "--expect": opts.expect.push(parseExpect(val())); break;
        case "--at": {
            const m = takeWords(a, AT_RE, 4, '"T NAME OP VALUE", OP in == != < <= > >=, integer T and VALUE'); i = argIndex;
            opts.timed.push({ kind: "at", tick: Number(m[1]), expr: `${m[2]} ${m[3]} ${m[4]}`, name: m[2], op: m[3], value: Number(m[4]) });
            break;
        }
        case "--call-at": {
            const m = takeWords(a, CALL_AT_RE, 2, '"T NAME", integer T'); i = argIndex;
            opts.timed.push({ kind: "call", tick: Number(m[1]), name: m[2] });
            break;
        }
        case "--quiet": opts.quiet = true; break;
        case "--raw-colors": opts.rawColors = true; break;
        case "-h": case "--help": usage();
        default:
            if (a.startsWith("--") || wasmPath) usage(`unexpected argument '${a}'`);
            wasmPath = a;
    }
}
if (!wasmPath) usage("missing <cart.wasm>");
if (opts.frames === null) usage("missing --frames N");
if (opts.controls > 0xffff) usage(`--controls ${opts.controls} does not fit in 16 bits`);
for (const e of opts.expect) if (!opts.dumpExports.includes(e.name)) opts.dumpExports.push(e.name);
for (const t of opts.timed) if (t.tick >= opts.frames) usage(`--${t.kind === "at" ? "at" : "call-at"} ${t.tick} ${t.name}: tick ${t.tick} is beyond the run (--frames ${opts.frames} runs updates 0..${opts.frames - 1})`);
// Items per tick, in command-line order.
const timedAt = new Map();
for (const t of opts.timed) { if (!timedAt.has(t.tick)) timedAt.set(t.tick, []); timedAt.get(t.tick).push(t); }

// ---------------------------------------------------------------- input script
function loadScript(file) {
    const fail = (m) => { console.error(`preview: --script ${file}: ${m}`); process.exit(2); };
    let text, list;
    try { text = fs.readFileSync(file, "utf8"); } catch (e) { fail(`cannot read: ${e.message}`); }
    try { list = JSON.parse(text); } catch (e) { fail(`invalid JSON: ${e.message}`); }
    if (!Array.isArray(list)) fail(`top level must be a JSON array of { "from", "to", "hold" } entries, got ${typeof list}`);
    return list.map((ent, k) => {
        const at = `entry ${k}`;
        if (ent === null || typeof ent !== "object" || Array.isArray(ent)) fail(`${at}: must be an object { "from", "to", "hold" }`);
        for (const key of Object.keys(ent)) if (!["from", "to", "hold"].includes(key)) fail(`${at}: unknown field "${key}" (allowed: from, to, hold)`);
        for (const key of ["from", "to"]) {
            if (!(key in ent)) fail(`${at}: missing field "${key}"`);
            if (!isTick(ent[key])) fail(`${at}: field "${key}" must be a non-negative integer tick, got ${JSON.stringify(ent[key])}`);
        }
        if (ent.to < ent.from) fail(`${at}: field "to" (${ent.to}) is before "from" (${ent.from})`);
        if (!("hold" in ent)) fail(`${at}: missing field "hold"`);
        if (!Array.isArray(ent.hold)) fail(`${at}: field "hold" must be an array of button names, got ${JSON.stringify(ent.hold)}`);
        const hold = [];
        let bits = 0;
        ent.hold.forEach((b, j) => {
            const r = buttonBit(b, `${at}: field "hold"[${j}]`);
            if (r.error) fail(r.error);
            if (!hold.includes(r.name)) hold.push(r.name);
            bits |= r.bit;
        });
        return { from: ent.from, to: ent.to, hold, bits };
    });
}
const scriptEntries = opts.script ? loadScript(opts.script) : [];

// Per-tick controls, computed once: controlsAt[i] is the u16 written to 0x04 before update() #i.
const controlsAt = new Uint16Array(opts.frames).fill(opts.controls);
const orRange = (from, to, bits) => { for (let i = from, end = Math.min(to, opts.frames - 1); i <= end; i++) controlsAt[i] |= bits; };
for (const p of opts.press) orRange(p.from, p.to, BUTTONS[p.button]);
for (const s of scriptEntries) orRange(s.from, s.to, s.bits);

// ---------------------------------------------------------------- wasm file parsing
function readWasmInfo(buf) {
    if (buf.length < 8 || buf.readUInt32LE(0) !== 0x6d736100) throw new Error("not a wasm module (bad magic)");
    let p = 8;
    const leb = () => { let r = 0, s = 0, b; do { b = buf[p++]; r += (b & 0x7f) * 2 ** s; s += 7; } while (b & 0x80); return r; };
    const custom = {}, data = [];
    while (p < buf.length) {
        const id = buf[p++]; const len = leb(); const end = p + len;
        if (id === 0) { const nl = leb(); custom[buf.toString("utf8", p, p + nl)] = buf.subarray(p + nl, end); }
        else if (id === 11) {
            const n = leb();
            for (let i = 0; i < n; i++) {
                const flag = leb(); let off = null;
                if (flag === 2) leb();
                if (flag === 0 || flag === 2) { const op = buf[p++]; off = op === 0x41 ? leb() : null; while (buf[p] !== 0x0b) p++; p++; }
                const sz = leb(); data.push({ off, size: sz }); p += sz;
            }
        }
        p = end;
    }
    return { custom, data };
}

// Minimal DWARF 2-5 .debug_info walker: returns Map(name -> {addr|null}) for
// DW_TAG_variable DIEs, keyed by both DW_AT_linkage_name and DW_AT_name.
function dwarfVariables(custom) {
    const info = custom[".debug_info"], abbr = custom[".debug_abbrev"], str = custom[".debug_str"];
    const vars = new Map();
    if (!info || !abbr) return null;
    const R = (b, o) => ({
        b, o,
        u8() { return this.b[this.o++]; },
        u16() { const v = this.b.readUInt16LE(this.o); this.o += 2; return v; },
        u32() { const v = this.b.readUInt32LE(this.o); this.o += 4; return v; },
        uleb() { let r = 0, s = 0, x; do { x = this.b[this.o++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; },
        sleb() { let r = 0, s = 0, x; do { x = this.b[this.o++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); if (x & 0x40) r -= 2 ** s; return r; },
        block(n) { const v = this.b.subarray(this.o, this.o + n); this.o += n; return v; },
    });
    const abbrevCache = new Map();
    const abbrevs = (off) => {
        if (abbrevCache.has(off)) return abbrevCache.get(off);
        const r = R(abbr, off), m = new Map();
        for (;;) {
            const code = r.uleb(); if (!code) break;
            const tag = r.uleb(); r.u8();
            const attrs = [];
            for (;;) { const at = r.uleb(), form = r.uleb(); let ic; if (form === 0x21) ic = r.sleb(); if (!at && !form) break; attrs.push([at, form, ic]); }
            m.set(code, { tag, attrs });
        }
        abbrevCache.set(off, m); return m;
    };
    const cstr = (o) => { if (!str) return null; let e = o; while (str[e]) e++; return str.toString("utf8", o, e); };
    const r = R(info, 0);
    while (r.o + 11 <= info.length) {
        const unitLen = r.u32(); if (unitLen >= 0xfffffff0) return vars; // 64-bit DWARF: unsupported
        const unitEnd = r.o + unitLen;
        const ver = r.u16(); let abbrOff, addrSize;
        if (ver >= 5) { const ut = r.u8(); addrSize = r.u8(); abbrOff = r.u32(); if (ut === 2 || ut === 6) r.o += 12; else if (ut === 4 || ut === 5) r.o += 8; }
        else { abbrOff = r.u32(); addrSize = r.u8(); }
        const ab = abbrevs(abbrOff);
        while (r.o < unitEnd) {
            const code = r.uleb(); if (!code) continue;
            const a = ab.get(code); if (!a) throw new Error(`DWARF: unknown abbrev ${code}`);
            let name = null, link = null, loc = null;
            for (const [at, form0, ic] of a.attrs) {
                let form = form0; if (form === 0x16) form = r.uleb();
                let v;
                switch (form) {
                    case 0x01: v = addrSize === 4 ? r.u32() : (r.o += 8, null); break;
                    case 0x03: v = r.block(r.u16()); break;
                    case 0x04: v = r.block(r.u32()); break;
                    case 0x05: case 0x12: r.o += 2; break;
                    case 0x06: case 0x10: case 0x13: case 0x17: case 0x1c: case 0x1d: case 0x1f: v = r.u32(); break;
                    case 0x07: case 0x14: case 0x20: r.o += 8; break;
                    case 0x08: { let e = r.o; while (r.b[e]) e++; v = r.b.toString("utf8", r.o, e); r.o = e + 1; break; }
                    case 0x09: case 0x18: v = r.block(r.uleb()); break;
                    case 0x0a: v = r.block(r.u8()); break;
                    case 0x0b: case 0x0c: case 0x11: r.o += 1; break;
                    case 0x0d: r.sleb(); break;
                    case 0x0e: v = cstr(r.u32()); break;
                    case 0x0f: case 0x15: case 0x1a: case 0x1b: case 0x22: case 0x23: r.uleb(); break;
                    case 0x19: case 0x21: break;
                    case 0x1e: r.o += 16; break;
                    case 0x25: case 0x29: r.o += 1; break;
                    case 0x26: case 0x2a: r.o += 2; break;
                    case 0x27: case 0x2b: r.o += 3; break;
                    case 0x28: case 0x2c: r.o += 4; break;
                    default: throw new Error(`DWARF: unsupported form 0x${form.toString(16)}`);
                }
                if (a.tag !== 0x34) continue;
                if (at === 0x03 && typeof v === "string") name = v;
                else if (at === 0x6e && typeof v === "string") link = v;
                else if (at === 0x02 && v instanceof Uint8Array) loc = v;
            }
            if (a.tag === 0x34 && (name || link)) {
                // Only a plain `DW_OP_addr <u32>` location is a static address.
                const addr = loc && loc.length === 5 && loc[0] === 0x03 ? Buffer.from(loc).readUInt32LE(1) : null;
                const entry = { addr: addr === 0xffffffff ? null : addr };
                for (const k of [link, name]) if (k && !(vars.has(k) && vars.get(k).addr !== null)) vars.set(k, entry);
            }
        }
        r.o = unitEnd;
    }
    return vars;
}

// ---------------------------------------------------------------- PNG
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
    ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr),
        chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

// ---------------------------------------------------------------- simulator font (simulator/src/font.ts)
const FONT = Buffer.from("///////////Hx8fPz//P/5OTk///////kwGTk5MBk//vgy+D6QPv/51bN+/ZtXP/jycnjyUzgf/Pz8////////Pnz8/P5/P/n8/n5+fPn///k8cBx5P////n54Hn5//////////Pz5////+B////////////z8///fv379+/f//Hszk5OZvH/+fH5+fn54H/gznxw4cfAf+B8+fD+TmD/+PDkzMB8/P/Az8D+fk5g//Dnz8DOTmD/wE58+fPz8//hzsbh2F5g/+DOTmB+fOH///Pz//Pz////8/P/8/Pn//z58+fz+fz////Af8B////n8/n8+fPn/+DATnzx//H/4N9RVVBf4P/x5M5OQE5Of8DOTkDOTkD/8OZPz8/mcP/BzM5OTkzB/8BPz8DPz8B/wE/PwM/Pz//wZ8/MTmZwf85OTkBOTk5/4Hn5+fn54H/+fn5+fk5g/85MycPByMx/5+fn5+fn4H/OREBASk5Of85GQkBITE5/4M5OTk5OYP/Azk5OQM/P/+DOTk5ITOF/wM5OTEHIzH/hzM/g/k5g/+B5+fn5+fn/zk5OTk5OYP/OTk5EYPH7/85OSkBARE5/zkRg8eDETn/mZmZw+fn5/8B8ePHjx8B/8PPz8/Pz8P/f7/f7/f7/f+H5+fn5+eH/8eT/////////////////wHv9///////////g/mBOYH/Pz8DOTk5g////4E/Pz+B//n5gTk5OYH///+DOQE/g//x54Hn5+fn////gTk5gfmDPz8DOTk5Of/n/8fn5+eB//P/4/Pz8/OHPz8xAwcjMf/H5+fn5+eB////A0lJSUn///8DOTk5Of///4M5OTmD////Azk5Az8///+BOTmB+fn//5GPn5+f////gz+D+QP/5+eB5+fn5////zk5OTmB////mZmZw+f///9JSUlJgf///zkBxwE5////OTk5gfmD//8B48ePAf/z5+fP5+fz/+fn5+fn5+f/n8/P58/Pn////49F4///////////k5P/gxEpOSkpg/+DMSkxKTGD/4MREX0REYP/gwEBfQEBg/+DESF9IRGD/4MRCX0JEYP/gxE5VRERg/+DERFVORGD/4MROX05EYP/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////5//n58fHx//vgykvKYPv/8OZnwOfnwH//6Xb29ul//+ZmcOB54Hn/+fn5//n5+f/w5mH2+GZw/+T/////////8O9Zl5eZr3Dh8OTw///////yZMnk8n/////gfn5///////////////DvUZaRlq9w4P/////////79fv///////n54Hn5/+B/8fz58P/////w+fzx//////37///////////MzMzMwk/wZW1lcH19f/////Pz/////////////fP58fnw//////Hk5PH//////8nk8mTJ///vTu3rdmxff+9O7ep3btx/x271y3ZsX3/x//HnzkBg//f78eTOQE5//fvx5M5ATn/x5PHkzkBOf/Lp8eTOQE5/5P/x5M5ATn/79fHkzkBOf/BhychBych/8OZPz+Zw/fP3+8BPwM/Af/37wE/Az8B/8eTAT8DPwH/k/8BPwM/Af/v94Hn5+eB//fvgefn54H/58OB5+fngf+Z/4Hn5+eB/4eTmQmZk4f/y6cZCQEhMf/f74M5OTmD//fvgzk5OYP/x5ODOTk5g//Lp4M5OTmD/5P/gzk5OYP//7vX79e7//+DOTEpGTmD/9/vOTk5OYP/9+85OTk5g//Hk/85OTmD/5P/OTk5OYP/9++ZmcPn5/8/Azk5OQM//8OZmZOZiZP/3++D+YE5gf/374P5gTmB/8eTg/mBOYH/y6eD+YE5gf+T/4P5gTmB/+/Xg/mBOYH///+D6YEvg////4E/P4H3z9/vgzkBP4P/9++DOQE/g//Hk4M5AT+D/5P/gzkBP4P/3+//x+fngf/37//H5+eB/8eT/8fn54H/k//H5+fngf+bh2eDOTmD/8unAzk5OTn/3++DOTk5g//374M5OTmD/8eTgzk5OYP/y6eDOTk5g/+T/4M5OTmD///n/4H/5/////+DMSkZg//f7zk5OTmB//fvOTk5OYH/x5P/OTk5gf+T/zk5OTmB//fvOTk5gfmDPz8DOTkDPz+T/zk5OYH5gw==", "base64");

// ---------------------------------------------------------------- main
let wasmBuf;
try { wasmBuf = fs.readFileSync(wasmPath); } catch (e) { console.error(`preview: cannot read ${wasmPath}: ${e.message}`); process.exit(1); }
let module;
try { module = new WebAssembly.Module(wasmBuf); } catch (e) { console.error(`preview: ${wasmPath}: invalid wasm: ${e.message}`); process.exit(1); }
const { custom, data: dataSegs } = readWasmInfo(wasmBuf);
const imports = WebAssembly.Module.imports(module);
const exportNames = WebAssembly.Module.exports(module).map((e) => e.name);
for (const need of ["start", "update"]) {
    if (!exportNames.includes(need)) { console.error(`preview: ${wasmPath} does not export '${need}()' (exports: ${exportNames.join(", ") || "none"}). Did the cart call cart.export_start_code()?`); process.exit(1); }
}

// Same memory as simulator/src/runtime.ts: 64 pages, fixed.
const memory = new WebAssembly.Memory({ initial: 64, maximum: 64 });
const mem8 = () => new Uint8Array(memory.buffer);
const dv = () => new DataView(memory.buffer);

// Legacy host drawing imports (simulator/src/framebuffer.ts semantics): they
// draw into the simulator's fixed region at 0x20, colors are u16 stored
// byte-swapped. Current-API carts do not import these.
const simFb = () => new Uint16Array(memory.buffer, SIM_ADDR_FRAMEBUFFER, WIDTH * HEIGHT);
const swap16 = (c) => ((c & 0xff) << 8) | ((c >> 8) & 0xff);
function point(c, x, y) { if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT) simFb()[x * HEIGHT + y] = swap16(c); }
function hline(c, x, y, len) { for (let xx = Math.max(0, x); xx < Math.min(WIDTH, x + len); xx++) point(c, xx, y); }
function vline(c, x, y, len) { for (let yy = Math.max(0, y); yy < Math.min(HEIGHT, y + len); yy++) point(c, x, yy); }
function rect(stroke, fill, x, y, w, h) {
    if (fill !== OPTIONAL_COLOR_NONE) for (let yy = y; yy < y + h; yy++) hline(fill, x, yy, w);
    if (stroke !== OPTIONAL_COLOR_NONE) { hline(stroke, x, y, w); hline(stroke, x, y + h - 1, w); vline(stroke, x, y, h); vline(stroke, x + w - 1, y, h); }
}
function oval(stroke, fill, x, y, w, h) {
    // Simple scanline ellipse (not pixel-identical to the simulator's midpoint version).
    const rx = w / 2, ry = h / 2, cx = x + rx, cy = y + ry;
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) {
        const dx = (xx + 0.5 - cx) / rx, dy = (yy + 0.5 - cy) / ry, d = dx * dx + dy * dy;
        if (d > 1) continue;
        const edge = ((xx + 1.5 - cx) / rx) ** 2 + dy * dy > 1 || ((xx - 0.5 - cx) / rx) ** 2 + dy * dy > 1 ||
            dx * dx + ((yy + 1.5 - cy) / ry) ** 2 > 1 || dx * dx + ((yy - 0.5 - cy) / ry) ** 2 > 1;
        if (edge && stroke !== OPTIONAL_COLOR_NONE) point(stroke, xx, yy);
        else if (fill !== OPTIONAL_COLOR_NONE) point(fill, xx, yy);
    }
}
function line(c, x1, y1, x2, y2) {
    const dx = Math.abs(x2 - x1), sx = x1 < x2 ? 1 : -1, dy = -Math.abs(y2 - y1), sy = y1 < y2 ? 1 : -1;
    let err = dx + dy;
    for (;;) { point(c, x1, y1); if (x1 === x2 && y1 === y2) break; const e2 = 2 * err; if (e2 >= dy) { err += dy; x1 += sx; } if (e2 <= dx) { err += dx; y1 += sy; } }
}
function text(fg, bg, ptr, len, x, y, scale = 1) {
    const s = Math.max(1, scale | 0), bytes = mem8().slice(ptr, ptr + len);
    let cx = x;
    for (const ch of bytes) {
        if (ch === 10) { y += 8 * s; cx = x; continue; }
        if (ch >= 32) for (let row = 0; row < 8; row++) for (let col = 0; col < 8; col++) {
            const bit = (FONT[((ch - 32) << 3) + row] >> (7 - col)) & 1;
            const c = bit === 0 ? fg : bg; // 0 bit = foreground, as in the simulator
            if (c === OPTIONAL_COLOR_NONE) continue;
            for (let sy = 0; sy < s; sy++) for (let sx = 0; sx < s; sx++) point(c, cx + col * s + sx, y + row * s + sy);
        }
        cx += 8 * s;
    }
}
function blit(spritePtr, x, y, w, h, srcX, srcY, stride, flags) {
    const spr = new Uint16Array(memory.buffer, spritePtr & ~1);
    const flipX = flags & 1, flipY = flags & 2, rot = flags & 4;
    for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++) {
        const fx = rot ? !flipX : flipX;
        const sx = srcX + (fx ? w - xx - 1 : xx), sy = srcY + (flipY ? h - yy - 1 : yy);
        point(spr[sy * stride + sx], x + (rot ? yy : xx), y + (rot ? xx : yy));
    }
}
let rngState = (opts.seed >>> 0) || 1;
function rand() { let x = rngState; x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; rngState = x; return x | 0; }
const flash = new Uint8Array(FLASH_PAGE_SIZE * FLASH_PAGE_COUNT);
const hostEnv = {
    memory, rect, oval, line, hline, vline, text, blit,
    tone() {}, // audio: no-op
    read_flash(off, dst, len) { const n = Math.max(0, Math.min(len, flash.length - off)); if (n > 0) mem8().set(flash.subarray(off, off + n), dst); return n; },
    write_flash_page(page, src) { if (page >= 0 && page < FLASH_PAGE_COUNT) flash.set(mem8().subarray(src, src + FLASH_PAGE_SIZE), page * FLASH_PAGE_SIZE); },
    rand,
    trace(ptr, len) { process.stderr.write(`trace: ${Buffer.from(mem8().slice(ptr, ptr + len)).toString("utf8")}\n`); },
};
const env = {};
const missing = [];
for (const imp of imports) {
    if (imp.module !== "env") { missing.push(`${imp.module}.${imp.name}`); continue; }
    if (imp.name in hostEnv) env[imp.name] = hostEnv[imp.name];
    else missing.push(`env.${imp.name} (${imp.kind})`);
}
if (missing.length) { console.error(`preview: cart imports functions this runner does not provide: ${missing.join(", ")}`); process.exit(1); }

let instance;
try { instance = new WebAssembly.Instance(module, { env }); }
catch (e) { console.error(`preview: instantiation failed: ${e.message}`); process.exit(1); }

// --dump-exports / --expect / --at / --call-at names must be zero-arg function exports; check before running.
{
    const wanted = [...opts.dumpExports];
    for (const t of opts.timed) if (!wanted.includes(t.name)) wanted.push(t.name);
    const callable = exportNames.filter((n) => typeof instance.exports[n] === "function" && instance.exports[n].length === 0 && n !== "start" && n !== "update" && n !== "_start" && n !== "_initialize");
    const bad = wanted.filter((n) => !callable.includes(n));
    if (bad.length) {
        const why = bad.map((n) => !exportNames.includes(n) ? `'${n}' is not exported`
            : typeof instance.exports[n] !== "function" ? `'${n}' is not a function`
            : ["start", "update", "_start", "_initialize"].includes(n) ? `'${n}' is an entry point, not a query`
            : `'${n}' takes ${instance.exports[n].length} argument(s)`).join("; ");
        console.error(`preview: --dump-exports/--expect/--at/--call-at: ${why}. Zero-arg function exports in ${wasmPath}: ${callable.join(", ") || "none"} (all exports: ${exportNames.join(", ") || "none"})`);
        process.exit(2);
    }
}

// Resolve framebuffer location.
let dwarf = null, dwarfError = null;
try { dwarf = dwarfVariables(custom); } catch (e) { dwarfError = e.message; }
const fbVar = dwarf && (dwarf.get("platform_wasm.framebuffer_data") || dwarf.get("framebuffer_data"));
const ptrVar = dwarf && (dwarf.get("api.framebuffer"));
let fbBase, fbSource;
const warnings = [];
const warn = (m) => { warnings.push(m); console.error(`preview: warning: ${m}`); };
const mode = opts.fbAddr;
const addrExport = typeof instance.exports.cart_framebuffer_address === "function" ? instance.exports.cart_framebuffer_address : null;
if (mode === "sim") { fbBase = SIM_ADDR_FRAMEBUFFER; fbSource = "sim"; }
else if (mode === "auto" && addrExport) {
    // Cart exports its draw-buffer pointer; buffer 0 has the lower address.
    fbSource = "export";
    fbBase = addrExport() >>> 0;
    if (fbVar && fbVar.addr !== null) fbBase = fbVar.addr;
}
else if (mode === "auto" || mode === "dwarf") {
    if (fbVar && fbVar.addr !== null) { fbBase = fbVar.addr; fbSource = "dwarf"; }
    else {
        const why = dwarfError ? `DWARF parse failed (${dwarfError})`
            : !dwarf ? "cart has no DWARF debug info"
            : fbVar ? "platform_wasm.framebuffer_data exists in DWARF but has no address: the compiler optimized the framebuffer away, so the cart's pixel writes were deleted and nothing can be displayed (neither here nor in any simulator)"
            : "no platform_wasm.framebuffer_data variable in DWARF";
        if (mode === "dwarf") { console.error(`preview: --fb-addr dwarf: ${why}`); process.exit(1); }
        warn(`${why}; falling back to the simulator's fixed region at 0x20`);
        fbBase = SIM_ADDR_FRAMEBUFFER; fbSource = "sim";
    }
} else {
    const n = Number(mode);
    if (!Number.isInteger(n) || n < 0 || n + FB_BYTES > memory.buffer.byteLength) usage(`bad --fb-addr '${mode}'`);
    fbBase = n; fbSource = "explicit";
}
let hasPtr = (fbSource === "dwarf" || fbSource === "export") && ptrVar && ptrVar.addr !== null;
function displayedBufferAddr() {
    // See header comment: the buffer api.framebuffer points at before update().
    if (fbSource === "export") return addrExport() >>> 0;
    if (fbSource === "sim" || fbSource === "sim-shim") return fbBase;
    if (hasPtr) {
        const p = dv().getUint32(ptrVar.addr, true);
        if (p === fbBase || p === fbBase + FB_BYTES) return p;
    }
    return fbBase;
}

function decode(addr) {
    const m = mem8(), rgb = Buffer.alloc(WIDTH * HEIGHT * 3);
    for (let x = 0; x < WIDTH; x++) for (let y = 0; y < HEIGHT; y++) {
        const o = addr + (x * HEIGHT + y) * 2;
        const c = (m[o] << 8) | m[o + 1]; // byte-swapped on wasm: memory is big-endian DisplayColor
        let r = c & 0x1f, g = (c >> 5) & 0x3f, b = (c >> 11) & 0x1f;
        if (!opts.rawColors) [r, b] = [b, r]; // GL 5_6_5 reads red from the high bits
        const i = (y * WIDTH + x) * 3;
        rgb[i] = (r << 3) | (r >> 2); rgb[i + 1] = (g << 2) | (g >> 4); rgb[i + 2] = (b << 3) | (b >> 2);
    }
    return rgb;
}

function trap(where, e) {
    console.error(`preview: wasm trapped in ${where}: ${e && e.message ? e.message : e}`);
    if (e && e.stack) console.error(e.stack.split("\n").slice(1, 6).join("\n"));
    process.exit(3);
}

fs.mkdirSync(opts.out, { recursive: true });
for (const f of fs.readdirSync(opts.out)) if (/^frame_\d+\.png$/.test(f)) fs.unlinkSync(path.join(opts.out, f));

// Snapshot before start() so carts that draw only in start() are not flagged as blank.
const snap = (base) => Buffer.from(mem8().slice(base, Math.min(memory.buffer.byteLength, base + (base === SIM_ADDR_FRAMEBUFFER ? FB_BYTES : 2 * FB_BYTES))));
let initial = snap(fbBase);
const initialSim = snap(SIM_ADDR_FRAMEBUFFER);
// Shim detection: some carts (ours) copy their finished frame to the
// simulator's fixed region 0x20 at the end of update(), because upstream's
// simulator only displays that region. [0x20, 0xa020) overlaps the shadow
// stack, which occupies [0, initial __stack_pointer) in stack-first layout, so
// only the part above the stack is a reliable signal. If that part changes,
// the cart is feeding the simulator and auto mode shows what it would show.
const sp0 = instance.exports.__stack_pointer instanceof WebAssembly.Global ? instance.exports.__stack_pointer.value >>> 0 : 0;
const probeLo = Math.max(SIM_ADDR_FRAMEBUFFER, sp0), probeHi = SIM_ADDR_FRAMEBUFFER + FB_BYTES;
const probeInitial = probeLo + 256 <= probeHi ? Buffer.from(mem8().slice(probeLo, probeHi)) : null;
const canSwitchToShim = mode === "auto" && fbSource !== "export" && fbSource !== "sim" && probeInitial !== null;
// Simulator's controls address. Upstream's API ignores it; our cart reads it on wasm.
// controlsAt (see "input script" above) holds --controls | --press | --script per tick;
// before start() only --controls is set.
const setControls = (i) => dv().setUint16(ADDR_CONTROLS, i < 0 ? opts.controls : controlsAt[i], true);
setControls(-1);
for (const init of ["_start", "_initialize"]) if (exportNames.includes(init)) { try { instance.exports[init](); } catch (e) { trap(init, e); } }
try { instance.exports.start(); } catch (e) { trap("start()", e); }

const written = [];
let changed = false;
const OPS = { "==": (a, b) => a === b, "!=": (a, b) => a !== b, "<": (a, b) => a < b, "<=": (a, b) => a <= b, ">": (a, b) => a > b, ">=": (a, b) => a >= b };
// Calls a checked zero-arg export and returns its integer result (as JS sees it).
function callExport(n, flag) {
    let v;
    try { v = instance.exports[n](); } catch (e) { trap(`${n}()`, e); }
    if (typeof v === "bigint") v = Number(v);
    if (typeof v !== "number") { console.error(`preview: ${flag}: ${n}() returned nothing (it must return an integer)`); process.exit(2); }
    return v;
}
const atResults = [], callResults = [];
function runTimed(i) {
    for (const t of timedAt.get(i)) {
        const actual = callExport(t.name, t.kind === "at" ? "--at" : "--call-at");
        if (t.kind === "call") {
            callResults.push({ tick: i, name: t.name, value: actual });
            console.error(`preview: call after update #${i}: ${t.name} = ${actual}`);
        } else {
            const pass = OPS[t.op](actual, t.value);
            atResults.push({ tick: i, expr: t.expr, name: t.name, op: t.op, value: t.value, actual, pass });
            console.error(`preview: ${pass ? "PASS" : "FAIL"} after update #${i}: ${t.expr} (${t.name} = ${actual})`);
        }
    }
}
const t0 = Date.now();
for (let i = 0; i < opts.frames; i++) {
    let addr = opts.quiet ? 0 : displayedBufferAddr();
    setControls(i);
    try { instance.exports.update(); } catch (e) { trap(`update() #${i}`, e); }
    if (i === 0 && canSwitchToShim && Buffer.compare(probeInitial, Buffer.from(mem8().slice(probeLo, probeHi))) !== 0) {
        console.error(`preview: cart copies its frame to the simulator region at 0x20; showing that (use --fb-addr dwarf for ${fbSource} @ 0x${fbBase.toString(16)})`);
        fbSource = "sim-shim"; fbBase = SIM_ADDR_FRAMEBUFFER; hasPtr = false; initial = initialSim; addr = fbBase;
    }
    // Capture the frame BEFORE any per-tick export call: the wasm shadow stack
    // (0x0..0x39a0) overlaps the simulator region at 0x20, so calling an export
    // after update() scribbles a black band over columns ~49..57 of the frame.
    if (!(opts.quiet || i < opts.startSkip || (i - opts.startSkip) % opts.every !== 0)) {
        if (!changed && Buffer.compare(initial, Buffer.from(mem8().slice(fbBase, fbBase + initial.length))) !== 0) changed = true;
        const name = `frame_${String(i).padStart(4, "0")}.png`;
        fs.writeFileSync(path.join(opts.out, name), encodePNG(decode(addr), WIDTH, HEIGHT));
        written.push({ file: name, update: i, buffer: (addr - fbBase) / FB_BYTES | 0 });
    }
    if (timedAt.has(i)) runTimed(i);
}
const runMs = Date.now() - t0;
if (written.length && !changed) warn(`framebuffer region at 0x${fbBase.toString(16)} never changed since instantiation; frames are blank`);

// Query exports after the last update().
const exportValues = {};
for (const n of opts.dumpExports) exportValues[n] = callExport(n, "--dump-exports");
if (opts.dumpExports.length) console.error(`preview: exports after update #${opts.frames - 1}: ${opts.dumpExports.map((n) => `${n}=${exportValues[n]}`).join(" ")}`);
const expectResults = opts.expect.map((e) => {
    const actual = exportValues[e.name], pass = OPS[e.op](actual, e.value);
    console.error(`preview: ${pass ? "PASS" : "FAIL"} ${e.expr} (${e.name} = ${actual})`);
    return { ...e, actual, pass };
});
const failed = expectResults.filter((r) => !r.pass).length + atResults.filter((r) => !r.pass).length;
const checks = expectResults.length + atResults.length;

const meta = {
    cart: path.resolve(wasmPath), width: WIDTH, height: HEIGHT, format: "rgb565 column-major, wasm byte-swapped",
    updates: opts.frames, every: opts.every, startSkip: opts.startSkip, seed: opts.seed, controls: opts.controls,
    press: opts.press.map((p) => `${p.button}:${p.from}-${p.to}`).join(",") || null, pressItems: opts.press,
    script: opts.script ? { file: path.resolve(opts.script), entries: scriptEntries.map(({ from, to, hold }) => ({ from, to, hold })) } : null,
    quiet: opts.quiet, rawColors: opts.rawColors,
    imports: imports.map((i) => `${i.module}.${i.name}`), moduleExports: exportNames,
    exports: exportValues, expect: expectResults, at: atResults, calls: callResults,
    framebuffer: { source: fbSource, base: `0x${fbBase.toString(16)}`, buffer1: fbSource === "dwarf" || fbSource === "export" ? `0x${(fbBase + FB_BYTES).toString(16)}` : null, drawPointer: hasPtr ? `0x${ptrVar.addr.toString(16)}` : null },
    dataSegments: dataSegs.map((d) => ({ off: d.off === null ? null : `0x${d.off.toString(16)}`, size: d.size })),
    warnings, frames: written,
};
fs.writeFileSync(path.join(opts.out, "frames.json"), JSON.stringify(meta, null, 2) + "\n");
console.error(`preview: ${written.length} frame(s) from ${opts.frames} update(s) -> ${opts.out}/ (framebuffer ${fbSource} @ 0x${fbBase.toString(16)}, ${runMs} ms)`);
if (failed) {
    const list = [...atResults.filter((r) => !r.pass).map((r) => `${r.expr} after update #${r.tick} (got ${r.actual})`),
        ...expectResults.filter((r) => !r.pass).map((r) => `${r.expr} at the end (got ${r.actual})`)];
    console.error(`preview: ${failed} of ${checks} expectation(s) failed: ${list.join("; ")}`);
    process.exit(3);
}
