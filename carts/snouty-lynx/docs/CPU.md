# CPU (core/cpu65.zig)

Rockwell 65C02 as in the Lynx (SPEC.md sections 3, 16, 20): the full 65C02
set plus RMB/SMB/BBR/BBS, no WAI/STP, no NMI. `Cpu(Bus)` makes exactly the
bus cycles of the SingleStepTests `rockwell65c02/v1` `cycles` lists, one
`fetch`/`read`/`write` call per cycle. `fetch` is used only for opcode and
operand bytes at PC (and the two dummy opcode cycles of the IRQ sequence);
every dummy read, including dummy reads of PC, is a `read`.

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

## P

`Regs.p` always holds bits 4 and 5 set (`step` forces them). The suite
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

Taken in `step` when `bus.irq_line()` and I is clear, instead of an
instruction (not counted in `instr_count`): `fetch(pc)` twice (the
discarded opcode and its repeat, as BRK's first two cycles but PC not
advanced), push PCH, PCL, P (bit 4 clear, bit 5 set), set I, clear D, PC
from `read($FFFE)`/`read($FFFF)`: 7 cycles.
