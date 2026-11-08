; Piano-roll screen: horizontal time axis (16 columns per page), vertical pitch axis.
; Design notes and budgets: docs/ROLL_DESIGN.md.
;
;   row 0       ruler:  channel label, beat numbers over the beat columns, page
;   rows 1-16   cols 0-1: key labels (black keys inverted)
;               cols 2-17: 16 grid columns of wDivTicks ticks each. Notes are
;               bars; the cursor is an outline box.
;   row 17      status: PLAY/STOP, BPM, grid division, cursor pitch
;
; Drawing is split in two so that VBlank stays short:
;   1. RenderPending (main loop, outside VBlank) renders up to 8 flagged rows
;      into the shadow tilemap wGrid, and builds the status line into wStatusBuf
;      (the ruler is built by BuildCols into wRulerBuf).
;   2. UpdateSeq (right after VBlank starts) only COPIES: up to 2 grid rows
;      (1 when the playhead moved), or the ruler, or the status line, and moves
;      the playhead sprite (OAM is only writable in VBlank too).
; Anything that changes what is shown just flags rows (MarkRowRender /
; MarkAllRender); the screen catches up over the next few frames.
; tools/headless_test.py measures that UpdateUI really finishes inside VBlank.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF COPY_BUDGET   EQU 2     ; rows copied to VRAM per frame (VBlank is only ~1140 cycles)
DEF RENDER_BUDGET EQU 8     ; rows rendered per frame (outside VBlank, ~750 cycles each)

SECTION "Roll", ROM0

; ---------------------------------------------------------------- state changes
; The pattern changed under the cursor (place / delete / length / transpose):
; rebuild the column summary and redraw only the rows whose content changed
; (the old and the new pitch of every changed column, plus the cursor row).
; This keeps the delay between a button press and the screen to a few frames.
RollRefresh:
    ld hl, wColPitch        ; keep the old summary to compare against
    ld de, wColOld
    ld b, SEQ_PAGE * 2
.save:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .save
    call BuildCols
    ld c, 0
.col:
    ld a, c
    add LOW(wColPitch)
    ld l, a
    ld h, HIGH(wColPitch)
    ld b, [hl]              ; new pitch
    ld a, l
    add SEQ_PAGE
    ld l, a
    ld d, [hl]              ; new flags
    ld a, c
    add LOW(wColOld)
    ld l, a
    ld h, HIGH(wColOld)
    ld e, [hl]              ; old pitch
    ld a, l
    add SEQ_PAGE
    ld l, a
    ld a, [hl]              ; old flags
    cp d
    jr nz, .changed
    ld a, e
    cp b
    jr z, .same
.changed:
    ld a, b
    call MarkPitchRow
    ld a, e
    call MarkPitchRow
.same:
    inc c
    ld a, c
    cp SEQ_PAGE
    jr c, .col
    ld a, [wRollNote]       ; the cursor tile depends on what is under it
    jp MarkPitchRow

; a = pitch (0 = none) -> flag its row for rendering if it is inside the window.
; Clobbers a, hl.
MarkPitchRow:
    and a
    ret z
    ld l, a
    ld a, [wRollTop]
    sub l
    cp ROLL_ROWS
    ret nc
    jp MarkRowRender

; Everything may have changed (new page, new pitch window, other channel, other
; division, loop length, load): rebuild the column summary and ruler, redraw all
; rows and the status line.
RollRefreshAll:
    call BuildCols
    call MarkAllRender
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER         ; copy the ruler to VRAM
    ld [hl], a
    jp MarkSeqStatus

; The selected channel changed: put the cursor on its first note (if it has
; one) and centre the pitch window on it, so the channel is visible at once.
RollChannelChanged:
    ld a, [wSelCh]
    add a
    add HIGH(wPatterns)     ; the channel's first page (segment 0)
    ld b, a
    xor a
    ld [wRCSeg], a
.seg:
    ld c, 0                 ; c = tick
.scan:
    ld a, [wRCSeg]
    add b
    ld h, a
    ld l, c
    ld a, [hl]
    and a
    jr z, .next
    cp CELL_OFF
    jr nz, .found
.next:
    inc c
    ld a, c
    cp SEQ_TICKS
    jr c, .scan
    ld a, [wRCSeg]          ; the next segment
    inc a
    ld [wRCSeg], a
    cp NUM_SEGS
    jr c, .seg
    jp RollRefreshAll       ; empty channel: leave the cursor where it is
