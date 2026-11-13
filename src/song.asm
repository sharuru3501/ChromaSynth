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
;   SELECT+UP/DOWN = loop / song mode (the piano roll edits the pattern of the cursor's cell)
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

; The sequencer starts: the first chain step (song mode) or the edited pattern (loop mode).
SongRestart:
    xor a
    ld [wChainPos], a
    ld a, [wSongMode]
    and a
    ld a, [wEditBank]
    jr z, .set
    call TsStore
    xor a
    call LoadStepPats       ; wPlayBank = step 0's first pattern + 1
    jr .queue
.set:
    ld [wPlayBank], a
.queue:
    xor a
    ld [wQueuedBank], a     ; (a pattern that was waiting for a bar line is the played one now)
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
    ld a, [wSongMode]
    and a
    jr nz, .mark
    ld a, [wSeqPlay]
    and a
    jr nz, .queue
    ld a, [wEditBank]       ; stopped: it is the played pattern at once
    ld [wPlayBank], a
    xor a
    ld [wQueuedBank], a
    jr .mark
.queue:
    ld a, [wEditBank]       ; playing: it takes over at the next bar line (SongBarStart)
    ld hl, wPlayBank
    cp [hl]
    jr nz, .set
    xor a                   ; (back to the pattern that plays: nothing waits)
.set:
    ld [wQueuedBank], a
.mark:
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    jp MarkSeqStatus

; A bar begins (SeqStep, before its first tick): a pattern that was chosen while playing takes
; over now (loop mode). The notes of the old one stop. Clobbers a, b, c, hl.
SongBarStart:
    ld a, [wQueuedBank]
    and a
    ret z
    ld b, a
    xor a
    ld [wQueuedBank], a
    ld a, [wSongMode]
    and a
    ret nz                  ; (song mode: the chain decides)
    ld a, [wPlayBank]
    cp b
    ret z
    ld a, b
    ld [wPlayBank], a
    call SeqSilence
    call PlayInfo           ; the new pattern's bar length and loop end
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
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    jp MarkSeqStatus

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

; -> a = a pattern number that no chain cell uses, preferably one that holds no notes at all; $FF if every pattern is in use.
; Clobbers bc, de, hl.
FindUnusedPat:
    xor a
    ld [wUsedMask], a
    ld [wUsedMask + 1], a
    ld hl, wChain
    ld b, CHAIN_BYTES
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

; a = pattern -> carry set if it holds no notes at all (no page of any channel). Keeps c. Clobbers a, b, hl.
PatIsEmpty:
    push bc
    add a
    add a
    add a                   ; pattern * 8
    add LOW(wPatPage)
    ld l, a
    ld h, HIGH(wPatPage)
    ld b, 8
.look:
    ld a, [hl+]
    cp NO_PAGE
    jr nz, .notEmpty
    dec b
    jr nz, .look
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
    xor a
    ld [hl+], a
    ld a, c
    and PAGE_STEPS - 1
    inc a                   ; the step's place in its page, 1..8 (the page number is at the right end)
    add '0' - 32
    ld [hl+], a
    inc c
    dec b
    jr nz, .hcell
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
    ld a, [wSongMode]
    and a
    jr z, .queued
    ld a, [wSeqPlay]
    and a
    jr z, .queued
    ld hl, ROW_SONG_INFO + 64 + 9   ; song mode, playing: "PAGEn STEPn" (the place of the playing step, as the grid shows it)
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
.queued:
    ld a, [wQueuedBank]
    and a
    ret z
    inc hl
    ld de, sSongNext
    call DrawString
    inc hl
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wQueuedBank]
    call PatTile
    ld [hl], a
    ret

; c = chain step -> carry set if the sequencer is playing the chain and this is the step. Keeps all but a.
StepPlaying:
    ld a, [wSongMode]
    and a
    ret z                   ; (carry is clear)
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
    bit PADB_LEFT, d        ; (the edited pattern is the one in the cursor's cell now: SELECT+LEFT / RIGHT are free)
    ret nz
    bit PADB_RIGHT, d
    ret nz
.mode:
    ld a, [wSongMode]      ; SELECT+UP / DOWN
    xor 1
    ld [wSongMode], a
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    ld a, [wSeqPlay]
    and a
    jp z, MarkSeqStatus
    call SeqSilence         ; (a running sequencer: the pattern that plays changes)
    call SongMarkPos
    jp SongRestart          ; and the song starts from the top
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
    jp SyncEdit

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
sSongHelp2:  db "SEL+LR:EDIT PATTERN", 0
sSongHelp3:  db "SEL+UD:LOOP/SONG", 0
sSongHelp4:  db "ST+DOWN:BACK", 0
