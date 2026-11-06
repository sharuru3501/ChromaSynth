; All work RAM lives here. wRingHead..wClearEnd is zeroed at boot.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

; Aligned so that "base + small offset" never carries into the high byte.
SECTION "Patch", WRAM0, ALIGN[5]
wPatch:         ds NUM_CH * PATCH_SIZE

; Pattern: wPattern[channel * 16 + step]. 64-byte aligned for carry-free indexing.
SECTION "Pattern", WRAM0, ALIGN[6]
wPattern:       ds NUM_CH * SEQ_STEPS

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
wSeqRow:        db          ; cursor on the sequencer screen
wSeqCh:         db
wSeqNote:       db          ; note inserted by A on the sequencer screen
wSelUsed:       db          ; SELECT was used as a modifier while held
wDirtySeq:      dw          ; sequencer rows needing redraw (bit per row)
wVibM:          db          ; scratch for the vibrato tick
wVibSign:       db
wClearEnd:      db
