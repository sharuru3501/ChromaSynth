; The page pool for the patterns (docs/M19_PATTERN_POOL.md, docs/M20_PER_CHANNEL_CHAINS.md).
;
; A pattern has NUM_CH channels of NUM_SEGS halves (4 bars each). Each channel half that holds something is lent a page from the pool
; (wPatPage); one that holds nothing is not lent a page and reads as empty from ZERO_PAGE. A page is the 192 cells of 4 bars of a channel,
; one byte a tick (0 = empty, CELL_OFF, or a note), in the 256 bytes of a WRAM page: WRAM bank 1 + id / 16, page $D0 + id mod 16.
;
; Whoever reads cells calls PageLoc (it sets SVBK); whoever writes them calls EnsurePage first (AbsHLW does), after PoolReserve said
; there is room. After the edit PoolRecalc counts the coded size again and gives back pages that became empty.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "Pool", ROMX, BANK[1]

; a = page id -> SVBK = its bank, h = its page, l = 0. Clobbers a.
PageAddr:
    ld l, a
    swap a
    and $0F
    inc a                   ; bank 1 + id / 16
    ld [$FF70], a
    ld a, l
    and $0F
    add $D0
    ld h, a
    ld l, 0
    ret

; a = pattern (0-based), b = channel, c = half (0 / 1) -> hl = its entry in wPatPage. Clobbers a.
PageEntry:
    add a
    add a
    add a                   ; pattern * 8
    ld l, a
    ld a, b
    add a
    add c
    add l
    add LOW(wPatPage)       ; wPatPage is 128 bytes at a 128-byte boundary: no carry
    ld l, a
    ld h, HIGH(wPatPage)
    ret

; a = pattern, b = channel, c = half -> a = the page (high byte) of that channel half, SVBK = its bank. Not lent: ZERO_PAGE.
; Keeps bc, de. Clobbers hl.
PageLoc:
    call PageEntry
    ld a, [hl]
    cp NO_PAGE
    jr nz, .have
    ld a, ZERO_PAGE
.have:
    call PageAddr
    ld a, h
    ret

; a = half (0 / 1) -> a = the page of the SELECTED channel in that half of the EDITED pattern, SVBK set. Keeps bc, de. Clobbers hl.
EdSegPage:
    push bc
    ld c, a
    ld a, [wSelCh]
    ld b, a
    ld a, [wEditPat]
    call PageLoc
    pop bc
    ret

; -> a = a free page id (marked as lent in wPageMap), carry set if there is none. Clobbers bc, d, hl.
FindFreePage:
    ld hl, wPageMap
    ld c, 0                 ; c = the id of bit 0 of this byte
    ld b, POOL_MAP
.byte:
    ld a, [hl]
    cp $FF
    jr nz, .found
    inc hl
    ld a, c
    add 8
    ld c, a
    dec b
    jr nz, .byte
    scf
    ret
.found:
    ld d, a
    ld b, 1
.bit:
    ld a, d
    and b
    jr z, .take
    sla b
    inc c
    jr .bit
.take:
    ld a, [hl]
    or b
    ld [hl], a              ; lent
    ld a, c
    and a
    ret

; a = page id: give it back (clears its bit in wPageMap). Clobbers a, bc, hl.
FreePageId:
    ld c, a
    srl a
    srl a
    srl a
    ld hl, wPageMap
    add l
    ld l, a
    jr nc, .nc
    inc h
.nc:
    ld a, c
    and 7
    ld b, a
    ld a, $FE               ; the mask without the bit, rotated into place
    inc b
.rot:
    dec b
    jr z, .rotted
    rlca
    jr .rot
.rotted:
    and [hl]
    ld [hl], a
    ret

; a = pattern, b = channel, c = half: make sure that channel half is lent a page (zeroed). -> carry set: none was free.
; Clobbers a, bc, de, hl.
EnsurePage:
    call PageEntry
    ld a, [hl]
    inc a
    jr z, .lend
    and a                   ; lent already: carry clear
    ret
.lend:
    push hl                 ; the table entry to fill
    call FindFreePage
    jr c, .none
    pop hl
    ld [hl], a
    call PageAddr           ; hl = the page
    ld bc, 256
    call MemClear
    and a
    ret
.none:
    pop hl
    scf
    ret

