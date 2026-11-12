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
; Ring: the BG map has 32 rows and SCY picks which 18 are visible. Pitch p always lives in map
; row (1 - p) mod 32 (the "ring row"); the visible window shows ring rows k .. k+17 with
; k = (-top) mod 32 (SCY = 8 * k): the ruler on row k, the 16 pitch rows, the status on row
; k + 17. The shadow rows, the render flags and the copy masks are all indexed by ring row, so
; they stay valid when the window moves. Everything is drawn in the hidden map and swapped in
; (below); moving the window by one pitch rewrites only 3 rows (the new pitch row, the ruler and
; the status line at their new places) and then changes SCY.
; Anything that changes what is shown just flags rows (MarkRowRender /
; MarkAllRender); the screen catches up over the next few frames.
; tools/headless_test.py measures that UpdateUI really finishes inside VBlank.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF COPY_BUDGET   EQU 2     ; (rows: the hidden-map copies; the shown map uses the unit budget below)
DEF V_UNITS       EQU 11    ; copy budget of a frame in units (about 0.7 DIV ticks each): the ruler / status line = 4, a row = 3 + changed tiles / 5
DEF RENDER_BUDGET EQU 16    ; rows rendered per frame (outside VBlank, ~750 cycles each)
DEF BUILD_BUDGET  EQU 2     ; rows copied per frame while a full redraw is built in the hidden map

SECTION "Roll", ROMX, BANK[1]

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

; A new page (same pitch window): rebuild the column summary and the ruler and re-render every
; row, but write straight into the shown map and copy only the rows (and ruler) that really
; changed (CommitRow compares): the page turns in a few frames instead of a whole hidden-map
; build. Falls back to RollRefreshAll when a build is running or the window is moving.
RollRefreshSoft:
    ld a, [wBuild]
    and a
    jp nz, RollRefreshAll
    ld a, [wRollTop]
    ld hl, wShownTop
    cp [hl]
    jp nz, RollRefreshAll
    call BuildCols
    call ShowPageNow        ; the playhead is placed on the new page from now on
    call MarkAllRender
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER         ; copy the ruler to VRAM
    ld [hl], a
    jp MarkSeqStatus

; Everything may have changed (other channel, other division, loop length, load, a big move of
; the pitch window): rebuild the column summary and ruler, redraw all rows and the status line
; in the hidden map and swap it in.
RollRefreshAll:
    call RollPageFromCell   ; (the bar length or the grid may have changed)
    call BuildCols
    xor a                   ; the shown map keeps what it has; the new picture is built in the other
    ld hl, wMaskV
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    ld hl, wMaskH
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    inc a
    ld [wBuild], a
    xor a
    ld [wBuildReady], a
    ld [wVPre], a           ; (a pending scroll step is over: the build shows the new window)
    call MarkAllRender
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_HEADER         ; copy the ruler to VRAM
    ld [hl], a
    jp MarkSeqStatus

; The selected channel changed: put the cursor on its first note (if it has
; one) and centre the pitch window on it, so the channel is visible at once.
RollChannelChanged:
    xor a
    ld [wRCSeg], a
.seg:
    ld a, [wRCSeg]
    call EdSegPage          ; a = the channel's page in this segment (SVBK set)
    ld b, a
    ld c, 0                 ; c = tick
.scan:
    ld h, b
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
    xor a
    ld [wPageChanged], a
    call RollScrollFix
    jr nc, .sameWindow
    ld a, [wPageChanged]
    and a
    jp nz, RollRefreshSoft  ; a new page: the page turns in a few frames
    ld a, [wBuild]
    and a
    jp nz, RollRefreshAll   ; (a redraw is being built: it starts over for the new window)
    ld a, [wRollTop]        ; only the pitch window moved: by one pitch it is a 3-row scroll
    ld hl, wShownTop
    sub [hl]
    ld b, 0                 ; b = the grid row that enters: 0 = the top one, 15 = the bottom one
    cp 1
    jr z, .oneStep
    ld b, ROLL_ROWS - 1
    cp $FF
    jp nz, RollRefreshAll   ; more than one pitch at once: redraw everything
.oneStep:
    ld a, b
    call MarkRowRender      ; the entering pitch row is rendered; UpdateSeq scrolls when it is ready
    call MarkSeqStatus      ; (the status line moves with the window)
.sameWindow:
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
    call CursorAbs
    call PageHas
    ld d, 0
    jr c, .samePage         ; the cursor is on the page
.newPage:
    ld a, 1
    ld [wPageChanged], a
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

; de = a tick (counted from the start of the pattern) -> carry set if the page shows it.
; Clobbers a, de, hl.
PageHas:
    ld hl, wPageAbs
    ld a, e
    sub [hl]
    ld e, a
    inc hl
    ld a, d
    sbc [hl]
    jr c, .out              ; before the page
    jr nz, .out             ; 256 ticks or more after its start
    ld a, e
    ld hl, wPageSpan
    cp [hl]                 ; carry = inside
    ret
.out:
    and a
    ret

; Show the page that has the cursor. Keeps de.
RollPageFromCell:
    push de
    call CursorAbs
    call PageFor
    pop de
    ret

