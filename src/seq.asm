; Step sequencer engine + piano-roll editing input.
;
; Pattern cells (wPattern[channel * 64 + step]): 0 = empty, CELL_OFF = note off,
; anything else = MIDI note (note-on). A note sounds from its note-on cell until
; the next non-empty cell, which is how the piano roll draws its length.
;
; Timing: every frame wSeqAcc += 256 (8.8 fixed point, 1.0 = one frame). When it
; reaches the step length for the current BPM (TempoTable, frames per 16th
; note) one step is played. Step length is always > 3 frames, so at most one
; step fires per frame.
;
; Piano-roll controls (see SeqInput):
;   d-pad            move cursor (hold B: 4 steps / octave)
;   A                place a 1-step note at the cursor (and audition it)
;   A + LEFT/RIGHT   shorten / lengthen the note under the cursor
;   A + UP/DOWN      transpose the note under the cursor
;   B (tap)          delete the note under the cursor
;   SELECT + UP/DOWN BPM +-1      SELECT + LEFT/RIGHT  loop length -+16 steps
;   SELECT tap       next channel (handled in joy.asm)
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Sequencer", ROM0

; ---------------------------------------------------------------- playback
; Start/stop (SELECT+START on any screen).
SeqToggle:
    ld a, [wSeqPlay]
    xor 1
    ld [wSeqPlay], a
    jr z, .stop
    xor a
    ld [wSeqStep], a
    inc a
    ld [wFollow], a         ; the roll scrolls along with the playhead
    call GetStepLen
    dec d                   ; acc = len - 1 frame: the first step fires next frame
    ld a, e
    ld [wSeqAcc], a
    ld a, d
    ld [wSeqAcc + 1], a
    jp MarkSeqStatus
.stop:
    ld c, 0
.silence:
    push bc
    call NoteOff
    pop bc
    inc c
    ld a, c
    cp NUM_CH
    jr c, .silence
    jp MarkSeqStatus

; Called once per frame.
SeqTick:
    ld a, [wSeqPlay]
    and a
    ret z
    ld hl, wSeqAcc + 1
    inc [hl]                ; acc += 256
    call GetStepLen         ; de = step length
    ld a, [wSeqAcc]
    ld l, a
    ld a, [wSeqAcc + 1]
    ld h, a
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a                 ; hl = acc - len
    ret c                   ; not yet
    ld a, l
    ld [wSeqAcc], a
    ld a, h
    ld [wSeqAcc + 1], a
    ; fall through

; Play the current step on all channels, then advance.
SeqStep:
    ld a, [wSeqStep]
    ld [wSeqCur], a
    ld c, 0
.ch:
    ld a, c
    rrca
    rrca                    ; channel * 64
    ld b, a
    ld a, [wSeqStep]
    add b
    ld l, a
    ld h, HIGH(wPattern)
    ld a, [hl]
    and a
    jr z, .next
    cp CELL_OFF
    jr nz, .on
    push bc
    call NoteOff
    pop bc
    jr .next
.on:
    push bc
    call NoteOn
    pop bc
.next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .ch
    ld a, [wSeqStep]
    inc a
    ld hl, wSeqLen
    cp [hl]
    jr c, .store
    xor a                   ; reached the loop end
.store:
    ld [wSeqStep], a
    ; the view follows the playhead until the user moves the cursor
    ld a, [wFollow]
    and a
    ret z
    ld a, [wSeqCur]
    swap a
    and 15                  ; page of the step just played
    ld b, a
    ld a, [wRollPage]
    cp b
    ret z
    ld a, b
    ld [wRollPage], a
    call RollRefresh
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER         ; redraw the ruler (page number)
    ld [hl], a
    ret

; -> de = step length (8.8 frames) for wBpm. Clobbers a, hl.
GetStepLen:
    ld a, [wBpm]
    sub BPM_MIN
    ld l, a
    ld h, 0
    add hl, hl
    ld de, TempoTable
    add hl, de
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    ret

; Redraw the status line. Clobbers a, hl.
MarkSeqStatus:
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS
    ld [hl], a
    ret

; ---------------------------------------------------------------- cell helpers
; b = step -> hl = address of that cell in the selected channel. Clobbers a.
CellHL:
    ld a, [wSelCh]
    rrca
    rrca
    add b
    ld l, a
    ld h, HIGH(wPattern)
    ret

; -> a = start step of the note under the cursor, or $FF if there is none.
; The note under the cursor is the latest note-on at or before the cursor step
; that has the cursor's pitch and has not been ended by an OFF cell.
; Clobbers b, c, hl.
FindNote:
    ld a, [wRollStep]
    ld b, a
.back:
    call CellHL
    ld a, [hl]
    and a
    jr nz, .hit
    ld a, b
    and a
    jr z, .none
    dec b
    jr .back
.hit:
    cp CELL_OFF
    jr z, .none
    ld c, a
    ld a, [wRollNote]
    cp c
    jr nz, .none
    ld a, b
    ret
.none:
    ld a, $FF
    ret

