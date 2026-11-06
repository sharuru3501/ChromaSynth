; Text UI on the BG layer. Tile index = ASCII - 32 (see tools/gen_font.py).
;
;   row 0   CHROMASYNTH
;   row 2   header
;   row 3-6 one line per channel:  > 1  PUL1  C-4  D2
;   row 9   PAD C-4   RX 90
;
; VRAM is only writable in VBlank, so UpdateUI redraws at most one dirty row
; per frame (it must be called right after the VBlank flag is seen).
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF ROW_TITLE  EQU _SCRN0 + 0 * 32 + 4
DEF ROW_HEADER EQU _SCRN0 + 2 * 32
DEF ROW_CH0    EQU 3
DEF ROW_STATUS EQU _SCRN0 + 9 * 32
DEF ROW_HELP1  EQU _SCRN0 + 15 * 32
DEF ROW_HELP2  EQU _SCRN0 + 16 * 32

SECTION "UI", ROM0

; Call with the LCD off. Loads the font, clears the map, draws static text.
InitUI:
    ld hl, _VRAM
    ld de, Font
    ld bc, FontEnd - Font
.font:
    ld a, [de]
    ld [hl+], a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .font

    ld hl, _SCRN0
    ld bc, 32 * 32
    call MemClear           ; tile 0 = space

    ld hl, ROW_TITLE
    ld de, sTitle
    call DrawString
    ld hl, ROW_HEADER
    ld de, sHeader
    call DrawString
    ld hl, ROW_STATUS
    ld de, sPad
    call DrawString
    ld hl, ROW_STATUS + 9
    ld de, sRx
    call DrawString
    ld hl, ROW_HELP1
    ld de, sHelp1
    call DrawString
    ld hl, ROW_HELP2
    ld de, sHelp2
    call DrawString

    ld a, DIRTY_ALL
    ld [wDirty], a
    ret

; de = zero-terminated ASCII, hl = dest. Returns hl past the last tile.
DrawString:
    ld a, [de]
    inc de
    and a
    ret z
    sub 32
    ld [hl+], a
    jr DrawString

; Redraw one dirty row (lowest bit first).
UpdateUI:
    ld a, [wDirty]
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
    ld hl, wDirty
    and [hl]
    ld [hl], a              ; clear the bit we are about to handle
    ld a, c
    cp NUM_CH
    jr z, DrawStatus
    ; fall through: channel row c

; c = channel
DrawChannel:
    xor a                   ; col 0: selection marker
    call RowPtr
    ld a, [wSelCh]
    cp c
    ld a, 0
    jr nz, .mark
    ld a, '>' - 32
.mark:
    ld [hl+], a
    inc l
    ld a, c                 ; col 2: channel number
    add '1' - 32
    ld [hl], a

    ld a, 5                 ; col 5: type name
    call RowPtr
    ld a, c
    add a
    add a
    add c                   ; c * 5
    ld e, a
    ld d, 0
    push hl
    ld hl, TypeNames
    add hl, de
    ld d, h
    ld e, l
    pop hl
    call DrawString

    ld a, 11                ; col 11: note name or ---
    call RowPtr
    push hl
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    pop hl
    and a
    jr z, .silent
    call DrawNoteName
    jr .param
.silent:
    ld a, '-' - 32
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
.param:
    ld a, 16                ; col 16: param letter + value
    call RowPtr
    push hl
    ld hl, ParamLetters
    call HLplusC
    ld a, [hl]
    sub 32
    pop hl
    ld [hl+], a
    push hl
    ld hl, wParam
    call HLplusC
    ld a, [hl]
    pop hl
    add '0' - 32
    ld [hl], a
    ret

DrawStatus:
    ld a, [wJoyNote]
    ld hl, ROW_STATUS + 4
    call DrawNoteName
    ld a, [wLastRx]
    ld hl, ROW_STATUS + 12
    jp DrawHex

; c = channel, a = column -> hl = BG map address of that cell. Clobbers a.
RowPtr:
    ld l, a
    ld a, c
    swap a
    add a                   ; c * 32
    add ROW_CH0 * 32
    add l
    ld l, a
    ld h, HIGH(_SCRN0)
    ret

; a = MIDI note, hl = dest -> three tiles, e.g. "C-4". Clobbers a, b, de.
DrawNoteName:
    ld b, 0
.oct:
    cp 12
    jr c, .name
    sub 12
    inc b
    jr .oct
.name:
    add a
    ld e, a
    ld d, 0
    push hl
    ld hl, NoteNames
    add hl, de
    ld d, h
    ld e, l
    pop hl
    ld a, [de]
    inc de
    sub 32
    ld [hl+], a
    ld a, [de]
    sub 32
    ld [hl+], a
    ld a, b
    dec a                   ; MIDI 12 is C0 here -> octave = n/12 - 1
    add '0' - 32
    ld [hl+], a
    ret

; a = byte, hl = dest -> two hex digit tiles. Clobbers a, b.
DrawHex:
    ld b, a
    swap a
    call .nibble
    ld a, b
.nibble:
    and $0F
    cp 10
    jr c, .digit
    add 'A' - 10 - 32
    jr .out
.digit:
    add '0' - 32
.out:
    ld [hl+], a
    ret

sTitle:       db "CHROMASYNTH", 0
sHeader:      db " CH  TYPE  NOTE PRM", 0
sPad:         db "PAD", 0
sRx:          db "RX", 0
sHelp1:       db "A:PLAY  B:PARAM", 0
sHelp2:       db "SEL:CH  PAD:NOTE", 0
TypeNames:    db "PUL1", 0, "PUL2", 0, "WAVE", 0, "NOIS", 0
ParamLetters: db "DDWL"
NoteNames:    db "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"

INCLUDE "font.inc"
