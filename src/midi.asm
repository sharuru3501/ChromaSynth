; MIDI byte stream parser (note on/off, running status). MIDI ch 1-4 -> CH1-4.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI", ROM0

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
    ld a, b
    ld [wLastRx], a
    ld a, [wDirty]
    or DIRTY_STATUS
    ld [wDirty], a
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
    ld a, [wMidiStatus]
    and $0F
    cp NUM_CH
    ret nc
    ld c, a
    ld hl, wCurNote
    call HLplusC
    ld a, [wMidiData1]
    cp [hl]
    ret nz                  ; mono: ignore release of an older note
    jp NoteOff
.noteOn:
    ld a, b                 ; velocity
    and a
    jr z, .noteOff          ; vel 0 == note off
    ld a, [wMidiStatus]
    and $0F
    cp NUM_CH
    ret nc
    ld c, a
    ld a, [wMidiData1]
    jp NoteOn
