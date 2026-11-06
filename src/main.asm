; ChromaSynth -- Game Boy / Chromatic synthesizer ROM
; Entry point, interrupt vectors, init and main loop.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

; ---------------------------------------------------------------- vectors
SECTION "VBlank vector", ROM0[$40]
    jp VBlankISR

SECTION "Serial vector", ROM0[$58]
    jp SerialISR

SECTION "Header", ROM0[$100]
    nop
    jp EntryPoint
    ds $150 - @, 0          ; rgbfix fills in the header

; ---------------------------------------------------------------- code
SECTION "Main", ROM0[$150]

EntryPoint:
    di
    ld sp, $FFFE

    ; --- clear RAM state and set defaults
    ld hl, wRingHead
    ld bc, wClearEnd - wRingHead + 1
    call MemClear
    ld a, 60
    ld [wJoyNote], a
    ld hl, DefaultPatch
    ld de, wPatch
    ld bc, NUM_CH * PATCH_SIZE
    call MemCopy
    ld hl, DefaultPattern
    ld de, wPattern
    ld bc, NUM_CH * SEQ_STRIDE
    call MemCopy
    ld a, 120
    ld [wBpm], a
    ld a, 2 * TICKS_PER_BAR ; the demo is two bars long
    ld [wSeqLen], a
    ld a, DEFAULT_DIV       ; piano-roll grid: 1/16
    ld [wDiv], a
    ld a, [DivTicks + DEFAULT_DIV]
    ld [wDivTicks], a
    ld a, 60                ; piano-roll cursor starts on C4; window top = C5
    ld [wRollNote], a
    ld a, 72
    ld [wRollTop], a
    call LoadAll            ; restore the last save if there is one (else keep defaults)

    ; --- LCD off (only legal during VBlank), build the screen
.waitVBlank:
    ldh a, [rLY]
    cp 144
    jr c, .waitVBlank
    xor a
    ldh [rLCDC], a
    call InitUI
    ld a, %11100100
    ldh [rBGP], a           ; DMG palette
    call InitPalette        ; CGB palette (the CGB boots with white palette RAM)
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_BLK01 | LCDCF_OBJON
    ldh [rLCDC], a

    ; --- APU on, all channels to both speakers, max master volume
    ld a, $80
    ldh [rNR52], a
    ld a, $FF
    ldh [rNR51], a
    ld a, $77
    ldh [rNR50], a

    ; --- link port as MIDI input: external clock (we are the slave)
    xor a
    ldh [rSB], a
    ld a, $80
    ldh [rSC], a

    xor a
    ldh [rIF], a
    ld a, IEF_VBLANK | IEF_SERIAL
    ldh [rIE], a
    ei

    ; boot beep (C5 on CH1, ~0.5 s): proves audio works independent of input
    ld a, 30
    ld [wBootTimer], a
    ld c, 0
    ld a, 72
    call NoteOn

MainLoop:
    halt
    nop
    call DrainMidi
    ld a, [wVBlank]
    and a
    jr z, MainLoop
    xor a
    ld [wVBlank], a
    call UpdateUI           ; VRAM is only writable now, so do this first
    call VoiceTick
    call SeqTick
    call RollPlayheadCalc
    call MsgTick
    ld a, [wBootTimer]
    and a
    jr z, .noBoot
    dec a
    ld [wBootTimer], a
    ld c, 0
    call z, NoteOff
.noBoot:
    call ReadJoy
    call HandleJoy
    call RenderPending      ; piano roll rows are rendered outside VBlank
    jr MainLoop

; ---------------------------------------------------------------- ISRs
VBlankISR:
    push af
    ld a, 1
    ld [wVBlank], a
    pop af
    reti

; Serial transfer complete: push received byte into the ring, re-arm.
SerialISR:
    push af
    push hl
    ld a, [wRingHead]
    ld l, a
    ld h, HIGH(wRing)
    ldh a, [rSB]
    ld [hl], a
    inc l                   ; 256-byte aligned ring: wraps naturally
    ld a, l
    ld [wRingHead], a
    xor a
    ldh [rSB], a            ; byte returned to the master (MIDI out later)
    ld a, $80
    ldh [rSC], a
    pop hl
    pop af
    reti

; ---------------------------------------------------------------- utils
; CGB palettes (the CGB boots with white palette RAM). Harmless on DMG (the
; registers are ignored; BGP/OBP0 are set separately). LCD must be off.
;   BG  0: white, pale blue, mid blue, navy (grid, notes and text)
;   OBJ 0: transparent, red, red, red (playhead line)
InitPalette:
    ld a, %11111100         ; DMG: sprite colours 1-3 = black, so the playhead shows
    ldh [rOBP0], a
    ld a, $80               ; index 0, auto-increment
    ldh [rBCPS], a
    ld hl, BGPalette
    ld b, 8
.bg:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .bg
    ld a, $80
    ldh [rOCPS], a
    ld hl, OBJPalette
    ld b, 8
.obj:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .obj
    ret

BGPalette:
    dw $7FFF, $7B79, $620C, $2062   ; RGB555
OBJPalette:
    dw $7FFF, $18DF, $18DF, $18DF

; hl = dest, bc = length (>0)
MemClear:
    xor a
.l: ld [hl+], a
    dec bc
    ld a, b
    or c
    ld a, 0
    jr nz, .l
    ret

; hl = src, de = dest, bc = length (>0)
MemCopy:
.l: ld a, [hl+]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .l
    ret

; hl += c   (clobbers a)
HLplusC:
    ld a, l
    add c
    ld l, a
    ret nc
    inc h
    ret
