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
    ld hl, wCurNote         ; remember what channel c was playing (for the slide)
    call HLplusC
    ld a, [hl]
    ld [wWasOn], a
    ld a, c
    cp 3
    jr nc, .voice
    add a
    add LOW(wOut)
    ld l, a
    ld h, HIGH(wOut)
    ld a, [hl+]
    ld [wPrevOut], a
    ld a, [hl]
    ld [wPrevOut + 1], a
.voice:
    push bc
    call .dispatch          ; returns de = the period it triggered (CH1-3)
    pop bc
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    cp b
    ret nz                  ; the voice refused the note (out of range)
    ld a, c
    cp 3
    ret nc
    jp EffectsStart
.dispatch:
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

; ---- effects (CH1-3): arpeggio, slide, duty switching. Driven every frame by TickChannel.
; c = channel 0..2, de = the period just triggered. Restarts the arpeggio and the duty
; switching; starts a slide from the period that was playing if the note is legato.
EffectsStart:
    ld a, c                 ; wOut = the period now playing (the slide of the next note starts here)
    add a
    add LOW(wOut)
    ld l, a
    ld h, HIGH(wOut)
    ld [hl], e
    inc l
    ld [hl], d
    ld hl, wArpStep
    call HLplusC
    ld [hl], 0
    ld a, P_ARPS
    call PatchByte
    and a
    jr nz, .arps
    inc a
.arps:
    ld b, a
    ld hl, wArpTimer
    call HLplusC
    ld [hl], b
    ld a, c
    cp 2
    jr nc, .glide
    ld hl, wDutyPh
    call HLplusC
    ld [hl], 0
    ld a, P_DSPD
    call PatchByte
    ld b, a
    ld hl, wDutyTimer
    call HLplusC
    ld [hl], b
.glide:
    ld hl, wGlide           ; hl = &wGlide[c]
    ld a, c
    add a
    add l
    ld l, a
    jr nc, .gp
    inc h
.gp:
    xor a
    ld [hl+], a
    ld [hl-], a
    ld a, [wWasOn]
    and a
    ret z                   ; nothing was sounding: no slide
    ld a, P_SLID
    call PatchByte
    and a
    ret z
    ld a, [wPrevOut]        ; glide = previous period - new period
    sub e
    ld [hl+], a
    ld a, [wPrevOut + 1]
    sbc d
    ld [hl], a
    ret

; c = channel 0..2, every frame while a note sounds: the arpeggio steps (it rewrites wBase and
; makes TickChannel write the period) and CH1/2's duty switching. Keeps c. Clobbers a, b, de, hl.
EffectsTick:
    ld a, P_ARP1
    call PatchByte
    ld b, a
    ld a, P_ARP2
    call PatchByte
    or b
    jr z, .duty             ; no arpeggio
    ld hl, wArpTimer
    call HLplusC
    dec [hl]
    jr nz, .duty
    ld a, P_ARPS
    call PatchByte
    and a
    jr nz, .reload
    inc a
.reload:
    ld [hl], a
    ld hl, wArpStep
    call HLplusC
    ld a, [hl]
    inc a
    cp 3
    jr c, .step
    xor a
.step:
    ld [hl], a
    and a
    jr z, .semis            ; a = 0: the root
    dec a
    ld a, P_ARP1
    jr z, .which
    ld a, P_ARP2
.which:
    call PatchByte
.semis:
    ld b, a                 ; b = semitones above the root
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    add b
    ld b, a                 ; b = the note of this step
    ld a, c
    cp 2
    ld a, NOTE_MAX
    jr nz, .max
    ld a, NOTE_MAX - 12
.max:
    cp b
    jr c, .duty             ; above the range: this step keeps the last pitch
    ld a, c
    cp 2
    jr nz, .period
    ld a, b                 ; CH3 plays an octave lower at the same period
    add 12
    ld b, a
.period:
    call GetPeriod          ; de
    ld a, c
    add a
    add LOW(wBase)
    ld l, a
    ld h, HIGH(wBase)
    ld [hl], e
    inc l
    ld [hl], d
    ld hl, wTickOn          ; write the new period this frame even without modulation
    call HLplusC
    ld [hl], 1
