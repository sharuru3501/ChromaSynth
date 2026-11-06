; All work RAM lives here. wRingHead..wClearEnd is zeroed at boot.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

; Aligned so that "base + small offset" never carries into the high byte.
SECTION "Patch", WRAM0, ALIGN[5]
wPatch:         ds NUM_CH * PATCH_SIZE

; Pattern: wPattern[channel * 64 + step]. 256-byte aligned: the low byte of an
; address is simply channel * 64 + step (no carry handling anywhere).
SECTION "Pattern", WRAM0, ALIGN[8]
wPattern:       ds NUM_CH * SEQ_STEPS

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
wSeqStep:       db          ; next step to play (0..15)
wSeqCur:        db          ; step that was played last (playhead)
wSeqAcc:        dw          ; 8.8 frame accumulator
wBpm:           db
wSeqLen:        db          ; loop length in steps (16/32/48/64)
wSelUsed:       db          ; SELECT was used as a modifier while held
wBUsed:         db          ; B was used as a modifier while held (sequencer screen)
wRollStep:      db          ; piano-roll cursor: step 0..63
wRollNote:      db          ; piano-roll cursor: MIDI note
wRollTop:       db          ; pitch shown on the top grid row
wRollPage:      db          ; visible page (first step = page * 16)
wFollow:        db          ; 1 = the view follows the playhead
wPlayCol:       db          ; column the playhead sprite is drawn at ($FF = hidden)
wOldNote:       db          ; cursor pitch before the last move
wRRPitch:       db          ; RenderRow scratch
wRRBlack:       db
wRRCur:         db
wSaveSum:       db          ; SaveAll running checksum
wMsg:           db          ; message code shown on row 17 (0 = none)
wMsgTimer:      db
wVibM:          db          ; scratch for the vibrato tick
wVibSign:       db
wClearEnd:      db
