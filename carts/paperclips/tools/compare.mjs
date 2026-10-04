// compare.mjs: diffs the oracle's two sides, the original JS
// (tools/js_oracle.mjs) and the Zig port (tools/oracle_runner.zig), run on
// the same action script.
//
//   node compare.mjs JS_OUT.json ZIG_OUT.json [--fields FILE] [--max N]
//                    [--rel X] [--all] [--quiet]
//
// Per checkpoint (same ms on both sides):
//   - every field of tools/oracle/fields.txt (JS name -> Zig snake_case
//     path, or the explicit "= zig_name"; "= -" fields are JS only):
//     exact when both values are integers (flags, counts, levels) or
//     strings, else relative 1e-12 (--rel); a field marked "~ reason" is
//     noisy and gets 1e-6;
//   - the active project list (display order), every project's flag and
//     uses, the disabled state of the active projects' buttons;
//   - buttons' disabled state and panels' visibility, for the ids the Zig
//     side models (g.disabled by Btn name, g.panels by element id);
//   - the number of console messages so far.
// Then the message texts in order and which actions applied.
//
// Prints the first diverging checkpoint (ms, every differing value there,
// up to --max) and the first message difference; exits 1 on any mismatch,
// 2 on a usage or format error. --all reports every diverging checkpoint's
// first field instead of stopping at the first one. With no arguments at
// all it runs the whole suite (tools/oracle/run.sh).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadFields, snake } from "./js_oracle.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const args = { fields: path.join(HERE, "oracle/fields.txt"), max: 40, rel: 1e-12, noisyRel: 1e-6, all: false, quiet: false };
const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--fields") args.fields = process.argv[++i];
  else if (a === "--max") args.max = Number(process.argv[++i]);
  else if (a === "--rel") args.rel = Number(process.argv[++i]);
  else if (a === "--all") args.all = true;
  else if (a === "--quiet") args.quiet = true;
  else pos.push(a);
}
if (pos.length === 0 && process.argv.length === 2) {
  // No arguments (tools/check.sh's oracle step): the whole suite.
  const { spawnSync } = await import("node:child_process");
  const r = spawnSync("bash", [path.join(HERE, "oracle/run.sh")], { stdio: "inherit" });
  process.exit(r.status === null ? 1 : r.status);
}
if (pos.length !== 2) {
  console.error("usage: node compare.mjs JS_OUT.json ZIG_OUT.json [--fields FILE] [--max N] [--rel X] [--all] [--quiet]");
  process.exit(2);
}

const js = JSON.parse(fs.readFileSync(pos[0], "utf8"));
const zig = JSON.parse(fs.readFileSync(pos[1], "utf8"));
const fields = loadFields(args.fields);
const label = js.name || path.basename(pos[0]);

// --------------------------------------------------------------- values ----

function norm(v) {
  if (v === true) return 1;
  if (v === false) return 0;
  if (v === undefined) return null;
  if (typeof v === "string") {
    if (v === "NaN") return NaN;
    if (v === "Infinity") return Infinity;
    if (v === "-Infinity") return -Infinity;
    if (/^-?\d+(\.\d+)?(e[-+]?\d+)?$/i.test(v)) return Number(v);
  }
  return v;
}

// "" when equal, else a short reason.
function diff(a0, b0, rel) {
  const a = norm(a0);
  const b = norm(b0);
  if (typeof a === "number" && typeof b === "number") {
    if (Number.isNaN(a) || Number.isNaN(b)) return Number.isNaN(a) && Number.isNaN(b) ? "" : "nan";
    if (a === b) return "";
    if (Number.isInteger(a) && Number.isInteger(b)) return "int";
    const d = Math.abs(a - b);
    const m = Math.max(Math.abs(a), Math.abs(b));
    if (d <= rel * m) return "";
    return `rel ${(d / m).toExponential(2)}`;
  }
  if (a === b) return "";
  return "value";
}

function lookup(obj, p) {
  let cur = obj;
  for (const tok of p.match(/[A-Za-z_][A-Za-z0-9_]*|\[\d+\]/g)) {
    if (cur === null || cur === undefined) return undefined;
    cur = tok[0] === "[" ? cur[Number(tok.slice(1, -1))] : cur[tok];
  }
  return cur;
}

const show = (v) => (typeof v === "string" ? JSON.stringify(v) : String(v));

// JS element id -> Zig name: btnHarvesterx10 -> btn_harvester_x10,
// btnQcompute -> btn_qcompute, qChip3 -> q_chip[3].
function zigId(id) {
  return snake(id).replace(/([a-z])x(\d+)$/, "$1_x$2");
}

// The port keeps the time of the last hypnoDroneEvent() instead of the
// overlay's display toggling. longBlink: a 32 ms interval from then; fire
// k (1..119) toggles display starting from "none" (shown on odd k), fire
// 120 hides it for good.
function hypnoShown(t0, ms) {
  if (t0 === null || t0 === undefined) return false;
  const k = Math.floor((ms - t0) / 32);
  return k >= 1 && k <= 119 && k % 2 === 1;
}

// ------------------------------------------------------------- compare ----

const problems = []; // {ms, what, js, zig, why}
const missing = new Set();
let firstBadMs = null;
let nChecked = 0;

