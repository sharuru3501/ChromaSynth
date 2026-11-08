; Sequencer engine + piano-roll editing input. Design notes: docs/ROLL_DESIGN.md.
;
; Time base: 12 ticks per beat. Pattern cells (wPattern[channel * 256 + tick]):
; 0 = empty, CELL_OFF = note off, anything else = MIDI note (note-on). A note
; sounds from its note-on cell until the next non-empty cell, which is how the
; piano roll draws its length.
;
; Timing: every frame wSeqAcc += 256 (8.8 fixed point, 1.0 = one frame). When it
; reaches the tick length for the current BPM (TempoTable) one tick is played.
; A tick always lasts more than one frame, so at most one tick fires per frame.
;
; The roll shows up to 16 columns per page; a "grid division" (DivTicks) says how
; many ticks one column covers (1/4, 1/4T, 1/8, 1/8T, 1/16, 1/16T, 1/48). A page
; always covers whole beats (DivSpan) so the bars stay put when the division changes.
; The cursor sits on a cell (wRollCell) = tick wRollTick = cell * wDivTicks.
;
; Piano-roll controls (see SeqInput):
;   d-pad            move cursor one cell / semitone (B held: 4 cells / octave)
;   B+A              next grid division (B first, or both together)
;   A                place a one-cell note at the cursor (and audition it)
;   A + LEFT/RIGHT   shorten / lengthen the note under the cursor by one cell
;   A + UP/DOWN      transpose the note under the cursor
;   B (tap)          delete the note under the cursor
;   SELECT + UP/DOWN BPM +-1      SELECT + LEFT/RIGHT  loop length -+1 bar
;   SELECT tap       next channel (handled in joy.asm)
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Sequencer", ROM0

; ---------------------------------------------------------------- playback
; Start/stop (SELECT+START on any screen).
SeqToggle:
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_IN
    ret z                   ; following the DAW: start/stop come over the link
    ld a, [wSeqPlay]
    xor 1
    ld [wSeqPlay], a
    jr z, .stop
    xor a
    ld [wSeqTick], a
    call SongRestart        ; from the first chain step (or the edited pattern in loop mode)
    ld a, 1
    ld [wFollow], a         ; the roll scrolls along with the playhead
    call GetTickLen
    dec d                   ; acc = len - 1 frame: the first tick fires next frame
    ld a, e
    ld [wSeqAcc], a
    ld a, d
    ld [wSeqAcc + 1], a
    ld a, $FA               ; MIDI start (only sent when SYNC_OUT)
    call MidiOutSync
    jp MarkSeqStatus
.stop:
    call SeqSilence
    ld a, $FC               ; MIDI stop
    call MidiOutSync
    jp MarkSeqStatus

; Release every channel (and tell the bridge about the notes that were sounding).
SeqSilence:
    ld c, 0
.l: push bc
    call NoteOutOff
    pop bc
    push bc
    call NoteOff
    pop bc
    inc c
    ld a, c
    cp NUM_CH
    jr c, .l
    ret

; Called once per frame. Internal clock: the 8.8 accumulator below. SYNC_IN: the
; DAW's clock (MidiRealtime counts the ticks, at most 4 waiting).
SeqTick:
    ld a, [wSeqPlay]
    and a
    ret z
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_IN
    jr nz, .internal
.external:                  ; one tick per clock byte that came in over the link
    ld a, [wExtTicks]
    and a
    ret z
    dec a
    ld [wExtTicks], a
    call SeqStep
    jr .external
.internal:
    ld hl, wSeqAcc + 1
    inc [hl]                ; acc += 256
    call GetTickLen         ; de = tick length
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

; Play the current tick on all channels, then advance.
SeqStep:
    ld a, [wSeqTick]
    ld [wSeqCur], a
    ld a, $F8               ; one MIDI clock per tick (only sent when SYNC_OUT)
    call MidiOutSync
    ld c, 0
.ch:
    ld a, [wSeqCur]
    ld l, a
    ld a, [wPlayBase]
    add c
    ld h, a
    ld a, [hl]
    and a
    jr z, .next
    cp CELL_OFF
    jr nz, .on
    push bc
    call NoteOutOff
    call NoteOff
    pop bc
    jr .next
.on:
    push bc
    ld d, a
    call NoteOutOn          ; (SYNC_OUT: note-off of the old note, then the note-on)
    ld a, d
    call NoteOn
    pop bc
.next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .ch
    ld a, [wSeqTick]
    inc a
    ld hl, wSeqLen
    cp [hl]
    jr c, .store
    xor a                   ; reached the loop end
    ld [wSeqTick], a
    ld a, [wSongMode]
    and a
    call nz, SongNext       ; the chain goes on with its next pattern
    ld a, [wSeqTick]
