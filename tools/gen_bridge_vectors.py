#!/usr/bin/env python3
"""Generate firmware/test/vectors.txt: golden traces of the bridge reference model.

The C core (firmware/core/bridge_core.c) must reproduce every line exactly. The traces are a
few hand-written scenarios plus seeded random ones (differential fuzzing: random MIDI streams
with junk, random GB replies with random timing, random link results).

Trace format, one step per line ('#' starts a comment):
  S <name>                 new scenario (fresh bridge)
  H <hex..> => <hex..>     host_in(bytes), then drain the GB-bound queue; expected bytes
  Q <hex..>                host_in(bytes), queue kept (for link scenarios)
  G <hex> <t_us>           gb_in(byte, t)
  D <t_us> => <hex..>      host_out_due(t); expected bytes
  N => <hex> <wait_us> <0|1>   link_next(): byte to clock, wait after it, real data?
  R <hex> <t_us>           link_rx(reply, t)
"""
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import bridge_ref as br  # noqa: E402

root = pathlib.Path(__file__).resolve().parent.parent
OUT = root / "firmware" / "test" / "vectors.txt"


def hx(bs):
    return " ".join(f"{x:02X}" for x in bs)


class Trace:
    def __init__(self):
        self.lines = []
        self.b = br.Bridge()

    def scenario(self, name):
        self.b = br.Bridge()
        self.lines.append(f"S {name}")

    def H(self, data):
        self.b.host_in(bytes(data))
        out = list(self.b.to_gb)
        self.b.to_gb.clear()
        self.lines.append(f"H {hx(data)} => {hx(out)}".rstrip())

    def Q(self, data):
        self.b.host_in(bytes(data))
        self.lines.append(f"Q {hx(data)}")

    def G(self, byte, t):
        self.b.gb_in(byte, t)
        self.lines.append(f"G {byte:02X} {t}")

    def D(self, t):
        out = self.b.host_out_due(t)
        self.lines.append(f"D {t} => {hx(out)}".rstrip())

    def N(self):
        tx, wait, data = self.b.link_next()
        self.lines.append(f"N => {tx:02X} {wait} {1 if data else 0}")

    def R(self, byte, t):
        self.b.link_rx(byte, t)
        self.lines.append(f"R {byte:02X} {t}")


def hand_written(t):
    t.scenario("notes and running status")
    t.H([0x90, 60, 100, 62, 100, 64, 0])
    t.H([0x80, 60, 0, 0xE0, 0, 64])
    t.scenario("filtering")
    t.H([0xD0, 50, 0xA0, 60, 50, 0xC0, 5, 0xB0, 7, 100, 0xF0, 1, 2, 3, 0xF7, 4, 5, 0xFE, 0xFF, 0xF9, 0xFD])
    t.H([0xB1, 1, 99, 120, 0, 123, 0, 64, 127])
    t.scenario("clock division")
    t.H([br.START] + [br.CLOCK] * 24)
    t.H([br.STOP, br.CONTINUE, br.CLOCK, br.CLOCK, br.CLOCK])
    t.H([br.START, br.CLOCK, br.CLOCK, br.CLOCK])
    t.scenario("clock interpolation")
    for i in range(8):
        t.G(br.CLOCK, i * 41_666)
    t.D(100_000)
    t.D(400_000)
    t.G(br.STOP, 500_000)
    t.G(br.START, 9_000_000)
    t.G(br.CLOCK, 9_000_000)
    t.G(br.CLOCK, 9_041_666)
    t.D(10_000_000)
    t.scenario("link")
    t.N()
    t.Q([0x90, 60, 100])
    t.N()
    t.R(0xFF, 0)
    t.R(br.IDLE, 1_000)
    t.Q([0x90, 60, 100])
    t.N()
    t.N()
    t.N()
    t.N()
    t.R(0x90, 5_000)
    t.R(60, 6_000)
    t.R(100, 7_000)
    t.D(10_000)


HOST_CHOICES = (
    [lambda r: r.randrange(0x80, 0xF0)] * 6          # channel status bytes
    + [lambda r: r.randrange(0x00, 0x80)] * 14        # data bytes
    + [lambda r: r.choice([0xF8, 0xF8, 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF, 0xF9, 0xFD])] * 5
    + [lambda r: r.choice([0xF0, 0xF7, 0xF1, 0xF2, 0xF3, 0xF6])] * 1
)


def host_chunk(r, n=None):
    n = n or r.randrange(1, 9)
    return [r.choice(HOST_CHOICES)(r) for _ in range(n)]


def fuzz_host(seed):
    r = random.Random(seed)
    t = Trace()
    t.scenario(f"fuzz host {seed}")
    for _ in range(120):
        t.H(host_chunk(r))
    return t


def fuzz_gb(seed):
    r = random.Random(1000 + seed)
    t = Trace()
    t.scenario(f"fuzz gb {seed}")
    now = r.randrange(0, 5_000_000)
    for _ in range(150):
        now += r.choice([0, 1, 500, 20_000, 41_666, 41_667, 100_000, 300_000, 900_000])
        kind = r.randrange(10)
        if kind < 5:
            t.G(br.CLOCK, now)
        elif kind == 5:
            t.G(r.choice([br.START, br.STOP, br.CONTINUE]), now)
        elif kind == 6:
            t.G(br.IDLE, now)
        elif kind == 7:
            for b in (r.choice([0x90, 0x80, 0x92]), r.randrange(36, 96), r.randrange(0, 128)):
                t.G(b, now)
        else:
            t.D(now + r.choice([-5, 0, 1, 20_000, 21_000, 60_000]) if now > 100_000 else now)
        if r.randrange(6) == 0:
            t.D(now + r.randrange(0, 80_000))
    t.D(now + 10_000_000)
    return t


def fuzz_link(seed):
    r = random.Random(2000 + seed)
    t = Trace()
    t.scenario(f"fuzz link {seed}")
    now = 0
    for _ in range(200):
        now += r.randrange(1, 3_000)
        kind = r.randrange(10)
        if kind < 3:
            t.Q(host_chunk(r, r.randrange(1, 5)))
        elif kind < 6:
            t.N()
        elif kind < 9:
            t.R(r.choice([0xFF, 0xFD, 0xFD, 0xF8, 0x90, 0x3C, 0x64, 0xFA, 0xFC, r.randrange(256)]), now)
        else:
            t.D(now + r.randrange(0, 60_000))
        while len(t.b.to_gb) > 300:                  # stay far below the C ring size
            t.N()
    t.D(now + 10_000_000)
    return t


def main():
    t = Trace()
    hand_written(t)
    for s in range(1, 13):
        for gen in (fuzz_host, fuzz_gb, fuzz_link):
            sub = gen(s)
            t.lines.extend(sub.lines)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    header = "# GENERATED by tools/gen_bridge_vectors.py from tools/bridge_ref.py -- do not edit by hand\n"
    OUT.write_text(header + "\n".join(t.lines) + "\n")
    print(f"{len(t.lines)} steps -> {OUT.relative_to(root)}")


if __name__ == "__main__":
    main()
