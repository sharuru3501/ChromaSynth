; Song: up to NUM_PATS patterns (each 4 channels x SEQ_TICKS ticks) and a chain of up to
; CHAIN_LEN steps that says which pattern each channel plays (wChain: channel * CHAIN_LEN + step; wPlayPat holds the
; ones of the step that plays). There is one tick counter and one loop length for all channels: the step's length and
; time signature are those of CH1's pattern (docs/M20_PER_CHANNEL_CHAINS.md, step 3 will give a step its own).
;   wSongMode 0 = loop the edited pattern (the way it always was), 1 = play the chain
;   wEditBase / wPlayBase = base page of the edited / played pattern (src/ram.asm)
; The code lives in ROM bank 1 (nothing switches it; the MBC5 boots with bank 1 at $4000).
;
; Song screen (START+UP opens it, START+DOWN goes back):
;   row 6: the places 1-8 of the page's steps; row 11: '^' under the step that plays (song mode, when it is on the shown page);
;   row 12: PAGE n/4; the PLAY row says "PAGEn STEPn" (the page and the place of the step that plays; P = pattern); rows 7-10: CH1..CH4, each "[cursor][pattern]"
;   pad LEFT/RIGHT = step (the page follows), UP/DOWN = channel; A / B = the pattern of that channel's step +1 / -1
;   (a "-" is the end of the song on CH1, and silence on the other channels)
;   SELECT+LEFT / RIGHT = the loop range starts / ends here, SELECT+DOWN = this step alone, SELECT+UP = no range;
;   START+LEFT / RIGHT = LOOP / SONG mode (the piano roll edits the pattern of the cursor's cell)
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF ROW_SONG_INFO  EQU _SCRN0 + 2 * 32
DEF ROW_SONG_HDR   EQU _SCRN0 + 6 * 32
DEF ROW_SONG_GRID  EQU _SCRN0 + 7 * 32
DEF ROW_SONG_MARK  EQU _SCRN0 + 11 * 32
DEF ROW_SONG_PAGE  EQU _SCRN0 + 12 * 32
DEF PAGE_STEPS     EQU 8        ; steps on a screen page (a page = one row of the grid per channel)

SECTION "Song", ROMX, BANK[1]

; Chain = pattern 1 only (on every channel), loop mode, pattern 1 edited and played.
ChainReset:
    ld hl, wChain
    ld bc, CHAIN_BYTES
    ld a, CHAIN_END
.fill:
    ld [hl+], a
    dec bc
    ld d, a                 ; (a stays CHAIN_END: only the flags of bc are tested)
    ld a, b
    or c
    ld a, d
    jr nz, .fill
    xor a
    ld [wChain], a
    ld [wChain + CHAIN_LEN], a
    ld [wChain + 2 * CHAIN_LEN], a
    ld [wChain + 3 * CHAIN_LEN], a
    ld [wChainPos], a
    ld [wSongMode], a
    ld [wEditPat], a
    ld [wPendActive], a
    ld [wSongCur], a
    call RangeClear
    jr LoadStepPats

; a = chain step -> wPlayPat (the pattern of each channel in that step), wPlayBank (the pattern + 1 of its first channel that
; has one: it is "the" pattern of the step for the PLAY row and for the bar length), and the step's timing: wChLen (each
; channel's pattern length in ticks, 0 = silent), wChPos (all back to the start), wStepLen (the longest of them: the step lasts
; that long, a shorter pattern repeats inside it) and wStepBarTicks (the bar length of the first pattern: the time signature
; of the step). Reads the patterns' lengths and time signatures from their slots (callers that play: TsStore first, so that the
; edited pattern's live values are there). Clobbers a, bc, de, hl.
LoadStepPats:
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de
    ld de, wPlayPat
    ld b, NUM_CH
.ch:
    ld a, [hl]
    ld [de], a
    inc de
    push de
    ld de, CHAIN_LEN
    add hl, de
    pop de
    dec b
    jr nz, .ch
    xor a
    ld [wStepLen], a
    ld [wStepLen + 1], a
    ld [wStepBarTicks], a
    ld [wPlayBank], a
    ld c, 0                 ; c = channel
.len:
    ld hl, wChPos           ; every channel starts at the beginning of its pattern
    ld a, c
    add a
    ld e, a
    ld d, 0
    add hl, de
    xor a
    ld [hl+], a
    ld [hl], a
    ld hl, wPlayPat
    ld e, c
    ld d, 0
    add hl, de
    ld a, [hl]
    cp NUM_PATS
    jr c, .has
    ld de, 0                ; no pattern: silent
    jr .setLen
.has:
    ld b, a
    push bc
    call PatLenTicks        ; de = ticks, c = bar ticks
    ld a, [wPlayBank]
    and a
    jr nz, .notFirst
    ld a, c                 ; the first channel with a pattern gives the step its time signature and its number
    ld [wStepBarTicks], a
    pop bc
    ld a, b
    inc a
    ld [wPlayBank], a
    push bc
.notFirst:
    pop bc
    ld a, [wStepLen + 1]    ; the step is as long as its longest pattern
    cp d
    jr c, .longer
    jr nz, .setLen
    ld a, [wStepLen]
    cp e
    jr nc, .setLen
.longer:
    ld a, e
    ld [wStepLen], a
    ld a, d
    ld [wStepLen + 1], a
