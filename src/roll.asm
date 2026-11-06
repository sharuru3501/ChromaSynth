; Piano-roll screen: horizontal time axis (16-step pages), vertical pitch axis.
;
;   row 0       ruler:  channel label, one beat number per 4 steps, page number
;   rows 1-16   cols 0-1: key labels (black keys inverted)
;               cols 2-17: 16 steps. Notes are bars; the cursor is an outline box.
;   row 17      status: PLAY/STOP, BPM, L = loop length, cursor pitch, cursor step
;
; Drawing is split in two so that VBlank stays short:
;   1. RenderPending (main loop, outside VBlank) renders up to 4 flagged rows
;      into the shadow tilemap wGrid and flags them for copying.
;   2. UpdateSeq (right after VBlank starts) copies up to 3 flagged rows to VRAM
; and moves the playhead sprite (OAM is only writable in VBlank too).
;      tools/headless_test.py measures that this really finishes inside VBlank.
; Anything that changes what is shown just flags rows (MarkRowRender /
; MarkAllRender); the screen catches up over the next few frames.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF COPY_BUDGET   EQU 2     ; rows copied to VRAM per frame (VBlank is only ~1140 cycles)
DEF RENDER_BUDGET EQU 4     ; rows rendered per frame

SECTION "Roll", ROM0

; ---------------------------------------------------------------- state changes
; Something in the pattern changed: rebuild the column summary, redraw all rows.
RollRefresh:
    call BuildCols
    call MarkAllRender
    jp MarkSeqStatus

; The selected channel changed: put the cursor on its first note (if it has
; one) and centre the pitch window on it, so the channel is visible at once.
RollChannelChanged:
    ld a, [wSelCh]
    rrca
    rrca
    ld b, a                 ; b = channel * 64
    ld c, 0                 ; c = step
.scan:
    ld a, b
    add c
    ld l, a
    ld h, HIGH(wPattern)
    ld a, [hl]
    and a
    jr z, .next
    cp CELL_OFF
    jr nz, .found
.next:
    inc c
    ld a, c
    cp SEQ_STEPS
    jr c, .scan
    jp RollRefresh          ; empty channel: leave the cursor where it is
.found:
    ld [wRollNote], a
    ld d, a
    ld a, c
    ld [wRollStep], a
    swap a
    and 15
    ld [wRollPage], a
    ld a, d
    add 8                   ; a few rows of headroom above the note
    cp NOTE_MAX + 1
    jr c, .hiOk
    ld a, NOTE_MAX
.hiOk:
    cp NOTE_MIN + ROLL_ROWS - 1
    jr nc, .loOk
    ld a, NOTE_MIN + ROLL_ROWS - 1
.loOk:
    ld [wRollTop], a
    jp RollRefresh

; The cursor moved (wOldNote = pitch before the move).
RollCursorMoved:
    call RollScrollFix
    jr nc, .sameView
    call BuildCols          ; new page and/or new pitch window
    call MarkAllRender
    jp MarkSeqStatus
.sameView:
    ld a, [wRollTop]        ; redraw the row the cursor left and the row it entered
    ld c, a
    ld a, [wOldNote]
    ld b, a
    ld a, c
    sub b
    cp ROLL_ROWS
    call c, MarkRowRender
    ld a, [wRollTop]
    ld c, a
    ld a, [wRollNote]
    ld b, a
    ld a, c
    sub b
    cp ROLL_ROWS
    call c, MarkRowRender
    jp MarkSeqStatus

; Scroll the view so that the cursor is visible.
; -> carry set if the page or the pitch window changed.
RollScrollFix:
    ld d, 0
    ld a, [wRollStep]
    swap a
    and 15
    ld b, a
    ld a, [wRollPage]
    cp b
    jr z, .samePage
    ld a, b
    ld [wRollPage], a
    ld d, 1
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER         ; ruler shows the page
    ld [hl], a
.samePage:
    ld a, [wRollNote]
    ld b, a
    ld a, [wRollTop]
    cp b
    jr nc, .notAbove        ; top >= note
    ld a, b
    ld [wRollTop], a        ; cursor above the window: it becomes the top row
    ld d, 1
    jr .done
.notAbove:
    sub ROLL_ROWS - 1       ; a = pitch of the bottom row
    cp b
    jr c, .done             ; bottom < note: visible
    jr z, .done             ; bottom == note: visible
    ld a, b
    add ROLL_ROWS - 1
    ld [wRollTop], a        ; cursor below the window: it becomes the bottom row
    ld d, 1
.done:
    ld a, d
    rra                     ; carry = changed
    ret

