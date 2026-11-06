; ChromaSynth -- Game Boy / Chromatic synthesizer ROM
; Milestone 0: boot, pulse-1 voice, joypad play, wired MIDI in via link port.
INCLUDE "hardware.inc"

; ---------------------------------------------------------------- vectors
SECTION "VBlank vector", ROM0[$40]
    jp VBlankISR

SECTION "Serial vector", ROM0[$58]
    jp SerialISR

SECTION "Header", ROM0[$100]
    nop
    jp EntryPoint
    ds $150 - @, 0          ; rgbfix fills in the header

; ---------------------------------------------------------------- RAM
SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

SECTION "Vars", WRAM0
wRingHead:      db          ; written by ISR
wRingTail:      db          ; written by main loop
wVBlank:        db
wMidiStatus:    db          ; running status (0 = none)
wMidiCount:     db          ; data bytes received for current message
wMidiData1:     db
wCurNote:       db          ; currently sounding note (monophonic)
wJoy:           db
wJoyPrev:       db
wBootTimer:     db          ; frames left of the boot beep
wJoyNote:       db          ; note played by the A button

; ---------------------------------------------------------------- code
SECTION "Main", ROM0[$150]

EntryPoint:
    di
    ld sp, $FFFE

    ; --- LCD off (only legal during VBlank), clear tile 0 + BG map
.waitVBlank:
    ldh a, [rLY]
    cp 144
    jr c, .waitVBlank
    xor a
    ldh [rLCDC], a

    ld hl, _VRAM
    ld bc, 16
    call MemClear
    ld hl, _SCRN0
    ld bc, 32 * 32
    call MemClear

    ld a, %11100100
    ldh [rBGP], a
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_BLK01
    ldh [rLCDC], a

    ; --- clear RAM state
    ld hl, wRingHead
    ld bc, wJoyNote - wRingHead + 1
    call MemClear
    ld a, 60                ; middle-ish C for the A button
    ld [wJoyNote], a

    ; --- APU on, all channels to both speakers, max master volume
    ld a, $80
    ldh [rNR52], a
    ld a, $FF
    ldh [rNR51], a
    ld a, $77
    ldh [rNR50], a

    ; --- link port as MIDI input: external clock (we are the slave)
    xor a
    ldh [rSB], a
    ld a, $80
    ldh [rSC], a

    xor a
    ldh [rIF], a
    ld a, IEF_VBLANK | IEF_SERIAL
    ldh [rIE], a
    ei

    ; boot beep (C5, ~0.5 s): proves audio works independent of input
    ld a, 30
    ld [wBootTimer], a
    ld a, 72
    call NoteOn

MainLoop:
    halt
    nop
    call DrainMidi
    ld a, [wVBlank]
    and a
    jr z, MainLoop
    xor a
    ld [wVBlank], a
    ld a, [wBootTimer]
    and a
    jr z, .noBoot
    dec a
    ld [wBootTimer], a
    call z, NoteOff
.noBoot:
    call ReadJoy
    call HandleJoy
    jr MainLoop

; ---------------------------------------------------------------- ISRs
VBlankISR:
    push af
    ld a, 1
    ld [wVBlank], a
    pop af
    reti

; Serial transfer complete: push received byte into the ring, re-arm.
SerialISR:
    push af
    push hl
    ld a, [wRingHead]
    ld l, a
    ld h, HIGH(wRing)
    ldh a, [rSB]
    ld [hl], a
    inc l                   ; 256-byte aligned ring: wraps naturally
    ld a, l
    ld [wRingHead], a
    xor a
    ldh [rSB], a            ; byte returned to the master (MIDI out later)
    ld a, $80
    ldh [rSC], a
    pop hl
    pop af
    reti

; ---------------------------------------------------------------- MIDI
DrainMidi:
    ld a, [wRingTail]
    ld c, a
.loop:
    ld a, [wRingHead]
    cp c
    jr z, .done
    ld h, HIGH(wRing)
    ld l, c
    ld b, [hl]
    inc c
    push bc
    call MidiByte
    pop bc
    jr .loop
