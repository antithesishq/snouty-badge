#!/usr/bin/env node
// Determinism check: runs the same scripted game twice and compares exports.
//
//   node tools/check_determinism.mjs <cart.wasm> --script FILE.json --frames N
//                                    [--exports debug_state_hash,debug_tick]
//                                    [--rewind-at T --rewind-for N]   (M4)
//
// Runs tools/preview.mjs twice (--quiet --dump-exports) into a temp dir,
// reads both frames.json "exports" and asserts every listed export equal.
// Prints one line: PASS/FAIL, then NAME=VALUE (NAME=RUN1|RUN2 when they differ).
// Exit codes: 0 match, 2 usage (or --rewind-* before M4), 3 mismatch or a
// failed run.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const preview = path.join(here, "preview.mjs");

function usage(msg) {
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
if (rewindAt !== null || rewindFor !== null) {
    console.error("check_determinism: --rewind-at/--rewind-for: not implemented until M4");
    process.exit(2);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "determinism-"));
const results = [];
try {
    for (const run of ["run1", "run2"]) {
        const out = path.join(tmp, run);
        const r = spawnSync(process.execPath, [preview, wasm, "--quiet", "--out", out, "--script", script,
            "--frames", String(frames), "--dump-exports", exportsList.join(",")], { encoding: "utf8" });
        if (r.status !== 0) {
            process.stderr.write(r.stderr || "");
            console.error(`check_determinism: ${run}: preview.mjs exited ${r.status ?? r.signal}`);
            process.exit(r.status === 2 ? 2 : 3);
        }
        results.push(JSON.parse(fs.readFileSync(path.join(out, "frames.json"), "utf8")).exports);
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

const [a, b] = results;
const bad = exportsList.filter((n) => a[n] !== b[n]);
const cells = exportsList.map((n) => a[n] === b[n] ? `${n}=${a[n]}` : `${n}=${a[n]}|${b[n]}`);
console.log(`check_determinism: ${bad.length ? "FAIL" : "PASS"} ${path.basename(script)} x${frames}: ${cells.join(" ")}` +
    (bad.length ? ` (differ: ${bad.join(", ")})` : ""));
process.exit(bad.length ? 3 : 0);
