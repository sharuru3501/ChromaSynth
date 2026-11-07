#!/usr/bin/env python3
"""Soak / stress test of the wired path on the real Chromatic, judged by counters (no ears needed).

The ChromaSynth ROM must be on its KEYBOARD screen (the link arms itself only then; the test says so if it is not). The test only talks
to the ESP32's console: it opens the port (the ESP32 resets once), switches to USB mode, plays a human-like random melody and fast
bursts through `m 90 3c 64` (what the Mac helper sends), then reads `link stat`, `link lat`, `heap`.

  python3 tools/mcu_soak_test.py                    # 90 s of melody + bursts
  python3 tools/mcu_soak_test.py --seconds 300      # a longer soak

Checks: no aborted packets, no retransmissions or re-syncs (the ROM took every packet), no hanging note, the heap does not shrink,
the console still answers, and switching to OFF in the middle of a stream stops it cleanly (nothing queued, no packets after OFF)
and USB mode works again afterwards.
"""
import argparse
import glob
import random
import re
import sys
import time


class Port:
    def __init__(self, path):
        import serial
        self.p = serial.Serial()
        self.p.port, self.p.baudrate = path, 115200
        self.p.dtr = False
        self.p.rts = False
        self.p.open()
        self.p.dtr = False
        self.p.rts = False
        self.p.timeout = 0.01

    def send(self, text):
        self.p.write((text + "\r\n").encode())

    def read(self, t):
        end = time.time() + t
        out = b""
        while time.time() < end:
            out += self.p.read(512)
        return out.decode(errors="replace").replace("\r", "")

    def command(self, text, wait=0.8):
        self.send(text)
        return self.read(wait)


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  [%s]" % detail) if detail != "" else ""))


def num(pattern, text, group=1):
    m = re.search(pattern, text)
    return int(m.group(group)) if m else None


def stats(port):
    st = port.command("link stat", wait=1.5)
    lat = port.command("link lat", wait=1.2)
    return {
        "armed": "armed yes" in st,
        "sent": num(r"packets sent (\d+)", st),
        "aborted": num(r"aborted (\d+)", st),
        "dropped": num(r"dropped (\d+)", st),
        "queued": num(r"queued (\d+)", st),
        "retrans": num(r"retransmitted (\d+)", st),
        "resync": num(r"re-synced (\d+)", st),
        "stale": num(r"stale note-offs not sent (\d+)", st),
        "sounding": num(r"sounding note (-?\d+)", st),
        "wait_avg": num(r"queue wait\s+n (\d+), last (\d+) us, avg (\d+)", lat, 3),
        "pkt_avg": num(r"packet \(symbols\)\s+n (\d+), last (\d+) us, avg (\d+)", lat, 3),
        "pkt_max": num(r"packet \(symbols\)\s+n (\d+), last (\d+) us, avg (\d+) us, max (\d+)", lat, 4),
        "notes": num(r"packet \(symbols\)\s+n (\d+)", lat),
        "rom": (re.search(r"ROM: (.*)", st).group(1).strip() if re.search(r"ROM: (.*)", st) else "?"),
    }


def quick(port):
    """A faster `link stat` + `link lat` read (about 2 s): for the part of the test that must finish inside the 20 s boot grace."""
    st = port.command("link stat", wait=0.7)
    lat = port.command("link lat", wait=0.6)
    return {"armed": "armed yes" in st, "queued": num(r"queued (\d+)", st), "notes": num(r"packet \(symbols\)\s+n (\d+)", lat)}


def heap(port):
    out = port.command("heap")
    return num(r"free heap (\d+) B", out), num(r"lowest ever (\d+) B", out)


