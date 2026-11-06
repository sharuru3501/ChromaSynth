; All work RAM lives here. wRingHead..wClearEnd is zeroed at boot.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI ring", WRAM0, ALIGN[8]
wRing:          ds 256      ; serial RX ring buffer (ISR -> main loop)

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
wDirty:         db          ; UI rows needing redraw (see synth.inc)
wCurNote:       ds NUM_CH   ; sounding note per channel, 0 = silent
wParam:         ds NUM_CH   ; per-channel param: duty / duty / wave / lfsr width
wClearEnd:      db
