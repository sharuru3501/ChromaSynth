; Shared synth constants. tools/gen_notetable.py reads NOTE_MIN/NOTE_MAX from here.
IF !DEF(SYNTH_INC)
DEF SYNTH_INC EQU 1

DEF NOTE_MIN EQU 36     ; C2
DEF NOTE_MAX EQU 107    ; B7
DEF NUM_CH   EQU 4

; Patch: 8 bytes per channel in wPatch (see docs/ARCHITECTURE.md).
;  CH1: duty vol env swt swd sws vibd vibs
;  CH2: duty vol env -   -   -   vibd vibs
;  CH3: wave level -  -   -   -   vibd vibs
;  CH4: width vol env -   -   -   -    -
DEF PATCH_SIZE EQU 8
DEF PATCH_VIBD EQU 6
DEF PATCH_VIBS EQU 7

; wDirty bits: 0-3 = channel rows, 4 = status line (play screen), 5 = header (edit screen)
DEF DIRTY_STATUS EQU %00010000
DEF DIRTY_ALL    EQU %00011111
DEF DIRTY_HEADER EQU %00100000

DEF SCREEN_PLAY EQU 0
DEF SCREEN_EDIT EQU 1

ENDC
