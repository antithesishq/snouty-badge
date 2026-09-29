# Snouty Genesis: ROMs and test data

M0 Track R research (2026-09-29). Section 1 lists the ROMs in `roms/`,
section 2 the homebrew candidates with their licences and verdicts, and
section 3 the 68000 SingleStepTests facts for M1 (Track A's harness).

## 1. Shipped ROMs (`roms/`)

| File | Size | What | Licence |
|------|-----:|------|---------|
| `snouty-test.bin` | 16384 | original test ROM, built from `tools/testrom/` (`build.sh --check` reproduces it) | MIT, `LICENSE-snouty-test` |
| `miniplanets.bin` | 524288 | *Miniplanets REMIX Ver (REV04)* by Sik (Javier Degirolmo), 2022 | zlib, `LICENSE-miniplanets` (verbatim) |

`snouty-test.bin` is the golden-test and badge-bench target and the
default `-Dmd-rom`; `tools/testrom/README.md` describes it frame by frame.

`miniplanets.bin` is the one clean third-party ROM found: a complete
platformer on small 3D-looking planets, with an attract mode. It is a
realistic stress target (not embeddable in the badge build at 512 KB;
drive or simulator only): Sik's Sona Z80 driver (FM, PSG and two mixed
PCM channels on the DAC), no SRAM, no mapper, no SVP. The header checksum
(`5873`) is correct and the game verifies it at boot, so the core must
never patch the ROM. Source:
`https://raw.githubusercontent.com/sikthehedgehog/miniplanets/0ac9c395289cc5d0837c96d45e61a27300e8eebc/Miniplanets%20REMIX%20Ver%20(REV04).bin`
(the repository HEAD on 2026-09-29), sha256
`e8aee1b9fedca87b638a7624709d7f6e1a2aff8a5222083346d1cd63963acbe7`. The
repository's only licence file, `LICENSE.txt` (sha256 `1587f53d...fe5`),
is zlib with no exclusions for data; the Sona driver is also zlib
(`https://www.arkagis.com/sona`: "Sona is released under the zlib
license"); fonts, graphics and music in the repository are Sik's own. The
itch page (`https://sik.itch.io/miniplanets`) says "Code license: zlib
License". zlib asks that the notice stay with source distributions, which
`LICENSE-miniplanets` does, and that the origin is not misrepresented: the
cart credits Sik wherever it names the game.

`tools/romcheck.py` on both (abridged):

```
roms/snouty-test.bin
  size       16384 bytes (16 KB)
  format     raw binary
  system     "SEGA GENESIS"   copyright "(C)SNTY 2026.SEP"
  domestic   "SNOUTY TEST"
  product    "GM SNOUTY01-00"   region "JUE"
  checksum   declared BCA2, computed BCA2 over 0x200-EOF (match)
  SRAM       none declared
  Z80        BUSREQ A11100 x3, RESET A11200 x3, A00000 x1 (1 as lea/movea base)
  verdict    OK: drive (romfs) and -Dmd-rom
roms/miniplanets.bin
  size       524288 bytes (512 KB)
  system     "SEGA MEGA DRIVE"   copyright "(C) SIK 2022.JUN"
  domestic   "MINIPLANETS"
  product    "GM SIK-MINI-04"   region "JUE"
  checksum   declared 5873, computed 5873 over 0x200-EOF (match)
  SRAM       none declared
  Z80        BUSREQ A11100 x29, RESET A11200 x3, A00000 x2 (2 as lea/movea base)
  verdict    OK: drive (romfs) and -Dmd-rom
```

Git: `*.bin` is too broad to ignore globally, so SPEC section 11 ignores
`.bin`/`.md` ROMs under `carts/snouty-genesis/roms/` and `tests/roms/` by
path (Track S owns those lines). The root `.gitignore` exceptions
(`!carts/snouty-genesis/roms/snouty-test.bin`,
`!carts/snouty-genesis/roms/miniplanets.bin`) must stay below them.

## 2. Homebrew candidates

Acceptable: MIT, BSD, zlib, CC BY, CC BY-SA, CC0 or public domain, with the
licence text covering the ROM (code and assets). Not acceptable: "freeware"
without a licence text, NC, or third-party assets under other terms. Sizes
against SPEC section 13: warn above 840 KB, refuse above 990 KB.

| Candidate | URL | Size (bytes) | Raw, size OK | Licence location: verbatim line | Verdict |
|-----------|-----|-----:|------|------------------|---------|
| Miniplanets REMIX REV04 (Sik) | github.com/sikthehedgehog/miniplanets | 524,288 | raw, OK | repo `LICENSE.txt`: "Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:" (zlib, "©2016, 2022 Javier Degirolmo") | **clean, committed** |
| Dragon's Castle prototype (Sik) | github.com/sikthehedgehog/dragon, `witch.bin` | 175,708 | raw, OK | repo `LICENSE`: zlib, "©2016 Javier Degirolmo", same permission text | clean, runner-up: unfinished prototype; Echo Z80 driver; header checksum 0 and ROM end 3FFFFF (romcheck notes, not failures) |
| Gentris (SGDK sample) | github.com/Stephane-D/SGDK, `sample/game/gentris/out/release/rom.bin` (HEAD 2eac605) | 131,072 | raw, OK | SGDK `license.txt`: "MIT License - Copyright (c) 2025 Stephane Dallongeville"; the sample's source says all graphics and sound are generated procedurally | clean licence, not chosen: Tetris clone (trade-dress risk), PSG only, header declares 32 KB SRAM (romcheck refuses: over 16 KB), checksum wrong (unchecked by the game) |
| SGDK platformer / sonic samples | same repository, `sample/game/platformer`, `sample/sonic` | 131,072 | raw, OK | MIT for the code, but `res/sound/sonic2Emerald.vgm` and the Sonic art are Sega's | not clean (Sega assets) |
| Project MD (Sik) | github.com/sikthehedgehog/projectmd, `bin/projmd-20120429.bin` | 786,432 | raw, OK (under 840 KB) | `minimal/LICENSE`: "GNU GENERAL PUBLIC LICENSE Version 3" | clean with a caveat (GPLv3 needs a source offer; only a "minimal source release" exists, without the data sources); not chosen |
| 5 Stars (Sik) | github.com/sikthehedgehog/5stars, `5stars.bin` | 10,967 | raw, OK | `LICENSE`: GPLv3 | clean with a caveat (GPL); the README says it is "far from complete" and crashes |
| Retail Clerk '89 (Hugues Johnson) | huguesjohnson.com/rc89/builds/RetailClerk89_2020-09-01.zip | 2,097,153 | raw, **over 990 KB** | zip `LICENSE`: "MIT License for original source code", "CC BY-SA 4.0 for original characters, story, art, & other non-code things", "3rd party assets (code, graphics, music) are under their respective licenses" (some are informal "Feel free to use" grants) | not usable: 2 MB with data at fixed 1 MB+ addresses, needs SRAM; licence mostly clean with caveats |
| Retail Clerk '90 | huguesjohnson.com/rc90/releases/RetailClerk90-V10-June2024.zip | 2,097,153 | raw, over 990 KB | `CREDITS`: "Almost all of the graphics are based off the following licensed tilesets" (LimeZu, GameDev Market) | not clean (commercial tilesets), too big |
| Speedrun Tower (Hugues Johnson) | huguesjohnson.com/speedrun-tower/builds/SpeedrunTower.zip | 2,097,153 | raw, over 990 KB | `LICENSE`: "The final compiled games is CC BY-SA 4.0", tilesets are paid LimeZu packs ("please purchase a license") | not clean, too big |
| Mojon Twins (Mega Cheril Perils etc.) | mojontwins.com/licencia-mt/ | not fetched | - | "toda nuestra obra creativa, incluido el código fuente está bajo licencia Creative Commons 3.0 «by-nc-ca»" (CC BY-NC-SA 3.0) | not clean (non-commercial) |
| PDRoms Genesis section, Sega-16 and Plutiedev listings, itch.io Genesis tags | pdroms.de, sega-16.com, plutiedev.com, itch.io | - | - | listings are "freeware" without licence texts; no permissively licensed title with a released ROM found beyond the rows above | nothing usable |

Also available if a smaller Sik title is wanted: the non-REMIX Miniplanets
(256 KB, Echo driver, same zlib licence) at repository commit
`104ce86dc5ebc57909019908b2002e872314941e`; not downloaded.

## 3. 68000 SingleStepTests (M1 Track A)

- Repository: `https://github.com/SingleStepTests/680x0`, directory
  `68000/v1` (Tom Harte's tests; `TomHarte/ProcessorTests` is archived and
  points there). Raw files:
  `https://raw.githubusercontent.com/SingleStepTests/680x0/main/68000/v1/<NAME>.json.gz`.
- Licence: **none**. The repository has no LICENSE file (checked
  `LICENSE`, `LICENSE.md`, `LICENSE.txt`: 404; no licence on the repository
  page; the archived ProcessorTests has none either), unlike
  `SingleStepTests/z80` (MIT). The files are fetched for local testing only
  and never committed; `tests/roms/` is gitignored (Track S).
- Files: 124 `.json.gz` files, one per operation and size (`ADD.b`,
  `ADD.w`, `ADD.l`, `Bcc`, `MOVEM.l`, `MOVEtoSR`, ...), 202,591,395 bytes
  (193 MB) gzipped; about 6x that as JSON (NOP: 1.2 MB gz, 7.1 MB JSON).
  Each holds 8,065 tests (the README: "slightly more than 8,000 tests per
  operation ... a little over 1,000,000 tests").
- `tools/fetch_test_roms.sh` (default): 36 files, one or two per family
  (ABCD, ADD.b/.l, ADDA.w, ADDX.l, AND.w, ANDItoSR, ASL.l, ASR.w, BCHG,
  BTST, Bcc, BSR, CHK, CLR.b, CMP.w, DBcc, DIVS, DIVU, EORItoCCR, EXG,
  EXT.l, JSR, LEA, LINK, LSR.b, MOVE.b/.w/.l/.q, MOVEA.l, MOVEM.l, MOVEP.w,
  MOVEtoSR, MULS, ROXL.w), 60,556,258 bytes (57 MB) into
  `tests/roms/68000/`; downloaded and in place on the VM on 2026-09-29.
  `--all` fetches all 124 (193 MB), `--dry-run` only lists and sizes. The
  files stay gzipped; the harness decompresses them
  (`std.compress.flate` in Zig's std, gzip container).
- Schema: each file is a JSON array of tests. One test:
  - `name`: string, for humans, e.g. `"e3ae [LSL.l D1, D6] 5"` (opcode
    word in hex first).
  - `initial`, `final`: objects with `d0`-`d7`, `a0`-`a6`, `usp`, `ssp`,
    `sr`, `pc` (numbers), `prefetch` (two 16-bit words, the prefetch
    queue, first fetched first) and `ram` (list of `[address, byte]` pairs; the
    initial ones are loaded before the test, the final ones checked
    after). Addresses are 24-bit (up to `FFFFFF` seen). A7 is `usp` or
    `ssp` by the S bit of `sr`. In the README sample (`LSL.l`, 1 word)
    initial `pc` = `0C00` with `prefetch` = the words at `0C00` (the
    opcode `E3AE`) and `0C02`, and the one bus read is at `0C04`; final
    `pc` = `0C02` with `prefetch` = the words at `0C02` and `0C04`. So
    `pc` is the address of the instruction whose opcode is `prefetch[0]`,
    and the core must seed its prefetch queue from `prefetch`, not by
    reading memory (the words at `pc` are not in `ram`).
  - `length`: total cycles of the instruction (e.g. MOVE.w 4-68, DIVS
    16-162, MOVEM.l 8-132).
  - `transactions`: bus activity in order: `["n", cycles]` idle, or
    `[kind, cycles, fc, address, size, value]` with `kind` `"r"` read,
    `"w"` write, `"t"` TAS read-modify-write, `fc` the function code
    (bit 0 FC0 ... bit 2 FC2), `size` `".b"` or `".w"`, `value` the data
    bus value (for bytes, 0-255 from the active half; UDS/LDS from
    address bit 0). Cycle counts assume immediate DTACK.
  - About 1% of tests start with odd address registers or in user mode,
    so address errors and privilege violations appear (the README: 99% of
    pointers word-aligned, 99% supervisor mode).
  - Checking `final` registers, `ram` and `length` is the M1 bar (SPEC
    section 4); the transaction list is available for bus-order checks.

## 4. Local ROMs on the VM

`ls ~/*.gen ~/*.bin ~/*.md ~/*.smd` finds nothing on 2026-09-29: no
commercial ROM to run romcheck on. Adrian's ROMs stay on his machine and
the badge drive; never commit them.
