; Text UI on the BG layer. Tile index = ASCII - 32 (see tools/gen_font.py).
;
; Play screen:                         Edit screen:
;   row 0   CHROMASYNTH                  row 0   PATCH    CH1 PUL1
;   row 3-6 > 1  PUL1  C-4               row 2-9 > DUTY   2   (one param per row)
;   row 9   PAD C-4   RX 90
;
; VRAM is only writable in VBlank, so UpdateUI redraws at most one dirty row
; per frame (it must be called right after the VBlank flag is seen).
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF ROW_CH0    EQU 3
DEF ROW_STATUS EQU _SCRN0 + 9 * 32

SECTION "UI", ROM0

; Call with the LCD off. Loads the font and draws the play screen.
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
    jr BuildScreen

; LCD must be off (or we must be in VBlank with a tiny update).
BuildScreen:
    ld a, [wScreen]         ; only the edit screen has the 5th (MIDI) page
    cp SCREEN_EDIT
    jr z, .chOk
    ld a, [wSelCh]
    cp NUM_CH
    jr c, .chOk
    xor a
    ld [wSelCh], a
.chOk:
    ld hl, _SCRN0
    ld bc, 32 * 32
    call MemClear           ; tile 0 = space
    ld hl, _OAMRAM          ; no sprites except on the piano roll
    ld bc, 160
    call MemClear
    ld a, $FF
    ld [wPlayShown], a
    ld [wPlayX], a
    ld a, [wScreen]
    and a
    jr z, .play
    cp SCREEN_SEQ
    jp z, BuildSeq
    cp SCREEN_KBD
    jr z, .kbd
    jr .edit
.kbd:
    call .play              ; the channel rows and status line are the play screen's
    ld hl, _SCRN0 + 4
    ld de, sKbdTitle
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sKbdHelp1
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sKbdHelp2
    call DrawString
    ld hl, _SCRN0 + 16 * 32
    ld de, sKbdHelp3
    jp DrawString
.play:
    ld hl, _SCRN0 + 4
    ld de, sTitle
    call DrawString
    ld hl, _SCRN0 + 2 * 32
    ld de, sHeader
    call DrawString
    ld hl, ROW_STATUS
    ld de, sPad
    call DrawString
    ld hl, ROW_STATUS + 9
    ld de, sRx
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sHelp1
    call DrawString
    ld hl, _SCRN0 + 16 * 32
    ld de, sHelp2
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sHelp3
    call DrawString
    ld a, DIRTY_ALL
    ld [wDirty], a
    ret
.edit:
    ld hl, _SCRN0
    ld de, sPatch
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sEditHelp1
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sEditHelp2
    call DrawString
    ld hl, _SCRN0 + 16 * 32
    ld de, sEditHelp3
    call DrawString
    ld a, DIRTY_HEADER
    ld [wDirty], a
    ld a, $FF
    ld [wDirtyEdit], a
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

