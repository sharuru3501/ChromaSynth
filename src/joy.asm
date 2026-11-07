; Joypad handling.
;  All screens: START+RIGHT / START+LEFT = next / previous screen, in a line (play - edit -
;               sequencer - keyboard, stops at both ends; one step per press of LEFT/RIGHT).
;               START alone does nothing (kept free on purpose).
;               SELECT+START = sequencer play/stop (also on the keyboard screen),
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
;
; The Chromatic's ESP32 can press virtual buttons (docs/CHROMATIC_LINK.md). The FPGA cancels
; UP+DOWN and LEFT+RIGHT, so a symbol never contains an opposite pair. The keyboard screen
; (SCREEN_KBD) reads the pad as data and hides it from the UI:
;   symbol = exactly one of UP (phase A) / DOWN (phase B) held; RIGHT and SELECT not held;
;   data bits 3..0 = LEFT, START, B, A.
; The ESP32 never presses SELECT or RIGHT, and it presses LEFT only together with UP or DOWN
; (src/clink chl_buttons), in the same d-pad group of P1. So a frame with neither UP nor DOWN
; is a person: there, START+LEFT (SELECT not held) leaves for the sequencer, and SELECT+START
; reaches the UI (play/stop). Frames with UP or DOWN neither start nor reset the combo.
; SELECT alone still reaches the UI (tap = next channel).

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
    ld a, [wScreen]
    cp SCREEN_KBD
    jr z, .kbd
    xor a
    ld [wKbdNav], a         ; the keyboard screen starts with no combo held
    ld a, [wNavHide]        ; 1 = just changed screen with START+LEFT/RIGHT
    and a
    jr z, .plain
    ld a, b
    and $F0
    jr z, .unhide
    ld a, b                 ; hide the d-pad until it is released, or the new screen would
    and $0F                 ; see it held (auto-repeat) and the next combo would not be new
    ld [wJoy], a
    ret
.unhide:
    ld [wNavHide], a        ; a = 0
.plain:
    ld a, b
    ld [wJoy], a
    ret
.kbd:
    ld a, b
    and $C0
    jr nz, .symbolFrame     ; UP or DOWN: maybe a symbol; the person's combo waits
    ld a, b
    and $2C                 ; LEFT, START, SELECT
    cp $28                  ; START+LEFT without SELECT
    ld c, 0
    jr nz, .combo
    inc c
.combo:
    ld a, [wKbdNav]
    ld e, a                 ; e = combo on the last person frame
    ld a, c
    ld [wKbdNav], a
    and a
    jr z, .person
    ld a, e
    and a
    jr nz, .hide            ; still held from before: one step per press
    xor a                   ; leave: back to the sequencer
    ld [wClN], a
    ld [wClHave], a
    inc a
    ld [wNavHide], a
    ld a, SCREEN_SEQ + 1
    ld [wScreenReq], a
    jr .hide
.person:
    ld a, b                 ; SELECT+START (no UP/DOWN): the UI toggles the sequencer
    and $0C
    cp $0C
    jr nz, .hide
    ld [wJoy], a
    ret
.symbolFrame:
    ld a, b
    and $14                 ; SELECT or RIGHT: never part of a symbol
    jr nz, .keepStart
    ld a, b
    and $C0
    ld c, 0
    cp $40
    jr z, .sym              ; UP only = phase A
    inc c
    cp $80
    jr nz, .keepStart       ; UP+DOWN (the FPGA cancels it): not a symbol
.sym:
    ld a, b
    and $03                 ; A, B
    ld d, a
    bit 3, b
    jr z, .noStart
    set 2, d
.noStart:
    bit 5, b
    jr z, .noLeft
    set 3, d
.noLeft:
    ld a, d
    ld [wClSym], a
    ld a, c
    ld [wClPh], a
    ld a, 1
    ld [wClHave], a
.keepStart:
    ld a, [wJoyPrev]        ; a frame with UP/DOWN neither presses nor releases the person's
    and $08                 ; START (SELECT+START would toggle the sequencer again and again)
    ld c, a
    ld a, b
    and $04
    or c
    ld [wJoy], a
    ret
.hide:
    ld a, b
    and $04                 ; only SELECT reaches the UI
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
    ld a, [wJoy]
    bit PADB_START, a
    jr z, .noStart          ; START alone does nothing: it only modifies
    bit PADB_SELECT, a
    jr z, .nav
    bit PADB_START, d
    jr z, .startHeld
    push de                 ; SELECT+START: sequencer play/stop
    call SeqToggle
    pop de
    jr .startHeld
.nav:
    ; START+LEFT / START+RIGHT becoming true (in either order; not the d-pad auto-repeat)
    ld a, [wJoyPrev]
    bit PADB_START, a
    jr nz, .prevStart
    xor a
.prevStart:
    and (1 << PADB_LEFT) | (1 << PADB_RIGHT)
    cpl
    ld c, a
    ld a, [wJoy]
    and (1 << PADB_LEFT) | (1 << PADB_RIGHT)
    and c
    jr z, .startHeld
    ld c, a
    ld a, [wScreen]
    bit PADB_LEFT, c
    jr z, .next
    and a
    jr z, .startHeld        ; the first screen: stay
    dec a
    jr .request
.next:
    cp SCREEN_KBD
    jr z, .startHeld        ; the last screen: stay
    inc a
.request:
    inc a                   ; request: target screen + 1
    ld [wScreenReq], a
    ld a, 1
    ld [wNavHide], a
.startHeld:
    ld a, 1                 ; a SELECT pressed under START is no channel tap
    ld [wSelUsed], a
    ld a, d                 ; the d-pad belongs to the navigation while START is held
    and $0F
    ld d, a
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

; c = delta (+1 / $FF). Moves wEditRow through the EDIT_ROWS rows (two pages of 8),
; skipping hidden rows (row 0 is never hidden). Crossing to the other page redraws the list.
MoveRow:
    ld a, [wEditRow]
    ld b, a                 ; b = old row
.try:
    ld a, [wEditRow]
    add c
    and EDIT_ROWS - 1
    ld [wEditRow], a
    push bc
    ld b, a
    call EntryPtr
    pop bc
    ld a, [hl]
    and a
    jr z, .try              ; max = 0 -> hidden
    ld a, [wEditRow]
    xor b
    and 8
    jr z, .samePage
    ld a, $FF               ; the other page: every row and the page number in the header
    ld [wDirtyEdit], a
    ld a, [wDirty]
    or DIRTY_HEADER
    ld [wDirty], a
    ret
.samePage:
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
    ld e, a                 ; e = max (up to 255)
    call PatchRowHL         ; hl -> value
    ld a, [hl]
    bit 7, c
    jr nz, .down
    cp e
    ret nc                  ; already at the maximum
    inc a
    jr .store
.down:
    and a
    ret z                   ; already 0
    dec a
.store:
    ld [hl], a
    ld a, b
    jp MarkEditRow

; a = parameter row -> flag its screen row (row & 7) for redraw. Keeps bc.
MarkEditRow:
    push bc
    and 7
    ld c, a
    ld hl, DirtyBits
    call HLplusC
    ld a, [hl]
    ld hl, wDirtyEdit
    or [hl]
    ld [hl], a
    pop bc
    ret