function checkCheckpoint(cj, cz) {
  const out = [];
  const add = (what, a, b, why) => out.push({ ms: cj.ms, what, js: a, zig: b, why });
  for (const f of fields) {
    if (f.zig === "-") continue;
    const a = cj.fields[f.js];
    const b = lookup(cz.fields, f.zig);
    if (b === undefined) {
      missing.add(`${f.js} -> ${f.zig}`);
      continue;
    }
    const why = diff(a, b, f.noisy ? args.noisyRel : args.rel);
    if (why) add(f.js, a, b, why);
  }
  if (JSON.stringify(cj.active_projects) !== JSON.stringify(cz.active_projects)) add("active_projects", JSON.stringify(cj.active_projects), JSON.stringify(cz.active_projects), "list");
  for (let i = 0; i < cj.project_flags.length; i++) {
    if (diff(cj.project_flags[i], cz.project_flags[i], 0)) add(`project_flags[${i}]`, cj.project_flags[i], cz.project_flags[i], "int");
    if (diff(cj.project_uses[i], cz.project_uses[i], 0)) add(`project_uses[${i}]`, cj.project_uses[i], cz.project_uses[i], "int");
  }
  for (const i of cj.active_projects) {
    if (cz.project_disabled && diff(cj.project_disabled[i], cz.project_disabled[i], 0)) add(`project_disabled[${i}]`, cj.project_disabled[i], cz.project_disabled[i], "flag");
  }
  if (cz.disabled) {
    for (const [id, v] of Object.entries(cj.disabled)) {
      const z = cz.disabled[zigId(id)];
      if (z === undefined) continue;
      if (diff(v, z, 0)) add(`disabled ${id}`, v, z, "flag");
    }
  }
  const zp = cz.fields.panels;
  if (zp) {
    for (const [id, v] of Object.entries(cj.panels)) {
      let z;
      const q = /^qChip(\d)$/.exec(id);
      if (q) z = zp.q_chip ? zp.q_chip[Number(q[1])] : undefined;
      else if (id === "hypnoDroneEventDiv" && "hypno_event_ms" in cz.fields) z = hypnoShown(cz.fields.hypno_event_ms, cj.ms);
      else z = zp[zigId(id)];
      if (z === undefined) continue;
      if (diff(v, z, 0)) add(`panel ${id}`, v, z, "flag");
    }
  }
  if (cj.msg_count !== cz.msg_count) add("msg_count", cj.msg_count, cz.msg_count, "int");
  return out;
}

if (js.checkpoints.length !== zig.checkpoints.length) {
  console.error(`${label}: checkpoint counts differ: js ${js.checkpoints.length}, zig ${zig.checkpoints.length}`);
}
const n = Math.min(js.checkpoints.length, zig.checkpoints.length);
let prevMs = 0;
for (let i = 0; i < n; i++) {
  const cj = js.checkpoints[i];
  const cz = zig.checkpoints[i];
  if (cj.ms !== cz.ms) {
    console.error(`${label}: checkpoint ${i} at different times: js ${cj.ms}, zig ${cz.ms}`);
    process.exit(2);
  }
  nChecked++;
  const bad = checkCheckpoint(cj, cz);
  if (bad.length) {
    if (firstBadMs === null) {
      firstBadMs = cj.ms;
      problems.push(...bad);
      if (!args.all) break;
    } else {
      problems.push(bad[0]);
    }
  }
  prevMs = cj.ms;
}

// Messages: texts in order (each side's full log).
let msgDiff = null;
{
  const a = js.messages || [];
  const b = zig.messages || [];
  const m = Math.min(a.length, b.length);
  for (let i = 0; i < m; i++) {
    if (a[i] !== b[i]) {
      msgDiff = { i, js: a[i], zig: b[i] };
      break;
    }
  }
  if (!msgDiff && a.length !== b.length) msgDiff = { i: m, js: a[m] ?? "(end)", zig: b[m] ?? "(end)" };
  if (msgDiff && js.message_ms) msgDiff.ms = js.message_ms[msgDiff.i];
}

let actDiff = null;
{
  const a = js.actions || [];
  const b = zig.actions || [];
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      actDiff = { i, js: a[i], zig: b[i] };
      break;
    }
  }
}

// --------------------------------------------------------------- report ----

const ok = firstBadMs === null && !msgDiff && !actDiff && missing.size === 0 && js.checkpoints.length === zig.checkpoints.length;
if (ok) {
  if (!args.quiet) console.log(`${label}: MATCH (${nChecked} checkpoints to ${js.checkpoints.at(-1)?.ms} ms, ${(js.messages || []).length} messages, ${(js.actions || []).length} actions)`);
  process.exit(0);
}
console.log(`${label}: MISMATCH`);
if (missing.size) console.log(`  fields missing on the Zig side: ${[...missing].join(", ")}`);
if (firstBadMs !== null) {
  console.log(`  first divergence at ${firstBadMs} ms (last matching checkpoint ${prevMs} ms):`);
  for (const p of problems.slice(0, args.max)) {
    console.log(`    ${args.all ? `[${p.ms}] ` : ""}${p.what}: js ${show(p.js)} zig ${show(p.zig)} (${p.why})`);
  }
  if (problems.length > args.max) console.log(`    ... ${problems.length - args.max} more`);
}
if (msgDiff) console.log(`  message #${msgDiff.i}${msgDiff.ms !== undefined ? ` (js at ${msgDiff.ms} ms)` : ""}: js ${show(msgDiff.js)} zig ${show(msgDiff.zig)}`);
if (actDiff) console.log(`  action #${actDiff.i} applied: js ${actDiff.js} zig ${actDiff.zig}`);
process.exit(1);
