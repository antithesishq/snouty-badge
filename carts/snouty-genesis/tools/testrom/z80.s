; Snouty test ROM: the Z80 sound driver (z80asm 1.8 syntax, Debian package
; `z80asm`; assembled by the Makefile into z80.bin, which crt0.s includes).
;
; Loaded by main.c into Z80 RAM at 0000 while the 68000 holds BUSREQ, then
; started by a RESET pulse. It sets up YM2612 channel 1 (part I, channel
; index 0) as a two-operator FM voice (algorithm 4, operator 1 modulating
; operator 2; operators 3 and 4 muted), keys it on at A4 and then toggles
; between A4 and E5 every 30 V-ints. Interrupt mode 1: the VDP's V-int
; drives INT, the handler at 0038 counts it, and the main loop HALTs between
; interrupts. Driver variables live at 1F00; the stack grows down from 2000.
;
; Note frequencies (YM2612 clock = 68000 clock = 53693175 / 7 Hz):
;   f = fnum * 2^(block-1) * (53693175 / 7) / (144 * 2^20)
;   A4: block 4, fnum 1082 (0x43A) -> 439.73 Hz
;   E5: block 4, fnum 1622 (0x656) -> 659.17 Hz

vcount: equ 0x1f00            ; V-ints since the last toggle
note:   equ 0x1f01            ; 0 = A4, 1 = E5
ym_a0:  equ 0x4000            ; YM2612 part I address / status
ym_d0:  equ 0x4001            ; YM2612 part I data

        org 0
        di                    ; no interrupts until the stack is set
        im 1                  ; INT -> RST 38h
        ld sp, 0x2000         ; top of the 8 KB RAM
        jp start

        defs 0x38 - $         ; pad up to the IM 1 vector

; RST 38h: one V-int.
irq:    push af
        ld a, (vcount)
        inc a
        ld (vcount), a
        pop af
        ei
        reti

start:  xor a
        ld (vcount), a
        ld (note), a
        ld hl, ym_init        ; (register, value) pairs, FF-terminated
init_loop:
        ld a, (hl)
        cp 0xff
        jr z, init_done
        inc hl
        ld c, (hl)
        inc hl
        call ym_write
        jr init_loop
init_done:
        call set_note         ; A4, key on

loop:   ei
        halt                  ; sleep until the next V-int
        ld a, (vcount)
        cp 30
        jr c, loop
        xor a
        ld (vcount), a
        ld a, (note)
        xor 1
        ld (note), a
        ld a, 0x28            ; key off channel 1
        ld c, 0x00
        call ym_write
        call set_note         ; new frequency, key on
        jr loop

; Writes the frequency of (note) to channel 1 (A4 first: the high byte is
; latched until A0 is written), then keys all four operators on.
set_note:
        ld hl, freq_a4
        ld a, (note)
        or a
        jr z, set_note_1
        ld hl, freq_e5
set_note_1:
        ld a, 0xa4
        ld c, (hl)
        call ym_write
        inc hl
        ld a, 0xa0
        ld c, (hl)
        call ym_write
        ld a, 0x28            ; key on: operators 1-4 (F0) of channel 1 (0)
        ld c, 0xf0
        jp ym_write

; A = register, C = value; part I. Waits for the busy flag (status bit 7)
; before the address and before the data write.
ym_write:
        push af
ym_wait1:
        ld a, (ym_a0)
        rlca
        jr c, ym_wait1
        pop af
        ld (ym_a0), a
ym_wait2:
        ld a, (ym_a0)
        rlca
        jr c, ym_wait2
        ld a, c
        ld (ym_d0), a
        ret

;               A4 = block<<3 | fnum>>8, A0 = fnum & FF
freq_a4: defb 0x24, 0x3a     ; block 4, fnum 0x43A
freq_e5: defb 0x26, 0x56     ; block 4, fnum 0x656

; Operator registers of channel 1: +0 operator 1, +4 operator 3,
; +8 operator 2, +C operator 4.
ym_init:
        defb 0x22, 0x00       ; LFO off
        defb 0x27, 0x00       ; channel 3 normal mode, timers off
        defb 0x2b, 0x00       ; DAC off
        defb 0x28, 0x00, 0x28, 0x01, 0x28, 0x02   ; key off channels 1-3
        defb 0x28, 0x04, 0x28, 0x05, 0x28, 0x06   ; key off channels 4-6
        defb 0x30, 0x01, 0x34, 0x01, 0x38, 0x01, 0x3c, 0x01  ; DT 0, MUL 1
        defb 0x40, 0x1c       ; TL op1 (modulator) 28
        defb 0x44, 0x7f       ; TL op3 muted
        defb 0x48, 0x08       ; TL op2 (carrier) 8
        defb 0x4c, 0x7f       ; TL op4 muted
        defb 0x50, 0x1f, 0x54, 0x1f, 0x58, 0x1f, 0x5c, 0x1f  ; RS 0, AR 31
        defb 0x60, 0x00, 0x64, 0x00, 0x68, 0x00, 0x6c, 0x00  ; AM off, D1R 0
        defb 0x70, 0x00, 0x74, 0x00, 0x78, 0x00, 0x7c, 0x00  ; D2R 0
        defb 0x80, 0x0f, 0x84, 0x0f, 0x88, 0x0f, 0x8c, 0x0f  ; SL 0, RR 15
        defb 0x90, 0x00, 0x94, 0x00, 0x98, 0x00, 0x9c, 0x00  ; SSG-EG off
        defb 0xb0, 0x04       ; feedback 0, algorithm 4
        defb 0xb4, 0xc0       ; left + right, AMS 0, FMS 0
        defb 0xff