; b = start step -> a = b = index of the first non-empty cell after it
; (SEQ_STEPS if there is none). Clobbers hl.
FindEnd:
.l: inc b
    ld a, b
    cp SEQ_STEPS
    jr c, .look
    ld a, SEQ_STEPS
    ld b, a
    ret
.look:
    call CellHL
    ld a, [hl]
    and a
    jr z, .l
    ld a, b
    ret

; ---------------------------------------------------------------- input
; Called every frame while the sequencer screen is shown. d = newly pressed.
SeqInput:
    ld a, [wJoy]
    ld e, a                 ; e = held
    bit PADB_SELECT, e
    jp nz, SeqSelectHeld
    bit PADB_B, d
    jr z, .noBPress
    xor a
    ld [wBUsed], a
.noBPress:
    bit PADB_A, d
    jp nz, SeqPlace
    bit PADB_A, e
    jp nz, SeqNoteEdit

    ld a, [wJoyPrev]        ; A released this frame: stop the audition note
    bit PADB_A, a
    jr z, .afterA
    push de
    ld a, [wPadCh]
    ld c, a
    call NoteOff
    pop de
.afterA:
    ld a, [wJoyPrev]        ; B released without moving: delete the note
    bit PADB_B, a
    jr z, .cursor
    bit PADB_B, e
    jr nz, .cursor
    ld a, [wBUsed]
    and a
    jr nz, .cursor
    push de
    call SeqDelete
    pop de
.cursor:
    ; fall through

; d-pad: move the cursor. Holding B jumps 4 steps / one octave.
SeqCursor:
    ld a, d
    and %11110000
    ret z                   ; no d-pad edge this frame
    xor a
    ld [wFollow], a         ; the user took over the view
    ld a, [wRollNote]
    ld [wOldNote], a
    bit PADB_B, e
    jr z, .small
    ld a, 1
    ld [wBUsed], a
.small:
    ld a, [wRollNote]
    ld b, a                 ; b = note
    ld a, [wRollStep]
    ld c, a                 ; c = step
    bit PADB_UP, d
    jr z, .noUp
    ld a, 1
    bit PADB_B, e
    jr z, .upGo
    ld a, 12
.upGo:
    add b
    cp NOTE_MAX + 1
    jr c, .upOk
    ld a, NOTE_MAX
.upOk:
    ld b, a
.noUp:
    bit PADB_DOWN, d
    jr z, .noDown
    ld a, 1
    bit PADB_B, e
    jr z, .downGo
    ld a, 12
.downGo:
    ld l, a
    ld a, b
    sub l
    jr c, .downMin
    cp NOTE_MIN
    jr nc, .downOk
.downMin:
    ld a, NOTE_MIN
.downOk:
    ld b, a
.noDown:
    bit PADB_RIGHT, d
    jr z, .noRight
    ld a, 1
    bit PADB_B, e
    jr z, .rightGo
    ld a, 4
.rightGo:
    add c
    cp SEQ_STEPS
    jr c, .rightOk
    ld a, SEQ_STEPS - 1
.rightOk:
    ld c, a
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    ld a, 1
    bit PADB_B, e
    jr z, .leftGo
    ld a, 4
.leftGo:
    ld l, a
    ld a, c
    sub l
    jr nc, .leftOk
    xor a
.leftOk:
    ld c, a
.noLeft:
    ld a, b
    ld [wRollNote], a
    ld a, c
    ld [wRollStep], a
    jp RollCursorMoved

; SELECT held: UP/DOWN = BPM +-1, LEFT/RIGHT = loop length -+16 steps.
SeqSelectHeld:
    ld a, d
    and %11110000
    ret z                   ; no d-pad edge: nothing to do
    ld a, 1
    ld [wSelUsed], a        ; SELECT acted as a modifier: its release must not switch channel
    ld a, [wBpm]
    ld b, a
    bit PADB_UP, d
    jr z, .noUp
    inc a
.noUp:
    bit PADB_DOWN, d
    jr z, .noDown
    dec a
.noDown:
    cp BPM_MIN
    jr c, .keepBpm
    cp BPM_MAX + 1
    jr nc, .keepBpm
    cp b
    jr z, .keepBpm
    ld [wBpm], a
    call MarkSeqStatus
.keepBpm:
    ld a, [wSeqLen]
    ld b, a
    bit PADB_RIGHT, d
    jr z, .noRight
    add SEQ_PAGE
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    sub SEQ_PAGE
.noLeft:
    cp SEQ_PAGE
    ret c                   ; below one page (also catches underflow)
    cp SEQ_STEPS + 1
    ret nc
    cp b
    ret z
    ld [wSeqLen], a
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER | DIRTY_STATUS
    ld [hl], a              ; ruler shows where the loop ends
    ret

; A pressed: put a one-step note at the cursor unless a note of that pitch is
; already under it. The note is auditioned either way.
SeqPlace:
    call FindNote
    cp $FF
    jr nz, .audition        ; already there: just audition it
    ld a, [wRollStep]
    ld b, a
    call CellHL
    ld a, [wRollNote]
    ld [hl], a              ; note-on
    ld a, b
    cp SEQ_STEPS - 1
    jr nc, .placed          ; last step: no room for an OFF
    inc l
    ld a, [hl]
    and a
    jr nz, .placed          ; next cell used: the note ends there
    ld [hl], CELL_OFF
