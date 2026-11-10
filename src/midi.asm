; MIDI byte stream parser (note on/off, CC, running status) and voice routing.
;
; Routing: each GB channel listens to one MIDI channel (patch byte MIDI_BLOCK +
; channel, 1-16, 0 = off; set on the 5th page of the edit screen). By default CH1-CH4
; listen to MIDI channels 1-4. Several GB channels set to the SAME MIDI channel
; play polyphonically: a new note goes to the channel that already plays that note,
; else to an idle one, else it steals one in round-robin order.
;
; Handled messages: note on/off (velocity 0 = off), CC1 (mod wheel -> vibrato
; depth), CC120/CC123 (all sound/notes off), pitch bend (MSB only; range = the BEND
; setting in semitones). Realtime messages (clock/start/continue/stop) drive the
; sequencer in SYNC_IN mode. Output towards the bridge: MidiOut and friends.
INCLUDE "hardware.inc"
INCLUDE "synth.inc"

SECTION "MIDI", ROM0

DrainMidi:
    ld a, [wRingTail]
    ld c, a
.loop:
    ld a, [wRingHead]
    cp c
    jr z, .done
    ld h, HIGH(wRing)
    ld l, c
    ld b, [hl]
    inc c
    ld a, b
    ld [wLastRx], a
    ld a, [wDirty]
    or DIRTY_STATUS
    ld [wDirty], a
    push bc
    call MidiByte
    pop bc
    jr .loop
.done:
    ld a, c
    ld [wRingTail], a
    ret

; b = received byte
MidiByte:
    bit 7, b
    jr z, .data
    ld a, b
    cp $F8
    jr nc, MidiRealtime     ; realtime messages never disturb running status
    ld [wMidiStatus], a
    xor a
    ld [wMidiCount], a
    ret
.data:
    ld a, [wMidiStatus]
    and a
    ret z
    and $F0
    cp $C0
    jr z, .programChange    ; program change: the pattern (SYNC_FOLLOW only)
    cp $D0
    ret z                   ; channel pressure: 1 data byte, ignored
    ld a, [wMidiCount]
    and a
    jr nz, .second
    ld a, b
    ld [wMidiData1], a
    ld a, 1
    ld [wMidiCount], a
    ret
.second:
    xor a
    ld [wMidiCount], a      ; keep running status
    ld a, [wMidiStatus]
    ld c, a
    and $0F
    inc a
    ld [wMidiChNum], a      ; MIDI channel 1-16 of this message
    ld a, c
    and $F0
    cp $90
    jr z, .noteOn
    cp $80
    jp z, MidiNoteOff
    cp $B0
    jp z, MidiCC
    cp $E0
    jp z, MidiBend
    ret                     ; (aftertouch etc.: not handled)
.noteOn:
    ld a, b                 ; velocity
    and a
    jp z, MidiNoteOff       ; velocity 0 == note off
    ld [wMidiVel], a
    jp MidiNoteOn

.programChange:
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_FOLLOW
    ret nz
    ld a, b
    cp NUM_PATS
    ret nc
    jp SongSetEdit          ; the pattern is edited; while playing it takes over at the next bar line

; Realtime message in a (>= $F8). The bridge sends one $F8 per sequencer tick (12 per
; beat) and $FA/$FB/$FC for start/continue/stop. Only acted on in SYNC_IN mode.
MidiRealtime:
    ld c, a
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_FOLLOW
    jr z, .follow
    cp SYNC_IN
    ret nz
    ld a, c
    cp $F8
    jr z, .clock
    cp $FA
    jr z, .start
    cp $FB
    jr z, .continue
    cp $FC
    ret nz
    xor a                   ; stop
    ld [wSeqPlay], a
    ld [wExtTicks], a
    call SeqSilence
    call SongMarkPos
    jp MarkSeqStatus
.clock:
    ld a, [wSeqPlay]
    and a
    ret z                   ; not running: ticks mean nothing
    ld a, [wExtTicks]
    cp 4
    ret nc                  ; a burst larger than the frame loop can absorb: drop
    inc a
    ld [wExtTicks], a
    ret
.start:
    xor a
    ld [wSeqTick], a        ; start from the beginning; the next clock plays tick 0
    ld [wSeqSeg], a
    ld [wBarPos], a
    dec a
    ld [wBarIdx], a
    xor a
    ld [wExtTicks], a
    call SongRestart
.continue:
    ld a, 1
    ld [wSeqPlay], a
    ld [wFollow], a
    xor a
    ld [wExtTicks], a
    jp MarkSeqStatus