.found:
    ld [wRollNote], a
    ld d, a
    ld a, [wRCSeg]
    ld [wRollSeg], a
    ld a, d
    ld d, a                 ; d = pitch
    ld a, [wDivTicks]
    ld e, a
    ld a, c
    ld b, 0                 ; b = cell = tick / div
.div:
    cp e
    jr c, .divDone
    sub e
    inc b
    jr .div
.divDone:
    ld h, a                 ; remainder
    ld a, c
    sub h
    ld [wRollTick], a       ; snapped to the grid
    ld a, b
    ld [wRollCell], a
    call RollPageFromCell
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
    jp RollRefreshAll

; The cursor moved (wOldNote = pitch before the move).
RollCursorMoved:
    call RollScrollFix
    jp c, RollRefreshAll    ; new page and/or new pitch window
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
    ld a, [wRollNote]       ; the status line shows the cursor pitch
    ld b, a
    ld a, [wOldNote]
    cp b
    ret z
    jp MarkSeqStatus

; Scroll the view so that the cursor is visible.
; -> carry set if the page or the pitch window changed.
RollScrollFix:
    ld d, 0
    ld a, [wRollSeg]
    ld hl, wPageSeg
    cp [hl]
    jr nz, .newPage         ; another segment
    ld a, [wRollCell]
    ld b, a
    ld a, [wPageCell]
    ld c, a
    ld a, b
    cp c
    jr c, .newPage          ; before the page
    ld a, [wPageCols]
    add c                   ; first cell after the page
    ld c, a
    ld a, b
    cp c
    jr c, .samePage         ; inside the page
.newPage:
    call RollPageFromCell
    ld d, 1
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

; a = page index -> wRollPage, wPageTick = page * span, wPageCell = page * cols.
; Clobbers a, b, c.
RollSetPage:
    ld [wRollPage], a
    ld b, a
    ld a, [wPageSpan]
    ld c, a
    xor a
    inc b
.tick:
    dec b
    jr z, .tickDone
    add c
    jr .tick
.tickDone:
    ld [wPageTick], a
    ld a, [wRollPage]
    ld b, a
    ld a, [wPageCols]
    ld c, a
    xor a
    inc b
.cell:
    dec b
    jr z, .cellDone
    add c
    jr .cell
.cellDone:
    ld [wPageCell], a
    ret

; Show the page that contains the cursor cell: page = wRollCell / wPageCols.
; Clobbers a, b, c.
RollPageFromCell:
    ld a, [wRollSeg]
    ld [wPageSeg], a
    ld a, [wPageCols]
    ld c, a
    ld a, [wRollCell]
    ld b, 0
.l: cp c
    jr c, .done
    sub c
    inc b
    jr .l
.done:
    ld a, b
    jp RollSetPage

; While playing with wFollow set: keep the playhead's tick inside the page.
; The user scrolling (moving the cursor) clears wFollow.
RollFollow:
    ld a, [wSeqCur]
    ld b, a
    ld a, [wSeqCurSeg]
    ld hl, wPageSeg
    cp [hl]
    jr nz, .move            ; the playhead is in another segment
    ld a, [wPageTick]
    ld c, a
    ld a, b
    sub c
    jr c, .move             ; before the page
    ld d, a
    ld a, [wPageSpan]
    ld e, a
    ld a, d
    cp e
    ret c                   ; still inside the page
.move:
    ld a, [wPageSpan]
    ld e, a
    ld a, b                 ; tick
    ld d, 0                 ; d = page index
.l: cp e
    jr c, .done
    sub e
    inc d
    jr .l
.done:
    ld a, [wSeqCurSeg]
    ld [wPageSeg], a
    ld a, d
    call RollSetPage
    jp RollRefreshAll

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
; For the visible page of the selected channel, work out for each of the
; wPageCols columns (wDivTicks ticks each):
;   wColPitch[c]  the pitch drawn in the column (0 = none): a note-on inside the
;                 column wins, else the note already sounding when it starts,
;                 and an OFF in the very first tick of a column silences it
;   wColHead[c]   flags: bit 0 = a note starts in this column, bit 1 = beat line
;                 column, bit 3 = bar line column, bit 2 = unused column (the
;                 page has fewer than 16 columns; drawn blank)
; and the ruler line (wRulerBuf): bar numbers over the bar lines, ticks over the
; other beat lines, nothing after the loop end. The page starts on a beat, so the
; bar/beat marks stay where they are when the grid division changes.
; Runs outside VBlank: at most about 400 ticks scanned.
BuildCols:
    ld a, [wSelCh]
    add a
    add HIGH(wPatterns)
    ld b, a                 ; b = high byte of this channel's pattern
    ld a, [wPageTick]
    ld c, a                 ; c = tick where the current column starts
    ld d, 0                 ; d = pitch sounding at c
    ld e, c
    ld a, [wPageSeg]
    ld [wBCSeg], a
