; All work RAM lives here. wRingHead..wClearEnd is zeroed at boot.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

; Aligned so that "base + small offset" never carries into the high byte.
SECTION "Patch", WRAM0, ALIGN[5]
wPatch:         ds NUM_CH * PATCH_SIZE

; Pattern: wPattern[channel * 256 + tick]. 256-byte aligned: HIGH(wPattern)+channel
; is the high byte and the tick is the low byte (no 16-bit arithmetic anywhere).
SECTION "Pattern", WRAM0, ALIGN[8]
wPattern:       ds NUM_CH * SEQ_STRIDE

; Piano roll shadow tilemap (rows 1-16 of the screen, 20 columns each). It is
; rendered outside VBlank and copied to VRAM a few rows per frame.
SECTION "Roll grid", WRAM0
wGrid:          ds ROLL_ROWS * 20

; 16 render flags, 16 copy flags, 16 column pitches, 16 head flags: 64 bytes, 64-byte
; aligned so that base + index never carries into the high byte.
SECTION "Roll flags", WRAM0, ALIGN[6]
wRowRender:     ds ROLL_ROWS    ; row must be re-rendered into wGrid
wRowDirty:      ds ROLL_ROWS    ; row must be copied to VRAM
; Per column of the visible page: sounding pitch (0 = silence), then 1 = note head.
wColPitch:      ds SEQ_PAGE
wColHead:       ds SEQ_PAGE

; Previous column summary, kept so that an edit only redraws the rows that changed.
SECTION "Roll old cols", WRAM0, ALIGN[5]
wColOld:        ds SEQ_PAGE * 2

SECTION "Synth state", WRAM0, ALIGN[3]
wBase:          ds NUM_CH * 2   ; base period of the sounding note (lo, hi)
wOut:           ds NUM_CH * 2   ; last period written by the vibrato (debug/test)

SECTION "Vars", WRAM0
wRingHead:      db          ; written by ISR
wRingTail:      db          ; written by main loop
wVBlank:        db
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
wCurNote:       ds NUM_CH   ; sounding note per channel, 0 = silent
wVibPh:         ds NUM_CH   ; vibrato phase per channel
wSeqPlay:       db          ; 1 = sequencer running
wSeqTick:       db          ; next tick to play (0..wSeqLen-1)
wSeqCur:        db          ; tick that was played last (playhead)
wSeqAcc:        dw          ; 8.8 frame accumulator
wBpm:           db
wSeqLen:        db          ; loop length in ticks (48/96/144/192)
wSelUsed:       db          ; SELECT was used as a modifier while held
wBUsed:         db          ; B was used as a modifier while held (sequencer screen)
wDiv:           db          ; grid division index (src/divs.inc)
wDivTicks:      db          ; ticks per grid cell for that division
wRollCell:      db          ; piano-roll cursor: grid cell index (tick / wDivTicks)
wRollTick:      db          ; piano-roll cursor: tick (= cell * wDivTicks)
wRollNote:      db          ; piano-roll cursor: MIDI note
wRollTop:       db          ; pitch shown on the top grid row
wRollPage:      db          ; visible page (first cell = page * 16)
wPageTick:      db          ; tick of the first visible column (= page * 16 * wDivTicks)
wFollow:        db          ; 1 = the view follows the playhead
wPlayX:         db          ; wanted playhead X in OAM coordinates ($FF = hidden)
wPlayShown:     db          ; playhead X currently in OAM ($FF = hidden)
wStatusRender:  db          ; 1 = rebuild wStatusBuf (outside VBlank)
wOldNote:       db          ; cursor pitch before the last move
wRRPitch:       db          ; RenderRow scratch
wRRBlack:       db
wRRCur:         db
wSaveSum:       db          ; SaveAll running checksum
wBCPitch:       db          ; BuildCols scratch
wBCHead:        db
wBCFlag:        db
wBCPhase:       db
wBCBeat:        db
wBCCol:         db
wRulerBuf:      ds 20       ; row 0 of the roll, built outside VBlank
wStatusBuf:     ds 20       ; row 17 of the roll
wMsg:           db          ; message code shown on row 17 (0 = none)
wMsgTimer:      db
wVibM:          db          ; scratch for the vibrato tick
wVibSign:       db
wClearEnd:      db
