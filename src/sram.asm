; Save/load a song (patches, chain, patterns, BPM) to cartridge SRAM (MBC5, 128 KB on the Smart Card).
;
; The SRAM is shared with every ROM on the card (LSDj uses it from the bottom), so ChromaSynth
; only touches the LAST FOUR 8 KB banks as NUM_SLOTS slots of one bank each:
;   slot n: bank SLOT_BANK0 + n, address $A000
; Version 11 (docs/M19_PATTERN_POOL.md, docs/M20_PER_CHANNEL_CHAINS.md):
;   +0    "CSYN", +4 version (SAVE_VERSION)
;   +5    checksum = (the sum of the bytes from +6 to the end of the coded pages) xor $A5
;   +6    the length of the coded pages (2 bytes)
;   +8    the mask (16 bytes): bit pattern * 8 + channel * 2 + half says that this channel half of that pattern is saved, in that order
;   +24   the name (NAME_LEN bytes, indices into NameChars)
;   +32   wPatch (NUM_PATCHES * PATCH_SIZE = 160 bytes), wChain (CHAIN_LEN), wBpm, wSeqBars
;         per pattern: numerator x16, denominator index x16, loop bars x16
;         the custom CH3 waves: a mark byte ($A5), then W1-W4 of 16 bytes
;   +323  the pages that are lent, each as one coded channel (EncodeChannel)
; Version 9 (4 patterns of 2 raw segments; the checksum at +6327, the name at +6328, then the per pattern values and the waves) is still read
; (LoadV9) and becomes version 11 when saved again. (A version 10 existed only on a development branch.)
; A slot is written only if it already holds a ChromaSynth save or is completely $00 / $FF;
; anything else (LSDj data that grew into these banks) is never overwritten (MSG_INUSE).
; Bump SAVE_VERSION whenever the layout changes, so old saves are ignored.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF SAVE_VERSION  EQU 11
DEF V9_DATA_LEN   EQU NUM_PATCHES * PATCH_SIZE + CHAIN_LEN + 2 + 4 * NUM_CH * NUM_SEGS * SEQ_TICKS   ; the data of a version 9 save (its checksum follows)
DEF SAVE_SUM      EQU 5
DEF SAVE_LEN      EQU 6
DEF SAVE_MASK     EQU 8
DEF SAVE_NAME     EQU 24
DEF FIXED_LEN     EQU NAME_LEN + NUM_PATCHES * PATCH_SIZE + CHAIN_LEN + 2 + 3 * NUM_PATS + 1 + 16 * NUM_CUSTOM   ; name ... waves
DEF SAVE_HEADER   EQU SAVE_NAME + FIXED_LEN             ; where the coded pages start

SECTION "SRAM", ROMX, BANK[1]   ; (bank 0 is nearly full; bank 1 is always mapped: nothing switches it)

SaveMagic:  db "CSYN", SAVE_VERSION

; Which mapper chips work: MBC5 (the target), MBC3 (the same RAM enable and bank registers) and MBC1 (needs RAM banking mode 1,
; which is selected here: a write to $6000 does nothing on an MBC5 and only a lone "1" on an MBC3, which is not a clock latch).
SramOpen:
    ld a, 1
    ld [$6000], a
    ld a, CART_SRAM_ENABLE
    ld [rRAMG], a
    ret

; The number of save slots from the cartridge header (RAM size code at $0149): 2 = 8 KB: one slot; 3, 4, 5 = 32 KB or more:
; NUM_SLOTS (4); anything else (no SRAM, 2 KB): none. A ROM built for 32 KB on an 8 KB cartridge is not detected: the header
; is what the ROM believes (docs/CARTRIDGES.md). Clobbers a.
InitSlots:
    ld a, [$0149]
    cp 2
    jr c, .none
    jr z, .one
    cp 6
    jr nc, .none
    ld a, NUM_SLOTS
    jr .set
.one:
    ld a, 1
    jr .set
