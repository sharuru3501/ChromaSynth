; Step sequencer: one 16-step pattern x 4 channels.
;
; Timing: every frame wSeqAcc += 256 (8.8 fixed point, 1.0 = one frame). When it
; reaches the step length for the current BPM (TempoTable, frames per 16th
; note) one step is played. Step length is always > 3 frames, so at most one
; step fires per frame.
;
; Sequencer screen controls (see SeqInput):
;   d-pad          move cursor            A       insert / pick up note (audition)
;   A + d-pad      UP/DOWN +-1, L/R +-12  B       empty -> OFF -> empty, note -> empty
;   SELECT + d-pad BPM (UP/DOWN +-1, LEFT/RIGHT +-10)
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
    ld a, [wSeqCur]
    call MarkSeqRow
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
    ld a, [wSeqCur]
    call MarkSeqRow         ; old playhead row
    ld a, [wSeqStep]
    ld [wSeqCur], a
    call MarkSeqRow         ; new playhead row
    ld c, 0
.ch:
    ld a, c
    swap a
    ld b, a
    ld a, [wSeqStep]
    add b
    add LOW(wPattern)
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
    and SEQ_STEPS - 1
    ld [wSeqStep], a
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

; ---------------------------------------------------------------- dirty flags
; a = row 0..15 -> redraw that row. Preserves everything but a.
MarkSeqRow:
    push bc
    push de
    push hl
    ld b, a
    and 7
    ld e, a
    ld d, 0
    ld hl, DirtyBits
    add hl, de
    ld c, [hl]              ; bit mask
    ld hl, wDirtySeq
    bit 3, b
    jr z, .lo
    inc hl
.lo:
    ld a, [hl]
    or c
    ld [hl], a
    pop hl
    pop de
    pop bc
    ret

; Redraw the status line. Clobbers a, hl.
MarkSeqStatus:
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS
    ld [hl], a
    ret

; -> hl = address of the cursor cell. Clobbers a.
SeqCellPtr:
    ld a, [wSeqCh]
    swap a
    ld l, a
    ld a, [wSeqRow]
    add l
    add LOW(wPattern)
    ld l, a
    ld h, HIGH(wPattern)
    ret

; ---------------------------------------------------------------- input
; Called every frame while the sequencer screen is shown. d = newly pressed.
SeqInput:
    ld a, [wJoy]
    ld e, a                 ; e = held
    bit PADB_SELECT, e
    jr nz, SeqBpm
    bit PADB_A, d
    jp nz, SeqPlace
    bit PADB_A, e
    jp nz, SeqModify

    ld a, [wJoyPrev]        ; A released this frame: stop the audition note
    bit PADB_A, a
    jr z, .moveRow
    ld a, [wPadCh]
    ld c, a
    push de
    call NoteOff
    pop de
.moveRow:
    ld a, [wSeqRow]
    ld b, a                 ; old row
    bit PADB_UP, d
    jr z, .nu
    dec a
.nu:
    bit PADB_DOWN, d
    jr z, .nd
    inc a
.nd:
    and SEQ_STEPS - 1
    ld [wSeqRow], a
    cp b
    jr z, .moveCh
    call MarkSeqRow         ; new row
    ld a, b
    call MarkSeqRow         ; old row
.moveCh:
    ld a, [wSeqCh]
    ld b, a
    bit PADB_LEFT, d
    jr z, .nl
    dec a
.nl:
    bit PADB_RIGHT, d
    jr z, .nr
    inc a
.nr:
    and NUM_CH - 1
    ld [wSeqCh], a
    cp b
    jr z, .chSame
    ld a, [wSeqRow]
    call MarkSeqRow
.chSame:
    bit PADB_B, d
    ret z
    ; B: empty -> OFF, anything else -> empty
    call SeqCellPtr
    ld a, [hl]
    and a
    jr nz, .toEmpty
    ld a, CELL_OFF
    jr .write
.toEmpty:
    xor a
.write:
    ld [hl], a
    ld a, [wSeqRow]
    jp MarkSeqRow

; SELECT held: BPM +-1 (UP/DOWN), +-10 (RIGHT/LEFT)
SeqBpm:
    ld a, [wBpm]
    ld e, a
    bit PADB_UP, d
    jr z, .b1
    inc a
.b1:
    bit PADB_DOWN, d
    jr z, .b2
    dec a
.b2:
    bit PADB_RIGHT, d
    jr z, .b3
    add 10
.b3:
    bit PADB_LEFT, d
    jr z, .b4
    sub 10
.b4:
    cp BPM_MIN
    ret c
    cp BPM_MAX + 1
    ret nc
    cp e
    ret z
    ld [wBpm], a
    jp MarkSeqStatus

; A pressed: fill an empty/OFF cell with the current note, or pick up the
; note already there. Either way the note is auditioned.
SeqPlace:
    call SeqCellPtr
    ld a, [hl]
    and a
    jr z, .put
    cp CELL_OFF
    jr z, .put
    jr .have
.put:
    ld a, [wSeqNote]
    ld [hl], a
.have:
    ld [wSeqNote], a
    ld b, a
    ld a, [wSeqRow]
    call MarkSeqRow
    call MarkSeqStatus
    ld a, [wSeqCh]
    ld [wPadCh], a
    ld c, a
    ld a, b
    jp NoteOn

; A held: UP/DOWN +-1 semitone, LEFT/RIGHT +-octave on the cell's note.
SeqModify:
    ld a, [wSeqNote]
    ld e, a
    bit PADB_UP, d
    jr z, .m1
    inc a
.m1:
    bit PADB_DOWN, d
    jr z, .m2
    dec a
.m2:
    bit PADB_RIGHT, d
    jr z, .m3
    add 12
.m3:
    bit PADB_LEFT, d
    jr z, .m4
    sub 12
.m4:
    cp NOTE_MIN
    ret c
    cp NOTE_MAX + 1
    ret nc
    cp e
    ret z
    ld b, a                 ; new note
    call SeqCellPtr
    ld a, [hl]
    and a
    ret z
    cp CELL_OFF
    ret z
    ld a, b
    ld [hl], a
    ld [wSeqNote], a
    ld a, [wSeqRow]
    call MarkSeqRow
    call MarkSeqStatus
    ld a, [wSeqCh]
    ld c, a
    ld a, b
    jp NoteOn

; ---------------------------------------------------------------- data
; Demo pattern so there is something to hear: arpeggio, bass, hi-hat.
DefaultPattern:
    ; CH1 pulse
    db 60, 0, CELL_OFF, 0,  64, 0, CELL_OFF, 0,  67, 0, CELL_OFF, 0,  64, 0, CELL_OFF, 0
    ; CH2 pulse (empty)
    db 0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0
    ; CH3 wave: bass
    db 48, 0, 0, 0,  0, 0, 0, 0,  43, 0, 0, 0,  0, 0, 0, 0
    ; CH4 noise: hats
    db 90, 0, 0, 0,  100, 0, 0, 0,  90, 0, 0, 0,  100, 0, 0, 0

INCLUDE "tempo.inc"
