; Voices: monophonic note on/off for the four GB channels.
;   CH1/CH2 pulse, CH3 wave (note range is 12 semitones narrower: it plays an
;   octave lower than a pulse at the same period), CH4 noise.
; NoteOn : a = MIDI note, c = channel (0..3)
; NoteOff: c = channel
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Voice", ROM0

NoteOn:
    ld b, a
    ld a, c
    and a
    jp z, VoicePulse1
    dec a
    jp z, VoicePulse2
    dec a
    jp z, VoiceWave
    dec a
    jp z, VoiceNoise
    ret

NoteOff:
    ld a, c
    cp NUM_CH
    ret nc
    ld hl, wCurNote
    call HLplusC
    xor a
    ld [hl], a
    call MarkDirty
    ld a, c
    and a
    jr z, .p1
    dec a
    jr z, .p2
    dec a
    jr z, .wave
    xor a
    ldh [rNR42], a          ; DAC off silences the channel
    ret
.p1:
    xor a
    ldh [rNR12], a
    ret
.p2:
    xor a
    ldh [rNR22], a
    ret
.wave:
    xor a
    ldh [rNR30], a
    ret

; ---- helpers
; Record b as the sounding note of channel c and flag its UI row.
SetCur:
    ld hl, wCurNote
    call HLplusC
    ld [hl], b
MarkDirty:                  ; c = channel
    ld hl, DirtyBits
    call HLplusC
    ld a, [hl]
    ld hl, wDirty
    or [hl]
    ld [hl], a
    ret

; b = note -> de = 11-bit period (pulse scale). Clobbers a, hl.
GetPeriod:
    ld a, b
    sub NOTE_MIN
    ld l, a
    ld h, 0
    add hl, hl
    ld de, NoteTable
    add hl, de
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    ret

; ---- CH1
VoicePulse1:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    ld a, [wParam + 0]
    rrca
    rrca                    ; duty -> bits 7-6
    ldh [rNR11], a
    xor a
    ldh [rNR10], a          ; no sweep
    ld a, $F0               ; volume 15, no envelope
    ldh [rNR12], a
    ld a, e
    ldh [rNR13], a
    ld a, d
    or $80                  ; trigger
    ldh [rNR14], a
    ret

; ---- CH2
VoicePulse2:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    ld a, [wParam + 1]
    rrca
    rrca
    ldh [rNR21], a
    ld a, $F0
    ldh [rNR22], a
    ld a, e
    ldh [rNR23], a
    ld a, d
    or $80
    ldh [rNR24], a
    ret

; ---- CH3
VoiceWave:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1 - 12
    ret nc
    call SetCur
    ld a, b
    add 12                  ; shift up an octave to compensate the half-rate channel
    ld b, a
    call GetPeriod
    xor a
    ldh [rNR30], a          ; DAC off while rewriting wave RAM
    call LoadWave
    ld a, $80
    ldh [rNR30], a
    xor a
    ldh [rNR31], a
    ld a, $20               ; output level 100%
    ldh [rNR32], a
    ld a, e
    ldh [rNR33], a
    ld a, d
    or $80
    ldh [rNR34], a
    ret

; Copy preset wave wParam+2 into wave RAM (CH3 must be stopped).
LoadWave:
    push de
    push bc
    ld a, [wParam + 2]
    swap a                  ; * 16 bytes
    ld l, a
    ld h, 0
    ld de, Waves
    add hl, de
    ld de, _AUD3WAVERAM
    ld b, 16
.l: ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .l
    pop bc
    pop de
    ret

; ---- CH4
; Noise pitch: clock shift s = (NOTE_MAX - note) / 6, so higher note = higher rate.
VoiceNoise:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    ld a, NOTE_MAX
    sub b
    ld d, 0
.div:
    cp 6
    jr c, .done
    sub 6
    inc d
    jr .div
.done:
    ld a, d
    swap a                  ; shift -> bits 7-4
    ld e, a
    ld a, [wParam + 3]
    and 1                   ; LFSR width -> bit 3
    add a
    add a
    add a
    or e
    ldh [rNR43], a
    xor a
    ldh [rNR41], a
    ld a, $F2               ; volume 15, decay (percussive)
    ldh [rNR42], a
    ld a, $80
    ldh [rNR44], a
    ret

; ---- params
; c = channel. Cycles the channel's param (duty / duty / wave / lfsr width).
CycleParam:
    ld hl, ParamMax
    call HLplusC
    ld a, [hl]
    ld b, a
    ld hl, wParam
    call HLplusC
    ld a, [hl]
    inc a
    cp b
    jr c, .ok
    xor a
.ok:
    ld [hl], a
    jp MarkDirty

ParamMax:   db 4, 4, WAVE_COUNT, 2
DirtyBits:  db %00000001, %00000010, %00000100, %00001000, %00010000

INCLUDE "notetable.inc"
INCLUDE "waves.inc"
