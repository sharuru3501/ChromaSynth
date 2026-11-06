; Cable-less link to the Chromatic's built-in ESP32. Design: docs/CHROMATIC_LINK.md.
;
;   down (ESP32 -> ROM): the ESP32 presses virtual buttons that the FPGA ORs into the
;     joypad. A frame with UP+DOWN (or LEFT+RIGHT) both pressed cannot come from the
;     real d-pad, so it is a data symbol (ReadJoy finds it, see joy.asm):
;       phase A: UP+DOWN pressed, exactly one of LEFT/RIGHT; data bit 4 = LEFT
;       phase B: LEFT+RIGHT pressed, exactly one of UP/DOWN; data bit 4 = UP
;       data bits 3..0 = START, SELECT, B, A
;     Consecutive symbols alternate phase A/B; a repeat of the last phase is the same
;     symbol still being held and is ignored.
;     Packets: the first symbol's bit 4 is the type.
;       play packet    (3 symbols): on(1) note(7) vel(3) check(3), mono, on the selected channel
;       general packet (6 symbols): 3 MIDI bytes (24 bits) + 5-bit check; HELLO = $FE $43 $53
;   up (ROM -> ESP32): once linked, 4 bytes are written to OBJ palette 1 colours 1-2
;     (the FPGA hands them to the MCU as "game palette data"): status, data1, data2 and a
;     header len(2) seq(3) ack(1) nack(1). Pad MIDI messages shorter than 3 bytes with $FE.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF CL_TIMEOUT  EQU 120     ; frames without a valid packet before the link is dropped
DEF CL_PKT_IDLE EQU 30      ; frames without a symbol before a half packet is dropped
DEF CL_HELLO0   EQU $FE
DEF CL_HELLO1   EQU $43
DEF CL_HELLO2   EQU $53

SECTION "Chromatic link", ROM0

; ---------------------------------------------------------------- down
; Once per frame, right after ReadJoy.
CLinkRx:
    ld a, [wClLinked]
    and a
    jr z, .noLink
    ld a, [wClTimer]
    inc a
    ld [wClTimer], a
    cp CL_TIMEOUT
    jr c, .noLink
    xor a
    ld [wClLinked], a
.noLink:
    ld a, [wClN]
    and a
    jr z, .noIdle
    ld a, [wClIdle]
    inc a
    ld [wClIdle], a
    cp CL_PKT_IDLE
    jr c, .noIdle
    xor a
    ld [wClN], a
.noIdle:
    ld a, [wClHave]
    and a
    ret z
    xor a
    ld [wClHave], a
    ld a, [wClPh]
    ld b, a
    ld a, [wClNextPh]
    cp b
    ret nz                  ; the symbol we already have, still held
    xor 1
    ld [wClNextPh], a
    xor a
    ld [wClIdle], a
    ld a, [wClSym]
    ld c, a                 ; c = the 5 data bits
    ld a, [wClN]
    and a
    jr nz, .more
    ; first symbol of a packet: bit 4 = type
    xor a
    ld [wClNack], a
    bit 4, c
    jr z, .type
    inc a
.type:
    ld [wClMode], a
    ld a, c
    and $0F
    ld [wClBuf], a
    ld a, 1
    ld [wClN], a
    ret
.more:
    ld e, a
    ld d, 0
    ld hl, wClBuf
    add hl, de
    ld [hl], c
    inc a
    ld [wClN], a
    ld b, a
    ld a, [wClMode]
    and a
    jr nz, .general
    ld a, b
    cp 3
    ret c
    jr ClPlayDone
.general:
    ld a, b
    cp 6
    ret c
    jr ClGenDone

; A packet failed its check (a real button was pressed while it was sent, or a symbol
; was lost): tell the ESP32, which then sends it again.
ClBad:
    ld a, 1
    ld [wClNack], a
    ret