.duty:
    ld a, c
    cp 2
    ret nc
    ld a, P_DSPD
    call PatchByte
    and a
    ret z
    ld b, a
    ld a, P_LEN
    call PatchByte
    and a
    ret nz                  ; a length is set: NRx1 holds it too, rewriting would restart it
    ld hl, wDutyTimer
    call HLplusC
    dec [hl]
    ret nz
    ld [hl], b
    ld hl, wDutyPh
    call HLplusC
    ld a, [hl]
    xor 1
    ld [hl], a
    ld a, P_MAIN
    jr z, .first
    ld a, P_DUT2
.first:
    call PatchByte
    rrca
    rrca                    ; duty -> bits 7-6, length 0 (no length is set)
    ld b, a
    ld a, c
    and a
    ld a, b
    jr nz, .nr21
    ldh [rNR11], a
    ret
.nr21:
    ldh [rNR21], a
    ret

; c = channel 0..2, hl = the period offset so far -> hl + the slide, which then decays by
; glide >> P_SLID each frame (at least 1 toward 0). Keeps c. Clobbers a, b, de.
GlideStep:
    push hl
    ld hl, wGlide
    ld a, c
    add a
    add l
    ld l, a
    jr nc, .gp
    inc h
.gp:
    ld e, [hl]
    inc hl
    ld d, [hl]              ; de = glide, hl = &glide + 1
    ld a, d
    or e
    jr z, .done
    ld a, P_SLID
    call PatchByte
    and a
    jr nz, .shift
    ld d, a                 ; the slide was switched off: drop it
    ld e, a
    jr .store
.shift:
    push hl
    ld b, a
    ld h, d
    ld l, e
.sh:
    sra h
    rr l
    dec b
    jr nz, .sh              ; hl = glide >> shift (arithmetic)
    ld a, h
    or l
    jr nz, .step
    inc l                   ; |step| < 1: move by 1 toward 0
    bit 7, d
    jr z, .step
    ld hl, $FFFF
.step:
    ld a, e                 ; glide -= step
    sub l
    ld e, a
    ld a, d
    sbc h
    ld d, a
    pop hl
.store:
    ld [hl], d
    dec hl
    ld [hl], e
.done:
    pop hl
    add hl, de
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

; ---- CH1: duty vol env len pan + sweep
VoicePulse1:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    call StoreBase
    call ApplyBendDE        ; a held bend applies from the first moment
    call PulseRegs          ; NR11, NR12 (c = 0: rNR11 + 0)
    ld a, P_SWT
    call PatchByte
    swap a                  ; sweep time -> bits 6-4
    ld b, a
    ld a, P_SWD
    call PatchByte
    add a
    add a
    add a                   ; sweep direction -> bit 3
    or b
    ld b, a
    ld a, P_SWS
    call PatchByte          ; sweep shift -> bits 2-0
    or b
    ldh [rNR10], a
    ld a, e
    ldh [rNR13], a
    call TrigHigh
    ldh [rNR14], a
    ret

; ---- CH2: duty vol env len pan
VoicePulse2:
    ld a, b
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    call SetCur
    call GetPeriod
    call StoreBase
    call ApplyBendDE
    call PulseRegs
    ld a, e
    ldh [rNR23], a
    call TrigHigh
    ldh [rNR24], a
    ret

; c = 0 (CH1) or 1 (CH2): writes NRx1 (duty + length) and NRx2 (volume + envelope).
; Keeps c, de.
PulseRegs:
    call LenSetup           ; a = length load
    and %00111111           ; CH1/2 count 6 bits: bits 7-6 of NRx1 are the duty, not the length
    ld b, a
    ld a, P_MAIN
    call PatchByte
    rrca
    rrca                    ; duty -> bits 7-6
    or b
    ld b, a
    ld a, c
    and a
    ld a, b
    jr nz, .ch2
    ldh [rNR11], a
    call VolEnv
    ldh [rNR12], a
    ret
.ch2:
    ldh [rNR21], a
    call VolEnv
    ldh [rNR22], a
    ret

; c = channel -> a = NRx2: volume (scaled by the velocity) << 4 | direction << 3 | pace.
; Records the volume in wVoiceVol. Keeps c, de.
VolEnv:
    push de
    ld a, P_VOL
    call PatchByte
    push bc
    call ScaleVol           ; (clobbers b, c)
    pop bc
    ld d, a
    ld hl, wVoiceVol
    call HLplusC            ; (clobbers a)
    ld [hl], d
    ld a, d
    swap a
    ld d, a
    ld a, P_EDIR
    call PatchByte
    add a
    add a
    add a                   ; direction -> bit 3
    or d
    ld d, a
    ld a, P_EPAC
    call PatchByte
    and 7
    or d
    pop de
    ret