.follow:                    ; start / stop of the DAW; the clock itself never comes (the link is too slow): the ROM keeps its own
    ld a, c
    cp $FA
    jr z, .followStart
    cp $FB
    jr z, .followContinue
    cp $FC
    ret nz
    ld a, [wSeqPlay]
    and a
    ret z
    jp SeqToggle            ; stop
.followStart:
    ld a, [wSeqPlay]
    and a
    call nz, SeqToggle      ; (already running: stop first, then start again from the top)
    jp SeqToggle
.followContinue:
    ld a, [wSeqPlay]
    and a
    ret nz
    jp SeqToggle

; a = byte -> queue it for the bridge (dropped when the queue is full, e.g. nobody
; is clocking the link). Clobbers a, b, hl.
MidiOut:
    ld b, a
    ld a, [wTxHead]
    inc a
    ld hl, wTxTail
    cp [hl]
    ret z                   ; full
    dec a
    ld l, a
    ld h, HIGH(wTx)
    ld [hl], b
    inc a
    ld [wTxHead], a
    ret

; Same, but only when this unit is the sync master (SYNC_OUT).
MidiOutSync:
    ld c, a
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_OUT
    ret nz
    ld a, c
    jr MidiOut

; The sequencer starts note d on GB channel c: send it (and the note-off of whatever
; that channel was playing). Only in SYNC_OUT mode, only if the channel has a MIDI
; channel. Keeps c and d. Clobbers a, b, e, hl.
NoteOutOn:
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_OUT
    ret nz
    ld hl, wPatch + MIDI_BLOCK
    call HLplusC
    ld a, [hl]
    and a
    ret z
    dec a
    ld e, a                 ; e = MIDI channel 0..15
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    and a
    jr z, .on
    ld a, $80
    or e
    call MidiOut
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    call MidiOut
    xor a
    call MidiOut
.on:
    ld a, $90
    or e
    call MidiOut
    ld a, d
    call MidiOut
    ld a, 100
    jp MidiOut

; The sequencer releases GB channel c: send the note-off of what it is playing.
; Keeps c. Clobbers a, b, e, hl.
NoteOutOff:
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_OUT
    ret nz
    ld hl, wPatch + MIDI_BLOCK
    call HLplusC
    ld a, [hl]
    and a
    ret z
    dec a
    ld e, a
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    and a
    ret z                   ; nothing sounding
    ld a, $80
    or e
    call MidiOut
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    call MidiOut
    xor a
    jp MidiOut

; wMidiData1 = note, wMidiChNum = MIDI channel, wMidiVel = velocity.
MidiNoteOn:
    ld a, [wMidiData1]
    ld d, a                 ; d = note
    ld c, 0                 ; pass 1: a listening channel that already plays this note
.p1:
    call IsAssigned
    and a
    jr z, .p1next
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    cp d
    jr z, .play
.p1next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .p1
    ld c, 0                 ; pass 2: the first idle listening channel
.p2:
    call IsAssigned
    and a
    jr z, .p2next
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    and a
    jr z, .play
.p2next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .p2
    ld a, [wMidiRR]         ; pass 3: steal, round-robin, starting after the last victim
    ld c, a
    ld e, NUM_CH
.p3:
    inc c
    ld a, c
    and NUM_CH - 1
    ld c, a
    call IsAssigned
    and a
    jr nz, .steal
    dec e
    jr nz, .p3
    ret                     ; no GB channel listens to this MIDI channel
.steal:
    ld a, c
    ld [wMidiRR], a
.play:
    ld a, [wMidiVel]
    ld [wNoteVel], a        ; the voice scales its volume by this
    ld a, d
    call NoteOn             ; a = note, c = GB channel
    ld a, 127
    ld [wNoteVel], a
    ret

; Release the listening channel(s) that play wMidiData1.
MidiNoteOff:
    ld a, [wMidiData1]
    ld d, a
    ld c, 0
.l: call IsAssigned
    and a
    jr z, .next
    ld hl, wCurNote
    call HLplusC
    ld a, [hl]
    cp d
    jr nz, .next
    push bc
    call NoteOff
    pop bc
.next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .l
    ret

; Pitch bend: wMidiData1 = LSB (ignored), b = MSB (64 = centre).
MidiBend:
    ld d, b
    ld c, 0
.l: call IsAssigned
    and a
    jr z, .next
    ld hl, wBend
    call HLplusC
    ld [hl], d
.next:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .l
    ret

; Control change: wMidiData1 = controller, b = value.
MidiCC:
    ld a, [wMidiData1]
    cp 1
    jp z, .modWheel
    cp 120
    jp z, .allOff
    cp 14
    jp z, .bpmLow
    cp 15
    jp z, .bpmHigh
    cp 20
    jp z, .ccMain
    cp 21
    jp z, .ccVol
    cp 10
    jp z, .ccPan
    cp 123
    ret nz