def melody(port, seconds, rng):
    """Random monophonic melody at human speed, with legato overlaps and a few fast bursts. Returns the number of notes sent."""
    end = time.time() + seconds
    n = 0
    note = 60
    held = None
    while time.time() < end:
        r = rng.random()
        if r < 0.12:                                   # a fast burst: 8 notes 70-110 ms apart (above what the link can take: it must drop, not break)
            for _ in range(8):
                note = max(36, min(107, note + rng.choice([-5, -2, -1, 1, 2, 3, 5])))
                port.send("m 90 %02x %02x" % (note, rng.randint(40, 127)))
                n += 1
                time.sleep(rng.uniform(0.07, 0.11))
                port.send("m 80 %02x 00" % note)
                time.sleep(rng.uniform(0.01, 0.03))
        else:
            note = max(36, min(107, note + rng.choice([-7, -4, -2, -1, 1, 2, 4, 7])))
            port.send("m 90 %02x %02x" % (note, rng.randint(40, 127)))
            n += 1
            if held is not None and rng.random() < 0.3:    # legato: the previous note is released AFTER the new one started
                port.send("m 80 %02x 00" % held)
            time.sleep(rng.uniform(0.18, 0.45))
            if rng.random() < 0.7:
                port.send("m 80 %02x 00" % note)
                held = None
            else:
                held = note
            time.sleep(rng.uniform(0.05, 0.3))
        if rng.random() < 0.05:
            port.send("m b0 7b 00")                     # all notes off
            held = None
    if held is not None:
        port.send("m 80 %02x 00" % held)
    port.send("m b0 7b 00")
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=90)
    ap.add_argument("--port")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    ports = [a.port] if a.port else sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        print("No /dev/cu.usbmodem* port.")
        return 2
    rng = random.Random(a.seed)
    print("opening", ports[0], "(the ESP32 resets once)")
    port = Port(ports[0])
    port.read(5)
    check("the console answers after boot", "firmware" in port.command("chver", wait=0.6))
    port.command("mode usb", wait=1.2)
    for _ in range(12):                                 # let the link arm itself (sync + HELLO takes about a second)
        if quick(port)["armed"]:
            break
        time.sleep(0.3)
    s0 = {"armed": quick(port)["armed"]}
    check("the link is armed (the ROM is on its KEYBOARD screen)", s0["armed"])
    if not s0["armed"]:
        print("The ROM is not on its KEYBOARD screen: only the idle checks can run.")
    # OFF in the middle of a stream. It must run inside the 20 s boot grace: after it, OFF lets the ESP32 light-sleep within 0.1 s
    # and the console goes quiet (that is the point of OFF, but then nothing can be read).
    if s0["armed"]:
        for i in range(6):
            port.send("m 90 %02x 64" % (60 + i))
            time.sleep(0.05)
        port.command("mode off", wait=0.5)
        so = quick(port)
        check("OFF in the middle of a stream: nothing stays queued", so["queued"] == 0, so["queued"])
        check("... and the link is disarmed", not so["armed"])
        port.send("m 90 3c 64")
        time.sleep(0.7)
        so2 = quick(port)
        check("... and `m` no longer sends anything", so2["notes"] == so["notes"], "%s -> %s" % (so["notes"], so2["notes"]))
        port.command("mode usb", wait=1.2)
        for _ in range(10):
            if quick(port)["armed"]:
                break
            time.sleep(0.3)
        s3 = quick(port)
        check("back in USB mode the link arms itself again", s3["armed"])
        n_before = s3["notes"]
        port.send("m 90 3c 64")
        time.sleep(2.0)
        port.send("m 80 3c 00")
        time.sleep(0.8)
        s4 = quick(port)
        check("... and a note goes through again", (s4["notes"] or 0) == (n_before or 0) + 1, "%s -> %s" % (n_before, s4["notes"]))

    s0 = stats(port)
    h0, low0 = heap(port)
    print("INFO  start of the soak: heap %s B (lowest %s B), note-on packets so far %s" % (h0, low0, s0["notes"]))

    sent = melody(port, a.seconds, rng) if s0["armed"] else 0
    time.sleep(2.0)                                     # let the queue drain
    for _ in range(20):
        s = stats(port)
        if s["queued"] == 0:
            break
        time.sleep(1.0)
    s = stats(port)
    h1, low1 = heap(port)
    print("INFO  sent %d note-ons from the host; packets: sent %s, aborted %s, dropped (coalesced/stale) %s, stale offs %s" %
          (sent, s["sent"], s["aborted"], s["dropped"], s["stale"]))
    print("INFO  note-on packets %s, queue wait avg %s us, packet avg %s us (max %s us); heap %s -> %s B (lowest %s)" %
          (s["notes"], s["wait_avg"], s["pkt_avg"], s["pkt_max"], h0, h1, low1))
    print("INFO  since boot: retransmitted %s, re-synced %s, aborted %s (a packet that took about 1 s is a retransmission with a re-sync)" %
          (s["retrans"], s["resync"], s["aborted"]))
    if s0["armed"]:
        check("no packet was aborted", s["aborted"] == s0["aborted"], "%s -> %s" % (s0["aborted"], s["aborted"]))
        check("the ROM took every packet: no retransmission, no re-sync", (s["retrans"] or 0) == (s0["retrans"] or 0) and (s["resync"] or 0) == (s0["resync"] or 0),
              "retransmitted %s, re-synced %s" % (s["retrans"], s["resync"]))
        check("the queue drained", s["queued"] == 0, s["queued"])
        check("no note is left hanging in the link's bookkeeping", s["sounding"] == -1, s["sounding"])
        check("the link is still armed after the soak", s["armed"], s["rom"])
        check("packets were really sent (the test did something)", (s["notes"] or 0) - (s0["notes"] or 0) >= max(5, sent // 3),
              "%s note-on packets for %d notes (the rest were coalesced under load)" % ((s["notes"] or 0) - (s0["notes"] or 0), sent))
    check("the free heap did not shrink during the soak (tolerance 2 KB)", h0 is not None and h1 is not None and h1 >= h0 - 2048, "%s -> %s" % (h0, h1))
    check("the console answers", "firmware" in port.command("chver"))

    port.command("mode off", wait=1.0)
    print()
    n_fail = results.count(False)
    print("ALL PASSED" if not n_fail else "%d FAILED" % n_fail)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