.store:
    ld [wSeqTick], a
    ld a, [wFollow]         ; the view follows the playhead until the user moves the cursor
    and a
    ret z
    jp RollFollow

; -> de = tick length (8.8 frames) for wBpm. Clobbers a, hl.
GetTickLen:
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

; Ask for the status line to be rebuilt (outside VBlank) and copied. Clobbers a.
MarkSeqStatus:
    ld a, 1
    ld [wStatusRender], a
    ret

; ---------------------------------------------------------------- cell helpers
; b = tick -> hl = address of that cell in the selected channel. Clobbers a.
CellHL:
    ld a, [wEditBase]
    ld h, a
    ld a, [wSelCh]
    add h
    ld h, a
    ld l, b
    ret

; -> a = tick of the note-on under the cursor cell, or $FF if there is none.
; Looks for a note-on of the cursor's pitch inside the cell, then for a note of
; that pitch that is still sounding when the cell starts. Clobbers b, c, e, hl.
FindNote:
    ld a, [wRollNote]
    ld e, a                 ; e = cursor pitch
    ld a, [wRollTick]
    ld b, a
    ld a, [wDivTicks]
    ld c, a                 ; c = ticks left in the cell
.inside:
    call CellHL
    ld a, [hl]
    cp e
    jr z, .found
    inc b
    dec c
    jr nz, .inside
    ld a, [wRollTick]
    ld b, a
.back:                      ; the last event at or before the cell start
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
    cp e
    jr nz, .none
.found:
    ld a, b
    ret
.none:
    ld a, $FF
    ret

; b = start tick -> a = b = tick of the first non-empty cell after it
; (SEQ_TICKS if there is none). Clobbers hl.
FindEnd:
.l: inc b
    ld a, b
    cp SEQ_TICKS
    jr c, .look
    ld a, SEQ_TICKS
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
    bit PADB_A, e
    jr nz, .chord           ; B pressed while A is held
    xor a
    ld [wBUsed], a
    jr .noBPress
.chord:
    ld a, 1
    ld [wBUsed], a
    jp SeqCycleDiv
.noBPress:
    bit PADB_A, d
    jr z, .noAPress
    bit PADB_B, e
    jp z, SeqPlace
    ld a, 1                 ; A pressed while B is held
    ld [wBUsed], a
    jp SeqCycleDiv
.noAPress:
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
    ld a, [wJoyPrev]        ; B released without moving or chording: delete the note
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

; d-pad: move the cursor. Holding B jumps 4 cells / one octave.
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
    ld a, 1
    bit PADB_B, e
    jr z, .cells
    ld a, 4
.cells:
    ld c, a                 ; c = cells to move horizontally
    bit PADB_RIGHT, d
    jr z, .noRight
    call CellRight
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    call CellLeft
.noLeft:
    ld a, b
    ld [wRollNote], a
    jp RollCursorMoved

; c = cells: move the cursor right, stopping at the last cell. Keeps b, c, d, e.
CellRight:
    push bc
    push de
    ld a, [wDiv]
    ld e, a
    ld d, 0
    ld hl, DivCells
    add hl, de
    ld a, [hl]
    dec a
    ld e, a                 ; e = last cell
.l: ld a, [wRollCell]
    cp e
    jr nc, .done
    inc a
    ld [wRollCell], a
    ld a, [wDivTicks]
    ld b, a
    ld a, [wRollTick]
    add b
    ld [wRollTick], a
    dec c
    jr nz, .l
.done:
    pop de
    pop bc
    ret

; c = cells: move the cursor left, stopping at cell 0. Keeps b, c, d, e.
CellLeft:
    push bc
.l: ld a, [wRollCell]
    and a
    jr z, .done
    dec a
    ld [wRollCell], a
    ld a, [wDivTicks]
    ld b, a
    ld a, [wRollTick]
    sub b
    ld [wRollTick], a
    dec c
    jr nz, .l
.done:
    pop bc
    ret

; a = division index -> wDiv, wDivTicks, wPageCols, wPageSpan. Clobbers a, de, hl.
SetDivision:
    ld [wDiv], a
    ld e, a
    ld d, 0
    ld hl, DivTicks
    add hl, de
    ld a, [hl]
    ld [wDivTicks], a
    ld hl, DivCols
    add hl, de
    ld a, [hl]
    ld [wPageCols], a
    ld hl, DivSpan
    add hl, de
    ld a, [hl]
    ld [wPageSpan], a
    ret