.none:
    xor a
.set:
    ld [wNumSlots], a
    ret

SramClose:
    xor a
    ld [rRAMB], a
    ld [rRAMG], a           ; disabling protects the save from stray writes
    ret

; Selects the selected slot's bank. -> hl = start of the slot (SRAM must be open). Clobbers a.
SlotBase:
    ld a, [wSlot]
    add SLOT_BANK0
    ld [rRAMB], a           ; the slot's bank (SRAM must be open)
    ld hl, _SRAM
    ret

; -> a = 1 << wSlot. Clobbers b.
SlotMask:
    ld a, [wSlot]
    ld b, a
    ld a, 1
    inc b
    dec b
    ret z
.shift:
    add a
    dec b
    jr nz, .shift
    ret

; c = pad bits (LEFT / RIGHT): select the previous / next slot (clamped). Clobbers a, hl.
SlotStep:
    ld a, [wSlot]
    bit PADB_LEFT, c
    jr z, .right
    and a
    ret z
    dec a
    jr .set
.right:
    inc a
    ld hl, wNumSlots
    cp [hl]
    ret nc                  ; no slot after this one
.set:
    ld [wSlot], a
    xor a
    ld [wConfirm], a
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS
    ld [hl], a
    ret

; hl = NAME_LEN name bytes -> wSlotNames for slot wSlot (bytes out of range become blank).
CacheName:
    ld a, [wSlot]
    add a
    add a
    add a
    add LOW(wSlotNames)     ; wSlotNames is 64-byte aligned: no carry
    ld e, a
    ld d, HIGH(wSlotNames)
    ld b, NAME_LEN
.copy:
    ld a, [hl+]
    cp NAME_CHARS
    jr c, .ok
    xor a
.ok:
    ld [de], a
    inc de
    dec b
    jr nz, .copy
    ret

; Clamp wName to valid indices.
SanitizeName:
    ld hl, wName
    ld b, NAME_LEN
.next:
    ld a, [hl]
    cp NAME_CHARS
    jr c, .ok
    xor a
    ld [hl], a
.ok:
    inc hl
    dec b
    jr nz, .next
    ret

; c = +1 / -1: the character under the name cursor (wraps through NameChars).
NameChar:
    ld a, [wNameCur]
    ld e, a
    ld d, 0
    ld hl, wName
    add hl, de
    ld a, [hl]
    add c
    cp NAME_CHARS
    jr c, .set
    bit 7, a
    ld a, NAME_CHARS - 1    ; below 0
    jr nz, .set
    xor a                   ; past the last
.set:
    ld [hl], a
    jr MarkName

; c = +1 / -1: move the name cursor (clamped).
NameCursor:
    ld a, [wNameCur]
    add c
    cp NAME_LEN
    ret nc                  ; -1 from 0 wraps to $FF, +1 from the end hits NAME_LEN
    ld [wNameCur], a
MarkName:
    ld a, 1
    ld [wDirtyName], a
    ret

; a = new slot. Slot screen: marks the old and the new row for redraw, drops a pending "again".
SlotGoto:
    push af
    call SlotMask
    ld hl, wDirtySlot
    or [hl]
    ld [hl], a
    pop af
    ld [wSlot], a
    xor a
    ld [wConfirm], a
    call SlotMask
    ld hl, wDirtySlot
    or [hl]
    ld [hl], a
    ret

; Slot screen input. d = buttons newly pressed.
SlotInput:
    ld a, [wJoy]
    bit PADB_SELECT, a
    jr z, .plain
    ld a, d                 ; SELECT + UP/DOWN: the character under the name cursor
    and (1 << PADB_UP) | (1 << PADB_DOWN)
    ret z
    ld a, 1
    ld [wSelUsed], a        ; no channel tap on release
    ld c, 1
    bit PADB_UP, d
    jr nz, NameChar
    ld c, $FF
    jr NameChar
