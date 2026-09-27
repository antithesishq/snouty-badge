#!/usr/bin/env node
// Soft-float check for the cart ELF (ARM, ELF32 little-endian).
//
//   node tools/check_float.mjs ../../zig-out/firmware/snouty-maze.elf [--quiet]
//
// The cart must use the Cortex-M33 single-precision FPU for all float math.
// Any f64 operation, or an f32 operation the FPU cannot do (f32 <-> i64/u64
// conversion, libm calls), is compiled into a call to a compiler-rt or libm
// routine, and that routine is linked into the ELF as a function with its
// own symbol. This script parses the ELF symbol tables (.symtab and
// .dynsym, with their linked string tables) and fails if any such routine is
// present. It also decodes .ARM.attributes (hard-float ABI, FP architecture)
// and counts VFP instructions in executable sections as a sanity signal.
//
// Why a symbol check is sound here: in a ReleaseFast cart almost all Zig
// functions are inlined into update(), so the symbol table is small (tens of
// entries), but compiler-rt lives in its own compilation unit, so a routine
// the code actually calls cannot be inlined away and keeps its (local)
// symbol, e.g. `__aeabi_dadd` or `compiler_rt.arm.__aeabi_dadd`. Unused
// compiler-rt routines are removed by --gc-sections, so presence means use.
// The check is weak only if the ELF is stripped (no .symtab): the script
// then exits 4 and says so, because it cannot tell soft-float from none.
//
// Exit codes: 0 pass, 1 unreadable or not an ARM ELF32, 2 usage,
//             3 soft-float routine found (or not a hard-float FPU build),
//             4 no symbol table (check cannot be performed).
// No npm dependencies.

import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const quiet = args.includes("--quiet");
const files = args.filter((a) => !a.startsWith("--"));
if (files.length !== 1) {
  console.error("usage: node tools/check_float.mjs <cart.elf> [--quiet]");
  process.exit(2);
}
const path = files[0];
const log = (...m) => {
  if (!quiet) console.log(...m);
};

let buf;
try {
  buf = readFileSync(path);
} catch (e) {
  console.error(`check_float: cannot read ${path}: ${e.message}`);
  process.exit(1);
}

// --- ELF header -----------------------------------------------------------
if (buf.length < 52 || buf.readUInt32BE(0) !== 0x7f454c46) {
  console.error(`check_float: ${path} is not an ELF file`);
  process.exit(1);
}
if (buf[4] !== 1 || buf[5] !== 1) {
  console.error("check_float: expected ELF32 little-endian (ARM cart ELF)");
  process.exit(1);
}
const EM_ARM = 40;
if (buf.readUInt16LE(18) !== EM_ARM) {
  console.error(`check_float: e_machine ${buf.readUInt16LE(18)} is not ARM (40)`);
  process.exit(1);
}
const shoff = buf.readUInt32LE(32);
const shentsize = buf.readUInt16LE(46);
const shnum = buf.readUInt16LE(48);
const shstrndx = buf.readUInt16LE(50);

const sections = [];
for (let i = 0; i < shnum; i++) {
  const o = shoff + i * shentsize;
  sections.push({
    nameOff: buf.readUInt32LE(o),
    type: buf.readUInt32LE(o + 4),
    flags: buf.readUInt32LE(o + 8),
    addr: buf.readUInt32LE(o + 12),
    offset: buf.readUInt32LE(o + 16),
    size: buf.readUInt32LE(o + 20),
    link: buf.readUInt32LE(o + 24),
    entsize: buf.readUInt32LE(o + 36),
  });
}
const cstr = (off) => {
  let end = off;
  while (end < buf.length && buf[end] !== 0) end++;
  return buf.toString("latin1", off, end);
};
const shstr = sections[shstrndx];
for (const s of sections) s.name = shstr ? cstr(shstr.offset + s.nameOff) : "";

const SHT_SYMTAB = 2;
const SHT_NOBITS = 8;
const SHT_DYNSYM = 11;
const SHT_ARM_ATTRIBUTES = 0x70000003;
const SHF_EXECINSTR = 0x4;
const STT_FUNC = 2;

// --- Symbols --------------------------------------------------------------
const symbols = [];
for (const s of sections) {
  if (s.type !== SHT_SYMTAB && s.type !== SHT_DYNSYM) continue;
  const strtab = sections[s.link];
  const n = Math.floor(s.size / (s.entsize || 16));
  for (let i = 1; i < n; i++) {
    const o = s.offset + i * 16;
    const name = cstr(strtab.offset + buf.readUInt32LE(o));
    if (!name) continue;
    const info = buf[o + 12];
    symbols.push({ name, value: buf.readUInt32LE(o + 4), type: info & 0xf, table: s.name });
  }
}

