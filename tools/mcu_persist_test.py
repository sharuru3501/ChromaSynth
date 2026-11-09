#!/usr/bin/env python3
"""Hardware test of the saved MIDI mode and the USB heartbeat (firmware with M11), over the USB-C serial console.

It only talks to the console (flashes nothing, presses no buttons). Opening the port resets the ESP32 once (a power cycle of the console is what reboots it for the real test: see below).
  1. a mode saved with `mode set ble` is applied again after a reboot (3 s after boot)
  2. `mode usb` (temporary) is not saved
  3. after `hb` has been seen, 3 s without it puts the saved mode back (the app sends one every second)
  4. `mode saved` puts the saved mode back at once
It ends by saving OFF again (`mode set off`).
  python3 tools/mcu_persist_test.py
"""
import glob
import re
import sys
import time

import serial

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


def open_port(path):
    p = serial.Serial()
    p.port = path
    p.baudrate = 115200
    p.dtr = False                                # (as tools/mcu_mode_test.py: DTR / RTS decide whether the ESP32 is held in reset)
    p.rts = False
    p.open()
    p.dtr = False
    p.rts = False
    p.timeout = 0.2
    return p


def cmd(p, line, wait=1.2):
    p.reset_input_buffer()
    p.write((line + "\r\n").encode())
    t = time.time() + wait
    out = b""
    while time.time() < t:
        out += p.read(256)
    return out.decode(errors="replace")


def mode(p):
    for _ in range(5):
        out = cmd(p, "mode", 1.5)
        m = re.search(r"MIDI mode (\w+) \(applied (\w+)\), saved for boot: (\w+)", out)
        if m:
            return m.groups()
    return None


ports = glob.glob("/dev/cu.usbmodem*")
if not ports:
    print("no /dev/cu.usbmodem* port")
    sys.exit(1)
path = ports[0]
p = open_port(path)
time.sleep(7)                                   # boot
m = mode(p)
check("the new firmware answers `mode` with the saved mode", m is not None, m)
cmd(p, "mode set off", 2.0)
cmd(p, "mode set ble", 3.0)
m = mode(p)
check("`mode set ble`: BLE applied and saved", m == ("BLE", "BLE", "BLE"), m)
p.close()
p = open_port(path)                              # a reboot
time.sleep(12)                                   # boot + 3 s + the BLE start
m = mode(p)
check("after a reboot the saved mode (BLE) is applied again", m == ("BLE", "BLE", "BLE"), m)
cmd(p, "mode usb", 2.0)
m = mode(p)
check("`mode usb` is temporary: USB applied, BLE still saved", m == ("USB", "USB", "BLE"), m)
for _ in range(6):                               # a heartbeat every second
    cmd(p, "hb", 0.1)
    time.sleep(0.9)
m = mode(p)
check("with heartbeats, USB stays", m == ("USB", "USB", "BLE"), m)
time.sleep(6)                                    # no heartbeat: back to the saved mode after 3 s (+ the BLE start)
m = mode(p)
check("3 s without a heartbeat: back to the saved mode (BLE)", m is not None and m[1] == "BLE", m)
cmd(p, "mode usb", 2.0)
cmd(p, "mode saved", 2.5)
m = mode(p)
check("`mode saved` puts the saved mode back at once", m is not None and m[1] == "BLE", m)
cmd(p, "mode usb", 2.0)                          # no heartbeat has been sent since: the older helpers keep USB
m = mode(p)
time.sleep(7)
m2 = mode(p)
check("a helper that never sends `hb` is not switched back", m is not None and m[:3] == ("USB", "USB", "BLE") and m2 is not None and m2[1] == "USB", (m, m2))
cmd(p, "mode set off", 3.0)
p.close()                                        # (in OFF the ESP32 light-sleeps and the console stops answering: look after a reboot)
p = open_port(path)
time.sleep(7)
m = mode(p)
check("saved OFF again (seen after a reboot)", m == ("OFF", "OFF", "OFF"), m)
p.close()
print("\n%d FAILED" % fails if fails else "\nALL PASSED")
sys.exit(1 if fails else 0)
