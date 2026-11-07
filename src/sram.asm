; Save/load patches, pattern and BPM to cartridge SRAM (MBC5, 128 KB on the Smart Card).
;
; The SRAM is shared with every ROM on the card (LSDj uses it from the bottom), so ChromaSynth
; only touches the LAST 8 KB bank (SLOT_BANK) as NUM_SLOTS slots of SLOT_SIZE bytes:
;   slot n at $A000 + n * SLOT_SIZE in bank SLOT_BANK
;   +0    "CSYN"   magic
;   +4    version  (SAVE_VERSION)
;   +5    wPatch   (NUM_PATCHES * PATCH_SIZE = 160 bytes: 4 channels + the MIDI settings block)
;   +165  wPattern (NUM_CH x SEQ_TICKS bytes: only the 192 used ticks of each channel)
;   +933  wBpm
;   +934  wSeqLen  (ticks)
;   +935  checksum = (sum of the data bytes) xor $A5
; A slot is written only if it already holds a ChromaSynth save or is completely $00 / $FF;
; anything else (LSDj data that grew into this bank) is never overwritten (MSG_INUSE).
; Bump SAVE_VERSION whenever the layout changes, so old saves are ignored.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

DEF SAVE_VERSION  EQU 7
DEF SAVE_DATA_LEN EQU NUM_PATCHES * PATCH_SIZE + NUM_CH * SEQ_TICKS + 2

SECTION "SRAM", ROM0

SaveMagic:  db "CSYN", SAVE_VERSION

SramOpen:
    ld a, CART_SRAM_ENABLE
    ld [rRAMG], a
    ld a, SLOT_BANK
    ld [rRAMB], a
    ret

SramClose:
    xor a
    ld [rRAMB], a
    ld [rRAMG], a           ; disabling protects the save from stray writes
    ret

; -> hl = start of the selected slot (SRAM must be open). Clobbers a.
SlotBase:
    ld a, [wSlot]
    add a
    add a                   ; * SLOT_SIZE / 256
    add HIGH(_SRAM)
    ld h, a
    ld l, 0
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
    cp NUM_SLOTS - 1
    ret nc
    inc a
.set:
    ld [wSlot], a
    xor a
    ld [wConfirm], a
    ld hl, wDirty
    ld a, [hl]
    or DIRTY_STATUS
    ld [hl], a
    ret

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
    call SramOpen
    call SlotBase
    call SlotWritable       ; (clobbers de)
    jr c, .inUse
    call SlotBase
    ld d, h
    ld e, l                 ; de = destination
    xor a
    ld [wSaveSum], a
    ld hl, SaveMagic
    ld bc, 5
    call CopyBytes
    ld hl, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call CopySum
    ld a, HIGH(wPattern)
.pat:
    push af
    ld h, a
    ld l, 0
    ld bc, SEQ_TICKS
    call CopySum
    pop af
    inc a
    cp HIGH(wPattern) + NUM_CH
    jr nz, .pat
    ld hl, wBpm
    ld bc, 1
    call CopySum
    ld hl, wSeqLen
    ld bc, 1
    call CopySum
    ld a, [wSaveSum]
    xor $A5
    ld [de], a
    call SlotBase
    call ValidateSave
    jr c, .fail
    call SlotMask
    ld hl, wSlotUsed
    or [hl]
    ld [hl], a
    call SramClose
    ld a, MSG_SAVED
    ret
.fail:
    call SramClose
    ld a, MSG_FAIL
    ret
.inUse:
    call SramClose
    ld a, MSG_INUSE
    ret

; Restore the state from the selected slot. -> carry set if it holds no valid save.
LoadAll:
    call SramOpen
    call SlotBase
    call ValidateSave       ; -> hl = start of the data
    jr c, .bad
    ld de, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call CopyBytes
    ld a, HIGH(wPattern)
.pat:
    push af
    ld d, a
    ld e, 0
    ld bc, SEQ_TICKS
    call CopyBytes
    pop af
    inc a
    cp HIGH(wPattern) + NUM_CH
    jr nz, .pat
    ld de, wBpm
    ld bc, 1
    call CopyBytes
    ld de, wSeqLen
    ld bc, 1
    call CopyBytes
    call SramClose
    and a                   ; clear carry
    ret
.bad:
    call SramClose
    scf
    ret

; Fill wSlotUsed: which slots hold a valid save. Keeps wSlot.
ScanSlots:
    call SramOpen
    xor a
    ld [wSlotUsed], a
    ld a, [wSlot]
    push af
    xor a
.next:
    ld [wSlot], a
    call SlotBase
    call ValidateSave
    jr c, .empty
    call SlotMask
    ld hl, wSlotUsed
    or [hl]
    ld [hl], a
.empty:
    ld a, [wSlot]
    inc a
    cp NUM_SLOTS
    jr c, .next
    pop af
    ld [wSlot], a
    jp SramClose

; hl = slot start, SRAM open. -> carry set if magic/version/checksum is wrong.
; On success hl = address of the first data byte.
ValidateSave:
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
    ld de, 0                ; d = running sum (e unused)
    ld bc, SAVE_DATA_LEN
.sum:
    ld a, [hl+]
    add d
    ld d, a
    dec bc
    ld a, b
    or c
    jr nz, .sum
    ld a, [hl]              ; stored checksum
    xor $A5
    cp d
    pop hl
    jr nz, .bad
    and a                   ; clear carry
    ret
.bad:
    scf
    ret

; ---------------------------------------------------------------- UI glue
; SELECT+A. A used slot asks for a second SELECT+A before it is overwritten.
DoSave:
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
    ret

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
    call RollRefreshAll     ; piano roll: rebuild columns and redraw every row
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
