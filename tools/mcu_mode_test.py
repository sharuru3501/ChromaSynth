#!/usr/bin/env python3
"""Hardware test of the MIDI mode (OFF / BLE / USB) over the Chromatic's USB-C serial console.

Needs the console firmware with the MIDI MODE (chromatic-mcu patch 0008) and pyserial. It only talks to the console: it flashes
nothing and presses no buttons. Opening the port resets the ESP32 once (then the mode is OFF).

  python3 tools/mcu_mode_test.py                  # real port (/dev/cu.usbmodem*)
  python3 tools/mcu_mode_test.py --mock           # no hardware: checks the script itself against a simulated ESP32
  python3 tools/mcu_mode_test.py --cycles 10      # more BLE on/off cycles (a longer leak test)

What it checks:
  1. the firmware version, and that the boot mode is OFF
  2. BLE <-> USB <-> OFF switching: `ble` shows "started" only in BLE mode, and the free heap goes down by the BLE stack in BLE mode
  3. after repeated BLE start/stop the free heap comes back (no leak)
  4. `m` (wired notes) is accepted in USB mode only
  5. light sleep: in OFF mode, 28 s after boot, the console no longer answers (the CPU sleeps, the stock behaviour). Then press MENU on
     the Chromatic: the console must answer again, still in OFF (= it slept, it did not crash).
"""
import argparse
import glob
import re
import sys
import time


class RealPort:
    def __init__(self, path):
        import serial  # pyserial
        self.p = serial.Serial()
        self.p.port = path
        self.p.baudrate = 115200
        self.p.dtr = False
        self.p.rts = False
        self.p.open()
        self.p.dtr = False
        self.p.rts = False
        self.p.timeout = 0.02

    def command(self, text, wait=0.8):
        self.p.write((text + "\r\n").encode())
        return self.read(wait)

    def read(self, t):
        end = time.time() + t
        out = b""
        while time.time() < end:
            out += self.p.read(256)
        return out.decode(errors="replace").replace("\r", "")


class MockPort:
    """A tiny simulated console, to test this script without the hardware (it models the intended behaviour)."""

    def __init__(self):
        self.mode = "OFF"
        self.applied = "OFF"
        self.switches = 0
        self.heap = 163444
        self.sleeping = False
        self.t0 = time.time()
        self.leak = 0
        self.packets = 0
        self.woken = False

    def command(self, text, wait=0.8):
        if time.time() - self.t0 > 25 and self.applied == "OFF" and not self.woken:
            self.sleeping = True
        if self.sleeping and time.time() - self.t0 > 32:
            self.sleeping, self.woken = False, True      # the user pressed MENU
        if self.sleeping:
            return ""
        w = text.split()
        if w[0] == "chver":
            return "chlink firmware v9 (stock v4.6 + ... MIDI MODE menu OFF/BLE/USB ...)\n"
        if w[0] == "mode":
            if len(w) > 1:
                prev = self.applied
                self.mode = self.applied = w[1].upper()
                self.switches += 1
                if prev != "BLE" and self.applied == "BLE":
                    self.heap -= 86000
                if prev == "BLE" and self.applied != "BLE":
                    self.heap += 86000 - 150      # a small leak, to see the script notice a trend
                    self.leak += 150
            return "MIDI mode %s (applied %s), %d switches\n" % (self.mode, self.applied, self.switches)
        if w[0] == "ble":
            return "BLE MIDI: %s (init rc 0), not connected, 0 connections\n" % ("started" if self.applied == "BLE" else "NOT started")
        if w[0] == "heap":
            return "free heap %d B, lowest ever %d B, largest free block %d B\n" % (self.heap, self.heap - 4000, self.heap - 50000)
        if w[0] == "m":
            if self.applied == "USB" and w[1] == "90":      # only a note-on counts as a note-on packet
                self.packets += 1
            return ""
        if w[0] == "link" and len(w) > 1 and w[1] == "lat":
            return "  packet (symbols)       n %d, last 0 us, avg 0 us, max 0 us\n" % self.packets
        if w[0] == "link":
            return "mode auto, armed %s, hold 36 ms\npackets sent %d, aborted 0, dropped 0\n" % ("yes" if self.applied == "USB" else "no", self.packets)
        return ""

    def read(self, t):
        return ""


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  [%s]" % detail) if detail != "" else ""))


def heap_of(port):
    m = re.search(r"free heap (\d+) B", port.command("heap"))
    return int(m.group(1)) if m else None


