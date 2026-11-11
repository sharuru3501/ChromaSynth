; The segment pool for the patterns (docs/M19_PATTERN_POOL.md).
;
; A pattern has NUM_SEGS halves (segments) of 4 bars. Each half that holds something is lent a segment from the pool
; (wPatSeg); a half that holds nothing is not lent one and reads as empty from ZERO_SEG. A segment is 4 pages (one per channel)
; of 192 cells, one byte per tick (0 = empty, CELL_OFF, or a note), in WRAM bank 1 + id / 4.
;
; Whoever reads cells calls SegLoc (it sets SVBK); whoever writes them calls EnsureSeg first (AbsHLW does), after PoolReserve
; said there is room. After the edit PoolRecalc counts the coded size again and gives back segments that became empty.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"



SECTION "Pool", ROMX, BANK[1]

; a = segment id -> SVBK = its bank, h = the page of its channel 0, l = 0. Clobbers a.
SegAddr:
    ld l, a
    srl a
    srl a
    inc a                   ; bank 1 + id / 4
    ld [$FF70], a
    ld a, l
    and 3
    add a
    add a                   ; 4 pages a segment
    add $D0
    ld h, a
    ld l, 0
    ret

; a = pattern (0-based), b = segment (0 / 1) -> a = the page of channel 0 of that segment, SVBK = its bank.
; A half that is not lent is ZERO_SEG. Keeps bc, de. Clobbers hl.
SegLoc:
    add a
    add b
    add LOW(wPatSeg)        ; wPatSeg is 32 bytes at a 32-byte boundary: no carry
    ld l, a
    ld h, HIGH(wPatSeg)
    ld a, [hl]
    cp NO_SEG
    jr nz, .have
    ld a, ZERO_SEG
.have:
    call SegAddr
    ld a, h
    ret

; a = segment (0 / 1) -> a = the page of the SELECTED channel in that segment of the EDITED pattern, SVBK set.
; Keeps bc, de. Clobbers hl.
EdSegPage:
    push bc
    ld b, a
    ld a, [wEditPat]
    call SegLoc
    ld b, a
    ld a, [wSelCh]
    add b
    pop bc
    ret

; a = pattern, b = segment: make sure the half is lent a segment (zeroed). -> carry set: none was free.
; Clobbers a, bc, de, hl.
EnsureSeg:
    add a
    add b
    add LOW(wPatSeg)
    ld l, a
    ld h, HIGH(wPatSeg)
    ld a, [hl]
    inc a
    jr z, .lend
    and a                   ; lent already: carry clear
    ret
.lend:
    push hl                 ; the table entry to fill
    ld c, 0                 ; c = the id to try
.try:
    ld hl, wPatSeg
    ld b, NUM_PATS * NUM_SEGS
.used:
    ld a, [hl+]
    cp c
    jr z, .taken
    dec b
    jr nz, .used
    jr .free
.taken:
    inc c
    ld a, c
    cp POOL_SEGS
    jr c, .try
    pop hl
    scf                     ; all lent
    ret
.free:
    pop hl
    ld [hl], c
    ld a, c
    call SegAddr            ; hl = the segment
    ld bc, SEG_PAGES * 256
    call MemClear
    and a
    ret

; a = segment id -> de = its coded size. Per channel: 1 byte when empty, else 193 bytes (RAW: all 192 cells) when it holds RAW_MIN cells or
; more, else 25 + the cells (a bitmap of the 192 ticks, then the cells). The coder in sram.asm must agree. Clobbers a, bc, hl; SVBK changes.
EncodedSegSize:
    call SegAddr
    ld de, 0
    ld a, NUM_CH
    ld [wPoolTmp], a
.ch:
    ld l, 0
    ld b, 0                 ; b = cells that are used
    ld c, SEQ_TICKS
.cell:
    ld a, [hl+]
    and a
    jr z, .empty
    inc b
.empty:
    dec c
    jr nz, .cell
    ld a, b
    and a
    jr nz, .some
    inc de                  ; an empty channel: 1 byte
    jr .next
.some:
    cp RAW_MIN
    jr c, .bitmap
    ld a, e
    add 193
    ld e, a
    jr nc, .next
    inc d
    jr .next
.bitmap:
    add 25
    add e
    ld e, a
    jr nc, .next
    inc d
.next:
    inc h                   ; the next channel's page (l = SEQ_TICKS here, the page is the same until this step)
    ld a, [wPoolTmp]
    dec a
    ld [wPoolTmp], a
    jr nz, .ch
    ret

; a = pattern: count the coded size of its segments again, give back the ones that are empty, and add the sizes up. Clobbers all.
PoolRecalc:
    ld [wPoolTmp + 1], a
    xor a
    ld [wPoolTmp + 2], a    ; the segment
