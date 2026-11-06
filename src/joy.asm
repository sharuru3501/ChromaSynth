; Joypad: A = gate, d-pad = note, SELECT = next channel, B = cycle param.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Joypad", ROM0

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

HandleJoy:
    ld a, [wJoyPrev]
    cpl
    ld b, a
    ld a, [wJoy]
    and b
    ld d, a                 ; d = newly pressed

    bit PADB_SELECT, d
    jr z, .noSel
    ld a, [wSelCh]
    inc a
    and NUM_CH - 1
    ld [wSelCh], a
    ld a, [wDirty]
    or %00001111            ; repaint the channel markers
    ld [wDirty], a
.noSel:
    bit PADB_B, d
    jr z, .noB
    ld a, [wSelCh]
    ld c, a
    push de
    call CycleParam
    pop de
.noB:
    ; d-pad: +-1 semitone / +-octave on the pad note
    ld a, [wJoyNote]
    ld e, a                 ; e = old note
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
    cp e
    jr z, .keep
    ld [wJoyNote], a
    ld a, [wDirty]
    or DIRTY_STATUS
    ld [wDirty], a
.keep:
    bit PADB_A, d
    jr z, .release
    ld a, [wSelCh]
    ld [wPadCh], a
    ld c, a
    ld a, [wJoyNote]
    jp NoteOn
.release:
    ld a, [wJoyPrev]
    bit PADB_A, a
    ret z
    ld a, [wJoy]
    bit PADB_A, a
    ret nz
    ld a, [wPadCh]
    ld c, a
    jp NoteOff