; c = channel -> a = the NRx1 length load for P_LEN (0 = off), and wLenBit[c] = $40 if on.
; CH1/2/4 count 64 - load steps, CH3 256 - load (steps of 1/256 s). Keeps bc, de.
LenSetup:
    push hl
    ld hl, wLenBit
    call HLplusC            ; (clobbers a)
    ld a, P_LEN
    call PatchByte
    and a
    jr z, .off
    ld [hl], $40
    cpl
    inc a                   ; -len: 64 - len in the low 6 bits, 256 - len for CH3
    pop hl
    ret
.off:
    ld [hl], a              ; a = 0
    pop hl
    ret

; c = channel, d = period high bits -> a = NRx4 with the trigger and the length enable.
TrigHigh:
    push hl
    ld hl, wLenBit
    call HLplusC
    ld a, [hl]
    pop hl
    or d
    or $80
    ret

; a = patch byte offset -> a = that byte of channel c's patch. Keeps bc, de, hl.
PatchByte:
    ASSERT PATCH_SIZE == 32
    push hl
    ld l, a
    ld a, c
    swap a
    add a                   ; c * PATCH_SIZE (32)
    add l
    add LOW(wPatch)         ; wPatch is 256-byte aligned: no carry
    ld l, a
    ld h, HIGH(wPatch)
    ld a, [hl]
    pop hl
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
    call ApplyBendDE
    xor a
    ldh [rNR30], a          ; DAC off while rewriting wave RAM
    call LoadWave
    ld a, $80
    ldh [rNR30], a
    call LenSetup
    ldh [rNR31], a
    ld a, [wPatch + 2 * PATCH_SIZE + P_VOL]
    ld b, a                 ; patch level 0/1/2
    ld a, [wPatch + MIDI_BLOCK + PM_VELO]
    and a
    jr z, .level
    ld a, [wNoteVel]        ; softer notes use a quieter wave level
    cp 96
    jr nc, .level
    inc b
    cp 48
    jr nc, .level
    inc b
.level:
    ld a, b
    cp 3
    jr c, .levelOk
    ld a, 2
.levelOk:
    ld [wVoiceVol + 2], a
    inc a                   ; level 0/1/2 -> NR32 $20/$40/$60 (100/50/25 %)
    swap a
    add a
    ldh [rNR32], a
    ld a, e
    ldh [rNR33], a
    call TrigHigh
    ldh [rNR34], a
    ret

; Copy preset wave (patch byte 0 of CH3) into wave RAM (CH3 must be stopped).
LoadWave:
    push de
    push bc
    ld a, [wPatch + 2 * PATCH_SIZE + P_MAIN]
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
    ld a, [wPatch + 3 * PATCH_SIZE + P_MAIN]
    and 1                   ; LFSR width -> bit 3
    add a
    add a
    add a
    or e
    ld e, a
    ld a, [wPatch + 3 * PATCH_SIZE + P_NDIV]
    and 7                   ; divisor code -> bits 2-0
    or e
    ldh [rNR43], a
    call LenSetup
    ldh [rNR41], a
    call VolEnv
    ldh [rNR42], a
    ld d, 0
    call TrigHigh
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
    ; fall through: the mixer follows the patches every frame (an edit is heard at once)

; NR51 from each channel's P_PAN (0 = both, 1 = left, 2 = right) and NR50 from the
; master volume of the MIDI block. Clobbers a, b, c, e.
ApplyMixer:
    ld b, 0                 ; NR51: bit n = right, bit n + 4 = left
    ld e, %00010001         ; channel 0's bits
    ld c, 0
.pan:
    ld a, P_PAN
    call PatchByte
    cp 1
    jr z, .left
    cp 2
    jr z, .right
    ld a, e                 ; both
    jr .set
.left:
    ld a, e
    and $F0
    jr .set
.right:
    ld a, e
    and $0F
