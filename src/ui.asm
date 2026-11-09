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
DEF ROW_SLOT   EQU _SCRN0 + 11 * 32
DEF EDIT_ROWS_PER_FRAME EQU 3

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
    xor a
    ldh [rSCY], a           ; only the piano roll scrolls (BuildSeq sets its SCY)
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
    jp z, .play
    cp SCREEN_SEQ
    jp z, BuildSeq
    cp SCREEN_KBD
    jp z, .kbd
    cp SCREEN_SLOT
    jp z, .slot
    cp SCREEN_SONG
    jp z, BuildSong
    cp SCREEN_WAVE
    jp z, BuildWave
    jp .edit
.slot:
    ld hl, _SCRN0 + 4
    ld de, sSlotTitle
    call DrawString
    ld hl, _SCRN0 + 13 * 32
    ld de, sSlotHelp1
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sSlotHelp2
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sSlotHelp4
    call DrawString
    ld hl, _SCRN0 + 16 * 32
    ld de, sSlotHelp3
    call DrawString
    ld a, $FF
    ld [wDirtySlot], a
    ld a, 1
    ld [wDirtyName], a
    ld hl, _SCRN0 + 11 * 32
    ld de, sNameLabel
    jp DrawString
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
    ld hl, ROW_SLOT
    ld de, sSlot
    call DrawString
    ld hl, ROW_SLOT + 12
    ld de, sSlotHint
    call DrawString
    ld a, [wScreen]         ; (the keyboard screen shares this, but cannot open the list)
    and a
    jr nz, .noListHint
    ld hl, _SCRN0 + 12 * 32
    ld de, sSlotList
    call DrawString
.noListHint:
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
    cp SCREEN_SLOT
    jp z, UpdateSlot
    cp SCREEN_SONG
    jp z, UpdateSong
    cp SCREEN_WAVE
    jp z, UpdateWave
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
    call DrawHex
    ld a, [wSlot]           ; slot number and whether it holds a save
    add '1' - 32
    ld [ROW_SLOT + 5], a
    call SlotMask
    ld hl, wSlotUsed
    and [hl]
    ld de, sSlotFree
    jr z, .mark
    ld de, sSlotUsed
.mark:
    ld hl, ROW_SLOT + 7
    jp DrawString

; Slot list: one dirty row per frame. Row n = screen row 2 + n: marker, number, USED / FREE.
UpdateSlot:
    ld a, [wDirty]
    and DIRTY_MSG
    ld [wDirty], a          ; the other play-screen bits mean nothing here
    ld a, [wDirtySlot]
    and a
    jr nz, .rows
    ld a, [wDirtyName]      ; the name and its cursor
    and a
    ret z
    xor a
    ld [wDirtyName], a
    ld hl, _SCRN0 + 11 * 32 + 5
    ld de, wName
    call DrawName
    ld hl, _SCRN0 + 12 * 32 + 5
    ld b, NAME_LEN
    xor a
.clearCur:
    ld [hl+], a
    dec b
    jr nz, .clearCur
    ld a, [wNameCur]
    ld e, a
    ld d, 0
    ld hl, _SCRN0 + 12 * 32 + 5
    add hl, de
    ld [hl], '+' - 32       ; under the character being edited
    ret
.rows:
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
    ld hl, wDirtySlot
    and [hl]
    ld [hl], a
    ld a, c
    ld hl, wNumSlots
    cp [hl]
    ret nc                  ; (the dirty byte starts with all bits set; slots this cartridge has no room for stay blank)
    ld b, c                 ; b = slot
    ld a, c
    swap a
    add a                   ; c * 32
    ld e, a
    ld d, 0
    ld hl, _SCRN0 + 2 * 32
    add hl, de
    ld a, [wSlot]
    cp b
    ld a, 0
    jr nz, .mark
    ld a, '>' - 32