.plain:
    bit PADB_A, d
    jp nz, DoLoad
    bit PADB_B, d
    jp nz, DoSave
    ld a, [wSlot]
    bit PADB_UP, d
    jr z, .down
    and a
    ret z
    dec a
    jr SlotGoto
.down:
    bit PADB_DOWN, d
    jr z, .lr
    inc a
    ld hl, wNumSlots
    cp [hl]
    ret nc
    jr SlotGoto
.lr:
    ld c, $FF               ; LEFT / RIGHT: the name cursor
    bit PADB_LEFT, d
    jr nz, NameCursor
    ld c, 1
    bit PADB_RIGHT, d
    ret z
    jr NameCursor

; hl = slot start (SRAM open). -> carry set if the slot may NOT be written: it is neither a
; ChromaSynth save (any version) nor entirely $00 or $FF. Clobbers a, bc, de, hl.
SlotWritable:
    push hl
    ld de, SaveMagic
    ld b, 4
.magic:
    ld a, [de]
    cp [hl]
    jr nz, .notOurs
    inc hl
    inc de
    dec b
    jr nz, .magic
    pop hl
    and a
    ret
.notOurs:
    pop hl
    ld a, [hl]
    cp $FF
    jr z, .uniform
    and a
    jr nz, .foreign
.uniform:
    ld d, a
    ld bc, SLOT_SIZE
.cmp:
    ld a, [hl+]
    cp d
    jr nz, .foreign
    dec bc
    ld a, b
    or c
    jr nz, .cmp
    and a
    ret
.foreign:
    scf
    ret

; hl = src, de = dst, bc = count (>0). Copies while adding the bytes to wSaveSum.
CopySum:
    ld a, [hl+]
    ld [de], a
    inc de
    push hl
    ld hl, wSaveSum
    add [hl]
    ld [hl], a
    pop hl
    dec bc
    ld a, b
    or c
    jr nz, CopySum
    ret

; hl = src, de = dst, bc = count (>0).
CopyBytes:
    ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, CopyBytes
    ret