; Called once per frame right after VBlank starts. VRAM/OAM are only writable
; during VBlank (LY 144-153, ~1140 cycles) and the jobs below need up to ~700,
; so if we got here late (the previous frame's work ran long) skip this frame:
; every job is driven by dirty flags, so it simply happens next frame.
UpdateUI:
    ldh a, [rLY]
    cp 144
    ret c                   ; not in VBlank at all
    cp 147
    ret nc                  ; too little VBlank left
    ld a, [wScreenReq]
    and a
    jr z, .noReq
    dec a
    ld [wScreen], a
    xor a
    ld [wScreenReq], a
    ; Rebuild the other screen. We are at the start of VBlank, LCD off is legal.
    xor a
    ldh [rLCDC], a
    call BuildScreen
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_BLK01 | LCDCF_OBJON
    ldh [rLCDC], a
    ret
.noReq:
    ld a, [wDirty]
    bit 6, a
    jr z, .noMsg
    res 6, a
    ld [wDirty], a
    jp DrawMsg
.noMsg:
    ld a, [wScreen]
    and a
    jr z, .play
    cp SCREEN_SEQ
    jp z, UpdateSeq
    cp SCREEN_KBD
    jr z, .play
    jp UpdateEdit
.play:
    ld a, [wDirty]
    and DIRTY_ALL
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
    call TypeNamePtr
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
    jp DrawNoteName
.silent:
    ld a, '-' - 32
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ret

DrawStatus:
    ld a, [wJoyNote]
    ld hl, ROW_STATUS + 4
    call DrawNoteName
    ld a, [wLastRx]
    ld hl, ROW_STATUS + 12
    jp DrawHex

; c = channel -> de = TypeNames + c * 5. Keeps hl, c.
TypeNamePtr:
    push hl
    ld a, c
    add a
    add a
    add c
    ld e, a
    ld d, 0
    ld hl, TypeNames
    add hl, de
    ld d, h
    ld e, l
    pop hl
    ret

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

; ---------------------------------------------------------------- edit screen
UpdateEdit:
    ld a, [wDirty]
    bit 5, a
    jr z, .rows
    res 5, a
    ld [wDirty], a
    jr DrawEditHeader
.rows:
    ld a, [wDirtyEdit]
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
    ld hl, wDirtyEdit
    and [hl]
    ld [hl], a
    ld b, c
    jr DrawEditRow

DrawEditHeader:
    ld hl, _SCRN0 + 8
    ld de, sCh
    call DrawString
    ld a, [wSelCh]
    ld c, a
    add '1' - 32
    ld [hl+], a
    inc hl
    call TypeNamePtr
    jp DrawString

; b = parameter row 0..7 for channel wSelCh
DrawEditRow:
    call EntryPtr           ; hl = entry
    ld a, [hl+]
    ld c, a                 ; c = max ($FF = hidden)
    push hl                 ; -> name string
    ld a, b
    swap a
    ld l, a
    ld h, 0
    add hl, hl              ; row * 32
    ld de, _SCRN0 + 2 * 32
    add hl, de              ; hl = start of this row on the map
    ld a, c
    inc a
    jr nz, .visible
    pop de                  ; hidden: blank the row
    ld b, 12
    xor a
.blank:
    ld [hl+], a
    dec b
    jr nz, .blank
    ret
.visible:
    ld a, [wEditRow]
    cp b
    ld a, 0
    jr nz, .mark
    ld a, '>' - 32
.mark:
    ld [hl+], a
    inc hl
    pop de
    call DrawString         ; name, cols 2..5
    inc hl
    inc hl                  ; value at col 8
    push hl
    call PatchRowHL
    ld a, [hl]
    pop hl
    cp 10
    jr c, .ones
    sub 10
    ld c, a
    ld a, '1' - 32
    jr .tens
.ones:
    ld c, a
    ld a, 0
.tens:
    ld [hl+], a
    ld a, c
    add '0' - 32
    ld [hl], a
    ret

; b = row -> hl = parameter table entry [max, name(4), 0] of channel wSelCh.
; Keeps b. Clobbers a, de.
EntryPtr:
    ld a, [wSelCh]
    add a
    ld e, a
    ld d, 0
    ld hl, ParamTables
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld a, b
    add a
    ld e, a
    add a
    add e                   ; row * 6
    ld e, a
    ld d, 0
    add hl, de
    ret

; b = row -> hl = address of that patch byte for channel wSelCh. Keeps b. Clobbers a.
PatchRowHL:
    ld a, [wSelCh]
    add a
    add a
    add a
    add b
    add LOW(wPatch)         ; wPatch is 32-byte aligned: no carry
    ld l, a
    ld h, HIGH(wPatch)
    ret

; Row 17 message line: wMsg = 0 clears it (and restores the sequencer status).
DrawMsg:
    ld hl, _SCRN0 + 17 * 32
    ld b, 20
    xor a
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld a, [wMsg]
    and a
    jr z, .restore
    dec a
    add a
    ld e, a
    ld d, 0
    ld hl, MsgTable
    add hl, de
    ld a, [hl+]
    ld e, a
    ld d, [hl]
    ld hl, _SCRN0 + 17 * 32
    jp DrawString
.restore:
    ld a, [wScreen]
    cp SCREEN_SEQ
    ret nz
    jp MarkSeqStatus

; ---------------------------------------------------------------- shared
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
    call NibbleTile
    ld [hl+], a
    ld a, b
    call NibbleTile
    ld [hl+], a
    ret

; a = 0..15 -> tile of its hex digit
NibbleTile:
    and $0F
    cp 10
    jr c, .digit
    add 'A' - 10 - 32
    ret
.digit:
    add '0' - 32
    ret

; a = 0..255, hl = dest -> three tiles, leading zero blanked. Clobbers a, b, c.
DrawDec3:
    ld b, 0
.h: cp 100
    jr c, .hd
    sub 100
    inc b
    jr .h
.hd:
    ld c, a
    ld a, b
    and a
    jr z, .blank
    add '0' - 32
    jr .wh
.blank:
    xor a
.wh:
    ld [hl+], a
    ld a, c
    ld b, 0
.t: cp 10
    jr c, .td
    sub 10
    inc b
    jr .t
.td:
    ld c, a
    ld a, b
    add '0' - 32
    ld [hl+], a
    ld a, c
    add '0' - 32
    ld [hl+], a
    ret

; ---------------------------------------------------------------- data
sTitle:       db "CHROMASYNTH", 0
sHeader:      db " CH  TYPE  NOTE", 0
sPad:         db "PAD", 0
sRx:          db "RX", 0
sHelp1:       db "A:PLAY  START:SCREEN", 0
sHelp2:       db "SEL:CH  PAD:NOTE", 0
sHelp3:       db "SEL+A:SAVE +B:LOAD", 0
sKbdTitle:    db "KEYBOARD   ", 0
sKbdHelp1:    db "PAD BUTTONS: OFF    ", 0
sKbdHelp2:    db "SEL TAP: NEXT CH    ", 0
sKbdHelp3:    db "HOLD SEL+START: EXIT", 0
sPatch:       db "PATCH", 0
sCh:          db "CH", 0
sEditHelp1:   db "UD:ROW  LR:VALUE", 0
sEditHelp2:   db "A:PLAY  B+PAD:NOTE", 0
sEditHelp3:   db "SEL:CH  START:SCREEN", 0
sMsgSaved:    db "SAVED", 0
sMsgLoaded:   db "LOADED", 0
sMsgNoData:   db "NO SAVE DATA", 0
sMsgFail:     db "SAVE FAILED", 0
MsgTable:     dw sMsgSaved, sMsgLoaded, sMsgNoData, sMsgFail
sStop:        db "STOP", 0
sPlay:        db "PLAY", 0
TypeNames:    db "PUL1", 0, "PUL2", 0, "WAVE", 0, "NOIS", 0, "MIDI", 0
NoteNames:    db "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"

; Parameter tables: 8 rows per channel, [max, 4-char name, 0]. max $FF = hidden.
; Row order must match the patch byte layout in synth.inc.
MACRO PARAM
    db \1
    db \2, 0
ENDM

ParamTables:  dw PT_Pulse1, PT_Pulse2, PT_Wave, PT_Noise, PT_Midi

PT_Pulse1:
    PARAM 3, "DUTY"
    PARAM 15, "VOL "
    PARAM 15, "ENV "
    PARAM 7, "SWT "
    PARAM 1, "SWD "
    PARAM 7, "SWS "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
PT_Pulse2:
    PARAM 3, "DUTY"
    PARAM 15, "VOL "
    PARAM 15, "ENV "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
PT_Wave:
    PARAM 3, "WAVE"
    PARAM 2, "LVL "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
PT_Noise:
    PARAM 1, "WDTH"
    PARAM 15, "VOL "
    PARAM 15, "ENV "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "
    PARAM $FF, "    "

; The 5th page of the edit screen: MIDI settings (patch bytes MIDI_BLOCK + row).
; Rows 0-3: which MIDI channel (1-16, 0 = off) each GB channel listens to.
PT_Midi:
    PARAM 16, "CH1 "
    PARAM 16, "CH2 "
    PARAM 16, "CH3 "
    PARAM 16, "CH4 "
    PARAM 12, "BEND"
    PARAM 1, "VELO"
    PARAM 1, "MODW"
    PARAM 2, "SYNC"

INCLUDE "font.inc"
