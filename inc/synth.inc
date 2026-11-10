; Shared synth constants. tools/gen_notetable.py reads NOTE_MIN/NOTE_MAX from here.
IF !DEF(SYNTH_INC)
DEF SYNTH_INC EQU 1

DEF NOTE_MIN EQU 36     ; C2
DEF NOTE_MAX EQU 107    ; B7
DEF NUM_CH   EQU 4

; Patch: 32 bytes per channel in wPatch (see docs/ARCHITECTURE.md). The edit screen shows
; them as pages of 8 rows (row = byte; rows 24-31 are reserved). The APU's registers, plus
; frame-by-frame effects of the kind GB games and LSDj use (vibrato, arpeggio, slide, duty).
;        0     1     2    3    4   5   6    7    | 8   9   10  11   | 16   17   18   19   20   21
;  CH1: duty  vol   edir epac len pan vibd vibs | swt swd sws -    | arp1 arp2 arps slid dut2 dspd
;  CH2: duty  vol   edir epac len pan vibd vibs | -   -   -   -    | arp1 arp2 arps slid dut2 dspd
;  CH3: wave  level -    -    len pan vibd vibs | -   -   -   -    | arp1 arp2 arps slid -    -
;  CH4: width vol   edir epac len pan -    -    | -   -   -   ndiv | -    -    -    -    -    -
DEF PATCH_SIZE EQU 32
DEF EDIT_ROWS  EQU 32       ; rows per channel on the edit screen (pages of 8; the last page is empty)
DEF P_MAIN EQU 0            ; duty (CH1/2), wave (CH3), LFSR width (CH4)
DEF P_VOL  EQU 1            ; initial volume 0-15 (CH3: output level 0-2)
DEF P_EDIR EQU 2            ; envelope direction (1 = up)          -> NRx2 bit 3
DEF P_EPAC EQU 3            ; envelope pace 0-7 (0 = no envelope)   -> NRx2 bits 2-0
DEF P_LEN  EQU 4            ; length counter: 0 = off, else steps of 1/256 s (CH1/2/4 1-64, CH3 1-255)
DEF P_PAN  EQU 5            ; 0 = both speakers, 1 = left, 2 = right -> NR51
DEF P_SWT  EQU 8            ; CH1 sweep time / direction / shift -> NR10
DEF P_SWD  EQU 9
DEF P_SWS  EQU 10
DEF P_NDIV EQU 11           ; CH4 noise divisor code 0-7 -> NR43 bits 2-0
DEF P_ARP1 EQU 16           ; arpeggio: root, +arp1, +arp2 semitones, round and round (0 and 0 = off)
DEF P_ARP2 EQU 17
DEF P_ARPS EQU 18           ; frames per arpeggio step (0 counts as 1)
DEF P_SLID EQU 19           ; slide from the sounding note to a legato one: 0 = off, 1 fast .. 7 slow
DEF P_DUT2 EQU 20           ; CH1/2: the second duty, alternated with the first every P_DSPD frames
DEF P_DSPD EQU 21           ; 0 = off (also off while P_LEN is set: NRx1 holds the duty and the length)
DEF NUM_PATCHES EQU NUM_CH + 1  ; CH1-CH4 plus a MIDI settings block (the 5th "page")
; MIDI settings block (patch byte offsets within the block). A MIDI channel is
; 1-16, 0 = off. Several GB channels on the same MIDI channel play polyphonically.
DEF MIDI_BLOCK EQU NUM_CH * PATCH_SIZE
DEF PM_BEND EQU 4           ; pitch bend range in semitones
DEF PM_VELO EQU 5           ; 1 = velocity changes the volume
DEF PM_MODW EQU 6           ; 1 = CC1 (mod wheel) raises the vibrato depth
DEF PM_SYNC EQU 7           ; sync mode, see SYNC_*
DEF PM_VOLL EQU 8           ; master volume left 0-7  -> NR50 bits 6-4
DEF PM_VOLR EQU 9           ; master volume right 0-7 -> NR50 bits 2-0
DEF PM_TSN  EQU 10          ; time signature: numerator 1-16 (0 = 4: songs saved before it existed)
DEF PM_TSD  EQU 11          ; time signature: denominator index 0 = 4, 1 = 8, 2 = 16
DEF SYNC_OFF EQU 0          ; no clock, nothing sent
DEF SYNC_OUT EQU 1          ; this unit is the master: sends clock/start/stop and the sequencer's notes
DEF SYNC_IN  EQU 2          ; this unit follows the DAW: clock/start/stop come from the link
DEF SYNC_FOLLOW EQU 3       ; follows the DAW over the slow cable-less link: start/stop, the tempo (CC14/CC15), program change = pattern, timbre CCs; the ROM keeps its own clock
; Link protocol (see docs/BRIDGE.md): both directions use $FD as "nothing to send".
; Clock is one $F8 per sequencer tick (12 per beat), not the MIDI standard 24 per beat.
DEF MIDI_IDLE EQU $FD
DEF PATCH_VIBD EQU 6
DEF PATCH_VIBS EQU 7

; wDirty bits: 0-3 = channel rows, 4 = status line (play screen), 5 = header (edit screen)
DEF DIRTY_STATUS EQU %00010000
DEF DIRTY_ALL    EQU %00011111
DEF DIRTY_HEADER EQU %00100000
DEF DIRTY_MSG    EQU %01000000   ; message line (row 17)

