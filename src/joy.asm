; Joypad handling.
;  All screens: START = next screen (play -> edit -> sequencer),
;               SELECT+START = sequencer play/stop,
;               SELECT tap = next channel (all screens; the roll shows it),
;               SELECT+A = save to SRAM, SELECT+B = load.
;  Play/edit:   A = gate on the selected channel.
;  Play screen : d-pad = note (+-1 / +-octave).
;  Edit screen : UP/DOWN = parameter row, LEFT/RIGHT = value,
;                hold B + d-pad = change the audition note.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Joypad", ROM0

; wJoy bits: 7 down, 6 up, 5 left, 4 right, 3 start, 2 select, 1 B, 0 A (1 = pressed).
; The Chromatic's ESP32 can press virtual buttons (src/clink.asm). Their data frames have
; UP+DOWN or LEFT+RIGHT both pressed, which the real d-pad cannot do: such a frame is
; handed to CLinkRx and wJoy stays 0 so that the UI never sees it.
ReadJoy:
    ld a, [wJoy]
    ld [wJoyPrev], a
    call ReadPadRaw
    ld c, a
    call ReadPadRaw
    cp c
    jr z, .stable
    call ReadPadRaw         ; a virtual button changed between the two groups: read again
.stable:
    ld b, a
    and $C0
    cp $C0
    jr nz, .notUD
    ld a, b                 ; UP+DOWN: phase A symbol if exactly one of LEFT/RIGHT
    and $30
    jr z, .masked
    cp $30
    jr z, .masked
    ld d, 0
    cp $20
    jr nz, .phaseA
    ld d, $10               ; LEFT pressed = data bit 4
.phaseA:
    ld c, 0
    jr .sym
.notUD:
    ld a, b
    and $30
    cp $30
    jr nz, .plain
    ld a, b                 ; LEFT+RIGHT: phase B symbol if exactly one of UP/DOWN
    and $C0
    jr z, .masked
    cp $C0
    jr z, .masked
    ld d, 0
    cp $40
    jr nz, .phaseB
    ld d, $10               ; UP pressed = data bit 4
.phaseB:
    ld c, 1
.sym:
    ld a, b
    and $0F
    or d
    ld [wClSym], a
    ld a, c
    ld [wClPh], a
    ld a, 1
    ld [wClHave], a
.masked:
    xor a
    ld [wJoy], a
    ret
.plain:
    ld a, b
    ld [wJoy], a
    ret

; a = the pad as wJoy bits (1 = pressed). Clobbers d.
ReadPadRaw:
    ld a, $20               ; select d-pad
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    and $0F
    swap a
    ld d, a
    ld a, $10               ; select buttons
    ldh [rP1], a
    REPT 6
        ldh a, [rP1]
    ENDR
    and $0F
    or d
    cpl
    ld d, a
    ld a, $30
    ldh [rP1], a
    ld a, d
    ret

HandleJoy:
    ld a, [wJoyPrev]
    cpl
    ld b, a
    ld a, [wJoy]
    and b
    ld d, a                 ; d = newly pressed

    ; d-pad auto-repeat: a held direction becomes a fresh "press" every
    ; REPEAT_RATE frames after REPEAT_DELAY frames. Any change of the d-pad
    ; state (new direction, release) restarts the delay.
    ld a, [wJoy]
    and %11110000
    ld b, a                 ; b = d-pad directions held now
    ld a, [wJoyPrev]
    and %11110000
    cp b
    jr nz, .repeatRestart
    ld a, b
    and a
    jr z, .repeatDone
    ld hl, wRepTimer
    dec [hl]
    jr nz, .repeatDone
    ld [hl], REPEAT_RATE
    ld a, d
    or b
    ld d, a
    jr .repeatDone
.repeatRestart:
    ld a, REPEAT_DELAY
    ld [wRepTimer], a
.repeatDone:

    bit PADB_SELECT, d
    jr z, .noSelPress
    xor a
    ld [wSelUsed], a
.noSelPress:
    ld a, [wJoy]
    bit PADB_SELECT, a
    jr z, .noCombo
    bit PADB_A, d
    jr z, .noSave
    ld a, 1
    ld [wSelUsed], a
    jp DoSave               ; SELECT+A: save
.noSave:
    bit PADB_B, d
    jr z, .noCombo
    ld a, 1
    ld [wSelUsed], a
    ld [wBUsed], a          ; the B release must not delete a note
    jp DoLoad               ; SELECT+B: load
.noCombo:
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
    ld a, [wScreen]         ; the edit screen has a 5th page (MIDI settings)
    cp SCREEN_EDIT
    ld a, NUM_CH
    jr nz, .limit
    inc a
.limit:
    ld b, a
    ld a, [wSelCh]
    inc a
    cp b
    jr c, .chOk
    xor a
.chOk:
    ld [wSelCh], a
    xor a
    ld [wEditRow], a
    ld a, [wDirty]
    or %00101111            ; channel markers + edit header / roll ruler
    ld [wDirty], a
    ld a, $FF
    ld [wDirtyEdit], a
    ld a, [wScreen]
    cp SCREEN_SEQ
    jr nz, .noSel
    push de                 ; RollChannelChanged trashes d (this frame's new presses)
    call RollChannelChanged ; the roll shows the selected channel
    pop de
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