.set:
    or b
    ld b, a
    sla e
    inc c
    ld a, c
    cp NUM_CH
    jr c, .pan
    ld a, b
    ldh [rNR51], a
    ld a, [wPatch + MIDI_BLOCK + PM_VOLL]
    and 7
    swap a
    ld b, a
    ld a, [wPatch + MIDI_BLOCK + PM_VOLR]
    and 7
    or b
    ldh [rNR50], a
    ret

TickChannel:                ; c = channel 0..2
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    and a
    ret z
    call EffectsTick        ; arpeggio (may move wBase) and duty switching
    call VibOffset          ; hl = signed vibrato offset
    ld a, l
    ld [wTickOff], a
    ld a, h
    ld [wTickOff + 1], a
    ld a, c                 ; de = base period of the note
    add a
    add LOW(wBase)
    ld l, a
    ld h, HIGH(wBase)
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    call BendOffset         ; hl = signed pitch bend offset (keeps c, de)
    ld a, [wTickOff]
    add l
    ld l, a
    ld a, [wTickOff + 1]
    adc h
    ld h, a                 ; hl = vibrato + bend
    push de                 ; de = the base period
    call GlideStep          ; + the slide
    pop de
    ld a, h
    or l
    jr nz, .modulated
    ld hl, wTickOn          ; nothing to add: if the last write was modulated,
    call HLplusC            ; put the plain period back once, then stay quiet
    ld a, [hl]
    and a
    ret z
    xor a
    ld [hl], a
    ld hl, 0
    jr .apply
.modulated:
    push hl
    ld hl, wTickOn
    call HLplusC
    ld [hl], 1
    pop hl
.apply:
    add hl, de              ; base + offset, clamped to 0..2047
    bit 7, h
    jr z, .notNeg
    ld hl, 0
.notNeg:
    ld a, h
    cp 8
    jr c, .inRange
    ld hl, $07FF
.inRange:
    ld d, h
    ld e, l
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
    call LenHigh
    ldh [rNR34], a          ; bit 7 clear: no retrigger
    ret
.ch1:
    ld a, e
    ldh [rNR13], a
    call LenHigh
    ldh [rNR14], a
    ret
.ch2:
    ld a, e
    ldh [rNR23], a
    call LenHigh
    ldh [rNR24], a
    ret

; c = channel, d = period high bits -> a = NRx4 without the trigger, keeping the length
; enable (writing it as 0 would stop the length counter).
LenHigh:
    ld hl, wLenBit
    call HLplusC
    ld a, [hl]
    or d
    ret

; c = channel -> hl = signed vibrato offset in period units (0 if there is none).
; Keeps c. Clobbers a, b, d, e.
VibOffset:
    ld a, c
    swap a
    add a                   ; c * PATCH_SIZE (32)
    add PATCH_VIBD
    add LOW(wPatch)
    ld l, a
    ld h, HIGH(wPatch)
    ld a, [hl+]             ; patch vibrato depth
    ld b, a
    push hl
    ld hl, wMod             ; the mod wheel (CC1) can raise it
    call HLplusC
    ld a, [hl]
    pop hl
    cp b
    jr c, .patchDepth
    ld b, a
.patchDepth:
    ld a, b
    and a
    jr nz, .active
    ld hl, 0
    ret
.active:
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
    ld a, c                 ; de = base period
    add a
    add LOW(wBase)
    ld l, a
    ld h, HIGH(wBase)
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    ld hl, 2048             ; hl = 2048 - base
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
    call Mul8               ; hl = m * (P >> 4)
    add hl, hl
    ld l, h                 ; off = product >> 7  (<= 54)
    ld h, 0
    ld a, [wVibSign]
    and a
    ret z
    xor a                   ; negative: hl = -hl
    sub l
    ld l, a
    ld a, 0
    sbc h
    ld h, a
    ret

; c = channel (0..2), de = base period -> hl = signed period offset for the channel's
; pitch bend. Keeps c and de. Clobbers a, b.
; With P = 2048 - period (proportional to 1/frequency) the exact offsets are
;   up    P * (1 - 2^(-s/12))        down   -P * (2^(s/12) - 1)      (s = semitones)
; The factors come from BendUp / BendDown (tools/gen_bend.py), looked up by
; m = |bend| * range / 4 (so s = m / 16); then offset = (P >> 3) * factor / 16.
BendOffset:
    push de
    ld hl, 2048             ; wBendP = (2048 - period) >> 3
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
    ld a, l
    srl a
    srl a
    srl a
    ld b, a
    ld a, h
    swap a
    add a                   ; h << 5
    or b
    ld [wBendP], a
    ld hl, wBend
    call HLplusC
    ld a, [hl]
    sub 64                  ; signed bend, -64..63
    jr z, .zero
    ld d, 0
    bit 7, a
    jr z, .mag
    cpl
    inc a                   ; |bend|
    inc d                   ; downwards
