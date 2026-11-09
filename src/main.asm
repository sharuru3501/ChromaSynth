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
    ld a, 1                 ; owe the ESP32 one end beacon ($F5) at boot: if it was still linked to an
    ld [wClBeacon], a       ; earlier run (the power was cut on the keyboard screen), it must stop now
    ld a, 60
    ld [wJoyNote], a
    ld hl, DefaultPatch
    ld de, wPatch
    ld bc, NUM_PATCHES * PATCH_SIZE
    call MemCopy
    ld a, 1                 ; every pattern bank starts empty ...
.clearBank:
    push af
    ld [$FF70], a           ; SVBK
    ld hl, wPatterns
    ld bc, NUM_CH * SEQ_STRIDE
    call MemClear
    pop af
    inc a
    cp NUM_PATS + 1
    jr nz, .clearBank
    ld a, 1                 ; ... except pattern 1: the demo
    ld [$FF70], a
    ld hl, DefaultPattern
    ld de, wPatterns
    ld b, NUM_CH
.demoCh:
    push bc
    ld bc, 256
    call MemCopy            ; (a channel's first 256 ticks; its second page stays empty)
    inc d                   ; de -> the next channel's first page
    pop bc
    dec b
    jr nz, .demoCh
    ld a, 1
    ld [wEditBank], a
    ld [wPlayBank], a
    call ChainReset
    ld a, 120
    ld [wBpm], a
    ld a, 2                 ; the demo is two bars long
    ld [wSeqBars], a
    ld a, DEFAULT_DIV       ; piano-roll grid: 1/16
    call SetDivision
    ld a, 127
    ld [wNoteVel], a       ; full velocity unless a MIDI note says otherwise
    ld a, 64               ; pitch bend wheel in the middle
    ld [wBend], a
    ld [wBend + 1], a
    ld [wBend + 2], a
    ld [wBend + 3], a
    ld a, 60                ; piano-roll cursor starts on C4; window top = C5
    ld [wRollNote], a
    ld a, 72
    ld [wRollTop], a
    xor a
    ld [wSlot], a
    ld [wConfirm], a
    call ScanSlots
    call LoadAll            ; restore slot 1 if it holds a save (else keep defaults)

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
    ld a, MIDI_IDLE
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
    di                      ; take the frame count atomically (the ISR counts VBlanks)
    ld a, [wVBlank]
    ld b, a
    xor a
    ld [wVBlank], a
    ei
    ld a, b
    and a
    jr nz, .frame
    call DrainMidi          ; woken by something else (the link): just the MIDI bytes
    jr MainLoop
.frame:
    cp 5
    jr c, .framesOk
    ld a, 4                 ; (a long stall: the sequencer catches up at most 4 frames at once)
.framesOk:
    ld [wFrames], a
    call CLinkUp            ; palette RAM is only writable now, so before anything else
    call UpdateUI           ; VRAM is only writable now, so do this first
    call DrainMidi
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
    call CLinkRx
    call HandleJoy
    call RenderPending      ; piano roll rows are rendered outside VBlank
    jr MainLoop

; ---------------------------------------------------------------- ISRs
VBlankISR:
    push af
    ld a, [wVBlank]
    inc a
    jr nz, .count
    dec a                   ; (cap at 255)
.count:
    ld [wVBlank], a
    pop af
    reti

; Serial transfer complete (the bridge clocked one byte through us).
;   in : SB = the byte that arrived; MIDI_IDLE means "nothing to say" and is dropped
;   out: SB = next byte for the bridge (from wTx, else MIDI_IDLE), SC re-armed so
;        that we are ready for the next byte. The bridge must wait >= ~200 us between
;        bytes: this routine takes about 100 cycles (~100 us) and the next byte must
;        not start before SB/SC are ready.
SerialISR:
    push af
    push bc
    push hl
    ldh a, [rSB]
    cp MIDI_IDLE
    jr z, .reply
    ld b, a
    ld a, [wRingHead]
    ld l, a
    ld h, HIGH(wRing)
    ld [hl], b
    inc l                   ; 256-byte aligned ring: wraps naturally
    ld a, l
    ld [wRingHead], a
.reply:
    ld a, [wClLinked]
    and a
    ld b, MIDI_IDLE
    jr nz, .send            ; the Chromatic link owns the queue (src/clink.asm)
    ld a, [wTxHead]
    ld b, a
    ld a, [wTxTail]
    cp b
    ld b, MIDI_IDLE
    jr z, .send             ; queue empty
    ld l, a
    ld h, HIGH(wTx)
    ld b, [hl]
    inc a
    ld [wTxTail], a
.send:
    ld a, b
    ldh [rSB], a
    ld a, $80
    ldh [rSC], a
    pop hl
    pop bc
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