; Write the current state to the selected slot, then read it back to verify.
; -> a = message code (MSG_SAVED, MSG_FAIL, MSG_INUSE).
SaveAll:
    call TsStore            ; the edited pattern's time signature and length into the arrays
    call SramOpen
    call SlotBase
    call SlotWritable       ; (clobbers de)
    jp c, .inUse
    call SlotBase
    ld a, [wPoolBytes]      ; the coded pages must fit behind the header (the pool's budget keeps them below)
    ld l, a
    ld a, [wPoolBytes + 1]
    ld h, a
    ld de, SLOT_SIZE - SAVE_HEADER + 1
    ld a, h
    cp d
    jr c, .fits
    jp nz, .fail
    ld a, l
    cp e
    jp nc, .fail
.fits:
    xor a
    ld [wSaveSum], a
    ld hl, SaveMagic
    ld de, _SRAM
    ld bc, 5
    call CopyBytes          ; magic and version; the checksum, the length and the mask follow once they are known
    ld de, _SRAM + SAVE_NAME
    ld hl, wName
    ld bc, NAME_LEN
    call CopySum
    ld hl, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call CopySum
    ld hl, wChain
    ld bc, CHAIN_LEN
    call CopySum
    ld hl, wBpm
    ld bc, 1
    call CopySum
    ld hl, wSeqBars
    ld bc, 1
    call CopySum
    ld hl, wPatTsn          ; per pattern: time signature and loop length
    ld bc, 3 * NUM_PATS
    call CopySum
    ld hl, wWaveMark        ; the custom CH3 waves
    ld bc, 1 + 16 * NUM_CUSTOM
    call CopySum
    ; de = _SRAM + SAVE_HEADER: the pages that are lent, in the order of wPatPage, each as one coded channel
    ld hl, wSaveMask
    ld b, 16
    xor a
.clearMask:
    ld [hl+], a
    dec b
    jr nz, .clearMask
    ld a, e
    ld [wSaveDst], a
    ld a, d
    ld [wSaveDst + 1], a
    xor a
    ld [wSaveIdx], a
.page:
    ld a, [wSaveIdx]
    ld c, a
    ld b, 0
    ld hl, wPatPage
    add hl, bc
    ld a, [hl]
    cp NO_PAGE
    jr z, .nextPage
    push af
    ld a, [wSaveIdx]
    call SetMaskBit
    pop af
    call PageAddr           ; h = the page, SVBK set
    ld d, h
    ld e, 0
    ld a, [wSaveDst]
    ld l, a
    ld a, [wSaveDst + 1]
    ld h, a                 ; hl = where the coded channel goes
    call EncodeChannel      ; (d = the page, e = 0; hl advances)
    ld a, l
    ld [wSaveDst], a
    ld a, h
    ld [wSaveDst + 1], a
.nextPage:
    ld hl, wSaveIdx
    inc [hl]
    ld a, [hl]
    cp NUM_PATS * PAT_PAGES
    jp c, .page
    ; the length of the coded region, the mask, the checksum
    ld a, [wSaveDst]
    sub LOW(_SRAM + SAVE_HEADER)
    ld e, a
    ld a, [wSaveDst + 1]
    sbc HIGH(_SRAM + SAVE_HEADER)
    ld d, a
    ld hl, _SRAM + SAVE_LEN
    ld a, e
    ld [hl+], a
    ld a, d
    ld [hl], a
    ld hl, wSaveSum         ; the sum covers the length and the mask too (the sum does not care about the order)
    add [hl]
    add e
    ld [hl], a
    ld hl, wSaveMask
    ld de, _SRAM + SAVE_MASK
    ld bc, 16
    call CopySum
    ld a, [wSaveSum]
    xor $A5
    ld [_SRAM + SAVE_SUM], a
    call SlotBase
    call ValidateSave
    jr c, .failClose
    call SlotMask
    ld hl, wSlotUsed
    or [hl]
    ld [hl], a
    ld hl, wName
    call CacheName
    call SramClose
    ld a, MSG_SAVED
    ret
.fail:
.failClose:
    call SramClose
    ld a, MSG_FAIL
    ret
.inUse:
    call SramClose
    ld a, MSG_INUSE
    ret

; a = a bit index (0..127): set that bit in wSaveMask (byte index / 8). Clobbers a, bc, hl.
SetMaskBit:
    ld c, a
    srl a
    srl a
    srl a
    ld hl, wSaveMask
    add l
    ld l, a
    jr nc, .nc
    inc h
.nc:
    ld a, c
    and 7
    ld b, a
    ld a, 1
    inc b
.shift:
    dec b
    jr z, .shifted
    add a
    jr .shift
.shifted:
    or [hl]
    ld [hl], a
    ret

; a = a bit index: -> nz if that bit of wSaveMask is set. Clobbers a, bc, hl.
TestMaskBit:
    ld c, a
    srl a
    srl a
    srl a
    ld hl, wSaveMask
    add l
    ld l, a
    jr nc, .nc
    inc h
.nc:
    ld a, c
    and 7
    ld b, a
    ld a, [hl]
    inc b
.shift:
    dec b
    jr z, .done
    srl a
    jr .shift
.done:
    and 1
    ret

; hl = destination (SRAM), d = the source page (e = 0): one channel half (a page), 192 cells, coded: a mode byte, then
; 0 = empty (nothing more) / 1 = a bitmap of the 192 ticks (24 bytes, tick 0 = bit 0 of the first byte) and then the used cells in order /
; 2 = all 192 cells. The mode is 2 when RAW_MIN cells or more are used, else 1 (pool.asm counts the same sizes). The bytes are added to
; wSaveSum. -> hl after the coded bytes. Clobbers a, bc, de.
EncodeChannel:
    push de
    ld b, 0                 ; b = cells that are used
    ld c, SEQ_TICKS
.count:
    ld a, [de]
    inc de
    and a
    jr z, .z
    inc b
.z:
    dec c
    jr nz, .count
    pop de
    ld a, b
    and a
    jr nz, .some
    xor a
    jp PutSum               ; empty: mode 0
.some:
    cp RAW_MIN
    jr nc, .raw
    ld a, 1
    call PutSum
    push de                 ; the bitmap: 24 bytes of 8 ticks
    ld b, SEQ_TICKS / 8
.bmByte:
    ld c, 8
    xor a
    ld [wEncAcc], a
.bit:
    ld a, [de]
    inc de
    and a
    ld a, [wEncAcc]
    jr z, .zero
    scf
    jr .shiftIn
.zero:
    and a                   ; (carry clear)
.shiftIn:
    rra
    ld [wEncAcc], a
    dec c
    jr nz, .bit
    call PutSum
    dec b
    jr nz, .bmByte
    pop de                  ; then the used cells
    ld c, SEQ_TICKS
.cells:
    ld a, [de]
    inc de
    and a
    call nz, PutSum
    dec c
    jr nz, .cells
    ret
.raw:
    ld a, 2
    call PutSum
    ld c, SEQ_TICKS
.rawCells:
    ld a, [de]
    inc de
    call PutSum
    dec c
    jr nz, .rawCells
    ret

; a = a byte: put it at hl, advance, add it to wSaveSum. Keeps bc, de. Clobbers a.
PutSum:
    ld [hl+], a
    push hl
    ld hl, wSaveSum
    add [hl]
    ld [hl], a
    pop hl
    ret

; hl = source (SRAM), d = the destination page (e = 0): the reverse of EncodeChannel (all 192 cells are written).
; -> hl after the coded bytes. Clobbers a, bc, de.
DecodeChannel:
    ld a, [hl+]
    and a
    jr nz, .coded
    ld c, SEQ_TICKS         ; empty
    xor a
.zeros:
    ld [de], a
    inc e
    dec c
    jr nz, .zeros
    ret
.coded:
    cp 2
    jr nz, .bitmap
    ld c, SEQ_TICKS         ; raw
.rawCells:
    ld a, [hl+]
    ld [de], a
    inc e
    dec c
    jr nz, .rawCells
    ret
.bitmap:
    push de
    ld de, wBitmap          ; the 24 bitmap bytes are copied out, hl then points at the cells
    ld bc, SEQ_TICKS / 8
    call CopyBytes
    pop de
    xor a
    ld [wDecIdx], a
    ld b, SEQ_TICKS / 8
.byte:
    push hl
    ld a, [wDecIdx]
    add LOW(wBitmap)        ; wBitmap is 32-byte aligned and 24 bytes long: no carry
    ld l, a
    ld h, HIGH(wBitmap)
    ld a, [hl]
    ld [wEncAcc], a
    ld hl, wDecIdx
    inc [hl]
    pop hl
    ld c, 8
.bit:
    ld a, [wEncAcc]
    rra
    ld [wEncAcc], a
    jr nc, .none
    ld a, [hl+]
    jr .put
.none:
    xor a
.put:
    ld [de], a
    inc e
    dec c
    jr nz, .bit
    dec b
    jr nz, .byte
    ret

; Restore the state from the selected slot. -> carry set if it holds no valid save.
LoadAll:
    ld a, [wNumSlots]
    and a
    jr nz, .have
    scf                     ; no SRAM: nothing to load
    ret
.have:
    call SramOpen
    call SlotBase
    call ValidateSave       ; carry: bad; else wSaveVer = 9 or SAVE_VERSION
    jr c, .bad
    ld a, [wSaveVer]
    cp 9
    jp z, LoadV9
    ld hl, _SRAM + SAVE_MASK
    ld de, wSaveMask
    ld bc, 16
    call CopyBytes
    call LoadFixed          ; hl = the coded pages
    call LoadPages
    jp LoadDone
.bad:
    call SramClose
    scf
    ret

; hl = the name of a version 11 slot -> the name, the patches, the chain, bpm, loop length, the per pattern values and the waves are
; in RAM; hl = after them (the coded part). Clobbers a, bc, de.
LoadFixed:
    ld de, wName
    ld bc, NAME_LEN
    call CopyBytes
    ld de, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call CopyBytes
    ld de, wChain
    ld bc, CHAIN_LEN
    call CopyBytes
    ld de, wBpm
    ld bc, 1
    call CopyBytes
    ld de, wSeqBars
    ld bc, 1
    call CopyBytes
    ld de, wPatTsn
    ld bc, 3 * NUM_PATS
    call CopyBytes
    ld de, wWaveMark
    ld bc, 1 + 16 * NUM_CUSTOM
    jp CopyBytes

; hl = the coded pages, wSaveMask says which channel halves of which patterns they are (in order): lend each one a page and decode it.
LoadPages:
    ld a, l
    ld [wSaveDst], a
    ld a, h
    ld [wSaveDst + 1], a
    call PoolInit
    xor a
    ld [wSaveIdx], a
.idx:
    ld a, [wSaveIdx]
    call TestMaskBit
    jr z, .next
    ld a, [wSaveIdx]
    and 1
    ld c, a                 ; the half
    ld a, [wSaveIdx]
    srl a
    and 3
    ld b, a                 ; the channel
    ld a, [wSaveIdx]
    srl a
    srl a
    srl a                   ; the pattern
    push af
    push bc
    call EnsurePage
    pop bc
    pop af
    call PageLoc            ; a = the page, SVBK set
    ld d, a
    ld e, 0
    ld a, [wSaveDst]
    ld l, a
    ld a, [wSaveDst + 1]
    ld h, a
    call DecodeChannel
    ld a, l
    ld [wSaveDst], a
    ld a, h
    ld [wSaveDst + 1], a
.next:
    ld hl, wSaveIdx
    inc [hl]
    ld a, [hl]
    cp NUM_PATS * PAT_PAGES
    jr c, .idx
    ret

; What every version does after the song is in RAM.
LoadDone:
    call PoolRecalcAll      ; (gives back the pages that came in empty)
    call SanitizeName
    call SramClose
    ld a, [wWaveMark]       ; a song saved before the custom waves existed: the default waves
    cp $A5
    call nz, WaveDefaults
    call SongLoaded         ; (clamps the chain, edits pattern 1 in loop mode)
    and a                   ; clear carry
    ret

; A song saved by version 9: 4 patterns of 2 segments, every channel in 192 raw bytes. Each channel half that holds anything is lent a page.
; The slot is open and valid.
LoadV9:
    ld hl, _SRAM + 5
    ld de, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call CopyBytes
    ld de, wChain
    ld bc, CHAIN_LEN
    call CopyBytes
    ld de, wBpm
    ld bc, 1
    call CopyBytes
    ld de, wSeqBars
    ld bc, 1
    call CopyBytes
    call PoolInit
    xor a                   ; patterns 5-16 are new, and a song from before the per-pattern values has $00 there: SongLoaded
    ld hl, wPatTsn          ; gives them the time signature and length of the song's one
    ld b, 3 * NUM_PATS
.defaults:
    ld [hl+], a             ; (wPatTsn, wPatTsd and wPatBars follow each other)
    dec b
    jr nz, .defaults
    xor a
    ld [wSaveIdx], a        ; pattern * 2 + segment, 0..7
.seg:
    xor a
    ld [wPoolTmp + 2], a    ; the channel
.ch:
    ld a, [wPoolTmp + 2]
    ld c, a
    call V9ChunkHL
    ld b, SEQ_TICKS
    xor a
.or:
    or [hl]
    inc hl
    dec b
    jr nz, .or
    and a
    jr z, .nextCh           ; an empty channel half: no page
    ld a, [wSaveIdx]
    and 1
    ld c, a                 ; the half
    ld a, [wPoolTmp + 2]
    ld b, a                 ; the channel
    ld a, [wSaveIdx]
    srl a                   ; the pattern
    push af
    push bc
    call EnsurePage
    pop bc
    pop af
    call PageLoc            ; a = the page, SVBK set
    ld [wLoadPage], a
    ld a, [wPoolTmp + 2]
    ld c, a
    call V9ChunkHL
    ld a, [wLoadPage]
    ld d, a
    ld e, 0
    ld bc, SEQ_TICKS
    call CopyBytes          ; the 192 cells (the page's last 64 bytes stay as the clear left them)
.nextCh:
    ld hl, wPoolTmp + 2
    inc [hl]
    ld a, [hl]
    cp NUM_CH
    jr c, .ch
    ld hl, wSaveIdx
    inc [hl]
    ld a, [hl]
    cp 8
    jr c, .seg
    ld hl, _SRAM + 6328     ; the name, then 4 x numerator, 4 x denominator index, 4 x loop bars, then the waves
    ld de, wName
    ld bc, NAME_LEN
    call CopyBytes
    ld de, wPatTsn
    ld bc, 4
    call CopyBytes
    ld de, wPatTsd
    ld bc, 4
    call CopyBytes
    ld de, wPatBars
    ld bc, 4
    call CopyBytes
    ld de, wWaveMark
    ld bc, 1 + 16 * NUM_CUSTOM
    call CopyBytes
    jp LoadDone

; wSaveIdx = pattern * 2 + segment of a version 9 save (0..7), c = the channel -> hl = that channel's 192 bytes in the slot.
; Keeps c. Clobbers a, b, de.
V9ChunkHL:
    ld a, [wSaveIdx]
    and 1
    ld b, a                 ; the segment
    ld a, [wSaveIdx]
    srl a                   ; the pattern
    add a
    add a
    add a                   ; 8 chunks a pattern
    add b
    ld b, a
    ld a, c
    add a
    add b                   ; the chunk number: pattern * 8 + channel * 2 + segment
    ld hl, _SRAM + 183      ; the patterns follow the bpm and the loop length
    ld de, SEQ_TICKS
    and a
    ret z
    ld b, a
.add:
    add hl, de
    dec b
    jr nz, .add
    ret

; Fill wSlotUsed: which slots hold a valid save. Keeps wSlot.
ScanSlots:
    xor a
    ld [wSlotUsed], a
    ld hl, wSlotNames
    ld bc, NUM_SLOTS * NAME_LEN
    call MemClear
    ld a, [wNumSlots]
    and a
    ret z                   ; no SRAM to look at
    call SramOpen
    ld a, [wSlot]
    push af
    xor a
.next:
    ld [wSlot], a
    call SlotBase
    call ValidateSave
    jr c, .empty
    ld hl, _SRAM + SAVE_NAME
    ld a, [wSaveVer]
    cp 9
    jr nz, .notV9
    ld hl, _SRAM + 6328     ; version 9: the name follows the checksum
.notV9:
.name:
    call CacheName
    call SlotMask
    ld hl, wSlotUsed
    or [hl]
    ld [hl], a
.empty:
    ld a, [wSlot]
    inc a
    ld hl, wNumSlots
    cp [hl]
    jr c, .next
    pop af
    ld [wSlot], a
    jp SramClose

; hl = slot start, SRAM open. -> carry set if magic/version/checksum is wrong. On success wSaveVer = the version (9 or SAVE_VERSION).
ValidateSave:
    ld de, SaveMagic
    ld b, 4
.magic:
    ld a, [de]
    cp [hl]
    jr nz, .bad
    inc hl
    inc de
    dec b
    jr nz, .magic
    ld a, [hl]              ; the version
    cp 9
    jr z, .v9
    ld de, SAVE_HEADER
    cp SAVE_VERSION
    jr nz, .bad
.region:                    ; version 11: +5 checksum, +6 the length of the coded part, then the rest of the header (de bytes in all)
    ld [wSaveVer], a
    ld hl, _SRAM + SAVE_LEN
    ld a, [hl+]
    ld c, a
    ld b, [hl]              ; bc = the length of the coded part
    ld hl, SLOT_SIZE
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a                 ; hl = the most the coded part can be
    ld a, h
    cp b
    jr c, .bad
    jr nz, .lenOk
    ld a, l
    cp c
    jr c, .bad
.lenOk:
    ld h, d
    ld l, e
    add hl, bc              ; the header and the coded part
    ld de, -SAVE_LEN
    add hl, de              ; the bytes from the length on
    ld b, h
    ld c, l
    ld hl, _SRAM + SAVE_LEN
    ld de, 0                ; d = running sum
.sum:
    ld a, [hl+]
    add d
    ld d, a
    dec bc
    ld a, b
    or c
    jr nz, .sum
    ld a, [_SRAM + SAVE_SUM]
    xor $A5
    cp d
    jr nz, .bad
    and a
    ret
.v9:
    ld [wSaveVer], a
    inc hl
    push hl
    ld de, 0                ; d = running sum (e unused)
    ld bc, V9_DATA_LEN
.sum9:
    ld a, [hl+]
    add d
    ld d, a
    dec bc
    ld a, b
    or c
    jr nz, .sum9
    ld a, [hl]              ; stored checksum
    xor $A5
    cp d
    pop hl
    jr nz, .bad
    and a
    ret
.bad:
    scf
    ret

; ---------------------------------------------------------------- UI glue
; SELECT+B. A used slot asks for a second SELECT+B before it is overwritten.
DoSave:
    ld a, [wNumSlots]
    and a
    jr nz, .some
    ld a, MSG_FAIL          ; no SRAM in this cartridge
    jp SetMsg
.some:
    call SlotMask
    ld hl, wSlotUsed
    and [hl]
    jr z, .go               ; an empty slot: just save
    ld a, [wSlot]
    inc a
    ld hl, wConfirm
    cp [hl]
    jr z, .go               ; the second press
    ld a, MSG_CONFIRM
    call SetMsg             ; (clears wConfirm)
    ld a, [wSlot]
    inc a
    ld [wConfirm], a
    ret
.go:
    call SaveAll
    call SetMsg
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS         ; the play screen's USED / FREE mark
    ld [hl], a
    call SlotMask           ; and the slot list's
    ld hl, wDirtySlot
    or [hl]
    ld [hl], a
    ret

; SELECT+A
DoLoad:
    ld a, [wNumSlots]
    and a
    jr nz, .some
    ld a, MSG_NODATA
    jp SetMsg
.some:
    call LoadAll
    ld a, MSG_NODATA
    jr c, SetMsg
    ; everything on screen is stale now
    ld a, DIRTY_ALL | DIRTY_HEADER
    ld [wDirty], a
    ld a, $FF
    ld [wDirtyEdit], a
    call RollRefreshAll     ; piano roll: rebuild columns and redraw every row
    call MarkName
    ld a, MSG_LOADED
    ; fall through

; a = message code. Shown on row 17 for MSG_FRAMES frames.
SetMsg:
    ld [wMsg], a
    xor a
    ld [wConfirm], a        ; any message ends a pending "press again"
    ld a, MSG_FRAMES
    ld [wMsgTimer], a
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_MSG
    ld [hl], a
    ret

; Once per frame: expire the message.
MsgTick:
    ld a, [wMsgTimer]
    and a
    ret z
    dec a
    ld [wMsgTimer], a
    ret nz
    xor a
    ld [wMsg], a            ; 0 = clear the line
    ld [wConfirm], a
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_MSG
    ld [hl], a
    ret
