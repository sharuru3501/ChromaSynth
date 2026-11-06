#!/usr/bin/env python3
"""Reference model of the bridge firmware (docs/BRIDGE.md).

The bridge sits between a MIDI source/sink (USB-MIDI, DIN-5 or BLE MIDI) and the Game
Boy's link port. It is the link's clock master; the Game Boy is the slave. This file
is the executable specification of what the firmware has to do, with no hardware in it:
  * Bridge.host_in(bytes)        MIDI from the computer/keyboard -> bytes for the GB
  * Bridge.gb_in(byte, now)      byte that came back from the GB -> MIDI for the host
  * Bridge.host_out_due(now)     MIDI bytes whose time has come (clock interpolation)
  * link_schedule(...)           when each byte may be clocked out over the link
tools/test_bridge_ref.py tests it; tools/headless_midi_test.py feeds its output into the ROM.

Conventions (the ROM implements the other half):
  * $FD is the idle filler in both directions ("nothing to say").
  * Between the bridge and the GB the clock is ONE $F8 PER SEQUENCER TICK = 12 per beat.
    MIDI hosts use 24 per beat, so the bridge divides host->GB by 2 and interpolates GB->host.
  * Only messages the ROM understands are forwarded: note on/off, CC1/CC120/CC123, pitch bend,
    and realtime clock/start/continue/stop. Everything else is dropped to save link bandwidth.
  * Every forwarded message is sent with its status byte (no running status).
"""
from collections import deque

IDLE = 0xFD
CLOCK, START, CONTINUE, STOP = 0xF8, 0xFA, 0xFB, 0xFC
FORWARDED_CC = {1, 120, 123}

# Link timing (see docs/BRIDGE.md, section "Timing")
BIT_CLOCK_HZ = 32_000        # SCK frequency while a byte is shifted
BYTE_US = 8 * 1_000_000 / BIT_CLOCK_HZ   # 250 us per byte
GAP_US = 250                 # pause between bytes: the GB's serial ISR needs ~100 us to re-arm
IDLE_POLL_US = 2_000         # when nothing is queued, still clock an idle byte this often
                             # so that the GB can hand over its own bytes


class HostParser:
    """Splits a MIDI byte stream into complete channel messages and realtime bytes."""

    DATA_BYTES = {0x80: 2, 0x90: 2, 0xA0: 2, 0xB0: 2, 0xC0: 1, 0xD0: 1, 0xE0: 2}

    def __init__(self):
        self.status = None
        self.data = []
        self.in_sysex = False

    def feed(self, data):
        """Yield ('rt', byte) or ('msg', bytes) in stream order."""
        for b in data:
            if b >= 0xF8:                       # realtime: may appear anywhere, changes nothing
                yield ("rt", b)
            elif b >= 0x80:                     # a new status byte
                if b == 0xF0:
                    self.in_sysex = True
                    self.status = None
                elif b == 0xF7:
                    self.in_sysex = False
                    self.status = None
                elif b >= 0xF0:                 # other system common: not forwarded, cancels running status
                    self.status = None
                else:
                    self.in_sysex = False
                    self.status = b & 0xF0 | 0
                    self.channel = b & 0x0F
                self.data = []
            else:                               # a data byte
                if self.in_sysex or self.status is None:
                    continue
                self.data.append(b)
                if len(self.data) == self.DATA_BYTES[self.status]:
                    yield ("msg", bytes([self.status | self.channel]) + bytes(self.data))
                    self.data = []              # running status: keep self.status


class Bridge:
    def __init__(self):
        self.parser = HostParser()
        self.clock_phase = 0                    # host clocks since start: forward 1st, 3rd, 5th...
        self.to_gb = deque()                    # bytes waiting for the link
        self.last_tick = None                   # time of the previous GB tick ($F8)
        self.host_out = []                      # (time, byte) scheduled for the host
        self.gb_msg = []                        # a message arriving from the GB, being assembled

    # ---- host -> GB
    def host_in(self, data):
        for kind, item in self.parser.feed(data):
            if kind == "rt":
                self._host_realtime(item)
            else:
                status = item[0] & 0xF0
                if status in (0x80, 0x90, 0xE0):
                    self.to_gb.extend(item)
                elif status == 0xB0 and item[1] in FORWARDED_CC:
                    self.to_gb.extend(item)

    def _host_realtime(self, b):
        if b == CLOCK:
            if self.clock_phase == 0:           # 24 -> 12 per beat
                self.to_gb.append(CLOCK)
            self.clock_phase ^= 1
        elif b == START:
            self.clock_phase = 0                # the first clock after start is tick 0
            self.to_gb.append(START)
        elif b in (CONTINUE, STOP):
            self.to_gb.append(b)
        # active sensing ($FE), system reset ($FF), undefined: dropped

    # ---- GB -> host
    def gb_in(self, byte, now):
        """`byte` just came back over the link at time `now` (seconds)."""
        if byte == IDLE:
            return
        if byte == CLOCK:                       # 12 -> 24 per beat
            self.host_out.append((now, CLOCK))
            if self.last_tick is not None:
                half = (now - self.last_tick) / 2
                if 0 < half < 0.25:             # sane tempo; else skip the interpolation
                    self.host_out.append((now + half, CLOCK))
            self.last_tick = now
        elif byte in (START, CONTINUE, STOP):
            if byte != CONTINUE:
                self.last_tick = None           # no tempo reference across a start/stop
            self.host_out.append((now, byte))
        else:                                   # channel messages arrive complete from the GB
            self.host_out.append((now, byte))

    def host_out_due(self, now):
        due = [e for e in self.host_out if e[0] <= now]
        self.host_out = [e for e in self.host_out if e[0] > now]
        return [b for _, b in sorted(due, key=lambda e: e[0])]


def link_schedule(payload, start=0.0, queue_empty_poll=True):
    """Times (seconds) at which each byte of `payload` starts to be shifted out, given the
    byte time and the mandatory gap. Returns (times, end_time)."""
    t = start
    times = []
    for _ in payload:
        times.append(t)
        t += (BYTE_US + GAP_US) / 1e6
    return times, t


def poll_times(duration, start=0.0):
    """When the idle polls happen if nothing is queued for `duration` seconds."""
    n = int(duration / (IDLE_POLL_US / 1e6))
    return [start + i * IDLE_POLL_US / 1e6 for i in range(n)]
