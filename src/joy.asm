; Joypad handling.
;  All screens: START = next screen (play -> edit -> sequencer),
;               SELECT+START = sequencer play/stop,
;               SELECT tap = next channel (play/edit screens).
;  Play/edit:   A = gate on the selected channel.
;  Play screen : d-pad = note (+-1 / +-octave).
;  Edit screen : UP/DOWN = parameter row, LEFT/RIGHT = value,
;                hold B + d-pad = change the audition note.
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
    jr z, .noSelPress
    xor a
    ld [wSelUsed], a
.noSelPress:
    bit PADB_START, d
    jr z, .noStart
    ld a, [wJoy]
    bit PADB_SELECT, a
    jr z, .cycle
    ld a, 1                 ; SELECT+START: sequencer play/stop
    ld [wSelUsed], a
    push de
    call SeqToggle
    pop de
    jr .noStart
.cycle:
    ld a, [wScreen]
    inc a
    cp 3
    jr c, .reqOk
    xor a
.reqOk:
    inc a                   ; request: target screen + 1
    ld [wScreenReq], a
.noStart:
    ; SELECT released without being used as a modifier: next channel
    ld a, [wJoyPrev]
    bit PADB_SELECT, a
    jr z, .noSel
    ld a, [wJoy]
    bit PADB_SELECT, a
    jr nz, .noSel
    ld a, [wSelUsed]
    and a
    jr nz, .noSel
    ld a, [wScreen]
    cp SCREEN_SEQ
    jr z, .noSel
    ld a, [wSelCh]
    inc a
    and NUM_CH - 1
    ld [wSelCh], a
    xor a
    ld [wEditRow], a
    ld a, [wDirty]
    or %00101111            ; channel markers + edit header
    ld [wDirty], a
    ld a, $FF
    ld [wDirtyEdit], a
.noSel:
    ld a, [wScreen]
    and a
    jr z, .play
    cp SCREEN_SEQ
    jp z, SeqInput
    call EditInput
    ld a, [wJoy]
    bit PADB_B, a
    jr z, .gate
.play:
    call NotePad
.gate:
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

; d-pad moves the audition note: +-1 semitone / +-octave. Keeps d.
NotePad:
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
    ret c
    cp NOTE_MAX + 1
    ret nc
    cp e
    ret z
    ld [wJoyNote], a
    ld a, [wDirty]
    or DIRTY_STATUS
    ld [wDirty], a
    ret

; Edit screen d-pad (ignored while B is held). Keeps d.
EditInput:
    ld a, [wJoy]
    bit PADB_B, a
    ret nz
    bit PADB_UP, d
    jr z, .noUp
    push de
    ld c, $FF
    call MoveRow
    pop de
.noUp:
    bit PADB_DOWN, d
    jr z, .noDown
    push de
    ld c, 1
    call MoveRow
    pop de
.noDown:
    bit PADB_LEFT, d
    jr z, .noLeft
    push de
    ld c, $FF
    call ChangeValue
    pop de
.noLeft:
    bit PADB_RIGHT, d
    ret z
    push de
    ld c, 1
    call ChangeValue
    pop de
    ret

; c = delta (+1 / $FF). Moves wEditRow, skipping hidden rows (row 0 is never hidden).
MoveRow:
    ld a, [wEditRow]
    ld b, a                 ; b = old row
.try:
    ld a, [wEditRow]
    add c
    and 7
    ld [wEditRow], a
    push bc
    ld b, a
    call EntryPtr
    pop bc
    ld a, [hl]
    inc a
    jr z, .try              ; max = $FF -> hidden
    ld a, b
    call MarkEditRow
    ld a, [wEditRow]
    jp MarkEditRow

; c = delta (+1 / $FF). Changes the selected parameter, clamped to 0..max.
ChangeValue:
    ld a, [wEditRow]
    ld b, a
    push bc
    call EntryPtr
    pop bc
    ld a, [hl]
    ld e, a                 ; e = max
    call PatchRowHL         ; hl -> value
    ld a, [hl]
    add c
    ld d, a
    ld a, e
    cp d
    ret c                   ; new value > max (or underflowed to $FF)
    ld a, d
    ld [hl], a
    ld a, b
    jp MarkEditRow

; a = parameter row -> flag it for redraw. Keeps bc.
MarkEditRow:
    push bc
    ld c, a
    ld hl, DirtyBits
    call HLplusC
    ld a, [hl]
    ld hl, wDirtyEdit
    or [hl]
    ld [hl], a
    pop bc
    ret