; Play packet: wClBuf = s0' (on, note 6..4), s1 (note 3..0, vel 2), s2 (vel 1..0, check 3).
ClPlayDone:
    xor a
    ld [wClN], a
    ld a, [wClBuf + 2]
    ld d, a                 ; d = s2
    srl a
    srl a
    srl a
    ld e, a                 ; e = velocity bits 1..0
    ld a, [wClBuf]
    ld b, a                 ; b = s0'
    ld a, [wClBuf + 1]
    ld c, a                 ; c = s1
    add a, b
    add a, e
    and 7
    ld h, a
    ld a, d
    and 7
    cp h
    jr nz, ClBad
    ld a, [wClLinked]
    and a
    ret z                   ; play packets count only after HELLO
    xor a
    ld [wClTimer], a
    ld a, c                 ; velocity = (s1 bit 0) * 4 + e, 0..7
    and 1
    add a, a
    add a, a
    or e
    swap a
    or 8                    ; -> 8..120: ScaleVol turns that into volume 2..16 of 16
    ld e, a
    ld a, b                 ; note = (s0' & 7) << 4 | s1 >> 1
    and 7
    swap a
    ld h, a
    ld a, c
    srl a
    or h
    ld d, a                 ; d = note
    bit 3, b
    jr z, .off
    ld a, [wSelCh]
    cp NUM_CH
    ret nc
    ld c, a
    ld [wClCh], a
    ld a, e
    ld [wNoteVel], a
    ld a, d
    call NoteOn
    ld a, 127
    ld [wNoteVel], a
    ret
.off:
    ld a, [wClCh]
    cp NUM_CH
    ret nc
    ld c, a
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    cp d
    ret nz                  ; a newer note replaced this one (mono legato): leave it
    jp NoteOff

; General packet: wClBuf = s0' (4 bits), s1..s4 (5 bits each), s5 = check.
ClGenDone:
    xor a
    ld [wClN], a
    ld hl, wClBuf
    ld b, 5
.sum:
    add a, [hl]
    inc hl
    dec b
    jr nz, .sum
    and $1F
    cp [hl]
    jp nz, ClBad
    ; bytes: B0 = s0' << 4 | s1 >> 1, B1 = (s1 & 1) << 7 | s2 << 2 | s3 >> 3,
    ;        B2 = (s3 & 7) << 5 | s4
    ld a, [wClBuf]
    swap a
    ld b, a
    ld a, [wClBuf + 1]
    ld c, a
    srl a
    or b
    ld [wClMsg], a
    ld a, c
    and 1
    rrca
    ld b, a
    ld a, [wClBuf + 2]
    add a, a
    add a, a
    or b
    ld b, a
    ld a, [wClBuf + 3]
    srl a
    srl a
    srl a
    or b
    ld [wClMsg + 1], a
    ld a, [wClBuf + 3]
    and 7
    swap a
    add a, a
    ld b, a
    ld a, [wClBuf + 4]
    or b
    ld [wClMsg + 2], a
    ; HELLO?
    ld a, [wClMsg]
    cp CL_HELLO0
    jr nz, .data
    ld a, [wClMsg + 1]
    cp CL_HELLO1
    jr nz, .data
    ld a, [wClMsg + 2]
    cp CL_HELLO2
    jr nz, .data
    ld a, 1
    ld [wClLinked], a
    xor a
    ld [wClTimer], a
    ret
.data:
    ld a, [wClLinked]
    and a
    ret z
    xor a
    ld [wClTimer], a
    ld a, [wClMsg]
    call ClFeed
    ld a, [wClMsg + 1]
    call ClFeed
    ld a, [wClMsg + 2]
    ; fall through

; a = a MIDI byte that arrived over the link (what DrainMidi does for the cable)
ClFeed:
    ld b, a
    ld [wLastRx], a
    ld a, [wDirty]
    or DIRTY_STATUS
    ld [wDirty], a
    jp MidiByte

; ---------------------------------------------------------------- up
; Once per frame, FIRST thing after the VBlank flag is seen (palette RAM is only
; writable outside PPU mode 3). Writes the slot every frame while linked: the header
; carries the ack for the symbols received. The slot (data AND length) stays the same until
; a new message replaces it; the seq counter tells the reader that this happened.
CLinkUp:
    ld a, [wClLinked]
    and a
    ret z
    ldh a, [rLY]
    cp 144
    ret c                   ; not in VBlank (the frame ran late): try again next frame
    cp 152
    ret nc
    ld e, 0                 ; e = message length (0 = nothing new)
    ld a, [wTxHead]
    ld b, a
    ld a, [wTxTail]
    cp b
    jr z, .compose          ; queue empty
    ld l, a
    ld h, HIGH(wTx)
    ld a, [hl]
    bit 7, a
    jr nz, .status
    inc l                   ; a stray data byte: drop it
    ld a, l
    ld [wTxTail], a
    jr .compose
.status:
    ld d, a                 ; d = status byte
    ld e, 1
    cp $F0
    jr nc, .haveLen         ; system / realtime: 1 byte
    and $F0
    cp $C0
    jr z, .two
    cp $D0
    jr z, .two
    ld e, 3
    jr .haveLen
.two:
    ld e, 2
.haveLen:
    ld a, [wTxHead]
    ld b, a
    ld a, [wTxTail]
    ld c, a
    ld a, b
    sub c                   ; bytes in the queue
    cp e
    jr nc, .take
    ld e, 0                 ; the rest of the message has not been queued yet
    jr .compose
.take:
    ld a, c
    ld l, a
    ld h, HIGH(wTx)
    ld a, d
    ld [wClSlot], a
    inc l
    xor a
    ld [wClSlot + 1], a
    ld [wClSlot + 2], a
    ld a, e
    cp 2
    jr c, .taken
    ld a, [hl]
    and $7F
    ld [wClSlot + 1], a
    inc l
    ld a, e
    cp 3
    jr c, .taken
    ld a, [hl]
    and $7F
    ld [wClSlot + 2], a
    inc l
.taken:
    ld a, l
    ld [wTxTail], a
    ld a, e
    ld [wClLen], a          ; the slot keeps describing this message until the next one
    ld a, [wClSeq]
    inc a
    and 7
    ld [wClSeq], a
.compose:
    ld a, [wClSeq]
    add a, a
    add a, a                ; seq << 2
    ld b, a
    ld a, [wClLen]
    swap a
    add a, a                ; len << 5
    or b
    ld b, a
    ld a, [wClNextPh]
    xor 1                   ; ack = phase of the last accepted symbol
    add a, a
    or b
    ld b, a
    ld a, [wClNack]
    or b
    ld [wClSlot + 3], a
    ld a, $80 | 10          ; OBJ palette 1, colour 1 (byte 10), auto-increment
    ldh [rOCPS], a
    ld a, [wClSlot]
    ldh [rOCPD], a
    ld a, [wClSlot + 1]
    ldh [rOCPD], a
    ld a, [wClSlot + 2]
    ldh [rOCPD], a
    ld a, [wClSlot + 3]
    ldh [rOCPD], a
    ret