; Messages shown on row 17
DEF MSG_SAVED  EQU 1
DEF MSG_LOADED EQU 2
DEF MSG_NODATA EQU 3
DEF MSG_FAIL   EQU 4
DEF MSG_INUSE   EQU 5      ; the slot holds data that is not ours (LSDj): nothing written
DEF MSG_CONFIRM EQU 6      ; the slot is used: press SELECT+B again to overwrite
DEF MSG_FRAMES EQU 90

; Save slots (src/sram.asm): 4 slots of 8 KB, one SRAM bank each. The public build uses banks 0-3 (a 32 KB SRAM
; is enough); the maintainer's shared EMS card keeps LSDj in banks 0-11, so `make card` builds with SLOT_BANK0 = 12.
DEF NUM_PATS   EQU 4       ; patterns per song (each 4 channels x up to 8 bars); pattern p lives in WRAM bank p + 1
DEF CHAIN_LEN  EQU 16      ; steps in the song chain; a step is a pattern number 0..NUM_PATS-1 or CHAIN_END
DEF CHAIN_END  EQU $FF
DEF NAME_LEN   EQU 8       ; characters in a song name (stored after the checksum of a slot)
DEF NAME_CHARS EQU 38      ; name bytes are indices into NameChars: space, A-Z, 0-9, "-"
DEF NUM_SLOTS  EQU 4
DEF SLOT_SIZE  EQU 8192    ; one 8 KB SRAM bank per slot
IF !DEF(SLOT_BANK0)
DEF SLOT_BANK0 EQU 0       ; slot n in bank SLOT_BANK0 + n (override: rgbasm -D SLOT_BANK0=12)
ENDC

; D-pad auto-repeat (frames)
DEF REPEAT_DELAY EQU 16
DEF REPEAT_RATE  EQU 4

DEF SCREEN_PLAY EQU 0
DEF SCREEN_EDIT EQU 1
DEF SCREEN_SEQ  EQU 2
DEF SCREEN_WAVE EQU 6       ; CH3 wave editor: START+A on the edit screen (CH3, WAVE = a custom wave) opens it, START+B goes back
DEF SCREEN_SONG EQU 5       ; song screen: START+UP opens it, START+DOWN goes back
DEF SCREEN_SLOT EQU 4       ; save slot list: START+DOWN opens it from play/edit/sequencer, START+UP goes back
DEF SCREEN_KBD  EQU 3       ; keyboard link screen: the buttons are data (src/clink.asm)

; Time base: 12 ticks per beat (quarter note); see docs/ROLL_DESIGN.md.
DEF TICKS_PER_BEAT EQU 12
DEF TICKS_PER_BAR  EQU 48
DEF SEQ_TICKS  EQU 192      ; ticks per segment (4 bars of 4/4); a position is (segment, tick)
DEF SEQ_STRIDE EQU 512      ; pattern bytes per channel: two 256-byte pages, one per segment of SEQ_TICKS ticks
DEF TOTAL_TICKS EQU 384     ; ticks in a whole pattern (NUM_SEGS x SEQ_TICKS)
DEF NUM_SEGS   EQU 2        ; segments per pattern: a pattern is up to 8 bars (2 x 4 bars)
DEF MAX_BARS   EQU 8           ; loop length in bars is at most this (and at most 384 ticks: wMaxBars)
DEF SEQ_PAGE   EQU 16       ; grid columns per piano-roll page
DEF ROLL_ROWS  EQU 16       ; pitch rows visible
DEF RING_ROWS  EQU 32       ; rows of a BG map: pitch p always lives in map row (1 - p) mod 32; SCY picks the visible 18
DEF ROLL_COL0  EQU 2        ; first grid column (cols 0-1 = key labels)
DEF ROLL_ROW0  EQU 1        ; first grid row on screen
DEF NUM_DIVS   EQU 7        ; grid divisions (src/divs.inc)
DEF DEFAULT_DIV EQU 4       ; 1/16

; Tile ids (generated by tools/gen_font.py)
DEF T_EMP_W     EQU 64      ; sub-grid cell; +1 black-key row, +2 beat column
DEF T_BAR_W     EQU 73      ; bar line column; +1 black-key row
DEF T_TICK      EQU 75      ; ruler beat mark, drawn exactly under the beat line
DEF T_NOTE_HEAD EQU 68
DEF T_NOTE_BODY EQU 69
DEF T_CUR_EMP   EQU 70
DEF T_CUR_NOTE  EQU 71
DEF T_PLAYHEAD  EQU 72
DEF T_BAR1      EQU 76      ; wave editor: a bar 1..8 pixels high (T_BAR1 + height - 1)
DEF WAVE_CUSTOM EQU 4       ; WAVE values 0-3 are presets, 4-7 are the custom waves W1-W4
DEF NUM_CUSTOM  EQU 4
DEF TILE_INV    EQU 128     ; add to a text tile for the inverted version

DEF BPM_MIN   EQU 60
DEF BPM_MAX   EQU 240
; pattern cell: 0 = empty (keep sounding), $FF = note off, else MIDI note
DEF CELL_OFF  EQU $FF

ENDC