; While playing with wFollow set: keep the playhead's tick inside the page.
; The user scrolling (moving the cursor) clears wFollow. Only on the sequencer screen: on the others nothing shows the roll, and
; rendering its rows for every page the playhead crosses cost the main loop more than a frame (the sequencer ticks jittered). The
; roll catches up with the playhead on its next tick after the screen is opened.
RollFollow:
    ld a, [wScreen]
    cp SCREEN_SEQ
    ret nz
    ld a, [wSeqCur]
    ld e, a
    ld d, 0
    ld a, [wSeqCurSeg]
    and a
    jr z, .have
    ld hl, SEQ_TICKS
    add hl, de
    ld d, h
    ld e, l
.have:
    push de
    call PageHas
    pop de
    ret c                   ; still inside the page
    call PageFor
    jp RollRefreshSoft

; The page that shows the tick de (the cursor or the playhead): wPageAbs / wPageSeg / wPageTick /
; wPageCols / wPageSpan. A page is made of whole bars of the same number of grid cells when the
; grid division divides the bar (at most 16 cells: as many whole bars as fit; more: pieces of 16
; cells from the bar's start, the last one shifted back to end on the bar's end); otherwise it is a
; piece of 16 cells that starts on a multiple of its span. Columns the page does not use are blank.
PageFor:
    push de
    call TsUpdate
    pop de
    ld a, e
    ld [wPfX], a
    ld a, d
    ld [wPfX + 1], a
    ld a, [wBarTicks]
    ld b, a                 ; b = ticks in a bar
    ld a, [wDivTicks]
    ld c, a                 ; c = ticks in a cell
    ld a, b
.mod:
    cp c
    jr c, .modDone
    sub c
    jr .mod
.modDone:
    and a
    jp nz, .fixed           ; the division does not divide the bar
    ld a, b
    ld e, 0                 ; e = cells in a bar
.cells:
    and a
    jr z, .cellsDone
    sub c
    inc e
    jr .cells
.cellsDone:
    ld a, e
    cp 17
    jp nc, .long
    ld a, 16
    ld d, 0                 ; d = whole bars that fit in 16 cells
.k:
    sub e
    jr c, .kDone
    inc d
    jr .k
.kDone:
    push de
    ld c, d
    ld d, 0
    ld e, b                 ; de = ticks in a bar
    ld hl, 0
.step:
    add hl, de
    dec c
    jr nz, .step            ; hl = bars * bar ticks
    pop de
    ld a, l
    ld [wPfStep], a
    ld a, h
    ld [wPfStep + 1], a
    xor a
    ld c, d
.cols:
    add e
    dec c
    jr nz, .cols            ; a = bars * cells
    ld [wPfCols], a
    call PageStart
    jp .finish
.long:                      ; a bar of more than 16 cells
    ld a, b
    ld [wPfStep], a
    xor a
    ld [wPfStep + 1], a
    ld a, e
    ld [wPfN], a
    call PageStart          ; hl = the start of the bar
    ld a, [wPfX]
    sub l
    ld b, a                 ; b = ticks into the bar
    ld a, [wDivTicks]
    ld c, a
    ld d, 0                 ; d = the cursor's cell in the bar
.cell:
    ld a, b
    cp c
    jr c, .cellDone
    sub c
    ld b, a
    inc d
    jr .cell
.cellDone:
    ld a, d
    and $F0                 ; the piece starts at a multiple of 16 cells
    ld d, a
    ld a, [wPfN]
    sub 16
    ld e, a                 ; the last piece starts at cell n - 16
    ld a, d
    cp e
    jr c, .piece
    ld d, e
.piece:
    ld a, d
    and a
    jr z, .pieceDone
.add:
    ld a, [wDivTicks]
    add l
    ld l, a
    jr nc, .noCarry
    inc h
.noCarry:
    dec d
    jr nz, .add
.pieceDone:
    ld a, 16
    ld [wPfCols], a
    jr .finish
.fixed:
    ld a, c
    add a
    add a
    add a
    add a                   ; the span of 16 cells (at most 192)
    ld [wPfStep], a
    xor a
    ld [wPfStep + 1], a
    ld a, 16
    ld [wPfCols], a
    call PageStart
    ld a, [wPfStep]
    ld c, a
    ld a, 128               ; de = 384 - span: the last page starts there
    sub c
    ld e, a
    ld a, 1
    sbc 0
    ld d, a
    ld a, e
    sub l
    ld a, d
    sbc h
    jr nc, .finish          ; the page start is not after it
    ld h, d
    ld l, e
.finish:                    ; hl = the start; wPfCols columns, fewer at the end of the pattern
    ld a, l
    ld [wPageAbs], a
    ld a, h
    ld [wPageAbs + 1], a
    ld a, 128
    sub l
    ld c, a
    ld a, 1
    sbc h
    ld b, a                 ; bc = ticks left in the pattern
    ld a, [wPfCols]
    ld d, a
    ld a, [wDivTicks]
    ld e, a
    xor a
.span:
    add e
    dec d
    jr nz, .span            ; a = the span of the columns
    ld d, a
    ld a, b
    and a
    jr nz, .full            ; 256 or more ticks left
    ld a, c
    cp d
    jr nc, .full
    ld d, 0                 ; fewer left than the span: the columns that fit