// Soft-float and libm routine names (compiler-rt, libgcc and C libm spellings).
const softFloatPatterns = [
  [/^__aeabi_d/, "AEABI double-precision helper (f64 math)"],
  [/^__aeabi_f/, "AEABI single-precision helper (soft f32, or f32 <-> i64 conversion)"],
  [/^__aeabi_u?[il]2[df]$/, "AEABI int -> float conversion helper"],
  [/^__aeabi_h2f|^__aeabi_f2h|^__aeabi_d2h/, "AEABI half-float helper"],
  [/^__(add|sub|mul|div|neg|pow)[hsdtx]f[23]$/, "compiler-rt float arithmetic"],
  [/^__(extend|trunc)[hsdtx]f[hsdtx]f2$/, "compiler-rt float width conversion"],
  [/^__fix(uns)?[hsdtx]f[sdt]i$/, "compiler-rt float -> int conversion"],
  [/^__float(un)?[sdt]i[hsdtx]f$/, "compiler-rt int -> float conversion"],
  [/^__(eq|ne|lt|le|gt|ge|un|cmp)[hsdtx]f2$/, "compiler-rt float comparison"],
  [/^__(fmin|fmax|fma|sqrt|floor|ceil|trunc|round)[hsdtx]?$/, "compiler-rt float math"],
  [
    /^(sqrt|sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|exp|exp2|expm1|log|log2|log10|log1p|pow|fmod|floor|ceil|round|trunc|fma|fmin|fmax|hypot|ldexp|frexp|modf|cbrt|sincos)(f|l)?$/,
    "libm routine",
  ],
];

function softFloatReason(name) {
  // Zig names compiler-rt locals like "compiler_rt.arm.__aeabi_dadd"; judge
  // those by the last component. Other Zig symbols (e.g. "math.sin_turns")
  // are judged by the full name, so cart functions never false-positive.
  const base = name.startsWith("compiler_rt.") ? name.slice(name.lastIndexOf(".") + 1) : name;
  for (const [re, why] of softFloatPatterns) if (re.test(base)) return why;
  return null;
}

const offenders = new Map();
for (const sym of symbols) {
  const why = softFloatReason(sym.name);
  if (why && !offenders.has(sym.name)) offenders.set(sym.name, why);
}

// --- .ARM.attributes (aeabi, file scope) ----------------------------------
const tagNames = {
  6: "Tag_CPU_arch",
  10: "Tag_FP_arch",
  20: "Tag_ABI_FP_denormal",
  21: "Tag_ABI_FP_exceptions",
  23: "Tag_ABI_FP_number_model",
  27: "Tag_ABI_HardFP_use",
  28: "Tag_ABI_VFP_args",
  36: "Tag_FP_HP_extension",
  38: "Tag_ABI_FP_16bit_format",
};
const vfpTags = new Set([10, 20, 21, 23, 27, 28, 36, 38]);
const fpArchNames = ["none", "VFPv1", "VFPv2", "VFPv3", "VFPv3-D16", "VFPv4", "VFPv4-D16", "FP for ARMv8", "FPv5/FP-D16 for ARMv8"];
const vfpArgsNames = ["base (soft-float ABI, core registers)", "VFP registers (hard-float ABI)", "toolchain-specific", "compatible with both"];
const hardFpUseNames = ["as Tag_FP_arch", "SP only", "DP only", "SP and DP"];