; B+A: next grid division. The cursor keeps its tick (snapped down to the new
; grid) and the page keeps the same bar: pages start on beat boundaries.
SeqCycleDiv:
    ld a, [wDiv]
    inc a
    cp NUM_DIVS
    jr c, .ok
    xor a
.ok:
    call SetDivision
    ld a, [wDivTicks]
    ld c, a                 ; c = ticks per cell
    ld a, [wRollTick]
    ld b, 0                 ; b = cell = tick / c
.div:
    cp c
    jr c, .divDone
    sub c
    inc b
    jr .div
.divDone:
    ld d, a                 ; remainder
    ld a, [wRollTick]
    sub d
    ld [wRollTick], a
    ld a, b
    ld [wRollCell], a
    call RollPageFromCell
    jp RollRefreshAll

; SELECT held: UP/DOWN = BPM +-1, LEFT/RIGHT = loop length -+1 bar.
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
    add TICKS_PER_BAR
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    sub TICKS_PER_BAR
.noLeft:
    cp TICKS_PER_BAR
    ret c                   ; below one bar (also catches underflow)
    cp SEQ_TICKS + 1
    ret nc
    cp b
    ret z
    ld [wSeqLen], a
    jp RollRefreshAll       ; the ruler shows where the loop ends

; A pressed: put a one-cell note at the cursor unless a note of that pitch is
; already under it. The note is auditioned either way.
SeqPlace:
    call FindNote
    cp $FF
    jr nz, .audition        ; already there: just audition it
    ld a, [wRollTick]
    ld b, a
    call CellHL
    ld a, [wRollNote]
    ld [hl], a              ; note-on
    ld a, [wDivTicks]
    add b                   ; a = end of the cell
    cp SEQ_TICKS
    jr nc, .placed          ; last cell: no room for an OFF
    ld b, a
    call CellHL
    ld a, [hl]
    and a
    jr nz, .placed          ; something already there: the note ends at it
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
    jr c, .moved
    call RollRefresh        ; same view: only the changed rows
    jr .status
.moved:
    call RollRefreshAll     ; the window scrolled with the note
.status:
    call MarkSeqStatus      ; the cursor pitch is shown in the status line
    ld a, [wSelCh]
    ld [wPadCh], a
    ld c, a
    ld a, d
    jp NoteOn

; c = +1 / -1: lengthen / shorten the note under the cursor by one cell.
; The end of a note is the next non-empty cell: an OFF marker, or another note.
SeqLength:
    push bc
    call FindNote
    pop bc
    cp $FF
    ret z
    ld d, a                 ; d = start tick
    ld b, a
    call FindEnd            ; b = end tick (first non-empty cell, or 192)
    bit 7, c
    jr nz, .shorten
    ; ---- lengthen: move the OFF one cell to the right
    ld a, b
    cp SEQ_TICKS
    ret nc                  ; runs to the end of the pattern already
    call CellHL
    ld a, [hl]
    cp CELL_OFF
    ret nz                  ; touches the next note: cannot grow
    xor a
    ld [hl], a              ; remove the old OFF
    ld e, b                 ; e = old end
    call FindEnd            ; b = next event after it (or 192)
    ld a, [wDivTicks]
    add e                   ; a = new end
    cp b
    jp nc, RollRefresh      ; reaches the next event / the end: the note runs into it
    ld b, a
    call CellHL
    ld [hl], CELL_OFF
    jp RollRefresh
.shorten:
    ld a, [wDivTicks]
    ld c, a                 ; c = one cell
    ld a, b
    sub d                   ; a = current length
    cp c
    ret c
    ret z                   ; already one cell long
    ld a, b
    cp SEQ_TICKS
    jr nc, .noOff
    call CellHL
    ld a, [hl]
    cp CELL_OFF
    jr nz, .noOff
    xor a
    ld [hl], a              ; the old OFF goes away...
.noOff:
    ld a, b
    sub c                   ; ...and a new one a cell earlier
    ld b, a
    call CellHL
    ld [hl], CELL_OFF
    jp RollRefresh

; B tapped: delete the note under the cursor together with its OFF marker.
SeqDelete:
    call FindNote
    cp $FF
    ret z
    ld d, a
    ld b, a
    call FindEnd
    ld e, a                 ; e = end tick
    ld b, d
    call CellHL
    xor a
    ld [hl], a              ; note-on gone
    ld a, e
    cp SEQ_TICKS
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
INCLUDE "tempo.inc"         ; TempoTable
INCLUDE "divs.inc"          ; DivTicks, DivCells, DivLabels, PlayXPtrs
INCLUDE "pattern.inc"       ; DefaultPattern