.fit:
    cp e
    jr c, .fitDone
    sub e
    inc d
    jr .fit
.fitDone:
    ld a, d
    ld [wPfCols], a
.full:
    ld a, [wPfCols]
    ld [wPageCols], a
    ld d, a
    xor a
.span2:
    add e
    dec d
    jr nz, .span2
    ld [wPageSpan], a
    ld a, [wPageAbs + 1]
    and a
    jr nz, .second
    ld a, [wPageAbs]
    cp SEQ_TICKS
    jr c, .first
    sub SEQ_TICKS
    ld [wPageTick], a
    ld a, 1
    ld [wPageSeg], a
    ret
.first:
    ld [wPageTick], a
    xor a
    ld [wPageSeg], a
    ret
.second:
    ld a, [wPageAbs]
    add 256 - SEQ_TICKS
    ld [wPageTick], a
    ld a, 1
    ld [wPageSeg], a
    ret

; hl = the last multiple of wPfStep (from 0) that is not after wPfX. Clobbers a, de.
PageStart:
    ld hl, 0
.next:
    ld a, [wPfStep]
    add l
    ld e, a
    ld a, [wPfStep + 1]
    adc h
    ld d, a                 ; de = the next start
    ld a, [wPfX]
    sub e
    ld a, [wPfX + 1]
    sbc d
    ret c                   ; the tick is before it
    ld h, d
    ld l, e
    jr .next

; a = grid row 0..15 of the window (top = row 0) -> a = its ring row. Clobbers hl.
RingOfRow:
    inc a
    ld l, a
    ld a, [wRollTop]
    ld h, a
    ld a, l
    sub h
    and RING_ROWS - 1
    ret

; a = grid row 0..15 -> flag its ring row for rendering. Clobbers a, hl.
MarkRowRender:
    call RingOfRow
    add LOW(wRowRender)     ; wRowRender is 32-byte aligned: no carry
    ld l, a
    ld h, HIGH(wRowRender)
    ld [hl], 1
    ret

MarkAllRender:
    ld c, 0
.l: ld a, c
    call MarkRowRender
    inc c
    ld a, c
    cp ROLL_ROWS
    jr c, .l
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
; The beat phase (ticks into the beat), the ticks into the bar and the bar index (0-based) at the
; first column of the page. Keeps bc, de.
BCInitPhases:
    push bc
    push de
    ld a, [wPageTick]
    ld l, a
    ld h, 0
    ld a, [wPageSeg]
    and a
    jr z, .first
    ld de, SEQ_TICKS
    add hl, de              ; hl = the tick counted from the start of the pattern
.first:
    ld a, [wBarTicks]
    ld e, a
    ld d, 0
    ld b, 0                 ; b = bar index: hl / bar ticks
.bar:
    ld a, h
    cp d
    jr c, .barDone
    jr nz, .sub
    ld a, l
    cp e
    jr c, .barDone
.sub:
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
    inc b
    jr .bar
.barDone:
    ld a, l
    ld [wBCInBar], a
    ld a, b
    ld [wBCBar], a
    ld a, [wBeatTicks]
    ld e, a
    ld a, [wBCInBar]
.phase:
    cp e
    jr c, .phaseDone
    sub e
    jr .phase
.phaseDone:
    ld [wBCPhase], a
    pop de
    pop bc
    ret

BuildCols:
    call TsUpdate
    call ComputeLoopEnd
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
    call EdSegPage          ; the channel's page in that segment (keeps bc, de)
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
    call EdSegPage
    ld b, a
    call BCInitPhases       ; the beat phase, the tick in the bar and the bar of the first column
    ld a, [wPageSeg]
    ld [wColSeg], a
    xor a
    ld [wBCCol], a
.col:
    ld a, [wBCCol]
    ld hl, wPageCols
    cp [hl]
    jp nc, .padFill
    ld a, c
    cp SEQ_TICKS
    jr c, .inSeg
    ld a, [wColSeg]         ; the page runs on into the next segment
    cp NUM_SEGS - 1
    jp nc, .padFill
    inc a
    ld [wColSeg], a
    call EdSegPage          ; (keeps bc, de)
    ld b, a
    ld c, 0
.inSeg:
    ld a, [wBCPhase]        ; beat / bar line column?
    and a
    jr nz, .noBeat
    ld a, [wBCInBar]
    and a
    ld a, 2                 ; beat line
    jr nz, .flagSet
    ld a, 2 | 8             ; bar line (the first beat of a bar)
    jr .flagSet
.noBeat:
    xor a
.flagSet:
    ld [wBCFlag], a
    and a                   ; ruler tile: bar numbers over the bar lines (all MAX_BARS bars, also after the
    ld a, 0                 ; loop end), a tick over the other beat lines inside the loop
    jr z, .rulerSet
    ld a, [wBCFlag]
    bit 3, a
    jr nz, .barNumber
    call InLoop
    ld a, 0
    jr nc, .rulerSet        ; after the loop end: no tick on an ordinary beat
    ld a, T_TICK
    jr .rulerSet