function parseAttributes() {
  const sec = sections.find((s) => s.type === SHT_ARM_ATTRIBUTES);
  if (!sec || buf[sec.offset] !== 0x41) return null;
  const attrs = new Map();
  let p = sec.offset + 1;
  const end = sec.offset + sec.size;
  const uleb = () => {
    let r = 0;
    let shift = 0;
    for (;;) {
      const b = buf[p++];
      r += (b & 0x7f) * 2 ** shift;
      shift += 7;
      if (!(b & 0x80)) return r;
    }
  };
  const str = () => {
    const s = cstr(p);
    p += s.length + 1;
    return s;
  };
  while (p < end) {
    const subStart = p;
    const subLen = buf.readUInt32LE(p);
    p += 4;
    const vendor = str();
    const subEnd = subStart + subLen;
    if (vendor !== "aeabi") {
      p = subEnd;
      continue;
    }
    while (p < subEnd) {
      const scopeStart = p;
      const scope = buf[p++];
      const scopeLen = buf.readUInt32LE(p);
      p += 4;
      const scopeEnd = scopeStart + scopeLen;
      if (scope !== 1) {
        p = scopeEnd; // section/symbol scope: skip
        continue;
      }
      while (p < scopeEnd) {
        const tag = uleb();
        let val;
        if (tag === 4 || tag === 5 || tag === 67 || (tag > 32 && tag % 2 === 1)) val = str();
        else if (tag === 32) {
          val = uleb();
          str();
        } else val = uleb();
        attrs.set(tag, val);
      }
    }
    p = subEnd;
  }
  return attrs;
}
const attrs = parseAttributes();

// --- VFP instruction count (heuristic Thumb-2 decode) ---------------------
// 32-bit Thumb coprocessor instructions have a first halfword 0xEC00-0xEFFF
// (or 0xFC00-0xFFFF) and coprocessor number 10 or 11 (bits 11:8 of the second
// halfword = 0b101x) for VFP. Literal pools can make this over-count a
// little; it is a sanity signal ("the FPU is used"), not a proof.
function countVfp() {
  let count = 0;
  for (const s of sections) {
    if (!(s.flags & SHF_EXECINSTR) || s.type === SHT_NOBITS) continue;
    let p = s.offset;
    const end = s.offset + s.size - 3;
    while (p < end) {
      const hw1 = buf.readUInt16LE(p);
      const top5 = hw1 >>> 11;
      if (top5 === 0b11101 || top5 === 0b11110 || top5 === 0b11111) {
        const hw2 = buf.readUInt16LE(p + 2);
        if ((hw1 & 0xec00) === 0xec00 && ((hw2 >>> 9) & 0x7) === 0b101) count++;
        p += 4;
      } else p += 2;
    }
  }
  return count;
}
const vfpCount = countVfp();

// --- Report ---------------------------------------------------------------
let failed = false;
const funcCount = symbols.filter((s) => s.type === STT_FUNC).length;
log(`check_float: ${path}`);
log(`  symbols: ${symbols.length} (${funcCount} functions) in ${[...new Set(symbols.map((s) => s.table))].join(", ") || "no symbol table"}`);

if (attrs) {
  const vfp = [...attrs.keys()].filter((t) => vfpTags.has(t));
  log(`  .ARM.attributes: ${attrs.size} file-scope tags, ${vfp.length} VFP-related:`);
  for (const t of vfp.sort((a, b) => a - b)) {
    let v = attrs.get(t);
    if (t === 10) v = `${v} (${fpArchNames[v] ?? "?"})`;
    if (t === 28) v = `${v} (${vfpArgsNames[v] ?? "?"})`;
    if (t === 27) v = `${v} (${hardFpUseNames[v] ?? "?"})`;
    log(`    ${tagNames[t]} = ${v}`);
  }
  if ((attrs.get(28) ?? 0) !== 1) {
    console.error("check_float: FAIL: Tag_ABI_VFP_args is not 'VFP registers': not a hard-float (eabihf) build");
    failed = true;
  }
  if ((attrs.get(10) ?? 0) === 0) {
    console.error("check_float: FAIL: Tag_FP_arch is absent/none: built without an FPU");
    failed = true;
  }
} else {
  log("  .ARM.attributes: missing (cannot confirm hard-float ABI)");
}
log(`  VFP instructions in executable sections (heuristic): ${vfpCount}`);

if (offenders.size > 0) {
  console.error(`check_float: FAIL: ${offenders.size} soft-float/libm routine(s) linked into ${path}:`);
  for (const [name, why] of offenders) console.error(`    ${name}  (${why})`);
  console.error("  Something in the cart uses f64 or a float operation the M33 FPU cannot do.");
  console.error("  Find the caller: search the cart for f64, comptime_float reaching runtime, u64/i64 <-> float, std.math.");
  failed = true;
}

if (failed) process.exit(3);

if (symbols.length === 0) {
  console.error(
    "check_float: WEAK: the ELF has no symbol table (stripped?), so soft-float routines cannot be detected by name.\n" +
      "  Build without stripping (the cart build uses -fno-strip) and rerun. Not counted as a pass.",
  );
  process.exit(4);
}

log(`check_float: PASS: no soft-float or libm routines among ${symbols.length} symbols`);