.placed:
    call RollRefresh
.audition:
    ld a, [wSelCh]
    ld [wPadCh], a
    ld c, a
    ld a, [wRollNote]
    jp NoteOn

; A held (not newly pressed): LEFT/RIGHT = length, UP/DOWN = transpose.
SeqNoteEdit:
    bit PADB_RIGHT, d
    jr z, .noRight
    ld c, 1
    jr SeqLength
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    ld c, $FF
    jr SeqLength
.noLeft:
    bit PADB_UP, d
    jr z, .noUp
    ld c, 1
    jr SeqTranspose
.noUp:
    bit PADB_DOWN, d
    ret z
    ld c, $FF
    ; fall through

; c = +1 / -1: move the note under the cursor by a semitone; the cursor follows.
SeqTranspose:
    push bc
    call FindNote
    pop bc
    cp $FF
    ret z
    ld b, a
    call CellHL
    ld a, [hl]
    add c
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    ld [hl], a
    ld d, a                 ; new pitch
    ld a, [wRollNote]
    ld [wOldNote], a
    ld a, d
    ld [wRollNote], a
    call RollScrollFix
    call RollRefresh
    ld a, [wSelCh]
    ld [wPadCh], a
    ld c, a
    ld a, d
    jp NoteOn

; c = +1 / -1: lengthen / shorten the note under the cursor by one step.
; The end of a note is the next non-empty cell: an OFF marker, or another note.
SeqLength:
    push bc
    call FindNote
    pop bc
    cp $FF
    ret z
    ld d, a                 ; d = start step
    ld b, a
    call FindEnd            ; b = end step (first non-empty cell, or 64)
    bit 7, c
    jr nz, .shorten
    ; ---- lengthen: move the OFF one step right
    ld a, b
    cp SEQ_STEPS
    ret nc                  ; runs to the end of the pattern already
    call CellHL
    ld a, [hl]
    cp CELL_OFF
    ret nz                  ; touches the next note: cannot grow
    xor a
    ld [hl], a              ; remove the OFF
    ld a, b
    inc a
    cp SEQ_STEPS
    jp nc, RollRefresh      ; no room for a new OFF: the note now runs to the end
    inc l
    ld a, [hl]
    and a
    jp nz, RollRefresh      ; next cell is used: the note ends there
    ld [hl], CELL_OFF
    jp RollRefresh
.shorten:
    ld a, b
    sub d
    cp 2
    ret c                   ; already one step long
    ld a, b
    cp SEQ_STEPS
    jr nc, .noOff
    call CellHL
    ld a, [hl]
    cp CELL_OFF
    jr nz, .noOff
    xor a
    ld [hl], a              ; the old OFF goes away...
.noOff:
    dec b
    call CellHL
    ld [hl], CELL_OFF       ; ...and a new one one step earlier
    jp RollRefresh

; B tapped: delete the note under the cursor together with its OFF marker.
SeqDelete:
    call FindNote
    cp $FF
    ret z
    ld d, a
    ld b, a
    call FindEnd
    ld e, a                 ; e = end step
    ld b, d
    call CellHL
    xor a
    ld [hl], a              ; note-on gone
    ld a, e
    cp SEQ_STEPS
    jp nc, RollRefresh
    ld b, e
    call CellHL
    ld a, [hl]
    cp CELL_OFF
    jp nz, RollRefresh
    xor a
    ld [hl], a              ; its OFF marker too
    jp RollRefresh

; ---------------------------------------------------------------- data
; Demo pattern (32 steps): arpeggio, bass, hi-hat. Channel blocks are 64 bytes.
DefaultPattern:
    ; CH1 pulse: C major arpeggio, then A minor
    db 60, 0, CELL_OFF, 0,  64, 0, CELL_OFF, 0,  67, 0, CELL_OFF, 0,  64, 0, CELL_OFF, 0
    db 57, 0, CELL_OFF, 0,  60, 0, CELL_OFF, 0,  64, 0, CELL_OFF, 0,  60, 0, CELL_OFF, 0
    ds 32, 0
    ; CH2 pulse (empty)
    ds 64, 0
    ; CH3 wave: bass
    db 48, 0, 0, 0,  0, 0, 0, 0,  43, 0, 0, 0,  0, 0, 0, 0
    db 45, 0, 0, 0,  0, 0, 0, 0,  40, 0, 0, 0,  0, 0, 0, 0
    ds 32, 0
    ; CH4 noise: hats
    db 90, 0, 0, 0,  100, 0, 0, 0,  90, 0, 0, 0,  100, 0, 0, 0
    db 90, 0, 0, 0,  100, 0, 0, 0,  90, 0, 0, 0,  100, 0, 0, 0
    ds 32, 0

INCLUDE "tempo.inc"