.barNumber:
    ld a, [wBCBar]
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
    ; advance the beat phase and the position in the bar by one column
    ld a, [wDivTicks]
    ld e, a
    ld a, [wBCPhase]
    add e
    ld hl, wBeatTicks
.phase:
    cp [hl]
    jr c, .phaseOk
    sub [hl]
    jr .phase
.phaseOk:
    ld [wBCPhase], a
    ld a, [wBCInBar]
    add e
    ld hl, wBarTicks
.inBar:
    cp [hl]
    jr c, .inBarOk
    sub [hl]
    push af
    ld a, [wBCBar]
    inc a
    ld [wBCBar], a
    pop af
    jr .inBar
.inBarOk:
    ld [wBCInBar], a
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
    ; ---- ruler ends: inverted channel label on the left, the edited pattern (P1-P4) on the right
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
    ld a, [wEditPat]        ; the edited pattern, like the P1-PG of the song screen
    inc a
    call PatTile
    add TILE_INV
    ld [hl], a
    ret

; c = tick inside the page's segment -> carry set if that position is before the loop end.
; Keeps bc, de.
InLoop:
    ld hl, wEdLoopSeg       ; (BuildCols computed it)
    ld a, [wColSeg]
    cp [hl]
    jr c, .inside           ; an earlier segment than the loop's last one
    jr nz, .outside         ; a later one
    ld hl, wEdLoopTail
    ld a, c
    cp [hl]                 ; the last segment: tick < ticks played in it
    ret
.inside:
    scf
    ret
.outside:
    and a
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
    ldh a, [rLY]            ; the frame is nearly over (LY 138-143): the rest waits for the next pass,
    sub 138                 ; or the main loop would miss the VBlank and the sequencer a frame
    cp 6
    ret c
    xor a
    ld [hl], a
    push bc
    call RenderRow          ; carry set: this ring row is not in the window (nothing drawn)
    pop bc
    jr c, .next
    ld a, [wBuild]
    and a
    jr nz, .hiddenOnly      ; a full redraw: the shown map is not touched until it is complete
    ld a, [wRRChanged]
    and a
    jr z, .budget           ; the row came out exactly as it already is: nothing to copy
    ld a, [wShownTop]       ; the shown picture: only rows of ITS window are copied (the others
    add c                   ; belong to a scroll that has not happened yet)
    dec a
    and RING_ROWS - 1
    cp ROLL_ROWS
    jr nc, .budget
    call AddSpan            ; (the changed tiles only)
    jr .budget
.hiddenOnly:
    ld hl, wMaskH
    ld a, c
    call SetRowBit
.budget:
    dec b
    ret z
.next:
    inc c
    ld a, c
    cp RING_ROWS
    jr c, .scan
    ld a, [wBuild]          ; every flagged row has been rendered: the redraw may be shown
    and a
    ret z
    ld a, 1
    ld [wBuildReady], a
    ret

; c = ring row. Renders the key label and the 16 cells of that row into its wGrid slot.
; -> carry set (and nothing drawn) when that ring row is not in the current window.
RenderRow:
    push bc
    ld a, [wRollTop]
    add c
    dec a
    and RING_ROWS - 1       ; grid row of the window = (top + r - 1) mod 32
    cp ROLL_ROWS
    jr c, .inWindow
    pop bc
    scf
    ret
.inWindow:
    ld e, a
    ld a, [wRollTop]
    sub e
    ld b, a                 ; b = pitch of this row
    ld a, b
    ld [wRRPitch], a
    ; --- cursor column for this row ($FF if the cursor is not on it / not on this page)
    ld a, [wRollNote]
    cp b
    jr nz, .noCursor
    push bc
    call CursorAbs
    ld hl, wPageAbs
    ld a, e
    sub [hl]
    ld e, a
    inc hl
    ld a, d
    sbc [hl]
    pop bc
    jr c, .noCursor         ; before the page
    jr nz, .noCursor
    ld a, e
    ld hl, wPageSpan
    cp [hl]
    jr nc, .noCursor        ; after it
    push bc
    ld b, 0                 ; column = ticks into the page / ticks per cell
    ld a, [wDivTicks]
    ld c, a
    ld a, e
.colDiv:
    cp c
    jr c, .colDone
    sub c
    inc b
    jr .colDiv
.colDone:
    ld a, b
    pop bc
    jr .haveCur
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
    ld a, c
    ld [wRRRow], a
    ld hl, wRRBuf           ; the row is built here and compared with its shadow slot at the end
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
    jp CommitRow

; The row built in wRRBuf goes into its shadow slot; wRRChanged says whether it differs. -> carry clear.
CommitRow:
    ld a, [wRRRow]
    ld c, a
    call GridPtr            ; hl = the shadow slot
    ld de, wRRBuf
    ld a, $FF
    ld [wRRLo], a
    xor a
    ld [wRRHi], a
    ld b, 20
.cmp:
    ld a, [de]
    inc de
    cp [hl]
    jr z, .same
    ld [hl], a
    ld a, 20
    sub b                   ; the tile's index
    ld c, a
    ld a, [wRRLo]
    cp c
    jr c, .loKept           ; (the first difference stays the start)
    ld a, c
    ld [wRRLo], a
.loKept:
    ld a, c
    inc a
    ld [wRRHi], a           ; the last difference + 1 so far