.setLen:
    ld hl, wChLen
    ld a, c
    add a
    ld b, 0
    ld c, a
    add hl, bc
    ld [hl], e
    inc hl
    ld [hl], d
    srl c                   ; (back to the channel number)
    inc c
    ld a, c
    cp NUM_CH
    jr c, .len
    ld a, [wPlayBank]
    and a
    ret nz
    inc a                   ; (a step with no pattern at all: pattern 1 as a stand-in)
    ld [wPlayBank], a
    ld a, 48
    ld [wStepBarTicks], a
    ld a, 192
    ld [wStepLen], a
    ret

; a = pattern index (0..NUM_PATS-1) -> de = its length in ticks (bars x bar ticks, at most 384), c = its bar ticks.
; Clobbers a, b, hl.
PatLenTicks:
    ld e, a
    ld d, 0
    ld hl, wPatTsd
    add hl, de
    ld a, [hl]
    ld c, a
    ld hl, wPatBars
    add hl, de
    ld a, [hl]
    and a
    jr nz, .bars
    inc a
.bars:
    push af                 ; the bars
    ld hl, wPatTsn
    add hl, de
    ld a, [hl]
    call TsBarTicks         ; a = bar ticks
    ld c, a
    pop af
    ld b, a
    ld hl, 0
    ld d, 0
    ld e, c
.mul:
    add hl, de
    dec b
    jr nz, .mul
    ld a, h
    and a
    jr z, .fits             ; under 256
    cp 1
    jr nz, .cap             ; 512 or more
    ld a, l
    cp $81
    jr c, .fits             ; 384 ($0180) or less
.cap:
    ld hl, TOTAL_TICKS
.fits:
    ld d, h
    ld e, l
    ret

; a = chain step -> carry set if any channel has a pattern there. Keeps bc, hl.
StepHasPat:
    push bc
    push hl
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de
    ld b, NUM_CH
    ld de, CHAIN_LEN
.look:
    ld a, [hl]
    cp NUM_PATS
    jr c, .yes
    add hl, de
    dec b
    jr nz, .look
    pop hl
    pop bc
    and a                   ; (carry clear)
    ret
.yes:
    pop hl
    pop bc
    scf
    ret

; The sequencer starts. LOOP: the step under the song screen's cursor, again and again. SONG: from the cursor's step when the song
; screen is shown, from the first one otherwise.
SongRestart:
    ld a, [wSongMode]
    and a
    ld a, [wSongCur]
    jr z, .have             ; LOOP: the cursor's step
    ld a, [wScreen]
    cp SCREEN_SONG
    ld a, 0
    jr nz, .fit             ; SONG, another screen: the first step
    ld a, [wSongCur]
.fit:                       ; with a loop range: a step outside it starts on the range's first step
    ld b, a
    ld a, [wRangeEnd]
    cp $FF
    jr z, .fitDone
    ld c, a                 ; c = the end
    ld a, [wRangeStart]
    ld d, a
    ld a, b
    cp d
    jr c, .toStart          ; before the range
    ld a, c
    cp b
    jr nc, .fitDone         ; inside
.toStart:
    ld b, d
.fitDone:
    ld a, b