.seg:
    ld a, [wPoolTmp + 1]
    add a
    ld hl, wPoolTmp + 2
    add [hl]
    add LOW(wPatSeg)
    ld l, a
    ld h, HIGH(wPatSeg)
    ld a, [hl]
    cp NO_SEG
    jr z, .next
    push hl
    ld [wPoolTmp + 3], a    ; the id
    call EncodedSegSize     ; de = size
    ld a, [wPoolTmp + 3]
    add a
    ld c, a
    ld b, 0
    ld hl, wSegSize
    add hl, bc
    ld a, d
    or a
    jr nz, .keep
    ld a, e
    cp 4                    ; 4 empty channels: nothing in it any more
    jr nz, .keep
    xor a
    ld [hl+], a
    ld [hl], a              ; size 0
    pop hl
    ld [hl], NO_SEG         ; give the segment back
    jr .next
.keep:
    ld a, e
    ld [hl+], a
    ld [hl], d
    pop hl
.next:
    ld hl, wPoolTmp + 2
    inc [hl]
    ld a, [hl]
    cp NUM_SEGS
    jr c, .seg
    ; fall through
; wPoolBytes = the sum of wSegSize
PoolSum:
    ld hl, wSegSize
    ld de, 0
    ld b, POOL_SEGS
.add:
    ld a, [hl+]
    add e
    ld e, a
    ld a, [hl+]
    adc d
    ld d, a
    dec b
    jr nz, .add
    ld a, e
    ld [wPoolBytes], a
    ld a, d
    ld [wPoolBytes + 1], a
    ld c, 0                 ; the percentage: bytes / (POOL_BYTES / 100), at most 100
.pct:
    ld a, d
    and a
    jr nz, .sub
    ld a, e
    cp POOL_BYTES / 100
    jr c, .pctDone
.sub:
    ld a, e
    sub POOL_BYTES / 100
    ld e, a
    jr nc, .nb
    dec d
.nb:
    inc c
    ld a, c
    cp 100
    jr c, .pct
.pctDone:
    ld a, c
    ld [wPoolPct], a
    ret

; Boot / before a load: no pattern holds a segment, the sizes are 0, ZERO_SEG is zeros. Clobbers all.
PoolInit:
    ld hl, wPatSeg
    ld b, NUM_PATS * NUM_SEGS
    ld a, NO_SEG
.table:
    ld [hl+], a
    dec b
    jr nz, .table
    ld hl, wSegSize
    ld bc, POOL_SEGS * 2 + 2
    call MemClear           ; (the sizes and wPoolBytes follow each other)
    ld a, ZERO_SEG
    call SegAddr
    ld bc, SEG_PAGES * 256
    jp MemClear

; Count every pattern again (after a load or the boot).
PoolRecalcAll:
    xor a
.p:
    push af
    call PoolRecalc
    pop af
    inc a
    cp NUM_PATS
    jr c, .p
    ret

; Is there room for one more edit that may grow things (a note, a longer note)? An edit lends at most two segments and grows the coded
; size by less than POOL_MARGIN. -> carry set: no (the caller shows MSG_FULL and does nothing). Clobbers a, bc, de, hl.
PoolReserve:
    ld hl, wPatSeg
    ld b, NUM_PATS * NUM_SEGS
    ld c, 0                 ; c = segments lent
.count:
    ld a, [hl+]
    cp NO_SEG
    jr z, .free
    inc c
.free:
    dec b
    jr nz, .count
    ld a, c
    cp POOL_SEGS - 1        ; room for two more?
    jr nc, .full
    ld a, [wPoolBytes]
    ld l, a
    ld a, [wPoolBytes + 1]
    ld h, a
    ld de, POOL_MARGIN
    add hl, de
    ld a, h
    cp HIGH(POOL_BYTES + 1)
    jr c, .ok
    jr nz, .full
    ld a, l
    cp LOW(POOL_BYTES + 1)
    jr nc, .full
.ok:
    and a
    ret
.full:
    scf
    ret

; de = a tick counted from the start of the pattern -> hl = its cell in the SELECTED channel of the EDITED pattern, SVBK set; the half
; is lent a segment first. If none is free hl is wDummyCell (a write there changes nothing). Keeps de. Clobbers a, bc.
AbsHLW:
    push de
    ld b, 0
    ld a, d
    and a
    jr nz, .second
    ld a, e
    cp SEQ_TICKS
    jr c, .go
.second:
    ld b, 1
.go:
    ld a, [wEditPat]
    call EnsureSeg
    pop de
    jp nc, AbsHL
    ld hl, wDummyCell
    ret