.same:
    inc hl
    dec b
    jr nz, .cmp
    ld a, [wRRHi]
    and a
    ld a, 0
    jr z, .store
    ld a, 1
.store:
    ld [wRRChanged], a
    and a                   ; carry clear: drawn
    ret

; Letter tile and sharp tile for each pitch class (tile = ASCII - 32).
KeyLabels:
    db 'C' - 32, 0,  'C' - 32, '#' - 32,  'D' - 32, 0,  'D' - 32, '#' - 32
    db 'E' - 32, 0,  'F' - 32, 0,  'F' - 32, '#' - 32,  'G' - 32, 0
    db 'G' - 32, '#' - 32,  'A' - 32, 0,  'A' - 32, '#' - 32,  'B' - 32, 0
BlackKeys:
    db 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0
ChanLabels: db "1P", "2P", "3W", "4N"

; Status line into wStatusBuf: PLAY/STOP  bpm  grid division  cursor pitch  loop length (bars)
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
    ld hl, wStatusBuf + 18  ; the loop length in bars: L1-L8
    ld a, 'L' - 32
    ld [hl+], a
    ld a, [wSeqBars]
    add '0' - 32
    ld [hl], a
    ld hl, wStatusBuf + 14
    ld a, [wRollNote]
    jp DrawNoteName

; ---------------------------------------------------------------- copy to VRAM
; a = ring row -> de = wCopyMap:00 + row * 32. Clobbers a, hl.
RowAddr:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld a, [wCopyMap]
    add h
    ld d, a
    ld e, l
    ret

; c = ring row -> copy that row of wGrid to the same ring row of the map. Clobbers a, b, hl, de.
RollCopyRow:
    call GridPtr            ; hl = source
    push hl
    ld a, c
    call RowAddr
    pop hl
    REPT 20                 ; unrolled: this runs inside VBlank (a row never crosses a page: inc e)
        ld a, [hl+]
        ld [de], a
        inc e
    ENDR
    ret

; c = ring row -> copy only the tiles of it that changed (wSpanLo .. wSpanHi - 1) from its shadow
; slot to the same row of the map. -> a = what it cost in units (3 + tiles / 5). Keeps c.
; Clobbers b, d, e, hl. (The slot and row addresses come from tables: this is the hot path.)
RollCopySpan:
    ld a, c
    add LOW(wSpanLo)        ; the span arrays are 64-byte aligned: no carry
    ld l, a
    ld h, HIGH(wSpanLo)
    ld a, [hl]
    ld d, a                 ; d = first tile
    ld a, l
    add RING_ROWS
    ld l, a
    ld a, [hl]              ; end (exclusive)
    sub d
    ld b, a                 ; b = tiles to copy (>= 1)
    push bc
    ld a, c
    add a
    ld e, a                 ; table offset = row * 2
    push de
    ld hl, SlotTab          ; source: the slot address + first tile
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    pop de                  ; d = first tile, e = offset
    ld a, l
    add d
    ld l, a
    jr nc, .src
    inc h
.src:
    push hl
    push de
    ld hl, MapTab           ; destination: row * 32 + the map + first tile
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a                 ; hl = row * 32
    ld a, [wCopyMap]
    add h
    ld h, a
    pop de
    ld a, l
    add d                   ; (a row never crosses a page)
    ld e, a
    ld d, h
    pop hl                  ; hl = source
    pop bc                  ; b = tiles
    push bc
.copy:
    ld a, [hl+]
    ld [de], a
    inc e
    dec b
    jr nz, .copy
    pop bc
    ld a, b                 ; the cost: 3 + tiles / 5 (the call itself is most of it)
    ld b, 3
.cost:
    sub 5
    jr c, .done
    inc b
    jr .cost
.done:
    ld a, b
    ret

; hl = a row mask, a = ring row: Z if its bit is clear. Clobbers a, d, e, hl.
TestRowBit:
.byte:
    cp 8
    jr c, .lo
    sub 8
    inc hl
    jr .byte
.lo:
    ld d, a
    ld e, 1
    inc d
.shift:
    dec d
    jr z, .test
    sla e
    jr .shift
.test:
    ld a, [hl]
    and e
    ret

; c = ring row: flag it for copying (V) and merge the changed tiles of the row just rendered
; (wRRLo .. wRRHi) into its pending span. Clobbers a, d, e, hl.
AddSpan:
    ld hl, wMaskV
    ld a, c
    call TestRowBit         ; Z = nothing pending for this row yet
    push af
    ld hl, wMaskV
    ld a, c
    call SetRowBit
    ld a, c
    add LOW(wSpanLo)
    ld l, a
    ld h, HIGH(wSpanLo)
    pop af
    jr z, .fresh
    ld a, [wRRLo]           ; union with the pending span
    cp [hl]
    jr nc, .loKept
    ld [hl], a
.loKept:
    ld a, l
    add RING_ROWS
    ld l, a
    ld a, [wRRHi]
    cp [hl]
    ret c
    ld [hl], a
    ret
.fresh:
    ld a, [wRRLo]
    ld [hl], a
    ld a, l
    add RING_ROWS
    ld l, a
    ld a, [wRRHi]
    ld [hl], a
    ret

