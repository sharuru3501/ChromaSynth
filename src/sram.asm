; Save/load patches, pattern and BPM to cartridge SRAM (MBC5, 8 KB).
;
; Slot layout at $A000:
;   +0  "CSYN"   magic
;   +4  version  (SAVE_VERSION)
;   +5  wPatch   (NUM_CH * PATCH_SIZE bytes)
;   +37 wPattern (NUM_CH * SEQ_STEPS bytes)
;   +101 wBpm
;   +102 checksum = (sum of the data bytes) xor $A5
; Bump SAVE_VERSION whenever the layout changes, so old saves are ignored.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF SAVE_VERSION  EQU 1
DEF SAVE_DATA_LEN EQU NUM_CH * PATCH_SIZE + NUM_CH * SEQ_STEPS + 1

SECTION "SRAM", ROM0

SaveMagic:  db "CSYN", SAVE_VERSION

SramOpen:
    ld a, CART_SRAM_ENABLE
    ld [rRAMG], a
    xor a
    ld [rRAMB], a           ; bank 0
    ret

SramClose:
    xor a
    ld [rRAMG], a           ; disabling protects the save from stray writes
    ret

; hl = src, de = dst, b = count, c = running sum. Clobbers a.
CopySum:
    ld a, [hl+]
    ld [de], a
    inc de
    add c
    ld c, a
    dec b
    jr nz, CopySum
    ret

; hl = src, de = dst, b = count. Clobbers a.
CopyBytes:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, CopyBytes
    ret

; Write the current state to SRAM, then read it back to verify.
; -> carry set if the slot does not validate (e.g. the cart has no SRAM).
SaveAll:
    call SramOpen
    ld de, _SRAM
    ld hl, SaveMagic
    ld b, 5
    call CopyBytes
    ld c, 0
    ld hl, wPatch
    ld b, NUM_CH * PATCH_SIZE
    call CopySum
    ld hl, wPattern
    ld b, NUM_CH * SEQ_STEPS
    call CopySum
    ld hl, wBpm
    ld b, 1
    call CopySum
    ld a, c
    xor $A5
    ld [de], a
    call ValidateSave
    push af
    call SramClose
    pop af
    ret

; Restore the state from SRAM. -> carry set if there is no valid save.
LoadAll:
    call SramOpen
    call ValidateSave       ; -> hl = start of the data
    jr c, .bad
    ld de, wPatch
    ld b, NUM_CH * PATCH_SIZE
    call CopyBytes
    ld de, wPattern
    ld b, NUM_CH * SEQ_STEPS
    call CopyBytes
    ld de, wBpm
    ld b, 1
    call CopyBytes
    call SramClose
    and a                   ; clear carry
    ret
.bad:
    call SramClose
    scf
    ret

; SRAM must be open. -> carry set if magic/version/checksum is wrong.
; On success hl = address of the first data byte.
ValidateSave:
    ld hl, _SRAM
    ld de, SaveMagic
    ld b, 5
.magic:
    ld a, [de]
    cp [hl]
    jr nz, .bad
    inc hl
    inc de
    dec b
    jr nz, .magic
    push hl
    ld c, 0
    ld b, SAVE_DATA_LEN
.sum:
    ld a, [hl+]
    add c
    ld c, a
    dec b
    jr nz, .sum
    ld a, [hl]              ; stored checksum
    xor $A5
    cp c
    pop hl
    jr nz, .bad
    and a                   ; clear carry
    ret
.bad:
    scf
    ret

; ---------------------------------------------------------------- UI glue
; SELECT+A
DoSave:
    call SaveAll
    ld a, MSG_SAVED
    jr nc, SetMsg
    ld a, MSG_FAIL
    jr SetMsg

; SELECT+B
DoLoad:
    call LoadAll
    ld a, MSG_NODATA
    jr c, SetMsg
    ; everything on screen is stale now
    ld a, DIRTY_ALL | DIRTY_HEADER
    ld [wDirty], a
    ld a, $FF
    ld [wDirtyEdit], a
    ld [wDirtySeq], a
    ld [wDirtySeq + 1], a
    ld a, MSG_LOADED
    ; fall through

; a = message code. Shown on row 17 for MSG_FRAMES frames.
SetMsg:
    ld [wMsg], a
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
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_MSG
    ld [hl], a
    ret
