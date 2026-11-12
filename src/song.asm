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
;   row 12: PAGE n/4; the PLAY row says "STEP nn" for the step that plays (P = pattern, STEP = place in the chain, PAGE = screen page); rows 7-10: CH1..CH4, each "[cursor][pattern]"
;   pad LEFT/RIGHT = step (the page follows), UP/DOWN = channel; A / B = the pattern of that channel's step +1 / -1
;   (a "-" is the end of the song on CH1, and silence on the other channels)
;   SELECT+LEFT/RIGHT = the edited pattern, SELECT+UP/DOWN = loop / song mode
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
    jr LoadStepPats

; a = chain step -> wPlayPat (the pattern of each channel in that step) and wPlayBank (CH1's pattern + 1: its length and
; time signature are the step's; a step whose CH1 is not a pattern plays pattern 1). Clobbers a, bc, de, hl.
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
    ld a, [wPlayPat]
    cp NUM_PATS
    jr c, .ok
    xor a
.ok:
    inc a                   ; pattern number -> its WRAM bank
    ld [wPlayBank], a
    ret

; The sequencer starts: the first chain step (song mode) or the edited pattern (loop mode).
SongRestart:
    xor a
    ld [wChainPos], a
    ld a, [wSongMode]
    and a
    ld a, [wEditBank]
    jr z, .set
    xor a
    call LoadStepPats       ; wPlayBank = step 0's CH1 pattern + 1
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
    ld e, c
    ld d, 0
    ld hl, wChain
    add hl, de
    ld a, [hl]              ; (CH1 decides where the song ends)
    cp NUM_PATS
    jr c, .ok               ; a valid pattern number
.first:
    ld c, 0
.ok:
    ld a, c
    ld [wChainPos], a
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
    ld a, [wChain]
    cp NUM_PATS
    jr c, .keep
    xor a
    ld [wChain], a          ; a song has at least one step
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
    ld a, 1                 ; the first pattern is edited; its values were not stored over the arrays
    ld [wEditBank], a
    xor a
    jp SongEditTo

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
    ld de, sSongChain
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
    ld hl, ROW_SONG_PAGE + 2
    ld de, sSongPage
    call DrawString
    ld a, [wSongCur]
    rrca
    rrca
    rrca
    and 3
    inc a
    add '0' - 32
    ld hl, ROW_SONG_PAGE + 7
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
    ld hl, ROW_SONG_INFO + 64 + 9   ; song mode, playing: "STEP nn" (the chain decides what is next)
    ld de, sSongStep
    call DrawString
    ld hl, ROW_SONG_INFO + 64 + 13
    ld a, [wChainPos]
    inc a
    jp DrawDec3
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
    ld a, [wEditPat]
    bit PADB_LEFT, d
    jr z, .notLeft
    and a
    ret z
    dec a
    jp SongSetEdit
.notLeft:
    bit PADB_RIGHT, d
    jr z, .mode
    cp NUM_PATS - 1
    ret nc
    inc a
    jp SongSetEdit
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
    ld a, c
    call MarkChRow
    ld a, [wSongCh]
    jr MarkChRow
.allRows:
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
; 0..NUM_PATS-1 and CHAIN_END (not on CH1's step 0: a song needs one step); they go round.
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
    ld a, [wSongCh]
    ld b, a
    ld a, [wSongCur]
    or b
    ld b, a                 ; b = 0 only on CH1's step 0
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
    ld a, 0                 ; CH1's step 0 cannot be the end
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
    ld a, [wSongCh]
    jr MarkChRow

sSongTitle:  db "SONG CHAIN", 0
sSongMem:    db "MEM", 0
sSongMode:   db "MODE", 0
sSongEdit:   db "EDIT", 0
sSongPlay:   db "PLAY", 0
sSongNext:   db "NEXT", 0
sSongStep:   db "STEP", 0
sSongPage:   db "PAGE  /4", 0
sSongChain:  db "ORDER STEP:PATTERN", 0
sSongEditNote: db "IN SEQ", 0
sLoop:       db "LOOP", 0
sSong:       db "SONG", 0
sSongHelp1:  db "PAD:MOVE A/B:PATTERN", 0
sSongHelp2:  db "SEL+LR:EDIT PATTERN", 0
sSongHelp3:  db "SEL+UD:LOOP/SONG", 0
sSongHelp4:  db "ST+DOWN:BACK", 0
