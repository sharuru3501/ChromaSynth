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
  5. light sleep: in OFF mode, 25 s after boot, the console no longer answers (the CPU sleeps, the stock behaviour). The ESP32 is then
     left asleep: press MENU on the Chromatic (or open the port again) to wake it.
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

    def command(self, text, wait=0.8):
        if time.time() - self.t0 > 25 and self.applied == "OFF":
            self.sleeping = True
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
            if self.applied == "USB":
                self.packets += 1
            return ""
        if w[0] == "link":
            return "mode auto, armed no, hold 36 ms\npackets sent %d, aborted 0, dropped 0\n" % self.packets
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

    # BLE <-> USB <-> OFF
    ble_heaps, off_heaps = [], []
    for i in range(a.cycles):
        ok = mode_cmd(port, "ble")
        started = "started (init" in port.command("ble") and "NOT started" not in port.command("ble")
        h = heap_of(port)
        ble_heaps.append(h)
        check("cycle %d: BLE mode applied, the stack is started" % (i + 1), ok and started, h)
        ok = mode_cmd(port, "usb")
        check("cycle %d: USB mode applied, the BLE stack is stopped" % (i + 1), ok and "NOT started" in port.command("ble"))
        ok = mode_cmd(port, "off")
        h = heap_of(port)
        off_heaps.append(h)
        check("cycle %d: OFF mode applied" % (i + 1), ok, h)
    if base and None not in ble_heaps and None not in off_heaps:
        used = base - min(ble_heaps)
        check("the BLE stack takes memory while it runs (expected about 60-110 KB)", 40000 < used < 130000, "%d B" % used)
        drift = base - off_heaps[-1]
        check("no leak: after %d BLE start/stop cycles the free heap is back within 4 KB of the start" % a.cycles, abs(drift) <= 4096,
              "drift %+d B; heap after each OFF: %s" % (-drift, off_heaps))
        trend = off_heaps[0] - off_heaps[-1]
        check("... and it does not shrink steadily from cycle to cycle", trend <= 1024, "first - last = %+d B" % trend)

    # wired notes
    def packets():
        m = re.search(r"packets sent (\d+)", port.command("link stat", wait=1.5))
        return int(m.group(1)) if m else None

    mode_cmd(port, "off")
    p0 = packets()
    port.command("m 90 3c 64", wait=0.3)
    port.command("m 80 3c 00", wait=0.3)
    time.sleep(0.5)
    check("`m` is ignored in OFF mode (no packets queued or sent)", packets() == p0, p0)
    mode_cmd(port, "ble")
    port.command("m 90 3c 64", wait=0.3)
    port.command("m 80 3c 00", wait=0.3)
    time.sleep(0.5)
    check("`m` is ignored in BLE mode (BLE and wired input are never both live)", packets() == p0, p0)
    mode_cmd(port, "usb")
    time.sleep(3)
    p1 = packets()
    port.command("m 90 3c 64", wait=0.3)
    time.sleep(1.5)
    port.command("m 80 3c 00", wait=0.3)
    time.sleep(1.5)
    p2 = packets()
    print("INFO  USB mode, ROM on its KEYBOARD screen? packets sent before/after two notes: %s -> %s "
          "(they only increase if the ROM shows the keyboard screen and the link is armed)" % (p1, p2))
    mode_cmd(port, "off")

    # light sleep
    wait = max(0, 28 - (time.time() - t_boot))
    print("INFO  OFF mode: waiting %.0f s for the 20 s boot grace to pass and the ESP32 to light-sleep..." % wait)
    time.sleep(wait)
    out = port.command("mode", wait=3.0)
    check("OFF mode: the console no longer answers (the ESP32 is light-sleeping, as in the stock firmware)", out.strip() == "",
          repr(out.strip()[:40]))
    print("The ESP32 is now asleep (stock behaviour). Press MENU on the Chromatic, or open the port again, to wake it.")
    print()
    n_fail = results.count(False)
    print("ALL PASSED" if not n_fail else "%d FAILED" % n_fail)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