CopyRuler:
    ld a, [wCopyTop]
    cpl
    inc a
    and RING_ROWS - 1       ; the ruler's ring row: (-top) mod 32
    call RowAddr
    ld hl, wRulerBuf
    REPT 20
        ld a, [hl+]
        ld [de], a
        inc e
    ENDR
    ret

CopyStatus:
    ld a, [wCopyTop]
    ld l, a
    ld a, 17
    sub l
    and RING_ROWS - 1       ; the status line's ring row: (17 - top) mod 32
    call RowAddr
    ld hl, wStatusBuf
    REPT 20
        ld a, [hl+]
        ld [de], a
        inc e
    ENDR
    ret

; ---------------------------------------------------------------- screen
; Called with the LCD off: build the whole roll screen.
BuildSeq:
    ld a, $FF
    ld [wPlayShown], a
    ld [wPlayX], a
    xor a
    ld [wShown], a          ; $9800 is shown (LCDC bit 3 = 0 when the screen is switched on)
    ld [wBuild], a
    ld [wBuildReady], a
    ld a, [wRollTop]
    ld [wShownTop], a
    call SetCopyVisible
    call ApplyScy           ; SCY for this window (the LCD is off: no tearing to worry about)
    call RollPageFromCell   ; (the time signature may have changed since the screen was last shown)
    call BuildCols
    call ShowPageNow
    ld b, 0                 ; b = grid row of the window
.render:
    ld a, b
    call RingOfRow
    ld c, a                 ; c = its ring row
    push bc
    call RenderRow
    pop bc
    push bc
    call RollCopyRow
    pop bc
    inc b
    ld a, b
    cp ROLL_ROWS
    jr c, .render
    ld hl, wRowRender       ; nothing left to do for the flag arrays and masks
    ld b, RING_ROWS
    xor a
.clr:
    ld [hl+], a
    dec b
    jr nz, .clr
    ld hl, wMaskV
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    ld hl, wMaskH
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl], a
    ld [wDirtyH], a
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
; The shown map is updated row by row; a full redraw (RollRefreshAll) is built in the hidden
; map only and shown by swapping the maps; a one-pitch scroll is the 3-row step below.
UpdateSeq:
    call UpdatePlayhead     ; carry set if it touched OAM
    ld a, 0
    rla
    ld e, a                 ; e = 1 if the playhead moved this frame
    ld a, [wBuild]
    and a
    jp nz, .build
    call SetCopyVisible
    ld a, e
    and a
    jr nz, .noScroll        ; the playhead moved: no scroll step, no ruler/status copy this frame
    call VScrollStep        ; a pending one-pitch scroll (needs its row rendered): 2 + 1 rows, SCY
    ret c                   ; it took this frame
.noScroll:
    ld a, V_UNITS           ; the ruler / status line (4 each) and the rows (3 + span / 5 each) share it
    ld b, a
    ld a, e
    and a
    jr z, .u
    ld a, b                 ; the playhead moved this frame and took some of the time
    sub 5
    ld b, a
.u:
    ld a, b
    call LimitUnits
    ld b, a
    ld a, e
    and a
    jr nz, .rows            ; the playhead moved: only rows this frame
    ld a, [wDirty]
    bit 5, a
    jr z, .noRuler
    res 5, a
    ld [wDirty], a
    push bc
    call CopyRuler
    pop bc
    ld a, b
    sub 4
    ret z
    ret c
    ld b, a
.noRuler:
    ld a, [wDirty]
    bit 4, a
    jr z, .rows
    res 4, a
    ld [wDirty], a
    push bc
    call CopyStatus
    pop bc
    ld a, b
    sub 4
    ret z
    ret c
    ld b, a
.rows:
.vLoop:
    ld a, b
    cp 3
    ret c                   ; not enough left for another row
    ld hl, wMaskV
    call TakeRow            ; c = a ring row that waits (and its flag is cleared)
    ret c                   ; none
    push bc
    call RollCopySpan       ; -> a = what it cost
    pop bc
    ld d, a
    ld a, b
    sub d
    ret z
    ret c
    ld b, a
    jr .vLoop

; A full redraw is being built: everything goes to the hidden map; when it is complete the maps
; are swapped (LCDC bit 3, and SCY for the new window).
.build:
    ld a, [wDirty]          ; the ruler / status line of the new picture belong to the hidden map
    bit 5, a
    jr z, .bNoRuler
    res 5, a
    ld [wDirty], a
    ld hl, wDirtyH
    set 0, [hl]
.bNoRuler:
    ld a, [wDirty]
    bit 4, a
    jr z, .bNoStatus
    res 4, a
    ld [wDirty], a
    ld hl, wDirtyH
    set 1, [hl]
