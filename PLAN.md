# Plan: one repository for every Snouty cart

Started 2026-09-27. This repository (GitHub `antithesishq/snouty-badge`)
began as the running/jumping Snouty cart. Adrian asked for it to become the
general repository for all of the SYCL Badge V2 carts plus the benchmark
tool. Work happens on the `monorepo` branch; `main` on GitHub stays as it was
until Adrian has reviewed.

## Status

- M1 (this plan): built 2026-09-27 on branch `monorepo`, awaiting Adrian's
  review; not pushed. Verified: every cart's uf2 and wasm code is identical
  to the pre-move build of its old repo (the only two differing bytes are
  the ELF header's section-table offset, which also differs between two
  clean builds of the same old repo); `zig build test`, `zig build
  check-float`, badge-bench `tests/test_reflections.sh` (24 reference frames
  exact), snouty-bugs and snoutenstein `tools/check.sh`, snouty-maze
  `check_golden.mjs`, one headless preview per cart and a fresh
  `git clone --recursive` + `zig build -Dcart=snouty-run` all pass.
  Judgment calls to confirm: `snouty-art/` folded in too (its scripts write
  into the carts' assets); `carts/snouty-boy/roms/2048.gb` committed as the
  fallback ROM; the running cart's directory is `carts/snouty-run`.
- M2: one shared `tools/` (2026-09-27, done). The shared `preview.mjs`
  writes byte-identical frames for all six carts (18 frames compared against
  the old per-cart tools), and every gate passes with it: bugs and
  snoutenstein `check.sh`, maze `check_golden.mjs`, snoutenstein
  determinism, `zig build check-float`.
- M3: done 2026-09-27 apart from hardware. XIP builds for every cart;
  badge-bench loads an XIP ELF at its flash load addresses and starts it
  through the vector table (`--flash-cycles N`, default 0). snouty-boy under
  the same scripted input in both modes: identical frame PNGs (so the
  `.data` copy and `.bss` clear are right), per-frame cycles within 3
  instructions (the start/update forwarding in `build/xip/entry.zig`),
  start-up 1.03 ms in XIP mode versus 0.21 ms in RAM mode (the cart clears
  its own 165 KB `.bss`, by words). `tests/test_reflections.sh` still exact.
  Numbers below. Hardware questions open.

  | cart | RAM uf2 blocks | XIP uf2 blocks | XIP flash use | .bss (RAM) |
  |---|---|---|---|---|
  | snouty | 601 | 599 | 153,344 | 48 |
  | snouty-bugs | 294 | 224 | 57,344 | 17,560 |
  | snoutenstein | 421 | 354 | 90,624 | 16,872 |
  | snouty-reflections | 383 | 382 | 97,792 | 40 |
  | snouty-boy | 968 | 322 | 82,432 | 165,304 |
  | snouty-maze | 481 | 249 | 63,744 | 59,296 |

  A UF2 block carries 256 bytes; the RAM image also ships its zero-filled
  `.bss`, which is why snouty-boy's RAM cart is three times the XIP one on
  the cart store. Every XIP image has its vector table at the flash origin
  (SP `0x20080000`, reset in flash with the Thumb bit) and every block inside
  the flash window (`tools/uf2_info.py`). Code and data sizes per mode are
  within a few hundred bytes of each other, as expected.

## Layout after M1

```
snouty-badge/                  the repository (a GitHub rename to e.g.
│                              snouty-carts is Adrian's call; nothing depends on it)
├── PLAN.md                    this file
├── README.md                  index of carts and tools, how to build
├── CLAUDE.md                  shared hardware, cart API and build notes
├── docs/RUNNING.md            shared: prerequisites, checkout, build, simulator, flash
├── build.zig, build.zig.zon   ONE Zig package; `zig build` builds every cart,
│                              `zig build -Dcart=snouty-bugs` one of them
├── build/common.zig           the per-cart build hook signature and shared options
├── src/os/system/tracy_protocol.zig -> ../../../sycl-badge/...  (one symlink,
│                              add_os_cart resolves it against the root package)
├── sycl-badge/                git submodule, upstream SDK pinned at a6ce19f
│                              (the commit every cart was built against)
├── carts/
│   ├── snouty-run/            was ../snouty-badge (binary name stays `snouty`)
│   ├── snouty-bugs/
│   ├── snoutenstein/
│   ├── snouty-reflections/
│   ├── snouty-boy/
│   └── snouty-maze/           each: cart/, assets/, tools/, docs/, PLAN.md,
│                              SPEC.md, CLAUDE.md, build.zig (a module with
│                              `pub fn add(...)`, no build.zig.zon)
├── badge-bench/               was ../badge-bench (emulated cycle benchmark)
└── snouty-art/                was ../snouty-art (code-driven sprite pipeline;
                               folded in because its scripts write into the
                               carts' assets and the carts' scripts read from it)
```

Build outputs land in the root `zig-out/`: `zig-out/firmware/<cart>.uf2`,
`.elf` and `zig-out/bin/<cart>.wasm`, the same file names as before.

## Decisions

- **History is kept.** Each sibling repo is imported with `git filter-repo
  --to-subdirectory-filter` so `git log carts/snouty-bugs/...` shows its
  whole history, then merged with `--allow-unrelated-histories`. Tags are
  renamed `<repo>/<tag>` (`snouty-bugs/m5`, `snouty-maze/m3`) because
  `m1`..`m3` exist in several repos. This repo's own tags (`v1.0.0`..`v3.0.0`)
  are untouched and still check out the old root layout; its history is not
  rewritten, so nothing is force-pushed.
- **One Zig package, not six.** Each cart's `build.zig` becomes a module
  exposing `pub fn add(b, sycl_badge_dep, opts)`; the root `build.zig` calls
  them. This shares `zig-pkg/` (137 MB per cart before), the SDK path
  dependency and the tracy symlink. `add_os_cart` is already called once per
  cart in upstream's own showcase build, so multiple calls per builder are fine.
  Build options that two carts declared (`-Ddebug_overlay`, `test`,
  `check-float`) are declared once at the root and passed down; `zig build
  test` runs every cart's host tests, `zig build check-float` every cart's
  float check. `-Dcart=a,b` limits a build to some carts.
- **SDK as a submodule**, pinned at the commit used so far. Upstream `main`
  has moved on (97c093e); updating is a deliberate, separate change.
- **snouty-boy's default ROM** stays `tests/roms/dmg-acid2.gb`, but when that
  file is absent (fresh clone, fetch script not run) the build prints a note
  and embeds the committed `roms/2048.gb` instead of failing the whole tree.
- **badge-bench** resolves `carts/<elf>.toml` script paths against the cart
  root derived from the ELF path, which is now the repository root; the toml
  files gain the `carts/<name>/` prefix.
- The old sibling repos under `/home/exedev` are left untouched until Adrian
  accepts this branch; then they can be deleted.

## Work breakdown (all done in M1)

1. Move this repo's files into `carts/snouty-run/`, commit with this plan.
2. Import the seven sibling repos with rewritten paths and tags.
3. Root `build.zig` + `build.zig.zon` + `build/common.zig`; convert the six
   cart build files; one root symlink; submodule.
4. Repoint scripts (`serve-cart.mjs` defaults, `check.sh`, `check_*.mjs`,
   `tools/emu`, `build_maze.py`, `install_badge.py`, badge-bench tomls and
   `test_reflections.sh`) and docs (per-cart RUNNING.md and CLAUDE.md, the
   badge-bench README) to the new layout.
5. Root README, CLAUDE.md, docs/RUNNING.md, .gitignore.

## Verification

- `zig build` at the root produces every cart; `sha256sum` of each
  `zig-out/firmware/*.uf2` and `zig-out/bin/*.wasm` compared with the
  pre-move builds of every sibling repo at HEAD (recorded before step 1).
- `zig build test` (snouty-boy core tests, snouty-maze host tests) and
  `zig build check-float` pass.
- `badge-bench/tests/test_reflections.sh` reproduces the m1.1 numbers from
  the new ELF path; `badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf`
  picks up `carts/snouty-bugs.toml` and its script.
- One headless preview per cart via its `tools/preview.mjs` from the root.
- A fresh `git clone --recursive` of the branch builds.

## M2: shared tools

The six `preview.mjs` copies form a tree: snouty-run (base) -> snouty-reflections
and snoutenstein (+ `--script`, `--dump-exports`, `--expect`, `--quiet`) ->
snouty-bugs and snouty-boy (+ `--at`, `--call-at`) and snouty-maze (+ `--call`,
`--pose`). Every option set is a superset of its parent, so one file with the
union of snouty-bugs and snouty-maze serves every cart unchanged. The six
`serve-cart.mjs` differ only in the default wasm name; `make_gif.py` is
identical everywhere; the two `check_float.mjs` differ in a usage comment.

- `tools/preview.mjs`: snouty-bugs' file plus snouty-maze's `--call` and
  `--pose`. Same exit codes, same `frames.json` (with the union of fields).
- `tools/serve-cart.mjs`: defaults to the cart of the directory it is run
  from (`carts/<cart>/` -> `zig-out/bin/<binary>.wasm`, snouty-run -> snouty);
  `--cart NAME` or a wasm path override it.
- `tools/make_gif.py`, `tools/check_float.mjs`: moved.
- `tools/uf2_info.py` (new, for M3): block count, address ranges, flash vs RAM.
- Per-cart copies deleted. Callers repointed: `check.sh` (bugs, snoutenstein),
  `check_determinism.mjs`, `check_cycle.mjs`, `check_golden.mjs`, the root
  `build.zig` check-float step, and the docs (`node ../../tools/preview.mjs`
  from a cart directory).
- Stays per cart: `prepare_assets.py` (the drawings are the cart), the maze
  and reflections checkers, snoutenstein's determinism check, `tools/emu`.
- Verification: every existing gate passes with the shared tool (bugs and
  snoutenstein `check.sh`, maze `check_golden.mjs`, snoutenstein determinism),
  and for each cart a preview run with the old per-cart tool and with the
  shared tool writes byte-identical PNGs and the same export values.

## M3: XIP carts

Background is in the SDK, not written down there: `sycl-badge/src/cart/cart_xip.ld`
links code and read-only data into the 256 KB flash window `0x101C0000..0x10200000`
with `.data` at RAM addresses loaded from flash, and leaves the whole 307 KB cart
RAM window for `.data`/`.bss`. The OS loader routes UF2 blocks by target
address, erases and programs the flash window, refuses a UF2 that mixes flash
and RAM blocks, and on launch reads `[SP, entry]` from the vector table at the
start of the window, sets VTOR and jumps. Unlike the RAM path it does not enable
the FPU or the cycle counter or mask interrupts before jumping, and nothing
copies `.data` or clears `.bss`: the cart must. Upstream's
`platform_cart_xip.zig` is dead code that would not link (its microzig startup
exports `_start`, and the RAM platform that `api.zig` hardcodes exports another).

Design, without patching the submodule:

- `build/os_cart.zig`: our `add(b, sycl_badge_dep, .{ name, optimize,
  root_source_file, custom_builder, mode })`. `mode = .ram` calls upstream's
  `add_os_cart` unchanged. `mode = .xip` mirrors it with the firmware root
  set to `build/xip/entry.zig`, the linker script `cart_xip.ld`, the artifact
  named `<binary>-xip` (so `zig-out/firmware/<binary>-xip.uf2` sits next to
  the RAM one) and the same custom builder applied to the user cart module.
  The wasm is built once, from the user module, whichever modes are on.
- `build/xip/entry.zig`: a two-entry vector table in `.microzig_flash_start`
  (`__stack_top__`, reset handler) and the reset handler: mask interrupts,
  enable the FPU (CPACR, FPCCR) and DWT_CYCCNT, copy `.data` from its flash
  load address, zero `.bss`, then call the RAM platform's `_start`, which is
  the usual start/update/present loop. No microzig startup, so no duplicate
  symbol; the cart source is untouched and still calls `export_start_code()`
  (its 12-byte descriptor lands in an orphan section, harmless).
- Root option `-Dcart-mode=ram|xip|both`, default `ram`. Passed to every
  cart through `common.Options`.
- badge-bench: map the flash window, load segments by their load address,
  and when a segment lives in flash start from the vector table instead of
  `_start` with SP from it too; `describe_addr` names flash; a
  `--flash-cycles N` knob adds N cycles per instruction fetched from flash
  (default 0, to be calibrated against the OS overlay's XIP hit rate on
  hardware). Frame boundaries still come from the `_start` loop.
- Verification without hardware (done, see Status): build snouty-boy in both modes;
  `readelf -l` shows text at the flash origin and `.data` with a RAM address
  and a flash load address; `tools/uf2_info.py` shows every block inside
  the flash window (what the loader requires); the XIP ELF runs under
  badge-bench with the same scripted input as the RAM ELF and writes the
  same frame PNGs, which proves the `.data` copy and `.bss` clear; sizes
  per mode recorded here. The hardware questions (does today's menu accept
  an XIP UF2, erase time per launch, XIP cache hit rate, ms per frame RAM
  vs XIP) stay open for Adrian's badge session.
