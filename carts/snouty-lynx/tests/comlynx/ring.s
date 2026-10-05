; ComLynx token ring for the virtual-bus tests (tests/comlynx_unit.zig,
; docs/COMLYNX.md section 5). Built with cc65's Lynx target by
; tools/make_comlynx_roms.sh into ring.lnx (committed next to this file).
;
; Every console runs this ROM. The joystick byte held from power on says
; who it is: bits 0-2 = its id, bits 4-7 = the ring size N, bit 3 =
; polling (else the receiver runs on the serial interrupt).
;
; A message is two bytes, $A0 | destination id and a sequence number.
; Every console hears every message (its own too: one wire), parses the
; same stream and counts it; the destination then sends the next message
; to (id + 1) mod N with the sequence plus one. Console 0 starts the ring
; after 30 frames and regenerates the token when the wire has been quiet
; for WATCHDOG ticks of timer 6 (16.4 ms each), as a game's master would.
;
; Results (the test reads console RAM):
;   $1F00 $C3 once running      $1F01 id      $1F02 N     $1F03 polling
;   $1F04/5 messages parsed     $1F06/7 tokens held by this console
;   $1F08 sequence/format errors $1F09 watchdog regenerations
;   $1F0A receive errors seen (PARERR, FRAMERR, OVERRUN)
;   $1F0B last sequence number   $1F0C timer-6 ticks after start (wraps)

        .setcpu "65C02"
        .include "lynx.inc"
        .export _main
        .forceimport __STARTUP__
        .interruptor rxirq

RES      = $1F00
WATCHDOG = 3

        .zeropage
id:     .res 1
nn:     .res 1
poll:   .res 1
head:   .res 1          ; ring buffer write index (IRQ or poll)
tail:   .res 1          ; read index
state:  .res 1          ; 0 = expect header, else destination + 1
dst:    .res 1
quiet:  .res 1          ; timer 6 ticks since the last message
tmp:    .res 1

        .bss
ring:   .res 256

        .code
_main:
        sei
        ; Wait for the joystick (the harness holds it from power on).
        ldx     #10
@settle:
        jsr     wait_frame
        dex
        bne     @settle
        lda     JOYSTICK
        and     #$07
        sta     id
        sta     RES+1
        lda     JOYSTICK
        lsr
        lsr
        lsr
        lsr
        sta     nn
        sta     RES+2
        lda     JOYSTICK
        and     #$08
        sta     poll
        sta     RES+3
        stz     head
        stz     tail
        stz     state
        stz     quiet
        ldx     #$0D
@clr:   stz     RES+4,x
        dex
        bpl     @clr
        ; 62,500 baud: timer 4 backup 1 on the 1 us clock.
        lda     #1
        sta     TIM4BKUP
        sta     TIM4CNT
        lda     #%00011000      ; reload, count, 1 us
        sta     TIM4CTLA
        ; Timer 6: 64 us clock, backup 255: a tick every 16.4 ms.
        lda     #255
        sta     TIM6BKUP
        sta     TIM6CNT
        lda     #%00011110      ; reload, count, 64 us
        sta     TIM6CTLA
        ; UART: open collector, 9th bit = mark, errors cleared.
        lda     #%00001101
        sta     SERCTL
        lda     SERDAT
        lda     poll
        bne     @nopirq
        lda     #%01000101      ; RXINTEN, open collector, mark
        sta     SERCTL
        cli
@nopirq:
        lda     #$C3
        sta     RES
        ; Console 0 starts the ring after 30 frames.
        lda     id
        bne     loop
        ldx     #30
@wait:  jsr     wait_frame
        dex
        bne     @wait
        lda     #1
        ldx     #0
        jsr     send

loop:
        lda     poll
        beq     @nopoll
        jsr     poll_rx
@nopoll:
        ; Timer 6 tick: count frames and quiet time.
        lda     TIM6CTLB
        and     #$08
        beq     @parse
        lda     #%01011110      ; reset done (a level), reload, count, 64 us
        sta     TIM6CTLA
        lda     #%00011110
        sta     TIM6CTLA
        inc     RES+$0C
        inc     quiet
        lda     id
        bne     @parse
        lda     quiet
        cmp     #WATCHDOG
        bcc     @parse
        ; The ring went quiet: regenerate the token.
        inc     RES+9
        stz     quiet
        stz     state
        lda     RES+$0B
        inc
        tax
        lda     #1
        jsr     send
@parse:
        ldx     tail
        cpx     head
        beq     loop
        lda     ring,x
        inc     tail
        jsr     byte_in
        bra     loop

; One byte of the stream.
byte_in:
        ldx     state
        bne     @seq
        tax
        and     #$F8
        cmp     #$A0
        bne     @bad
        txa
        and     #$07
        inc
        sta     state
        rts
@seq:
        dex
        stx     dst
        stz     state
        sta     tmp
        stz     quiet
        inc     RES+4
        bne     @c
        inc     RES+5
@c:
        ; The sequence must follow the last one (after the first).
        lda     RES+4
        cmp     #1
        bne     @chk
        lda     RES+5
        beq     @ok
@chk:   lda     RES+$0B
        inc
        cmp     tmp
        beq     @ok
        inc     RES+8
@ok:    lda     tmp
        sta     RES+$0B
        lda     dst
        cmp     id
        bne     @done
        inc     RES+6
        bne     @c2
        inc     RES+7
@c2:    lda     id
        inc
        cmp     nn
        bcc     @to
        lda     #0
@to:    ldx     tmp
        inx
        jsr     send
@done:  rts
@bad:   inc     RES+8
        rts

; Send message (destination A, sequence X).
send:
        ora     #$A0
        jsr     put
        txa
put:
        pha
@w:     lda     poll
        beq     @nop
        phx
        jsr     poll_rx
        plx
@nop:   lda     SERCTL
        and     #$80            ; TXRDY
        beq     @w
        pla
        sta     SERDAT
        rts

; Polling receiver: move a ready byte into the ring.
poll_rx:
        lda     SERCTL
        tay
        and     #$1C
        beq     @noerr
        inc     RES+$0A
        lda     #%00001101
        sta     SERCTL
@noerr: tya
        and     #$40            ; RXRDY
        beq     @none
        lda     SERDAT
        ldx     head
        sta     ring,x
        inc     head
@none:  rts

; Interrupt receiver (cc65's IRQ stub clears INTSET after this).
rxirq:
        lda     INTSET
        and     #$10
        beq     @no
@more:  lda     SERCTL
        tay
        and     #$1C
        beq     @noerr
        inc     RES+$0A
        lda     #%01001101
        sta     SERCTL
@noerr: tya
        and     #$40
        beq     @out
        lda     SERDAT
        ldx     head
        sta     ring,x
        inc     head
        bra     @more
@out:   sec
        rts
@no:    clc
        rts

; Wait for the next vertical blank (timer 2 reload).
wait_frame:
@a:     lda     TIM2CNT
        beq     @a
@b:     lda     TIM2CNT
        bne     @b
@c:     lda     TIM2CNT
        beq     @c
        rts