.done:
    ld a, c
    ld [wRingTail], a
    ret

; b = received byte
MidiByte:
    bit 7, b
    jr z, .data
    ld a, b
    cp $F8
    ret nc                  ; realtime (clock/start/stop): TODO sync
    ld [wMidiStatus], a
    xor a
    ld [wMidiCount], a
    ret
.data:
    ld a, [wMidiStatus]
    and a
    ret z
    and $F0
    cp $C0
    ret z                   ; program change / channel pressure: 1 data byte, ignored
    cp $D0
    ret z
    ld a, [wMidiCount]
    and a
    jr nz, .second
    ld a, b
    ld [wMidiData1], a
    ld a, 1
    ld [wMidiCount], a
    ret
.second:
    xor a
    ld [wMidiCount], a      ; keep running status
    ld a, [wMidiStatus]
    and $F0
    cp $90
    jr z, .noteOn
    cp $80
    ret nz
.noteOff:
    ld a, [wMidiData1]
    ld b, a
    ld a, [wCurNote]
    cp b
    ret nz                  ; mono: ignore release of an older note
    jp NoteOff
.noteOn:
    ld a, b                 ; velocity
    and a
    jr z, .noteOff          ; vel 0 == note off
    ld a, [wMidiData1]
    jp NoteOn

; ---------------------------------------------------------------- joypad
ReadJoy:
    ld a, [wJoy]
    ld [wJoyPrev], a
    ld a, $20               ; select d-pad
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    and $0F
    swap a
    ld b, a
    ld a, $10               ; select buttons
    ldh [rP1], a
    REPT 6
        ldh a, [rP1]
    ENDR
    and $0F
    or b
    cpl
    ld [wJoy], a
    ld a, $30
    ldh [rP1], a
    ret

; Standalone play: A = gate, left/right = +-1 semitone, up/down = +-octave.
HandleJoy:
    ld a, [wJoyPrev]
    cpl
    ld b, a
    ld a, [wJoy]
    and b
    ld d, a                 ; d = newly pressed
    ld a, [wJoyNote]
    bit PADB_RIGHT, d
    jr z, .l
    inc a
.l: bit PADB_LEFT, d
    jr z, .u
    dec a
.u: bit PADB_UP, d
    jr z, .dn
    add 12
.dn:bit PADB_DOWN, d
    jr z, .store
    sub 12
.store:
    cp NOTE_MIN
    jr c, .keep
    cp NOTE_MAX + 1
    jr nc, .keep
    ld [wJoyNote], a
.keep:
    bit PADB_A, d
    jr z, .release
    ld a, [wJoyNote]
    jp NoteOn
.release:
    ld a, [wJoyPrev]
    bit PADB_A, a
    ret z
    ld a, [wJoy]
    bit PADB_A, a
    ret nz
    ld a, [wJoyNote]
    ld b, a
    ld a, [wCurNote]
    cp b
    ret nz
    jp NoteOff

; ---------------------------------------------------------------- voice
; a = MIDI note. Out-of-range notes are ignored. Trashes af, de, hl.
NoteOn:
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    ld [wCurNote], a
    sub NOTE_MIN
    ld l, a
    ld h, 0
    add hl, hl
    ld de, NoteTable
    add hl, de
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    xor a
    ldh [rNR10], a          ; no sweep
    ld a, %10000000         ; duty 50%
    ldh [rNR11], a
    ld a, $F0               ; volume 15, no envelope
    ldh [rNR12], a
    ld a, e
    ldh [rNR13], a
    ld a, d
    or $80                  ; trigger
    ldh [rNR14], a
    ret

NoteOff:
    xor a
    ld [wCurNote], a
    ldh [rNR12], a          ; DAC off
    ret

; hl = dest, bc = length (>0)
MemClear:
    xor a
.l: ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, 0
    jr nz, .l
    ret

INCLUDE "notetable.inc"