; a = row -> flag it for rendering. Clobbers a, hl.
MarkRowRender:
    add LOW(wRowRender)
    ld l, a
    ld h, HIGH(wRowRender)
    ld [hl], 1
    ret

MarkAllRender:
    ld hl, wRowRender
    ld b, ROLL_ROWS
    ld a, 1
.l: ld [hl+], a
    dec b
    jr nz, .l
    ret

; ---------------------------------------------------------------- column summary
; For the visible page of the selected channel, work out which pitch sounds in
; each of the 16 columns (wColPitch) and whether a note starts there (wColHead).
BuildCols:
    ld a, [wSelCh]
    rrca
    rrca
    ld b, a                 ; b = channel * 64
    ld a, [wRollPage]
    swap a
    ld c, a                 ; c = first step of the page
    ld d, 0                 ; d = pitch sounding when the page starts
    ld e, c
.back:                      ; look backwards for the last event before the page
    ld a, e
    and a
    jr z, .forward
    dec e
    ld a, b
    add e
    ld l, a
    ld h, HIGH(wPattern)
    ld a, [hl]
    and a
    jr z, .back
    cp CELL_OFF
    jr z, .forward          ; ended: silence
    ld d, a
.forward:
    ld e, 0                 ; e = column
.col:
    ld a, b
    add c
    ld l, a
    ld h, HIGH(wPattern)
    ld a, [hl]
    and a
    jr z, .keep
    cp CELL_OFF
    jr z, .off
    ld d, a                 ; note-on
    ld a, 1                 ; head
    jr .store
.off:
    ld d, 0
.keep:
    xor a                   ; no head
.store:
    push af
    ld a, e
    add LOW(wColPitch)
    ld l, a
    ld h, HIGH(wColPitch)
    ld [hl], d
    ld a, l
    add SEQ_PAGE
    ld l, a
    pop af
    ld [hl], a
    inc c
    inc e
    ld a, e
    cp SEQ_PAGE
    jr c, .col
    ret

; ---------------------------------------------------------------- rendering
; c = row 0..15 -> hl = wGrid + c * 20. Clobbers a, de.
GridPtr:
    ld h, 0
    ld l, c
    add hl, hl
    add hl, hl              ; 4c
    ld d, h
    ld e, l
    add hl, hl
    add hl, hl              ; 16c
    add hl, de              ; 20c
    ld de, wGrid
    add hl, de
    ret

; Render up to RENDER_BUDGET flagged rows and flag them for copying.
RenderPending:
    ld c, 0
    ld b, RENDER_BUDGET
.scan:
    ld a, c
    add LOW(wRowRender)
    ld l, a
    ld h, HIGH(wRowRender)
    ld a, [hl]
    and a
    jr z, .next
    xor a
    ld [hl], a
    ld a, l
    add ROLL_ROWS
    ld l, a
    ld [hl], 1              ; wRowDirty[row] = 1
    push bc
    call RenderRow
    pop bc
    dec b
    ret z
.next:
    inc c
    ld a, c
    cp ROLL_ROWS
    jr c, .scan
    ret

; c = row. Renders the key label and the 16 cells of that row into wGrid.
RenderRow:
    push bc
    ld a, [wRollTop]
    sub c
    ld b, a                 ; b = pitch of this row
    ld a, b
    ld [wRRPitch], a
    ; --- cursor column for this row ($FF if the cursor is not on it / not on this page)
    ld a, [wRollNote]
    cp b
    jr nz, .noCursor
    ld a, [wRollPage]
    swap a
    ld d, a
    ld a, [wRollStep]
    sub d                   ; column = step - page start
    cp SEQ_PAGE
    jr c, .haveCur
.noCursor:
    ld a, $FF
.haveCur:
    ld [wRRCur], a
    ; --- pitch class (e) and octave number (d)
    ld a, b
    ld d, 0
.mod:
    cp 12
    jr c, .modDone
    sub 12
    inc d
    jr .mod
.modDone:
    ld e, a                 ; e = pitch class
    ; --- black key?
    ld hl, BlackKeys
    ld c, e
    ld b, 0
    add hl, bc
    ld a, [hl]
    ld [wRRBlack], a
    ; --- key label: letter + ('#' | octave digit for C | blank)
    pop bc                  ; c = row again
    push de                 ; keep pitch class / octave
    call GridPtr            ; hl = dest (clobbers de)
    pop de
    push hl
    ld a, e
    add a
    ld e, a                 ; e = pitch class * 2
    ld c, a
    ld b, 0
    ld hl, KeyLabels
    add hl, bc
    ld a, [hl+]             ; letter tile
    ld b, a
    ld a, [hl]              ; second tile: '#' or blank
    ld c, a
    ld a, e
    and a
    jr nz, .notC
    ld a, d                 ; C: show the octave (MIDI n/12 - 1)
    dec a
    add '0' - 32
    ld c, a