.mark:
    ld [hl+], a
    inc hl
    ld a, b
    add '1' - 32
    ld [hl+], a
    inc hl
    inc hl
    push bc
    push hl                 ; the name of slot b (cached): 8 tiles at col 5
    ld a, b
    add a
    add a
    add a
    add LOW(wSlotNames)
    ld e, a
    ld d, HIGH(wSlotNames)
    call DrawName           ; -> hl past the name (col 13)
    inc hl                  ; col 14: USED / FREE
    ld d, h
    ld e, l
    pop hl
    pop bc
    ld h, d
    ld l, e
    ld a, 1                 ; mask of slot b
    inc b
    dec b
    jr z, .masked
.shift:
    add a
    dec b
    jr nz, .shift
.masked:
    push hl
    ld hl, wSlotUsed
    and [hl]
    pop hl
    ld de, sSlotFree
    jr z, .draw
    ld de, sSlotUsed
.draw:
    jp DrawString

; hl = dest tiles, de = NAME_LEN name indices -> NAME_LEN tiles; hl returns past them.
DrawName:
    ld b, NAME_LEN
.next:
    ld a, [de]
    inc de
    push de
    push hl
    ld e, a
    ld d, 0
    ld hl, NameChars
    add hl, de
    ld a, [hl]
    sub 32
    pop hl
    ld [hl+], a
    pop de
    dec b
    jr nz, .next
    ret

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
    ld a, EDIT_ROWS_PER_FRAME   ; several rows a frame (a page change redraws 8 of them), as long as
    ld [wRowBudget], a          ; VBlank has time left
.again:
    ld a, [wDirtyEdit]
    and a
    ret z
    ldh a, [rLY]
    cp 148
    ret nc                  ; (the rest waits for the next frame)
    ld a, [wDirtyEdit]
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
    call DrawEditRow
    ld a, [wRowBudget]
    dec a
    ld [wRowBudget], a
    jr nz, .again
    ret

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
    call DrawString
    ld hl, _SCRN0 + 18      ; page: P1 = patch rows 0-7, P2 = 8-15, P3 = 16-23
    ld a, 'P' - 32
    ld [hl+], a
    ld a, [wEditRow]
    and $18
    rrca
    rrca
    rrca
    add '1' - 32
    ld [hl], a
    ret

; b = screen row 0..7 of the edit list; the page of wEditRow picks patch row b + 8 * page
DrawEditRow:
    ld a, b
    swap a
    ld l, a
    ld h, 0
    add hl, hl              ; screen row * 32
    ld de, _SCRN0 + 2 * 32
    add hl, de              ; hl = start of this row on the map
    push hl
    ld a, [wEditRow]
    and $18
    or b
    ld b, a                 ; b = patch row
    call EntryPtr           ; hl = entry
    ld a, [hl+]
    ld c, a                 ; c = max (0 = hidden)
    ld d, h
    ld e, l                 ; de -> name string
    pop hl
    push de
    ld a, c
    and a
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
    inc hl                  ; value at cols 8-10, right-aligned
    push hl
    call PatchRowHL
    ld a, [hl]
    pop hl
    ld c, a
    ld a, [wSelCh]
    cp NUM_CH
    ld a, c
    jp nz, DrawNum3
    ld c, a                 ; the MIDI page:
    ld a, b
    cp PM_TSD
    ld a, c
    jp nz, DrawNum3
    cp 3                    ; UNIT shows the denominator (4, 8, 16), not its index
    jr c, .unit
    xor a
.unit:
    push hl
    ld e, a
    ld d, 0
    ld hl, TsDenShown
    add hl, de
    ld a, [hl]
    pop hl
    jp DrawNum3

TsDenShown: db 4, 8, 16

; a = 0..255, hl = dest -> three tiles, right-aligned, no leading zeros. Clobbers a, b, c.
DrawNum3:
    ld b, 0
.h: cp 100
    jr c, .hd
    sub 100
    inc b
    jr .h
.hd:
    ld c, a                 ; c = tens and ones
    ld a, b
    and a
    jr z, .noH
    add '0' - 32
.noH:
    ld [hl+], a             ; hundreds, or blank
    ld a, c
    ld c, b                 ; c = hundreds (non-zero: the tens must show)
    ld b, 0
