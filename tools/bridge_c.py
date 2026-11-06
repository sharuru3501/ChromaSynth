#!/usr/bin/env python3
"""The C bridge core (firmware/core/bridge_core.c) behind the same interface as tools/bridge_ref.Bridge.

Build the library first:  make -C firmware/test lib
It lets tools/headless_midi_test.py run the ROM (in PyBoy) against the code that will run on the
ESP32, not only against the Python model.
"""
import ctypes
import pathlib
import platform

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "firmware" / "test" / ("libbridge." + ("dylib" if platform.system() == "Darwin" else "so"))


class _LinkStep(ctypes.Structure):
    _fields_ = [("tx", ctypes.c_uint8), ("wait_us", ctypes.c_uint32), ("data", ctypes.c_bool)]


def available():
    return LIB.exists()


class CBridge:
    def __init__(self):
        lib = self.lib = ctypes.CDLL(str(LIB))
        lib.br_sizeof.restype = ctypes.c_size_t
        self.state = ctypes.create_string_buffer(lib.br_sizeof())
        lib.bridge_init(self.state)
        lib.bridge_host_in.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        lib.bridge_to_gb_pop.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)]
        lib.bridge_to_gb_pop.restype = ctypes.c_bool
        lib.bridge_gb_in.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]
        lib.bridge_host_out_pop_due.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint8)]
        lib.bridge_host_out_pop_due.restype = ctypes.c_bool
        lib.bridge_link_next.argtypes = [ctypes.c_void_p]
        lib.bridge_link_next.restype = _LinkStep
        lib.bridge_link_rx.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]

    def host_in(self, data):
        data = bytes(data)
        self.lib.bridge_host_in(self.state, data, len(data))

    def take_to_gb(self):
        out, x = [], ctypes.c_uint8()
        while self.lib.bridge_to_gb_pop(self.state, ctypes.byref(x)):
            out.append(x.value)
        return out

    def gb_in(self, byte, now_us):
        self.lib.bridge_gb_in(self.state, byte, now_us & 0xFFFFFFFF)

    def host_out_due(self, now_us):
        out, x = [], ctypes.c_uint8()
        while self.lib.bridge_host_out_pop_due(self.state, now_us & 0xFFFFFFFF, ctypes.byref(x)):
            out.append(x.value)
        return out

    def link_next(self):
        s = self.lib.bridge_link_next(self.state)
        return s.tx, s.wait_us, bool(s.data)

    def link_rx(self, reply, now_us):
        self.lib.bridge_link_rx(self.state, reply, now_us & 0xFFFFFFFF)