.back:                      ; look backwards for the last event before the page (across segments)
    ld a, e
    and a
    jr nz, .step
    ld a, [wBCSeg]
    and a
    jr z, .init             ; the very start of the pattern
    dec a
    ld [wBCSeg], a
    ld e, SEQ_TICKS         ; the end of the previous segment
.step:
    dec e
    ld a, [wBCSeg]
    add b
    ld h, a
    ld l, e
    ld a, [hl]
    and a
    jr z, .back
    cp CELL_OFF
    jr z, .init
    ld d, a
.init:                      ; b = the channel's page in the page's segment from here on
    ld a, [wPageSeg]
    add b
    ld b, a
    ld a, c                 ; beat phase of the first column: tick mod 12, tick / 12
    ld e, 0
.mod:
    cp TICKS_PER_BEAT
    jr c, .modDone
    sub TICKS_PER_BEAT
    inc e
    jr .mod
.modDone:
    ld [wBCPhase], a
    ld a, [wPageSeg]
    swap a                  ; a segment is 16 beats
    add e
    ld [wBCBeat], a         ; absolute beat number (bar = beat / 4)
    xor a
    ld [wBCCol], a
.col:
    ld a, [wBCCol]
    ld hl, wPageCols
    cp [hl]
    jp nc, .padFill
    ld a, c
    cp SEQ_TICKS
    jp nc, .padFill         ; (never happens: pages tile the pattern exactly)
    ld a, [wBCPhase]        ; beat / bar line column?
    and a
    jr nz, .noBeat
    ld a, [wBCBeat]
    and 3
    ld a, 2                 ; beat line
    jr nz, .flagSet
    ld a, 2 | 8             ; bar line (first beat of a bar)
    jr .flagSet
.noBeat:
    xor a
.flagSet:
    ld [wBCFlag], a
    and a                   ; ruler tile: only beat columns inside the loop get a mark
    ld a, 0
    jr z, .rulerSet
    call InLoop
    ld a, 0
    jr nc, .rulerSet        ; after the loop end: blank
    ld a, [wBCFlag]
    bit 3, a
    ld a, T_TICK
    jr z, .rulerSet         ; ordinary beat: a tick on the beat line
    ld a, [wBCBeat]
    srl a
    srl a
    inc a                   ; bar number, 1-based
    call NibbleTile
.rulerSet:
    call BCStoreRuler
    ld a, d
    ld [wBCPitch], a        ; default: whatever is sounding
    xor a
    ld [wBCHead], a
    ld a, [wDivTicks]
    ld e, a                 ; e = ticks left in this column
.tick:
    ld h, b
    ld l, c
    ld a, [hl]
    and a
    jr z, .nextTick
    cp CELL_OFF
    jr nz, .noteOn
    ld d, 0                 ; OFF
    ld a, [wDivTicks]
    cp e
    jr nz, .nextTick        ; not the first tick: the column still shows the note
    xor a
    ld [wBCPitch], a        ; OFF right at the start: nothing in this column
    jr .nextTick
.noteOn:
    ld d, a
    ld a, [wBCHead]
    and a
    jr nz, .nextTick        ; only the first note-on of the column is drawn
    ld a, d
    ld [wBCPitch], a
    ld a, 1
    ld [wBCHead], a
.nextTick:
    inc c
    dec e
    jr nz, .tick
    ; advance the beat phase by one column
    ld a, [wDivTicks]
    ld e, a
    ld a, [wBCPhase]
    add e
    cp TICKS_PER_BEAT
    jr c, .phaseOk
    sub TICKS_PER_BEAT
    push af
    ld a, [wBCBeat]
    inc a
    ld [wBCBeat], a
    pop af
.phaseOk:
    ld [wBCPhase], a
    call BCStoreCol
    jp .col
.padFill:                   ; columns the page does not use
    ld a, [wBCCol]
    cp SEQ_PAGE
    jr nc, .finish
    xor a
    ld [wBCPitch], a
    ld [wBCHead], a
    ld a, 4
    ld [wBCFlag], a
    xor a
    call BCStoreRuler
    call BCStoreCol
    jr .padFill
.finish:
    ; ---- ruler ends: inverted channel label on the left, page number on the right
    ld de, ChanLabels
    ld a, [wSelCh]
    add a
    add e
    ld e, a
    jr nc, .labelPtr
    inc d
