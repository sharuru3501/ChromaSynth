; All work RAM lives here. wRingHead..wClearEnd is zeroed at boot.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

; Bytes waiting to go out to the bridge (main loop -> ISR). 256-byte ring that wraps
; naturally; the main loop owns wTxHead, the ISR owns wTxTail.
SECTION "MIDI tx ring", WRAM0, ALIGN[8]
wTx:            ds 256

; Aligned so that "base + small offset" never carries into the high byte.
SECTION "Patch", WRAM0, ALIGN[8]
wPatch:         ds NUM_PATCHES * PATCH_SIZE

; The segment pool: WRAM banks 1-7, 4 KB each, at $D000. Segment id n is in bank 1 + n / 4, its channel c at page $D0 + (n mod 4) * 4 + c
; (a page: the 192 ticks of a channel's 4 bars, one byte per tick). Which segment a pattern's half is in: wPatSeg (src/pool.asm).
; SVBK ($FF70) is set by every routine that touches the cells (SegLoc), so it is not fixed to anything. (Needs a CGB.)
SECTION "Pool 1", WRAMX[$D000], BANK[1]
wPool:          ds 4096
SECTION "Pool 2", WRAMX[$D000], BANK[2]
                ds 4096
SECTION "Pool 3", WRAMX[$D000], BANK[3]
                ds 4096
SECTION "Pool 4", WRAMX[$D000], BANK[4]
                ds 4096
SECTION "Pool 5", WRAMX[$D000], BANK[5]
                ds 4096
SECTION "Pool 6", WRAMX[$D000], BANK[6]
                ds 4096
SECTION "Pool 7", WRAMX[$D000], BANK[7]
                ds 4096

SECTION "Bitmap", WRAM0, ALIGN[5]
wBitmap:        ds SEQ_TICKS / 8    ; the decoder's copy of a channel's 24 bitmap bytes (32-byte aligned: no carry when indexed)

; per pattern, channel and half (index pattern * 8 + channel * 2 + half): the page id, or NO_PAGE. 128 bytes at a 128-byte boundary: base + index never carries.
SECTION "Pool table", WRAM0, ALIGN[7]
wPatPage:       ds NUM_PATS * PAT_PAGES
wPageSize:      ds POOL_PAGES       ; per page id: its coded size in bytes (EncodedPageSize)
wPoolBytes:     dw                  ; the sum of wPageSize over the pages that are lent
wPoolPct:       db                  ; wPoolBytes as a percentage of POOL_BYTES (0..100), for the song screen
wPageMap:       ds POOL_MAP         ; which page ids are lent (bit n of byte n / 8); the ZERO_PAGE bit is always set
wPoolTmp:       ds 4                ; scratch of the pool routines
wDummyCell:     db                  ; where a write goes that found no free page (never the zero page)
wSaveMask:      ds 16               ; which pages are in a save (bit pattern * 8 + channel * 2 + half; a version 10 save: pattern * 2 + segment)
wSaveDst:       dw                  ; where the next coded channel goes / comes from
wSaveIdx:       db                  ; the index being saved / loaded
wSaveVer:       db                  ; the version of the slot that ValidateSave looked at
wEncAcc:        db                  ; scratch of the coder
wLoadPage:      db                  ; scratch of the loaders
wDecIdx:        db                  ; scratch of the decoder: the bitmap byte

; Piano roll shadow tilemap (rows 1-16 of the screen, 20 columns each). It is
; rendered outside VBlank and copied to VRAM a few rows per frame.
SECTION "Roll grid", WRAM0
wGrid:          ds RING_ROWS * 20   ; one slot per ring row (see the piano-roll header in roll.asm)

; 16 render flags, 16 copy flags, 16 column pitches, 16 head flags: 64 bytes, 64-byte
; aligned so that base + index never carries into the high byte.
SECTION "Roll render flags", WRAM0, ALIGN[5]
wRowRender:     ds RING_ROWS    ; ring row must be re-rendered into wGrid
SECTION "Roll spans", WRAM0, ALIGN[6]
wSpanLo:        ds RING_ROWS    ; per ring row waiting to be copied: its first changed tile
wSpanHi:        ds RING_ROWS    ; and the end (exclusive); wSpanHi = wSpanLo + RING_ROWS
SECTION "Roll flags", WRAM0, ALIGN[5]
; Per column of the visible page: sounding pitch (0 = silence), then 1 = note head.
wColPitch:      ds SEQ_PAGE
wColHead:       ds SEQ_PAGE

; The roll is drawn into a map that is NOT shown and the two maps are swapped (LCDC bit 3) when
; it is complete, so a scroll or a page change never shows half old / half new rows.
SECTION "Roll flags H", WRAM0
wMaskV:         ds 4            ; bit r = ring row r waits to be copied to the shown map
wMaskH:         ds 4            ; the same for the hidden map (only while a full redraw is built)
wShownTop:      db              ; the pitch window (top pitch) of the picture on screen
wVPre:          db              ; 1 = the free row of a one-pitch scroll is already written (see VScrollStep)
wPageChanged:   db              ; RollScrollFix: 1 = the page (not just the pitch window) changed
wCopyTop:       db              ; ... of the map the copy routines write to
wShown:         db              ; 0 = $9800 is shown, 1 = $9C00
wBuild:         db              ; 1 = a full redraw is being built in the hidden map
wBuildReady:    db              ; 1 = every row of that redraw has been rendered
wDirtyH:        db              ; bit 0 = ruler, bit 1 = status line must be copied to the hidden map
wCopyMap:       db              ; HIGH of the map the copy routines write to
wRowBudget:     db              ; rows left to draw this frame (edit screen)
wCopyInit:      db              ; the copy budget at the start of the frame
wShSeg:         db              ; the page that is ON SCREEN (the live wPage* may already be the next one)
wShTick:        db
wShSpan:        db
wShDiv:         db

SECTION "Roll old cols", WRAM0, ALIGN[5]
wColOld:        ds SEQ_PAGE * 2

SECTION "Synth state", WRAM0, ALIGN[3]
wBase:          ds NUM_CH * 2   ; base period of the sounding note (lo, hi)
wOut:           ds NUM_CH * 2   ; last period written by the vibrato (debug/test)

SECTION "Vars", WRAM0
wRingHead:      db          ; written by ISR
wRingTail:      db          ; written by main loop
wTxHead:        db          ; next free slot in wTx (written by the main loop)
wTxTail:        db          ; next byte the ISR hands to the bridge
wCcValue:       db          ; MidiCC scratch: the raw CC value
wFollowLo:      db          ; SYNC_FOLLOW: the low part of the DAW's BPM (CC14), waiting for CC15
wExtTicks:      db          ; clock ticks received from the DAW and not played yet (0..4)
wVBlank:        db          ; frames (VBlank interrupts) since the main loop last looked (capped at 255)
wFrames:        db          ; the same, taken by the main loop for this pass: 1..4 (more than 1 = frames were lost)
wSeqCatch:      db          ; SeqTick: ticks it may still play this pass
wMidiStatus:    db          ; running status (0 = none)
wMidiCount:     db          ; data bytes received for current message
wMidiData1:     db
wLastRx:        db          ; last raw MIDI byte (shown on screen)
wJoy:           db
wJoyPrev:       db
wRepTimer:      db          ; frames until the held d-pad direction repeats
wBootTimer:     db          ; frames left of the boot beep
wSelCh:         db          ; channel the pad plays/edits (0..3)
wPadCh:         db          ; channel the A button was pressed on
wJoyNote:       db          ; note played by the A button
wScreen:        db          ; SCREEN_PLAY / SCREEN_EDIT
wScreenReq:     db          ; 0 = none, else requested screen + 1
wEditRow:       db          ; selected parameter row on the edit screen
wDirty:         db          ; play-screen rows needing redraw (see synth.inc)
wDirtyEdit:     db          ; edit-screen parameter rows needing redraw
wNoteVel:       db          ; velocity of the note being started (127 = full; MIDI sets it)
wMod:           ds NUM_CH   ; mod wheel (CC1) vibrato depth per GB channel (0..7)
wMidiChNum:     db          ; MIDI channel (1-16) of the message being handled
wMidiVel:       db
wMidiRR:        db          ; last GB channel that was stolen for a new note
wVoiceVol:      ds NUM_CH   ; volume nibble last used per channel (after velocity; debug/test)
wBend:          ds NUM_CH   ; pitch bend per GB channel: MIDI MSB 0..127, 64 = centre
wTickOn:        ds NUM_CH   ; 1 = this channel's period was last written with a modulation offset
wLenBit:        ds NUM_CH   ; $40 = the length counter is on for this channel (OR it into every NRx4 write)
wArpStep:       ds 3        ; CH1-3: 0 root, 1 +arp1, 2 +arp2
wArpTimer:      ds 3        ; frames to the next arpeggio step
wGlide:         ds 6        ; CH1-3: signed period offset of the slide, decays to 0
wDutyPh:        ds 2        ; CH1/2: 0 = the first duty, 1 = the second
wDutyTimer:     ds 2
wWasOn:         db          ; NoteOn: the note channel c was sounding before (0 = none)
wPrevOut:       dw          ; NoteOn: the period channel c was playing
wTickOff:       dw          ; scratch: vibrato offset while the bend offset is computed
wBendP:         db          ; scratch: (2048 - period) >> 3
wBendSign:      db
wCurNote:       ds NUM_CH   ; sounding note per channel, 0 = silent
wVibPh:         ds NUM_CH   ; vibrato phase per channel
wSeqPlay:       db          ; 1 = sequencer running
wSeqTick:       db          ; next tick to play inside the segment (0..SEQ_TICKS-1)
wSeqCur:        db          ; tick that was played last (playhead)
wSeqAcc:        dw          ; 8.8 frame accumulator
wBpm:           db
wPatTsn:        ds NUM_PATS ; per pattern: the time signature's numerator ...
wPatTsd:        ds NUM_PATS ; ... the denominator index ...
wPatBars:       ds NUM_PATS ; ... and the loop length in bars (the edited pattern's values live in the
                            ; MIDI block / wSeqBars until TsStore copies them here)
wPBarTicks:     db          ; ticks in a bar of the PLAYED pattern
wEdLoopSeg:     db          ; where the loop of the EDITED pattern ends (the ruler): segment ...
wEdLoopTail:    db          ; ... and ticks in it
wBarIdx:        db          ; index of the bar that is playing (0-based; $FF just before the first)
wBarPos:        db          ; ticks since the bar began (0 = a bar begins with the next tick played)
wQueuedBank:    db          ; the pattern (1-based) that takes over at the next bar line (0 = none)
wBarTicks:      db          ; ticks in a bar of the time signature (numerator * ticks of the beat unit)
wBeatTicks:     db          ; ticks in the beat unit: 12 (/4), 6 (/8), 3 (/16)
wMaxBars:       db          ; the longest loop in bars: 384 ticks / wBarTicks, at most MAX_BARS
wLoopSeg:       db          ; where the loop ends: the last segment ...
wLoopTail:      db          ; ... and the ticks played in it (ComputeLoopEnd)
wBCInBar:       db          ; BuildCols: ticks into the bar at the column that is being built
wBCBar:         db          ; BuildCols: bar index (0-based) of that column
wSeqBars:       db          ; loop length in bars (1..MAX_BARS)
wSeqSeg:        db          ; segment (4 bars) of the next tick to play
wSeqCurSeg:     db          ; segment of the tick that was played last (playhead)
wRollSeg:       db          ; piano-roll cursor: segment (wRollTick / wRollCell count inside it)
wPageSeg:       db          ; segment of the visible page
wBCSeg:         db          ; BuildCols scratch
wRCSeg:         db          ; RollChannelChanged scratch
wEditBank:      db          ; the pattern shown / edited on the piano roll, 1-based (1..NUM_PATS) = wEditPat + 1
wPlayBank:      db          ; the pattern the sequencer plays, 1-based
wEditPat:       db          ; the edited pattern's number
wSongMode:      db          ; 0 = loop the edited pattern, 1 = play the chain
wChainPos:      db          ; chain step being played
wSongWrap:      db          ; 1 = the chain just moved on: release the notes before the next pattern's first tick
wChain:         ds CHAIN_LEN ; pattern numbers, CHAIN_END after the last step
wSongCur:       db          ; song screen: the cursor's chain step
wDirtySong:     db          ; song-screen rows needing redraw (bit 0 = mode / edit rows, bit n = chain row n-1)
wSelUsed:       db          ; SELECT was used as a modifier while held
wBUsed:         db          ; B was used as a modifier while held (sequencer screen)
wDiv:           db          ; grid division index (src/divs.inc)
wDivTicks:      db          ; ticks per grid cell for that division
wPageCols:      db          ; grid columns the page uses (1..16; the rest are blank)
wPageSpan:      db          ; ticks the page shows (wPageCols * wDivTicks)
wPageAbs:       dw          ; the page's first tick, counted from the start of the pattern
wShAbs:         dw          ; the same for the page that is on screen
wColSeg:        db          ; BuildCols: the segment of the column being built
wPfX:           dw          ; PageFor: the tick the page must show
wPfStep:        dw          ; PageFor: ticks from one page start to the next
wPfCols:        db          ; PageFor: columns of the page
wPfN:           db          ; PageFor: cells in a bar
wRollCell:      db          ; piano-roll cursor: grid cell index (tick / wDivTicks)
wRollTick:      db          ; piano-roll cursor: tick (= cell * wDivTicks)
wRollNote:      db          ; piano-roll cursor: MIDI note
wRollTop:       db          ; pitch shown on the top grid row
wRollPage:      db          ; visible page index
wPageTick:      db          ; tick of the first visible column (= page * wPageSpan)
wPageCell:      db          ; cell index of the first visible column (= page * wPageCols)
wNtStart:       dw          ; SeqLength: the edited note's start (absolute tick)
wWaveMark:      db          ; $A5 once the custom waves hold something (saved with the song, right before them)
wWaves:         ds 16 * 4   ; the custom CH3 waves W1-W4, 16 bytes each (wave RAM format: two 4-bit samples a byte, high nibble first)
wWaveSel:       db          ; the custom wave the editor shows (0-3)
wWaveCur:       db          ; the sample the cursor is on (0-31)
wWavePre:       db          ; the preset that START+A copies next
wWaveBase:      db          ; WaveRender scratch
wWaveJ:         db
wWaveIdx:       db
wDirtyWave:     db          ; wave editor rows to copy to the screen (bit 0 = graph top, 1 = graph bottom, 2 = values, 3 = info)
wWaveBuf:       ds 20 * 4   ; those rows, ready to copy
wFollow:        db          ; 1 = the view follows the playhead
wPlayX:         db          ; wanted playhead X in OAM coordinates ($FF = hidden)
wPlayShown:     db          ; playhead X currently in OAM ($FF = hidden)
wStatusRender:  db          ; 1 = rebuild wStatusBuf (outside VBlank)
wOldNote:       db          ; cursor pitch before the last move
wRRPitch:       db          ; RenderRow scratch
wRRBlack:       db
wRRCur:         db
wSaveSum:       db          ; SaveAll running checksum
wNumSlots:      db          ; save slots this cartridge has room for (InitSlots: from the header's RAM size)
wSlot:          db          ; selected save slot 0..NUM_SLOTS-1
wSlotUsed:      db          ; bit n = slot n holds a valid save (cached; scanned at boot, kept up to date)
wDirtySlot:     db          ; slot-screen rows needing redraw (bit n = row n)
wScreenBack:    db          ; the screen START+UP returns to from the slot screen
wName:          ds NAME_LEN ; the song's name (indices into NameChars), saved with it
wNameCur:       db          ; name editing cursor 0..NAME_LEN-1
wDirtyName:     db          ; 1 = redraw the name rows of the slot screen
wConfirm:       db          ; slot + 1 while "SEL+A again to overwrite" is waiting, else 0
wBCPitch:       db          ; BuildCols scratch
wBCHead:        db
wBCFlag:        db
wBCPhase:       db
wBCBeat:        db
wBCCol:         db
wRulerBuf:      ds 20       ; row 0 of the roll, built outside VBlank
wRRBuf:         ds 20       ; RenderRow builds a row here, CommitRow compares it with the shadow slot
wRRRow:         db          ; the ring row being rendered
wRRLo:          db          ; the first changed tile of the row just rendered ($FF = none)
wRRHi:          db          ; the end of the changed tiles
wSpanTmp:       db
wRRChanged:     db          ; 1 = the rendered row differs from its shadow slot (it must be copied)
wStatusBuf:     ds 20       ; row 17 of the roll
wMsg:           db          ; message code shown on row 17 (0 = none)
wMsgTimer:      db
wVibM:          db          ; scratch for the vibrato tick
wVibSign:       db
; Link to the Chromatic's built-in ESP32 (src/clink.asm, docs/CHROMATIC_LINK.md)
wClLinked:      db          ; 1 = the ESP32 said HELLO and keeps talking
wClTimer:       db          ; frames since the last valid packet
wClIdle:        db          ; frames since the last accepted symbol (a half packet is dropped)
wClHave:        db          ; ReadJoy found a symbol frame (set by ReadJoy, cleared by CLinkRx)
wClSym:         db          ; its 4 data bits
wClPh:          db          ; its phase (0 = A, 1 = B)
wClNextPh:      db          ; phase of the next new symbol (a repeat of the last one is ignored)
wClN:           db          ; symbols of the current packet received so far
wClMode:        db          ; 0 = play packet (4 symbols), 1 = general packet (8 symbols)
wClBuf:         ds 8
wClMsg:         ds 3        ; the 3 MIDI bytes of the last general packet
wClSeq:         db          ; uplink message counter (0..7)
wClNack:        db          ; 1 = the last packet failed its check
wClCh:          db          ; GB channel the keyboard note went to
wClSlot:        ds 4        ; the 4 bytes last written to OBJ palette 1 (also read by the tests)
wClLen:         db          ; length of the message in the slot (kept until the next message replaces it)
wKbdNav:        db          ; 1 = START+LEFT was held on the last person frame of the keyboard screen
wNavHide:       db          ; 1 = changed screen with START+LEFT/RIGHT: hide the d-pad until released
wClBeacon:      db          ; 1 = the slot shows the keyboard screen (beacon or link): an end beacon is owed when we leave
wClearEnd:      db

; Names of the saved slots, cached so the slot list never reads SRAM inside VBlank.
SECTION "Slot names", WRAM0, ALIGN[6]
wSlotNames:     ds NUM_SLOTS * NAME_LEN