.notC:
    pop hl
    ld a, [wRRBlack]
    and a
    jr z, .whiteKey
    ld a, b
    add TILE_INV
    ld b, a
    ld a, c
    add TILE_INV
    ld c, a
.whiteKey:
    ld a, b
    ld [hl+], a
    ld a, c
    ld [hl+], a
    ; --- 16 cells
    ld e, 0
.cell:
    ld a, e
    add LOW(wColPitch)
    ld c, a
    push hl
    ld h, HIGH(wColPitch)
    ld l, c
    ld b, [hl]              ; sounding pitch in this column
    ld a, l
    add SEQ_PAGE
    ld l, a
    ld d, [hl]              ; 1 = note head
    pop hl
    ld a, [wRRPitch]
    cp b
    jr nz, .emptyCell
    ld a, [wRRCur]          ; a note bar
    cp e
    ld a, T_CUR_NOTE
    jr z, .put
    ld a, d
    and a
    ld a, T_NOTE_BODY
    jr z, .put
    ld a, T_NOTE_HEAD
    jr .put
.emptyCell:
    ld a, [wRRCur]
    cp e
    ld a, T_CUR_EMP
    jr z, .put
    ld a, e                 ; background: beat column? black-key row?
    and 3
    jr nz, .noBeat
    ld a, 2
    jr .bg
.noBeat:
    xor a
.bg:
    ld b, a
    ld a, [wRRBlack]
    add b
    add T_EMP_W
.put:
    ld [hl+], a
    inc e
    ld a, e
    cp SEQ_PAGE
    jr c, .cell
    xor a
    ld [hl+], a             ; cols 18-19: blank
    ld [hl], a
    ret

; Letter tile and sharp tile for each pitch class (tile = ASCII - 32).
KeyLabels:
    db 'C' - 32, 0,  'C' - 32, '#' - 32,  'D' - 32, 0,  'D' - 32, '#' - 32
    db 'E' - 32, 0,  'F' - 32, 0,  'F' - 32, '#' - 32,  'G' - 32, 0
    db 'G' - 32, '#' - 32,  'A' - 32, 0,  'A' - 32, '#' - 32,  'B' - 32, 0
BlackKeys:
    db 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0

; ---------------------------------------------------------------- copy to VRAM
; c = row -> copy that row of wGrid to the screen. Clobbers a, b, hl, de.
RollCopyRow:
    call GridPtr            ; hl = source
    push hl
    ld h, 0
    ld l, c
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl              ; row * 32
    ld de, _SCRN0 + ROLL_ROW0 * 32
    add hl, de
    ld d, h
    ld e, l                 ; de = destination
    pop hl
    REPT 20                 ; unrolled: this runs inside VBlank
        ld a, [hl+]
        ld [de], a
        inc de
    ENDR
    ret

; ---------------------------------------------------------------- screen
; Called with the LCD off: build the whole roll screen.
BuildSeq:
    ld hl, _SCRN0 + 17 * 32 + 9
    ld a, 'L' - 32
    ld [hl], a
    call BuildCols
    ld c, 0
.render:
    push bc
    call RenderRow
    pop bc
    push bc
    call RollCopyRow
    pop bc
    inc c
    ld a, c
    cp ROLL_ROWS
    jr c, .render
    ld hl, wRowRender       ; nothing left to do for the flag arrays
    ld b, ROLL_ROWS * 2
    xor a
.clr:
    ld [hl+], a
    dec b
    jr nz, .clr
    call DrawRuler
    call DrawSeqStatus
    ; playhead: 16 sprites stacked down the grid, tile + attribute set once
    ld hl, _OAMRAM + 2
    ld b, ROLL_ROWS
.oam:
    ld a, T_PLAYHEAD
    ld [hl+], a
    xor a
    ld [hl+], a
    inc hl
    inc hl
    dec b
    jr nz, .oam
    xor a
    ld [wDirty], a
    ret

; Right after VBlank starts: one cheap job per frame, plus the playhead.
UpdateSeq:
    call UpdatePlayhead     ; carry set if it touched OAM
    ld a, 0
    rla
    ld e, a                 ; e = 1 if the playhead moved this frame
    and a
    jr nz, .rows            ; it did: leave the ruler/status redraw for the next frame
    ld a, [wDirty]
    bit 5, a
    jr z, .noRuler
    res 5, a
    ld [wDirty], a
    jp DrawRuler
.noRuler:
    bit 4, a
    jr z, .rows
    res 4, a
    ld [wDirty], a
    jp DrawSeqStatus
