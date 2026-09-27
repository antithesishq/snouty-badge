# Plan: one repository for every Snouty cart

Started 2026-09-27. This repository (GitHub `antithesishq/snouty-badge`)
began as the running/jumping Snouty cart. Adrian asked for it to become the
general repository for all of the SYCL Badge V2 carts plus the benchmark
tool. Work happens on the `monorepo` branch; `main` on GitHub stays as it was
until Adrian has reviewed.

## Status

- M1 (this plan): import every sibling repo with its history, one root
  `zig build` that builds all carts, one pinned SDK checkout, docs and
  scripts repointed, verified against the pre-move binaries. In progress.
- M2 (later): one shared `tools/` (the per-cart `preview.mjs`,
  `serve-cart.mjs`, `make_gif.py` copies have drifted apart), one shared
  CLAUDE.md with the per-cart files trimmed to cart specifics.

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

## Work breakdown

1. Move this repo's files into `carts/snouty-run/`, commit with this plan. (done)
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