; a = page id -> a = its coded size: 1 byte when empty, 193 (RAW) when it holds RAW_MIN cells or more, else 25 + the cells (a bitmap of
; the 192 ticks, then the cells). The coder in sram.asm must agree. Clobbers bc, hl; SVBK changes.
EncodedPageSize:
    call PageAddr
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
    inc a                   ; an empty channel: 1 byte
    ret
.some:
    cp RAW_MIN
    jr c, .bitmap
    ld a, 193
    ret
.bitmap:
    add 25
    ret

; a = pattern: count the coded size of its pages again and give back the ones that are empty; then add all sizes up. Clobbers all.
PoolRecalc:
    add a
    add a
    add a                   ; the first entry: pattern * 8
    add LOW(wPatPage)
    ld l, a
    ld h, HIGH(wPatPage)
    ld a, PAT_PAGES
    ld [wPoolTmp + 1], a
.entry:
    ld a, [hl]
    cp NO_PAGE
    jr z, .next
    push hl
    ld [wPoolTmp + 2], a    ; the id
    call EncodedPageSize
    ld [wPoolTmp + 3], a    ; its size
    ld a, [wPoolTmp + 2]
    ld c, a
    ld b, 0
    ld hl, wPageSize
    add hl, bc
    ld a, [wPoolTmp + 3]
    cp 1
    jr z, .giveBack
    ld [hl], a              ; the size stays
    pop hl
    jr .next
.giveBack:
    xor a
    ld [hl], a              ; size 0
    ld a, [wPoolTmp + 2]
    call FreePageId
    pop hl
    ld [hl], NO_PAGE
.next:
    inc hl
    ld a, [wPoolTmp + 1]
    dec a
    ld [wPoolTmp + 1], a
    jr nz, .entry
    ; fall through
; wPoolBytes = the sum of wPageSize, wPoolPct = its share of POOL_BYTES
PoolSum:
    ld hl, wPageSize
    ld de, 0
    ld b, POOL_PAGES
.add:
    ld a, [hl+]
    add e
    ld e, a
    jr nc, .nc
    inc d
.nc:
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

; Boot / before a load: no pattern holds a page, the sizes are 0, ZERO_PAGE is zeros and marked as lent. Clobbers all.
PoolInit:
    ld hl, wPatPage
    ld b, NUM_PATS * PAT_PAGES
    ld a, NO_PAGE
.table:
    ld [hl+], a
    dec b
    jr nz, .table
    ld hl, wPageSize
    ld bc, POOL_PAGES + 3
    call MemClear           ; (the sizes, wPoolBytes and wPoolPct follow each other)
    ld hl, wPageMap
    ld bc, POOL_MAP
    call MemClear
    ld a, ZERO_PAGE
    ld c, a
    srl a
    srl a
    srl a
    ld hl, wPageMap
    add l
    ld l, a
    jr nc, .nc2
    inc h
.nc2:
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
    ld [hl], a              ; the zero page is lent for good
    ld a, ZERO_PAGE
    call PageAddr
    ld bc, 256
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

; Is there room for one more edit that may grow things (a note, a longer note)? An edit lends at most two pages and grows the coded
; size by less than POOL_MARGIN. -> carry set: no (the caller shows MSG_FULL and does nothing). Clobbers a, bc, de, hl.
PoolReserve:
    ld hl, wPatPage
    ld b, NUM_PATS * PAT_PAGES
    ld c, 0                 ; c = pages lent
.count:
    ld a, [hl+]
    cp NO_PAGE
    jr z, .free
    inc c
.free:
    dec b
    jr nz, .count
    ld a, c
    cp POOL_PAGES - 1       ; room for two more?
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

; de = a tick counted from the start of the pattern -> hl = its cell in the SELECTED channel of the EDITED pattern, SVBK set; the channel
; half is lent a page first. If none is free hl is wDummyCell (a write there changes nothing). Keeps de. Clobbers a, bc.
AbsHLW:
    push de
    ld c, 0
    ld a, d
    and a
    jr nz, .second
    ld a, e
    cp SEQ_TICKS
    jr c, .go
.second:
    ld c, 1
.go:
    ld a, [wSelCh]
    ld b, a
    ld a, [wEditPat]
    call EnsurePage
    pop de
    jp nc, AbsHL
    ld hl, wDummyCell
    ret
