; Voices: monophonic note on/off for the four GB channels, driven by wPatch.
;   CH1/CH2 pulse, CH3 wave (note range is 12 semitones narrower: it plays an
;   octave lower than a pulse at the same period), CH4 noise.
; NoteOn : a = MIDI note, c = channel (0..3)
; NoteOff: c = channel
; VoiceTick: per-frame vibrato for CH1-CH3.
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

; c = channel, de = period: remember it for the vibrato, restart its phase.
StoreBase:
    ld a, c
    add a
    add LOW(wBase)
    ld l, a
    ld h, HIGH(wBase)
    ld [hl], e
    inc l
    ld [hl], d
    ld hl, wVibPh
    call HLplusC
    xor a
    ld [hl], a
    ret

; ---- CH1: duty vol env swt swd sws
VoicePulse1:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    call StoreBase
    ld hl, wPatch
    ld a, [hl+]
    rrca
    rrca                    ; duty -> bits 7-6
    ldh [rNR11], a
    ld a, [hl+]
    swap a                  ; volume -> bits 7-4
    ld b, a
    ld a, [hl+]
    or b                    ; env: bit 3 = direction (1 = up), bits 2-0 = pace
    ldh [rNR12], a
    ld a, [hl+]
    swap a                  ; sweep time -> bits 6-4
    ld b, a
    ld a, [hl+]
    add a
    add a
    add a                   ; sweep direction -> bit 3
    or b
    ld b, a
    ld a, [hl]              ; sweep shift -> bits 2-0
    or b
    ldh [rNR10], a
    ld a, e
    ldh [rNR13], a
    ld a, d
    or $80                  ; trigger
    ldh [rNR14], a
    ret

; ---- CH2: duty vol env
VoicePulse2:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    call StoreBase
    ld hl, wPatch + PATCH_SIZE
    ld a, [hl+]
    rrca
    rrca
    ldh [rNR21], a
    ld a, [hl+]
    swap a
    ld b, a
    ld a, [hl]
    or b
    ldh [rNR22], a
    ld a, e
    ldh [rNR23], a
    ld a, d
    or $80
    ldh [rNR24], a
    ret

; ---- CH3: wave level
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
    call StoreBase
    xor a
    ldh [rNR30], a          ; DAC off while rewriting wave RAM
    call LoadWave
    ld a, $80
    ldh [rNR30], a
    xor a
    ldh [rNR31], a
    ld a, [wPatch + 2 * PATCH_SIZE + 1]
    inc a                   ; level 0/1/2 -> NR32 $20/$40/$60 (100/50/25 %)
    swap a
    add a
    ldh [rNR32], a
    ld a, e
    ldh [rNR33], a
    ld a, d
    or $80
    ldh [rNR34], a
    ret

; Copy preset wave (patch byte 0 of CH3) into wave RAM (CH3 must be stopped).
LoadWave:
    push de
    push bc
    ld a, [wPatch + 2 * PATCH_SIZE]
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

; ---- CH4: width vol env
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
    ld a, [wPatch + 3 * PATCH_SIZE]
    and 1                   ; LFSR width -> bit 3
    add a
    add a
    add a
    or e
    ldh [rNR43], a
    xor a
    ldh [rNR41], a
    ld a, [wPatch + 3 * PATCH_SIZE + 1]
    swap a
    ld b, a
    ld a, [wPatch + 3 * PATCH_SIZE + 2]
    or b
    ldh [rNR42], a
    ld a, $80
    ldh [rNR44], a
    ret

; ---------------------------------------------------------------- vibrato
; Every frame, for each sounding CH1-CH3 note with depth > 0:
;   tri   = triangle(phase) in -8..7
;   m     = |tri| * depth                       (0..56)
;   P     = 2048 - period                       (proportional to 1/frequency)
;   off   = (m * (P >> 4)) >> 7                 (scales with pitch)
;   period' = period +- off  (clamped to 0..2047), written without trigger.
VoiceTick:
    ld c, 0