.rows:
    ld a, COPY_BUDGET       ; one row less when the playhead used up some of VBlank
    sub e
    ld b, a
    ld c, 0
.scan:
    ld a, c
    add LOW(wRowDirty)
    ld l, a
    ld h, HIGH(wRowDirty)
    ld a, [hl]
    and a
    jr z, .next
    xor a
    ld [hl], a
    push bc
    call RollCopyRow
    pop bc
    dec b
    ret z
.next:
    inc c
    ld a, c
    cp ROLL_ROWS
    jr c, .scan
    ret

; Move the playhead sprites to the column of the step that was played last. -> carry set if OAM was written.
; (hidden while stopped or when that step is on another page). Moving between
; two visible columns only rewrites the 16 X coordinates; Y is written when the
; line appears (and zeroed when it disappears).
UpdatePlayhead:
    ld a, [wSeqPlay]
    and a
    jr z, .hide
    ld a, [wSeqCur]
    ld b, a
    swap a
    and 15
    ld c, a
    ld a, [wRollPage]
    cp c
    jr nz, .hide
    ld a, b
    and 15                  ; column
    jr .show
.hide:
    ld a, $FF
.show:
    ld hl, wPlayCol
    cp [hl]
    jr nz, .changed
    and a                   ; nothing changed: carry clear
    ret
.changed:
    ld b, [hl]              ; b = previous column ($FF = was hidden)
    ld [hl], a
    cp $FF
    jr z, .hideAll
    add a
    add a
    add a
    add (ROLL_COL0 * 8) + 8 ; X = column * 8 + grid left edge + OAM offset
    ld c, a
    ld a, b
    cp $FF
    jr z, .appear
    ld hl, _OAMRAM + 1      ; moved: X only
    ld b, ROLL_ROWS
.moveX:
    ld [hl], c
    inc l
    inc l
    inc l
    inc l
    dec b
    jr nz, .moveX
    scf
    ret
.appear:
    ld hl, _OAMRAM
    ld b, ROLL_ROWS
    ld d, ROLL_ROW0 * 8 + 16
.appearLoop:
    ld a, d
    ld [hl+], a             ; Y
    ld a, c
    ld [hl+], a             ; X
    inc l
    inc l
    ld a, d
    add 8
    ld d, a
    dec b
    jr nz, .appearLoop
    scf
    ret
.hideAll:
    ld hl, _OAMRAM
    ld b, ROLL_ROWS
    xor a
.hideLoop:
    ld [hl], a              ; Y = 0: off screen
    inc l
    inc l
    inc l
    inc l
    dec b
    jr nz, .hideLoop
    scf
    ret

; Ruler: channel label, beat numbers (a dot where the loop has ended), page.
DrawRuler:
    ld hl, _SCRN0
    ld de, ChanLabels
    ld a, [wSelCh]
    add a
    add e
    ld e, a
    jr nc, .labelPtr
    inc d
.labelPtr:
    ld a, [de]
    sub 32 - TILE_INV       ; inverted: the label reads as a tab
    ld [hl+], a
    inc de
    ld a, [de]
    sub 32 - TILE_INV
    ld [hl+], a
    ld c, 0
.beat:
    ld a, [wRollPage]
    add a
    add a
    add c
    ld b, a                 ; b = beat number
    add a
    add a
    ld d, a                 ; d = first step of that beat
    ld a, [wSeqLen]
    cp d
    jr c, .past
    jr z, .past
    ld a, b
    call NibbleTile
    jr .put
.past:
    ld a, '.' - 32
.put:
    ld [hl+], a
    xor a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    inc c
    ld a, c
    cp 4
    jr c, .beat
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wRollPage]
    inc a
    add '0' - 32
    ld [hl], a
    ret

ChanLabels: db "1P", "2P", "3W", "4N"

; Status: PLAY/STOP  bpm  Llen  note  step
DrawSeqStatus:
    ld hl, _SCRN0 + 17 * 32
    ld de, sStop
    ld a, [wSeqPlay]
    and a
    jr z, .state
    ld de, sPlay
.state:
    call DrawString
    ld hl, _SCRN0 + 17 * 32 + 5
    ld a, [wBpm]
    call DrawDec3
    ld hl, _SCRN0 + 17 * 32 + 10
    ld a, [wSeqLen]
    call DrawDec3
    ld hl, _SCRN0 + 17 * 32 + 14
    ld a, [wRollNote]
    call DrawNoteName
    ld hl, _SCRN0 + 17 * 32 + 17
    ld a, [wRollStep]
    inc a                   ; shown 1-based
    jp DrawDec3
