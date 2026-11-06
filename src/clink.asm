; Cable-less link to the Chromatic's built-in ESP32. Design: docs/CHROMATIC_LINK.md.
;
;   down (ESP32 -> ROM): the ESP32 presses virtual buttons that the FPGA ORs into the
;     joypad. This works on the keyboard screen only (SCREEN_KBD): there ReadJoy (joy.asm) reads
;     the pad as data and hides it from the UI. (The FPGA cancels UP+DOWN and LEFT+RIGHT, so a
;     symbol never has an opposite pair.)
;       phase A: UP held; phase B: DOWN held; data bits 3..0 = LEFT, START, B, A
;     Consecutive symbols alternate phase A/B; a repeat of the last phase is the same
;     symbol still being held and is ignored.
;     Packets: the first symbol's bit 3 is the type; checks are sums mod 15.
;       play packet    (4 symbols): on(1) note(7) vel(3) check(4), mono, on the selected channel
;       general packet (8 symbols): 3 MIDI bytes (24 bits), 3 zero bits, check(4); HELLO = $FE $43 $53
;   up (ROM -> ESP32): on the keyboard screen 4 bytes are written to OBJ palette 1 colours 1-2
;     (the FPGA hands them to the MCU as "game palette data"): status, data1, data2 and a
;     header len(2) seq(3) ack(1) nack(1). Pad MIDI messages shorter than 3 bytes with $FE.
;     Not linked yet: the beacon {$F4, 0, 0, len 3} (the ESP32 may send HELLO). Leaving the keyboard
;     screen unlinks and writes {$F5, 0, 0, len 3} once (the ESP32 must stop). See docs/BLE_MIDI.md.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF CL_TIMEOUT  EQU 250     ; frames (4.2 s, the counter is 8 bits) without a valid packet before the link is dropped
DEF CL_PKT_IDLE EQU 30      ; frames without a symbol before a half packet is dropped
DEF CL_HELLO0   EQU $FE
DEF CL_HELLO1   EQU $43
DEF CL_HELLO2   EQU $53
DEF CL_BEACON_KBD  EQU $F4  ; slot {B0 = $F4, len 3}: on the keyboard screen, not linked
DEF CL_BEACON_LEFT EQU $F5  ; slot {B0 = $F5, len 3}: just left the keyboard screen (written once)

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
    ; first symbol of a packet: bit 3 = type
    xor a
    ld [wClNack], a
    bit 3, c
    jr z, .type
    inc a
.type:
    ld [wClMode], a
    ld a, c
    and 7
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
    cp 4
    ret c
    jr ClPlayDone
.general:
    ld a, b
    cp 8
    ret c
    jr ClGenDone

; A packet failed its check (a real button was pressed while it was sent, or a symbol
; was lost): tell the ESP32, which then sends it again.
ClBad:
    ld a, 1
    ld [wClNack], a
    ret

; Play packet: wClBuf = s0' (on, note 6..5), s1 (note 4..1), s2 (note 0, vel 2..0), s3 = check.
ClPlayDone:
    xor a
    ld [wClN], a
    ld a, [wClBuf]
    ld b, a                 ; b = s0'
    ld a, [wClBuf + 1]
    ld c, a                 ; c = s1
    ld a, [wClBuf + 2]
    ld e, a                 ; e = s2
    add a, b
    add a, c                ; at most 7 + 15 + 15
.mod15:
    cp 15
    jr c, .modDone
    sub 15
    jr .mod15
.modDone:
    ld h, a                 ; mod 15, so that every single changed bit (1, 2, 4, 8) changes the check
    ld a, [wClBuf + 3]
    cp h
    jp nz, ClBad
    ld a, [wClLinked]
    and a
    ret z                   ; play packets count only after HELLO
    xor a
    ld [wClTimer], a
    ld a, b                 ; note = (s0' & 3) << 5 | s1 << 1 | s2 >> 3
    and 3
    swap a
    add a, a
    ld h, a
    ld a, c
    add a, a
    or h
    ld h, a
    ld a, e
    srl a
    srl a
    srl a
    or h
    ld d, a                 ; d = note
    ld a, e                 ; velocity = s2 & 7 -> (vel << 4) | 8: ScaleVol turns that into volume 2..16 of 16
    and 7
    swap a
    or 8
    ld e, a
    bit 2, b
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

; \1 = the first of three symbols (3+4+4 bits, the byte is bits 7..5, 4..1, 0 of them), \2 = destination
MACRO PackByte
    ld a, [\1]
    and 7
    swap a
    add a, a
    ld b, a
    ld a, [\1 + 1]
    add a, a
    or b
    ld b, a
    ld a, [\1 + 2]
    srl a
    srl a
    srl a
    or b
    ld [\2], a
ENDM

; General packet: wClBuf = s0' (3 bits), s1..s6 (4 bits each), s7 = check.
;   B0 = s0' << 5 | s1 << 1 | s2 >> 3, B1 = (s2 & 7) << 5 | s3 << 1 | s4 >> 3,
;   B2 = (s4 & 7) << 5 | s5 << 1 | s6 >> 3; s6 & 7 must be 0.
ClGenDone:
    xor a
    ld [wClN], a
    ld hl, wClBuf
    ld b, 7
.sum:
    add a, [hl]
    inc hl
    dec b
    jr nz, .sum
.mod15:
    cp 15
    jr c, .modDone
    sub 15
    jr .mod15
.modDone:
    cp [hl]
    jp nz, ClBad
    ld a, [wClBuf + 6]
    and 7
    jp nz, ClBad
    PackByte wClBuf, wClMsg
    PackByte wClBuf + 2, wClMsg + 1
    PackByte wClBuf + 4, wClMsg + 2
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
    ldh a, [rLY]
    cp 144
    ret c                   ; not in VBlank (the frame ran late): try again next frame
    cp 152
    ret nc
    ld a, [wScreen]
    cp SCREEN_KBD
    jr z, .kbd
    ; Not on the keyboard screen. Leaving it unlinks (the ESP32 must stop sending symbols: here they
    ; would be real button presses) and owes one end beacon, $F5, so that the ESP32 learns it.
    ld a, [wClLinked]
    and a
    jr z, .away
    xor a
    ld [wClLinked], a
    ld [wClN], a
    ld [wClHave], a
    inc a
    ld [wClBeacon], a
.away:
    ld a, [wClBeacon]
    and a
    ret z
    xor a
    ld [wClBeacon], a
    ld b, CL_BEACON_LEFT
    jr .beacon
.kbd:
    ld a, 1
    ld [wClBeacon], a
    ld a, [wClLinked]
    and a
    jr nz, .linked
    ld b, CL_BEACON_KBD     ; on the keyboard screen, not linked: tell the ESP32 it may send HELLO
.beacon:
    ld a, b
    ld [wClSlot], a
    xor a
    ld [wClSlot + 1], a
    ld [wClSlot + 2], a
    ld a, 3 << 5            ; len = 3
    ld [wClSlot + 3], a
    xor a
    ld [wClLen], a          ; the message length that persists must not outlive the beacon: a linked slot
    jp .write               ; with the old length 3 and this $F4 in B0 would look like a beacon
.linked:
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
.write:
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