.bNoStatus:
    call SetCopyHidden
    ld a, BUILD_BUDGET
    sub e
    call LimitBudget
    call CopyHidden
    call HiddenPending
    ret nz                  ; rows are still waiting
    ld a, [wBuildReady]
    and a
    ret z                   ; (more rows still have to be rendered)
    ld a, [wShown]          ; swap the maps
    xor 1
    ld [wShown], a
    ldh a, [rLCDC]
    xor %00001000           ; LCDC bit 3: BG tile map select
    ldh [rLCDC], a
    ld a, [wRollTop]
    ld [wShownTop], a
    call ApplyScy
    xor a
    ld [wBuild], a
    ld [wBuildReady], a
    call ShowPageNow
    ld a, [wMsg]            ; a message on the status row must be drawn again (the status line
    and a                   ; copy overwrote it in the hidden map)
    ret z
    ld hl, wDirty
    set 6, [hl]
    ret

; SCY for the window of wShownTop: 8 * ((-top) mod 32).
ApplyScy:
    ld a, [wShownTop]
    cpl
    inc a
    and RING_ROWS - 1
    add a
    add a
    add a
    ldh [rSCY], a
    ret

; a = row budget. Copies the ruler, the status line or flagged rows to the hidden map.
; (a = row budget -> a = 1 when VBlank is already 2 lines old: see LimitBudget)
LimitBudget:
    ld c, a
    ldh a, [rLY]
    cp 146
    ld a, c
    ret c
    cp 2
    ret c
    ld a, 1
    ret

; a = copy budget in units -> a = the units left for a frame that starts late: LY 146: 8, LY >= 147: 5.
LimitUnits:
    ld c, a
    ldh a, [rLY]
    cp 147
    jr nc, .late
    cp 146
    ld a, c
    ret c
    cp 9
    ret c
    ld a, 8
    ret
.late:
    ld a, c
    cp 6
    ret c
    ld a, 5
    ret

CopyHidden:
    ld b, a
    ld a, [wDirtyH]
    bit 0, a
    jr z, .noRuler
    res 0, a
    ld [wDirtyH], a
    jp CopyRuler
.noRuler:
    bit 1, a
    jr z, .rows
    res 1, a
    ld [wDirtyH], a
    jp CopyStatus
.rows:
    ld a, b
    and a
    ret z
.hLoop:
    ld hl, wMaskH
    call TakeRow
    ret c                   ; nothing waits
    push bc
    call RollCopyRow
    pop bc
    dec b
    jr nz, .hLoop
    ret

; -> Z if nothing waits to be copied to the hidden map. Clobbers a, hl.
HiddenPending:
    ld a, [wDirtyH]
    and 3
    ret nz
    ld hl, wMaskH
    ld a, [hl+]
    or [hl]
    inc hl
    or [hl]
    inc hl
    or [hl]
    ret

; hl = a row mask (4 bytes), a = ring row 0..31: set its bit. Clobbers a, d, e, hl.
SetRowBit:
.byte:
    cp 8
    jr c, .lo
    sub 8
    inc hl
    jr .byte
.lo:
    ld d, a                 ; bit number
    ld e, 1
    inc d
.shift:
    dec d
    jr z, .set
    sla e
    jr .shift
.set:
    ld a, [hl]
    or e
    ld [hl], a
    ret

; hl = a row mask (4 bytes) -> c = the lowest ring row that is set (its bit is cleared) and
; carry clear, or carry set when the mask is empty. Keeps b. Clobbers a, d, e, hl.
TakeRow:
    ld c, 0
    ld a, [hl]
    and a
    jr nz, .go
    inc hl
    ld c, 8
    ld a, [hl]
    and a
    jr nz, .go
    inc hl
    ld c, 16
    ld a, [hl]
    and a
    jr nz, .go
    inc hl
    ld c, 24
    ld a, [hl]
    and a
    jr nz, .go
    scf
    ret
.go:
    ld d, a                 ; the byte
    push hl
    ld h, HIGH(LowBitTab)   ; the index of its lowest set bit (a 256-byte table, page aligned)
    ld l, a
    ld a, [hl]
    pop hl
    add c
    ld c, a
    ld a, d
    ld e, a
    dec a
    and e                   ; clear the lowest set bit
    ld [hl], a
    and a                   ; carry clear
    ret

; The page that is on screen = the live page (called when a picture is shown). Clobbers a.
ShowPageNow:
    ld a, [wPageAbs]
    ld [wShAbs], a
    ld a, [wPageAbs + 1]
    ld [wShAbs + 1], a
    ld a, [wPageSpan]
    ld [wShSpan], a
    ld a, [wDiv]
    ld [wShDiv], a
    ret

; wCopyMap / wCopyTop = the map the copy routines write to and the window it holds.
SetCopyVisible:
    ld a, [wShown]
    and a
    ld a, HIGH(_SCRN0)
    jr z, .set
    ld a, HIGH(_SCRN0) + 4  ; $9C00
.set:
    ld [wCopyMap], a
    ld a, [wShownTop]
    ld [wCopyTop], a
    ret

SetCopyHidden:
    ld a, [wShown]
    and a
    ld a, HIGH(_SCRN0) + 4
    jr z, .set
    ld a, HIGH(_SCRN0)
.set:
    ld [wCopyMap], a
    ld a, [wRollTop]
    ld [wCopyTop], a
    ret