.labelPtr:
    ld hl, wRulerBuf
    ld a, [de]
    sub 32 - TILE_INV       ; inverted: the label reads as a tab
    ld [hl+], a
    inc de
    ld a, [de]
    sub 32 - TILE_INV
    ld [hl], a
    ld hl, wRulerBuf + 18
    ld a, 'P' - 32 + TILE_INV   ; inverted tab, like the channel label
    ld [hl+], a
    push hl
    ld a, [wPageSpan]       ; the page number counts on through the segments
    ld e, a
    ld a, SEQ_TICKS
    ld c, 0
.pps:
    sub e
    inc c                   ; c = pages in a segment (a page span divides SEQ_TICKS)
    and a
    jr nz, .pps
    ld a, [wPageSeg]
    and a
    ld a, 0
    jr z, .firstSeg
    ld a, c
.firstSeg:
    ld hl, wRollPage
    add [hl]
    pop hl
    inc a
    call NibbleTile
    add TILE_INV
    ld [hl], a
    ret

; c = tick inside the page's segment -> carry set if that position is before the loop end.
; Keeps bc, de.
InLoop:
    push de
    ld a, [wSeqBars]
    dec a
    add a
    ld e, a
    ld d, 0
    ld hl, LoopEndTab
    add hl, de
    ld a, [wPageSeg]
    cp [hl]
    jr c, .inside           ; an earlier segment than the loop's last one
    jr nz, .outside         ; a later one
    inc hl
    ld a, c
    cp [hl]                 ; the last segment: tick < ticks played in it
    pop de
    ret
.inside:
    scf
    pop de
    ret
.outside:
    and a
    pop de
    ret

; Store the current column (wBCPitch, wBCHead | wBCFlag) and move to the next one.
; Clobbers a, e, hl (keeps b, c, d).
BCStoreCol:
    ld a, [wBCCol]
    add LOW(wColPitch)
    ld l, a
    ld h, HIGH(wColPitch)
    ld a, [wBCPitch]
    ld [hl], a
    ld a, l
    add SEQ_PAGE
    ld l, a
    ld a, [wBCHead]
    ld e, a
    ld a, [wBCFlag]
    or e
    ld [hl], a
    ld a, [wBCCol]
    inc a
    ld [wBCCol], a
    ret

; a = tile -> wRulerBuf[2 + wBCCol]. Clobbers a, hl (keeps b, c, d).
BCStoreRuler:
    push af
    ld hl, wRulerBuf + ROLL_COL0
    ld a, [wBCCol]
    add l
    ld l, a
    jr nc, .ok
    inc h
.ok:
    pop af
    ld [hl], a
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

; Build the status line if requested, then render up to RENDER_BUDGET flagged
; rows and flag them for copying. Runs in the main loop, outside VBlank.
RenderPending:
    ld a, [wStatusRender]
    and a
    jr z, .rows
    xor a
    ld [wStatusRender], a
    call BuildStatus
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS         ; copy it to VRAM
    ld [hl], a
.rows:
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
    ld a, [wRollSeg]
    ld hl, wPageSeg
    cp [hl]
    jr nz, .noCursor        ; the cursor is in another segment
    ld a, [wPageCell]
    ld d, a
    ld a, [wRollCell]
    sub d                   ; column = cell - first cell of the page
    ld hl, wPageCols
    cp [hl]
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
    ld b, [hl]              ; pitch drawn in this column
    ld a, l
    add SEQ_PAGE
    ld l, a
    ld d, [hl]              ; flags: bit 0 = note head, bit 1 = beat line
    pop hl
    ld a, [wRRPitch]
    cp b
    jr nz, .emptyCell
    ld a, [wRRCur]          ; a note bar
    cp e
    ld a, T_CUR_NOTE
    jr z, .put
    bit 0, d
    ld a, T_NOTE_BODY
    jr z, .put
    ld a, T_NOTE_HEAD
    jr .put
.emptyCell:
    bit 2, d                ; unused column (short page): blank
    ld a, 0
    jr nz, .put
    ld a, [wRRCur]
    cp e
    ld a, T_CUR_EMP
    jr z, .put
    bit 3, d                ; background: bar line / beat line / plain sub-grid cell
    jr z, .notBar
    ld a, T_BAR_W
    jr .addBlack
.notBar:
    bit 1, d
    ld a, T_EMP_W
    jr z, .addBlack
    ld a, T_EMP_W + 2
