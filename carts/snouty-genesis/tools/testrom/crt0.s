| Snouty test ROM: vectors, cartridge header, startup (GNU as, m68k ELF).
|
| 0x000 vector table (64 longs), 0x100 the standard Sega header, 0x200 code.
| The header's ROM end (0x1A4) and checksum (0x18E) are left zero here and
| filled in by fixup.py after linking (sum of the big-endian words from 0x200
| to the end of the padded image, modulo 0x10000).

        .section .vectors, "ax"
        .globl  _vectors
_vectors:
        .long   0x00FFFE00              | 0: initial SSP (top of RAM minus 512)
        .long   _start                  | 1: reset PC
        .rept   22
        .long   exc_default             | 2-23: bus/address error, illegal, traps...
        .endr
        .long   exc_default             | 24: spurious interrupt
        .long   exc_default             | 25: level 1
        .long   exc_default             | 26: level 2 (external, pad TH)
        .long   exc_default             | 27: level 3
        .long   hint_isr                | 28: level 4 = VDP H-int
        .long   exc_default             | 29: level 5
        .long   vint_isr                | 30: level 6 = VDP V-int
        .long   exc_default             | 31: level 7
        .rept   32
        .long   exc_default             | 32-63: TRAP #n, reserved
        .endr

        | Cartridge header, 0x100-0x1FF.
        .ascii  "SEGA GENESIS    "      | 0x100 system type (16)
        .ascii  "(C)SNTY 2026.SEP"      | 0x110 copyright (16)
        .ascii  "SNOUTY TEST                                     " | 0x120 domestic (48)
        .ascii  "SNOUTY TEST                                     " | 0x150 overseas (48)
        .ascii  "GM SNOUTY01-00"        | 0x180 product code and version (14)
        .word   0                       | 0x18E checksum (fixup.py)
        .ascii  "J               "      | 0x190 I/O support: 3-button pad (16)
        .long   0x00000000              | 0x1A0 ROM start
        .long   0                       | 0x1A4 ROM end (fixup.py)
        .long   0x00FF0000              | 0x1A8 RAM start
        .long   0x00FFFFFF              | 0x1AC RAM end
        .ascii  "            "          | 0x1B0 no SRAM (12)
        .ascii  "            "          | 0x1BC modem (12)
        .ascii  "                                        " | 0x1C8 memo (40)
        .ascii  "JUE             "      | 0x1F0 region (16)
        .if     . - _vectors - 0x200
        .error  "header does not end at 0x200"
        .endif

        .section .text.start, "ax"
        .globl  _start
_start:
        move.w  #0x2700, %sr            | supervisor, all interrupts masked
        | TMSS: a version register with a non-zero hardware version needs
        | "SEGA" at 0xA14000 before the VDP can be used.
        move.b  0xA10001, %d0
        andi.b  #0x0F, %d0
        beq.s   1f
        move.l  #0x53454741, 0xA14000
1:      lea     0x00FFFE00, %sp
        | .data: copy from ROM (LMA) to RAM.
        lea     _data_load, %a0
        lea     _data_start, %a1
        move.l  #_data_end, %d0
        sub.l   %a1, %d0
        lsr.l   #1, %d0
        bra.s   3f
2:      move.w  (%a0)+, (%a1)+
3:      dbra    %d0, 2b
        | .bss: clear.
        lea     _bss_start, %a1
        move.l  #_bss_end, %d0
        sub.l   %a1, %d0
        lsr.l   #1, %d0
        bra.s   5f
4:      clr.w   (%a1)+
5:      dbra    %d0, 4b
        jsr     main
6:      bra.s   6b

        .text
        | Unused vectors: stop here (a golden test sees the PC parked).
exc_default:
        bra.s   exc_default

hint_isr:
        movem.l %d0-%d1/%a0-%a1, -(%sp)
        jsr     on_hint
        movem.l (%sp)+, %d0-%d1/%a0-%a1
        rte

vint_isr:
        movem.l %d0-%d1/%a0-%a1, -(%sp)
        jsr     on_vint
        movem.l (%sp)+, %d0-%d1/%a0-%a1
        rte

        | The Z80 driver, assembled from z80.s by the Makefile.
        .section .rodata
        .globl  z80_driver, z80_driver_end
        .balign 2
z80_driver:
        .incbin "z80.bin"
z80_driver_end:
        .balign 2

        .section .note.GNU-stack, "", %progbits
