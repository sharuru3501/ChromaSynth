; Shared synth constants. tools/gen_notetable.py reads NOTE_MIN/NOTE_MAX from here.
IF !DEF(SYNTH_INC)
DEF SYNTH_INC EQU 1

DEF NOTE_MIN EQU 36     ; C2
DEF NOTE_MAX EQU 107    ; B7
DEF NUM_CH   EQU 4

; wDirty bits: 0-3 = channel rows, 4 = status line
DEF DIRTY_STATUS EQU %00010000
DEF DIRTY_ALL    EQU %00011111

ENDC
