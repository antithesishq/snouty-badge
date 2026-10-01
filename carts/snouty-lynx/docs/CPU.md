# CPU (core/cpu65.zig)

Rockwell 65C02 as in the Lynx (SPEC.md sections 3, 16, 20): the full 65C02
set plus RMB/SMB/BBR/BBS, no WAI/STP, no NMI. `Cpu(Bus)` makes exactly the
bus cycles of the SingleStepTests `rockwell65c02/v1` `cycles` lists, one
`fetch`/`read`/`dummy`/`write` call per cycle. `fetch` is used only for
opcode and operand bytes at PC; `read` for data (operand memory, pointers,
stack pulls, vectors); `dummy` for internal cycles (every dummy read the
suite lists: implied instructions' second cycle, indexing, the RMW re-read,
the decimal extra cycle, the JSR/RTS/RTI/pull stack and PC dummies, the IRQ
sequence's two opcode cycles). The test bus logs all three as "read".

`dummy` exists for the Lynx's page mode (lynx-tests lynx-page-mode.md,
measured on hardware): internal cycles cost a full 5-tick cycle but
neither contribute to nor break the sequential instruction stream, while
data reads and writes break it. A taken branch's extra cycle is a `read`
(breaks the stream) when the target differs from PC and a `dummy` for a
zero displacement, as the guide's branch table says. On the Lynx, `dummy`
touches no device (a dummy cycle at RCART0 does not advance the cart
counter; Gearlynx agrees).

## Verification (M1, 2026-10-01)

- `zig build test-lynx -Dtest-filter=cpu65`: the 24 fetched files
  (240,000 cases) pass, compared on registers, every `final.ram` entry, the
  cycle count and each cycle's address, value and kind. About 1 s on the VM
  (ReleaseSafe; most of it JSON parsing).
- `tools/fetch_test_roms.sh --all` with `LYNX_SST_CMD` running the test
  binary on each batch: 256 pass, 0 fail, 0 missing (2,560,000 cases,
  about 1 min including the download). The wrapper used:

      #!/bin/sh
      LYNX_SST_DIR="$1" /path/to/snouty-lynx-tests 2>&1 | grep -E '^(PASS|FAIL) '

  (the test binary from `zig build test-lynx -Dtest-filter=cpu65`, path in
  `.zig-cache/o/*/snouty-lynx-tests`).
- The IRQ sequence has its own unit test (the suite has no interrupts).