.allOff:
    ld c, 0
.offLoop:
    call IsAssigned
    and a
    jr z, .offNext
    push bc
    call NoteOff
    pop bc
.offNext:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .offLoop
    ret
.bpmLow:                    ; SYNC_FOLLOW: BPM = 60 + CC14 + 128 * CC15 (the app sends CC14, then CC15)
    ld a, b
    ld [wFollowLo], a
    ret
.bpmHigh:
    ld a, [wPatch + MIDI_BLOCK + PM_SYNC]
    cp SYNC_FOLLOW
    ret nz
    ld a, [wFollowLo]
    add 60
    ld c, a
    ld a, b
    and 1
    ld a, c
    jr z, .bpmSet
    add 128
    jr nc, .bpmSet
    ld a, BPM_MAX           ; (the sum went past 255)
    jr .bpmOk
.bpmSet:
    cp BPM_MAX + 1
    jr c, .bpmOk
    ld a, BPM_MAX
.bpmOk:
    ld [wBpm], a
    ld a, [wDirtySong]
    or 1
    ld [wDirtySong], a
    jp MarkSeqStatus
; Timbre CCs: for every GB channel that listens to this MIDI channel; the value is scaled to the channel's own range. They change the
; patch (the next note-on uses it): CC20 = duty (CH1/2: 0-3) / wave (CH3: 0-7) / width (CH4: 0-1), CC21 = volume (0-15; CH3: level 0-2),
; CC10 = pan (0-31 left, 32-95 both, 96-127 right).
.ccMain:
    ld e, P_MAIN
    jr .ccEach
.ccVol:
    ld e, P_VOL
    jr .ccEach
.ccPan:
    ld e, P_PAN
.ccEach:
    ld a, b
    ld [wCcValue], a
    ld c, 0
.ccLoop:
    call IsAssigned         ; keeps c, e
    and a
    jr z, .ccNext
    ld a, [wCcValue]
    ld b, a                 ; b = the raw value 0-127
    ld a, e
    cp P_PAN
    jr z, .scalePan
    and a                   ; P_MAIN = 0
    jr nz, .scaleVol
    ld a, c                 ; main: CH1/2 value / 32, CH3 value / 16, CH4 value / 64
    cp 2
    ld a, b
    jr c, .main32
    jr z, .main16
    swap a                  ; CH4
    rrca
    rrca
    and 1
    jr .have
.main32:
    swap a
    rrca
    and 3
    jr .have
.main16:
    swap a
    and 7
    jr .have
.scaleVol:
    ld a, c
    cp 2
    ld a, b
    jr z, .volWave
    srl a                   ; value / 8
    srl a
    srl a
    jr .have
.volWave:
    cp 86                   ; CH3: output level 0 / 1 / 2
    ld a, 2
    jr nc, .have
    ld a, b
    cp 43
    ld a, 1
    jr nc, .have
    xor a
    jr .have
.scalePan:
    ld a, b
    cp 96
    ld a, 2
    jr nc, .have
    ld a, b
    cp 32
    ld a, 1
    jr c, .have
    xor a
.have:
    ld d, a                 ; d = the patch value
    ld a, c
    swap a
    add a                   ; channel * PATCH_SIZE (32)
    add e                   ; + the parameter
    push bc
    ld c, a
    ld hl, wPatch
    call HLplusC
    pop bc
    ld [hl], d
.ccNext:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .ccLoop
    ld a, $FF
    ld [wDirtyEdit], a      ; (the patch screen shows the new values)
    ret
.modWheel:
    ld a, [wPatch + MIDI_BLOCK + PM_MODW]
    and a
    ret z                   ; mod wheel disabled in the MIDI settings
    ld a, b
    swap a
    and $0F                 ; value / 16 = 0..7 vibrato depth
    ld d, a
    ld c, 0
.modLoop:
    call IsAssigned
    and a
    jr z, .modNext
    ld hl, wMod
    call HLplusC
    ld [hl], d
.modNext:
    inc c
    ld a, c
    cp NUM_CH
    jr c, .modLoop
    ret

; c = GB channel -> a = 1 if it listens to the MIDI channel in wMidiChNum, else 0.
; Keeps c, d, e. Clobbers hl.
IsAssigned:
    ld hl, wPatch + MIDI_BLOCK
    call HLplusC
    ld a, [wMidiChNum]
    cp [hl]
    ld a, 0
    ret nz
    inc a
    ret