.mag:
    ld e, a
    ld a, d
    ld [wBendSign], a
    ld a, [wPatch + MIDI_BLOCK + PM_BEND]
    and a
    jr z, .zero             ; range 0: bend disabled
    ld b, a                 ; b = range in semitones
    ld a, e                 ; a = |bend|
    call Mul8               ; hl = |bend| * range  (<= 768)
    srl h
    rr l
    srl h
    rr l                    ; hl = m (<= 192)
    ld de, BendUp
    ld a, [wBendSign]
    and a
    jr z, .lookup
    ld de, BendDown
.lookup:
    add hl, de
    ld b, [hl]              ; factor * 128
    ld a, [wBendP]
    call Mul8               ; hl = (P >> 3) * factor
    REPT 4
        srl h
        rr l
    ENDR                    ; / 16
    ld a, [wBendSign]
    and a
    jr z, .done
    xor a                   ; downwards: hl = -hl
    sub l
    ld l, a
    ld a, 0
    sbc h
    ld h, a
.done:
    pop de
    ret
.zero:
    ld hl, 0
    pop de
    ret

; de = base period of a note starting on channel c -> de plus the pitch bend that
; is in effect, clamped to 0..2047. Keeps c. Clobbers a, b, hl.
ApplyBendDE:
    call BendOffset
    add hl, de
    bit 7, h
    jr z, .pos
    ld hl, 0
.pos:
    ld a, h
    cp 8
    jr c, .ok
    ld hl, $07FF
.ok:
    ld d, h
    ld e, l
    ret

; a = patch volume 0..15 -> volume scaled by the note velocity (wNoteVel 0..127)
; when velocity sensitivity is on: vol * (vel / 8 + 1) / 16, never below 1 for a
; non-zero volume. Keeps hl, de. Clobbers a, b, c.
ScaleVol:
    ld b, a
    ld a, [wPatch + MIDI_BLOCK + PM_VELO]
    and a
    ld a, b
    ret z                   ; velocity ignored
    ld a, [wNoteVel]
    srl a
    srl a
    srl a                   ; 0..15
    inc a                   ; 1..16
    ld c, a
    xor a
.mul:
    add b
    dec c
    jr nz, .mul             ; vol * scale (at most 15 * 16 = 240)
    swap a
    and $0F                 ; / 16
    and a
    ret nz
    ld a, b                 ; a quiet note is still audible
    and a
    ret z
    ld a, 1
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
DefaultPatch:                       ; byte order: see synth.inc (16-21: arp1 arp2 arps slid dut2 dspd)
    db 2, 15, 0, 0, 0, 0, 0, 3,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 2, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0, 0, 0, 0   ; CH1
    db 2, 15, 0, 0, 0, 0, 0, 3,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 2, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0, 0, 0, 0   ; CH2
    db 0, 0,  0, 0, 0, 0, 0, 3,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 2, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0, 0, 0, 0   ; CH3
    db 0, 15, 0, 2, 0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0, 0, 0, 0   ; CH4: decays at pace 2
    db 1, 2, 3, 4, 2, 1, 1, 0,  7, 7, 4, 0,  0, 0, 0, 0,  0, 0, 0, 0, 0, 0,  0, 0,  0, 0, 0, 0, 0, 0, 0, 0   ; MIDI: CH1-4 listen to MIDI ch 1-4,
                                                              ; bend 2, velocity on, mod wheel on, sync off, master 7/7, time 4/4
    ASSERT @ - DefaultPatch == NUM_PATCHES * PATCH_SIZE

DirtyBits:  db %00000001, %00000010, %00000100, %00001000
            db %00010000, %00100000, %01000000, %10000000

INCLUDE "bend.inc"
INCLUDE "notetable.inc"
INCLUDE "waves.inc"