.have:
    ld [wChainPos], a
    xor a
    ld [wQueuedStep], a
    call TsStore            ; (the edited pattern's live length and time signature go to its slot: they are read from there)
    ld a, [wChainPos]
    call LoadStepPats
    ld a, [wDirtySong]
    or 1                    ; the PLAY row
    ld [wDirtySong], a
    jr SongMarkPos

; Redraw the marker row of the song screen (the '^' under the step that is playing).
SongMarkPos:
    ld a, [wDirtySong]
    or %01000001            ; the marker row and the PLAY row (it names the step)
    ld [wDirtySong], a
    ret

; The pattern ended in song mode: the next chain step (back to the first after the last).
SongNext:
    ld a, 1
    ld [wSongWrap], a       ; (SeqStep releases the old pattern's notes before tick 0 of the next)
    call SongMarkPos        ; the old step loses its marks
    ld a, [wRangeEnd]
    cp $FF
    jr z, .noRange
    ld b, a                 ; b = the end of the loop range
    ld a, [wChainPos]
    cp b
    jr c, .insideRange
    ld a, [wRangeStart]     ; at the end of the range: back to its start
    ld c, a
    jr .ok
.insideRange:
    inc a
    ld c, a                 ; (inside the range every step plays, an empty one is silent)
    jr .ok
.noRange:
    ld a, [wChainPos]
    inc a
    ld c, a                 ; c = the next step
    cp CHAIN_LEN
    jr nc, .first
    ld a, c
    call StepHasPat         ; the song ends at the first step where no channel has a pattern
    jr c, .ok
.first:
    ld c, 0
.ok:
    ld a, c
    ld [wChainPos], a
    call TsStore            ; (the edited pattern's live length and time signature go to its slot)
    ld a, [wChainPos]
    call LoadStepPats
    jr SongMarkPos          ; the new step gets them

; a = pattern number (0..NUM_PATS-1): edit it. In loop mode it is played from now on too.
SongSetEdit:
    push af
    call TsStore            ; the pattern that was edited keeps its time signature and length
    pop af
; (SongEditTo: the same without TsStore: after a load the arrays are the truth)
SongEditTo:
    ld [wEditPat], a
    inc a
    ld [wEditBank], a
    ld [$FF70], a           ; the piano roll reads this bank
    call TsLoadEdit         ; the new one's time signature and length become the live ones
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    jp MarkSeqStatus

; A bar begins (SeqStep, before its first tick): in LOOP mode, a step that was chosen while playing (the cursor moved) takes over now.
; Its patterns start at the same bar number (its own bar length), or from the start when that is past its end. The notes of the old
; step stop. Clobbers a, b, c, d, e, hl.
SongBarStart:
    ld a, [wQueuedStep]
    and a
    ret z
    ld b, a
    xor a
    ld [wQueuedStep], a
    ld a, [wSongMode]
    and a
    ret nz                  ; (SONG: the chain decides)
    ld a, b
    dec a
    ld [wChainPos], a       ; the step that plays now
    call SeqSilence
    call TsStore
    ld a, [wChainPos]
    call LoadStepPats
    call PlayInfo           ; the new step's bar length and loop end
    ld a, [wBarIdx]         ; it goes on at the same bar number (its own bar length), or from the
    ld b, a                 ; start when that is past its end
    ld a, [wPBarTicks]
    ld e, a
    ld d, 0
    ld hl, 0
.pos:
    ld a, b
    and a
    jr z, .posDone
    add hl, de
    dec b
    jr .pos
.posDone:                   ; hl = the tick the bar starts at
    ld a, [wLoopSeg]
    ld de, 0
    and a
    jr z, .total
    ld de, SEQ_TICKS
.total:
    ld a, [wLoopTail]
    add e
    ld e, a
    jr nc, .compare
    inc d                   ; de = ticks in the whole loop of the new pattern
.compare:
    ld a, h
    cp d
    jr c, .inside
    jr nz, .past
    ld a, l
    cp e
    jr c, .inside
.past:
    ld hl, 0
    xor a
    ld [wBarIdx], a         ; (the loop of the new pattern starts over)
.inside:
    ld a, h
    and a
    jr nz, .second          ; 256 or more
    ld a, l
    cp SEQ_TICKS
    jr c, .first
.second:
    ld de, -SEQ_TICKS
    add hl, de
    ld a, 1
    ld [wSeqSeg], a
    ld a, l
    ld [wSeqTick], a
    jr .placed
.first:
    xor a
    ld [wSeqSeg], a
    ld a, l
    ld [wSeqTick], a
.placed:
    call ChPosFromGlobal    ; every channel goes on at its own place inside its pattern
    call SongMarkPos
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    jp MarkSeqStatus

; Every channel with a pattern: its place = the step's position (wSeqSeg / wSeqTick) modulo its pattern length. Clobbers a, bc, de, hl.
ChPosFromGlobal:
    ld c, 0
.each:
    ld hl, wChLen
    ld a, c
    add a
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl]
    ld d, a                 ; de = the length of this channel's pattern
    or e
    jr z, .next             ; (silent)
    push de
    ld a, [wSeqSeg]
    ld hl, 0
    and a
    jr z, .tick
    ld hl, SEQ_TICKS
.tick:
    ld a, [wSeqTick]
    add l
    ld l, a
    jr nc, .mod
    inc h                   ; hl = the position in the step
.mod:
    ld a, h
    cp d
    jr c, .done
    jr nz, .sub
    ld a, l
    cp e
    jr c, .done
.sub:
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
    jr .mod
.done:
    push hl
    ld a, c
    add a
    ld e, a
    ld d, 0
    ld hl, wChPos
    add hl, de
    pop de                  ; de = the place inside the pattern
    ld [hl], e
    inc hl
    ld [hl], d
    pop af                  ; (the length)
.next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .each
    ret

; LOOP mode: the step reached its end: it plays again (its patterns are read from the chain anew), or the step that was chosen
; meanwhile takes over. Clobbers a, bc, de, hl.
LoopAgain:
    ld a, [wQueuedStep]
    and a
    jr z, .same
    dec a
    ld [wChainPos], a
    xor a
    ld [wQueuedStep], a
.same:
    call SongMarkPos        ; (the PLAY row may name another step)
    call TsStore
    ld a, [wChainPos]
    jp LoadStepPats

; LOOP mode, playing: the cursor stands on another step than the one that plays: that one takes over at the next bar line.
; (On the same step: nothing waits.) Clobbers a, b, hl.
LoopFollow:
    ld a, [wSongMode]
    and a
    ret nz                  ; (SONG: the chain decides)
    ld a, [wSeqPlay]
    and a
    ret z                   ; (stopped: the start takes the cursor's step)
    ld a, [wSongCur]
    ld b, a
    ld a, [wChainPos]
    cp b
    jr z, .cancel
    ld a, b
    inc a
    jr .set
.cancel:
    xor a
.set:
    ld [wQueuedStep], a
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    ret

; A step that plays has to measure its patterns again (the loop length of the edited one changed): its lengths and its end are
; recalculated, the places of the channels are kept. Clobbers a, bc, de, hl.
RefreshStepLen:
    ld a, [wSeqPlay]
    and a
    ret z
    ld hl, wChPos
    ld de, wChPosSave
    ld b, 2 * NUM_CH
.save:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .save
    call TsStore
    ld a, [wChainPos]
    call LoadStepPats
    ld hl, wChPosSave
    ld de, wChPos
    ld b, 2 * NUM_CH
.back:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .back
    ret

; A song was loaded: a damaged chain is repaired (an unknown number ends it, step 0 plays), the
; first pattern is edited, loop mode. Clobbers a, b, hl.
SongLoaded:
    ld hl, wChain
    ld b, CHAIN_BYTES       ; (128: fits a byte)
.fix:
    ld a, [hl]
    cp NUM_PATS
    jr c, .ok
    ld a, CHAIN_END
    ld [hl], a
.ok:
    inc hl
    dec b
    jr nz, .fix
    xor a
    call StepHasPat
    jr c, .keep
    xor a
    ld [wChain], a          ; a song has at least one step (CH1 plays pattern 1 in it)
.keep:
    xor a                   ; the per-pattern time signatures and lengths: bad values are blanked, and a
    ld [wBCBar], a          ; song saved before they existed (all 0) takes the one in the MIDI block
.pat:                       ; (wBCBar = the pattern index: a free variable here)
    ld a, [wBCBar]
    ld e, a
    ld d, 0
    ld hl, wPatTsn
    add hl, de
    ld a, [hl]
    cp 17
    jr c, .tsnOk
    xor a
    ld [hl], a
.tsnOk:
    ld b, a                 ; b = numerator
    ld hl, wPatTsd
    add hl, de
    ld a, [hl]
    cp 3
    jr c, .tsdOk
    xor a
    ld [hl], a
.tsdOk:
    or b
    jr nz, .bars            ; this pattern has its own time signature
    ld hl, wPatTsn
    add hl, de
    ld a, [wPatch + MIDI_BLOCK + PM_TSN]
    ld [hl], a
    ld hl, wPatTsd
    add hl, de
    ld a, [wPatch + MIDI_BLOCK + PM_TSD]
    ld [hl], a
.bars:
    ld hl, wPatBars
    add hl, de
    ld a, [hl]
    cp MAX_BARS + 1
    jr c, .barsOk
    xor a
.barsOk:
    and a
    jr nz, .storeBars
    ld a, [wSeqBars]        ; (the song's one loop length of before)
    and a
    jr nz, .storeBars
    inc a
.storeBars:
    ld [hl], a
    ld a, [wBCBar]
    inc a
    ld [wBCBar], a
    cp NUM_PATS
    jr c, .pat
    xor a
    ld [wSongMode], a
    ld [wChainPos], a
    ld [wPendActive], a
    call RangeClear
    ld a, 1                 ; the pattern of the cursor's cell (the first step) is edited; its values were not stored over the arrays
    ld [wEditBank], a
    xor a
    ld [wSongCur], a
    ld a, [wSelCh]
    cp NUM_CH
    jr nc, .firstPat
    call CellPtr
    ld a, [hl]
    cp NUM_PATS
    jr c, .editIt
.firstPat:
    xor a
.editIt:
    jp SongEditTo

; ---------------------------------------------------------------- the roll edits the pattern of the cursor's cell
; The cell is (channel wSelCh, step wSongCur): the pattern in it is the edited one (wEditPat), so what the piano roll shows
; and writes is what the chain plays there. An empty cell ("-") gets a pattern nobody uses as a candidate: it is only put in
; the chain (CommitPending) when it gets its first note, so looking at an empty cell leaves the song as it was.

; The edited pattern becomes the one in the cursor's cell. Call it when the channel or the step of the cursor changed.
; Clobbers a, bc, de, hl.
SyncEdit:
    call CommitPending
    ld a, [wSelCh]
    cp NUM_CH
    ret nc                  ; (the edit screen's settings page is no channel)
    call CellPtr            ; hl = the cell
    ld a, [hl]
    cp NUM_PATS
    jp c, SongSetEdit
    call FindUnusedPat      ; an empty cell: a pattern nobody uses ...
    cp NUM_PATS
    ret nc                  ; (all of them are in use: the edited one stays)
    ld b, a
    ld a, [wSelCh]
    ld [wPendCh], a
    ld a, [wSongCur]
    ld [wPendStep], a
    ld a, 1
    ld [wPendActive], a     ; ... that goes into the chain with its first note
    ld a, b
    jp SongSetEdit

; -> hl = the chain cell of channel wSelCh at step wSongCur. Clobbers a, de.
CellPtr:
    ld a, [wSelCh]
    swap a
    add a                   ; channel * 32
    ld e, a
    ld a, [wSongCur]
    add e
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de
    ret

; A pattern that was only a candidate for an empty cell goes into the chain once its channel holds a note; otherwise it is
; dropped. Clobbers a, bc, de, hl.
CommitPending:
    ld a, [wPendActive]
    and a
    ret z
    xor a
    ld [wPendActive], a
    ld a, [wEditPat]
    ld b, a                 ; (the pattern)
    ld a, [wPendCh]
    ld c, a
    ld a, b
    ld b, c                 ; b = channel
    ld c, 0                 ; first half
    push af
    call PageEntry
    ld a, [hl]
    cp NO_PAGE
    jr nz, .has
    pop af
    push af
    ld c, 1
    call PageEntry
    ld a, [hl]
    cp NO_PAGE
    jr nz, .has
    pop af
    ret                     ; nothing was written: not in the chain
.has:
    pop af
    ld c, a                 ; c = the pattern
    ld a, [wPendCh]
    swap a
    add a
    ld e, a
    ld a, [wPendStep]
    add e
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de
    ld [hl], c
    ret

; a = pattern: it goes into the cursor's cell and is the edited one. Clobbers a, bc, de, hl.
SetCellPattern:
    ld c, a
    call CellPtr
    ld [hl], c
    xor a
    ld [wPendActive], a
    ld a, c
    jp SongSetEdit

; -> a = a pattern number that no chain cell of the channel wSelCh uses (the channels do not share numbers: each has its own
; row of the chain and its own part of every pattern), preferably one whose part of this channel holds no notes;
; $FF if all 16 are in the channel's row. Clobbers bc, de, hl.
FindUnusedPat:
    xor a
    ld [wUsedMask], a
    ld [wUsedMask + 1], a
    ld a, [wSelCh]
    swap a
    add a
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de              ; the channel's row
    ld b, CHAIN_LEN
.scan:
    ld a, [hl+]
    cp NUM_PATS
    jr nc, .skip
    push hl
    push bc
    call UsedBit            ; (sets the bit)
    pop bc
    pop hl
.skip:
    dec b
    jr nz, .scan
    xor a
    ld c, a                 ; pass 1: unused and empty
.p1:
    ld a, c
    call TestUsed
    jr nz, .p1next
    ld a, c
    call PatIsEmpty
    jr nc, .p1next
    ld a, c
    ret
.p1next:
    inc c
    ld a, c
    cp NUM_PATS
    jr c, .p1
    xor a
    ld c, a                 ; pass 2: unused
.p2:
    ld a, c
    call TestUsed
    jr nz, .p2next
    ld a, c
    ret
.p2next:
    inc c
    ld a, c
    cp NUM_PATS
    jr c, .p2
    ld a, $FF
    ret

; a = pattern -> sets its bit in wUsedMask. Clobbers a, b, hl.
UsedBit:
    call UsedMaskBit
    or [hl]
    ld [hl], a
    ret

; a = pattern -> nz if its bit in wUsedMask is set. Keeps c. Clobbers a, b, hl.
TestUsed:
    call UsedMaskBit
    and [hl]
    ret

; a = pattern 0..15 -> hl = the byte of wUsedMask that holds it, a = the bit's mask. Clobbers b.
UsedMaskBit:
    ld hl, wUsedMask
    cp 8
    jr c, .lo
    inc hl
    sub 8
.lo:
    ld b, a
    ld a, 1
.shift:
    inc b
    dec b
    ret z
    dec b
    add a
    jr .shift

; a = pattern -> carry set if its part of the channel wSelCh holds no notes (neither half has a page). Keeps c. Clobbers a, b, hl.
PatIsEmpty:
    push bc
    add a
    add a
    add a                   ; pattern * 8
    ld b, a
    ld a, [wSelCh]
    add a                   ; channel * 2
    add b
    add LOW(wPatPage)
    ld l, a
    ld h, HIGH(wPatPage)
    ld a, [hl+]
    cp NO_PAGE
    jr nz, .notEmpty
    ld a, [hl]
    cp NO_PAGE
    jr nz, .notEmpty
    pop bc
    scf
    ret
.notEmpty:
    pop bc
    and a                   ; (carry clear)
    ret

; ---------------------------------------------------------------- the song screen
; Called with the LCD off after the screen was cleared.
BuildSong:
    ld hl, _SCRN0 + 4
    ld de, sSongTitle
    call DrawString
    ld hl, ROW_SONG_INFO
    ld de, sSongMode
    call DrawString
    ld hl, ROW_SONG_INFO + 32
    ld de, sSongEdit
    call DrawString
    ld hl, ROW_SONG_INFO + 32 + 9
    ld de, sSongEditNote
    call DrawString
    ld hl, _SCRN0 + 5 * 32
    ld de, sSongStepLbl     ; over the numbers 1-8 below it
    call DrawString
    ld hl, _SCRN0 + 13 * 32
    ld de, sSongHelp1
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sSongHelp2
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sSongHelp3
    call DrawString
    ld hl, _SCRN0 + 16 * 32
    ld de, sSongHelp4
    call DrawString
    ld hl, _SCRN0 + 17 * 32
    ld de, sSongHelp5
    call DrawString
    ld a, %11111111         ; the info rows, the header, the four channel rows and the MEM row
    ld [wDirtySong], a
    ret

; One dirty row of the song screen per frame (called from UpdateUI inside VBlank).
UpdateSong:
    ld a, [wDirty]
    and DIRTY_MSG
    ld [wDirty], a          ; the play-screen bits mean nothing here
    ld a, [wDirtySong]
    and a
    ret z
    ld c, 0
.find:
    rra
    jr c, .found
    inc c
    jr .find
.found:
    ld hl, DirtyBits
    call HLplusC
    ld a, [hl]
    cpl
    ld hl, wDirtySong
    and [hl]
    ld [hl], a
.dispatch:
    ld a, c
    and a
    jp z, .info
    cp 7
    jp z, .mem
    cp 1
    jr z, .header
    cp 6
    jp z, .marker
    sub 2                   ; channel row 0..3
    ld b, a
    swap a
    add a                   ; channel * 32 = its row offset and its first chain offset
    ld c, a
    ld e, a
    ld d, 0
    ld hl, ROW_SONG_GRID
    add hl, de
    ld a, [wSongCh]
    cp b
    ld a, $FF               ; (no cursor in this row)
    jr nz, .cursorSet
    ld a, [wSongCur]
    add c
.cursorSet:
    ld [wSongCurDraw], a    ; the chain offset (channel * 32 + step) the cursor is on
    ld a, [wSongCur]
    and -PAGE_STEPS         ; the page's first step
    add c
    ld c, a                 ; c = chain offset of the first cell
    ld a, 'C' - 32
    ld [hl+], a
    ld a, b
    add '1' - 32
    ld [hl+], a
    push hl
    ld hl, wChain
    ld b, 0
    add hl, bc
    ld d, h
    ld e, l                 ; de = the cell's pattern number
    pop hl
    ld b, PAGE_STEPS
.cell:
    ld a, [wSongCurDraw]
    cp c
    ld a, 0
    jr nz, .sep
    ld a, '>' - 32
.sep:
    ld [hl+], a
    ld a, [de]
    inc de
    cp NUM_PATS
    jr nc, .endMark
    inc a
    call PatTile
    jr .digit
.endMark:
    ld a, '-' - 32
.digit:
    ld [hl+], a
    inc c
    dec b
    jr nz, .cell
    ret
.header:                    ; "  " then per step " n" (n = place in the page, 1-8); the page text goes to row 12
    ld a, [wSongCur]
    and -PAGE_STEPS
    ld c, a                 ; c = the page's first step
    ld hl, ROW_SONG_HDR
    xor a
    ld [hl+], a
    ld [hl+], a
    ld b, PAGE_STEPS
.hcell:
    call RangeMark          ; the cell before the number: '[' where the range starts, ']' just after its last step
    ld [hl+], a
    ld a, c
    and PAGE_STEPS - 1
    inc a                   ; the step's place in its page, 1..8 (the page number is at the right end)
    add '0' - 32
    ld [hl+], a
    inc c
    dec b
    jr nz, .hcell
    ld a, [wRangeEnd]       ; a range that ends on the last step of the page: its ']' goes after the last number
    inc a
    cp c
    ld a, 0
    jr nz, .noClose
    ld a, ']' - 32
.noClose:
    ld [hl], a
    ld hl, ROW_SONG_PAGE + 12
    ld de, sSongPage
    call DrawString
    ld a, [wSongCur]
    rrca
    rrca
    rrca
    and 3
    inc a
    add '0' - 32
    ld hl, ROW_SONG_PAGE + 17
    ld [hl], a
    ret
.marker:                    ; blank, then per step " ^" under the one that plays (nothing when it is on another page)
    ld a, [wSongCur]
    and -PAGE_STEPS
    ld c, a                 ; c = the page's first step
    ld hl, ROW_SONG_MARK
    xor a
    ld [hl+], a
    ld [hl+], a
    ld b, PAGE_STEPS
.mcell:
    xor a
    ld [hl+], a
    call StepPlaying
    ld a, 0
    jr nc, .mdraw
    ld a, '^' - 32
.mdraw:
    ld [hl+], a
    inc c
    dec b
    jr nz, .mcell
    ret
.mem:                       ; MEM nnn%: how much of the pattern memory is used (a row of its own: one row a frame fits VBlank)
    ld hl, _SCRN0 + 32 + 4
    ld de, sSongMem
    call DrawString
    ld a, [wPoolPct]
    ld hl, _SCRN0 + 32 + 8
    call DrawDec3
    ld a, '%' - 32
    ld [hl], a
    ret
.info:
    ld hl, ROW_SONG_INFO + 6
    ld de, sLoop
    ld a, [wSongMode]
    and a
    jr z, .drawMode
    ld de, sSong
.drawMode:
    call DrawString
    ld hl, ROW_SONG_INFO + 11       ; LOOP, playing, another step chosen: "NEXT p-s" until it takes over at the next bar line
    ld b, 9
    xor a
.nextBlank:
    ld [hl+], a
    dec b
    jr nz, .nextBlank
    ld a, [wQueuedStep]
    and a
    jr z, .noNext
    dec a
    ld b, a                 ; b = the step
    ld hl, ROW_SONG_INFO + 11
    ld de, sSongNext
    call DrawString
    ld hl, ROW_SONG_INFO + 16
    ld a, b
    rrca
    rrca
    rrca
    and 3
    inc a
    add '0' - 32
    ld [hl+], a
    ld a, '-' - 32
    ld [hl+], a
    ld a, b
    and PAGE_STEPS - 1
    inc a
    add '0' - 32
    ld [hl], a
.noNext:
    ld hl, ROW_SONG_INFO + 32 + 6
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wEditPat]
    inc a
    call PatTile
    ld [hl], a
    ld hl, ROW_SONG_INFO + 64       ; PLAY P1  [NEXT P2]
    ld b, 20
    xor a
.infoBlank:
    ld [hl+], a
    dec b
    jr nz, .infoBlank
    ld hl, ROW_SONG_INFO + 64
    ld de, sSongPlay
    call DrawString
    ld hl, ROW_SONG_INFO + 64 + 6
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wPlayBank]
    call PatTile            ; (the pattern number + 1)
    ld [hl+], a
    ld a, [wSeqPlay]
    and a
    ret z
    ld hl, ROW_SONG_INFO + 64 + 9   ; playing: "PAGEn STEPn" (the place of the playing step, as the grid numbers it)
    ld de, sSongPlayAt
    call DrawString
    ld a, [wChainPos]
    rrca
    rrca
    rrca
    and 3
    inc a
    add '0' - 32
    ld hl, ROW_SONG_INFO + 64 + 13
    ld [hl], a
    ld a, [wChainPos]
    and PAGE_STEPS - 1
    inc a
    add '0' - 32
    ld hl, ROW_SONG_INFO + 64 + 19
    ld [hl], a
    ret

; c = chain step -> carry set if the sequencer is playing and this is the step it plays (LOOP: the one it repeats). Keeps all but a.
StepPlaying:
    ld a, [wSeqPlay]
    and a
    ret z
    ld a, [wChainPos]
    cp c
    jr nz, .no
    scf
    ret
.no:
    and a
    ret

; The loop range (steps wRangeStart .. wRangeEnd, $FF = none): SONG mode plays only inside it and starts over at its end. It is not
; saved (it is for the song being worked on right now). Setting one end of a missing range makes the other end the first / last step.

; Flag the header row (it shows the range) for redraw. Clobbers a, hl.
MarkHeader:
    ld a, [wDirtySong]
    or 2
    ld [wDirtySong], a
    ret

RangeClear:
    ld a, $FF
    ld [wRangeStart], a
    ld [wRangeEnd], a
    ret

; -> a = the last step of the song (before the first step where no channel has a pattern). Clobbers bc, de, hl.
LastSongStep:
    ld c, 1
.look:
    ld a, c
    cp CHAIN_LEN
    jr nc, .done
    call StepHasPat
    jr nc, .done
    inc c
    jr .look
.done:
    ld a, c
    dec a
    ret

; SELECT+LEFT: the range starts at the cursor's step.
RangeStartHere:
    ld a, [wRangeEnd]
    cp $FF
    jr nz, .have
    call LastSongStep
    ld [wRangeEnd], a       ; (no range yet: it reaches to the last step of the song)
.have:
    ld a, [wSongCur]
    ld [wRangeStart], a
    ld b, a
    ld a, [wRangeEnd]
    cp b
    jr nc, MarkHeader       ; (the end is not before the start)
    ld a, b
    ld [wRangeEnd], a
    jr MarkHeader

; SELECT+RIGHT: the range ends at the cursor's step.
RangeEndHere:
    ld a, [wRangeStart]
    cp $FF
    jr nz, .have
    xor a
    ld [wRangeStart], a     ; (no range yet: it starts at the first step)
.have:
    ld a, [wSongCur]
    ld [wRangeEnd], a
    ld b, a
    ld a, [wRangeStart]
    cp b
    jr c, MarkHeader        ; (the start is before the end)
    jr z, MarkHeader
    ld a, b
    ld [wRangeStart], a
    jr MarkHeader

; SELECT+DOWN: the range is the cursor's step alone.
RangeOne:
    ld a, [wSongCur]
    ld [wRangeStart], a
    ld [wRangeEnd], a
    jr MarkHeader

; a = 0 (LOOP) / 1 (SONG): the playing mode. A running sequencer starts over in the new mode. Clobbers a, bc, de, hl.
SongSetMode:
    ld b, a
    ld a, [wSongMode]
    cp b
    ret z
    ld a, b
    ld [wSongMode], a
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    ld a, [wSeqPlay]
    and a
    jp z, MarkSeqStatus
    call SeqSilence         ; (a running sequencer: what plays changes)
    call SongMarkPos
    jp SongRestart

; c = a step -> a = the tile for the cell before its number in the header: '[' if the loop range starts here, ']' if it ended at
; the step before, blank otherwise. Keeps bc, hl.
RangeMark:
    ld a, [wRangeEnd]
    cp $FF
    jr z, .none
    inc a
    cp c
    jr z, .close
    ld a, [wRangeStart]
    cp c
    jr nz, .none
    ld a, '[' - 32
    ret
.close:
    ld a, ']' - 32
    ret
.none:
    xor a
    ret

; d = buttons newly pressed.
SongInput:
    ld a, [wJoy]
    bit PADB_SELECT, a
    jr z, .plain
    ld a, d
    and $F0
    ret z
    ld a, 1
    ld [wSelUsed], a
    bit PADB_LEFT, d        ; SELECT + pad: the loop range (SONG mode plays only inside it)
    jr z, .notRangeL
    jp RangeStartHere
.notRangeL:
    bit PADB_RIGHT, d
    jr z, .notRangeR
    jp RangeEndHere
.notRangeR:
    bit PADB_DOWN, d
    jr z, .rangeUp
    jp RangeOne
.rangeUp:
    call RangeClear
    jp MarkHeader
.plain:
    bit PADB_A, d
    jr z, .notA
    ld c, 1
    jr StepValue
.notA:
    bit PADB_B, d
    jr z, .move
    ld c, $FF
    jr StepValue
.move:
    ld a, [wSongCur]
    ld b, a                 ; b = old step
    ld a, [wSongCh]
    ld c, a                 ; c = old channel
    bit PADB_LEFT, d
    jr z, .notL
    ld a, b
    and a
    ret z
    dec a
    jr .setStep
.notL:
    bit PADB_RIGHT, d
    jr z, .notR
    ld a, b
    cp CHAIN_LEN - 1
    ret nc
    inc a
.setStep:
    ld [wSongCur], a
    xor b                   ; another page: every row of the grid changes
    and -PAGE_STEPS
    jr nz, .allRows
    jr .twoRows
.notR:
    bit PADB_UP, d
    jr z, .notU
    ld a, c
    and a
    ret z
    dec a
    jr .setCh
.notU:
    bit PADB_DOWN, d
    ret z
    ld a, c
    cp NUM_CH - 1
    ret nc
    inc a
.setCh:
    ld [wSongCh], a
.twoRows:                   ; redraw the rows of the old and of the new cursor
    push bc
    call EditCursorCell     ; the roll edits the pattern in the cell under the cursor
    pop bc
    ld a, c
    call MarkChRow
    ld a, [wSongCh]
    jr MarkChRow
.allRows:
    call EditCursorCell
    ld a, [wDirtySong]
    or %01111110            ; the header, the four channel rows and the marker row
    ld [wDirtySong], a
    ret

; a = channel -> flag its row of the grid for redraw (bit 0 = info rows, 1 = header, channel c = bit c + 2, 6 = marker row)
MarkChRow:
    ld b, a
    ld a, 4
.shift:
    inc b
    dec b
    jr z, .done
    dec b
    add a
    jr .shift
.done:
    ld hl, wDirtySong
    or [hl]
    ld [hl], a
    ret

; c = +1 / $FF: the pattern number of the cell under the cursor (channel wSongCh, step wSongCur). The valid values are
; 0..NUM_PATS-1 and CHAIN_END; they go round. The end is not offered when it would leave the first step with no pattern at
; all (a song needs one step); anywhere else a cell may be the end (the song ends at the first step where all four are).
StepValue:
    ld a, [wSongCh]
    swap a
    add a                   ; channel * 32
    ld e, a
    ld a, [wSongCur]
    add e
    ld e, a
    ld d, 0
    ld hl, wChain
    add hl, de
    ld a, [wSongCur]
    and a
    ld b, 1                 ; b = 1: the end is allowed
    jr nz, .endKnown
    call OthersHavePat      ; step 1: only if another channel has a pattern there
    ld b, 0
    jr nc, .endKnown
    ld b, 1
.endKnown:
    ld a, [hl]
    bit 7, c
    jr nz, .back
    cp NUM_PATS
    jr nc, .toFirst         ; from the end: back to pattern 1
    inc a
    cp NUM_PATS
    jr c, .store            ; still a pattern
    ld a, b
    and a
    ld a, 0                 ; (the end is not allowed: round to pattern 1)
    jr z, .store
    ld a, CHAIN_END
    jr .store
.toFirst:
    xor a
    jr .store
.back:
    cp NUM_PATS
    jr nc, .toLast          ; from the end: the last pattern
    and a
    jr z, .wrap
    dec a
    jr .store
.wrap:
    ld a, b
    and a
    ld a, NUM_PATS - 1
    jr z, .store
    ld a, CHAIN_END
    jr .store
.toLast:
    ld a, NUM_PATS - 1
.store:
    ld [hl], a
    call EditCursorCell     ; (the cell changed: the edited pattern follows)
    ld a, [wSongCh]
    jr MarkChRow

; The channel of the song screen's cursor is the selected one, and the edited pattern is the one in its cell. Clobbers a, bc, de, hl.
EditCursorCell:
    ld a, [wSongCh]
    ld [wSelCh], a
    call SyncEdit
    jp LoopFollow           ; (LOOP, playing: the step under the cursor takes over at the next bar line)

; Carry set if a channel other than the cursor's has a pattern on the cursor's step. Keeps bc, hl.
OthersHavePat:
    push bc
    push hl
    ld hl, wChain
    ld a, [wSongCur]
    ld e, a
    ld d, 0
    add hl, de
    ld de, CHAIN_LEN
    ld a, [wSongCh]
    ld c, a                 ; c = the cursor's channel
    ld b, 0                 ; b = the channel being looked at
.look:
    ld a, b
    cp c
    jr z, .skip
    ld a, [hl]
    cp NUM_PATS
    jr c, .yes
.skip:
    add hl, de
    inc b
    ld a, b
    cp NUM_CH
    jr c, .look
    pop hl
    pop bc
    and a
    ret
.yes:
    pop hl
    pop bc
    scf
    ret

sSongTitle:  db "SONG CHAIN", 0
sSongMem:    db "MEM", 0
sSongMode:   db "MODE", 0
sSongEdit:   db "EDIT", 0
sSongPlay:   db "PLAY", 0
sSongNext:   db "NEXT", 0
sSongPlayAt: db "PAGE  STEP", 0
sSongPage:   db "PAGE  /4", 0
sSongStepLbl: db "STEP", 0
sSongEditNote: db "IN SEQ", 0
sLoop:       db "LOOP", 0
sSong:       db "SONG", 0
sSongHelp1:  db "PAD:MOVE A/B:PATTERN", 0
sSongHelp2:  db "SEL+LR:RANGE ST/END", 0
sSongHelp3:  db "SEL+D:1STEP U:CLEAR", 0
sSongHelp4:  db "ST+LR:LOOP/SONG", 0
sSongHelp5:  db "ST+DOWN:BACK", 0