.t: cp 10
    jr c, .td
    sub 10
    inc b
    jr .t
.td:
    push af                 ; ones
    ld a, b
    or c
    jr z, .noT
    ld a, b
    add '0' - 32
.noT:
    ld [hl+], a             ; tens, or blank
    pop af
    add '0' - 32
    ld [hl+], a
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
    swap a
    add a                   ; * PATCH_SIZE (32)
    add b
    add LOW(wPatch)         ; wPatch is 256-byte aligned: no carry
    ld l, a
    ld h, HIGH(wPatch)
    ret

; Row 17 message line: wMsg = 0 clears it (and restores the sequencer status).
DrawMsg:
    ld a, [wScreen]
    cp SCREEN_SEQ
    jr z, .roll
    ld c, 17                ; the other screens use $9800 only (SCY = 0)
    ld a, HIGH(_SCRN0)
    call DrawMsgRow
    ld c, 17
    ld a, HIGH(_SCRN0) + 4
    call DrawMsgRow
    jr .done
.roll:                      ; the piano roll: the status row of each map, wherever its window put it
    ld a, [wShownTop]
    ld l, a
    ld a, 17
    sub l
    and RING_ROWS - 1
    ld c, a
    ld a, [wShown]
    and a
    ld a, HIGH(_SCRN0)
    jr z, .shown
    ld a, HIGH(_SCRN0) + 4
.shown:
    call DrawMsgRow
    ld a, [wRollTop]
    ld l, a
    ld a, 17
    sub l
    and RING_ROWS - 1
    ld c, a
    ld a, [wShown]
    and a
    ld a, HIGH(_SCRN0) + 4
    jr z, .hidden
    ld a, HIGH(_SCRN0)
.hidden:
    call DrawMsgRow
.done:
    ld a, [wMsg]
    and a
    ret nz
    ld a, [wScreen]         ; the message is gone: the sequencer's status line comes back
    cp SCREEN_SEQ
    ret nz
    jp MarkSeqStatus

; a = HIGH of a tile map, c = map row: clear that row and write the message (if any).
DrawMsgRow:
    ld l, c
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl              ; row * 32
    add h
    ld h, a
    ld d, h
    ld e, l                 ; de = the row
    ld b, 20
    xor a
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld a, [wMsg]
    and a
    ret z
    dec a
    add a
    ld l, a
    ld h, 0
    push de
    ld de, MsgTable
    add hl, de
    pop de
    ld a, [hl+]
    ld c, a
    ld a, [hl]
    ld h, a
    ld l, c                 ; hl = the message text
    push de
    ld d, h
    ld e, l                 ; de = text
    pop hl                  ; hl = the row
    call DrawString
    inc hl                  ; every message ends with the slot number
    ld a, [wSlot]
    add '1' - 32
    ld [hl], a
    ret

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
sHelp1:       db "A:PLAY ST+LR:SCREEN", 0
sHelp2:       db "SEL:CH  PAD:NOTE", 0
sHelp3:       db "SEL+A:SAVE +B:LOAD", 0
sKbdTitle:    db "KEYBOARD   ", 0
sKbdHelp1:    db "PAD BUTTONS: OFF    ", 0
sKbdHelp2:    db "SEL TAP: NEXT CH    ", 0
sKbdHelp3:    db "START+LEFT: BACK    ", 0
sPatch:       db "PATCH", 0
sCh:          db "CH", 0
sEditHelp1:   db "UD:ROW LR/SEL+UD:VAL", 0
sEditHelp2:   db "A:PLAY  B+PAD:NOTE", 0
sEditHelp3:   db "SEL:CH ST+LR:SCREEN", 0
sMsgSaved:    db "SAVED", 0
sMsgLoaded:   db "LOADED", 0
sMsgNoData:   db "NO SAVE DATA", 0
sMsgFail:     db "SAVE FAILED", 0
sMsgInUse:    db "SLOT IN USE", 0
sMsgConfirm:  db "AGAIN:OVERWRITE", 0
MsgTable:     dw sMsgSaved, sMsgLoaded, sMsgNoData, sMsgFail, sMsgInUse, sMsgConfirm
sSlot:        db "SLOT", 0
sSlotUsed:    db "USED", 0
sSlotFree:    db "FREE", 0
sSlotHint:    db "SEL+LR", 0
sSlotList:    db "ST+DOWN:SLOT LIST", 0
sSlotTitle:   db "SAVE SLOTS", 0
sSlotHelp1:   db "UD:PICK  A:LOAD", 0
sSlotHelp2:   db "B:SAVE (TWICE:OVER)", 0
sSlotHelp4:   db "LR:POS  SEL+UD:CHAR", 0
sSlotHelp3:   db "ST+UP:BACK", 0
sNameLabel:   db "NAME", 0
NameChars:    db " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
NameCharsEnd:
    ASSERT NameCharsEnd - NameChars == NAME_CHARS