; A one-pitch scroll is pending (the window moved by one pitch, wRollTop != wShownTop). Three
; rows change: the entering pitch row, the ruler and the status line at their new ring rows. One
; of the two (the ruler when scrolling up, the status line when scrolling down) lands on a row
; nobody sees, so it is written one frame early (wVPre); the next frame writes the other two rows
; and moves SCY. -> carry set if it used this frame, carry clear if there is nothing (yet) to do.
; Needs the shown map (wCopyMap) to be set. Keeps de.
VScrollStep:
    push de
    ld a, [wRollTop]
    ld hl, wShownTop
    sub [hl]
    jp z, .none             ; no scroll pending
    ld b, 0                 ; b = entering grid row: 0 = top (scrolling up), 15 = bottom (down)
    cp 1
    jr z, .step
    ld b, ROLL_ROWS - 1
    cp $FF
    jp nz, .none            ; (the main loop never leaves more than one pitch: it redraws instead)
.step:
    ld a, [wStatusRender]
    and a
    jp nz, .none            ; the status line is being rebuilt: wait
    ldh a, [rLY]
    cp 148
    jp nc, .none            ; too late in VBlank: next frame
    ld a, b
    call RingOfRow
    ld c, a                 ; c = ring row of the entering pitch
    add LOW(wRowRender)
    ld l, a
    ld h, HIGH(wRowRender)
    ld a, [hl]
    and a
    jp nz, .none            ; not rendered yet
    ld a, [wVPre]
    and a
    jr nz, .second
    ; ---- first frame: the row that is free (it is not in the shown window) gets its content
    ld a, [wRollTop]
    ld [wCopyTop], a        ; (the copy routines place the ruler / status line for the NEW window)
    push bc
    ld a, b
    and a
    jr nz, .preStatus
    ld hl, wDirty
    res 5, [hl]             ; (the ruler is copied now; a later change sets the bit again)
    call CopyRuler
    jr .preDone
.preStatus:
    ld hl, wDirty
    res 4, [hl]
    call CopyStatus
.preDone:
    pop bc
    ld a, 1
    ld [wVPre], a
    pop de
    scf
    ret
.second:
    ; ---- second frame: the entering pitch row and the other of the ruler / status line, then SCY
    ld a, b
    and a
    ld a, [wShownTop]       ; (old window) scrolling up: the old bottom pitch leaves; down: the old top
    jr nz, .down
    sub ROLL_ROWS - 1       ; a = old bottom pitch
.down:
    ld e, a
    ld a, 1
    sub e
    and RING_ROWS - 1       ; the leaving pitch's ring row (1 - p)
    ld hl, wMaskV
    call ClearRowBit        ; no copy may land on it any more (it becomes the ruler / status line)
    ld a, [wRollTop]
    ld [wShownTop], a
    ld [wCopyTop], a
    push bc
    ld a, b
    and a
    jr nz, .postRuler
    ld hl, wDirty
    res 4, [hl]
    call CopyStatus         ; scrolling up: the status line takes the leaving bottom row
    jr .postDone
.postRuler:
    ld hl, wDirty
    res 5, [hl]
    call CopyRuler          ; scrolling down: the ruler takes the leaving top row
.postDone:
    pop bc
    call RollCopyRow        ; c = the entering pitch row
    call ApplyScy
    xor a
    ld [wVPre], a
    pop de
    scf
    ret
.none:
    pop de
    and a
    ret

; hl = a row mask (4 bytes), a = ring row 0..31: clear its bit. Clobbers a, d, e, hl.
ClearRowBit:
.byte:
    cp 8
    jr c, .lo
    sub 8
    inc hl
    jr .byte
.lo:
    ld d, a
    ld e, 1
    inc d
.shift:
    dec d
    jr z, .clear
    sla e
    jr .shift
.clear:
    ld a, e
    cpl
    and [hl]
    ld [hl], a
    ret

; Decide where the playhead line should be (OAM X) for the tick that was played
; last, using the per-division pixel table. Outside VBlank, once per frame.
; wPlayX = X in OAM coordinates, or $FF when stopped / the tick is on another page.
RollPlayheadCalc:
    ld a, [wSeqPlay]
    and a
    jr z, .hide
    ld a, [wSeqCur]         ; (relative to the page that is on screen: a rebuilt one is not shown yet)
    ld e, a
    ld d, 0
    ld a, [wSeqCurSeg]
    and a
    jr z, .abs
    ld hl, SEQ_TICKS
    add hl, de
    ld d, h
    ld e, l
.abs:
    ld hl, wShAbs
    ld a, e
    sub [hl]
    ld e, a
    inc hl
    ld a, d
    sbc [hl]
    jr c, .hide             ; before the page
    jr nz, .hide            ; far after it
    ld b, e                 ; b = ticks since the page start
    ld a, [wShSpan]         ; ticks in a page
    cp b
    jr z, .hide
    jr c, .hide             ; after the page
    ld a, [wShDiv]
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

; ---------------------------------------------------------------- tables
SECTION "Roll tables", ROMX, BANK[1], ALIGN[8]
; the lowest set bit of every byte value (0 for 0): GENERATED by tools/gen_lowbit.py
LowBitTab:
INCLUDE "lowbit.inc"

; the wGrid slot address of every ring row, and row * 32
SlotTab:
FOR I, RING_ROWS
    dw wGrid + 20 * I
ENDR
MapTab:
FOR I, RING_ROWS
    dw 32 * I
ENDR