Bus calls per instruction (the tick-model sanity check), averaged over the
cases: the 24-file subset 2.20 fetch, 1.95 read, 0.50 write; all 256
opcodes (uniform mix, not a game's) 2.03 fetch, 1.50 read, 0.27 write.

## Speed (M4)

`exec` (the opcode switch, ~30 KB of Thumb) is `inline` and exists once:
the console's `run_cpu` (core/lynx.zig, out of line) holds the run loop
with the switch in it, and `step_one` goes through it too, so no call or
register save is paid per instruction. The CPU's bus there is a
`bus.Port`, a local of the loop holding the console pointer and copies
of the clock, the page-mode fetch cost, `fetch_ticks` and the run's end
bound, written back around every high-page access (the only calls that
read or change them); the console's own `fetch`/`read`/`write` remain
for the tests. Per instruction the loop does one compare against a
per-run PC bound (0 while the IRQ line is high, else the mapped ROM's
$FE00 or $FFFF), counts the instruction in a register (added to
`instr_count` at the end of the run) and sets P's bits 4-5 once per run
(`normalize_p`: no instruction clears them). `step` and `step_inline`
(the SingleStepTests path) keep the per-instruction forms. Calibrated
badge-bench, raycast m2_play: ~64 cycles of `run_cpu` per Lynx
instruction (M3: ~123 with `exec` out of line). For a build with room
to spare (XIP), `noinline` -> `inline` on `run_cpu` is the one-keyword
switch, but it would only save the call per Mikey event.

## P

`Regs.p` always holds bits 4 and 5 set (`step` forces them; the Lynx's
run loop sets them once per run). The suite
stores bit 5 set and bit 4 as its generator left it: clear in most files,
set throughout `0f`, `f1`, `ff`; PLP and RTI results have it clear. The test
compares `p | 0x30` on both sides. Pushes: PHP and BRK push P | $30, the IRQ
sequence pushes P with bit 4 clear and bit 5 set.

## Suite cycle patterns worth knowing

- Decimal ADC/SBC take one extra cycle: a re-read of the effective address
  for memory operands. For immediate operands the suite reads **$0059**
  (ADC #) and **$0000** (SBC #); a generator artefact, matched as is (a
  RAM read either way: same tick cost, no side effect).
- JMP (abs) (6 cycles): pointer low, then the NMOS-style page-wrapped high
  byte address as a dummy read, then the real high byte (ptr + 1).
- JMP (abs,X): the dummy cycle re-reads the operand's low byte address.
- abs,X/abs,Y reads with a page crossing, and every abs,X/abs,Y store and
  INC/DEC abs,X: the dummy read is the operand's high byte address (PC - 1).
  ASL/LSR/ROL/ROR abs,X are 6 cycles without a crossing, 7 with.
- (zp),Y: the crossing (always for STA) dummy re-reads the zp operand byte.
- zp,X / zp,Y / (zp,X): a dummy read of the unindexed zero-page address.
- RMW (incl. TSB/TRB, RMB/SMB): read, re-read, write.
- Branches taken: a dummy read of PC; with a page crossing another read of
  the target's low byte in the old page. BBR/BBS: zp read twice, the
  offset, then taken = read PC, crossing = read PC again (5/6/7 cycles).
- RTS: dummy PC, dummy stack, pull lo, pull hi, read of the pulled address.
- Undefined opcodes: `$x3`, `$xB` 1 byte 1 cycle, except `$CB` (1 byte, 2
  cycles, reads PC) and `$DB` (2 bytes, 4 cycles, zp,X pattern); `$x2` 2/2;
  `$44` 2/3 (zp read); `$54`/`$D4`/`$F4` 2/4 (zp,X); `$5C`/`$DC`/`$FC` 3/4
  (the 4th re-reads the operand's high byte address). Felix has `$5C` at 8
  cycles; not measured on hardware (SPEC.md 20 still open).

## IRQ

Taken in `step` when `bus.irq_line()` and the previous instruction's poll
allowed it (`Cpu.irq_ok`, `takes_irq(line)`), instead of an instruction
(not counted in `instr_count`): `dummy(pc)` twice (the discarded opcode
and its repeat, as BRK's first two cycles but PC not advanced), push PCH,
PCL, P (bit 4 clear, bit 5 set), set I, clear D, PC from
`read($FFFE)`/`read($FFFF)`: 7 cycles.

The poll is the 6502's: each instruction polls with the I flag as its last
cycle sees it, so CLI, SEI and PLP take effect one instruction late (after
CLI the next instruction runs before the IRQ; an IRQ can still come right
after SEI, pushing P with I set), RTI at once. The line itself is sampled
at the start of `step`. The Lynx's 1-cycle NOPs (`$x3`, `$xB`, every
opcode with low bits 011) do not poll: an IRQ cannot be taken right after
one, only after the next real instruction (lynx-tests cpu "UNDC NOP IRQ":
CLI, 160 of them, a sentinel INX; the IRQ returns to the byte after INX).
A boot-set CPU starts with `irq_ok` false (one instruction before an IRQ).

## Lynx NOPs $CB and $DB

The suite's Rockwell model has `$CB` 1 byte 2 cycles and `$DB` 2 bytes 4
cycles (zp,X). On the Lynx both are 1-byte 1-cycle NOPs like the rest of
the `$xB` column: the same cpu test runs five of each between CLI and the
sentinel and the IRQ still comes after the sentinel, which a polling 2- or
4-cycle instruction would not allow (Felix and Gearlynx have them at 1/1).
`Cpu(Bus)` takes the Lynx behaviour when `Bus` declares
`cpu_lynx_nops = true` (`Lynx` does); the SingleStepTests bus does not, so
`cb.json` still passes as the suite has it. `$5C` stays 3/4 (Felix and
Gearlynx: 8 cycles; no hardware measurement yet).