sStop:        db "STOP", 0
sPlay:        db "PLAY", 0
TypeNames:    db "PUL1", 0, "PUL2", 0, "WAVE", 0, "NOIS", 0, "MIDI", 0
NoteNames:    db "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"

INCLUDE "font.inc"

; ---------------------------------------------------------------- parameter tables
; In ROM bank 1 (the MBC5 boots with bank 1 at $4000 and nothing switches it).
SECTION "Param tables", ROMX, BANK[1]

; Parameter tables: EDIT_ROWS rows per channel, [max, 4-char name, 0]. max 0 = hidden
; (so a parameter can go up to 255, e.g. the CH3 length). Row = patch byte (synth.inc).
MACRO PARAM
    db \1
    db \2, 0
ENDM

ParamTables:  dw PT_Pulse1, PT_Pulse2, PT_Wave, PT_Noise, PT_Midi

PT_Pulse1:
    PARAM 3, "DUTY"
    PARAM 15, "VOL "
    PARAM 1, "EDIR"
    PARAM 7, "EPAC"
    PARAM 64, "LEN "
    PARAM 2, "PAN "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
    PARAM 7, "SWT "
    PARAM 1, "SWD "
    PARAM 7, "SWS "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 15, "ARP1"
    PARAM 15, "ARP2"
    PARAM 15, "ARPS"
    PARAM 7, "SLID"
    PARAM 3, "DUT2"
    PARAM 15, "DSPD"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
PT_Pulse2:
    PARAM 3, "DUTY"
    PARAM 15, "VOL "
    PARAM 1, "EDIR"
    PARAM 7, "EPAC"
    PARAM 64, "LEN "
    PARAM 2, "PAN "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 15, "ARP1"
    PARAM 15, "ARP2"
    PARAM 15, "ARPS"
    PARAM 7, "SLID"
    PARAM 3, "DUT2"
    PARAM 15, "DSPD"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
PT_Wave:
    PARAM 7, "WAVE"
    PARAM 2, "LVL "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 255, "LEN "
    PARAM 2, "PAN "
    PARAM 7, "VIBD"
    PARAM 7, "VIBS"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 15, "ARP1"
    PARAM 15, "ARP2"
    PARAM 15, "ARPS"
    PARAM 7, "SLID"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
PT_Noise:
    PARAM 1, "WDTH"
    PARAM 15, "VOL "
    PARAM 1, "EDIR"
    PARAM 7, "EPAC"
    PARAM 64, "LEN "
    PARAM 2, "PAN "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 7, "NDIV"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "

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
    PARAM 7, "VOLL"
    PARAM 7, "VOLR"
    PARAM 16, "BEAT"
    PARAM 2, "UNIT"
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
    PARAM 0, "    "
PT_End:

    ASSERT PT_Pulse2 - PT_Pulse1 == EDIT_ROWS * 6
    ASSERT PT_Wave - PT_Pulse2 == EDIT_ROWS * 6
    ASSERT PT_Noise - PT_Wave == EDIT_ROWS * 6
    ASSERT PT_Midi - PT_Noise == EDIT_ROWS * 6
    ASSERT PT_End - PT_Midi == EDIT_ROWS * 6