.addBlack:
    ld b, a
    ld a, [wRRBlack]        ; +1 on black-key rows
    add b
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
ChanLabels: db "1P", "2P", "3W", "4N"

; Status line into wStatusBuf: PLAY/STOP  bpm  grid division  cursor pitch  edited pattern
BuildStatus:
    ld hl, wStatusBuf
    ld b, 20
    xor a
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld hl, wStatusBuf
    ld de, sStop
    ld a, [wSeqPlay]
    and a
    jr z, .state
    ld de, sPlay
.state:
    call DrawString
    ld hl, wStatusBuf + 4
    ld a, [wBpm]
    call DrawDec3
    ld a, [wDiv]            ; label = DivLabels + 6 * index
    ld e, a
    add a
    add e
    add a
    ld e, a
    ld d, 0
    ld hl, DivLabels
    add hl, de
    ld d, h
    ld e, l
    ld hl, wStatusBuf + 8
    call DrawString
    ld hl, wStatusBuf + 18  ; the edited pattern: P1-P4
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wEditPat]
    add '1' - 32
    ld [hl], a
    ld hl, wStatusBuf + 14
    ld a, [wRollNote]
    jp DrawNoteName

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

CopyRuler:
    ld hl, wRulerBuf
    ld de, _SCRN0
    REPT 20
        ld a, [hl+]
        ld [de], a
        inc de
    ENDR
    ret

CopyStatus:
    ld hl, wStatusBuf
    ld de, _SCRN0 + 17 * 32
    REPT 20
        ld a, [hl+]
        ld [de], a
        inc de
    ENDR
    ret

; ---------------------------------------------------------------- screen
; Called with the LCD off: build the whole roll screen.
BuildSeq:
    ld a, $FF
    ld [wPlayShown], a
    ld [wPlayX], a
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
    call BuildStatus
    call CopyStatus
    call CopyRuler
    xor a
    ld [wStatusRender], a
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

; Right after VBlank starts: copy jobs only (see the header comment).
UpdateSeq:
    call UpdatePlayhead     ; carry set if it touched OAM
    ld a, 0
    rla
    ld e, a                 ; e = 1 if the playhead moved this frame
    and a
    jr nz, .rows            ; it did: leave the ruler/status copy for the next frame
    ld a, [wDirty]
    bit 5, a
    jr z, .noRuler
    res 5, a
    ld [wDirty], a
    jp CopyRuler
.noRuler:
    bit 4, a
    jr z, .rows
    res 4, a
    ld [wDirty], a
    jp CopyStatus
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

; Decide where the playhead line should be (OAM X) for the tick that was played
; last, using the per-division pixel table. Outside VBlank, once per frame.
; wPlayX = X in OAM coordinates, or $FF when stopped / the tick is on another page.
RollPlayheadCalc:
    ld a, [wSeqPlay]
    and a
    jr z, .hide
    ld a, [wSeqCurSeg]
    ld hl, wPageSeg
    cp [hl]
    jr nz, .hide            ; the playhead is in another segment
    ld a, [wPageTick]
    ld c, a
    ld a, [wSeqCur]
    sub c
    jr c, .hide             ; before the page
    ld b, a                 ; b = ticks since the page start
    ld a, [wPageSpan]       ; ticks in a page
    cp b
    jr z, .hide
    jr c, .hide             ; after the page
    ld a, [wDiv]
    add a
    ld e, a
    ld d, 0
    ld hl, PlayXPtrs
    add hl, de
    ld a, [hl+]
    ld e, a
    ld d, [hl]              ; de = pixel table of this division
    ld h, d
    ld l, e
    ld c, b
    ld b, 0
    add hl, bc
    ld a, [hl]              ; pixels from the left edge of the grid
    add ROLL_COL0 * 8 + 8   ; + grid left edge + OAM X offset
    ld [wPlayX], a
    ret
.hide:
    ld a, $FF
    ld [wPlayX], a
    ret

; Move the playhead sprites to wPlayX. Moving between two visible positions only
; rewrites the 16 X coordinates; Y is written when the line appears (and zeroed
; when it disappears). -> carry set if OAM was written. Runs in VBlank.
UpdatePlayhead:
    ld a, [wPlayX]
    ld hl, wPlayShown
    cp [hl]
    jr nz, .changed
    and a                   ; nothing changed: carry clear
    ret
.changed:
    ld b, [hl]              ; b = previous X ($FF = was hidden)
    ld [hl], a
    cp $FF
    jr z, .hideAll
    ld c, a                 ; c = new X
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