.loop:
    push bc
    call TickChannel
    pop bc
    inc c
    ld a, c
    cp 3
    jr c, .loop
    ret

TickChannel:                ; c = channel 0..2
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    and a
    ret z
    ld a, c
    add a
    add a
    add a
    add PATCH_VIBD
    add LOW(wPatch)
    ld l, a
    ld h, HIGH(wPatch)
    ld a, [hl+]             ; depth
    and a
    ret z
    ld b, a
    ld a, [hl]              ; speed
    ld d, a
    add a
    add d
    add 3                   ; phase step = speed * 3 + 3
    ld d, a
    ld hl, wVibPh
    call HLplusC
    ld a, [hl]
    add d
    ld [hl], a              ; advance phase
    cp 128
    jr c, .rise
    cpl
.rise:
    srl a
    srl a
    srl a                   ; 0..15
    sub 8                   ; -8..7
    ld d, 0
    bit 7, a
    jr z, .pos
    cpl
    inc a                   ; |tri|
    inc d                   ; negative
.pos:
    ld e, a
    xor a
    inc e
.mul:                       ; a = |tri| * depth (b)
    dec e
    jr z, .mdone
    add b
    jr .mul
.mdone:
    ld [wVibM], a
    ld a, d
    ld [wVibSign], a
    ; de = base period
    ld a, c
    add a
    add LOW(wBase)
    ld l, a
    ld h, HIGH(wBase)
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    ; hl = 2048 - base
    ld hl, 2048
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
    ld a, l                 ; a = (hl >> 4) & $FF
    swap a
    and $0F
    ld b, a
    ld a, h
    swap a
    and $F0
    or b
    ld b, a
    ld a, [wVibM]
    push de
    call Mul8               ; hl = m * (P >> 4)
    add hl, hl
    ld a, h                 ; off = product >> 7
    pop de
    ld b, a
    ld a, [wVibSign]
    and a
    jr nz, .neg
    ld a, e
    add b
    ld e, a
    jr nc, .chkHi
    inc d
.chkHi:
    ld a, d
    cp 8
    jr c, .write
    ld de, $07FF
    jr .write
.neg:
    ld a, e
    sub b
    ld e, a
    jr nc, .write
    dec d
    bit 7, d
    jr z, .write
    ld de, 0
.write:
    ld a, c
    add a
    add LOW(wOut)
    ld l, a
    ld h, HIGH(wOut)
    ld [hl], e
    inc l
    ld [hl], d
    ld a, c
    and a
    jr z, .ch1
    dec a
    jr z, .ch2
    ld a, e
    ldh [rNR33], a
    ld a, d
    ldh [rNR34], a          ; bit 7 clear: no retrigger
    ret
.ch1:
    ld a, e
    ldh [rNR13], a
    ld a, d
    ldh [rNR14], a
    ret
.ch2:
    ld a, e
    ldh [rNR23], a
    ld a, d
    ldh [rNR24], a
    ret

; hl = a * b (unsigned). Clobbers a, b, d, e.
Mul8:
    ld hl, 0
    ld d, 0
    ld e, b
.l: and a
    ret z
    srl a
    jr nc, .skip
    add hl, de
.skip:
    sla e
    rl d
    jr .l

; ---------------------------------------------------------------- data
DefaultPatch:
    db 2, 15, 0, 0, 0, 0, 0, 3      ; CH1
    db 2, 15, 0, 0, 0, 0, 0, 3      ; CH2
    db 0, 0, 0, 0, 0, 0, 0, 3       ; CH3
    db 0, 15, 2, 0, 0, 0, 0, 0      ; CH4

DirtyBits:  db %00000001, %00000010, %00000100, %00001000
            db %00010000, %00100000, %01000000, %10000000

INCLUDE "notetable.inc"
INCLUDE "waves.inc"