def mode_cmd(port, name):
    out = port.command("mode " + name, wait=1.6)
    return ("applied %s" % name.upper()) in out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mock", action="store_true")
    ap.add_argument("--port")
    ap.add_argument("--cycles", type=int, default=5)
    ap.add_argument("--no-sleep-test", action="store_true", help="skip the light-sleep and MENU wake-up part (it needs a person to press MENU)")
    a = ap.parse_args()
    if a.mock:
        port = MockPort()
    else:
        ports = [a.port] if a.port else sorted(glob.glob("/dev/cu.usbmodem*"))
        if not ports:
            print("No /dev/cu.usbmodem* port: connect the Chromatic (USB data cable, cartridge in, console on).")
            return 2
        print("opening", ports[0], "(the ESP32 resets once; waiting for the boot)")
        port = RealPort(ports[0])
        port.read(6)
    t_boot = time.time()

    out = port.command("chver")
    check("firmware is the MIDI MODE build (v9)", "firmware v9" in out, out.strip()[:60])
    out = port.command("mode")
    check("boots in OFF", "MIDI mode OFF (applied OFF)" in out, out.strip())
    base = heap_of(port)
    check("free heap in OFF mode is readable", base is not None, base)
    check("`ble` says the stack is not started in OFF", "NOT started" in port.command("ble"))

    def packets():
        m = re.search(r"packets sent (\d+)", port.command("link stat", wait=1.2))
        return int(m.group(1)) if m else None

    def note_ons():
        """Note-on packets the link has sent (`link lat`: the n of 'packet (symbols)'). Keep-alives, HELLO and releases do not count."""
        m = re.search(r"packet \(symbols\)\s+n (\d+)", port.command("link lat", wait=1.0))
        return int(m.group(1)) if m else None

    def armed():
        return "armed yes" in port.command("link stat", wait=1.2)

    # wired notes first: OFF still keeps the ESP32 awake during the 20 s after boot (the boot grace), so the console answers
    n0 = note_ons()
    port.command("m 90 3c 64", wait=0.2)
    port.command("m 80 3c 00", wait=0.2)
    time.sleep(1.0)
    check("`m` is ignored in OFF mode (no note-on packet is queued or sent)", note_ons() == n0, n0)
    mode_cmd(port, "ble")
    time.sleep(3.0)                       # (BLE mode arms the link by itself: let its own HELLO/keep-alive traffic settle)
    n1 = note_ons()
    port.command("m 90 3c 64", wait=0.2)
    port.command("m 80 3c 00", wait=0.2)
    time.sleep(1.5)
    check("`m` is ignored in BLE mode (BLE and wired input are never both live)", note_ons() == n1, n1)

    # BLE <-> USB (never OFF between cycles: after the boot grace OFF lets the ESP32 sleep and the console goes quiet)
    usb_heaps, ble_heaps = [], []
    for i in range(a.cycles):
        ok = mode_cmd(port, "ble")
        started = "NOT started" not in port.command("ble")
        h = heap_of(port)
        ble_heaps.append(h)
        check("cycle %d: BLE mode applied, the stack is started" % (i + 1), ok and started, h)
        ok = mode_cmd(port, "usb")
        h = heap_of(port)
        usb_heaps.append(h)
        check("cycle %d: USB mode applied, the BLE stack is stopped" % (i + 1), ok and "NOT started" in port.command("ble"), h)
    if None not in ble_heaps and None not in usb_heaps and usb_heaps:
        used = usb_heaps[-1] - min(ble_heaps)
        check("the BLE stack takes memory while it runs (expected about 30-110 KB)", 30000 < used < 130000, "%d B" % used)
        steady = usb_heaps[0]
        drift = steady - usb_heaps[-1]
        check("no leak: after %d BLE start/stop cycles the free heap is back within 2 KB of the first stop" % a.cycles, abs(drift) <= 2048,
              "drift %+d B; heap after each stop: %s" % (-drift, usb_heaps))
        check("... and it does not shrink steadily from cycle to cycle", usb_heaps[0] - usb_heaps[-1] <= 1024, "first - last = %+d B" % (usb_heaps[0] - usb_heaps[-1]))

    # wired notes in USB mode
    mode_cmd(port, "usb")
    time.sleep(4)
    n2 = note_ons()
    is_armed = armed()
    port.command("m 90 3c 64", wait=0.3)
    time.sleep(2.5)
    port.command("m 80 3c 00", wait=0.3)
    time.sleep(2.0)
    n3 = note_ons()
    if is_armed:
        check("`m` is accepted in USB mode: a note-on packet is sent when the ROM is on its KEYBOARD screen", n3 == n2 + 1, "%s -> %s" % (n2, n3))
    else:
        print("INFO  USB mode, but the link is not armed (the ROM is not on its KEYBOARD screen): note-on packets %s -> %s, not checked" % (n2, n3))

    if a.no_sleep_test:
        mode_cmd(port, "usb")           # leave the ESP32 awake (USB mode) for the next test
        print()
        n_fail = results.count(False)
        print("ALL PASSED" if not n_fail else "%d FAILED" % n_fail)
        return 1 if n_fail else 0

    # light sleep, and waking from it
    heap_before = heap_of(port)
    mode_cmd(port, "off")
    wait = max(0, 28 - (time.time() - t_boot))
    print("INFO  OFF mode: waiting %.0f s for the boot grace to pass and the ESP32 to light-sleep..." % wait)
    time.sleep(wait)
    out = port.command("mode", wait=3.0)
    asleep = out.strip() == ""
    check("OFF mode: the console no longer answers (the ESP32 is light-sleeping, as in the stock firmware)", asleep, repr(out.strip()[:40]))
    if asleep and not a.mock:
        print("NOW: press the MENU button on the Chromatic (the OSD menu should open). Waiting up to 60 s for the ESP32 to answer again...")
    woke = False
    if asleep:
        for _ in range(30 if not a.mock else 6):
            out = port.command("mode", wait=2.0)
            if a.mock:
                time.sleep(2)      # the real port waits for the answer; the mock returns at once
            if "MIDI mode" in out:
                woke = True
                break
        check("MENU woke it: the console answers again, still OFF, so it was asleep and not crashed", woke and "applied OFF" in out, out.strip()[:50])
        if woke:
            h = heap_of(port)
            check("... and the free heap is unchanged by the sleep", h is not None and heap_before is not None and abs(h - heap_before) < 40000,
                  "%s -> %s (USB mode before, OFF now: BLE already stopped in both)" % (heap_before, h))
    print()
    n_fail = results.count(False)
    print("ALL PASSED" if not n_fail else "%d FAILED" % n_fail)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
