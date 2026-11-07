#!/usr/bin/env python3
"""Long-run and abuse test of the Chromatic's ESP32 firmware over the USB-C console, judged by counters (no ears, no Mac Bluetooth).

  python3 tools/mcu_longrun_test.py                 # flood + 5 min USB idle + 5 min BLE idle
  python3 tools/mcu_longrun_test.py --minutes 1     # a short run

1. flood: 3000 `m` lines at the serial port's full speed (what a MIDI loop does). The ESP32 must stay alive, the heap must not shrink,
   the link queue must drain and the link must work again.
2. USB idle: the link is armed and only keep-alive pings flow. No re-sync, no retransmission, no abort; the heap stays put.
3. BLE idle: the BLE stack advertises. It must not crash, its heap use and the stack margins must stay put.
The ChromaSynth ROM should be on its KEYBOARD screen for parts 1 and 2 (the test says if it is not).
"""
import argparse
import glob
import re
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from mcu_soak_test import Port, check, num, results, stats, heap  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=5.0)
    ap.add_argument("--port")
    a = ap.parse_args()
    ports = [a.port] if a.port else sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        print("No /dev/cu.usbmodem* port.")
        return 2
    print("opening", ports[0], "(the ESP32 resets once)")
    port = Port(ports[0])
    port.read(5)
    check("the console answers after boot", "firmware" in port.command("chver"))
    port.command("mode usb", wait=1.5)
    for _ in range(12):
        if "armed yes" in port.command("link stat", wait=0.8):
            break
        time.sleep(0.3)
    s0 = stats(port)
    armed = s0["armed"]
    check("the link is armed (the ROM is on its KEYBOARD screen)", armed)
    h0, low0 = heap(port)

    # 1. flood
    n_lines = 3000
    t0 = time.time()
    chunk = []
    for i in range(n_lines):
        chunk.append("m 90 %02x 64\r\nm 80 %02x 00\r\n" % (48 + i % 24, 48 + i % 24))
        if len(chunk) == 50:
            port.p.write("".join(chunk).encode())
            chunk = []
    if chunk:
        port.p.write("".join(chunk).encode())
    port.p.flush()
    print("INFO  flood: %d console lines written in %.1f s" % (2 * n_lines, time.time() - t0))
    time.sleep(8.0)        # the console works through its input at 115200 bps
    alive = "firmware" in port.command("chver", wait=3.0)
    for _ in range(60):
        if alive:
            break
        time.sleep(1.0)
        alive = "firmware" in port.command("chver", wait=2.0)
    check("flood: the ESP32 is alive afterwards", alive)
    for _ in range(40):
        s = stats(port)
        if s["queued"] == 0:
            break
        time.sleep(1.0)
    s = stats(port)
    h1, low1 = heap(port)
    check("flood: the link queue drained (it is bounded: the rest was dropped, not stored)", s["queued"] == 0, s["queued"])
    check("flood: the free heap did not shrink (tolerance 2 KB)", h0 is not None and h1 is not None and h1 >= h0 - 2048, "%s -> %s (lowest %s)" % (h0, h1, low1))
    print("INFO  flood: note-on packets %s, dropped %s, aborted %s, retransmitted %s, re-synced %s" %
          (s["notes"], s["dropped"], s["aborted"], s["retrans"], s["resync"]))
    if armed:
        check("flood: the link is still armed and nothing hangs", s["armed"] and s["sounding"] == -1, "sounding %s" % s["sounding"])
        n = s["notes"]
        port.send("m 90 3c 64")
        time.sleep(2.0)
        port.send("m 80 3c 00")
        time.sleep(1.5)
        check("flood: a note goes through afterwards", (stats(port)["notes"] or 0) == (n or 0) + 1)

    # 2. USB idle
    base = stats(port)
    hb, _ = heap(port)
    end = time.time() + a.minutes * 60
    print("INFO  USB idle for %.0f min (keep-alive pings only)..." % a.minutes)
    while time.time() < end:
        time.sleep(30)
    s = stats(port)
    h2, _ = heap(port)
    if armed:
        check("USB idle: still armed", s["armed"])
        check("USB idle: no re-sync, retransmission or abort", (s["resync"] or 0) == (base["resync"] or 0) and (s["retrans"] or 0) == (base["retrans"] or 0)
              and (s["aborted"] or 0) == (base["aborted"] or 0), "re-synced %s, retransmitted %s, aborted %s" % (s["resync"], s["retrans"], s["aborted"]))
        check("USB idle: keep-alive packets went out (about one per 2 s)", (s["sent"] or 0) - (base["sent"] or 0) >= a.minutes * 60 / 2 * 0.8,
              "%s -> %s packets" % (base["sent"], s["sent"]))
    check("USB idle: the heap did not move (tolerance 1 KB)", hb is not None and h2 is not None and abs(h2 - hb) <= 1024, "%s -> %s" % (hb, h2))

    # 3. BLE idle
    port.command("mode ble", wait=2.0)
    time.sleep(3)
    tk0 = port.command("tasks")
    hb0, _ = heap(port)
    started = "NOT started" not in port.command("ble") and "started" in port.command("ble")
    check("BLE idle: the stack is started", started)
    end = time.time() + a.minutes * 60
    print("INFO  BLE idle for %.0f min (advertising)..." % a.minutes)
    ok_alive = True
    while time.time() < end:
        time.sleep(30)
        if "firmware" not in port.command("chver", wait=1.0):
            ok_alive = False
            break
    tk1 = port.command("tasks")
    hb1, lowb = heap(port)
    check("BLE idle: the ESP32 stayed alive", ok_alive)
    check("BLE idle: still started", "NOT started" not in port.command("ble"))
    check("BLE idle: the heap did not move (tolerance 1 KB)", hb0 is not None and hb1 is not None and abs(hb1 - hb0) <= 1024, "%s -> %s (lowest %s)" % (hb0, hb1, lowb))
    m0 = re.search(r"NimBLE host (\d+)", tk0)
    m1 = re.search(r"NimBLE host (\d+)", tk1)
    check("BLE idle: the NimBLE host stack margin did not shrink", bool(m0 and m1) and int(m1.group(1)) >= int(m0.group(1)) - 64,
          "%s -> %s B free" % (m0.group(1) if m0 else "?", m1.group(1) if m1 else "?"))
    port.command("mode usb", wait=1.5)
    check("the console answers at the end", "firmware" in port.command("chver"))
    port.command("mode off", wait=1.0)
    print()
    n_fail = results.count(False)
    print("ALL PASSED" if not n_fail else "%d FAILED" % n_fail)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
