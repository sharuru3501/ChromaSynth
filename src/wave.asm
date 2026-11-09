; CH3 wave editor. The patch's WAVE value 0-3 is a preset (src/waves.inc), 4-7 is one of the four custom
; waves W1-W4 (wWaves, 16 bytes each in wave RAM format: two 4-bit samples a byte, the high nibble first).
; The custom waves are saved with the song (src/sram.asm).
;
; Screen (START+A on the edit screen with CH3 selected and WAVE = 4-7 opens it, START+B goes back):
;   rows 3-4  the 16 samples of the page (the cursor's half of the 32) as bars, 1-16 pixels high
;   row  5    the same samples as hex digits, the cursor's one inverted
;   row  7    which wave, which sample, its level
;   LEFT / RIGHT = sample, UP / DOWN = level +-1 (with B: +-4), A = hear it (hold), START+A = load the next preset
; The rows are built in the main loop (wWaveBuf) and copied one a frame in VBlank.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF ROW_WAVE_TOP  EQU _SCRN0 + 3 * 32
DEF ROW_WAVE_BOT  EQU _SCRN0 + 4 * 32
DEF ROW_WAVE_HEX  EQU _SCRN0 + 5 * 32
DEF ROW_WAVE_INFO EQU _SCRN0 + 7 * 32
DEF WAVE_COL0     EQU 2

SECTION "Wave editor", ROMX, BANK[1]

; The four custom waves start as copies of the four presets. Clobbers a, bc, de, hl.
WaveDefaults:
    ld hl, Waves
    ld de, wWaves
    ld bc, 16 * NUM_CUSTOM
    call MemCopy
    ld a, $A5
    ld [wWaveMark], a
    ret

; START+A on the edit screen (CH3): open the editor on the custom wave that the patch uses.
WaveOpen:
    ld a, [wPatch + 2 * PATCH_SIZE + P_MAIN]
    sub WAVE_CUSTOM
    ret c                   ; a preset: nothing to edit
    cp NUM_CUSTOM
    ret nc
    ld [wWaveSel], a
    ld a, SCREEN_WAVE + 1   ; (a request is the screen + 1)
    ld [wScreenReq], a
    ld a, 1
    ld [wNavHide], a
    ret

WaveClose:
    ld c, 2
    call NoteOff
    ld a, 2
    ld [wSelCh], a          ; (SELECT may have moved it)
    ld a, SCREEN_EDIT + 1
    ld [wScreenReq], a
    ld a, 1
    ld [wNavHide], a
    ret

; LCD off: draw the screen.
BuildWave:
    ld hl, _SCRN0 + 4
    ld de, sWaveTitle
    call DrawString
    ld hl, _SCRN0 + 10 * 32
    ld de, sWaveHelp1
    call DrawString
    ld hl, _SCRN0 + 11 * 32
    ld de, sWaveHelp2
    call DrawString
    ld hl, _SCRN0 + 12 * 32
    ld de, sWaveHelp3
    call DrawString
    ld hl, _SCRN0 + 13 * 32
    ld de, sWaveHelp4
    call DrawString
    ld hl, _SCRN0 + 14 * 32
    ld de, sWaveHelp5
    call DrawString
    ld hl, _SCRN0 + 15 * 32
    ld de, sWaveHelp6
    call DrawString
    call WaveRender
    ld hl, wWaveBuf         ; the LCD is off: all the rows at once
    ld de, ROW_WAVE_TOP
    call WaveCopyRow
    ld de, ROW_WAVE_BOT
    call WaveCopyRow
    ld de, ROW_WAVE_HEX
    call WaveCopyRow
    ld de, ROW_WAVE_INFO
    call WaveCopyRow
    xor a
    ld [wDirtyWave], a
    ret

; hl = source (20 tiles), de = destination -> hl past the source. Clobbers a, b, de.
WaveCopyRow:
    ld b, 20
.l: ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .l
    ret

; One dirty row per frame (called from UpdateUI inside VBlank).
UpdateWave:
    ld a, [wDirty]
    and DIRTY_MSG
    ld [wDirty], a
    ld a, [wDirtyWave]
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
    ld hl, wDirtyWave
    and [hl]
    ld [hl], a
    ld a, c                 ; the row's buffer: wWaveBuf + 20 * c
    add a
    add a
    ld b, a
    add a
    add a
    add b
    ld e, a
    ld d, 0
    ld hl, wWaveBuf
    add hl, de
    ld a, c
    ld de, WaveRowAddr
    add a
    add e
    ld e, a
    jr nc, .addr
    inc d
.addr:
    ld a, [de]
    inc de
    ld c, a
    ld a, [de]
    ld d, a
    ld e, c
    jr WaveCopyRow

WaveRowAddr:
    dw ROW_WAVE_TOP, ROW_WAVE_BOT, ROW_WAVE_HEX, ROW_WAVE_INFO

; a = sample index 0-31 -> hl = the byte of the selected custom wave that holds it, c = the index.
; Clobbers a, b, de.
WaveSampleAddr:
    ld c, a
    srl a
    ld b, a
    ld a, [wWaveSel]
    swap a
    add b
    ld e, a
    ld d, 0
    ld hl, wWaves
    add hl, de
    ret

; a = sample index -> a = its level 0-15. Clobbers b, c, de, hl.
WaveGet:
    call WaveSampleAddr
    ld a, [hl]
    bit 0, c
    jr nz, .low
    swap a
.low:
    and $0F
    ret

; Build the four rows in wWaveBuf (the cursor's page of 16 samples) and flag them. Clobbers everything.
WaveRender:
    ld hl, wWaveBuf
    ld bc, 20 * 4
    call MemClear
    ld a, [wWaveCur]
    and $10                 ; the page: samples 0-15 or 16-31
    ld [wWaveBase], a
    xor a
    ld [wWaveJ], a
.col:
    ld hl, wWaveJ
    ld a, [wWaveBase]
    add [hl]                ; the sample
    ld [wWaveIdx], a
    call WaveGet            ; a = its level
    ld d, a
    call NibbleTile         ; the hex digit, inverted under the cursor
    ld e, a
    ld a, [wWaveIdx]
    ld hl, wWaveCur
    cp [hl]
    jr nz, .notCur
    ld a, e
    add TILE_INV
    ld e, a
.notCur:
    ld a, [wWaveJ]
    add WAVE_COL0
    ld c, a
    ld b, 0
    ld hl, wWaveBuf + 40
    add hl, bc
    ld [hl], e
    ld a, d
    inc a                   ; the bar is level + 1 pixels high (1-16)
    cp 9
    jr nc, .tall
    add T_BAR1 - 1
    ld d, a                 ; d = the bottom tile, e = the top tile
    ld e, 0
    jr .put
.tall:
    sub 8
    add T_BAR1 - 1
    ld e, a
    ld d, T_BAR1 + 7
.put:
    ld hl, wWaveBuf
    add hl, bc
    ld [hl], e
    ld hl, wWaveBuf + 20
    add hl, bc
    ld [hl], d
    ld hl, wWaveJ
    inc [hl]
    ld a, [hl]
    cp 16
    jr c, .col
    ld a, [wWaveCur]        ; the info row
    call WaveGet
    ld [wWaveIdx], a        ; (the level)
    ld hl, wWaveBuf + 60 + WAVE_COL0
    ld a, 'W' - 32
    ld [hl+], a
    ld a, [wWaveSel]
    add '1' - 32
    ld [hl+], a
    inc hl
    ld de, sWaveSmp
    call DrawString
    ld a, [wWaveCur]
    inc a
    call DrawDec3
    inc hl
    ld de, sWaveLvl
    call DrawString
    ld a, [wWaveIdx]
    call DrawDec3
    ld a, %1111
    ld [wDirtyWave], a
    ret

; A pad frame on the wave editor (d = newly pressed, wJoy = held).
WaveInput:
    ld a, [wJoy]
    ld e, a
    bit PADB_START, e
    jr z, .plain
    bit PADB_B, d
    jp nz, WaveClose
    bit PADB_A, d
    ret z                   ; START+A: the next preset goes into this wave
    ld a, [wWavePre]
    inc a
    and 3
    ld [wWavePre], a
    swap a
    ld e, a
    ld d, 0
    ld hl, Waves
    add hl, de
    push hl
    ld a, [wWaveSel]
    swap a
    ld e, a
    ld d, 0
    ld hl, wWaves
    add hl, de
    ld d, h
    ld e, l
    pop hl
    ld bc, 16
    call MemCopy
    jp WaveRender
.plain:
    bit PADB_A, d
    jr z, .noPress
    push de
    ld a, 2
    ld [wPadCh], a
    ld c, a
    ld a, [wJoyNote]
    call NoteOn
    pop de
.noPress:
    ld a, [wJoyPrev]        ; A released: the note stops
    bit PADB_A, a
    jr z, .pad
    ld a, [wJoy]
    bit PADB_A, a
    jr nz, .pad
    push de
    ld c, 2
    call NoteOff
    pop de
.pad:
    ld a, [wWaveCur]
    ld b, a
    bit PADB_RIGHT, d
    jr z, .noRight
    inc a
    cp 32
    jr c, .noRight
    ld a, 31
.noRight:
    bit PADB_LEFT, d
    jr z, .noLeft
    and a
    jr z, .noLeft
    dec a
.noLeft:
    ld [wWaveCur], a
    cp b
    ld b, 0                 ; b = 1 when something changed
    jr z, .level
    inc b
.level:
    ld c, 0
    bit PADB_UP, d
    jr z, .noUp
    ld c, 1
.noUp:
    bit PADB_DOWN, d
    jr z, .noDown
    ld c, $FF
.noDown:
    ld a, c
    and a
    jr z, .done
    bit PADB_B, e           ; with B: steps of 4
    jr z, .step
    add a
    add a
.step:
    ld [wWaveIdx], a        ; the change
    push bc
    ld a, [wWaveCur]
    call WaveSampleAddr     ; hl = its byte, c = the index
    ld a, [hl]
    bit 0, c
    jr nz, .low
    swap a
.low:
    and $0F
    ld b, a
    ld a, [wWaveIdx]
    add b
    cp 16
    jr c, .inRange
    bit 7, a
    ld a, 15
    jr z, .inRange
    xor a
.inRange:
    ld b, a                 ; the new level
    ld a, [hl]
    bit 0, c
    jr nz, .writeLow
    and $0F
    ld e, a
    ld a, b
    swap a
    or e
    jr .store
.writeLow:
    and $F0
    or b
.store:
    ld [hl], a
    pop bc
    inc b
    ld a, [wJoy]            ; A held: hear the new level
    bit PADB_A, a
    jr z, .done
    push bc
    ld c, 2
    ld a, [wJoyNote]
    call NoteOn
    pop bc
.done:
    ld a, b
    and a
    ret z
    jp WaveRender

sWaveTitle: db "WAVE EDITOR", 0
sWaveSmp:   db "SMP", 0
sWaveLvl:   db "LVL", 0
sWaveHelp1: db "LEFT/RIGHT: SAMPLE", 0
sWaveHelp2: db "UP/DOWN: LEVEL +-1", 0
sWaveHelp3: db "B+UP/DOWN: +-4", 0
sWaveHelp4: db "A: HEAR (HOLD)", 0
sWaveHelp5: db "START+A: PRESET", 0
sWaveHelp6: db "START+B: BACK", 0
