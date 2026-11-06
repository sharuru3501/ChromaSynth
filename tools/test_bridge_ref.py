#!/usr/bin/env python3
"""Unit tests for the bridge reference model (pure Python, no emulator): python3 tools/test_bridge_ref.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import bridge_ref as br  # noqa: E402


def gb_bytes(bridge):
    out = list(bridge.to_gb)
    bridge.to_gb.clear()
    return out


class HostToGb(unittest.TestCase):
    def test_note_messages_pass_through(self):
        b = br.Bridge()
        b.host_in(bytes([0x90, 60, 100, 0x80, 60, 0, 0xE0, 0, 64]))
        self.assertEqual(gb_bytes(b), [0x90, 60, 100, 0x80, 60, 0, 0xE0, 0, 64])

    def test_running_status_is_expanded(self):
        b = br.Bridge()
        b.host_in(bytes([0x93, 60, 100, 62, 100, 64, 0]))
        self.assertEqual(gb_bytes(b), [0x93, 60, 100, 0x93, 62, 100, 0x93, 64, 0])

    def test_message_split_across_chunks(self):
        b = br.Bridge()
        b.host_in(bytes([0x90, 60]))
        self.assertEqual(gb_bytes(b), [])
        b.host_in(bytes([100]))
        self.assertEqual(gb_bytes(b), [0x90, 60, 100])

    def test_unsupported_messages_are_dropped(self):
        b = br.Bridge()
        b.host_in(bytes([0xD0, 50]))                        # channel pressure
        b.host_in(bytes([0xA0, 60, 50]))                    # poly aftertouch
        b.host_in(bytes([0xC0, 5]))                         # program change
        b.host_in(bytes([0xB0, 7, 100]))                    # CC7
        b.host_in(bytes([0xF0, 0x7E, 0x00, 0x09, 0x01, 0xF7]))  # sysex
        b.host_in(bytes([0xFE, 0xFF, 0xF9, 0xFD]))          # active sensing, reset, undefined realtime
        self.assertEqual(gb_bytes(b), [])

    def test_forwarded_controllers(self):
        b = br.Bridge()
        b.host_in(bytes([0xB1, 1, 99, 120, 0, 123, 0, 64, 127]))   # CC1, CC120, CC123 pass; sustain (64) does not
        self.assertEqual(gb_bytes(b), [0xB1, 1, 99, 0xB1, 120, 0, 0xB1, 123, 0])

    def test_dropping_a_message_does_not_corrupt_running_status(self):
        b = br.Bridge()
        b.host_in(bytes([0xB0, 7, 100, 10, 100, 0x90, 60, 100]))   # two CC7 (dropped), then a note
        self.assertEqual(gb_bytes(b), [0x90, 60, 100])

    def test_realtime_inside_a_message(self):
        b = br.Bridge()
        b.host_in(bytes([0x90, 60, 0xF8, 100]))
        # the clock byte is forwarded at once (it is the 1st clock after reset), the note when it completes
        self.assertEqual(gb_bytes(b), [0xF8, 0x90, 60, 100])
        self.assertEqual(b.clock_phase, 1)

    def test_sysex_does_not_leak_data_bytes(self):
        b = br.Bridge()
        b.host_in(bytes([0x90, 60, 100, 0xF0, 1, 2, 3, 0xF7, 4, 5]))   # after sysex there is no running status
        self.assertEqual(gb_bytes(b), [0x90, 60, 100])


class Clock(unittest.TestCase):
    def test_24_to_12_per_beat(self):
        b = br.Bridge()
        b.host_in(bytes([br.START]))
        b.host_in(bytes([br.CLOCK] * 24))
        out = gb_bytes(b)
        self.assertEqual(out[0], br.START)
        self.assertEqual(out[1:].count(br.CLOCK), 12)

    def test_first_clock_after_start_is_forwarded(self):
        b = br.Bridge()
        b.host_in(bytes([br.CLOCK] * 5))                 # stray clocks before start
        gb_bytes(b)
        b.host_in(bytes([br.START, br.CLOCK, br.CLOCK, br.CLOCK]))
        self.assertEqual(gb_bytes(b), [br.START, br.CLOCK, br.CLOCK])   # clocks #1 and #3

    def test_continue_keeps_the_phase(self):
        b = br.Bridge()
        b.host_in(bytes([br.START, br.CLOCK]))           # phase 1 now
        gb_bytes(b)
        b.host_in(bytes([br.STOP, br.CONTINUE, br.CLOCK, br.CLOCK]))
        self.assertEqual(gb_bytes(b), [br.STOP, br.CONTINUE, br.CLOCK])

    def test_12_to_24_per_beat_is_evenly_spaced(self):
        b = br.Bridge()
        period = 41_666                                  # 120 BPM: 41.67 ms per tick, in us
        for i in range(8):
            b.gb_in(br.CLOCK, i * period)
        times = sorted(t for t, _ in b.host_out)
        gaps = [y - x for x, y in zip(times[2:], times[3:])]
        self.assertTrue(all(abs(g - period / 2) <= 1 for g in gaps), gaps)
        # after the first interval is known there are two clocks per tick
        self.assertEqual(len(times), 8 + 7)

    def test_start_resets_the_tempo_reference(self):
        b = br.Bridge()
        b.gb_in(br.CLOCK, 0)
        b.gb_in(br.CLOCK, 40_000)
        b.gb_in(br.STOP, 50_000)
        b.gb_in(br.START, 5_000_000)
        b.gb_in(br.CLOCK, 5_000_000)
        n = len(b.host_out)
        b.gb_in(br.CLOCK, 5_040_000)                     # first interval after the pause: interpolated
        self.assertEqual(len(b.host_out) - n, 2)
        c = br.Bridge()
        c.gb_in(br.CLOCK, 0)
        c.gb_in(br.START, 9_000_000)
        c.gb_in(br.CLOCK, 9_000_000)
        self.assertEqual([x for _, x in c.host_out].count(br.CLOCK), 2)   # no 9-second "half period"

    def test_gb_idle_bytes_are_filtered_and_notes_pass(self):
        b = br.Bridge()
        for byte in (br.IDLE, 0x90, 60, 100, br.IDLE, 0x80, 60, 0):
            b.gb_in(byte, 0)
        self.assertEqual(b.host_out_due(1_000_000), [0x90, 60, 100, 0x80, 60, 0])

    def test_scheduled_clocks_come_out_in_time_order(self):
        b = br.Bridge()
        b.gb_in(br.CLOCK, 0)
        b.gb_in(br.CLOCK, 40_000)        # interval 40 ms -> the in-between clock is due at 60 ms
        self.assertEqual(b.host_out_due(39_000), [br.CLOCK])      # the tick at 0
        self.assertEqual(b.host_out_due(41_000), [br.CLOCK])      # the tick at 40 ms
        self.assertEqual(b.host_out_due(59_000), [])
        self.assertEqual(b.host_out_due(61_000), [br.CLOCK])      # the interpolated one at 60 ms

    def test_a_note_arriving_before_a_pending_clock_is_ordered_by_time(self):
        b = br.Bridge()
        b.gb_in(br.CLOCK, 0)
        b.gb_in(br.CLOCK, 40_000)        # pending interpolated clock at 60 ms
        b.gb_in(0x90, 45_000)
        b.gb_in(60, 45_000)
        b.gb_in(100, 45_000)
        self.assertEqual(b.host_out_due(100_000), [br.CLOCK, br.CLOCK, 0x90, 60, 100, br.CLOCK])


class Link(unittest.TestCase):
    def test_link_starts_down_and_only_polls(self):
        b = br.Bridge()
        b.host_in(bytes([0x90, 60, 100]))
        self.assertEqual(b.link_next(), (br.IDLE, br.LINK_DOWN_POLL_US, False))
        self.assertEqual(len(b.to_gb), 0)                         # nothing is hoarded for an absent GB

    def test_ff_means_not_ready_and_anything_else_brings_the_link_up(self):
        b = br.Bridge()
        b.link_next()
        b.link_rx(0xFF, 0)
        self.assertFalse(b.link_up)
        b.link_rx(br.IDLE, 1000)
        self.assertTrue(b.link_up)
        b.host_in(bytes([0x90, 60, 100]))
        self.assertEqual(b.link_next(), (0x90, br.GAP_US, True))
        self.assertEqual(b.link_next(), (60, br.GAP_US, True))
        self.assertEqual(b.link_next(), (100, br.GAP_US, True))
        self.assertEqual(b.link_next(), (br.IDLE, br.IDLE_POLL_US - br.BYTE_US, False))

    def test_losing_the_link_drops_what_is_queued(self):
        b = br.Bridge()
        b.link_rx(br.IDLE, 0)
        b.host_in(bytes([0x90, 60, 100]))
        b.link_rx(0xFF, 10)
        self.assertEqual(b.link_next()[0], br.IDLE)
        self.assertEqual(len(b.to_gb), 0)

    def test_stale_input_is_dropped_when_the_link_comes_back(self):
        b = br.Bridge()
        b.to_gb.extend([0x90, 60, 100])                           # arrived while the GB was away
        b.link_rx(br.IDLE, 0)
        self.assertEqual(len(b.to_gb), 0)

    def test_replies_are_forwarded_to_the_host(self):
        b = br.Bridge()
        b.link_rx(br.IDLE, 0)
        for t, byte in enumerate((0x90, 60, 100, br.IDLE)):
            b.link_rx(byte, 1000 * t)
        self.assertEqual(b.host_out_due(10_000), [0x90, 60, 100])


class LinkTiming(unittest.TestCase):
    def test_byte_gap_is_enough_for_the_gb_isr(self):
        # The ROM's serial ISR takes about 100 cycles (~100 us at 1 MHz machine cycles).
        # The next byte must not start before SB/SC are ready again.
        self.assertGreaterEqual(br.GAP_US, 2 * 100)
        self.assertEqual(br.BYTE_US, 250)

    def test_throughput_covers_midi(self):
        times, end = br.link_schedule([0] * 1000)
        rate = 1000 / (end / 1e6)
        self.assertGreater(rate, 1500)                    # bytes per second: plenty for the filtered stream

    def test_a_three_note_chord_arrives_quickly(self):
        times, end = br.link_schedule([0x90, 60, 100] * 3)
        self.assertLess(end / 1000, 5.0)                  # ms

    def test_idle_polling_lets_the_gb_talk_within_a_couple_of_ms(self):
        polls = br.poll_times(100_000)
        self.assertEqual(len(polls), 50)
        gaps = {y - x for x, y in zip(polls, polls[1:])}
        self.assertEqual(gaps, {br.IDLE_POLL_US})

    def test_clock_stream_is_a_small_part_of_the_link(self):
        # 240 BPM, one byte per tick: 48 bytes/s out and in, against ~1800 bytes/s capacity
        self.assertLess(48 / (1e6 / (br.BYTE_US + br.GAP_US)), 0.03)


if __name__ == "__main__":
    unittest.main(verbosity=1)
